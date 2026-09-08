// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.offline

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
abstract class OfflineTestBase {
    protected fun context(): Context = ApplicationProvider.getApplicationContext()

    protected fun track(serverId: String = "server-x", id: String = "1"): Track = Track(
        id = TrackId(id),
        serverId = ServerId(serverId),
        albumId = com.auralis.core.domain.AlbumId(""),
        artistId = com.auralis.core.domain.ArtistId(""),
        title = "T$id",
        artistName = "A",
        albumTitle = "B",
        durationSeconds = 10.0,
    )

    /**
     * 内存下载仓储：记录写入次数以便验证进度节流。
     *
     * DownloadManager 明确允许最多三路并发，因此测试替身本身也必须具备与 Room 相同的
     * 原子更新语义。旧实现对 StateFlow 做无锁 read-modify-write，三条下载同时 record()
     * 时会互相覆盖，表现成「8 条任务最终只剩 6/7 条 Downloaded」的随机 CI 失败，
     * 实际并不是 Semaphore 越界。所有写操作现在由同一 Mutex 串行化。
     */
    protected class FakeDownloadRepo : DownloadRepository {
        private val state = MutableStateFlow<List<DownloadRecord>>(emptyList())
        private val mutex = Mutex()
        var writes = 0
            private set

        override fun observe(globalId: GlobalId): Flow<DownloadRecord?> =
            state.map { records -> records.lastOrNull { it.globalId == globalId } }

        override fun observeAll(serverId: ServerId?): Flow<List<DownloadRecord>> =
            if (serverId == null) state else state.map { records ->
                records.filter { it.globalId.serverId == serverId }
            }

        override suspend fun localPath(globalId: GlobalId): String? =
            state.value.lastOrNull { it.globalId == globalId }?.localPath

        override suspend fun record(record: DownloadRecord) {
            mutex.withLock {
                writes++
                state.value = state.value.filterNot { it.globalId == record.globalId } + record
            }
        }

        override suspend fun remove(globalId: GlobalId) {
            mutex.withLock {
                state.value = state.value.filterNot { it.globalId == globalId }
            }
        }

        fun seed(record: DownloadRecord) {
            // seed 只在任务启动前的测试准备阶段调用，不与下载协程并发。
            state.value = state.value.filterNot { it.globalId == record.globalId } + record
        }

        suspend fun statusOf(globalId: GlobalId): DownloadStatus? =
            state.value.lastOrNull { it.globalId == globalId }?.status
    }
}
