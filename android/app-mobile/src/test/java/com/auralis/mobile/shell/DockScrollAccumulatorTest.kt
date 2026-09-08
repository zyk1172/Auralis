// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class DockScrollAccumulatorTest {
    @Test
    fun `upward travel reaches compact only after threshold`() {
        val reducer = DockScrollAccumulator(thresholdPx = 44f)

        assertThat(reducer.consume(-20f)).isNull()
        assertThat(reducer.consume(-23f)).isNull()
        assertThat(reducer.consume(-1f)).isTrue()
    }

    @Test
    fun `downward travel reaches expanded only after threshold`() {
        val reducer = DockScrollAccumulator(thresholdPx = 44f)

        assertThat(reducer.consume(12f)).isNull()
        assertThat(reducer.consume(32f)).isFalse()
    }

    @Test
    fun `direction reversal discards the previous partial gesture`() {
        val reducer = DockScrollAccumulator(thresholdPx = 44f)

        assertThat(reducer.consume(-30f)).isNull()
        assertThat(reducer.consume(30f)).isNull()
        assertThat(reducer.consume(14f)).isFalse()
    }

    @Test
    fun `reset prevents stale travel from leaking into the next gesture`() {
        val reducer = DockScrollAccumulator(thresholdPx = 44f)

        assertThat(reducer.consume(-30f)).isNull()
        reducer.reset()
        assertThat(reducer.consume(-20f)).isNull()
        assertThat(reducer.consume(-24f)).isTrue()
    }

    @Test
    fun `non finite and zero deltas are ignored`() {
        val reducer = DockScrollAccumulator(thresholdPx = 44f)

        assertThat(reducer.consume(0f)).isNull()
        assertThat(reducer.consume(Float.NaN)).isNull()
        assertThat(reducer.consume(Float.POSITIVE_INFINITY)).isNull()
    }
}
