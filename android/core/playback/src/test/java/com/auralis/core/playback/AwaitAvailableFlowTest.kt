// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Test

/**
 * R3：冷启动等待语义测试（P0-1「首击必达」的等待原语）。
 *
 * [awaitAvailableFlow] 等待引擎可用标记从 false → true；
 * 覆盖：已就绪直接返回 / 未就绪等待后返回 / 超时抛 [TimeoutCancellationException]。
 */
class AwaitAvailableFlowTest {

    @Test
    fun `returns immediately when already available`() = runTest {
        val available = MutableStateFlow(true)
        awaitAvailableFlow(available, timeoutMs = 1_000)
        assertThat(available.value).isTrue()
    }

    @Test
    fun `returns once availability flips to true`() = runTest {
        val available = MutableStateFlow(false)
        // 先在后台把标记置 true，模拟引擎就绪
        launch {
            delay(50)
            available.value = true
        }
        awaitAvailableFlow(available, timeoutMs = 1_000)
        assertThat(available.value).isTrue()
    }

    @Test
    fun `throws TimeoutCancellationException when never ready`() = runTest {
        val available = MutableStateFlow(false)
        var threw = false
        try {
            awaitAvailableFlow(available, timeoutMs = 100)
        } catch (_: TimeoutCancellationException) {
            threw = true
        }
        assertThat(threw).isTrue()
    }
}
