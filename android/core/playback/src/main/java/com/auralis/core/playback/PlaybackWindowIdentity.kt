// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

/**
 * Identity mapping between the currently materialized Media3 list and Auralis' logical queue.
 *
 * A single active item at logical index N must be represented as [N, N + 1), never as the desired
 * prefetch window. Otherwise Media3 index 0 is temporarily published as logical item 0 while the
 * neighbours are still being resolved, which causes a visible wrong-track flash during Next/Prev.
 */
internal object PlaybackWindowIdentity {
    fun currentOnly(logicalIndex: Int): IntRange {
        require(logicalIndex >= 0)
        return logicalIndex until (logicalIndex + 1)
    }

    fun logicalIndex(windowStart: Int, mediaItemIndex: Int): Int {
        require(windowStart >= 0)
        require(mediaItemIndex >= 0)
        return windowStart + mediaItemIndex
    }
}
