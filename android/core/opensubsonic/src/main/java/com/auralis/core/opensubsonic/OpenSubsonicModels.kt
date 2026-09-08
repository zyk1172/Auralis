// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.opensubsonic

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * 凭据读取端口。Android 实现走 Keystore-backed 加密存储；
 * 明文密码/API Key 只在调用瞬间存在于内存，不落 Room、不进日志。
 */
interface CredentialVault {
    suspend fun store(reference: String, secret: String)

    suspend fun retrieve(reference: String): String?

    suspend fun delete(reference: String)
}

sealed interface OpenSubsonicAuthentication {
    data class Token(val username: String, val credentialReference: String) : OpenSubsonicAuthentication
    data class ApiKey(val credentialReference: String) : OpenSubsonicAuthentication
}

@Serializable
data class OpenSubsonicErrorBody(val code: Int, val message: String? = null)

@Serializable
data class OpenSubsonicResponse(
    val status: String? = null,
    val version: String? = null,
    val type: String? = null,
    @SerialName("serverVersion") val serverVersion: String? = null,
    @SerialName("openSubsonic") val openSubsonic: Boolean? = null,
    val error: OpenSubsonicErrorBody? = null,
    // containers
    @SerialName("musicFolders") val musicFolders: MusicFolders? = null,
    val artists: ArtistsContainer? = null,
    val artist: ArtistDetail? = null,
    val album: AlbumDetail? = null,
    val song: Child? = null,
    val genres: GenresContainer? = null,
    @SerialName("albumList2") val albumList2: AlbumListContainer? = null,
    @SerialName("randomSongs") val randomSongs: SongsContainer? = null,
    @SerialName("starred2") val starred2: StarredContainer? = null,
    @SerialName("searchResult3") val searchResult3: SearchContainer? = null,
    val playlists: PlaylistsContainer? = null,
    val playlist: PlaylistDto? = null,
    @SerialName("lyricsList") val lyricsList: LyricsListContainer? = null,
    val lyrics: LyricsDto? = null,
    @SerialName("similarSongs2") val similarSongs2: SongsContainer? = null,
    @SerialName("openSubsonicExtensions") val openSubsonicExtensions: ExtensionsContainer? = null,
)

@Serializable
data class OpenSubsonicEnvelope(@SerialName("subsonic-response") val response: OpenSubsonicResponse)

@Serializable
data class MusicFolders(@SerialName("musicFolder") val musicFolder: List<MusicFolderDto> = emptyList())

@Serializable
data class MusicFolderDto(val id: FlexibleString? = null, val name: String = "")

@Serializable
data class ArtistsContainer(
    val index: List<ArtistIndexEntry> = emptyList(),
    @SerialName("ignoredArticles") val ignoredArticles: String? = null,
)

@Serializable
data class ArtistIndexEntry(val name: String = "", val artist: List<ArtistDto> = emptyList())

@Serializable
data class ArtistDto(
    val id: FlexibleString? = null,
    val name: String = "",
    @SerialName("albumCount") val albumCount: Int = 0,
    @SerialName("coverArt") val coverArt: FlexibleString? = null,
)

@Serializable
data class ArtistDetail(
    val id: FlexibleString? = null,
    val name: String = "",
    @SerialName("albumCount") val albumCount: Int = 0,
    @SerialName("coverArt") val coverArt: FlexibleString? = null,
    val album: List<AlbumDto> = emptyList(),
)

@Serializable
data class AlbumDto(
    val id: FlexibleString? = null,
    val name: String = "",
    val artist: String? = null,
    @SerialName("artistId") val artistId: FlexibleString? = null,
    @SerialName("coverArt") val coverArt: FlexibleString? = null,
    @SerialName("songCount") val songCount: Int? = null,
    val duration: Int? = null,
    val year: Int? = null,
    val genre: String? = null,
    val created: String? = null,
    val song: List<Child> = emptyList(),
)

@Serializable
data class AlbumDetail(
    val id: FlexibleString? = null,
    val name: String = "",
    val artist: String? = null,
    @SerialName("artistId") val artistId: FlexibleString? = null,
    @SerialName("coverArt") val coverArt: FlexibleString? = null,
    @SerialName("songCount") val songCount: Int? = null,
    val year: Int? = null,
    val genre: String? = null,
    val song: List<Child> = emptyList(),
)

@Serializable
data class AlbumListContainer(val album: List<AlbumDto> = emptyList())

@Serializable
data class SongsContainer(val song: List<Child> = emptyList())

@Serializable
data class StarredContainer(
    val song: List<Child> = emptyList(),
    val album: List<AlbumDto> = emptyList(),
    val artist: List<ArtistDto> = emptyList(),
)

@Serializable
data class SearchContainer(
    val artist: List<ArtistDto> = emptyList(),
    val album: List<AlbumDto> = emptyList(),
    val song: List<Child> = emptyList(),
)

@Serializable
data class GenresContainer(val genre: List<GenreDto> = emptyList())

@Serializable
data class GenreDto(
    val value: String = "",
    @SerialName("songCount") val songCount: Int = 0,
    @SerialName("albumCount") val albumCount: Int = 0,
)

@Serializable
data class ReplayGainDto(
    @SerialName("trackGain") val trackGain: Double? = null,
    @SerialName("albumGain") val albumGain: Double? = null,
    @SerialName("trackPeak") val trackPeak: Double? = null,
    @SerialName("albumPeak") val albumPeak: Double? = null,
    @SerialName("baseGain") val baseGain: Double? = null,
    @SerialName("fallbackGain") val fallbackGain: Double? = null,
)

@Serializable
data class Child(
    val id: FlexibleString? = null,
    val parent: FlexibleString? = null,
    val title: String = "",
    val album: String? = null,
    val artist: String? = null,
    @SerialName("albumId") val albumId: FlexibleString? = null,
    @SerialName("artistId") val artistId: FlexibleString? = null,
    @SerialName("coverArt") val coverArt: FlexibleString? = null,
    val duration: Double? = null,
    @SerialName("bitRate") val bitRate: Int? = null,
    @SerialName("bitDepth") val bitDepth: Int? = null,
    @SerialName("sampleRate") val sampleRate: Int? = null,
    @SerialName("channelCount") val channelCount: Int? = null,
    val track: Int? = null,
    @SerialName("discNumber") val discNumber: Int? = null,
    val year: Int? = null,
    val genre: String? = null,
    val genres: List<GenreNameDto> = emptyList(),
    val language: String? = null,
    val starred: String? = null,
    @SerialName("userRating") val userRating: Int? = null,
    val suffix: String? = null,
    @SerialName("contentType") val contentType: String? = null,
    @SerialName("transcodedContentType") val transcodedContentType: String? = null,
    @SerialName("replayGain") val replayGain: ReplayGainDto? = null,
    val size: Long? = null,
    val path: String? = null,
)

@Serializable
data class GenreNameDto(val name: String = "")

@Serializable
data class PlaylistsContainer(val playlist: List<PlaylistDto> = emptyList())

@Serializable
data class PlaylistDto(
    val id: FlexibleString? = null,
    val name: String = "",
    val comment: String? = null,
    @SerialName("songCount") val songCount: Int = 0,
    val duration: Int? = null,
    val created: String? = null,
    val changed: String? = null,
    @SerialName("public") val isPublic: Boolean? = null,
    val readonly: Boolean? = null,
    @SerialName("validUntil") val validUntil: String? = null,
    val entry: List<Child> = emptyList(),
)

@Serializable
data class LyricsListContainer(@SerialName("structuredLyrics") val structuredLyrics: List<StructuredLyricsDto> = emptyList())

@Serializable
data class StructuredLyricsDto(
    val lang: String? = null,
    val synced: Boolean? = null,
    val line: List<LyricLineDto> = emptyList(),
    val displayArtist: String? = null,
    val displayTitle: String? = null,
)

@Serializable
data class LyricLineDto(
    val start: Long? = null,
    val value: String = "",
)

@Serializable
data class LyricsDto(
    val value: String? = null,
    val artist: String? = null,
    val title: String? = null,
)

@Serializable
data class ExtensionsContainer(
    @SerialName("openSubsonicExtensions") val openSubsonicExtensions: List<ExtensionDto> = emptyList(),
)

@Serializable
data class ExtensionDto(val name: String = "", val versions: List<Int> = emptyList())

@Serializable
data class ServerInfo(
    val version: String?,
    val type: String?,
    val serverVersion: String?,
    val openSubsonic: Boolean,
)

/**
 * OpenSubsonic 服务器会把 id 以数字或字符串返回，必须两者都接受。
 * 对应 Apple `FlexibleString`。
 */
@Serializable(with = FlexibleStringSerializer::class)
data class FlexibleString(val value: String)
