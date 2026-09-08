// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.connector.PlaybackHistoryCoordinator
import com.auralis.core.data.connector.ServerClientRegistry
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 播放历史 / scrobble（P0 第六项）：
 * 开始播放 → lastPlayed + playCount；自然播完 → completed + 一次 scrobble；
 * 重复事件不重复计数；手动切歌不 completed；手动切歌不 completed；无客户端不崩。
 */
class PlaybackHistoryCoordinatorTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var repo: RoomCatalogRepository
    private lateinit var vault: FakeVault
    private lateinit var registry: ServerClientRegistry
    private lateinit var mock: MockWebServer

    private val serverId = ServerId("server-history")
    private lateinit var track: Track

    @Before
    fun setUp() {
        db = openDatabase()
        repo = repository(db)
        vault = FakeVault()
        registry = ServerClientRegistry(vault)
        mock = MockWebServer(); mock.start()

        val account = server(
            id = serverId,
            displayName = "Srv",
            baseUrl = mock.url("/").toString(),
            username = "u",
        )
        runBlocking { vault.store(account.credentialReference!!, "pw") }
        registry.registerResolved(registry.makeInternalEndpoint(account))
        track = trackOf(serverId, "t1", "Track One")
    }

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
        if (::mock.isInitialized) mock.shutdown()
    }

    private fun coordinator() = PlaybackHistoryCoordinator(registry, repo)

    private suspend fun historyOf(): Triple<Long?, Int, Boolean> {
        val entity = db.annotationDao().history(GlobalId(serverId, "t1").serialized)
        return Triple(entity?.lastPlayed, entity?.playCount ?: 0, entity?.completed ?: false)
    }

    @Test
    fun `开始播放写 lastPlayed 与 playCount`() = runBlocking {
        val coord = coordinator()
        val entry = QueueEntry.of(track)

        coord.onOccurrenceActivated(entry, track)

        val (lastPlayed, playCount, completed) = historyOf()
        assertTrue((lastPlayed ?: 0) > 0)
        assertEquals(1, playCount)
        assertFalse(completed)
    }

    @Test
    fun `自然播完只置 completed 不叠加 playCount 且只 scrobble 一次`() = runBlocking {
        mock.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse =
                MockResponse().setResponseCode(200).setBody(SubsonicJson.pingOk)
        }
        val coord = coordinator()
        val entry = QueueEntry.of(track)

        coord.onOccurrenceActivated(entry, track)
        coord.onOccurrenceCompleted(entry, track, 180_000)
        // 引擎侧重复事件：STATE_ENDED + transition + 窗口 refill。
        coord.onOccurrenceActivated(entry, track)
        coord.onOccurrenceCompleted(entry, track, 180_000)
        coord.onOccurrenceCompleted(entry, track, 180_000)

        val (_, playCount, completed) = historyOf()
        assertEquals(1, playCount)
        assertTrue(completed)

        // 只向服务器 scrobble 一次。
        var scrobbles = 0
        while (true) {
            val req = mock.takeRequest(0, java.util.concurrent.TimeUnit.MILLISECONDS) ?: break
            if (req.path!!.contains("scrobble.view")) scrobbles++
        }
        assertEquals(1, scrobbles)
    }

    @Test
    fun `手动切歌不算完成也不 scrobble`() = runBlocking {
        val coord = coordinator()
        val first = QueueEntry.of(track)

        coord.onOccurrenceActivated(first, track)
        // 切到下一个 occurrence：只激活新的，不 completed 旧的。
        coord.onOccurrenceActivated(QueueEntry.of(track), track)

        val (_, playCount, completed) = historyOf()
        assertEquals(2, playCount) // 两次 occurrence 各计一次
        assertFalse(completed)
        assertNull(mock.takeRequest(0, java.util.concurrent.TimeUnit.MILLISECONDS)?.path)
    }

    @Test
    fun `没有可用客户端时只写本地不抛错`() = runBlocking {
        val orphanRegistry = ServerClientRegistry(vault)
        val coord = PlaybackHistoryCoordinator(orphanRegistry, repo)
        val entry = QueueEntry.of(track)

        coord.onOccurrenceActivated(entry, track)
        coord.onOccurrenceCompleted(entry, track, 10_000)

        val (_, playCount, completed) = historyOf()
        assertEquals(1, playCount)
        assertTrue(completed)
    }
}
