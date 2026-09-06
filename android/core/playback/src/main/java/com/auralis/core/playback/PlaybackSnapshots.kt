package com.auralis.core.playback

import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.QueueEntryId
import com.auralis.core.domain.Track

/**
 * 高频播放状态（对应 Apple `PlaybackStore`）。
 *
 * position/buffer/state 每秒多次变化，只允许让播放器相关小范围重组；
 * 队列/目录等低频数据**绝不能**订阅这个 Flow。
 */
data class PlaybackSnapshot(
    val state: PlaybackState = PlaybackState.Idle,
    val entry: QueueEntry? = null,
    val track: Track? = null,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val isBuffering: Boolean = false,
    val speed: Float = 1f,
    val playMode: PlayMode = PlayMode.Sequential,
    val volume: Float = 1f,
    /** 拖拽过程中的暂定 seek 目标（松手才真正 seek）。 */
    val pendingSeekMs: Long? = null,
    /** 已下载（本地文件播放）。 */
    val isLocalSource: Boolean = false,
) {
    companion object {
        val Empty = PlaybackSnapshot()
    }
}

/**
 * 低频队列展示状态（对应 Apple `PlaybackQueuePresentationStore`）。
 *
 * 保存**当前激活窗口**的 entries + 身份游标；窗口外的大队列用
 * [windowStartLogicalIndex] + [totalCount] 表达，绝不让上万条目进入 UI 重组。
 */
data class QueueSnapshot(
    val entries: List<QueueEntry> = emptyList(),
    /** 当前激活窗口在逻辑队列中的起始下标。 */
    val windowStartLogicalIndex: Int = 0,
    val currentEntryId: QueueEntryId? = null,
    /** 当前项在窗口内的下标。 */
    val currentWindowIndex: Int? = null,
    val currentLogicalIndex: Int? = null,
    val totalCount: Int = 0,
    /** 窗口是否还在加载后续部分（逻辑队列 > 阈值时）。 */
    val hasMoreBehindWindow: Boolean = false,
) {
    val currentEntry: QueueEntry?
        get() = currentWindowIndex?.let { entries.getOrNull(it) }

    companion object {
        val Empty = QueueSnapshot()
    }
}

/**
 * 队列窗口化参数。逐值对齐 Apple `AuralisAppModel.swift:80-83`：
 * 逻辑队列 > 500 才窗口化；首屏物化 256（以当前曲 −64 起始）；
 * 窗口尾部剩余 ≤ 48 时追加 192；跳出窗口时以 index−64 重建。
 */
object QueueWindowing {
    const val LARGE_CONTEXT_THRESHOLD = 500
    const val LARGE_WINDOW_INITIAL = 256
    const val LARGE_WINDOW_REFILL_THRESHOLD = 48
    const val LARGE_WINDOW_REFILL_BATCH = 192
    const val WINDOW_CENTER_BACK = 64

    /** 返回激活窗口区间 [start, end)。 */
    fun initialWindow(total: Int, currentIndex: Int): IntRange {
        require(total >= 0)
        if (total <= LARGE_CONTEXT_THRESHOLD) return 0 until total
        val start = (currentIndex - WINDOW_CENTER_BACK).coerceAtLeast(0)
        val end = (start + LARGE_WINDOW_INITIAL).coerceAtMost(total)
        return start until end
    }

    /** 是否需要为逻辑队列补窗口。 */
    fun needsRefill(windowEndLogical: Int, total: Int): Boolean {
        if (total <= LARGE_CONTEXT_THRESHOLD) return false
        val tailRemaining = total - windowEndLogical
        return tailRemaining > 0 && tailRemaining <= LARGE_WINDOW_REFILL_THRESHOLD
    }

    /** 窗口重建：把中心对准给定逻辑下标。 */
    fun windowAround(total: Int, currentIndex: Int): IntRange = initialWindow(total, currentIndex)
}
