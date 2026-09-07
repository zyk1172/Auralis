package com.auralis.core.data.repository

import com.auralis.core.data.db.AlbumDao
import com.auralis.core.data.db.AlbumEntity
import com.auralis.core.data.db.AnnotationDao
import com.auralis.core.data.db.ArtistDao
import com.auralis.core.data.db.ArtistEntity
import com.auralis.core.data.db.AuralisDatabase
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
import com.auralis.core.data.db.PlaylistTrackEntity
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
import androidx.room.withTransaction
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
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
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
    private val database: AuralisDatabase,
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

    /**
     * 忘记服务器：按 serverId 删除**该服务器**的全部本地痕迹（含收藏/评分/历史/
     * 不喜欢/歌词/下载记录/FTS/歌单关联/同步元数据），单事务提交，绝不影响其它服务器。
     */
    override suspend fun deleteServer(serverId: ServerId) {
        database.withTransaction {
            val sid = serverId.value
            val ftsIds = trackFtsDao.idsForServer(sid)
            serverDao.delete(sid)
            artistDao.deleteByServer(sid)
            albumDao.deleteByServer(sid)
            trackDao.deleteByServer(sid)
            if (ftsIds.isNotEmpty()) trackFtsDao.delete(ftsIds)
            genreDao.deleteByServer(sid)
            playlistDao.deleteTracksByServer(sid)
            playlistDao.deleteByServer(sid)
            annotationDao.deleteFavoritesByServer(sid)
            annotationDao.deleteRatingsByServer(sid)
            annotationDao.deleteHistoryByServer(sid)
            annotationDao.deleteDislikesByServer(sid)
            annotationDao.deleteLyricsByServer(sid)
            downloadDao.deleteByServer(sid)
            syncDao.deleteStagedByServer(sid)
            syncDao.deleteCheckpointsByServer(sid)
            syncDao.deleteSession(sid)
            syncDao.deleteMetaByServer(sid)
        }
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

    override suspend fun artistTracks(artistGlobalId: GlobalId) =
        trackDao.byArtist(artistGlobalId.serialized).map { decode<Track>(it.payload) }

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

    override suspend fun markCompleted(globalId: GlobalId) {
        annotationDao.markCompleted(globalId.serialized)
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
        isFavorite(globalId, FavoriteKind.Track)

    override suspend fun isFavorite(globalId: GlobalId, kind: FavoriteKind): Boolean =
        annotationDao.isFavorite(globalId.serialized, kind.name) ?: false

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

    override suspend fun topArtists(serverId: ServerId?, limit: Int): List<Artist> =
        homeTopArtists(serverId, limit).map { it.first }

    override suspend fun topAlbums(serverId: ServerId?, limit: Int): List<Album> =
        homeTopAlbums(serverId, limit).map { it.first }

    // -------------------------------------------------------------- home 聚合

    /** 收藏歌曲总数（首页「收藏」快捷入口徽标）。 */
    override suspend fun favoriteCount(serverId: ServerId?): Int =
        annotationDao.favoriteTrackCount(serverId?.value)

    /** 播放过的曲目总数（首页「最常听」快捷入口徽标）。 */
    override suspend fun playedTrackCount(serverId: ServerId?): Int =
        annotationDao.playedTrackCount(serverId?.value)

    /** 已下载曲目（下载完整文件，首页「下载」模块）。 */
    override suspend fun downloadedTracks(serverId: ServerId?, limit: Int): List<Track> =
        trackDao.downloadedTracks(serverId?.value, limit).map { decode<Track>(it.payload) }

    /** 近 [days] 天内同步入库的曲目（首页「最近添加」30 天窗口）。 */
    override suspend fun recentlyAddedWithin(
        serverId: ServerId?,
        days: Int,
        limit: Int,
    ): List<Track> = trackDao.recentlyAddedSince(
        serverId?.value,
        sinceMillis = System.currentTimeMillis() - days * 86_400_000L,
        limit = limit,
    ).map { decode<Track>(it.payload) }

    /**
     * 常听艺术家：按艺人名下全部曲目播放量真实聚合降序（对齐 Apple
     * `HomeSnapshotBuilder` 的 artistTotals），返回 (艺人, 播放量) 对。
     */
    override suspend fun homeTopArtists(serverId: ServerId?, limit: Int): List<Pair<Artist, Int>> {
        val rows = trackDao.artistPlayTotals(serverId?.value, limit)
        if (rows.isEmpty()) return emptyList()
        val byGid = rows.mapNotNull { row ->
            artistDao.get(row.ownerId)?.let { decode<Artist>(it.payload) to row.total }
        }
        return byGid
    }

    /** 常听专辑：语义同上，返回 (专辑, 播放量) 对。 */
    override suspend fun homeTopAlbums(serverId: ServerId?, limit: Int): List<Pair<Album, Int>> {
        val rows = trackDao.albumPlayTotals(serverId?.value, limit)
        if (rows.isEmpty()) return emptyList()
        return rows.mapNotNull { row ->
            albumDao.get(row.ownerId)?.let { decode<Album>(it.payload) to row.total }
        }
    }

    // ------------------------------------------------------------ Library（S4）

    /** 收藏曲目：计数信号（收藏表增删即发）驱动重新查询，不监听全表解码。 */
    @kotlinx.coroutines.ExperimentalCoroutinesApi
    override fun observeFavoriteTracks(serverId: ServerId?): Flow<List<Track>> {
        val sid = serverId?.value
        return annotationDao.observeFavoriteTrackCount(sid).flatMapLatest {
            flow { emit(resolveTrackGids(annotationDao.favoriteTrackIds(sid))) }
        }
    }

    /** 流派筛选：对齐 Swift `tracks(for:)` 的内存过滤语义（track.genres，大小写不敏感）。 */
    override suspend fun genreTracks(serverId: ServerId?, genreName: String): List<Track> {
        if (genreName.isBlank()) return emptyList()
        return trackDao.observeAll(serverId?.value).first()
            .asSequence()
            .mapNotNull { runCatching { decode<Track>(it.payload) }.getOrNull() }
            .filter { track -> track.genres.any { it.equals(genreName, ignoreCase = true) } }
            .toList()
    }

    /** 歌单详情落盘：单事务更新歌单头并整体替换其曲目关联。 */
    override suspend fun upsertPlaylist(playlist: Playlist) {
        val sid = playlist.serverId.value
        val now = System.currentTimeMillis()
        database.withTransaction {
            playlistDao.upsertAll(
                listOf(
                    PlaylistEntity(
                        globalId = playlist.globalId.serialized,
                        serverId = sid,
                        remoteId = playlist.id.value,
                        name = playlist.name,
                        isReadOnly = playlist.isReadOnly,
                        modifiedAt = playlist.modifiedAtMillis,
                        payload = json.encodeToString(playlist),
                        updatedAt = now,
                    ),
                ),
            )
            val gids = playlist.trackIds.mapNotNull { tid ->
                trackDao.get("$sid:${tid.value}")?.globalId
            }
            playlistDao.deleteTracks(playlist.globalId.serialized)
            if (gids.isNotEmpty()) {
                playlistDao.insertTracks(
                    gids.mapIndexed { index, gid -> PlaylistTrackEntity(playlist.globalId.serialized, index, gid) },
                )
            }
        }
    }

    /** 删除歌单本地行与曲目关联（单事务；远端删除确认后调用）。 */
    override suspend fun deletePlaylistLocally(globalId: GlobalId) {
        database.withTransaction {
            playlistDao.deleteTracks(globalId.serialized)
            playlistDao.delete(globalId.serialized)
        }
    }

    /**
     * 流派刷新（对齐 Swift `mergeServerGenres`，R15）：只在服务器返回非空时并入，
     * 服务器为空**不**把本地已有流派伪装成「无流派」。genreDao 按 (global_id) upsert，
     * 同名流派（global_id = "server:name.lowercase()"）覆盖 songCount 与 payload。
     */
    suspend fun mergeGenres(serverId: ServerId, genres: List<Genre>) {
        if (genres.isEmpty()) return
        val sid = serverId.value
        val now = System.currentTimeMillis()
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
            },
        )
    }

    /**
     * 首页自动刷新信号：目录 / 歌单 / 收藏 / 播放记录 / 下载完成任一变化即发射。
     * 轻量（只数 COUNT，不解码 payload），供 Home 页在数据变化时重建快照。
     */
    fun homeChangeSignals(serverId: ServerId?): Flow<Unit> {
        val sid = serverId?.value
        return kotlinx.coroutines.flow.combine(
            trackDao.observeCount(sid),
            playlistDao.observeCount(sid),
            annotationDao.observeFavoriteTrackCount(sid),
            annotationDao.observePlayedTrackCount(sid),
            downloadDao.observeDownloadedCount(sid),
        ) { _, _, _, _, _ -> Unit }.distinctUntilChanged()
    }

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

    /**
     * 渐进同步的落盘（对齐 Apple `LibrarySync` 分段提交）。只替换该 session
     * 对应服务器的曲目与 FTS 行——**绝不** `DELETE FROM tracks_fts` 清空别的服务器。
     */
    suspend fun commitTracks(sessionId: String) {
        val staged = syncDao.stagedTracks(sessionId)
        if (staged.isEmpty()) return
        val sid = staged.first().serverId
        database.withTransaction {
            val oldFtsIds = trackFtsDao.idsForServer(sid)
            trackDao.deleteByServer(sid)
            if (oldFtsIds.isNotEmpty()) oldFtsIds.chunked(FTS_DELETE_CHUNK).forEach { trackFtsDao.delete(it) }
            staged.chunked(WRITE_CHUNK).forEach { chunk ->
                trackDao.upsertAll(chunk.map { it.toTrackEntity(json) })
                trackFtsDao.insertAll(chunk.map { it.toFtsEntity() })
            }
            syncDao.discardStaged(sessionId)
        }
    }

    /** 整目录快照提交（首连全量同步用）。单事务：中途任何一步失败，旧目录仍完整。 */
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

        database.withTransaction {
            // 1) 先记下该服务器旧曲目的 FTS 行，删除只命中自己，绝不误删其它服务器索引。
            val oldFtsIds = trackFtsDao.idsForServer(sid)

            // 2) 删除该服务器旧目录。
            artistDao.deleteByServer(sid)
            albumDao.deleteByServer(sid)
            trackDao.deleteByServer(sid)
            if (oldFtsIds.isNotEmpty()) {
                oldFtsIds.chunked(FTS_DELETE_CHUNK).forEach { trackFtsDao.delete(it) }
            }
            genreDao.deleteByServer(sid)
            playlistDao.deleteTracksByServer(sid)
            playlistDao.deleteByServer(sid)

            // 3) 写新目录（同 server 前缀的 globalId 幂等；分批防 SQLite 参数上限）。
            artists.chunked(WRITE_CHUNK).forEach { chunk ->
                artistDao.upsertAll(
                    chunk.map {
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
            }
            albums.chunked(WRITE_CHUNK).forEach { chunk ->
                albumDao.upsertAll(
                    chunk.map {
                        AlbumEntity(
                            globalId = it.globalId.serialized,
                            serverId = sid,
                            remoteId = it.id.value,
                            name = it.title,
                            artistName = it.artistName,
                            artistGid = if (it.artistId.value.isEmpty()) null else "$sid:${it.artistId.value}",
                            year = it.year,
                            genre = it.genre,
                            songCount = it.songCount,
                            payload = json.encodeToString(it),
                            updatedAt = now,
                        )
                    }
                )
            }
            tracks.chunked(WRITE_CHUNK).forEach { chunk ->
                trackDao.upsertAll(
                    chunk.map {
                        TrackEntity(
                            globalId = it.globalId.serialized,
                            serverId = sid,
                            remoteId = it.id.value,
                            title = it.title,
                            artistName = it.artistName,
                            albumTitle = it.albumTitle,
                            albumGid = if (it.albumId.value.isEmpty()) null else "$sid:${it.albumId.value}",
                            artistGid = if (it.artistId.value.isEmpty()) null else "$sid:${it.artistId.value}",
                            duration = it.durationSeconds,
                            year = it.year,
                            payload = json.encodeToString(it),
                            updatedAt = now,
                        )
                    }
                )
            }
            tracks.chunked(WRITE_CHUNK).forEach { chunk ->
                trackFtsDao.insertAll(
                    chunk.map {
                        TrackFtsEntity(
                            globalId = it.globalId.serialized,
                            title = it.title,
                            artistName = it.artistName,
                            albumTitle = it.albumTitle,
                        )
                    }
                )
            }
            genres.chunked(WRITE_CHUNK).forEach { chunk ->
                genreDao.upsertAll(
                    chunk.map {
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
            }
            playlists.chunked(WRITE_CHUNK).forEach { chunk ->
                playlistDao.upsertAll(
                    chunk.map {
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
            }
            // 歌单曲目关联：直接替换（在 withTransaction 内避免嵌套 @Transaction DAO 方法）。
            playlists.forEach { playlist ->
                val trackGids = playlist.trackIds.mapNotNull { tid ->
                    trackDao.get("$sid:${tid.value}")?.globalId
                }
                playlistDao.deleteTracks(playlist.globalId.serialized)
                if (trackGids.isNotEmpty()) {
                    playlistDao.insertTracks(
                        trackGids.mapIndexed { index, gid -> PlaylistTrackEntity(playlist.globalId.serialized, index, gid) },
                    )
                }
            }
        }
    }

    /**
     * 服务器收藏回流（对齐 Apple connect 尾部 starred 处理）：
     * 以 getStarred2 的完整集合为准替换该服务器 Track 收藏，本地“手动取消”之外
     * 的漂移会被远端纠正。单事务。
     */
    suspend fun replaceFavoriteTracks(serverId: ServerId, remoteTrackIds: List<String>) {
        val sid = serverId.value
        database.withTransaction {
            annotationDao.deleteFavoritesByServerAndKind(sid, FavoriteKind.Track.name)
            val now = System.currentTimeMillis()
            remoteTrackIds.chunked(WRITE_CHUNK).forEach { chunk ->
                annotationDao.upsertFavorites(
                    chunk.map { tid ->
                        FavoriteEntity(
                            globalId = "$sid:$tid",
                            serverId = sid,
                            kind = FavoriteKind.Track.name,
                            value = true,
                            updatedAt = now,
                        )
                    }
                )
            }
        }
    }

    /** 歌单曲目关联是否仅用于已入库曲目（帮助判断 playlist 是否需要按需拉详情）。 */
    suspend fun playlistTrackGids(playlistGlobalId: GlobalId): List<String> =
        playlistDao.tracks(playlistGlobalId.serialized).map { it.trackGid }

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

    companion object {
        /** 单批写入行数：低于 SQLite 变量数上限(999)，避免大批量 IN/UPSERT 崩。 */
        const val WRITE_CHUNK = 800
        const val FTS_DELETE_CHUNK = 800
    }
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
