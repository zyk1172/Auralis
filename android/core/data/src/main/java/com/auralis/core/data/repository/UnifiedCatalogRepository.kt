// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.repository

import com.auralis.core.data.local.AndroidLocalMusicLibrary
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.CatalogRepository
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.Genre
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LibraryStats
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.SearchResults
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackQuality
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Public read facade for Auralis' unified library.
 *
 * Remote catalog rows remain owned by Room/CachedCatalogRepository and local files remain owned by
 * AndroidLocalMusicLibrary.  This facade composes them at the read boundary so Search, Library,
 * Home and the Assistant see one library without inventing a fake ServerAccount for local files.
 * Server mutations still delegate to the real remote repository; local annotations/history are
 * handled by the local-library runtime and therefore never fall through to OpenSubsonic.
 *
 * ## 为什么除了「合并」还需要「合并结果缓存」
 *
 * `Flow` 的 `combine`/`map` transform **在收集者上下文执行**，而这里的合并后处理
 * （`TrackQuality.deduplicatedPreferringQuality`）是 O(N) 的字符串归一化 + HashMap 去重。
 * Compose 侧的习惯写法是「每个列表行订阅一次收藏集合」（见 `lib`/`LibraryTrackRow`），
 * 于是同一份全量收藏会被去重 N 次，而且全部落在 Main 上，形成行数 × 库规模的双重放大。
 *
 * 因此每个「远端 + 本地」家族在这里只建**每服务器一条**热流（`replay = 1`）：合并与去重
 * 只做一次，所有调用方共享同一个快照。同时所有上游（含 `suspend` 读取路径）统一切到
 * [CatalogDispatcher]，保证 JSON 解码与集合运算不再阻塞 Main。
 */
class UnifiedCatalogRepository(
    private val delegate: CachedCatalogRepository,
    private val local: AndroidLocalMusicLibrary,
    scope: CoroutineScope,
) : CatalogRepository by delegate, DownloadRepository by delegate {

    private val localServerId: ServerId get() = AndroidLocalMusicLibrary.LOCAL_SERVER_ID

    private val scope: CoroutineScope = scope

    /** 合并流缓存项：热流 + 负责喂它的收集任务。 */
    private class Cached<T>(val flow: SharedFlow<T>, val job: Job)

    private val mergedArtists = ConcurrentHashMap<String, Cached<List<Artist>>>()
    private val mergedAlbums = ConcurrentHashMap<String, Cached<List<Album>>>()
    private val mergedTracks = ConcurrentHashMap<String, Cached<List<Track>>>()
    private val mergedGenres = ConcurrentHashMap<String, Cached<List<Genre>>>()
    private val mergedFavorites = ConcurrentHashMap<String, Cached<List<Track>>>()
    private val mergedDisliked = ConcurrentHashMap<String, Cached<List<GlobalId>>>()

    /**
     * 把 [upstream] 变成每服务器一条的热流。
     *
     * `replay = 1` 保证后进入的页面立即拿到最近一次快照；`DROP_OLDEST` 保证下游消费慢时上游
     * 收集器不会被 `emit` 挂住（快照语义下旧值可以直接丢弃）。
     */
    private fun <T> merged(
        cache: ConcurrentHashMap<String, Cached<T>>,
        serverId: ServerId,
        upstream: () -> Flow<T>,
    ): Flow<T> = cache.computeIfAbsent(serverId.value) {
        val replay = MutableSharedFlow<T>(
            replay = 1,
            extraBufferCapacity = 1,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
        val job = scope.launch {
            upstream().flowOn(CatalogDispatcher).collect { replay.emit(it) }
        }
        Cached(replay, job)
    }.flow

    override fun observeArtists(serverId: ServerId?): Flow<List<Artist>> {
        val localFlow = local.tracks.map(::localArtists).distinctUntilChanged()
        if (serverId == null || serverId == localServerId) return localFlow.flowOn(CatalogDispatcher)
        return merged(mergedArtists, serverId) {
            combine(delegate.observeArtists(serverId), localFlow) { remote, localItems ->
                remote + localItems
            }
        }
    }

    override fun observeAlbums(serverId: ServerId?): Flow<List<Album>> {
        val localFlow = local.tracks.map(::localAlbums).distinctUntilChanged()
        if (serverId == null || serverId == localServerId) return localFlow.flowOn(CatalogDispatcher)
        return merged(mergedAlbums, serverId) {
            combine(delegate.observeAlbums(serverId), localFlow) { remote, localItems ->
                remote + localItems
            }
        }
    }

    override fun observeTracks(serverId: ServerId?): Flow<List<Track>> {
        // 纯本地路径直接透传 StateFlow：它本身就是快照，没有需要下放的计算，且
        // SharedFlow 上的 flowOn 是无效操作（kotlinx.coroutines 已将其标记为 ERROR）。
        if (serverId == null || serverId == localServerId) return local.tracks
        return merged(mergedTracks, serverId) {
            combine(delegate.observeTracks(serverId), local.tracks) { remote, localTracks ->
                TrackQuality.deduplicatedPreferringQuality(remote + localTracks)
            }
        }
    }

    override fun observeGenres(serverId: ServerId?): Flow<List<Genre>> {
        val localFlow = local.tracks.map(::localGenres).distinctUntilChanged()
        if (serverId == null || serverId == localServerId) return localFlow.flowOn(CatalogDispatcher)
        return merged(mergedGenres, serverId) {
            combine(delegate.observeGenres(serverId), localFlow) { remote, localItems ->
                mergeGenresForRead(remote, localItems)
            }
        }
    }

    override fun observePlaylists(serverId: ServerId?): Flow<List<Playlist>> =
        if (serverId == null || serverId == localServerId) flowOf(emptyList()) else delegate.observePlaylists(serverId)

    override suspend fun track(globalId: GlobalId): Track? =
        if (globalId.serverId == localServerId) local.track(globalId) else delegate.track(globalId)

    override suspend fun album(globalId: GlobalId): Album? =
        if (globalId.serverId == localServerId) {
            withContext(CatalogDispatcher) { localAlbums(local.tracks.value).firstOrNull { it.globalId == globalId } }
        } else {
            delegate.album(globalId)
        }

    override suspend fun artist(globalId: GlobalId): Artist? =
        if (globalId.serverId == localServerId) {
            withContext(CatalogDispatcher) { localArtists(local.tracks.value).firstOrNull { it.globalId == globalId } }
        } else {
            delegate.artist(globalId)
        }

    override suspend fun playlist(globalId: GlobalId): Playlist? =
        if (globalId.serverId == localServerId) null else delegate.playlist(globalId)

    override suspend fun albumTracks(albumGlobalId: GlobalId): List<Track> =
        if (albumGlobalId.serverId == localServerId) {
            withContext(CatalogDispatcher) {
                local.tracks.value.filter { it.albumId.value == albumGlobalId.remoteId }
            }
        } else {
            delegate.albumTracks(albumGlobalId)
        }

    override suspend fun artistAlbums(artistGlobalId: GlobalId): List<Album> =
        if (artistGlobalId.serverId == localServerId) {
            withContext(CatalogDispatcher) {
                localAlbums(local.tracks.value).filter { it.artistId.value == artistGlobalId.remoteId }
            }
        } else {
            delegate.artistAlbums(artistGlobalId)
        }

    override suspend fun artistTracks(artistGlobalId: GlobalId): List<Track> =
        if (artistGlobalId.serverId == localServerId) {
            withContext(CatalogDispatcher) {
                local.tracks.value.filter { it.artistId.value == artistGlobalId.remoteId }
            }
        } else {
            delegate.artistTracks(artistGlobalId)
        }

    override suspend fun playlistTracks(playlistGlobalId: GlobalId): List<Track> =
        if (playlistGlobalId.serverId == localServerId) emptyList() else delegate.playlistTracks(playlistGlobalId)

    override suspend fun search(serverId: ServerId?, query: String, limit: Int): SearchResults {
        // 本地全库扫描必须后台执行：即使当前选中的是远端服务器，这一步也无条件先跑一次。
        val localResult = withContext(CatalogDispatcher) { localSearch(query, limit) }
        if (serverId == null || serverId == localServerId) return localResult
        val remote = delegate.search(serverId, query, limit)
        return withContext(CatalogDispatcher) {
            SearchResults(
                songs = TrackQuality.deduplicatedPreferringQuality(remote.songs + localResult.songs).take(limit),
                albums = (remote.albums + localResult.albums).distinctBy { it.globalId }.take(limit),
                artists = (remote.artists + localResult.artists).distinctBy { it.globalId }.take(limit),
                playlists = remote.playlists.take(limit),
            )
        }
    }

    override suspend fun stats(serverId: ServerId?): LibraryStats = withContext(CatalogDispatcher) {
        val localTracks = local.tracks.value
        val localStats = LibraryStats(
            artistCount = localArtists(localTracks).size,
            albumCount = localAlbums(localTracks).size,
            trackCount = localTracks.size,
            playlistCount = 0,
        )
        if (serverId == null || serverId == localServerId) return@withContext localStats
        val remote = delegate.stats(serverId)
        LibraryStats(
            artistCount = remote.artistCount + localStats.artistCount,
            albumCount = remote.albumCount + localStats.albumCount,
            trackCount = remote.trackCount + localStats.trackCount,
            playlistCount = remote.playlistCount,
        )
    }

    override fun observeFavoriteTracks(serverId: ServerId?): Flow<List<Track>> {
        val localFavorites = local.tracks.map { tracks -> tracks.filter { it.isFavorite } }.distinctUntilChanged()
        if (serverId == null || serverId == localServerId) return localFavorites.flowOn(CatalogDispatcher)
        return merged(mergedFavorites, serverId) {
            combine(delegate.observeFavoriteTracks(serverId), localFavorites) { remote, localItems ->
                TrackQuality.deduplicatedPreferringQuality(remote + localItems)
            }
        }
    }

    override suspend fun favoriteTracks(serverId: ServerId?): List<Track> =
        observeFavoriteTracks(serverId).firstSnapshot()

    override suspend fun mostPlayedTracks(serverId: ServerId?, limit: Int): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value
                .map { it to local.playCount(it.globalId) }
                .filter { it.second > 0 }
                .sortedByDescending { it.second }
                .map { it.first }
            if (serverId == null || serverId == localServerId) return@withContext localItems.take(limit)
            TrackQuality.deduplicatedPreferringQuality(delegate.mostPlayedTracks(serverId, limit) + localItems).take(limit)
        }

    override suspend fun setFavorite(globalId: GlobalId, kind: FavoriteKind, value: Boolean) {
        if (globalId.serverId == localServerId) {
            if (kind != FavoriteKind.Track) throw IllegalArgumentException("本地专辑/艺术家收藏尚未启用")
            local.setFavorite(globalId, value)
        } else {
            delegate.setFavorite(globalId, kind, value)
        }
    }

    override suspend fun setRating(globalId: GlobalId, rating: Int?) {
        if (globalId.serverId == localServerId) local.setRating(globalId, rating)
        else delegate.setRating(globalId, rating)
    }

    override suspend fun recordPlay(globalId: GlobalId, completed: Boolean) {
        if (globalId.serverId == localServerId) local.recordPlay(globalId, completed)
        else delegate.recordPlay(globalId, completed)
    }

    override suspend fun markCompleted(globalId: GlobalId) {
        if (globalId.serverId == localServerId) local.markCompleted(globalId)
        else delegate.markCompleted(globalId)
    }

    override suspend fun setDisliked(globalId: GlobalId, disliked: Boolean) {
        if (globalId.serverId == localServerId) local.setDisliked(globalId, disliked)
        else delegate.setDisliked(globalId, disliked)
    }

    override suspend fun isDisliked(globalId: GlobalId): Boolean =
        if (globalId.serverId == localServerId) local.isDisliked(globalId) else delegate.isDisliked(globalId)

    override suspend fun dislikedIds(serverId: ServerId): Set<GlobalId> = withContext(CatalogDispatcher) {
        if (serverId == localServerId) local.dislikedIds() else delegate.dislikedIds(serverId) + local.dislikedIds()
    }

    override fun observeDislikedIds(serverId: ServerId?): Flow<List<GlobalId>> {
        val localFlow = combine(local.tracks, local.revision) { _, _ -> local.dislikedIds().toList() }
            .distinctUntilChanged()
            .flowOn(CatalogDispatcher)
        if (serverId == null || serverId == localServerId) return localFlow
        return merged(mergedDisliked, serverId) {
            combine(delegate.observeDislikedIds(serverId), localFlow) { remote, localItems ->
                (remote + localItems).distinct()
            }
        }
    }

    override suspend fun isFavorite(globalId: GlobalId): Boolean =
        if (globalId.serverId == localServerId) local.track(globalId)?.isFavorite == true
        else delegate.isFavorite(globalId)

    override suspend fun isFavorite(globalId: GlobalId, kind: FavoriteKind): Boolean =
        if (globalId.serverId == localServerId) kind == FavoriteKind.Track && local.track(globalId)?.isFavorite == true
        else delegate.isFavorite(globalId, kind)

    override suspend fun neverPlayed(serverId: ServerId?, limit: Int): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value.filter { local.playCount(it.globalId) == 0 }
            if (serverId == null || serverId == localServerId) return@withContext localItems.take(limit)
            TrackQuality.deduplicatedPreferringQuality(delegate.neverPlayed(serverId, limit) + localItems).take(limit)
        }

    override suspend fun longUnplayed(serverId: ServerId?, limit: Int): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value.sortedBy { local.lastPlayedMillis(it.globalId) ?: Long.MIN_VALUE }
            if (serverId == null || serverId == localServerId) return@withContext localItems.take(limit)
            TrackQuality.deduplicatedPreferringQuality(delegate.longUnplayed(serverId, limit) + localItems).take(limit)
        }

    override suspend fun recentlyPlayed(serverId: ServerId?, limit: Int): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value
                .mapNotNull { track -> local.lastPlayedMillis(track.globalId)?.let { track to it } }
                .sortedByDescending { it.second }
                .map { it.first }
            if (serverId == null || serverId == localServerId) return@withContext localItems.take(limit)
            TrackQuality.deduplicatedPreferringQuality(delegate.recentlyPlayed(serverId, limit) + localItems).take(limit)
        }

    override suspend fun randomTracks(serverId: ServerId?, limit: Int): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value.shuffled().take(limit)
            if (serverId == null || serverId == localServerId) return@withContext localItems
            TrackQuality.deduplicatedPreferringQuality(delegate.randomTracks(serverId, limit) + localItems)
                .shuffled()
                .take(limit)
        }

    override suspend fun favoriteRandom(serverId: ServerId?, limit: Int): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value.filter { it.isFavorite }.shuffled().take(limit)
            if (serverId == null || serverId == localServerId) return@withContext localItems
            TrackQuality.deduplicatedPreferringQuality(delegate.favoriteRandom(serverId, limit) + localItems)
                .shuffled()
                .take(limit)
        }

    override suspend fun favoriteCount(serverId: ServerId?): Int = withContext(CatalogDispatcher) {
        val localCount = local.tracks.value.count { it.isFavorite }
        if (serverId == null || serverId == localServerId) localCount else delegate.favoriteCount(serverId) + localCount
    }

    override suspend fun playedTrackCount(serverId: ServerId?): Int = withContext(CatalogDispatcher) {
        val localCount = local.tracks.value.count { local.playCount(it.globalId) > 0 }
        if (serverId == null || serverId == localServerId) localCount else delegate.playedTrackCount(serverId) + localCount
    }

    override suspend fun genreTracks(serverId: ServerId?, genreName: String): List<Track> =
        withContext(CatalogDispatcher) {
            val localItems = local.tracks.value.filter { track ->
                track.genres.any { it.equals(genreName, ignoreCase = true) }
            }
            if (serverId == null || serverId == localServerId) return@withContext localItems
            TrackQuality.deduplicatedPreferringQuality(delegate.genreTracks(serverId, genreName) + localItems)
        }

    fun homeChangeSignals(serverId: ServerId?): Flow<Unit> =
        merge(
            if (serverId == null || serverId == localServerId) flowOf(Unit) else delegate.homeChangeSignals(serverId),
            local.revision.map { Unit },
        ).flowOn(CatalogDispatcher)

    suspend fun mergeGenres(serverId: ServerId, values: List<Genre>) {
        if (serverId != localServerId) delegate.mergeGenres(serverId, values)
    }

    /**
     * 忘记服务器时同时释放合并流缓存，避免留下「仍在观察已删除服务器」的常驻收集任务。
     */
    fun evict(serverId: ServerId) {
        if (serverId != localServerId) delegate.evict(serverId)
        listOf(mergedArtists, mergedAlbums, mergedTracks, mergedGenres, mergedFavorites, mergedDisliked)
            .forEach { cache -> cache.remove(serverId.value)?.job?.cancel() }
    }

    private fun localSearch(query: String, limit: Int): SearchResults {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) return SearchResults()
        val tracks = local.tracks.value
        fun String.matches(): Boolean = lowercase().contains(needle)
        val songs = tracks.filter {
            it.title.matches() || it.artistName.matches() || it.albumTitle.matches()
        }.take(limit)
        val albums = localAlbums(tracks).filter { it.title.matches() || it.artistName.matches() }.take(limit)
        val artists = localArtists(tracks).filter { it.name.matches() }.take(limit)
        return SearchResults(songs = songs, albums = albums, artists = artists)
    }

    private fun localArtists(tracks: List<Track>): List<Artist> =
        tracks.groupBy { it.artistId }.map { (artistId, group) ->
            Artist(
                id = artistId,
                serverId = localServerId,
                name = group.first().artistName,
                albumCount = group.map { it.albumId }.distinct().size,
            )
        }.sortedBy { it.name.lowercase() }

    private fun localAlbums(tracks: List<Track>): List<Album> =
        tracks.groupBy { it.albumId }.map { (albumId, group) ->
            val first = group.first()
            Album(
                id = albumId,
                serverId = localServerId,
                artistId = first.artistId,
                title = first.albumTitle,
                artistName = first.artistName,
                year = group.mapNotNull { it.year }.firstOrNull(),
                genre = group.flatMap { it.genres }.firstOrNull(),
                songCount = group.size,
            )
        }.sortedWith(compareBy<Album> { it.artistName.lowercase() }.thenBy { it.title.lowercase() })

    /**
     * 归一化流派表。
     *
     * 历史实现对**每个**归一化流派重新遍历全部曲目的 genres 去找显示名（O(G×N)），且每次比较
     * 都新建 `trim().lowercase()` 字符串。改为一趟建立「归一化 → 首个原始写法」映射后整体降为
     * O(N)，比较不再产生额外分配。
     */
    private fun localGenres(tracks: List<Track>): List<Genre> {
        val displayByNormalized = HashMap<String, String>()
        val countByNormalized = HashMap<String, Int>()
        tracks.forEach { track ->
            track.genres.forEach { raw ->
                val trimmed = raw.trim()
                if (trimmed.isEmpty()) return@forEach
                val normalized = trimmed.lowercase()
                displayByNormalized.putIfAbsent(normalized, trimmed)
                countByNormalized[normalized] = (countByNormalized[normalized] ?: 0) + 1
            }
        }
        return countByNormalized.map { (normalized, count) ->
            Genre(displayByNormalized[normalized] ?: normalized, count, localServerId)
        }.sortedBy { it.name.lowercase() }
    }

    private fun mergeGenresForRead(remote: List<Genre>, localItems: List<Genre>): List<Genre> {
        val result = LinkedHashMap<String, Genre>()
        (remote + localItems).forEach { genre ->
            val key = genre.name.trim().lowercase()
            val previous = result[key]
            result[key] = if (previous == null) genre else previous.copy(songCount = previous.songCount + genre.songCount)
        }
        return result.values.toList()
    }

    private suspend fun <T> Flow<List<T>>.firstSnapshot(): List<T> = first()

    private companion object {
        /**
         * 目录合并/解码的执行器。
         *
         * 用 Default 而不是 IO：JSON 反序列化与集合去重是 CPU 工作，IO 池需要留给网络与文件。
         */
        val CatalogDispatcher: CoroutineDispatcher = Dispatchers.Default
    }
}
