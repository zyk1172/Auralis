package com.auralis.core.data

import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 多服务器 FTS 隔离（P0 第四项）：
 * Server A 与 Server B 各有 remote TrackID=123，搜索必须互不串数据；
 * 重同步 B 只清 B 自己的索引，A 仍可搜到。
 */
class MultiServerFtsIsolationTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var repo: RoomCatalogRepository

    private fun open() {
        db = openDatabase()
        repo = repository(db)
    }

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
    }

    private suspend fun commitSnapshot(
        serverId: ServerId,
        tracks: List<Track>,
    ) {
        repo.commitCatalogSnapshot(
            serverId = serverId,
            artists = emptyList(),
            albums = emptyList(),
            tracks = tracks,
            genres = emptyList(),
            playlists = emptyList(),
        )
    }

    @Test
    fun `同 ID 曲目分属两服务器互不串库`() = runBlocking {
        open()
        val serverA = ServerId("server-a")
        val serverB = ServerId("server-b")
        val songA = trackOf(serverA, "123", "Song Alpha", artist = "Artist A")
        val songB = trackOf(serverB, "123", "Song Beta", artist = "Artist B")

        commitSnapshot(serverA, listOf(songA))
        commitSnapshot(serverB, listOf(songB))

        // 两首同 remoteId 曲目都存在且 gid 前缀正确隔离。
        assertNotNull(repo.track(GlobalId(serverA, "123")))
        assertNotNull(repo.track(GlobalId(serverB, "123")))

        // 搜索只命中各自服务器。
        assertEquals(listOf("Song Alpha"), repo.search(serverA, "Alpha", 50).songs.map { it.title })
        assertEquals(listOf("Song Beta"), repo.search(serverB, "Beta", 50).songs.map { it.title })
        assertTrue(repo.search(serverA, "Beta", 50).songs.isEmpty())
        assertTrue(repo.search(serverB, "Alpha", 50).songs.isEmpty())

        // 全库搜索两首都出。
        assertEquals(setOf("Song Alpha", "Song Beta"), repo.search(null, "Song", 50).songs.map { it.title }.toSet())
    }

    @Test
    fun `重同步 B 只清 B 的 FTS 索引`() = runBlocking {
        open()
        val serverA = ServerId("server-a")
        val serverB = ServerId("server-b")
        commitSnapshot(serverA, listOf(trackOf(serverA, "123", "Song Alpha")))
        commitSnapshot(serverB, listOf(trackOf(serverB, "123", "Song Beta")))

        // B 重同步：远端已变化（只剩 Song Gamma），必须只替换 B 自己的索引。
        commitSnapshot(serverB, listOf(trackOf(serverB, "456", "Song Gamma")))

        // B 旧曲目消失、新曲目可搜。
        assertNull(repo.track(GlobalId(serverB, "123")))
        assertEquals(listOf("Song Gamma"), repo.search(serverB, "Gamma", 50).songs.map { it.title })

        // A 的索引毫发无损。
        assertNotNull(repo.track(GlobalId(serverA, "123")))
        assertEquals(listOf("Song Alpha"), repo.search(serverA, "Alpha", 50).songs.map { it.title })
        assertEquals(listOf("Song Alpha"), repo.search(serverA, "Song", 50).songs.map { it.title })
    }

    @Test
    fun `删除 B 服务器不影响 A 的曲目与索引`() = runBlocking {
        open()
        val serverA = ServerId("server-a")
        val serverB = ServerId("server-b")
        commitSnapshot(serverA, listOf(trackOf(serverA, "123", "Song Alpha")))
        commitSnapshot(serverB, listOf(trackOf(serverB, "123", "Song Beta")))

        repo.deleteServer(serverB)

        assertNull(repo.track(GlobalId(serverB, "123")))
        assertNotNull(repo.track(GlobalId(serverA, "123")))
        assertEquals(listOf("Song Alpha"), repo.search(serverA, "Alpha", 50).songs.map { it.title })
        // 全库搜索不再包含 B。
        assertEquals(listOf("Song Alpha"), repo.search(null, "Song", 50).songs.map { it.title })
    }
}
