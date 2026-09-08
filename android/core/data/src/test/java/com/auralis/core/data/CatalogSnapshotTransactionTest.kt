// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.PlaylistId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.TrackId
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 目录快照提交（P0 第四项）：commitCatalogSnapshot 是单事务的一致性提交。
 * 全量替换不累积、playlist_tracks 关联一致、删除服务器不留半同步残留。
 */
class CatalogSnapshotTransactionTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var repo: RoomCatalogRepository

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
    }

    private fun open(): Pair<AuralisDatabase, RoomCatalogRepository> {
        db = openDatabase()
        repo = repository(db)
        return db to repo
    }

    private suspend fun commitA() {
        val sid = ServerId("server-a")
        repo.commitCatalogSnapshot(
            serverId = sid,
            artists = listOf(artistOf(sid, "ar1", "Artist One", albumCount = 1)),
            albums = listOf(albumOf(sid, "al1", "Album One", artist = "Artist One", songCount = 2)),
            tracks = listOf(
                trackOf(sid, "t1", "Track One", artist = "Artist One", album = "Album One", albumId = "al1"),
                trackOf(sid, "t2", "Track Two", artist = "Artist One", album = "Album One", albumId = "al1"),
            ),
            genres = listOf(genreOf("Rock", songCount = 2, serverId = sid)),
            playlists = listOf(
                Playlist(
                    id = PlaylistId("pl1"),
                    serverId = sid,
                    name = "Mix",
                    trackIds = listOf(TrackId("t1"), TrackId("t2")),
                    isReadOnly = false,
                ),
            ),
        )
    }

    @Test
    fun `快照提交后各表一致可查`() = runBlocking {
        val (db, repo) = open()
        val sid = ServerId("server-a")
        commitA()

        val stats = repo.stats(sid)
        assertEquals(1, stats.artistCount)
        assertEquals(1, stats.albumCount)
        assertEquals(2, stats.trackCount)
        assertEquals(1, stats.playlistCount)

        assertNotNull(repo.albumTracks(GlobalId(sid, "al1")))
        assertEquals(listOf("Track One", "Track Two"), repo.albumTracks(GlobalId(sid, "al1")).map { it.title })
        assertEquals(setOf("t1", "t2"), repo.playlistTrackGids(GlobalId(sid, "pl1")).map { it.substringAfter(':') }.toSet())

        // FTS 可搜。
        assertTrue(repo.search(sid, "Track", 50).songs.isNotEmpty())
        db.close()
    }

    @Test
    fun `重同步全量替换不累积`() = runBlocking {
        val (db, repo) = open()
        val sid = ServerId("server-a")
        commitA()

        // 服务器目录变小：只剩一首。
        repo.commitCatalogSnapshot(
            serverId = sid,
            artists = emptyList(),
            albums = emptyList(),
            tracks = listOf(trackOf(sid, "t9", "Sole Track")),
            genres = emptyList(),
            playlists = emptyList(),
        )

        assertEquals(0, repo.stats(sid).artistCount)
        assertEquals(0, repo.stats(sid).albumCount)
        assertEquals(1, repo.stats(sid).trackCount)
        assertEquals(0, repo.stats(sid).playlistCount)
        assertNull(repo.track(GlobalId(sid, "t1")))
        assertEquals(listOf("Sole Track"), repo.search(sid, "Sole", 50).songs.map { it.title })
        db.close()
    }

    @Test
    fun `删除服务器清空该服务器全部本地痕迹`() = runBlocking {
        val (db, repo) = open()
        val sidA = ServerId("server-a")
        val sidB = ServerId("server-b")
        commitA()
        repo.commitCatalogSnapshot(
            serverId = sidB,
            artists = emptyList(),
            albums = emptyList(),
            tracks = listOf(trackOf(sidB, "t1", "B Track")),
            genres = emptyList(),
            playlists = emptyList(),
        )
        repo.upsertServer(server(id = sidB, displayName = "B"))
        repo.recordPlay(GlobalId(sidB, "t1"), completed = true)

        repo.deleteServer(sidB)

        // B 全部消失：曲目/历史/服务器行。
        assertNull(repo.track(GlobalId(sidB, "t1")))
        assertNull(repo.servers().firstOrNull { it.id == sidB })
        // A 毫发无损。
        assertNotNull(repo.track(GlobalId(sidA, "t1")))
        assertEquals(1, repo.stats(sidA).artistCount)
        assertEquals(2, repo.stats(sidA).trackCount)
        db.close()
    }
}
