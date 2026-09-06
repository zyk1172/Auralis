package com.auralis.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

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

    @Query("SELECT COUNT(*) FROM playlists WHERE (:serverId IS NULL OR server_id = :serverId)")
    suspend fun count(serverId: String?): Int

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

    @Upsert
    suspend fun upsertFavorite(entity: FavoriteEntity)

    @Query("DELETE FROM favorites WHERE global_id = :globalId AND kind = :kind")
    suspend fun deleteFavorite(globalId: String, kind: String)

    @Upsert
    suspend fun upsertRating(entity: RatingEntity)

    @Query("SELECT value FROM ratings WHERE global_id = :globalId")
    suspend fun rating(globalId: String): Int?

    @Query("SELECT * FROM play_history WHERE global_id = :globalId")
    suspend fun history(globalId: String): PlayHistoryEntity?

    @Upsert
    suspend fun upsertHistory(entity: PlayHistoryEntity)

    @Upsert
    suspend fun upsertDislike(entity: DislikedTrackEntity)

    @Query("DELETE FROM disliked_tracks WHERE global_id = :globalId")
    suspend fun deleteDislike(globalId: String)

    @Query("SELECT * FROM lyrics WHERE global_id = :globalId")
    suspend fun lyric(globalId: String): LyricEntity?

    @Upsert
    suspend fun upsertLyric(entity: LyricEntity)
}

@Dao
interface DownloadDao {
    @Query("SELECT * FROM downloads WHERE global_id = :globalId")
    fun observe(globalId: String): Flow<DownloadEntity?>

    @Query("SELECT * FROM downloads WHERE (:serverId IS NULL OR server_id = :serverId) ORDER BY updated_at DESC")
    fun observeAll(serverId: String?): Flow<List<DownloadEntity>>

    @Query("SELECT * FROM downloads WHERE global_id = :globalId")
    suspend fun get(globalId: String): DownloadEntity?

    @Query("SELECT * FROM downloads")
    suspend fun all(): List<DownloadEntity>

    @Upsert
    suspend fun upsert(entity: DownloadEntity)

    @Query("DELETE FROM downloads WHERE global_id = :globalId")
    suspend fun delete(globalId: String)
}

@Dao
interface SyncDao {
    @Upsert
    suspend fun upsertSession(entity: SyncSessionEntity)

    @Query("SELECT * FROM sync_sessions WHERE server_id = :serverId")
    suspend fun session(serverId: String): SyncSessionEntity?

    @Query("DELETE FROM sync_sessions WHERE server_id = :serverId")
    suspend fun deleteSession(serverId: String)

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
}
