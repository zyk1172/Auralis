package com.auralis.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/** 播放量合计行（ownerId = artist_gid / album_gid；total = 该艺人/专辑全部曲目 play_count 之和）。 */
data class PlayTotalRow(val ownerId: String, val total: Int)

@Dao
interface ServerDao {
    @Query("SELECT * FROM servers ORDER BY name")
    fun observeAll(): Flow<List<ServerEntity>>

    @Query("SELECT * FROM servers WHERE server_id = :serverId")
    fun observe(serverId: String): Flow<ServerEntity?>

    @Query("SELECT * FROM servers WHERE server_id = :serverId")
    suspend fun get(serverId: String): ServerEntity?

    @Upsert
    suspend fun upsert(entity: ServerEntity)

    @Query("DELETE FROM servers WHERE server_id = :serverId")
    suspend fun delete(serverId: String)
}

@Dao
interface ArtistDao {
    @Query("SELECT * FROM artists WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY name")
    fun observeAll(serverId: String?): Flow<List<ArtistEntity>>

    @Query("SELECT * FROM artists WHERE global_id = :globalId")
    suspend fun get(globalId: String): ArtistEntity?

    @Upsert
    suspend fun upsertAll(entities: List<ArtistEntity>)

    @Query("DELETE FROM artists WHERE server_id = :serverId")
    suspend fun deleteByServer(serverId: String)
}

@Dao
interface AlbumDao {
    @Query("SELECT * FROM albums WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY name")
    fun observeAll(serverId: String?): Flow<List<AlbumEntity>>

    @Query("SELECT * FROM albums WHERE global_id = :globalId")
    suspend fun get(globalId: String): AlbumEntity?

    @Query("SELECT * FROM albums WHERE artist_gid = :artistGid ORDER BY year DESC, name")
    suspend fun byArtist(artistGid: String): List<AlbumEntity>

    @Upsert
    suspend fun upsertAll(entities: List<AlbumEntity>)

    @Query("DELETE FROM albums WHERE server_id = :serverId")
    suspend fun deleteByServer(serverId: String)

    /** 常听专辑：按该专辑曲目的播放次数合计降序。 */
    @Query(
        """
        SELECT a.* FROM albums a
        JOIN tracks t ON t.album_gid = a.global_id
        LEFT JOIN play_history h ON h.global_id = t.global_id
        WHERE (:serverId IS NULL OR a.server_id = :serverId)
        GROUP BY a.global_id
        ORDER BY COALESCE(SUM(h.play_count), 0) DESC, a.name
        LIMIT :limit
        """
    )
    suspend fun topAlbums(serverId: String?, limit: Int): List<AlbumEntity>
}

@Dao
interface TrackDao {
    @Query("SELECT * FROM tracks WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY title")
    fun observeAll(serverId: String?): Flow<List<TrackEntity>>

    @Query("SELECT * FROM tracks WHERE global_id = :globalId")
    suspend fun get(globalId: String): TrackEntity?

    @Query("SELECT * FROM tracks WHERE global_id IN (:globalIds)")
    suspend fun getMany(globalIds: List<String>): List<TrackEntity>

    @Query("SELECT * FROM tracks WHERE album_gid = :albumGid ORDER BY title")
    suspend fun byAlbum(albumGid: String): List<TrackEntity>

    @Query("SELECT * FROM tracks WHERE artist_gid = :artistGid ORDER BY title")
    suspend fun byArtist(artistGid: String): List<TrackEntity>

    @Upsert
    suspend fun upsertAll(entities: List<TrackEntity>)

    @Query("DELETE FROM tracks WHERE server_id = :serverId")
    suspend fun deleteByServer(serverId: String)

    /** 最近添加：以 updated_at（同步时间）近似创建顺序。 */
    @Query("SELECT * FROM tracks WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY updated_at DESC LIMIT :limit")
    suspend fun recentlyAdded(serverId: String?, limit: Int): List<TrackEntity>

    /** 从未播放：play_history 中没有记录。 */
    @Query(
        """
        SELECT * FROM tracks t
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
          AND NOT EXISTS (SELECT 1 FROM play_history h WHERE h.global_id = t.global_id)
        ORDER BY t.title
        LIMIT :limit
        """
    )
    suspend fun neverPlayed(serverId: String?, limit: Int): List<TrackEntity>

    /** 很久没听：有播放记录，按 last_played 升序。 */
    @Query(
        """
        SELECT t.* FROM tracks t
        JOIN play_history h ON h.global_id = t.global_id
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
        ORDER BY h.last_played ASC
        LIMIT :limit
        """
    )
    suspend fun longUnplayed(serverId: String?, limit: Int): List<TrackEntity>

    /** 最近播放。 */
    @Query(
        """
        SELECT t.* FROM tracks t
        JOIN play_history h ON h.global_id = t.global_id
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
        ORDER BY h.last_played DESC
        LIMIT :limit
        """
    )
    suspend fun recentlyPlayed(serverId: String?, limit: Int): List<TrackEntity>

    /** 最常听。 */
    @Query(
        """
        SELECT t.* FROM tracks t
        JOIN play_history h ON h.global_id = t.global_id
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
        ORDER BY h.play_count DESC, h.last_played DESC
        LIMIT :limit
        """
    )
    suspend fun mostPlayed(serverId: String?, limit: Int): List<TrackEntity>

    @Query("SELECT * FROM tracks WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY RANDOM() LIMIT :limit")
    suspend fun random(serverId: String?, limit: Int): List<TrackEntity>

    /** 收藏里随便听。 */
    @Query(
        """
        SELECT t.* FROM tracks t
        JOIN favorites f ON f.global_id = t.global_id AND f.kind = 'Track' AND f.value = 1
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
        ORDER BY RANDOM()
        LIMIT :limit
        """
    )
    suspend fun favoriteRandom(serverId: String?, limit: Int): List<TrackEntity>

    @Query("SELECT COUNT(*) FROM tracks WHERE (:serverId IS NULL OR server_id = :serverId)")
    suspend fun count(serverId: String?): Int

    /** 目录版本信号：曲目行变化（同步入库/删除）即发射（Room Flow 语义）。 */
    @Query("SELECT COUNT(*) FROM tracks WHERE (:serverId IS NULL OR server_id = :serverId)")
    fun observeCount(serverId: String?): Flow<Int>

    /** 已下载曲目（downloads.state = 'Downloaded' 的本地完整文件），按下载完成先后倒序。 */
    @Query(
        """
        SELECT t.* FROM tracks t
        JOIN downloads d ON d.global_id = t.global_id
        WHERE (:serverId IS NULL OR d.server_id = :serverId)
          AND d.state = 'Downloaded'
        ORDER BY d.updated_at DESC
        LIMIT :limit
        """
    )
    suspend fun downloadedTracks(serverId: String?, limit: Int): List<TrackEntity>

    /** 近 N 毫秒内同步入库的曲目（首页「最近添加」30 天窗口用；updated_at ≈ 入库时间）。 */
    @Query(
        """
        SELECT * FROM tracks
        WHERE (:serverId IS NULL OR server_id = :serverId)
          AND updated_at >= :sinceMillis
        ORDER BY updated_at DESC
        LIMIT :limit
        """
    )
    suspend fun recentlyAddedSince(serverId: String?, sinceMillis: Long, limit: Int): List<TrackEntity>

    /** 艺人播放量合计（首页「常听艺术家」：真实聚合，杜绝内存里 distinct 后瞎猜）。 */
    @Query(
        """
        SELECT t.artist_gid AS ownerId, COALESCE(SUM(h.play_count), 0) AS total
        FROM tracks t
        JOIN play_history h ON h.global_id = t.global_id
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
          AND t.artist_gid IS NOT NULL
        GROUP BY t.artist_gid
        ORDER BY total DESC, t.artist_gid
        LIMIT :limit
        """
    )
    suspend fun artistPlayTotals(serverId: String?, limit: Int): List<PlayTotalRow>

    /** 专辑播放量合计（首页「常听专辑」）。 */
    @Query(
        """
        SELECT t.album_gid AS ownerId, COALESCE(SUM(h.play_count), 0) AS total
        FROM tracks t
        JOIN play_history h ON h.global_id = t.global_id
        WHERE (:serverId IS NULL OR t.server_id = :serverId)
          AND t.album_gid IS NOT NULL
        GROUP BY t.album_gid
        ORDER BY total DESC, t.album_gid
        LIMIT :limit
        """
    )
    suspend fun albumPlayTotals(serverId: String?, limit: Int): List<PlayTotalRow>

    // ---- FTS ----

    @Query(
        """
        SELECT t.* FROM tracks_fts f
        JOIN tracks t ON t.global_id = f.global_id
        WHERE tracks_fts MATCH :match
          AND (:serverId IS NULL OR t.server_id = :serverId)
        LIMIT :limit
        """
    )
    suspend fun searchFts(match: String, serverId: String?, limit: Int): List<TrackEntity>
}

@Dao
interface TrackFtsDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(entities: List<TrackFtsEntity>)

    @Query("DELETE FROM tracks_fts WHERE global_id IN (:globalIds)")
    suspend fun delete(globalIds: List<String>)

    @Query("DELETE FROM tracks_fts")
    suspend fun clear()

    /** 仅取某服务器当前曲目的 FTS 行（多服务器清理用，避免 DELETE 全表）。 */
    @Query(
        """
        SELECT global_id FROM tracks_fts
        WHERE global_id IN (SELECT global_id FROM tracks WHERE server_id = :serverId)
        """
    )
    suspend fun idsForServer(serverId: String): List<String>
}

@Dao
interface GenreDao {
    @Query("SELECT * FROM genres WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY song_count DESC, name")
    fun observeAll(serverId: String?): Flow<List<GenreEntity>>

    @Upsert
    suspend fun upsertAll(entities: List<GenreEntity>)

    @Query("DELETE FROM genres WHERE server_id = :serverId")
    suspend fun deleteByServer(serverId: String)
}

@Dao
interface PlaylistDao {
    @Query("SELECT * FROM playlists WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY name")
    fun observeAll(serverId: String?): Flow<List<PlaylistEntity>>

    @Query("SELECT * FROM playlists WHERE global_id = :globalId")
    suspend fun get(globalId: String): PlaylistEntity?

    @Upsert
    suspend fun upsertAll(entities: List<PlaylistEntity>)

    @Query("DELETE FROM playlists WHERE global_id = :globalId")
    suspend fun delete(globalId: String)

    @Query("DELETE FROM playlists WHERE server_id = :serverId")
    suspend fun deleteByServer(serverId: String)

    /** 删除某服务器的全部歌单曲目关联（playlist_tracks 无 server_id 列，需经 playlists 反查）。 */
    @Query(
        """
        DELETE FROM playlist_tracks WHERE playlist_gid IN
        (SELECT global_id FROM playlists WHERE server_id = :serverId)
        """
    )
    suspend fun deleteTracksByServer(serverId: String)

    @Query("SELECT COUNT(*) FROM playlists WHERE (:serverId IS NULL OR server_id = :serverId)")
    suspend fun count(serverId: String?): Int

    /** 歌单数量变化信号（首页「歌单」快捷入口 / 资料库统计）。 */
    @Query("SELECT COUNT(*) FROM playlists WHERE (:serverId IS NULL OR server_id = :serverId)")
    fun observeCount(serverId: String?): Flow<Int>

    @Query("SELECT * FROM playlist_tracks WHERE playlist_gid = :playlistGid ORDER BY position")
    suspend fun tracks(playlistGid: String): List<PlaylistTrackEntity>

    @Transaction
    open suspend fun replaceTracks(playlistGid: String, trackGids: List<String>) {
        deleteTracks(playlistGid)
        insertTracks(trackGids.mapIndexed { index, gid -> PlaylistTrackEntity(playlistGid, index, gid) })
    }

    @Query("DELETE FROM playlist_tracks WHERE playlist_gid = :playlistGid")
    suspend fun deleteTracks(playlistGid: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertTracks(entities: List<PlaylistTrackEntity>)
}

@Dao
interface AnnotationDao {
    @Query("SELECT value FROM favorites WHERE global_id = :globalId AND kind = :kind")
    suspend fun isFavorite(globalId: String, kind: String): Boolean?

    @Query("SELECT global_id FROM favorites WHERE kind = 'Track' AND value = 1 AND (:serverId IS NULL OR server_id = :serverId)")
    suspend fun favoriteTrackIds(serverId: String?): List<String>

    /** 收藏的歌曲总数（首页「收藏」快捷入口徽标）。 */
    @Query(
        """
        SELECT COUNT(*) FROM favorites
        WHERE kind = 'Track' AND value = 1
          AND (:serverId IS NULL OR server_id = :serverId)
        """
    )
    suspend fun favoriteTrackCount(serverId: String?): Int

    /** 播放过的曲目总数（首页「最常听」快捷入口徽标）。 */
    @Query(
        """
        SELECT COUNT(*) FROM (
            SELECT DISTINCT h.global_id FROM play_history h
            WHERE (:serverId IS NULL OR h.server_id = :serverId)
              AND h.play_count > 0
        )
        """
    )
    suspend fun playedTrackCount(serverId: String?): Int

    /** 收藏数量变化信号（首页「收藏」快捷入口自动刷新）。 */
    @Query(
        """
        SELECT COUNT(*) FROM favorites
        WHERE kind = 'Track' AND value = 1
          AND (:serverId IS NULL OR server_id = :serverId)
        """
    )
    fun observeFavoriteTrackCount(serverId: String?): Flow<Int>

    /** 播放记录变化信号（首页最近播放/最常听/常听艺人专辑自动刷新）。 */
    @Query(
        """
        SELECT COUNT(*) FROM play_history
        WHERE (:serverId IS NULL OR server_id = :serverId) AND play_count > 0
        """
    )
    fun observePlayedTrackCount(serverId: String?): Flow<Int>

    @Upsert
    suspend fun upsertFavorite(entity: FavoriteEntity)

    @Upsert
    suspend fun upsertFavorites(entities: List<FavoriteEntity>)

    @Query("DELETE FROM favorites WHERE global_id = :globalId AND kind = :kind")
    suspend fun deleteFavorite(globalId: String, kind: String)

    @Query("DELETE FROM favorites WHERE server_id = :serverId AND kind = :kind")
    suspend fun deleteFavoritesByServerAndKind(serverId: String, kind: String)

    @Query("DELETE FROM favorites WHERE server_id = :serverId")
    suspend fun deleteFavoritesByServer(serverId: String)

    @Upsert
    suspend fun upsertRating(entity: RatingEntity)

    @Query("SELECT value FROM ratings WHERE global_id = :globalId")
    suspend fun rating(globalId: String): Int?

    @Query("DELETE FROM ratings WHERE server_id = :serverId")
    suspend fun deleteRatingsByServer(serverId: String)

    @Query("SELECT * FROM play_history WHERE global_id = :globalId")
    suspend fun history(globalId: String): PlayHistoryEntity?

    @Upsert
    suspend fun upsertHistory(entity: PlayHistoryEntity)

    /** 自然播完：只翻 completed 标记，不再叠加 playCount（避免重复计数）。 */
    @Query("UPDATE play_history SET completed = 1 WHERE global_id = :globalId")
    suspend fun markCompleted(globalId: String)

    @Query("DELETE FROM play_history WHERE server_id = :serverId")
    suspend fun deleteHistoryByServer(serverId: String)

    @Upsert
    suspend fun upsertDislike(entity: DislikedTrackEntity)

    @Query("DELETE FROM disliked_tracks WHERE global_id = :globalId")
    suspend fun deleteDislike(globalId: String)

    @Query("DELETE FROM disliked_tracks WHERE server_id = :serverId")
    suspend fun deleteDislikesByServer(serverId: String)

    @Query("SELECT * FROM lyrics WHERE global_id = :globalId")
    suspend fun lyric(globalId: String): LyricEntity?

    @Upsert
    suspend fun upsertLyric(entity: LyricEntity)

    @Query("DELETE FROM lyrics WHERE server_id = :serverId")
    suspend fun deleteLyricsByServer(serverId: String)

    /** 歌词缓存总行数（设置页「数据与备份」统计用）。 */
    @Query("SELECT COUNT(*) FROM lyrics")
    suspend fun lyricCount(): Int

    /** 清空全部歌词缓存（对齐 Swift `clearLyricsCache`；歌词按需重新从服务器加载）。 */
    @Query("DELETE FROM lyrics")
    suspend fun clearAllLyrics()
}

@Dao
interface DownloadDao {
    @Query("SELECT * FROM downloads WHERE global_id = :globalId")
    fun observe(globalId: String): Flow<DownloadEntity?>

    @Query("SELECT * FROM downloads WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY updated_at DESC")
    fun observeAll(serverId: String?): Flow<List<DownloadEntity>>

    /** 已下载完成数量变化信号（首页「下载」模块自动刷新）。 */
    @Query(
        """
        SELECT COUNT(*) FROM downloads
        WHERE (:serverId IS NULL OR server_id = :serverId) AND state = 'Downloaded'
        """
    )
    fun observeDownloadedCount(serverId: String?): Flow<Int>

    @Query("SELECT * FROM downloads WHERE global_id = :globalId")
    suspend fun get(globalId: String): DownloadEntity?

    @Query("SELECT * FROM downloads")
    suspend fun all(): List<DownloadEntity>

    @Upsert
    suspend fun upsert(entity: DownloadEntity)

    @Query("DELETE FROM downloads WHERE global_id = :globalId")
    suspend fun delete(globalId: String)

    @Query("DELETE FROM downloads WHERE server_id = :serverId")
    suspend fun deleteByServer(serverId: String)
}

@Dao
interface SyncDao {
    @Upsert
    suspend fun upsertSession(entity: SyncSessionEntity)

    @Query("SELECT * FROM sync_sessions WHERE server_id = :serverId")
    suspend fun session(serverId: String): SyncSessionEntity?

    @Query("DELETE FROM sync_sessions WHERE server_id = :serverId")
    suspend fun deleteSession(serverId: String)

    @Query("DELETE FROM sync_checkpoints WHERE server_id = :serverId")
    suspend fun deleteCheckpointsByServer(serverId: String)

    @Query(
        """
        DELETE FROM sync_staged_tracks WHERE session_id IN
        (SELECT session_id FROM sync_sessions WHERE server_id = :serverId)
        """
    )
    suspend fun deleteStagedByServer(serverId: String)

    @Upsert
    suspend fun upsertCheckpoint(entity: SyncCheckpointEntity)

    @Query("SELECT * FROM sync_checkpoints WHERE session_id = :sessionId AND section = :section")
    suspend fun checkpoint(sessionId: String, section: String): SyncCheckpointEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun stageTracks(entities: List<SyncStagedTrackEntity>)

    @Query("SELECT * FROM sync_staged_tracks WHERE session_id = :sessionId ORDER BY rowid")
    suspend fun stagedTracks(sessionId: String): List<SyncStagedTrackEntity>

    @Query("DELETE FROM sync_staged_tracks WHERE session_id = :sessionId")
    suspend fun discardStaged(sessionId: String)

    @Upsert
    suspend fun upsertMeta(entity: SyncMetaEntity)

    @Query("SELECT * FROM sync_meta WHERE server_id = :serverId")
    suspend fun meta(serverId: String): SyncMetaEntity?

    @Query("DELETE FROM sync_meta WHERE server_id = :serverId")
    suspend fun deleteMetaByServer(serverId: String)
}
