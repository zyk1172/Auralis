// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.connector

import com.auralis.core.domain.CatalogRepository
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.Track
import com.auralis.core.playback.PlaybackHistorySink

/**
 * 播放历史 / scrobble 协调器（P0 第六项）。
 *
 * 对接 Apple 语义：
 * - **开始播放**（occurrence 激活）：写 `lastPlayed` 并 `playCount + 1`；
 * - **自然播完**（STATE_ENDED）：只把 `completed` 置位（不再叠加 playCount），
 *   并向 OpenSubsonic `scrobble(submission=true)`；
 * - **手动切歌 / 播放失败**：不写 completed、不 scrobble；
 * - 同一 occurrence 自然播完**只记一次**——引擎侧的
 *   `STATE_ENDED` / `MediaItemTransition` / 窗口 refill 重复触发由这里的
 *   `started / completed` 幂等集合兜底。
 */
class PlaybackHistoryCoordinator(
    private val registry: ServerClientRegistry,
    private val catalog: CatalogRepository,
    private val scrobbleEnabled: Boolean = true,
) : PlaybackHistorySink {
    private val started = HashSet<String>()
    private val completed = HashSet<String>()

    override suspend fun onOccurrenceActivated(entry: QueueEntry, track: Track) {
        if (!started.add(entry.id.value)) return
        catalog.recordPlay(track.globalId, completed = false)
    }

    override suspend fun onOccurrenceCompleted(entry: QueueEntry, track: Track, playedMs: Long) {
        // 极端情况下没收到 activated（首次进入即播完）也要有历史记录。
        if (started.add(entry.id.value)) {
            catalog.recordPlay(track.globalId, completed = false)
        }
        if (!completed.add(entry.id.value)) return
        catalog.markCompleted(track.globalId)
        if (!scrobbleEnabled) return
        val client = registry.client(track.serverId) ?: return
        runCatching { client.scrobble(listOf(track.id.value), submission = true) }
    }
}
