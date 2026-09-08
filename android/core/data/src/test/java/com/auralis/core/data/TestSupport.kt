// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import com.auralis.core.opensubsonic.CredentialVault
import java.util.concurrent.ConcurrentHashMap
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 内存 CredentialVault：模拟 Keystore 语义（store 覆盖、retrieve 无则 null）。 */
class FakeVault : CredentialVault {
    private val map = ConcurrentHashMap<String, String>()

    override suspend fun store(reference: String, secret: String) {
        map[reference] = secret
    }

    override suspend fun retrieve(reference: String): String? = map[reference]

    override suspend fun delete(reference: String) {
        map.remove(reference)
    }

    fun snapshot(): Map<String, String> = map.toMap()
}

/** Robolectric + Room in-memory 测试基座。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
abstract class RoomDbTest {
    protected fun openDatabase(): AuralisDatabase = Room.inMemoryDatabaseBuilder(
        ApplicationProvider.getApplicationContext(),
        AuralisDatabase::class.java,
    ).allowMainThreadQueries().build()

    protected fun repository(db: AuralisDatabase): RoomCatalogRepository {
        return RoomCatalogRepository(
            database = db,
            serverDao = db.serverDao(),
            artistDao = db.artistDao(),
            albumDao = db.albumDao(),
            trackDao = db.trackDao(),
            trackFtsDao = db.trackFtsDao(),
            genreDao = db.genreDao(),
            playlistDao = db.playlistDao(),
            annotationDao = db.annotationDao(),
            downloadDao = db.downloadDao(),
            syncDao = db.syncDao(),
        )
    }

    protected fun server(
        id: ServerId = ServerId("server-a"),
        displayName: String = "A",
        baseUrl: String? = "http://lan-a.local",
        external: String? = null,
        username: String? = "u",
        credentialReference: String = "opensubsonic.${id.value}",
    ): ServerAccount = ServerAccount(
        id = id,
        displayName = displayName,
        baseUrl = baseUrl,
        externalBaseUrl = external,
        username = username,
        credentialReference = credentialReference,
    )
}

/** OpenSubsonic JSON 信封构造器。协议是 JSON（FORMAT=json），全部 POST form 编码。 */
object SubsonicJson {
    const val OK_PREFIX = """{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.53.0","openSubsonic":true"""

    fun ok(vararg pairs: Pair<String, String>): String {
        val body = pairs.joinToString(",") { (k, v) -> """"$k":$v""" }
        return if (pairs.isEmpty()) "$OK_PREFIX}}" else "$OK_PREFIX,$body}}"
    }

    fun fail(code: Int, message: String): String =
        """{"subsonic-response":{"status":"failed","error":{"code":$code,"message":"$message"}}}"""

    val pingOk = ok()
    val artistsEmpty = ok("artists" to """{"index":[]}""")
    val albumListEmpty = ok("albumList2" to """{"album":[]}""")
    val genresEmpty = ok("genres" to """{"genre":[]}""")
    val playlistsEmpty = ok("playlists" to """{"playlist":[]}""")
    val starredEmpty = ok("starred2" to """{"song":[]}""")
    val extensionsEmpty = ok("openSubsonicExtensions" to """{"openSubsonicExtension":[]}""")
}

/** 空目录且成功的标准模拟服务器：按 endpoint 分派 JSON。 */
fun MockWebServer.enqueueCatalog() {
    dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
            val path = request.path.orEmpty()
            val json = when {
                "ping.view" in path -> SubsonicJson.pingOk
                "getArtists.view" in path -> SubsonicJson.artistsEmpty
                "getAlbumList2.view" in path -> SubsonicJson.albumListEmpty
                "getGenres.view" in path -> SubsonicJson.genresEmpty
                "getPlaylists.view" in path -> SubsonicJson.playlistsEmpty
                "getStarred2.view" in path -> SubsonicJson.starredEmpty
                "getOpenSubsonicExtensions.view" in path -> SubsonicJson.extensionsEmpty
                else -> SubsonicJson.pingOk
            }
            return MockResponse().setResponseCode(200).setBody(json)
        }
    }
}

/** 全部请求固定返回某状态码（模拟整机不可达/5xx）。 */
fun MockWebServer.enqueueHttp(code: Int) {
    dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse =
            MockResponse().setResponseCode(code).setBody("boom")
    }
}

/** ping 固定返回认证失败（其余端点 200 空目录）。 */
fun MockWebServer.enqueueAuthFailure() {
    dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
            val path = request.path.orEmpty()
            val json = if ("ping.view" in path) {
                SubsonicJson.fail(40, "Wrong username or password")
            } else {
                SubsonicJson.pingOk
            }
            return MockResponse().setResponseCode(200).setBody(json)
        }
    }
}

/** ping 固定返回 200 + 非法正文（协议错误，不是网络不可达）。 */
fun MockWebServer.enqueueGarbageBody() {
    dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
            val path = request.path.orEmpty()
            val body = if ("ping.view" in path) "this is not json {{{" else SubsonicJson.pingOk
            return MockResponse().setResponseCode(200).setBody(body)
        }
    }
}

/** ping 成功 + 带一首收藏歌（s1），其余空。 */
fun MockWebServer.enqueueCatalogWithStarredSong() {
    dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
            val path = request.path.orEmpty()
            val json = when {
                "ping.view" in path -> SubsonicJson.pingOk
                "getArtists.view" in path -> SubsonicJson.artistsEmpty
                "getAlbumList2.view" in path -> SubsonicJson.albumListEmpty
                "getGenres.view" in path -> SubsonicJson.genresEmpty
                "getPlaylists.view" in path -> SubsonicJson.playlistsEmpty
                "getStarred2.view" in path ->
                    SubsonicJson.ok("starred2" to """{"song":[{"id":"s1","title":"Star","artist":"X","album":"Y"}]}""")
                else -> SubsonicJson.pingOk
            }
            return MockResponse().setResponseCode(200).setBody(json)
        }
    }
}

// ------------------------------------------------------------ domain builders

private val emptyArtistId = com.auralis.core.domain.ArtistId("")
private val emptyAlbumId = com.auralis.core.domain.AlbumId("")

fun trackOf(
    serverId: ServerId,
    remoteId: String,
    title: String,
    artist: String = "Artist",
    album: String = "Album",
    albumId: String = "",
    artistId: String = "",
): com.auralis.core.domain.Track = com.auralis.core.domain.Track(
    id = com.auralis.core.domain.TrackId(remoteId),
    serverId = serverId,
    albumId = if (albumId.isEmpty()) emptyAlbumId else com.auralis.core.domain.AlbumId(albumId),
    artistId = if (artistId.isEmpty()) emptyArtistId else com.auralis.core.domain.ArtistId(artistId),
    title = title,
    artistName = artist,
    albumTitle = album,
    durationSeconds = 180.0,
)

fun albumOf(
    serverId: ServerId,
    remoteId: String,
    title: String,
    artist: String = "Artist",
    songCount: Int = 0,
): com.auralis.core.domain.Album = com.auralis.core.domain.Album(
    id = com.auralis.core.domain.AlbumId(remoteId),
    serverId = serverId,
    artistId = emptyArtistId,
    title = title,
    artistName = artist,
    songCount = songCount,
)

fun artistOf(
    serverId: ServerId,
    remoteId: String,
    name: String,
    albumCount: Int = 0,
): com.auralis.core.domain.Artist = com.auralis.core.domain.Artist(
    id = com.auralis.core.domain.ArtistId(remoteId),
    serverId = serverId,
    name = name,
    albumCount = albumCount,
)

fun genreOf(name: String, songCount: Int = 1, serverId: ServerId? = null): com.auralis.core.domain.Genre =
    com.auralis.core.domain.Genre(name = name, songCount = songCount, serverId = serverId)
