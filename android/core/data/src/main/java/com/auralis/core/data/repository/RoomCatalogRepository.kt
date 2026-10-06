// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import com.auralis.core.domain.SearchResults
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
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

    /**
     * 目录读取的执行上下文。
     *
     * Room 的 suspend DAO 只把 SQL 段放到自己的 query executor；**返回之后的**
     * `map { decode<T>(payload) }`、全表 `filter`、`sortedBy` 都在**调用者上下文**执行。
     * 调用者常常是 Compose（`collectAsState` 在 Main 收集）或 `LaunchedEffect`，
     * 因此万级曲库下这些「看起来只是 map」的代码会直接把主线程阻塞成百上千毫秒。
     *
     * 约定：本类所有「可能读取多行并逐行 JSON 解码」的读取路径都必须显式切到
     * [CatalogDispatcher]；只有单行点查与 COUNT 允许留在调用者上下文。
     */
    private suspend fun <T> onCatalogDispatcher(block: suspend () -> T): T =
        withContext(CatalogDispatcher) { block() }

    /**
     * `IN (...)` 分批读取。
     *
     * Room 会把集合展开成等量的绑定变量，超过 SQLite 上限（旧版本 999）会直接抛
     * `SQLiteException: too many SQL variables`。收藏/歌单/快照提交都可能超过该上限，
     * 所以读写两侧统一走分块。
     */
    private suspend fun trackEntitiesByIds(globalIds: List<String>): Map<String, TrackEntity> {
        if (globalIds.isEmpty()) return emptyMap()
        if (globalIds.size <= TRACK_ID_CHUNK) {
            return trackDao.getMany(globalIds).associateBy { it.globalId }
        }
        val merged = LinkedHashMap<String, TrackEntity>(globalIds.size)
        globalIds.chunked(TRACK_ID_CHUNK).forEach { chunk ->
            trackDao.getMany(chunk).forEach { merged[it.globalId] = it }
        }
        return merged
    }

    private suspend fun artistEntitiesByIds(globalIds: List<String>): Map<String, ArtistEntity> {
        if (globalIds.isEmpty()) return emptyMap()
        if (globalIds.size <= TRACK_ID_CHUNK) {
            return artistDao.getMany(globalIds).associateBy { it.globalId }
        }
        val merged = LinkedHashMap<String, ArtistEntity>(globalIds.size)
        globalIds.chunked(TRACK_ID_CHUNK).forEach { chunk ->
            artistDao.getMany(chunk).forEach { merged[it.globalId] = it }
        }
        return merged
    }

    private suspend fun albumEntitiesByIds(globalIds: List<String>): Map<String, AlbumEntity> {
        if (globalIds.isEmpty()) return emptyMap()
        if (globalIds.size <= TRACK_ID_CHUNK) {
            return albumDao.getMany(globalIds).associateBy { it.globalId }
        }
        val merged = LinkedHashMap<String, AlbumEntity>(globalIds.size)
        globalIds.chunked(TRACK_ID_CHUNK).forEach { chunk ->
            albumDao.getMany(chunk).forEach { merged[it.globalId] = it }
        }
        return merged
    }

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
        artistDao.observeAll(serverId?.value)
            .map { it.map { e -> decode<Artist>(e.payload) } }
            .flowOn(CatalogDispatcher)

    override fun observeAlbums(serverId: ServerId?) =
        albumDao.observeAll(serverId?.value)
            .map { it.map { e -> decode<Album>(e.payload) } }
            .flowOn(CatalogDispatcher)

    override fun observeTracks(serverId: ServerId?) =
        trackDao.observeAll(serverId?.value)
            .map { it.map { e -> decode<Track>(e.payload) } }
            .flowOn(CatalogDispatcher)

    override fun observeGenres(serverId: ServerId?) =
        genreDao.observeAll(serverId?.value)
            .map { it.map { e -> decode<Genre>(e.payload) } }
            .flowOn(CatalogDispatcher)

    override fun observePlaylists(serverId: ServerId?) =
        playlistDao.observeAll(serverId?.value)
            .map { it.map { e -> decode<Playlist>(e.payload) } }
            .flowOn(CatalogDispatcher)

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
        onCatalogDispatcher { trackDao.byAlbum(albumGlobalId.serialized).map { decode<Track>(it.payload) } }

    override suspend fun artistAlbums(artistGlobalId: GlobalId) =
        onCatalogDispatcher { albumDao.byArtist(artistGlobalId.serialized).map { decode<Album>(it.payload) } }

    override suspend fun artistTracks(artistGlobalId: GlobalId) =
        onCatalogDispatcher { trackDao.byArtist(artistGlobalId.serialized).map { decode<Track>(it.payload) } }

    override suspend fun playlistTracks(playlistGlobalId: GlobalId): List<Track> =
        onCatalogDispatcher {
            val trackGids = playlistDao.tracks(playlistGlobalId.serialized).map { it.trackGid }
            if (trackGids.isEmpty()) return@onCatalogDispatcher emptyList()
            val byId = trackEntitiesByIds(trackGids)
            trackGids.mapNotNull { byId[it]?.let { e -> decode<Track>(e.payload) } }
        }

    // -------------------------------------------------------------- derived

    override suspend fun favoriteTracks(serverId: ServerId?): List<Track> =
        onCatalogDispatcher { resolveTrackGids(annotationDao.favoriteTrackIds(serverId?.value)) }

    override suspend fun mostPlayedTracks(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.mostPlayed(serverId?.value, limit).map { decode<Track>(it.payload) } }

    override suspend fun search(serverId: ServerId?, query: String, limit: Int): SearchResults {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return SearchResults()
        // 搜索每敲一个字都会走一次：全表读 + 逐行解码必须在后台，否则直接阻塞输入。
        return onCatalogDispatcher {
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
            SearchResults(songs, albums, artists, playlists)
        }
    }

    /**
     * 资料库四项统计。
     *
     * 历史实现把 `artists`/`albums` **全表读进内存再取 `.size`**，只为拿两个计数。改成
     * SQL `COUNT(*)` 后，即使十万级曲库也只是一次索引扫描，不再产生任何解码与列表分配。
     */
    override suspend fun stats(serverId: ServerId?): LibraryStats = LibraryStats(
        artistCount = artistDao.count(serverId?.value),
        albumCount = albumDao.count(serverId?.value),
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

    override suspend fun isDisliked(globalId: GlobalId): Boolean =
        annotationDao.isDisliked(globalId.serialized)

    override suspend fun dislikedIds(serverId: ServerId): Set<GlobalId> =
        onCatalogDispatcher {
            annotationDao.dislikedIds(serverId.value).mapNotNullTo(mutableSetOf()) { raw ->
                runCatching { GlobalId.parse(raw) }.getOrNull()
            }
        }

    override fun observeDislikedIds(serverId: ServerId?): Flow<List<GlobalId>> =
        annotationDao.observeDislikedIds(serverId?.value).map { list ->
            list.mapNotNull { raw -> runCatching { GlobalId.parse(raw) }.getOrNull() }
        }.flowOn(CatalogDispatcher)

    override suspend fun isFavorite(globalId: GlobalId): Boolean =
        isFavorite(globalId, FavoriteKind.Track)

    override suspend fun isFavorite(globalId: GlobalId, kind: FavoriteKind): Boolean =
        annotationDao.isFavorite(globalId.serialized, kind.name) ?: false

    override suspend fun neverPlayed(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.neverPlayed(serverId?.value, limit).map { decode<Track>(it.payload) } }

    override suspend fun longUnplayed(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.longUnplayed(serverId?.value, limit).map { decode<Track>(it.payload) } }

    override suspend fun recentlyAdded(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.recentlyAdded(serverId?.value, limit).map { decode<Track>(it.payload) } }

    override suspend fun recentlyPlayed(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.recentlyPlayed(serverId?.value, limit).map { decode<Track>(it.payload) } }

    override suspend fun randomTracks(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.random(serverId?.value, limit).map { decode<Track>(it.payload) } }

    override suspend fun favoriteRandom(serverId: ServerId?, limit: Int) =
        onCatalogDispatcher { trackDao.favoriteRandom(serverId?.value, limit).map { decode<Track>(it.payload) } }

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
        onCatalogDispatcher {
            trackDao.downloadedTracks(serverId?.value, limit).map { decode<Track>(it.payload) }
        }

    /** 近 [days] 天内同步入库的曲目（首页「最近添加」30 天窗口）。 */
    override suspend fun recentlyAddedWithin(
        serverId: ServerId?,
        days: Int,
        limit: Int,
    ): List<Track> = onCatalogDispatcher {
        trackDao.recentlyAddedSince(
            serverId?.value,
            sinceMillis = System.currentTimeMillis() - days * 86_400_000L,
            limit = limit,
        ).map { decode<Track>(it.payload) }
    }

    /**
     * 常听艺术家：按艺人名下全部曲目播放量真实聚合降序（对齐 Apple
     * `HomeSnapshotBuilder` 的 artistTotals），返回 (艺人, 播放量) 对。
     *
     * 历史实现是「聚合结果里每一行各发一次 `artistDao.get`」的 N+1 查询；改为一次分批
     * `IN` 批量取回后再解码，避免长列表把 SQLite 往返放大成 O(艺人数量)。
     */
    override suspend fun homeTopArtists(serverId: ServerId?, limit: Int): List<Pair<Artist, Int>> =
        onCatalogDispatcher {
            val rows = trackDao.artistPlayTotals(serverId?.value, limit)
            if (rows.isEmpty()) return@onCatalogDispatcher emptyList()
            val byId = artistEntitiesByIds(rows.map { it.ownerId })
            rows.mapNotNull { row ->
                byId[row.ownerId]?.let { decode<Artist>(it.payload) to row.total }
            }
        }

    /** 常听专辑：语义同上，返回 (专辑, 播放量) 对。 */
    override suspend fun homeTopAlbums(serverId: ServerId?, limit: Int): List<Pair<Album, Int>> =
        onCatalogDispatcher {
            val rows = trackDao.albumPlayTotals(serverId?.value, limit)
            if (rows.isEmpty()) return@onCatalogDispatcher emptyList()
            val byId = albumEntitiesByIds(rows.map { it.ownerId })
            rows.mapNotNull { row ->
                byId[row.ownerId]?.let { decode<Album>(it.payload) to row.total }
            }
        }

    // ------------------------------------------------------------ Library（S4）

    /** 收藏曲目：计数信号（收藏表增删即发）驱动重新查询，不监听全表解码。 */
    @kotlinx.coroutines.ExperimentalCoroutinesApi
    override fun observeFavoriteTracks(serverId: ServerId?): Flow<List<Track>> {
        val sid = serverId?.value
        return annotationDao.observeFavoriteTrackCount(sid).flatMapLatest {
            flow { emit(resolveTrackGids(annotationDao.favoriteTrackIds(sid))) }
        }.flowOn(CatalogDispatcher)
    }

    /** 流派筛选：对齐 Swift `tracks(for:)` 的内存过滤语义（track.genres，大小写不敏感）。 */
    override suspend fun genreTracks(serverId: ServerId?, genreName: String): List<Track> {
        if (genreName.isBlank()) return emptyList()
        return onCatalogDispatcher {
            trackDao.observeAll(serverId?.value).first()
                .asSequence()
                .mapNotNull { runCatching { decode<Track>(it.payload) }.getOrNull() }
                .filter { track -> track.genres.any { it.equals(genreName, ignoreCase = true) } }
                .toList()
        }
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
        ) { trackCount, playlistCount, favoriteCount, playedCount, downloadedCount ->
            // 必须先对真实计数快照去重，再映射成 Unit。
            // 旧实现先映射成 Unit 再 distinctUntilChanged()，第一次发射后所有后续变化都会被吞掉。
            listOf(trackCount, playlistCount, favoriteCount, playedCount, downloadedCount)
        }.distinctUntilChanged().map { Unit }
    }

    // -------------------------------------------------------------- downloads

    override fun observe(globalId: GlobalId): Flow<DownloadRecord?> =
        downloadDao.observe(globalId.serialized)
            .map { it?.let(::toDownloadRecord) }
            .flowOn(CatalogDispatcher)

    override fun observeAll(serverId: ServerId?): Flow<List<DownloadRecord>> =
        downloadDao.observeAll(serverId?.value)
            .map { rows -> rows.mapNotNull(::toDownloadRecord) }
            .flowOn(CatalogDispatcher)

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
                // 历史实现是「每个 trackId 一次 trackDao.get」的点查循环：一张千首歌单就是
                // 一千次 SQLite 往返，全部压在同一次事务里，长时间持锁并阻塞其它读写。
                // 改为按批 `IN` 读取后再按原顺序过滤。
                val requested = playlist.trackIds.map { "$sid:${it.value}" }
                if (requested.isEmpty()) {
                    playlistDao.deleteTracks(playlist.globalId.serialized)
                } else {
                    val existing = trackEntitiesByIds(requested)
                    val trackGids = requested.filter { existing.containsKey(it) }
                    playlistDao.deleteTracks(playlist.globalId.serialized)
                    if (trackGids.isNotEmpty()) {
                        playlistDao.insertTracks(
                            trackGids.mapIndexed { index, gid -> PlaylistTrackEntity(playlist.globalId.serialized, index, gid) },
                        )
                    }
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
        onCatalogDispatcher {
            playlistDao.tracks(playlistGlobalId.serialized).map { it.trackGid }
        }

    // ---------------------------------------------------------------- helpers

    private suspend fun resolveTrackGids(gids: List<String>): List<Track> {
        if (gids.isEmpty()) return emptyList()
        val byId = trackEntitiesByIds(gids)
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

    /**
     * `downloads` 行的映射是**容错解析**：`state` 与 `global_id` 都可能来自历史版本或外部
     * 写入。历史实现直接 `GlobalId.parse` / `DownloadStatus.valueOf`，一旦遇到脏数据就在
     * Flow 的 `map` 里抛出，导致整个观察流终止（列表永久不刷新，或冒泡成崩溃）。
     * 现在非法行降级为 `null` 并被过滤掉。
     */
    private fun toDownloadRecord(e: DownloadEntity): DownloadRecord? {
        val globalId = runCatching { GlobalId.parse(e.globalId) }.getOrNull() ?: return null
        val status = runCatching { DownloadStatus.valueOf(e.state) }.getOrNull() ?: return null
        return DownloadRecord(
            globalId = globalId,
            status = status,
            progress = e.progress,
            localPath = e.localPath,
            updatedAtMillis = e.updatedAt,
        )
    }

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

        /** `IN (...)` 读取的批次上限，与写入侧保持同一安全水位。 */
        const val TRACK_ID_CHUNK = 800

        /**
         * 目录解码/排序的执行器。
         *
         * 用 Default 而不是 IO：这里的工作是 CPU 密集的 JSON 反序列化与集合运算，
         * 不是阻塞 IO；IO 池需要留给网络与文件。
         */
        private val CatalogDispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Default
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
