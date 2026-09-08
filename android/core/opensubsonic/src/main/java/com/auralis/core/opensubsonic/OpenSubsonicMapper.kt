// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.opensubsonic

import com.auralis.core.domain.Album
import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.Artist
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.AudioSourceInfo
import com.auralis.core.domain.Genre
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.PlaylistId
import com.auralis.core.domain.ReplayGainMetadata
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.TimedLyricLine
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import java.time.Instant
import java.time.format.DateTimeParseException

/**
 * DTO → Domain 的唯一映射边界。
 *
 * 严禁把 Retrofit/OkHttp DTO、Room Entity、Compose UI Model 三层共用一个类。
 */
object OpenSubsonicMapper {

    fun track(child: Child, serverId: ServerId): Track {
        val id = child.id?.value.orEmpty()
        val genres = buildList {
            child.genres.mapTo(this) { it.name }
            child.genre?.takeIf { it.isNotBlank() }?.let { add(it) }
        }.distinct()
        return Track(
            id = TrackId(id),
            serverId = serverId,
            albumId = AlbumId(child.albumId?.value ?: child.parent?.value ?: ""),
            artistId = ArtistId(child.artistId?.value ?: ""),
            title = child.title,
            artistName = child.artist.orEmpty(),
            albumTitle = child.album.orEmpty(),
            durationSeconds = child.duration ?: 0.0,
            trackNumber = child.track,
            discNumber = child.discNumber,
            year = child.year,
            genres = genres,
            language = child.language,
            isFavorite = child.starred != null,
            rating = child.userRating?.takeIf { it > 0 },
            artworkKey = child.coverArt?.value,
            sourceInfo = AudioSourceInfo(
                codec = child.suffix ?: child.contentType ?: child.transcodedContentType,
                bitDepth = child.bitDepth,
                sampleRate = child.sampleRate,
                bitRate = child.bitRate,
                channelCount = child.channelCount,
                replayGain = child.replayGain?.let {
                    ReplayGainMetadata(
                        trackGainDb = it.trackGain,
                        albumGainDb = it.albumGain,
                        trackPeak = it.trackPeak,
                        albumPeak = it.albumPeak,
                        baseGainDb = it.baseGain,
                        fallbackGainDb = it.fallbackGain,
                    )
                },
            ),
        )
    }

    fun album(dto: AlbumDto, serverId: ServerId): Album = Album(
        id = AlbumId(dto.id?.value.orEmpty()),
        serverId = serverId,
        artistId = ArtistId(dto.artistId?.value.orEmpty()),
        title = dto.name,
        artistName = dto.artist.orEmpty(),
        year = dto.year,
        genre = dto.genre,
        artworkKey = dto.coverArt?.value,
        songCount = dto.songCount,
    )

    fun artist(dto: ArtistDto, serverId: ServerId): Artist = Artist(
        id = ArtistId(dto.id?.value.orEmpty()),
        serverId = serverId,
        name = dto.name,
        albumCount = dto.albumCount,
        artworkKey = dto.coverArt?.value,
    )

    fun genre(dto: GenreDto, serverId: ServerId): Genre =
        Genre(name = dto.value, songCount = dto.songCount, serverId = serverId)

    fun playlist(dto: PlaylistDto, serverId: ServerId): Playlist = Playlist(
        id = PlaylistId(dto.id?.value.orEmpty()),
        serverId = serverId,
        name = dto.name,
        trackIds = dto.entry.mapNotNull { it.id?.value }.map { TrackId(it) },
        comment = dto.comment,
        modifiedAtMillis = dto.changed?.let(::parseDate) ?: dto.created?.let(::parseDate),
        isReadOnly = dto.readonly ?: false,
        validUntilMillis = dto.validUntil?.let(::parseDate),
    )

    /** 结构化歌词优先；`start` 单位是毫秒。 */
    fun structuredLyrics(dto: StructuredLyricsDto, serverId: ServerId, trackId: TrackId): LyricsDocument =
        LyricsDocument(
            globalId = com.auralis.core.domain.GlobalId(serverId, trackId.value),
            language = dto.lang,
            lines = dto.line.map { TimedLyricLine(startTimeSeconds = (it.start ?: 0) / 1000.0, text = it.value) },
            isSynced = dto.synced ?: dto.line.any { it.start != null },
        )

    /** 非结构化歌词：按行拆分，没有时间轴。 */
    fun plainLyrics(value: String, serverId: ServerId, trackId: TrackId): LyricsDocument =
        LyricsDocument(
            globalId = com.auralis.core.domain.GlobalId(serverId, trackId.value),
            lines = value.lineSequence()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .map { TimedLyricLine(startTimeSeconds = null, text = it) }
                .toList(),
            isSynced = false,
        )

    fun parseDate(raw: String): Long? = try {
        Instant.parse(raw).toEpochMilli()
    } catch (_: DateTimeParseException) {
        null
    }
}
