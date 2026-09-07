package com.auralis.core.playback

import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.Track

/**
 * 播放事件下沉接口（P0 第六项）。
 *
 * 引擎只负责**识别真实 occurrence 生命周期**，不直接碰 Room：
 * 由 core:data 的 `PlaybackHistoryCoordinator` 实现写历史与 scrobble。
 *
 * 去重规则（避免 STATE_ENDED + MediaItemTransition + 窗口 refill 重复计数）：
 * 同一个 `QueueEntry.id` 的 activated 只发一次；completed 只发一次。
 */
interface PlaybackHistorySink {
    /** occurrence 开始播放（用户点击/自动下一首/队首起播都算）。 */
    suspend fun onOccurrenceActivated(entry: QueueEntry, track: Track)

    /** occurrence **自然播完**（STATE_ENDED）。手动切歌/失败不算。 */
    suspend fun onOccurrenceCompleted(entry: QueueEntry, track: Track, playedMs: Long)
}
