// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.graph

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.auralis.core.data.connector.EndpointKind
import com.auralis.core.data.connector.ProductionServerConnector
import com.auralis.core.data.connector.ResolvedServerEndpoint
import com.auralis.core.data.connector.ServerClientRegistry
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.db.AuralisDatabaseProvider
import com.auralis.core.data.prefs.AuralisPreferences
import com.auralis.core.data.repository.RecommendationIndexStore
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.data.repository.RoomLyricsRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.PlaybackSourceResolver
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.StreamUrlProvider
import com.auralis.core.domain.Track
import com.auralis.core.image.ArtworkUrl
import com.auralis.core.image.ArtworkUrlProvider
import com.auralis.core.offline.DownloadManager
import com.auralis.core.offline.DownloadServiceHolder
import com.auralis.core.opensubsonic.NetworkKind
import com.auralis.core.opensubsonic.StreamQualityPolicy
import com.auralis.core.playback.DefaultPlaybackSourceResolver
import com.auralis.core.playback.PlaybackDependencies
import com.auralis.core.security.KeystoreCredentialVault
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * Auralis 组合根（对应 Apple `ApplicationComposition`）。
 *
 * 铁律：
 * - **数据库进程单例**：Connector / 仓储 / Search / Recommendation Index / AI Tool Runtime
 *   共用同一个 [AuralisDatabaseProvider] 实例，杜绝 catalog split-brain；
 * - **服务器客户端唯一来源是 [ServerClientRegistry]**（connector 持有）。Graph 不再
 *   维护第二份易漂移的 accountCache：resolveStream / download / cover 一律
 *   `registry.client(serverId)` 取当前真正可用的端点；
 * - 播放器 / 下载器均为进程级单例。
 */
class AuralisGraph(context: Context) {

    val appContext: Context = context.applicationContext

    val database: AuralisDatabase = AuralisDatabaseProvider.get(appContext)
    val preferences = AuralisPreferences(appContext)
    val vault = KeystoreCredentialVault(appContext)

    val catalogRepository = RoomCatalogRepository(
        database = database,
        serverDao = database.serverDao(),
        artistDao = database.artistDao(),
        albumDao = database.albumDao(),
        trackDao = database.trackDao(),
        trackFtsDao = database.trackFtsDao(),
        genreDao = database.genreDao(),
        playlistDao = database.playlistDao(),
        annotationDao = database.annotationDao(),
        downloadDao = database.downloadDao(),
        syncDao = database.syncDao(),
    )

    /** 与 Catalog 使用同一个 Room 实例；Categories / Agent classifier 只能从这里访问索引。 */
    val recommendationIndex = RecommendationIndexStore(database)

    val connector = ProductionServerConnector(vault, catalogRepository)

    /** 服务器客户端注册表：连接成功后登记；这是唯一真实来源。 */
    val registry: ServerClientRegistry get() = connector.registry

    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val streamUrlProvider = StreamUrlProvider { track, _ -> resolveStreamUrl(track) }

    /** 应用级后台作用域（Room 就绪后的本地恢复等，不阻塞首屏、不做网络门槛）。 */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private fun detectNetwork(): NetworkKind {
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return NetworkKind.Other
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return NetworkKind.Other
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkKind.Wifi
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkKind.Cellular
            else -> NetworkKind.Other
        }
    }

    // ------------------------------------------------------ 账户管理（原子接口）

    /**
     * 冷启动本地恢复：读已保存账号 → 按上次选中的端点类型（内/外网）重建客户端并登记。
     * 只做本地读取，不发起 ping / 不做网络门槛；随后 Shell 后台探测可再切换端点。
     */
    suspend fun bootstrapFromLocal() {
        val servers = catalogRepository.servers()
        servers.forEach { account -> registerAccount(account) }
        if (servers.isNotEmpty()) {
            val active = preferences.activeServerIdValue()
            if (active == null || servers.none { it.id.value == active }) {
                preferences.setActiveServerId(servers.first().id.value)
            }
        }
    }

    /** 按账户构造端点并登记（kind 依据上次持久化选择；未记录 → 内网）。 */
    suspend fun registerAccount(account: ServerAccount): ResolvedServerEndpoint {
        val savedKind = preferences.endpointKind(account.id.value)
        val endpoint = when (savedKind) {
            EndpointKind.External.name -> {
                val ext = runCatching { registry.makeExternalEndpoint(account) }.getOrNull()
                if (ext != null) ext else registry.makeInternalEndpoint(account)
            }

            else -> registry.makeInternalEndpoint(account)
        }
        registry.registerResolved(endpoint)
        return endpoint
    }

    /** 连接/编辑成功提交后登记真实端点并持久化选中类型（重启恢复外网路由）。 */
    suspend fun commitResolvedEndpoint(endpoint: ResolvedServerEndpoint) {
        registry.registerResolved(endpoint)
        preferences.setEndpointKind(endpoint.serverId.value, endpoint.kind.name)
    }

    /**
     * 忘记服务器：删除 server-scoped 目录/凭据/客户端，并处理 active 切换。
     * Recommendation tag 表没有外键级 server_id，所以 connector 成功删除服务器后还必须
     * 显式清掉对应 state/tags，否则会留下永远不可达的索引孤儿。
     * @return 切换后应激活的服务器（null = 无服务器）。
     */
    suspend fun forgetServer(serverId: ServerId): ServerId? {
        val wasActive = preferences.activeServerIdValue() == serverId.value
        connector.forgetServer(serverId)
        recommendationIndex.clear(serverId)
        preferences.clearEndpointKind(serverId.value)
        val remaining = catalogRepository.servers()
        val next = if (wasActive) {
            remaining.firstOrNull { it.id.value != serverId.value }?.id
        } else {
            remaining.firstOrNull()?.id
        }
        preferences.setActiveServerId(next?.value)
        return next
    }

    // ------------------------------------------------------ URL 解析（走注册表）

    private suspend fun resolveStreamUrl(track: Track): String? {
        val client = registry.client(track.serverId) ?: return null
        val settings = preferences.streamQualityFlow.first()
        val decision = StreamQualityPolicy.decide(settings, detectNetwork())
        return runCatching { client.makeStreamUrl(track.id, decision) }.getOrNull()
    }

    private suspend fun resolveDownloadUrl(track: Track): String? {
        val client = registry.client(track.serverId) ?: return null
        return runCatching { client.makeDownloadUrl(track.id) }.getOrNull()
    }

    // ------------------------------------------------------ 依赖装配

    /** 收藏/评分协调器（远端先行，成功后落本地）。 */
    val libraryActions by lazy {
        com.auralis.core.data.connector.LibraryActionCoordinator(registry, catalogRepository)
    }

    /** 歌单动作协调器（远端先行；rename/add/remove 后用服务器最新详情整表替换本地）。 */
    val playlistActions by lazy {
        com.auralis.core.data.connector.PlaylistCoordinator(registry, catalogRepository)
    }

    /** 播放历史/scrobble 协调器：由 App 注入到播放引擎的 historySink。 */
    val historyCoordinator: com.auralis.core.data.connector.PlaybackHistoryCoordinator =
        com.auralis.core.data.connector.PlaybackHistoryCoordinator(registry, catalogRepository)

    val playbackResolver: PlaybackSourceResolver = DefaultPlaybackSourceResolver(
        downloads = catalogRepository,
        streamUrlProvider = streamUrlProvider,
    )

    /** 歌词：本地优先（Room），未命中才走当前服务器客户端（结构化 → 纯文本兜底）。 */
    val lyricsService: com.auralis.core.lyrics.LyricsServiceImpl by lazy {
        com.auralis.core.lyrics.LyricsServiceImpl(
            store = RoomLyricsRepository(database.annotationDao()),
            remote = { track -> registry.client(track.serverId)?.lyricsFor(track) },
        )
    }

    /** 下载器：进程级，由 DownloadService 持有。 */
    val downloadManager: DownloadManager by lazy {
        DownloadManager(
            context = appContext,
            downloads = catalogRepository,
            urlFactory = { track -> resolveDownloadUrl(track) },
        ).also {
            DownloadServiceHolder.manager = it
            DownloadServiceHolder.initialized = true
        }
    }

    /** App 启动装配（幂等、同步、不阻塞：数据库按需打开，注册表由 bootstrap 填充）。 */
    fun install() {
        PlaybackDependencies.install(playbackResolver, historyCoordinator)
        ArtworkUrl.provider = ArtworkUrlProvider { serverId, artworkKey, size ->
            val client = registry.client(serverId) ?: return@ArtworkUrlProvider null
            runBlocking { runCatching { client.coverArtUrl(artworkKey, size) }.getOrNull() }
        }
        downloadManager
    }

    /**
     * 播放服务：先作为普通 started service 创建并注册 MediaSession。
     *
     * 这里不能预先调用 startForegroundService：冷启动后用户可能只执行“下一首播放/加入队列”
     * 而并不真正开始播放，或者首曲 URL 解析失败/变慢；这两种情况都会让 Android 的 FGS
     * deadline 在播放器进入前台前到期。真正开始播放时，Media3 的 MediaNotificationManager
     * 会在已注册 Player 进入 BUFFERING/READY 且 playWhenReady=true 后，自行把同一服务提升
     * 为 mediaPlayback foreground service 并同步发布通知。
     */
    fun startPlaybackService() {
        val intent = Intent(appContext, com.auralis.core.playback.AuralisPlaybackService::class.java)
        appContext.startService(intent)
    }

    /**
     * 下载是长期 dataSync 前台任务。Android 8+ 从后台启动普通 Service 会直接被系统拒绝，
     * 因此下载继续走 startForegroundService；DownloadService 会在收到启动后立即
     * 根据 activeCount 进入前台或自停。
     */
    fun startDownloadService() {
        val intent = Intent(appContext, com.auralis.core.offline.DownloadService::class.java)
        appContext.startForegroundService(intent)
    }

    suspend fun trackFor(globalId: GlobalId): Track? = catalogRepository.track(globalId)

    // ------------------------------------------------------------ 缓存管理

    suspend fun lyricCacheCount(): Int =
        runCatching { database.annotationDao().lyricCount() }.getOrDefault(0)

    suspend fun clearLyricCache() {
        database.annotationDao().clearAllLyrics()
    }

    suspend fun serverSearch(serverId: ServerId, query: String, limit: Int): List<Track> {
        val client = registry.client(serverId)
            ?: throw IllegalStateException("服务器尚未就绪（无可用客户端）")
        val container = client.search(
            query = query,
            artistCount = 0,
            albumCount = 0,
            songCount = limit.coerceIn(1, 100),
        )
        return container.song.map { com.auralis.core.opensubsonic.OpenSubsonicMapper.track(it, serverId) }
    }

    suspend fun similarSongs(serverId: ServerId, trackId: String, count: Int = 30): List<Track> {
        val client = registry.client(serverId)
            ?: throw IllegalStateException("服务器尚未就绪（无可用客户端）")
        return client.similarSongs(trackId = trackId, count = count.coerceIn(1, 100))
    }
}
