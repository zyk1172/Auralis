// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.connector.ServerClientRegistry
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomLyricsRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.TimedLyricLine
import com.auralis.core.domain.Track
import com.auralis.core.lyrics.LyricsServiceImpl
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * 歌词链路（P0 第八项）：
 * - RoomLyricsRepository 以 serverID+trackID 为 key（多服务器隔离）；
 * - LyricsServiceImpl 本地优先，未命中才走远端，成功后写回 Room。
 */
class LyricsRepositoryTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var store: RoomLyricsRepository
    private lateinit var vault: FakeVault
    private lateinit var registry: ServerClientRegistry
    private lateinit var mock: MockWebServer

    private val serverA = ServerId("server-a")
    private val serverB = ServerId("server-b")

    @Before
    fun setUp() {
        db = openDatabase()
        store = RoomLyricsRepository(db.annotationDao())
        vault = FakeVault()
        registry = ServerClientRegistry(vault)
        mock = MockWebServer(); mock.start()
        val account = server(id = serverA, displayName = "A", baseUrl = mock.url("/").toString(), username = "u")
        runBlocking { vault.store(account.credentialReference!!, "pw") }
        registry.registerResolved(registry.makeInternalEndpoint(account))
    }

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
        if (::mock.isInitialized) mock.shutdown()
    }

    private fun track(serverId: ServerId, remoteId: String): Track =
        trackOf(serverId, remoteId, "Title $remoteId", artist = "Artist", album = "Album")

    private fun document(serverId: ServerId, remoteId: String, text: String): LyricsDocument =
        LyricsDocument(
            globalId = GlobalId(serverId, remoteId),
            language = "zh",
            lines = listOf(TimedLyricLine(startTimeSeconds = 1.0, text = text)),
            isSynced = true,
        )

    @Test
    fun `存取往返且按服务器隔离`() = runBlocking {
        store.save(document(serverA, "123", "歌词 A"))
        store.save(document(serverB, "123", "歌词 B"))

        assertEquals("歌词 A", store.load(track(serverA, "123"))?.lines?.first()?.text)
        assertEquals("歌词 B", store.load(track(serverB, "123"))?.lines?.first()?.text)
        assertNull(store.load(track(ServerId("server-c"), "123")))
    }

    @Test
    fun `本地命中时不请求远端`() = runBlocking {
        store.save(document(serverA, "t1", "本地歌词"))
        val service = LyricsServiceImpl(store) { _ -> error("不应请求远端") }

        val result = service.lyricsFor(track(serverA, "t1"))
        assertEquals("本地歌词", result?.lines?.first()?.text)
        assertNull(mock.takeRequest(0, java.util.concurrent.TimeUnit.MILLISECONDS))
    }

    @Test
    fun `本地未命中时走远端结构化歌词并写回 Room`() = runBlocking {
        mock.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                val path = request.path.orEmpty()
                val body = if (path.contains("getLyricsBySongId")) {
                    SubsonicJson.ok(
                        "lyricsList" to """{"structuredLyrics":[{"lang":"zh","synced":true,"line":[{"start":1000,"value":"远端歌词"}]}]}""",
                    )
                } else {
                    SubsonicJson.pingOk
                }
                return MockResponse().setResponseCode(200).setBody(body)
            }
        }
        val service = LyricsServiceImpl(store) { t -> registry.client(t.serverId)?.lyricsFor(t) }

        val result = service.lyricsFor(track(serverA, "t1"))
        assertNotNull(result)
        assertEquals("远端歌词", result?.lines?.first()?.text)
        // 写回 Room：再次请求不再打网络。
        assertEquals("远端歌词", store.load(track(serverA, "t1"))?.lines?.first()?.text)
    }

    @Test
    fun `结构化为空时降级到纯文本歌词`() = runBlocking {
        mock.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                val path = request.path.orEmpty()
                val body = when {
                    path.contains("getLyricsBySongId") -> SubsonicJson.ok("lyricsList" to """{"structuredLyrics":[]}""")
                    path.contains("getLyrics") ->
                        SubsonicJson.ok("lyrics" to """{"value":"第一行\n第二行"}""")
                    else -> SubsonicJson.pingOk
                }
                return MockResponse().setResponseCode(200).setBody(body)
            }
        }
        val service = LyricsServiceImpl(store) { t -> registry.client(t.serverId)?.lyricsFor(t) }

        val result = service.lyricsFor(track(serverA, "t2"))
        assertEquals(listOf("第一行", "第二行"), result?.lines?.map { it.text })
    }
}
