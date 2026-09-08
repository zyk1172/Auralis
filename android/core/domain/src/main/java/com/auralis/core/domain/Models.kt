// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

import kotlinx.serialization.Serializable

/**
 * 服务器账号。注意**双地址**语义：
 * - [baseUrl] 是内网优先地址；
 * - [externalBaseUrl] 是内网不可达时才使用的外网地址。
 *
 * 简化成单个 `serverUrl` 会直接丢失 Auralis 已有能力。
 * 凭据永远不放在这里，只放 [credentialReference]（Android Keystore 里的 key）。
 */
@Serializable
data class ServerAccount(
    val id: ServerId,
    val displayName: String,
    val baseUrl: String? = null,
    val externalBaseUrl: String? = null,
    val username: String? = null,
    val credentialReference: String? = null,
)

@Serializable
data class Artist(
    val id: ArtistId,
    val serverId: ServerId,
    val name: String,
    val albumCount: Int,
    val artworkKey: String? = null,
) {
    val globalId: GlobalId get() = GlobalId(serverId, id.value)
}

@Serializable
data class Album(
    val id: AlbumId,
    val serverId: ServerId,
    val artistId: ArtistId,
    val title: String,
    val artistName: String,
    val year: Int? = null,
    val genre: String? = null,
    val artworkKey: String? = null,
    /** 服务器报告的曲目数（getAlbumList2 的 songCount）。 */
    val songCount: Int? = null,
) {
    val globalId: GlobalId get() = GlobalId(serverId, id.value)
}

@Serializable
data class AudioSourceInfo(
    val codec: String? = null,
    val bitDepth: Int? = null,
    val sampleRate: Int? = null,
    val bitRate: Int? = null,
    val channelCount: Int? = null,
    val replayGain: ReplayGainMetadata? = null,
) {
    /** "audio/mpeg" -> "mpeg"；"FLAC" -> "flac"；空 -> null。 */
    val normalizedCodec: String?
        get() {
            val raw = codec?.trim()?.lowercase() ?: return null
            if (raw.isEmpty()) return null
            return raw.removePrefix("audio/").ifEmpty { null }
        }
}

/** 增益单位 dB；peak 为线性满量程比值。 */
@Serializable
data class ReplayGainMetadata(
    val trackGainDb: Double? = null,
    val albumGainDb: Double? = null,
    val trackPeak: Double? = null,
    val albumPeak: Double? = null,
    val baseGainDb: Double? = null,
    val fallbackGainDb: Double? = null,
)

/**
 * 曲目领域对象。字段与 Apple `Track` 同等信息量——不要退化成 `Song(id,name,url)`。
 *
 * [streamUrl] 只在真正要播放前才 resolve，领域对象本身不长期持有带认证的 URL。
 */
@Serializable
data class Track(
    val id: TrackId,
    val serverId: ServerId,
    val albumId: AlbumId,
    val artistId: ArtistId,
    val title: String,
    val artistName: String,
    val albumTitle: String,
    val durationSeconds: Double,
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val year: Int? = null,
    val genres: List<String> = emptyList(),
    val language: String? = null,
    val isFavorite: Boolean = false,
    val rating: Int? = null,
    val artworkKey: String? = null,
    val sourceInfo: AudioSourceInfo = AudioSourceInfo(),
    val streamUrl: String? = null,
) {
    val globalId: GlobalId get() = GlobalId(serverId, id.value)

    /** 跨服务器安全比较：必须同时比较 serverId 与 id。 */
    fun isSameAs(other: Track): Boolean = serverId == other.serverId && id == other.id
}

@Serializable
data class Genre(
    val name: String,
    val songCount: Int,
    val serverId: ServerId? = null,
) {
    val id: String get() = name.lowercase()
}

@Serializable
data class Playlist(
    val id: PlaylistId,
    val serverId: ServerId,
    val name: String,
    val trackIds: List<TrackId> = emptyList(),
    val comment: String? = null,
    /** 最后一次修改时间，用于同步时的 LWW 合并。 */
    val modifiedAtMillis: Long? = null,
    val isReadOnly: Boolean = false,
    val validUntilMillis: Long? = null,
) {
    val globalId: GlobalId get() = GlobalId(serverId, id.value)
}

@Serializable
data class PlayHistory(
    val track: Track,
    val lastPlayedMillis: Long,
    val playCount: Int,
    val completed: Boolean,
)

@Serializable
enum class DownloadStatus { NotDownloaded, Queued, Downloading, Downloaded, Failed }

@Serializable
data class DownloadRecord(
    val globalId: GlobalId,
    val status: DownloadStatus,
    val progress: Float = 0f,
    val localPath: String? = null,
    val updatedAtMillis: Long = 0L,
)

@Serializable
data class TimedLyricLine(
    val startTimeSeconds: Double? = null,
    val text: String,
    val translation: String? = null,
)

@Serializable
data class LyricsDocument(
    val globalId: GlobalId,
    val language: String? = null,
    val lines: List<TimedLyricLine> = emptyList(),
    val isSynced: Boolean = false,
)

@Serializable
data class ServerCapabilities(
    val supportsStructuredLyrics: Boolean = false,
    val supportsSonicSimilarity: Boolean = false,
    val supportsIndexedQueue: Boolean = false,
    val supportsPlaybackReport: Boolean = false,
    val supportsTranscoding: Boolean = false,
    val supportsTranscodeOffset: Boolean = false,
    val supportsApiKeyAuthentication: Boolean = false,
)

/**
 * 同一录音可能有多个编码版本。推荐/智能队列用它合并，高质量优先。
 * Apple 端 `TrackQuality` 的 1:1 移植（时长按 8 秒分桶）。
 */
object TrackQuality {
    fun recordingKey(track: Track): String {
        val bucket = (track.durationSeconds / 8.0).let { kotlin.math.round(it) }.toInt().coerceAtLeast(0)
        return "${normalize(track.title)}|${normalize(track.artistName)}|$bucket"
    }

    fun deduplicatedPreferringQuality(tracks: List<Track>): List<Track> {
        val result = ArrayList<Track>(tracks.size)
        val index = HashMap<String, Int>()
        for (track in tracks) {
            val key = recordingKey(track)
            val at = index[key]
            if (at != null) {
                if (isPreferred(track, result[at])) result[at] = track
            } else {
                index[key] = result.size
                result.add(track)
            }
        }
        return result
    }

    fun isPreferred(candidate: Track, current: Track): Boolean {
        val a = score(candidate)
        val b = score(current)
        if (a != b) return a > b
        if (candidate.isFavorite != current.isFavorite) return candidate.isFavorite
        if (candidate.rating != current.rating) return (candidate.rating ?: 0) > (current.rating ?: 0)
        return candidate.id.value < current.id.value
    }

    fun score(track: Track): Long {
        val tier = when (track.sourceInfo.normalizedCodec) {
            "dsf", "dff" -> 7L
            "wav", "aiff", "aif" -> 6L
            "flac", "alac", "ape", "wv" -> 5L
            "opus" -> 3L
            "aac", "m4a", "mp4", "ogg", "vorbis" -> 2L
            "mp3", "mpeg" -> 1L
            else -> 0L
        }
        val bitDepth = (track.sourceInfo.bitDepth ?: 0).coerceIn(0, 64).toLong()
        val sampleRate = (track.sourceInfo.sampleRate ?: 0).coerceIn(0, 768_000).toLong()
        val bitRate = (track.sourceInfo.bitRate ?: 0).coerceIn(0, 20_000_000).toLong()
        val channels = (track.sourceInfo.channelCount ?: 0).coerceIn(0, 16).toLong()
        return tier * 1_000_000_000_000L + bitDepth * 1_000_000_000L + sampleRate * 1_000L + bitRate + channels
    }

    private fun normalize(value: String): String =
        value.filter { it.isLetterOrDigit() }.lowercase()
}
