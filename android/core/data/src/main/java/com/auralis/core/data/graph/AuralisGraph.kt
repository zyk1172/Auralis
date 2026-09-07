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
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * Auralis 组合根（对应 Apple `ApplicationComposition`）。
 *
 * 铁律：
 * - **数据库进程单例**：Connector / 仓储 / 搜索 / AI Tool Runtime 共用同一个
 *   [AuralisDatabaseProvider] 实例，杜绝 catalog split-brain；
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
     * @return 切换后应激活的服务器（null = 无服务器）。
     */
    suspend fun forgetServer(serverId: ServerId): ServerId? {
        val wasActive = preferences.activeServerIdValue() == serverId.value
        connector.forgetServer(serverId)
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

    /** 下载器：进程级，由 DownloadService 持有。 */
    /** 歌词：本地优先（Room），未命中才走当前服务器客户端（结构化 → 纯文本兜底）。 */
    val lyricsService: com.auralis.core.lyrics.LyricsServiceImpl by lazy {
        com.auralis.core.lyrics.LyricsServiceImpl(
            store = RoomLyricsRepository(database.annotationDao()),
            remote = { track -> registry.client(track.serverId)?.lyricsFor(track) },
        )
    }

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

    /** 播放服务：跨 Activity 进程内长期持有单个 ExoPlayer。 */
    fun startPlaybackService() {
        val intent = Intent(appContext, com.auralis.core.playback.AuralisPlaybackService::class.java)
        appContext.startForegroundService(intent)
    }

    fun startDownloadService() {
        val intent = Intent(appContext, com.auralis.core.offline.DownloadService::class.java)
        appContext.startService(intent)
    }

    suspend fun trackFor(globalId: GlobalId): Track? = catalogRepository.track(globalId)

    // ------------------------------------------------------------ 缓存管理（设置页）

    /** 歌词缓存行数（设置 → 数据与备份 统计；失败按 0 处理不抛给 UI）。 */
    suspend fun lyricCacheCount(): Int =
        runCatching { database.annotationDao().lyricCount() }.getOrDefault(0)

    /** 清空全部歌词缓存（Room lyrics 表），对齐 Swift `clearLyricsCache`。 */
    suspend fun clearLyricCache() {
        database.annotationDao().clearAllLyrics()
    }

    // ------------------------------------------------------------ 服务器在线搜索

    /**
     * 在线搜索（OpenSubsonic `search3`，对齐 Apple `AuralisAppModel.searchOnServer`：
     * 服务器搜索结果只取歌曲，本地无结果时作为兜底播放源）。
     * 无该服务器的可用客户端时抛 [IllegalStateException]，由 UI 如实呈现，不伪装空结果。
     */
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
}
