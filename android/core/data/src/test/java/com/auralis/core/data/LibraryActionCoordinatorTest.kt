// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.connector.LibraryActionCoordinator
import com.auralis.core.data.connector.LibraryRemoteOperationException
import com.auralis.core.data.connector.ServerClientRegistry
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * LibraryActionCoordinator（P0 第五项）：远端先行、成功落本地、失败不留假状态。
 */
class LibraryActionCoordinatorTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var repo: RoomCatalogRepository
    private lateinit var vault: FakeVault
    private lateinit var registry: ServerClientRegistry
    private lateinit var mock: MockWebServer

    private val serverId = ServerId("server-actions")
    private lateinit var track: Track

    @Before
    fun setUp() {
        db = openDatabase()
        repo = repository(db)
        vault = FakeVault()
        registry = ServerClientRegistry(vault)
        mock = MockWebServer(); mock.start()

        val url = mock.url("/").toString()
        val account = server(
            id = serverId,
            displayName = "Srv",
            baseUrl = url,
            username = "u",
        )
        runBlocking { vault.store(account.credentialReference!!, "pw") }
        registry.registerResolved(registry.makeInternalEndpoint(account))

        track = trackOf(serverId, "t1", "Track One", albumId = "al1")
    }

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
        if (::mock.isInitialized) mock.shutdown()
    }

    private fun okDispatcher(vararg paths: String) {
        mock.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                val p = request.path.orEmpty()
                val json = if (paths.any { it in p }) SubsonicJson.pingOk else SubsonicJson.pingOk
                return MockResponse().setResponseCode(200).setBody(json)
            }
        }
    }

    private fun coordinator() = LibraryActionCoordinator(registry, repo)

    @Test
    fun `收藏歌曲远端 star 成功后才落本地`() = runBlocking {
        okDispatcher("star.view")
        val coord = coordinator()

        assertTrue(coord.setTrackFavorite(track, true))

        // 远端已调用 star。
        val request = mock.takeRequest()
        assertTrue(request.path!!.contains("star.view"))
        assertTrue(request.body.readUtf8().contains("id=t1"))
        // 本地已生效。
        assertTrue(repo.isFavorite(track.globalId))
    }

    @Test
    fun `取消收藏远端 unstar 成功后本地清除`() = runBlocking {
        okDispatcher("unstar.view")
        repo.setFavorite(track.globalId, FavoriteKind.Track, true)
        val coord = coordinator()

        assertTrue(coord.setTrackFavorite(track, false))
        val request = mock.takeRequest()
        assertTrue(request.path!!.contains("unstar.view"))
        assertFalse(repo.isFavorite(track.globalId))
    }

    @Test
    fun `远端失败本地不留假收藏`() = runBlocking {
        mock.enqueueHttp(500) // star 失败
        val coord = coordinator()

        assertThrows(LibraryRemoteOperationException::class.java) {
            runBlocking { coord.setTrackFavorite(track, true) }
        }
        assertFalse(repo.isFavorite(track.globalId))
    }

    @Test
    fun `未连接服务器直接抛 ServerNotConnected 不动本地`() = runBlocking {
        val orphan = registry.also { it.remove(serverId) }
        val coord = LibraryActionCoordinator(orphan, repo)

        assertThrows(Exception::class.java) {
            runBlocking { coord.setTrackFavorite(track, true) }
        }
        assertFalse(repo.isFavorite(track.globalId))
    }

    @Test
    fun `评分远端成功后本地记录`() = runBlocking {
        okDispatcher("setRating.view")
        val coord = coordinator()

        coord.setRating(track, 4)
        val request = mock.takeRequest()
        assertTrue(request.path!!.contains("setRating.view"))
        assertTrue(request.body.readUtf8().contains("rating=4"))
        assertEquals(4, db.annotationDao().rating(track.globalId.serialized))
    }

    @Test
    fun `专辑收藏走远端 Album star`() = runBlocking {
        okDispatcher("star.view")
        val coord = coordinator()
        val album = albumOf(serverId, "al1", "Album One")

        assertTrue(coord.toggleAlbumFavorite(album))
        val request = mock.takeRequest()
        assertTrue(request.body.readUtf8().contains("albumId=al1"))
        assertEquals(true, db.annotationDao().isFavorite(album.globalId.serialized, FavoriteKind.Album.name))
    }

    // ------------------------------------------------------------ 不喜欢（R4）

    @Test
    fun `不喜欢是纯本地状态 不依赖远端`() = runBlocking {
        val coord = coordinator()

        coord.toggleDisliked(track) // false → true

        assertTrue(repo.isDisliked(track.globalId))
        assertTrue(db.annotationDao().isDisliked(track.globalId.serialized))

        coord.toggleDisliked(track) // true → false
        assertFalse(repo.isDisliked(track.globalId))
    }

    @Test
    fun `设置不喜欢时先取消收藏 收藏与不喜欢互斥`() = runBlocking {
        okDispatcher("unstar.view")
        repo.setFavorite(track.globalId, FavoriteKind.Track, true)
        val coord = coordinator()

        coord.setDisliked(track, true)

        // 先 unstar（远端）→ 本地收藏清除 → 本地 dislike 落盘。
        val request = mock.takeRequest()
        assertTrue(request.path!!.contains("unstar.view"))
        assertFalse(repo.isFavorite(track.globalId))
        assertTrue(repo.isDisliked(track.globalId))
    }

    @Test
    fun `远端取消收藏失败时 dislike 仍落盘 收藏残留留给下次回流`() = runBlocking {
        mock.enqueueHttp(500) // unstar 失败
        repo.setFavorite(track.globalId, FavoriteKind.Track, true)
        val coord = coordinator()

        coord.setDisliked(track, true) // runCatching 吞掉远端失败，不抛

        assertTrue(repo.isDisliked(track.globalId))
        // 本地收藏残留（与 Apple 一致：`_ = await setFavorite` 忽略远端结果）。
        assertTrue(repo.isFavorite(track.globalId))
    }

    @Test
    fun `收藏已不喜欢的歌曲会清除不喜欢`() = runBlocking {
        okDispatcher("star.view")
        repo.setDisliked(track.globalId, true)
        val coord = coordinator()

        assertTrue(coord.setTrackFavorite(track, true))

        assertTrue(repo.isFavorite(track.globalId))
        assertFalse(repo.isDisliked(track.globalId))
    }
}
