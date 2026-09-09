// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class PlayerUiPolicyTest {
    @Test
    fun `titles that fit or only need slight shrink stay static`() {
        assertThat(MarqueeLayoutPolicy.shouldScroll(textWidth = 280f, containerWidth = 300f)).isFalse()
        // 320 * 0.86 = 275.2, so 320pt still fits after the same 86% minimum scale used by Swift.
        assertThat(MarqueeLayoutPolicy.shouldScroll(textWidth = 320f, containerWidth = 300f)).isFalse()
    }

    @Test
    fun `truly oversized title scrolls`() {
        assertThat(MarqueeLayoutPolicy.shouldScroll(textWidth = 360f, containerWidth = 300f)).isTrue()
    }

    @Test
    fun `static scale never shrinks below Apple minimum`() {
        assertThat(MarqueeLayoutPolicy.staticScale(textWidth = 320f, containerWidth = 300f)).isWithin(0.001f).of(0.9375f)
        assertThat(MarqueeLayoutPolicy.staticScale(textWidth = 1000f, containerWidth = 300f)).isEqualTo(0.86f)
        assertThat(MarqueeLayoutPolicy.staticScale(textWidth = 250f, containerWidth = 300f)).isEqualTo(1f)
    }

    @Test
    fun `marquee uses ten dp per second with nine second floor`() {
        // density=2 => 180px = 90dp => exactly nine seconds.
        assertThat(MarqueeLayoutPolicy.durationMillis(distancePx = 180f, pixelsPerDp = 2f)).isEqualTo(9_000)
        // 300dp at 10dp/s => 30 seconds.
        assertThat(MarqueeLayoutPolicy.durationMillis(distancePx = 600f, pixelsPerDp = 2f)).isEqualTo(30_000)
    }

    @Test
    fun `clock formatting matches Apple minute second display`() {
        assertThat(formatClock(0)).isEqualTo("0:00")
        assertThat(formatClock(61_000)).isEqualTo("1:01")
        assertThat(formatClock(-5_000)).isEqualTo("0:00")
    }
}
