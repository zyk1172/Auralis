// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.PlayMode

/**
 * UI/system transport capabilities derived from the same semantics as [PlaybackLogic].
 *
 * Keeping these checks here prevents shells from treating queue adjacency as the whole contract.
 * Apple exposes Previous whenever a current track exists: the command either restarts the current
 * track, selects the physical previous occurrence, or wraps in RepeatAll. Next is mode-sensitive.
 */
object PlaybackCapabilities {
    fun canGoPrevious(playback: PlaybackSnapshot, queue: QueueSnapshot): Boolean =
        playback.track != null && queue.totalCount > 0 && queue.currentLogicalIndex != null

    fun canGoNext(playback: PlaybackSnapshot, queue: QueueSnapshot): Boolean {
        val current = queue.currentLogicalIndex ?: return false
        if (playback.track == null || queue.totalCount <= 0) return false
        return when (playback.playMode) {
            PlayMode.Sequential -> current < queue.totalCount - 1
            PlayMode.RepeatAll -> true
            PlayMode.RepeatOne -> true
            PlayMode.Shuffle -> queue.totalCount > 1
        }
    }
}
