// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.offline

import com.auralis.core.domain.DownloadStatus
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
 * 下载并发（P0 第七项）：
 * - 全局最多 3 个并发（Semaphore 真实限制，不是注释）；
 * - 8 个任务排队执行，最终全部 Downloaded；
 * - 进度写库节流：不是每个 buffer 都打一次 Room。
 */
class DownloadConcurrencyTest : OfflineTestBase() {
    private lateinit var server: MockWebServer
    private lateinit var repo: FakeDownloadRepo
    private lateinit var manager: DownloadManager

    @Before
    fun setUp() {
        server = MockWebServer(); server.start()
        repo = FakeDownloadRepo()
        manager = DownloadManager(context(), repo, urlFactory = { "${server.url("/")}file" })
    }

    @After
    fun tearDown() {
        manager.release()
        server.shutdown()
    }

    private fun delayedBody(size: Int) {
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse =
                MockResponse()
                    .setResponseCode(200)
                    .setHeader("Content-Length", size.toString())
                    .setBody(Buffer().apply { write(ByteArray(size)) })
                    .throttleBody(64 * 1024, 60, TimeUnit.MILLISECONDS)
        }
    }

    @Test
    fun `八条任务并发不超过三`() = runBlocking {
        delayedBody(128 * 1024)

        repeat(8) { index -> manager.enqueue(track(id = "$index")) }

        // 第一秒密集采样并发峰值（每 10ms 一次，确保抓到 3 路并行窗口）。
        var maxRunning = 0
        repeat(100) {
            maxRunning = maxOf(maxRunning, manager.runningCount.value)
            delay(10)
        }
        // 等待全部完成：预算放宽到 15s，避免多模块并行测试时机器负载导致的时序抖动。
        val deadline = System.currentTimeMillis() + 15_000
        var downloaded = 0
        while (System.currentTimeMillis() < deadline) {
            downloaded = repo.observeAll(null).first().count { it.status == DownloadStatus.Downloaded }
            if (downloaded == 8) break
            delay(50)
        }

        if (downloaded != 8) {
            println("下载未完成诊断: ${repo.observeAll(null).first().map { "${it.globalId.serialized}=${it.status}" }}")
        }
        assertTrue("应观察到并发 >1，实际 maxRunning=$maxRunning", maxRunning > 1)
        assertTrue("并发上限应为 3，实际 maxRunning=$maxRunning", maxRunning <= DownloadManager.MAX_CONCURRENT_DOWNLOADS)
        assertEquals(8, downloaded)
    }

    @Test
    fun `进度写库被节流`() = runBlocking {
        delayedBody(2 * 1024 * 1024)
        manager.enqueue(track(id = "big"))

        repeat(120) {
            if (repo.statusOf(track(id = "big").globalId) == DownloadStatus.Downloaded) return@repeat
            delay(50)
        }
        assertEquals(DownloadStatus.Downloaded, repo.statusOf(track(id = "big").globalId))
        // 2MB / 8KB ≈ 256 个 buffer；节流后写库次数应明显少于 buffer 数。
        assertTrue("写库次数应远小于 buffer 数（实际 ${repo.writes}）", repo.writes < 200)
    }
}
