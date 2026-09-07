package com.auralis.core.playback

import com.auralis.core.domain.PlayMode

/**
 * R3（第三方审查 P0-3）：播放决策纯逻辑。
 *
 * 从 [AuralisPlaybackEngine] 抽出的**确定性计算**（不接触 Media3/可变状态）：
 * - 上一首/下一首的目标下标（顺序/随机/列表循环/单曲循环）
 * - 删除/移动 occurrence 后的逻辑游标校正
 * - 流失败后能否自动续播
 * - 播放位置是否应「回到曲首」而非切上一首
 *
 * 这些是播放核心最容易被改坏的决策点；抽出后由纯 JVM 单测覆盖，
 * engine 内部改为调用本对象（行为与抽取前逐行等价）。
 */
internal object PlaybackLogic {

    /**
     * 用户 next / 自动下一首 / shuffle 的目标逻辑下标；返回 null 表示不切换。
     *
     * 语义（与 engine 抽取前等价）：
     * - Sequential：仅当下标+1 < total 时前进；
     * - RepeatAll：到尾回 0；
     * - RepeatOne：目标=自身（由引擎特判 seek(0) 重播）；
     * - Shuffle：在「非当前」集合中随机；集合为空（只有 1 首）时，
     *   force=true（自然播完触发的自动续播）才重播自己，否则不切换。
     */
    fun nextTarget(
        mode: PlayMode,
        currentLogical: Int,
        total: Int,
        force: Boolean = false,
    ): Int? {
        if (total <= 0) return null
        return when (mode) {
            PlayMode.Shuffle -> {
                val candidates = (0 until total).filter { it != currentLogical }
                when {
                    candidates.isNotEmpty() -> candidates.random()
                    force -> (0 until total).filter { it != currentLogical }.randomOrNull() ?: currentLogical
                    else -> null
                }
            }

            PlayMode.RepeatOne -> currentLogical

            PlayMode.RepeatAll -> {
                val next = currentLogical + 1
                if (next < total) next else 0
            }

            PlayMode.Sequential -> {
                val next = currentLogical + 1
                if (next < total) next else null
            }
        }
    }

    /**
     * 上一首目标下标；返回 null 表示不切换。
     * 仅 RepeatAll 允许从队首绕到队尾；其余到顶即停。
     */
    fun previousTarget(mode: PlayMode, currentLogical: Int, total: Int): Int? {
        if (total <= 0) return null
        val previous = currentLogical - 1
        return if (previous >= 0) {
            previous
        } else if (mode == PlayMode.RepeatAll) {
            total - 1
        } else {
            null
        }
    }

    /** 上一首按键的阈值判断：播放已超过该时长 → 回到曲首，而非切上一首。 */
    fun shouldRestartInsteadOfPrevious(positionMs: Long, thresholdMs: Long = PREVIOUS_RESTART_THRESHOLD_MS): Boolean =
        positionMs > thresholdMs

    /** 删除非当前 occurrence 后的游标校正（被删项在当前项之前才前移）。 */
    fun currentAfterRemove(removedIndex: Int, current: Int): Int =
        if (removedIndex < current) current - 1 else current

    /** 移动 occurrence 后的游标校正（三种情形：被移项即当前 / 从当前前移到 ≥当前 / 从当前后移到 ≤当前）。 */
    fun currentAfterMove(from: Int, to: Int, current: Int): Int = when {
        from == current -> to
        from < current && to >= current -> current - 1
        from > current && to <= current -> current + 1
        else -> current
    }

    /** 流失败重试耗尽后能否自动续播下一首（RepeatOne 或已到队尾时不能）。 */
    fun canAutoAdvanceAfterFailure(mode: PlayMode, currentLogical: Int?, total: Int): Boolean =
        mode != PlayMode.RepeatOne && (currentLogical ?: -1) < total - 1

    const val PREVIOUS_RESTART_THRESHOLD_MS = 3_000L
}
