package com.auralis.core.data.graph

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.auralis.core.data.connector.ProductionServerConnector
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.db.AuralisDatabaseProvider
import com.auralis.core.data.prefs.AuralisPreferences
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.PlaybackSourceResolver
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.StreamUrlProvider
import com.auralis.core.domain.Track
import com.auralis.core.image.ArtworkUrl
import com.auralis.core.image.ArtworkUrlProvider
import com.auralis.core.offline.DownloadManager
import com.auralis.core.offline.DownloadServiceHolder
import com.auralis.core.opensubsonic.NetworkKind
import com.auralis.core.opensubsonic.OpenSubsonicClient
import com.auralis.core.opensubsonic.StreamQualityPolicy
import com.auralis.core.opensubsonic.StreamQualitySettings
import com.auralis.core.playback.DefaultPlaybackSourceResolver
import com.auralis.core.playback.PlaybackDependencies
import com.auralis.core.security.KeystoreCredentialVault
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient

/**
 * Auralis 组合根（对应 Apple `ApplicationComposition`）。
 *
 * 铁律：
 * - **数据库进程单例**：Connector / 仓储 / 搜索 / AI Tool Runtime 共用同一个
 *   [AuralisDatabaseProvider] 实例，杜绝 catalog split-brain；
 * - 播放器 / 下载器均为进程级单例；任何地方都不允许自行 `Room.databaseBuilder`。
 */
class AuralisGraph(context: Context) {

    val appContext: Context = context.applicationContext

    val database: AuralisDatabase = AuralisDatabaseProvider.get(appContext)
    val preferences = AuralisPreferences(appContext)
    val vault = KeystoreCredentialVault(appContext)

    val catalogRepository = RoomCatalogRepository(
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

    private val accountCache = ConcurrentHashMap<String, ServerAccount>()

    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val streamUrlProvider = StreamUrlProvider { track, _ -> resolveStreamUrl(track) }

    /** 冷启动本地优先：读已保存账号 → 填缓存，之后 resolveStreamUrl 不再碰网络探测。 */
    fun warmServerCache() {
        val servers = runBlocking { catalogRepository.servers() }
        servers.forEach { accountCache[it.id.value] = it }
        runBlocking {
            val active = preferences.activeServerIdValue()
            if (active == null && servers.isNotEmpty()) {
                preferences.setActiveServerId(servers.first().id.value)
            }
        }
    }

    private suspend fun resolveStreamUrl(track: Track): String? {
        val account = accountCache[track.serverId.value] ?: return null
        val settings = preferences.streamQualityFlow.first()
        val decision = StreamQualityPolicy.decide(settings, detectNetwork())
        val client = connector.clientFor(account)
        return runCatching { client.makeStreamUrl(track.id, decision) }.getOrNull()
    }

    private suspend fun resolveDownloadUrl(track: Track): String? {
        val account = accountCache[track.serverId.value] ?: return null
        val client = connector.clientFor(account)
        return runCatching { client.makeDownloadUrl(track.id) }.getOrNull()
    }

    private fun detectNetwork(): NetworkKind {
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return NetworkKind.Other
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return NetworkKind.Other
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkKind.Wifi
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkKind.Cellular
            else -> NetworkKind.Other
        }
    }

    val playbackResolver: PlaybackSourceResolver = DefaultPlaybackSourceResolver(
        downloads = catalogRepository,
        streamUrlProvider = streamUrlProvider,
    )

    /** 下载器：进程级，由 [com.auralis.core.offline.DownloadService] 持有。 */
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

    /** App 启动装配（幂等）。 */
    fun install() {
        warmServerCache()
        PlaybackDependencies.install(playbackResolver)
        ArtworkUrl.provider = ArtworkUrlProvider { serverId, artworkKey, size ->
            val account = accountCache[serverId.value] ?: return@ArtworkUrlProvider null
            val client = connector.clientFor(account)
            runBlocking { runCatching { client.coverArtUrl(artworkKey, size) }.getOrNull() }
        }
        downloadManager
    }

    /** 播放服务：跨 Activity / 进程内长期持有单个 ExoPlayer。 */
    fun startPlaybackService() {
        val intent = Intent(appContext, com.auralis.core.playback.AuralisPlaybackService::class.java)
        appContext.startForegroundService(intent)
    }

    fun startDownloadService() {
        val intent = Intent(appContext, com.auralis.core.offline.DownloadService::class.java)
        appContext.startService(intent)
    }

    suspend fun trackFor(globalId: GlobalId): Track? = catalogRepository.track(globalId)
}
