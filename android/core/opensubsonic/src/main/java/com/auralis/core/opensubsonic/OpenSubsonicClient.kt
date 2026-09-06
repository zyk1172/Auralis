package com.auralis.core.opensubsonic

import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.Genre
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.PlaylistId
import com.auralis.core.domain.ServerCapabilities
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import com.auralis.core.opensubsonic.StreamQualityDecision.Companion.NO_BITRATE_LIMIT
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/** 星标目标：不同实体用不同参数名。 */
sealed interface StarTarget {
    data class Song(val id: String) : StarTarget
    data class Album(val id: String) : StarTarget
    data class Artist(val id: String) : StarTarget
}

class OpenSubsonicConfiguration(
    val baseUrl: String,
    val serverId: ServerId,
    val authentication: OpenSubsonicAuthentication,
    val requestTimeoutSeconds: Long = 30,
    val clientName: String = OpenSubsonicProtocol.CLIENT_NAME,
    val protocolVersion: String = OpenSubsonicProtocol.PROTOCOL_VERSION,
)

/**
 * OpenSubsonic REST 客户端。
 *
 * 对应 Apple `OpenSubsonicClient`：
 * - 所有请求都是 POST form-urlencoded（即使只读）；
 * - 认证参数由本类注入，调用方禁止传 `u/p/t/s/apikey`；
 * - stream/download URL **运行时构造**，不做持久化（避免认证信息落库）。
 *
 * 本类不依赖 Android UI，也不依赖 Room。
 */
class OpenSubsonicClient(
    private val configuration: OpenSubsonicConfiguration,
    private val http: OkHttpClient,
    private val vault: CredentialVault,
    private val json: Json = defaultJson,
) {
    val serverId: ServerId get() = configuration.serverId
    val baseUrl: String get() = configuration.baseUrl

    // ---------------------------------------------------------------- request

    private suspend fun authParams(): List<Pair<String, String>> {
        val auth = configuration.authentication
        val secret = when (auth) {
            is OpenSubsonicAuthentication.ApiKey -> vault.retrieve(auth.credentialReference)
            is OpenSubsonicAuthentication.Token -> vault.retrieve(auth.credentialReference)
        }
        return when (auth) {
            is OpenSubsonicAuthentication.Token -> {
                val password = secret ?: throw OpenSubsonicException(OpenSubsonicError.AuthenticationFailed)
                val salt = OpenSubsonicTokenSigner.newSalt()
                listOf(
                    "u" to auth.username,
                    "t" to OpenSubsonicTokenSigner.token(password, salt),
                    "s" to salt,
                )
            }

            is OpenSubsonicAuthentication.ApiKey -> {
                if (secret.isNullOrEmpty()) {
                    throw OpenSubsonicException(OpenSubsonicError.InvalidConfiguration("API key is empty"))
                }
                listOf("apiKey" to secret)
            }
        }
    }

    private fun globalParams(): List<Pair<String, String>> = listOf(
        "c" to configuration.clientName,
        "v" to configuration.protocolVersion,
        "f" to OpenSubsonicProtocol.FORMAT,
    )

    suspend fun request(
        endpoint: OpenSubsonicEndpoint,
        params: List<Pair<String, String>> = emptyList(),
    ): OpenSubsonicResponse {
        val forbidden = params.map { it.first }.firstOrNull {
            OpenSubsonicProtocol.RESERVED_AUTH_PARAMS.contains(it.lowercase())
        }
        if (forbidden != null) {
            throw OpenSubsonicException(OpenSubsonicError.InvalidConfiguration("authentication"))
        }
        val body = OpenSubsonicFormEncoder.encode(globalParams() + params + authParams())
        return execute(endpoint, body)
    }

    private suspend fun execute(endpoint: OpenSubsonicEndpoint, encodedBody: String): OpenSubsonicResponse =
        withContext(Dispatchers.IO) {
            val url = OpenSubsonicProtocol.endpointUrl(configuration.baseUrl, endpoint)
            val request = Request.Builder()
                .url(url)
                .post(encodedBody.toRequestBody(FORM_MEDIA_TYPE))
                .header("Accept", "application/json, application/octet-stream;q=0.9, */*;q=0.1")
                .build()
            val call = http.newBuilder()
                .callTimeout(configuration.requestTimeoutSeconds, TimeUnit.SECONDS)
                .build()
                .newCall(request)

            val raw = try {
                call.execute().use { response ->
                    if (!response.isSuccessful) throw OpenSubsonicException(mapHttp(response.code))
                    response.body?.string().orEmpty()
                }
            } catch (e: OpenSubsonicException) {
                throw e
            } catch (e: SocketTimeoutException) {
                throw OpenSubsonicException(OpenSubsonicError.TimedOut, e)
            } catch (e: UnknownHostException) {
                throw OpenSubsonicException(OpenSubsonicError.Unreachable, e)
            } catch (e: IOException) {
                throw OpenSubsonicException(OpenSubsonicError.NetworkUnavailable, e)
            }

            val envelope = try {
                json.decodeFromString<OpenSubsonicEnvelope>(raw)
            } catch (e: Exception) {
                throw OpenSubsonicException(OpenSubsonicError.InvalidResponse(raw.take(200)), e)
            }
            val response = envelope.response
            val error = response.error
            if (error != null) throw OpenSubsonicException(mapServerError(error))
            if (!response.status.equals("ok", ignoreCase = true)) {
                throw OpenSubsonicException(OpenSubsonicError.InvalidResponse("status=${response.status}"))
            }
            response
        }

    private fun mapHttp(code: Int): OpenSubsonicError = when (code) {
        401, 403 -> OpenSubsonicError.AuthenticationFailed
        404 -> OpenSubsonicError.NotFound
        in 500..599 -> OpenSubsonicError.Unreachable
        else -> OpenSubsonicError.Server(code, "HTTP $code")
    }

    private fun mapServerError(error: OpenSubsonicErrorBody): OpenSubsonicError = when (error.code) {
        0, 10, 20, 30 -> OpenSubsonicError.Server(error.code, error.message ?: "generic")
        40, 41, 50 -> OpenSubsonicError.AuthenticationFailed
        60 -> OpenSubsonicError.AuthorizationFailed
        70 -> OpenSubsonicError.NotFound
        else -> OpenSubsonicError.Server(error.code, error.message ?: "server error")
    }

    // ------------------------------------------------------------ capabilities

    suspend fun ping(): ServerInfo {
        val response = request(OpenSubsonicEndpoint.Ping)
        return ServerInfo(
            version = response.version,
            type = response.type,
            serverVersion = response.serverVersion,
            openSubsonic = response.openSubsonic ?: false,
        )
    }

    suspend fun capabilities(): ServerCapabilities = try {
        val response = request(OpenSubsonicEndpoint.GetOpenSubsonicExtensions)
        OpenSubsonicCapabilities.parse(
            response.openSubsonicExtensions?.openSubsonicExtensions
                ?: response.let { emptyList() },
        )
    } catch (e: OpenSubsonicException) {
        if (!OpenSubsonicEndpoint.GetOpenSubsonicExtensions.isRetryable()) throw e
        ServerCapabilities()
    }

    // ----------------------------------------------------------------- catalog

    suspend fun musicFolders(): List<MusicFolderDto> =
        request(OpenSubsonicEndpoint.GetMusicFolders).musicFolders?.musicFolder.orEmpty()

    suspend fun artists(): List<Artist> {
        val response = request(OpenSubsonicEndpoint.GetArtists)
        return response.artists?.index
            ?.flatMap { it.artist }
            ?.map { OpenSubsonicMapper.artist(it, serverId) }
            .orEmpty()
    }

    suspend fun albums(offset: Int, size: Int = DEFAULT_ALBUM_PAGE_SIZE): List<Album> {
        val response = request(
            OpenSubsonicEndpoint.GetAlbumList2,
            listOf("type" to "alphabeticalByName", "offset" to offset.toString(), "size" to size.toString()),
        )
        return response.albumList2?.album?.map { OpenSubsonicMapper.album(it, serverId) }.orEmpty()
    }

    suspend fun album(id: String): AlbumDetail? = request(
        OpenSubsonicEndpoint.GetAlbum,
        listOf("id" to id),
    ).album

    suspend fun artist(id: String): ArtistDetail? = request(
        OpenSubsonicEndpoint.GetArtist,
        listOf("id" to id),
    ).artist

    suspend fun song(id: String): Track? =
        request(OpenSubsonicEndpoint.GetSong, listOf("id" to id)).song?.let {
            OpenSubsonicMapper.track(it, serverId)
        }

    suspend fun genres(): List<Genre> =
        request(OpenSubsonicEndpoint.GetGenres).genres?.genre?.map {
            OpenSubsonicMapper.genre(it, serverId)
        }.orEmpty()

    suspend fun randomSongs(size: Int = 50): List<Track> =
        request(OpenSubsonicEndpoint.GetRandomSongs, listOf("size" to size.toString()))
            .randomSongs?.song?.map { OpenSubsonicMapper.track(it, serverId) }.orEmpty()

    /** 收藏（starred2）。返回曲目 / 专辑 / 艺术家三组。 */
    suspend fun starred(): StarredContainer =
        request(OpenSubsonicEndpoint.GetStarred2).starred2 ?: StarredContainer()

    suspend fun search(
        query: String,
        artistCount: Int = 20,
        albumCount: Int = 40,
        songCount: Int = 60,
    ): SearchContainer = request(
        OpenSubsonicEndpoint.Search3,
        listOf(
            "query" to query,
            "artistCount" to artistCount.toString(),
            "albumCount" to albumCount.toString(),
            "songCount" to songCount.toString(),
        ),
    ).searchResult3 ?: SearchContainer()

    // ---------------------------------------------------------------- playlists

    suspend fun playlists(): List<Playlist> =
        request(OpenSubsonicEndpoint.GetPlaylists).playlists?.playlist?.map {
            OpenSubsonicMapper.playlist(it, serverId)
        }.orEmpty()

    suspend fun playlist(id: String): Playlist? =
        request(OpenSubsonicEndpoint.GetPlaylist, listOf("id" to id)).playlist?.let {
            OpenSubsonicMapper.playlist(it, serverId)
        }

    suspend fun createPlaylist(name: String, trackIds: List<String>): PlaylistId? {
        val params = mutableListOf("name" to name)
        trackIds.forEach { params += "songId" to it }
        return request(OpenSubsonicEndpoint.CreatePlaylist, params).playlist?.id?.value?.let { PlaylistId(it) }
    }

    suspend fun updatePlaylist(
        id: String,
        name: String? = null,
        comment: String? = null,
        appendTrackIds: List<String> = emptyList(),
        removeIndexes: List<Int> = emptyList(),
    ) {
        val params = mutableListOf("playlistId" to id)
        name?.let { params += "name" to it }
        comment?.let { params += "comment" to it }
        appendTrackIds.forEach { params += "songIdToAdd" to it }
        removeIndexes.forEach { params += "songIndexToRemove" to it.toString() }
        request(OpenSubsonicEndpoint.UpdatePlaylist, params)
    }

    suspend fun deletePlaylist(id: String) {
        request(OpenSubsonicEndpoint.DeletePlaylist, listOf("id" to id))
    }

    // ------------------------------------------------------------------- social

    suspend fun star(target: StarTarget) {
        request(OpenSubsonicEndpoint.Star, listOf(target.toParam()))
    }

    suspend fun unstar(target: StarTarget) {
        request(OpenSubsonicEndpoint.Unstar, listOf(target.toParam()))
    }

    suspend fun setRating(trackId: String, rating: Int) {
        request(OpenSubsonicEndpoint.SetRating, listOf("id" to trackId, "rating" to rating.toString()))
    }

    suspend fun scrobble(trackIds: List<String>, submission: Boolean = true) {
        val params = mutableListOf<Pair<String, String>>()
        val now = System.currentTimeMillis()
        trackIds.forEach { params += "id" to it }
        trackIds.forEach { params += "time" to now.toString() }
        params += "submission" to submission.toString()
        request(OpenSubsonicEndpoint.Scrobble, params)
    }

    // -------------------------------------------------------------------- lyrics

    /** 结构化歌词（getLyricsBySongId）。没有结果时返回空列表，由上层回退到 [plainLyrics]。 */
    suspend fun structuredLyrics(trackId: String): List<StructuredLyricsDto> =
        request(OpenSubsonicEndpoint.GetLyricsBySongId, listOf("id" to trackId))
            .lyricsList?.structuredLyrics.orEmpty()

    /** 传统歌词（getLyrics by artist+title）。 */
    suspend fun plainLyrics(artist: String, title: String): String? =
        request(OpenSubsonicEndpoint.GetLyrics, listOf("artist" to artist, "title" to title))
            .lyrics?.value?.takeIf { it.isNotBlank() }

    suspend fun lyricsFor(track: Track): LyricsDocument? {
        val structured = structuredLyrics(track.id.value).firstOrNull { it.line.isNotEmpty() }
        if (structured != null) {
            return OpenSubsonicMapper.structuredLyrics(structured, track.serverId, track.id)
        }
        val plain = plainLyrics(track.artistName, track.title) ?: return null
        return OpenSubsonicMapper.plainLyrics(plain, track.serverId, track.id)
    }

    suspend fun similarSongs(trackId: String, count: Int = 30): List<Track> =
        request(OpenSubsonicEndpoint.GetSimilarSongs2, listOf("id" to trackId, "count" to count.toString()))
            .similarSongs2?.song?.map { OpenSubsonicMapper.track(it, serverId) }.orEmpty()

    // -------------------------------------------------------------- url builders

    /**
     * 构造 stream URL。认证参数以 query 形式附在 URL 上（供 ExoPlayer 直接播放）。
     * **绝不持久化、绝不打印**——见 [redacted]。
     */
    suspend fun makeStreamUrl(
        trackId: TrackId,
        decision: StreamQualityDecision = StreamQualityDecision.Raw,
    ): String {
        val params = mutableListOf("id" to trackId.value)
        if (decision.maxBitRate != NO_BITRATE_LIMIT) params += "maxBitRate" to decision.maxBitRate.toString()
        decision.format?.let { params += "format" to it }
        return urlFor(OpenSubsonicEndpoint.Stream, params)
    }

    suspend fun makeDownloadUrl(trackId: TrackId): String =
        urlFor(OpenSubsonicEndpoint.Download, listOf("id" to trackId.value))

    suspend fun coverArtUrl(key: String, size: Int): String =
        urlFor(OpenSubsonicEndpoint.GetCoverArt, listOf("id" to key, "size" to size.coerceIn(1, 4096).toString()))

    private suspend fun urlFor(endpoint: OpenSubsonicEndpoint, params: List<Pair<String, String>>): String {
        val query = OpenSubsonicFormEncoder.encode(globalParams() + params + authParams())
        return "${OpenSubsonicProtocol.endpointUrl(configuration.baseUrl, endpoint)}?$query"
    }

    /** 日志用的脱敏 URL：去掉所有认证 query 参数。 */
    fun redacted(url: String): String {
        val index = url.indexOf('?')
        if (index < 0) return url
        val kept = url.substring(index + 1).split('&').filterNot {
            val name = it.substringBefore('=')
            OpenSubsonicProtocol.RESERVED_AUTH_PARAMS.contains(name)
        }
        return url.substring(0, index) + if (kept.isEmpty()) "" else "?" + kept.joinToString("&")
    }

    companion object {
        const val DEFAULT_ALBUM_PAGE_SIZE = 250
        private val FORM_MEDIA_TYPE = "application/x-www-form-urlencoded; charset=utf-8".toMediaType()
        val defaultJson = Json {
            ignoreUnknownKeys = true
            isLenient = true
            explicitNulls = false
            coerceInputValues = true
        }
    }
}

private fun StarTarget.toParam(): Pair<String, String> = when (this) {
    is StarTarget.Song -> "id" to id
    is StarTarget.Album -> "albumId" to id
    is StarTarget.Artist -> "artistId" to id
}
