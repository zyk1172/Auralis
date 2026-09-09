// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class MarqueeLayoutPolicyTest {
    @Test
    fun `text fitting container stays static`() {
        assertThat(MarqueeLayoutPolicy.shouldScroll(textWidth = 100f, containerWidth = 100f)).isFalse()
        assertThat(MarqueeLayoutPolicy.staticScale(textWidth = 100f, containerWidth = 100f)).isEqualTo(1f)
    }

    @Test
    fun `slightly oversized title shrinks instead of scrolling`() {
        assertThat(MarqueeLayoutPolicy.shouldScroll(textWidth = 110f, containerWidth = 100f)).isFalse()
        assertThat(MarqueeLayoutPolicy.staticScale(textWidth = 110f, containerWidth = 100f))
            .isWithin(0.0001f)
            .of(100f / 110f)
    }

    @Test
    fun `title exceeding Apple 86 percent fit threshold scrolls`() {
        assertThat(MarqueeLayoutPolicy.shouldScroll(textWidth = 117f, containerWidth = 100f)).isTrue()
    }

    @Test
    fun `marquee duration preserves Apple minimum nine seconds`() {
        // 100px at 2px/dp = 50dp; 10dp/s would be five seconds, so Apple clamps to nine.
        assertThat(MarqueeLayoutPolicy.durationMillis(distancePx = 100f, pixelsPerDp = 2f))
            .isEqualTo(9_000)
    }

    @Test
    fun `marquee duration uses ten dp per second for long overflow`() {
        // 400px at 2px/dp = 200dp → 20s at the Swift 10pt/s target speed.
        assertThat(MarqueeLayoutPolicy.durationMillis(distancePx = 400f, pixelsPerDp = 2f))
            .isEqualTo(20_000)
    }
}
