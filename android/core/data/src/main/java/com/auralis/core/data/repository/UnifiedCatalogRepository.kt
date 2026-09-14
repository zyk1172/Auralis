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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge

/**
 * Public read facade for Auralis' unified library.
 *
 * Remote catalog rows remain owned by Room/CachedCatalogRepository and local files remain owned by
 * AndroidLocalMusicLibrary.  This facade composes them at the read boundary so Search, Library,
 * Home and the Assistant see one library without inventing a fake ServerAccount for local files.
 * Server mutations still delegate to the real remote repository; local annotations/history are
 * handled by the local-library runtime and therefore never fall through to OpenSubsonic.
 */
class UnifiedCatalogRepository(
    private val delegate: CachedCatalogRepository,
    private val local: AndroidLocalMusicLibrary,
) : CatalogRepository by delegate, DownloadRepository by delegate {

    private val localServerId: ServerId get() = AndroidLocalMusicLibrary.LOCAL_SERVER_ID

    override fun observeArtists(serverId: ServerId?): Flow<List<Artist>> {
        val localFlow = local.tracks.map(::localArtists).distinctUntilChanged()
        if (serverId == localServerId) return localFlow
        return combine(delegate.observeArtists(serverId), localFlow) { remote, localItems ->
            remote + localItems
        }
    }

    override fun observeAlbums(serverId: ServerId?): Flow<List<Album>> {
        val localFlow = local.tracks.map(::localAlbums).distinctUntilChanged()
        if (serverId == localServerId) return localFlow
        return combine(delegate.observeAlbums(serverId), localFlow) { remote, localItems ->
            remote + localItems
        }
    }

    override fun observeTracks(serverId: ServerId?): Flow<List<Track>> {
        if (serverId == localServerId) return local.tracks
        return combine(delegate.observeTracks(serverId), local.tracks) { remote, localTracks ->
            TrackQuality.deduplicatedPreferringQuality(remote + localTracks)
        }
    }

    override fun observeGenres(serverId: ServerId?): Flow<List<Genre>> {
        val localFlow = local.tracks.map(::localGenres).distinctUntilChanged()
        if (serverId == localServerId) return localFlow
        return combine(delegate.observeGenres(serverId), localFlow) { remote, localItems ->
            mergeGenresForRead(remote, localItems)
        }
    }

    override fun observePlaylists(serverId: ServerId?): Flow<List<Playlist>> =
        if (serverId == localServerId) flowOf(emptyList()) else delegate.observePlaylists(serverId)

    override suspend fun track(globalId: GlobalId): Track? =
        if (globalId.serverId == localServerId) local.track(globalId) else delegate.track(globalId)

    override suspend fun album(globalId: GlobalId): Album? =
        if (globalId.serverId == localServerId) localAlbums(local.tracks.value).firstOrNull { it.globalId == globalId }
        else delegate.album(globalId)

    override suspend fun artist(globalId: GlobalId): Artist? =
        if (globalId.serverId == localServerId) localArtists(local.tracks.value).firstOrNull { it.globalId == globalId }
        else delegate.artist(globalId)

    override suspend fun playlist(globalId: GlobalId): Playlist? =
        if (globalId.serverId == localServerId) null else delegate.playlist(globalId)

    override suspend fun albumTracks(albumGlobalId: GlobalId): List<Track> =
        if (albumGlobalId.serverId == localServerId) {
            local.tracks.value.filter { it.albumId.value == albumGlobalId.remoteId }
        } else {
            delegate.albumTracks(albumGlobalId)
        }

    override suspend fun artistAlbums(artistGlobalId: GlobalId): List<Album> =
        if (artistGlobalId.serverId == localServerId) {
            localAlbums(local.tracks.value).filter { it.artistId.value == artistGlobalId.remoteId }
        } else {
            delegate.artistAlbums(artistGlobalId)
        }

    override suspend fun artistTracks(artistGlobalId: GlobalId): List<Track> =
        if (artistGlobalId.serverId == localServerId) {
            local.tracks.value.filter { it.artistId.value == artistGlobalId.remoteId }
        } else {
            delegate.artistTracks(artistGlobalId)
        }

    override suspend fun playlistTracks(playlistGlobalId: GlobalId): List<Track> =
        if (playlistGlobalId.serverId == localServerId) emptyList() else delegate.playlistTracks(playlistGlobalId)

    override suspend fun search(serverId: ServerId?, query: String, limit: Int): SearchResults {
        val localResult = localSearch(query, limit)
        if (serverId == localServerId) return localResult
        val remote = delegate.search(serverId, query, limit)
        return SearchResults(
            songs = TrackQuality.deduplicatedPreferringQuality(remote.songs + localResult.songs).take(limit),
            albums = (remote.albums + localResult.albums).distinctBy { it.globalId }.take(limit),
            artists = (remote.artists + localResult.artists).distinctBy { it.globalId }.take(limit),
            playlists = remote.playlists.take(limit),
        )
    }

    override suspend fun stats(serverId: ServerId?): LibraryStats {
        val localTracks = local.tracks.value
        val localStats = LibraryStats(
            artistCount = localArtists(localTracks).size,
            albumCount = localAlbums(localTracks).size,
            trackCount = localTracks.size,
            playlistCount = 0,
        )
        if (serverId == localServerId) return localStats
        val remote = delegate.stats(serverId)
        return LibraryStats(
            artistCount = remote.artistCount + localStats.artistCount,
            albumCount = remote.albumCount + localStats.albumCount,
            trackCount = remote.trackCount + localStats.trackCount,
            playlistCount = remote.playlistCount,
        )
    }

    override fun observeFavoriteTracks(serverId: ServerId?): Flow<List<Track>> {
        val localFavorites = local.tracks.map { tracks -> tracks.filter { it.isFavorite } }.distinctUntilChanged()
        if (serverId == localServerId) return localFavorites
        return combine(delegate.observeFavoriteTracks(serverId), localFavorites) { remote, localItems ->
            TrackQuality.deduplicatedPreferringQuality(remote + localItems)
        }
    }

    override suspend fun favoriteTracks(serverId: ServerId?): List<Track> =
        observeFavoriteTracks(serverId).firstSnapshot()

    override suspend fun mostPlayedTracks(serverId: ServerId?, limit: Int): List<Track> {
        val localItems = local.tracks.value
            .map { it to local.playCount(it.globalId) }
            .filter { it.second > 0 }
            .sortedByDescending { it.second }
            .map { it.first }
        if (serverId == localServerId) return localItems.take(limit)
        return TrackQuality.deduplicatedPreferringQuality(delegate.mostPlayedTracks(serverId, limit) + localItems).take(limit)
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

    override suspend fun dislikedIds(serverId: ServerId): Set<GlobalId> =
        if (serverId == localServerId) local.dislikedIds() else delegate.dislikedIds(serverId) + local.dislikedIds()

    override fun observeDislikedIds(serverId: ServerId?): Flow<List<GlobalId>> {
        val localFlow = combine(local.tracks, local.revision) { _, _ -> local.dislikedIds().toList() }
            .distinctUntilChanged()
        if (serverId == localServerId) return localFlow
        return combine(delegate.observeDislikedIds(serverId), localFlow) { remote, localItems ->
            (remote + localItems).distinct()
        }
    }

    override suspend fun isFavorite(globalId: GlobalId): Boolean =
        if (globalId.serverId == localServerId) local.track(globalId)?.isFavorite == true
        else delegate.isFavorite(globalId)

    override suspend fun isFavorite(globalId: GlobalId, kind: FavoriteKind): Boolean =
        if (globalId.serverId == localServerId) kind == FavoriteKind.Track && local.track(globalId)?.isFavorite == true
        else delegate.isFavorite(globalId, kind)

    override suspend fun neverPlayed(serverId: ServerId?, limit: Int): List<Track> {
        val localItems = local.tracks.value.filter { local.playCount(it.globalId) == 0 }
        if (serverId == localServerId) return localItems.take(limit)
        return TrackQuality.deduplicatedPreferringQuality(delegate.neverPlayed(serverId, limit) + localItems).take(limit)
    }

    override suspend fun longUnplayed(serverId: ServerId?, limit: Int): List<Track> {
        val localItems = local.tracks.value.sortedBy { local.lastPlayedMillis(it.globalId) ?: Long.MIN_VALUE }
        if (serverId == localServerId) return localItems.take(limit)
        return TrackQuality.deduplicatedPreferringQuality(delegate.longUnplayed(serverId, limit) + localItems).take(limit)
    }

    override suspend fun recentlyPlayed(serverId: ServerId?, limit: Int): List<Track> {
        val localItems = local.tracks.value
            .mapNotNull { track -> local.lastPlayedMillis(track.globalId)?.let { track to it } }
            .sortedByDescending { it.second }
            .map { it.first }
        if (serverId == localServerId) return localItems.take(limit)
        return TrackQuality.deduplicatedPreferringQuality(delegate.recentlyPlayed(serverId, limit) + localItems).take(limit)
    }

    override suspend fun randomTracks(serverId: ServerId?, limit: Int): List<Track> {
        val localItems = local.tracks.value.shuffled().take(limit)
        if (serverId == localServerId) return localItems
        return TrackQuality.deduplicatedPreferringQuality(delegate.randomTracks(serverId, limit) + localItems)
            .shuffled()
            .take(limit)
    }

    override suspend fun favoriteRandom(serverId: ServerId?, limit: Int): List<Track> {
        val localItems = local.tracks.value.filter { it.isFavorite }.shuffled().take(limit)
        if (serverId == localServerId) return localItems
        return TrackQuality.deduplicatedPreferringQuality(delegate.favoriteRandom(serverId, limit) + localItems)
            .shuffled()
            .take(limit)
    }

    override suspend fun favoriteCount(serverId: ServerId?): Int {
        val localCount = local.tracks.value.count { it.isFavorite }
        return if (serverId == localServerId) localCount else delegate.favoriteCount(serverId) + localCount
    }

    override suspend fun playedTrackCount(serverId: ServerId?): Int {
        val localCount = local.tracks.value.count { local.playCount(it.globalId) > 0 }
        return if (serverId == localServerId) localCount else delegate.playedTrackCount(serverId) + localCount
    }

    override suspend fun genreTracks(serverId: ServerId?, genreName: String): List<Track> {
        val localItems = local.tracks.value.filter { track ->
            track.genres.any { it.equals(genreName, ignoreCase = true) }
        }
        if (serverId == localServerId) return localItems
        return TrackQuality.deduplicatedPreferringQuality(delegate.genreTracks(serverId, genreName) + localItems)
    }

    fun homeChangeSignals(serverId: ServerId?): Flow<Unit> =
        merge(
            if (serverId == localServerId) flowOf(Unit) else delegate.homeChangeSignals(serverId),
            local.revision.map { Unit },
        ).distinctUntilChanged()

    suspend fun mergeGenres(serverId: ServerId, values: List<Genre>) {
        if (serverId != localServerId) delegate.mergeGenres(serverId, values)
    }

    fun evict(serverId: ServerId) {
        if (serverId != localServerId) delegate.evict(serverId)
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

    private fun localGenres(tracks: List<Track>): List<Genre> =
        tracks.flatMap { it.genres }
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .groupingBy { it.lowercase() }
            .eachCount()
            .map { (normalized, count) ->
                val display = tracks.asSequence().flatMap { it.genres.asSequence() }
                    .firstOrNull { it.trim().lowercase() == normalized }
                    ?.trim()
                    ?: normalized
                Genre(display, count, localServerId)
            }
            .sortedBy { it.name.lowercase() }

    private fun mergeGenresForRead(remote: List<Genre>, localItems: List<Genre>): List<Genre> {
        val result = LinkedHashMap<String, Genre>()
        (remote + localItems).forEach { genre ->
            val key = genre.name.trim().lowercase()
            val previous = result[key]
            result[key] = if (previous == null) genre else previous.copy(songCount = previous.songCount + genre.songCount)
        }
        return result.values.toList()
    }

    private suspend fun <T> Flow<List<T>>.firstSnapshot(): List<T> =
        kotlinx.coroutines.flow.first(this)
}
