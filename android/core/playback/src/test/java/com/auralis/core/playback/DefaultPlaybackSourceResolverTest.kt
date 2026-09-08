// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.ResolvedSource
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.StreamUrlProvider
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import com.google.common.truth.Truth.assertThat
import java.nio.file.Files
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Test

/**
 * R3：播放源解析决策测试（对应 Apple `resolvePlayableTrack`）。
 *
 * 决策链：本地完整缓存优先 → 存量 streamUrl 复用（非强制刷新）→
 * 即时解析（forceRefresh / 无存量）→ 拿不到 URL 则 Unavailable。
 */
class DefaultPlaybackSourceResolverTest {

    private val tempDir = Files.createTempDirectory("auralis-resolver-test")

    @After
    fun tearDown() {
        tempDir.toFile().deleteRecursively()
    }

    // ---------------------------------------------------------- fakes

    private class FakeDownloads(private val path: String?) : DownloadRepository {
        override fun observe(globalId: GlobalId): Flow<DownloadRecord?> = emptyFlow()
        override fun observeAll(serverId: ServerId?): Flow<List<DownloadRecord>> = emptyFlow()
        override suspend fun localPath(globalId: GlobalId): String? = path
        override suspend fun record(record: DownloadRecord) = Unit
        override suspend fun remove(globalId: GlobalId) = Unit
    }

    private fun resolver(
        downloadPath: String?,
        provider: StreamUrlProvider,
    ): DefaultPlaybackSourceResolver =
        DefaultPlaybackSourceResolver(
            downloads = FakeDownloads(downloadPath),
            streamUrlProvider = provider,
        )

    private fun realFile(content: String = "not-a-real-audio-bytes"): String {
        val file = tempDir.resolve("cached-${System.nanoTime()}.mp3").toFile()
        file.writeText(content)
        return file.absolutePath
    }

    private fun track(streamUrl: String? = null) = Track(
        id = TrackId("t1"),
        serverId = ServerId("srv"),
        albumId = AlbumId("al1"),
        artistId = ArtistId("ar1"),
        title = "Title",
        artistName = "Artist",
        albumTitle = "Album",
        durationSeconds = 200.0,
        streamUrl = streamUrl,
    )

    // ---------------------------------------------------------- tests

    @Test
    fun `complete local cache wins and provider is never consulted`() = runTest {
        var providerCalls = 0
        val local = realFile()
        val r = resolver(downloadPath = local) { _, _ ->
            providerCalls++
            "http://remote/should-not-be-used"
        }
        val result = r.resolve(track(streamUrl = "http://existing"))
        assertThat(result).isEqualTo(ResolvedSource.Local(local))
        assertThat(providerCalls).isEqualTo(0)
    }

    @Test
    fun `stale download entry pointing at missing file falls through to stream url`() = runTest {
        val missing = tempDir.resolve("gone.mp3").toString() // 未创建 → 不存在
        val r = resolver(downloadPath = missing) { _, _ -> "http://fresh" }
        val result = r.resolve(track(streamUrl = "http://existing"))
        assertThat(result).isEqualTo(ResolvedSource.Remote("http://existing"))
    }

    @Test
    fun `empty file on disk is treated as unusable and ignored`() = runTest {
        val empty = realFile(content = "") // length 0
        val r = resolver(downloadPath = empty) { _, _ -> "http://fresh" }
        val result = r.resolve(track(streamUrl = "http://existing"))
        assertThat(result).isEqualTo(ResolvedSource.Remote("http://existing"))
    }

    @Test
    fun `existing stream url reused when not force refreshing`() = runTest {
        var providerCalls = 0
        val r = resolver(downloadPath = null) { _, _ ->
            providerCalls++
            "http://re-resolved"
        }
        val result = r.resolve(track(streamUrl = "http://existing"), forceRefresh = false)
        assertThat(result).isEqualTo(ResolvedSource.Remote("http://existing"))
        assertThat(providerCalls).isEqualTo(0)
    }

    @Test
    fun `force refresh bypasses stored url and re-resolves`() = runTest {
        val r = resolver(downloadPath = null) { _, force ->
            assertThat(force).isTrue()
            "http://re-resolved"
        }
        val result = r.resolve(track(streamUrl = "http://existing"), forceRefresh = true)
        assertThat(result).isEqualTo(ResolvedSource.Remote("http://re-resolved"))
    }

    @Test
    fun `provider returning null yields unavailable`() = runTest {
        val r = resolver(downloadPath = null) { _, _ -> null }
        assertThat(r.resolve(track(streamUrl = null))).isEqualTo(ResolvedSource.Unavailable)
    }

    @Test
    fun `provider returning blank yields unavailable`() = runTest {
        val r = resolver(downloadPath = null) { _, _ -> "" }
        assertThat(r.resolve(track(streamUrl = null))).isEqualTo(ResolvedSource.Unavailable)
    }
}
