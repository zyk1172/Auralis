// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.offline

import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * 冷启动水合（P0 第七项）：
 * 进程启动恢复 Queued/Downloading 记录时，必须走同一个三并发调度器，
 * 不能把上百条任务同时 launch。
 */
class DownloadHydrationTest : OfflineTestBase() {
    private lateinit var server: MockWebServer
    private lateinit var repo: FakeDownloadRepo
    private lateinit var manager: DownloadManager

    private val serverId = ServerId("server-x")

    @Before
    fun setUp() {
        server = MockWebServer(); server.start()
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse =
                MockResponse()
                    .setResponseCode(200)
                    .setHeader("Content-Length", (64 * 1024).toString())
                    .setBody(Buffer().apply { write(ByteArray(64 * 1024)) })
                    .throttleBody(32 * 1024, 60, TimeUnit.MILLISECONDS)
        }
        repo = FakeDownloadRepo()
        manager = DownloadManager(context(), repo, urlFactory = { "${server.url("/")}file" })
    }

    @After
    fun tearDown() {
        manager.release()
        server.shutdown()
    }

    private fun seedQueued(count: Int) {
        repeat(count) { index ->
            repo.seed(
                DownloadRecord(
                    globalId = GlobalId(serverId, "$index"),
                    status = DownloadStatus.Queued,
                    progress = 0f,
                    localPath = null,
                ),
            )
        }
    }

    @Test
    fun `水合恢复十二条任务仍受并发上限约束`() = runBlocking {
        seedQueued(12)

        manager.hydrate { gid -> track(serverId = gid.serverId.value, id = gid.remoteId) }

        // 第一秒密集采样并发峰值（每 10ms 一次）。
        var maxRunning = 0
        repeat(100) {
            maxRunning = maxOf(maxRunning, manager.runningCount.value)
            delay(10)
        }
        // 等待全部完成：预算放宽到 15s，避免并行负载/首轮 Robolectric 预热导致的抖动。
        val deadline = System.currentTimeMillis() + 15_000
        var downloaded = 0
        while (System.currentTimeMillis() < deadline) {
            downloaded = repo.observeAll(null).first().count { it.status == DownloadStatus.Downloaded }
            if (downloaded == 12) break
            delay(50)
        }

        val statuses = repo.observeAll(null).first().associate { it.globalId.remoteId to it.status }
        assertTrue("水合也应并发 >1，实际 $maxRunning", maxRunning > 1)
        assertTrue("水合并发上限应为 3，实际 $maxRunning", maxRunning <= DownloadManager.MAX_CONCURRENT_DOWNLOADS)
        assertEquals(
            "12 条都应下载完成，实际：$statuses",
            12,
            downloaded,
        )
    }

    @Test
    fun `水合时找不到曲目的记录标记为失败而不是永久 downloading`() = runBlocking {
        repo.seed(
            DownloadRecord(
                globalId = GlobalId(serverId, "ghost"),
                status = DownloadStatus.Downloading,
                progress = 0.4f,
                localPath = null,
            ),
        )

        manager.hydrate { null }

        assertEquals(DownloadStatus.Failed, repo.statusOf(GlobalId(serverId, "ghost")))
    }
}
