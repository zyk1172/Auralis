package com.auralis.core.data.repository

import com.auralis.core.data.db.AlbumDao
import com.auralis.core.data.db.AlbumEntity
import com.auralis.core.data.db.AnnotationDao
import com.auralis.core.data.db.ArtistDao
import com.auralis.core.data.db.ArtistEntity
import com.auralis.core.data.db.DataJson
import com.auralis.core.data.db.DislikedTrackEntity
import com.auralis.core.data.db.DownloadDao
import com.auralis.core.data.db.DownloadEntity
import com.auralis.core.data.db.FavoriteEntity
import com.auralis.core.data.db.GenreDao
import com.auralis.core.data.db.GenreEntity
import com.auralis.core.data.db.PlayHistoryEntity
import com.auralis.core.data.db.PlaylistDao
import com.auralis.core.data.db.PlaylistEntity
import com.auralis.core.data.db.RatingEntity
import com.auralis.core.data.db.ServerDao
import com.auralis.core.data.db.ServerEntity
import com.auralis.core.data.db.SyncDao
import com.auralis.core.data.db.SyncSessionEntity
import com.auralis.core.data.db.SyncStagedTrackEntity
import com.auralis.core.data.db.TrackDao
import com.auralis.core.data.db.TrackEntity
import com.auralis.core.data.db.TrackFtsDao
import com.auralis.core.data.db.TrackFtsEntity
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.CatalogRepository
import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.Genre
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LibraryStats
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import com.auralis.core.domain.SearchResults
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Room 驱动的本地权威目录。实现 [CatalogRepository] + [DownloadRepository]。
 *
 * 目录写入采用**拉取 → 暂存 → 成功后 commit** 的事务语义（对齐 Apple `LibrarySync`）：
 * 网络同步失败**不会**把原本完整的本地目录截断。
 */
@Suppress("TooManyFunctions")
class RoomCatalogRepository(
    private val serverDao: ServerDao,
    private val artistDao: ArtistDao,
    private val albumDao: AlbumDao,
    private val trackDao: TrackDao,
    private val trackFtsDao: TrackFtsDao,
    private val genreDao: GenreDao,
    private val playlistDao: PlaylistDao,
    private val annotationDao: AnnotationDao,
    private val downloadDao: DownloadDao,
    private val syncDao: SyncDao,
    json: Json = DataJson.json,
) : CatalogRepository, DownloadRepository {

    private val json: Json = json

    // ------------------------------------------------------------- server

    override fun observeServer(serverId: ServerId): Flow<ServerAccount?> =
        serverDao.observe(serverId.value).map { it?.let(::toServerAccount) }

    override suspend fun servers(): List<ServerAccount> =
        serverDao.observeAll().first().map(::toServerAccount)

    override suspend fun upsertServer(account: ServerAccount) {
        serverDao.upsert(
            ServerEntity(
                globalId = account.id.value,
                serverId = account.id.value,
                remoteId = account.id.value,
                name = account.displayName,
                baseUrl = account.baseUrl,
                externalBaseUrl = account.externalBaseUrl,
                username = account.username,
                credentialReference = account.credentialReference,
                updatedAt = System.currentTimeMillis(),
            )
        )
    }

    override suspend fun deleteServer(serverId: ServerId) {
        serverDao.delete(serverId.value)
        artistDao.deleteByServer(serverId.value)
        albumDao.deleteByServer(serverId.value)
        trackDao.deleteByServer(serverId.value)
        genreDao.deleteByServer(serverId.value)
        playlistDao.deleteByServer(serverId.value)
        syncDao.deleteSession(serverId.value)
    }

    // ------------------------------------------------------------ observe

    override fun observeArtists(serverId: ServerId?) =
        artistDao.observeAll(serverId?.value).map { it.map { e -> decode<Artist>(e.payload) } }

    override fun observeAlbums(serverId: ServerId?) =
        albumDao.observeAll(serverId?.value).map { it.map { e -> decode<Album>(e.payload) } }

    override fun observeTracks(serverId: ServerId?) =
        trackDao.observeAll(serverId?.value).map { it.map { e -> decode<Track>(e.payload) } }

    override fun observeGenres(serverId: ServerId?) =
        genreDao.observeAll(serverId?.value).map { it.map { e -> decode<Genre>(e.payload) } }

    override fun observePlaylists(serverId: ServerId?) =
        playlistDao.observeAll(serverId?.value).map { it.map { e -> decode<Playlist>(e.payload) } }

    // -------------------------------------------------------------- getters

    override suspend fun artist(globalId: GlobalId) =
        artistDao.get(globalId.serialized)?.let { decode<Artist>(it.payload) }

    override suspend fun album(globalId: GlobalId) =
        albumDao.get(globalId.serialized)?.let { decode<Album>(it.payload) }

    override suspend fun track(globalId: GlobalId) =
        trackDao.get(globalId.serialized)?.let { decode<Track>(it.payload) }

    override suspend fun playlist(globalId: GlobalId) =
        playlistDao.get(globalId.serialized)?.let { decode<Playlist>(it.payload) }

    override suspend fun albumTracks(albumGlobalId: GlobalId) =
        trackDao.byAlbum(albumGlobalId.serialized).map { decode<Track>(it.payload) }

    override suspend fun artistAlbums(artistGlobalId: GlobalId) =
        albumDao.byArtist(artistGlobalId.serialized).map { decode<Album>(it.payload) }

    override suspend fun playlistTracks(playlistGlobalId: GlobalId): List<Track> {
        val trackGids = playlistDao.tracks(playlistGlobalId.serialized).map { it.trackGid }
        if (trackGids.isEmpty()) return emptyList()
        val byId = trackDao.getMany(trackGids).associateBy { it.globalId }
        return trackGids.mapNotNull { byId[it]?.let { e -> decode<Track>(e.payload) } }
    }

    // -------------------------------------------------------------- derived

    override suspend fun favoriteTracks(serverId: ServerId?): List<Track> =
        resolveTrackGids(annotationDao.favoriteTrackIds(serverId?.value))

    override suspend fun mostPlayedTracks(serverId: ServerId?, limit: Int) =
        trackDao.mostPlayed(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun search(serverId: ServerId?, query: String, limit: Int): SearchResults {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return SearchResults()
        val songs = trackDao.searchFts(toFtsMatch(trimmed), serverId?.value, limit)
            .map { decode<Track>(it.payload) }
        val albums = albumDao.observeAll(serverId?.value).first()
            .filter { it.name.contains(trimmed, ignoreCase = true) }.take(limit)
            .map { decode<Album>(it.payload) }
        val artists = artistDao.observeAll(serverId?.value).first()
            .filter { it.name.contains(trimmed, ignoreCase = true) }.take(limit)
            .map { decode<Artist>(it.payload) }
        val playlists = playlistDao.observeAll(serverId?.value).first()
            .filter { it.name.contains(trimmed, ignoreCase = true) }.take(limit)
            .map { decode<Playlist>(it.payload) }
        return SearchResults(songs, albums, artists, playlists)
    }

    override suspend fun stats(serverId: ServerId?): LibraryStats = LibraryStats(
        artistCount = artistDao.observeAll(serverId?.value).first().size,
        albumCount = albumDao.observeAll(serverId?.value).first().size,
        trackCount = trackDao.count(serverId?.value),
        playlistCount = playlistDao.count(serverId?.value),
    )

    override suspend fun setFavorite(globalId: GlobalId, kind: FavoriteKind, value: Boolean) {
        if (value) {
            annotationDao.upsertFavorite(
                FavoriteEntity(
                    globalId = globalId.serialized,
                    serverId = globalId.serverId.value,
                    kind = kind.name,
                    value = true,
                    updatedAt = System.currentTimeMillis(),
                )
            )
        } else {
            annotationDao.deleteFavorite(globalId.serialized, kind.name)
        }
    }

    override suspend fun setRating(globalId: GlobalId, rating: Int?) {
        if (rating == null || rating <= 0) {
            annotationDao.upsertRating(
                RatingEntity(
                    globalId = globalId.serialized,
                    serverId = globalId.serverId.value,
                    value = rating ?: 0,
                    updatedAt = System.currentTimeMillis(),
                )
            )
        } else {
            annotationDao.upsertRating(
                RatingEntity(
                    globalId = globalId.serialized,
                    serverId = globalId.serverId.value,
                    value = rating,
                    updatedAt = System.currentTimeMillis(),
                )
            )
        }
    }

    override suspend fun recordPlay(globalId: GlobalId, completed: Boolean) {
        val existing = annotationDao.history(globalId.serialized)
        annotationDao.upsertHistory(
            PlayHistoryEntity(
                globalId = globalId.serialized,
                serverId = globalId.serverId.value,
                lastPlayed = System.currentTimeMillis(),
                playCount = (existing?.playCount ?: 0) + 1,
                completed = completed,
            )
        )
    }

    override suspend fun setDisliked(globalId: GlobalId, disliked: Boolean) {
        if (disliked) {
            annotationDao.upsertDislike(
                DislikedTrackEntity(
                    globalId = globalId.serialized,
                    serverId = globalId.serverId.value,
                    createdAt = System.currentTimeMillis(),
                    source = "user",
                )
            )
        } else {
            annotationDao.deleteDislike(globalId.serialized)
        }
    }

    override suspend fun isFavorite(globalId: GlobalId): Boolean =
        annotationDao.isFavorite(globalId.serialized, FavoriteKind.Track.name) ?: false

    override suspend fun neverPlayed(serverId: ServerId?, limit: Int) =
        trackDao.neverPlayed(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun longUnplayed(serverId: ServerId?, limit: Int) =
        trackDao.longUnplayed(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun recentlyAdded(serverId: ServerId?, limit: Int) =
        trackDao.recentlyAdded(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun recentlyPlayed(serverId: ServerId?, limit: Int) =
        trackDao.recentlyPlayed(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun randomTracks(serverId: ServerId?, limit: Int) =
        trackDao.random(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun favoriteRandom(serverId: ServerId?, limit: Int) =
        trackDao.favoriteRandom(serverId?.value, limit).map { decode<Track>(it.payload) }

    override suspend fun topArtists(serverId: ServerId?, limit: Int): List<Artist> {
        val gids = trackDao.mostPlayed(serverId?.value, limit * 4)
            .mapNotNull { it.artistGid }.distinct().take(limit)
        return gids.mapNotNull { artistDao.get(it)?.let { e -> decode<Artist>(e.payload) } }
    }

    override suspend fun topAlbums(serverId: ServerId?, limit: Int) =
        albumDao.topAlbums(serverId?.value, limit).map { decode<Album>(it.payload) }

    // -------------------------------------------------------------- downloads

    override fun observe(globalId: GlobalId): Flow<DownloadRecord?> =
        downloadDao.observe(globalId.serialized).map { it?.let(::toDownloadRecord) }

    override fun observeAll(serverId: ServerId?): Flow<List<DownloadRecord>> =
        downloadDao.observeAll(serverId?.value).map { it.map(::toDownloadRecord) }

    override suspend fun localPath(globalId: GlobalId): String? =
        downloadDao.get(globalId.serialized)?.localPath

    override suspend fun record(record: DownloadRecord) {
        downloadDao.upsert(
            DownloadEntity(
                globalId = record.globalId.serialized,
                serverId = record.globalId.serverId.value,
                state = record.status.name,
                progress = record.progress,
                localPath = record.localPath,
                byteCount = 0,
                updatedAt = if (record.updatedAtMillis == 0L) System.currentTimeMillis() else record.updatedAtMillis,
            )
        )
    }

    override suspend fun remove(globalId: GlobalId) {
        downloadDao.delete(globalId.serialized)
    }

    // ------------------------------------------------------------ sync 写入

    /** 会话由每服务器一个的 UNIQUE 约束保证：同一时间只有一条活动同步。 */
    suspend fun beginSync(serverId: ServerId, mode: String): String {
        val sessionId = java.util.UUID.randomUUID().toString()
        syncDao.upsertSession(
            SyncSessionEntity(
                sessionId = sessionId,
                serverId = serverId.value,
                mode = mode,
                startedAt = System.currentTimeMillis(),
            )
        )
        return sessionId
    }

    suspend fun stageTracks(sessionId: String, tracks: List<Track>) {
        val now = System.currentTimeMillis()
        syncDao.stageTracks(
            tracks.map { track ->
                SyncStagedTrackEntity(
                    sessionId = sessionId,
                    globalId = track.globalId.serialized,
                    serverId = track.serverId.value,
                    remoteId = track.id.value,
                    title = track.title,
                    artistName = track.artistName,
                    albumTitle = track.albumTitle,
                    albumGid = if (track.albumId.value.isEmpty()) null else "${track.serverId.value}:${track.albumId.value}",
                    artistGid = if (track.artistId.value.isEmpty()) null else "${track.serverId.value}:${track.artistId.value}",
                    duration = track.durationSeconds,
                    payload = json.encodeToString(track),
                    updatedAt = now,
                )
            }
        )
    }

    suspend fun commitTracks(sessionId: String) {
        val staged = syncDao.stagedTracks(sessionId)
        if (staged.isEmpty()) return
        val sid = staged.first().serverId
        trackDao.deleteByServer(sid)
        trackFtsDao.clear()
        staged.chunked(500).forEach { chunk ->
            trackDao.upsertAll(chunk.map { it.toTrackEntity(json) })
            trackFtsDao.insertAll(chunk.map { it.toFtsEntity() })
        }
        syncDao.discardStaged(sessionId)
    }

    /** 整目录快照提交（首连全量同步用）。 */
    suspend fun commitCatalogSnapshot(
        serverId: ServerId,
        artists: List<Artist>,
        albums: List<Album>,
        tracks: List<Track>,
        genres: List<Genre>,
        playlists: List<Playlist>,
    ) {
        val now = System.currentTimeMillis()
        val sid = serverId.value
        artistDao.deleteByServer(sid)
        albumDao.deleteByServer(sid)
        trackDao.deleteByServer(sid)
        trackFtsDao.clear()
        genreDao.deleteByServer(sid)
        playlistDao.deleteByServer(sid)

        artistDao.upsertAll(
            artists.map {
                ArtistEntity(
                    globalId = it.globalId.serialized,
                    serverId = sid,
                    remoteId = it.id.value,
                    name = it.name,
                    albumCount = it.albumCount,
                    artworkKey = it.artworkKey,
                    payload = json.encodeToString(it),
                    updatedAt = now,
                )
            }
        )
        albumDao.upsertAll(
            albums.map {
                AlbumEntity(
                    globalId = it.globalId.serialized,
                    serverId = sid,
                    remoteId = it.id.value,
                    name = it.title,
                    artistName = it.artistName,
                    artistGid = if (it.artistId.value.isEmpty()) null else "${sid}:${it.artistId.value}",
                    year = it.year,
                    genre = it.genre,
                    songCount = it.songCount,
                    payload = json.encodeToString(it),
                    updatedAt = now,
                )
            }
        )
        trackDao.upsertAll(
            tracks.map {
                TrackEntity(
                    globalId = it.globalId.serialized,
                    serverId = sid,
                    remoteId = it.id.value,
                    title = it.title,
                    artistName = it.artistName,
                    albumTitle = it.albumTitle,
                    albumGid = if (it.albumId.value.isEmpty()) null else "${sid}:${it.albumId.value}",
                    artistGid = if (it.artistId.value.isEmpty()) null else "${sid}:${it.artistId.value}",
                    duration = it.durationSeconds,
                    year = it.year,
                    payload = json.encodeToString(it),
                    updatedAt = now,
                )
            }
        )
        trackFtsDao.insertAll(
            tracks.map {
                TrackFtsEntity(
                    globalId = it.globalId.serialized,
                    title = it.title,
                    artistName = it.artistName,
                    albumTitle = it.albumTitle,
                )
            }
        )
        genreDao.upsertAll(
            genres.map {
                GenreEntity(
                    globalId = "$sid:${it.id}",
                    serverId = sid,
                    remoteId = it.id,
                    name = it.name,
                    songCount = it.songCount,
                    payload = json.encodeToString(it),
                    updatedAt = now,
                )
            }
        )
        playlistDao.upsertAll(
            playlists.map {
                PlaylistEntity(
                    globalId = it.globalId.serialized,
                    serverId = sid,
                    remoteId = it.id.value,
                    name = it.name,
                    isReadOnly = it.isReadOnly,
                    modifiedAt = it.modifiedAtMillis,
                    payload = json.encodeToString(it),
                    updatedAt = now,
                )
            }
        )
        playlists.forEach { playlist ->
            val trackGids = playlist.trackIds.mapNotNull { tid ->
                trackDao.get("${sid}:${tid.value}")?.globalId
            }
            playlistDao.replaceTracks(playlist.globalId.serialized, trackGids)
        }
    }

    // ---------------------------------------------------------------- helpers

    private suspend fun resolveTrackGids(gids: List<String>): List<Track> {
        if (gids.isEmpty()) return emptyList()
        val byId = trackDao.getMany(gids).associateBy { it.globalId }
        return gids.mapNotNull { byId[it]?.let { e -> decode<Track>(e.payload) } }
    }

    private fun toServerAccount(e: ServerEntity) = ServerAccount(
        id = ServerId(e.serverId),
        displayName = e.name,
        baseUrl = e.baseUrl,
        externalBaseUrl = e.externalBaseUrl,
        username = e.username,
        credentialReference = e.credentialReference,
    )

    private fun toDownloadRecord(e: DownloadEntity) = DownloadRecord(
        globalId = GlobalId.parse(e.globalId),
        status = DownloadStatus.valueOf(e.state),
        progress = e.progress,
        localPath = e.localPath,
        updatedAtMillis = e.updatedAt,
    )

    /** FTS MATCH 表达式：每个词加引号 + 前缀通配。 */
    private fun toFtsMatch(query: String): String = query
        .split(Regex("[\\s，。、；：？！,.;:!?'\"()（）\\[\\]{}<>《》]+"))
        .filter { it.isNotBlank() }
        .joinToString(" AND ") { "\"${it.replace("\"", "\"\"")}\"*" }

    private inline fun <reified T> decode(payload: String): T = json.decodeFromString(payload)
}

private fun SyncStagedTrackEntity.toTrackEntity(json: Json) = TrackEntity(
    globalId = globalId,
    serverId = serverId,
    remoteId = remoteId,
    title = title,
    artistName = artistName,
    albumTitle = albumTitle,
    albumGid = albumGid,
    artistGid = artistGid,
    duration = duration,
    year = null,
    payload = payload,
    updatedAt = updatedAt,
)

private fun SyncStagedTrackEntity.toFtsEntity() = TrackFtsEntity(
    globalId = globalId,
    title = title,
    artistName = artistName,
    albumTitle = albumTitle,
)
