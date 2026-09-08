// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.HomeLayoutPreference
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.HomeQuickEntry
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.PlaylistId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S3 首页数据链路：HomeLayoutPreference 归一化（补齐/去重/丢弃未知）
 * + Room 真实聚合查询（收藏/播放计数、下载曲目、30 天新增、常听艺人/专辑按播放量）。
 * 全部是真实 SQL，不允许 mock 数据。
 */
class HomeAggregateQueriesTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var repo: RoomCatalogRepository

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
    }

    private fun open(): RoomCatalogRepository {
        db = openDatabase()
        repo = repository(db)
        return repo
    }

    private suspend fun seedCatalog() {
        val sid = ServerId("server-a")
        repo.commitCatalogSnapshot(
            serverId = sid,
            artists = listOf(
                artistOf(sid, "ar1", "Artist One", albumCount = 2),
                artistOf(sid, "ar2", "Artist Two", albumCount = 1),
            ),
            albums = listOf(
                albumOf(sid, "al1", "Album One", artist = "Artist One", songCount = 3),
                albumOf(sid, "al2", "Album Two", artist = "Artist Two", songCount = 1),
            ),
            tracks = listOf(
                trackOf(sid, "t1", "Track One", artist = "Artist One", album = "Album One", albumId = "al1", artistId = "ar1"),
                trackOf(sid, "t2", "Track Two", artist = "Artist One", album = "Album One", albumId = "al1", artistId = "ar1"),
                trackOf(sid, "t3", "Track Three", artist = "Artist One", album = "Album One", albumId = "al1", artistId = "ar1"),
                trackOf(sid, "t4", "Track Four", artist = "Artist Two", album = "Album Two", albumId = "al2", artistId = "ar2"),
            ),
            genres = emptyList(),
            playlists = listOf(
                Playlist(PlaylistId("pl1"), sid, name = "Picks", trackIds = listOf(TrackId("t1"))),
            ),
        )
    }

    @Test
    fun `归一化_补齐注册表新模块并去重丢弃未知`() = runBlocking {
        open()
        val sid = ServerId("server-a")
        repo.upsertServer(server(id = sid))
        seedCatalog()

        // 造一份「旧配置」：缺失若干模块、重复、含未知 id。
        val legacy = HomeLayoutPreference(
            quickEntries = listOf(
                com.auralis.core.domain.HomeEntryPreference("Playlists", visible = true),
                com.auralis.core.domain.HomeEntryPreference("Playlists", visible = true), // 重复
                com.auralis.core.domain.HomeEntryPreference("Bogus", visible = true), // 未知
                com.auralis.core.domain.HomeEntryPreference("Favorites", visible = false),
            ),
            contentModules = listOf(
                com.auralis.core.domain.HomeEntryPreference("NeverPlayed", visible = true), // 默认关,但用户开了
                com.auralis.core.domain.HomeEntryPreference("Unknown", visible = true), // 丢弃
            ),
        ).normalized()

        assertEquals(
            listOf("Playlists", "Favorites", "MostPlayed"),
            legacy.quickEntries.map { it.id },
        )
        assertEquals(false, legacy.quickEntries.first { it.id == "Favorites" }.visible)
        // 内容组：显式项在前，注册表缺的模块按默认可见性补齐到末尾。
        assertEquals(HomeModuleId.entries.size, legacy.contentModules.size)
        assertEquals("NeverPlayed", legacy.contentModules.first().id)
        assertEquals(true, legacy.contentModules.first().visible)
        assertEquals(
            HomeModuleId.entries.map { it.name }.toSet(),
            legacy.contentModules.map { it.id }.toSet(),
        )
        // 缺失的 RandomSongs(默认开) 补到末尾且可见。
        val random = legacy.contentModules.first { it.id == HomeModuleId.RandomSongs.name }
        assertEquals(true, random.visible)
    }

    @Test
    fun `收藏与播放计数_多服务器隔离`() = runBlocking {
        open()
        val sidA = ServerId("server-a")
        val sidB = ServerId("server-b")
        repo.upsertServer(server(id = sidA))
        repo.upsertServer(server(id = sidB))
        seedCatalog()
        repo.commitCatalogSnapshot(
            serverId = sidB,
            artists = emptyList(),
            albums = emptyList(),
            tracks = listOf(trackOf(sidB, "bx", "B Track")),
            genres = emptyList(),
            playlists = emptyList(),
        )

        repo.setFavorite(GlobalId(sidA, "t1"), FavoriteKind.Track, true)
        repo.setFavorite(GlobalId(sidA, "t2"), FavoriteKind.Track, true)
        repo.setFavorite(GlobalId(sidB, "bx"), FavoriteKind.Track, true)
        repo.recordPlay(GlobalId(sidA, "t1"), completed = true)
        repo.recordPlay(GlobalId(sidA, "t1"), completed = true)
        repo.recordPlay(GlobalId(sidA, "t2"), completed = true)

        assertEquals(2, repo.favoriteCount(sidA))
        assertEquals(1, repo.favoriteCount(sidB))
        assertEquals(2, repo.playedTrackCount(sidA))
        assertEquals(0, repo.playedTrackCount(sidB))

        // 无服务器过滤 = 全部。
        assertEquals(3, repo.favoriteCount(null))
        assertEquals(2, repo.playedTrackCount(null))
    }

    @Test
    fun `常听艺人与专辑_按真实播放量聚合降序`() = runBlocking {
        open()
        val sid = ServerId("server-a")
        repo.upsertServer(server(id = sid))
        seedCatalog()
        // Artist One 三首各 1 次 = 3；Artist Two 一首 2 次 = 2。
        repo.recordPlay(GlobalId(sid, "t1"), completed = true)
        repo.recordPlay(GlobalId(sid, "t2"), completed = true)
        repo.recordPlay(GlobalId(sid, "t3"), completed = true)
        repo.recordPlay(GlobalId(sid, "t4"), completed = true)
        repo.recordPlay(GlobalId(sid, "t4"), completed = true)

        val artists = repo.homeTopArtists(sid, 10)
        assertEquals(2, artists.size)
        assertEquals("Artist One", artists[0].first.name)
        assertEquals(3, artists[0].second)
        assertEquals("Artist Two", artists[1].first.name)
        assertEquals(2, artists[1].second)

        val albums = repo.homeTopAlbums(sid, 10)
        assertEquals(2, albums.size)
        assertEquals("Album One", albums[0].first.title)
        assertEquals(3, albums[0].second)
        assertEquals("Album Two", albums[1].first.title)
        assertEquals(2, albums[1].second)

        // 接口版 topArtists/topAlbums 只投影实体。
        assertEquals(listOf("Artist One", "Artist Two"), repo.topArtists(sid, 10).map { it.name })
        assertEquals(listOf("Album One", "Album Two"), repo.topAlbums(sid, 10).map { it.title })
    }

    @Test
    fun `下载曲目_仅Downloaded状态且按完成倒序`() = runBlocking {
        open()
        val sid = ServerId("server-a")
        repo.upsertServer(server(id = sid))
        seedCatalog()
        repo.record(com.auralis.core.domain.DownloadRecord(GlobalId(sid, "t1"), com.auralis.core.domain.DownloadStatus.Downloaded))
        repo.record(com.auralis.core.domain.DownloadRecord(GlobalId(sid, "t2"), com.auralis.core.domain.DownloadStatus.Queued))
        repo.record(com.auralis.core.domain.DownloadRecord(GlobalId(sid, "t3"), com.auralis.core.domain.DownloadStatus.Downloaded))

        val downloaded = repo.downloadedTracks(sid, 10)
        assertEquals(setOf("t1", "t3"), downloaded.map { it.id.value }.toSet())
        assertTrue(downloaded.none { it.id.value == "t2" })
    }

    @Test
    fun `最近添加_30天窗口只含近期同步曲目`() = runBlocking {
        open()
        val sid = ServerId("server-a")
        repo.upsertServer(server(id = sid))
        seedCatalog()

        val within = repo.recentlyAddedWithin(sid, days = 30, limit = 50)
        // 全部曲目都是刚同步 → 应全部落入 30 天窗口。
        assertEquals(4, within.size)
        assertTrue(within.all { it.serverId == sid })
    }

    // ------------------------------------------------------------ 不喜欢硬排除（R4）

    @Test
    fun `随机播放硬排除不喜欢_自动发现语义`() = runBlocking {
        open()
        val sid = ServerId("server-a")
        repo.upsertServer(server(id = sid))
        seedCatalog()
        // t1 标记不喜欢：自动随机 / 收藏随机都不应再出现。
        repo.setDisliked(GlobalId(sid, "t1"), true)

        val random = repo.randomTracks(sid, limit = 100)
        assertTrue(random.isNotEmpty())
        assertTrue(random.none { it.id.value == "t1" })

        // 收藏随机：只收藏 t1（不喜欢）→ 结果必须为空；t2 收藏后可出且仍排除 t1。
        repo.setFavorite(GlobalId(sid, "t1"), FavoriteKind.Track, true)
        assertTrue(repo.favoriteRandom(sid, 10).isEmpty())

        repo.setFavorite(GlobalId(sid, "t2"), FavoriteKind.Track, true)
        val favRandom = repo.favoriteRandom(sid, 10)
        assertEquals(listOf("t2"), favRandom.map { it.id.value })
    }

    @Test
    fun `不喜欢集合与观察流按服务器隔离`() = runBlocking {
        open()
        val sidA = ServerId("server-a")
        val sidB = ServerId("server-b")
        repo.upsertServer(server(id = sidA))
        repo.upsertServer(server(id = sidB))
        repo.setDisliked(GlobalId(sidA, "t1"), true)

        assertEquals(setOf(GlobalId(sidA, "t1")), repo.dislikedIds(sidA))
        assertTrue(repo.dislikedIds(sidB).isEmpty())
        assertTrue(repo.isDisliked(GlobalId(sidA, "t1")))
        assertFalse(repo.isDisliked(GlobalId(sidB, "t1")))

        val snapshot = repo.observeDislikedIds(sidA).first()
        assertEquals(listOf(GlobalId(sidA, "t1")), snapshot)
    }
}
