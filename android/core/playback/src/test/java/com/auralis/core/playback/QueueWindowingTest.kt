// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * R3：队列窗口化测试（逐值对齐 Apple `AuralisAppModel.swift:80-83`）：
 * 逻辑队列 >500 才窗口化；首屏物化 256（当前曲 −64 起始）；尾部剩余 ≤48 补 192。
 */
class QueueWindowingTest {

    @Test
    fun `small queue materialises whole range regardless of windowing`() {
        assertThat(QueueWindowing.initialWindow(total = 0, currentIndex = 0)).isEqualTo(0 until 0)
        assertThat(QueueWindowing.initialWindow(total = 1, currentIndex = 0)).isEqualTo(0 until 1)
        assertThat(QueueWindowing.initialWindow(total = 500, currentIndex = 250)).isEqualTo(0 until 500)
    }

    @Test
    fun `large queue centres window 64 behind current with 256 initial`() {
        val window = QueueWindowing.initialWindow(total = 1_000, currentIndex = 500)
        assertThat(window.first).isEqualTo(500 - QueueWindowing.WINDOW_CENTER_BACK) // 436
        assertThat(window.last - window.first + 1).isEqualTo(QueueWindowing.LARGE_WINDOW_INITIAL)
        assertThat(window).isEqualTo(436 until 692)
    }

    @Test
    fun `large queue at head starts window at zero`() {
        assertThat(QueueWindowing.initialWindow(total = 1_000, currentIndex = 0))
            .isEqualTo(0 until QueueWindowing.LARGE_WINDOW_INITIAL)
    }

    @Test
    fun `large queue near tail clamps window end to total`() {
        val window = QueueWindowing.initialWindow(total = 1_000, currentIndex = 999)
        assertThat(window.last).isEqualTo(999)
        assertThat(window.first).isEqualTo(999 - QueueWindowing.WINDOW_CENTER_BACK)
    }

    @Test
    fun `window clamps start to zero near head center`() {
        val window = QueueWindowing.initialWindow(total = 1_000, currentIndex = 10)
        assertThat(window.first).isEqualTo(0)
    }

    @Test
    fun `needsRefill only when tail remaining small and queue large`() {
        // 大队列 + 尾剩 ≤48 → 需补
        assertThat(QueueWindowing.needsRefill(windowEndLogical = 952, total = 1_000)).isTrue()
        assertThat(QueueWindowing.needsRefill(windowEndLogical = 956, total = 1_000)).isTrue()
        // 尾剩大 → 无需补
        assertThat(QueueWindowing.needsRefill(windowEndLogical = 700, total = 1_000)).isFalse()
        // 尾已尽 → 无需补
        assertThat(QueueWindowing.needsRefill(windowEndLogical = 1_000, total = 1_000)).isFalse()
        // 小队列恒不窗口化
        assertThat(QueueWindowing.needsRefill(windowEndLogical = 480, total = 500)).isFalse()
    }

    @Test
    fun `windowAround equals initialWindow semantics`() {
        assertThat(QueueWindowing.windowAround(total = 800, currentIndex = 300))
            .isEqualTo(QueueWindowing.initialWindow(total = 800, currentIndex = 300))
    }

    @Test
    fun `invalid total rejected`() {
        val e = runCatching { QueueWindowing.initialWindow(total = -1, currentIndex = 0) }.exceptionOrNull()
        assertThat(e).isInstanceOf(IllegalArgumentException::class.java)
    }
}
