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

/** Auralis Android 组合根。 */
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
    val recommendationIndex = RecommendationIndexStore(database)
    val connector = ProductionServerConnector(vault, catalogRepository)
    val registry: ServerClientRegistry get() = connector.registry
    private val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
    private val streamUrlProvider = StreamUrlProvider { track, _ -> resolveStreamUrl(track) }
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

    suspend fun bootstrapFromLocal() {
        val servers = catalogRepository.servers()
        servers.forEach { account -> registerAccount(account) }
        if (servers.isNotEmpty()) {
            val active = preferences.activeServerIdValue()
            if (active == null || servers.none { it.id.value == active }) preferences.setActiveServerId(servers.first().id.value)
        }
    }

    suspend fun registerAccount(account: ServerAccount): ResolvedServerEndpoint {
        val savedKind = preferences.endpointKind(account.id.value)
        val endpoint = when (savedKind) {
            EndpointKind.External.name -> registry.makeExternalEndpoint(account) ?: registry.makeInternalEndpoint(account)
            else -> registry.makeInternalEndpoint(account)
        }
        registry.registerResolved(endpoint)
        return endpoint
    }

    suspend fun commitResolvedEndpoint(endpoint: ResolvedServerEndpoint) {
        registry.registerResolved(endpoint)
        preferences.setEndpointKind(endpoint.serverId.value, endpoint.kind.name)
    }

    suspend fun forgetServer(serverId: ServerId): ServerId? {
        val wasActive = preferences.activeServerIdValue() == serverId.value
        connector.forgetServer(serverId)
        recommendationIndex.clear(serverId)
        preferences.clearEndpointKind(serverId.value)
        val remaining = catalogRepository.servers()
        val next = if (wasActive) remaining.firstOrNull { it.id.value != serverId.value }?.id else remaining.firstOrNull()?.id
        preferences.setActiveServerId(next?.value)
        return next
    }

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

    val libraryActions by lazy { com.auralis.core.data.connector.LibraryActionCoordinator(registry, catalogRepository) }
    val playlistActions by lazy { com.auralis.core.data.connector.PlaylistCoordinator(registry, catalogRepository) }
    val historyCoordinator: com.auralis.core.data.connector.PlaybackHistoryCoordinator = com.auralis.core.data.connector.PlaybackHistoryCoordinator(registry, catalogRepository)
    val playbackResolver: PlaybackSourceResolver = DefaultPlaybackSourceResolver(downloads = catalogRepository, streamUrlProvider = streamUrlProvider)
    val lyricsService: com.auralis.core.lyrics.LyricsServiceImpl by lazy {
        com.auralis.core.lyrics.LyricsServiceImpl(store = RoomLyricsRepository(database.annotationDao()), remote = { track -> registry.client(track.serverId)?.lyricsFor(track) })
    }
    val downloadManager: DownloadManager by lazy {
        DownloadManager(context = appContext, downloads = catalogRepository, urlFactory = { track -> resolveDownloadUrl(track) }).also {
            DownloadServiceHolder.manager = it
            DownloadServiceHolder.initialized = true
        }
    }

    fun install() {
        PlaybackDependencies.install(playbackResolver, historyCoordinator)
        ArtworkUrl.provider = ArtworkUrlProvider { serverId, artworkKey, size ->
            val client = registry.client(serverId) ?: return@ArtworkUrlProvider null
            runBlocking { runCatching { client.coverArtUrl(artworkKey, size) }.getOrNull() }
        }
        downloadManager
    }

    /**
     * Create the MediaSessionService as an ordinary started service.
     *
     * Do not pre-emptively call startForegroundService here: callers may only mutate an idle queue,
     * or the first stream URL may fail/resolve slowly, either of which can miss Android's foreground
     * deadline. MediaSessionService/MediaNotificationManager owns the promotion instead: once the
     * registered player enters BUFFERING/READY with playWhenReady=true, Media3 starts this same
     * service as a foreground service and immediately posts the media notification.
     */
    fun startPlaybackService() {
        val intent = Intent(appContext, com.auralis.core.playback.AuralisPlaybackService::class.java)
        appContext.startService(intent)
    }

    fun startDownloadService() {
        val intent = Intent(appContext, com.auralis.core.offline.DownloadService::class.java)
        appContext.startForegroundService(intent)
    }

    suspend fun trackFor(globalId: GlobalId): Track? = catalogRepository.track(globalId)
    suspend fun lyricCacheCount(): Int = runCatching { database.annotationDao().lyricCount() }.getOrDefault(0)
    suspend fun clearLyricCache() { database.annotationDao().clearAllLyrics() }

    suspend fun serverSearch(serverId: ServerId, query: String, limit: Int): List<Track> {
        val client = registry.client(serverId) ?: throw IllegalStateException("服务器尚未就绪（无可用客户端）")
        val container = client.search(query = query, artistCount = 0, albumCount = 0, songCount = limit.coerceIn(1, 100))
        return container.song.map { com.auralis.core.opensubsonic.OpenSubsonicMapper.track(it, serverId) }
    }

    suspend fun similarSongs(serverId: ServerId, trackId: String, count: Int = 30): List<Track> {
        val client = registry.client(serverId) ?: throw IllegalStateException("服务器尚未就绪（无可用客户端）")
        return client.similarSongs(trackId = trackId, count = count.coerceIn(1, 100))
    }
}
