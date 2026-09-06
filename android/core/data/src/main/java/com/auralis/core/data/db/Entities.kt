package com.auralis.core.data.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.FtsOptions
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Room 实体。
 *
 * 设计对齐 Apple `catalog.sqlite`：主键一律是 `global_id = "{serverId}:{remoteId}"`，
 * 实体主表额外保留可索引/可排序的业务列，`payload` 存完整领域对象 JSON。
 *
 * 与 Apple 的**有意差异**：favorites/ratings/play_history/downloads/lyrics 在 Apple 端
 * 没有 server_id 列（只靠 global_id 前缀隔离），Android **全部补上 server_id 并建索引**，
 * 便于按服务器批量清理。记录在 `android/docs/platform-decisions.md`。
 */

@Entity(
    tableName = "servers",
    indices = [Index("server_id")],
)
data class ServerEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "base_url") val baseUrl: String?,
    @ColumnInfo(name = "external_base_url") val externalBaseUrl: String?,
    @ColumnInfo(name = "username") val username: String?,
    @ColumnInfo(name = "credential_reference") val credentialReference: String?,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "artists",
    indices = [Index("server_id")],
)
data class ArtistEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "album_count") val albumCount: Int,
    @ColumnInfo(name = "artwork_key") val artworkKey: String?,
    @ColumnInfo(name = "payload") val payload: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "albums",
    indices = [Index("server_id"), Index("artist_gid")],
)
data class AlbumEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "artist_name") val artistName: String,
    @ColumnInfo(name = "artist_gid") val artistGid: String?,
    @ColumnInfo(name = "year") val year: Int?,
    @ColumnInfo(name = "genre") val genre: String?,
    @ColumnInfo(name = "song_count") val songCount: Int?,
    @ColumnInfo(name = "payload") val payload: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "tracks",
    indices = [Index("server_id"), Index("album_gid"), Index("artist_gid")],
)
data class TrackEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "artist_name") val artistName: String,
    @ColumnInfo(name = "album_title") val albumTitle: String,
    @ColumnInfo(name = "album_gid") val albumGid: String?,
    @ColumnInfo(name = "artist_gid") val artistGid: String?,
    @ColumnInfo(name = "duration") val duration: Double,
    @ColumnInfo(name = "year") val year: Int?,
    @ColumnInfo(name = "payload") val payload: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

/**
 * 曲目全文检索表。使用 unicode61 分词器以兼容中文（simple 分词器会把整段中文当成一个 token）。
 * `global_id` 标记为 notIndexed，只作为回查主键。
 */
@Entity(tableName = "tracks_fts")
@Fts4(tokenizer = FtsOptions.TOKENIZER_UNICODE61, notIndexed = ["global_id"])
data class TrackFtsEntity(
    @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "artist_name") val artistName: String,
    @ColumnInfo(name = "album_title") val albumTitle: String,
)

@Entity(
    tableName = "genres",
    indices = [Index("server_id")],
)
data class GenreEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "song_count") val songCount: Int,
    @ColumnInfo(name = "payload") val payload: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "playlists",
    indices = [Index("server_id")],
)
data class PlaylistEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "is_readonly") val isReadOnly: Boolean,
    @ColumnInfo(name = "modified_at") val modifiedAt: Long?,
    @ColumnInfo(name = "payload") val payload: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "playlist_tracks",
    primaryKeys = ["playlist_gid", "position"],
    indices = [Index("track_gid")],
)
data class PlaylistTrackEntity(
    @ColumnInfo(name = "playlist_gid") val playlistGid: String,
    @ColumnInfo(name = "position") val position: Int,
    @ColumnInfo(name = "track_gid") val trackGid: String,
)

@Entity(
    tableName = "favorites",
    indices = [Index("server_id")],
)
data class FavoriteEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "kind") val kind: String,
    @ColumnInfo(name = "value") val value: Boolean,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "ratings",
    indices = [Index("server_id")],
)
data class RatingEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "value") val value: Int,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "play_history",
    indices = [Index("server_id"), Index("last_played")],
)
data class PlayHistoryEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "last_played") val lastPlayed: Long,
    @ColumnInfo(name = "play_count") val playCount: Int,
    @ColumnInfo(name = "completed") val completed: Boolean,
)

@Entity(
    tableName = "downloads",
    indices = [Index("server_id")],
)
data class DownloadEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "state") val state: String,
    @ColumnInfo(name = "progress") val progress: Float,
    @ColumnInfo(name = "local_path") val localPath: String?,
    @ColumnInfo(name = "byte_count") val byteCount: Long,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(
    tableName = "lyrics",
    indices = [Index("server_id")],
)
data class LyricEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "payload") val payload: String,
)

@Entity(
    tableName = "disliked_tracks",
    indices = [Index("server_id")],
)
data class DislikedTrackEntity(
    @PrimaryKey @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "created_at") val createdAt: Long,
    @ColumnInfo(name = "source") val source: String?,
)

@Entity(tableName = "sync_sessions", indices = [Index(value = ["server_id"], unique = true)])
data class SyncSessionEntity(
    @PrimaryKey @ColumnInfo(name = "session_id") val sessionId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "mode") val mode: String,
    @ColumnInfo(name = "started_at") val startedAt: Long,
)

@Entity(tableName = "sync_checkpoints", primaryKeys = ["session_id", "section"])
data class SyncCheckpointEntity(
    @ColumnInfo(name = "session_id") val sessionId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "section") val section: String,
    @ColumnInfo(name = "continuation") val continuation: String?,
    @ColumnInfo(name = "source_revision") val sourceRevision: String?,
    @ColumnInfo(name = "processed_count") val processedCount: Int,
    @ColumnInfo(name = "completed_at") val completedAt: Long?,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(tableName = "sync_staged_tracks", primaryKeys = ["session_id", "global_id"])
data class SyncStagedTrackEntity(
    @ColumnInfo(name = "session_id") val sessionId: String,
    @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "remote_id") val remoteId: String,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "artist_name") val artistName: String,
    @ColumnInfo(name = "album_title") val albumTitle: String,
    @ColumnInfo(name = "album_gid") val albumGid: String?,
    @ColumnInfo(name = "artist_gid") val artistGid: String?,
    @ColumnInfo(name = "duration") val duration: Double,
    @ColumnInfo(name = "payload") val payload: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(tableName = "sync_meta")
data class SyncMetaEntity(
    @PrimaryKey @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "mode") val mode: String?,
    @ColumnInfo(name = "last_completed_at") val lastCompletedAt: Long?,
    @ColumnInfo(name = "last_processed_count") val lastProcessedCount: Int,
    @ColumnInfo(name = "remote_fingerprint") val remoteFingerprint: String?,
    @ColumnInfo(name = "last_probe_at") val lastProbeAt: Long?,
)
