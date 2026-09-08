// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.PlayMode
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * R3：播放导航/游标纯逻辑测试（顺序/随机/列表循环/单曲循环、上一首、
 * 删除/移动游标、失败续播、上一首阈值）。
 */
class PlaybackLogicTest {

    // ---------------------------------------------------------- next

    @Test
    fun `sequential advances within bounds and stops at end`() {
        assertThat(PlaybackLogic.nextTarget(PlayMode.Sequential, 0, 3)).isEqualTo(1)
        assertThat(PlaybackLogic.nextTarget(PlayMode.Sequential, 1, 3)).isEqualTo(2)
        assertThat(PlaybackLogic.nextTarget(PlayMode.Sequential, 2, 3)).isNull()
    }

    @Test
    fun `sequential from not-started -1 starts at first`() {
        assertThat(PlaybackLogic.nextTarget(PlayMode.Sequential, -1, 3)).isEqualTo(0)
    }

    @Test
    fun `repeatAll wraps to zero at end`() {
        assertThat(PlaybackLogic.nextTarget(PlayMode.RepeatAll, 2, 3)).isEqualTo(0)
        assertThat(PlaybackLogic.nextTarget(PlayMode.RepeatAll, 0, 3)).isEqualTo(1)
    }

    @Test
    fun `repeatOne targets self`() {
        assertThat(PlaybackLogic.nextTarget(PlayMode.RepeatOne, 5, 9)).isEqualTo(5)
    }

    @Test
    fun `shuffle picks a different index within bounds`() {
        repeat(50) {
            val target = PlaybackLogic.nextTarget(PlayMode.Shuffle, 2, 10)!!
            assertThat(target).isIn(0 until 10)
            assertThat(target).isNotEqualTo(2)
        }
    }

    @Test
    fun `shuffle with single item honours force flag`() {
        assertThat(PlaybackLogic.nextTarget(PlayMode.Shuffle, 0, 1, force = false)).isNull()
        assertThat(PlaybackLogic.nextTarget(PlayMode.Shuffle, 0, 1, force = true)).isEqualTo(0)
    }

    @Test
    fun `empty queue never advances`() {
        assertThat(PlaybackLogic.nextTarget(PlayMode.Sequential, -1, 0)).isNull()
        assertThat(PlaybackLogic.nextTarget(PlayMode.Shuffle, -1, 0)).isNull()
        assertThat(PlaybackLogic.nextTarget(PlayMode.RepeatAll, -1, 0)).isNull()
        assertThat(PlaybackLogic.nextTarget(PlayMode.RepeatOne, -1, 0)).isNull()
    }

    // ---------------------------------------------------------- previous

    @Test
    fun `previous steps back within bounds`() {
        assertThat(PlaybackLogic.previousTarget(PlayMode.Sequential, 2, 3)).isEqualTo(1)
        assertThat(PlaybackLogic.previousTarget(PlayMode.Sequential, 1, 3)).isEqualTo(0)
    }

    @Test
    fun `previous at first stops unless repeatAll wraps to last`() {
        assertThat(PlaybackLogic.previousTarget(PlayMode.Sequential, 0, 3)).isNull()
        assertThat(PlaybackLogic.previousTarget(PlayMode.Shuffle, 0, 3)).isNull()
        assertThat(PlaybackLogic.previousTarget(PlayMode.RepeatOne, 0, 3)).isNull()
        assertThat(PlaybackLogic.previousTarget(PlayMode.RepeatAll, 0, 3)).isEqualTo(2)
    }

    @Test
    fun `previous on empty queue returns null`() {
        assertThat(PlaybackLogic.previousTarget(PlayMode.RepeatAll, 0, 0)).isNull()
    }

    // ---------------------------------------------------------- restart threshold

    @Test
    fun `previous restarts track after threshold`() {
        assertThat(PlaybackLogic.shouldRestartInsteadOfPrevious(3_001L)).isTrue()
        assertThat(PlaybackLogic.shouldRestartInsteadOfPrevious(3_000L)).isFalse()
        assertThat(PlaybackLogic.shouldRestartInsteadOfPrevious(0L)).isFalse()
        assertThat(PlaybackLogic.PREVIOUS_RESTART_THRESHOLD_MS).isEqualTo(3_000L)
    }

    // ---------------------------------------------------------- cursor after remove

    @Test
    fun `remove before current shifts cursor back`() {
        assertThat(PlaybackLogic.currentAfterRemove(removedIndex = 0, current = 3)).isEqualTo(2)
    }

    @Test
    fun `remove at or after current keeps cursor`() {
        assertThat(PlaybackLogic.currentAfterRemove(removedIndex = 3, current = 3)).isEqualTo(3)
        assertThat(PlaybackLogic.currentAfterRemove(removedIndex = 5, current = 3)).isEqualTo(3)
    }

    // ---------------------------------------------------------- cursor after move

    @Test
    fun `moving the current item points cursor at target`() {
        assertThat(PlaybackLogic.currentAfterMove(from = 1, to = 4, current = 1)).isEqualTo(4)
    }

    @Test
    fun `moving an earlier item to or past current shifts cursor back`() {
        assertThat(PlaybackLogic.currentAfterMove(from = 0, to = 4, current = 3)).isEqualTo(2)
        assertThat(PlaybackLogic.currentAfterMove(from = 1, to = 3, current = 3)).isEqualTo(2)
    }

    @Test
    fun `moving a later item to or before current shifts cursor forward`() {
        assertThat(PlaybackLogic.currentAfterMove(from = 5, to = 0, current = 3)).isEqualTo(4)
        assertThat(PlaybackLogic.currentAfterMove(from = 5, to = 3, current = 3)).isEqualTo(4)
    }

    @Test
    fun `move without crossing current leaves cursor unchanged`() {
        assertThat(PlaybackLogic.currentAfterMove(from = 0, to = 1, current = 3)).isEqualTo(3)
        assertThat(PlaybackLogic.currentAfterMove(from = 6, to = 7, current = 3)).isEqualTo(3)
    }

    // ---------------------------------------------------------- auto-advance after failure

    @Test
    fun `failure auto-advance blocked by repeatOne or queue end`() {
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.RepeatOne, 2, 5)).isFalse()
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.Sequential, 4, 5)).isFalse()
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.Sequential, null, 5)).isTrue()
    }

    @Test
    fun `failure auto-advance allowed mid-queue in non-repeatOne modes`() {
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.Sequential, 2, 5)).isTrue()
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.Shuffle, 2, 5)).isTrue()
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.RepeatAll, 2, 5)).isTrue()
    }

    @Test
    fun `failure auto-advance stays conservative at queue end in every mode`() {
        // 失败路径比自然播完更保守：RepeatAll 在队尾也 pause，不自动绕回（引擎抽取前即如此）
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.RepeatAll, 4, 5)).isFalse()
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.Sequential, 4, 5)).isFalse()
        assertThat(PlaybackLogic.canAutoAdvanceAfterFailure(PlayMode.RepeatOne, 4, 5)).isFalse()
    }
}
