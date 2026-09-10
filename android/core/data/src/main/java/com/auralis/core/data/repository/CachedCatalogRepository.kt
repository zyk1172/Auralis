// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.repository

import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.CatalogRepository
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.Genre
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Process-lifetime decoded metadata cache in front of the Room catalog.
 *
 * Room remains the only source of truth. The expensive part for a large music library is repeatedly
 * collecting a cold DAO Flow and decoding every JSON payload into thousands of domain objects each
 * time a Compose destination is disposed/re-entered. Every observed catalog family therefore owns
 * one replaying hot stream per server. The first collection performs the Room decode; later screens
 * receive the latest immutable List immediately and only pay again when Room actually invalidates
 * that query.
 *
 * Cache jobs are explicit and cancellable. Deleting a server evicts/cancels all of its collectors,
 * avoiding an unbounded graveyard of server-scoped Room observers. Artwork bytes are intentionally
 * not retained here; Coil continues to own image memory/disk policy independently.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CachedCatalogRepository(
    private val delegate: RoomCatalogRepository,
    private val scope: CoroutineScope,
) : CatalogRepository by delegate, DownloadRepository by delegate {

    private data class CachedList<T>(
        val flow: SharedFlow<List<T>>,
        val job: Job,
    )

    private val artists = ConcurrentHashMap<String, CachedList<Artist>>()
    private val albums = ConcurrentHashMap<String, CachedList<Album>>()
    private val tracks = ConcurrentHashMap<String, CachedList<Track>>()
    private val genres = ConcurrentHashMap<String, CachedList<Genre>>()
    private val playlists = ConcurrentHashMap<String, CachedList<Playlist>>()
    private val favorites = ConcurrentHashMap<String, CachedList<Track>>()

    override fun observeArtists(serverId: ServerId?): Flow<List<Artist>> =
        cached(artists, serverId) { delegate.observeArtists(serverId) }

    override fun observeAlbums(serverId: ServerId?): Flow<List<Album>> =
        cached(albums, serverId) { delegate.observeAlbums(serverId) }

    override fun observeTracks(serverId: ServerId?): Flow<List<Track>> =
        cached(tracks, serverId) { delegate.observeTracks(serverId) }

    override fun observeGenres(serverId: ServerId?): Flow<List<Genre>> =
        cached(genres, serverId) { delegate.observeGenres(serverId) }

    override fun observePlaylists(serverId: ServerId?): Flow<List<Playlist>> =
        cached(playlists, serverId) { delegate.observePlaylists(serverId) }

    override fun observeFavoriteTracks(serverId: ServerId?): Flow<List<Track>> =
        cached(favorites, serverId) { delegate.observeFavoriteTracks(serverId) }

    /** Concrete helper retained for Library's explicit remote genre refresh. */
    suspend fun mergeGenres(serverId: ServerId, values: List<Genre>) {
        delegate.mergeGenres(serverId, values)
    }

    /** Cancel and forget all replaying collectors associated with a removed server. */
    fun evict(serverId: ServerId) {
        val key = key(serverId)
        cancel(artists.remove(key))
        cancel(albums.remove(key))
        cancel(tracks.remove(key))
        cancel(genres.remove(key))
        cancel(playlists.remove(key))
        cancel(favorites.remove(key))

        // Any all-server observer also contains the removed server and must be rebuilt lazily.
        cancel(artists.remove(ALL_SERVERS))
        cancel(albums.remove(ALL_SERVERS))
        cancel(tracks.remove(ALL_SERVERS))
        cancel(genres.remove(ALL_SERVERS))
        cancel(playlists.remove(ALL_SERVERS))
        cancel(favorites.remove(ALL_SERVERS))
    }

    private fun <T> cached(
        cache: ConcurrentHashMap<String, CachedList<T>>,
        serverId: ServerId?,
        upstream: () -> Flow<List<T>>,
    ): Flow<List<T>> {
        val key = key(serverId)
        return cache.computeIfAbsent(key) {
            val replay = MutableSharedFlow<List<T>>(replay = 1)
            val job = scope.launch {
                upstream()
                    .distinctUntilChanged()
                    .collect { snapshot ->
                        // Domain models/lists are treated as immutable snapshots. Replaying this
                        // exact list avoids thousands of unnecessary object allocations on re-entry.
                        replay.emit(snapshot)
                    }
            }
            CachedList(replay, job)
        }.flow
    }

    private fun cancel(entry: CachedList<*>?) {
        entry?.job?.cancel()
    }

    private fun key(serverId: ServerId?): String = serverId?.value ?: ALL_SERVERS

    private companion object {
        const val ALL_SERVERS = "<all-servers>"
    }
}
