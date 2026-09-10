// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.PlayMode

/**
 * UI/system transport capabilities derived from the same semantics as [PlaybackLogic].
 *
 * Keeping these checks here prevents shells from treating queue adjacency as the whole contract:
 * previous can restart the current track after the restart threshold, RepeatAll wraps at both ends,
 * RepeatOne can explicitly restart the current occurrence, and Shuffle needs another candidate.
 */
object PlaybackCapabilities {
    fun canGoPrevious(playback: PlaybackSnapshot, queue: QueueSnapshot): Boolean {
        val current = queue.currentLogicalIndex ?: return false
        if (playback.track == null || queue.totalCount <= 0) return false
        if (playback.positionMs > PlaybackLogic.PREVIOUS_RESTART_THRESHOLD_MS) return true
        if (current > 0) return true
        return playback.playMode == PlayMode.RepeatAll
    }

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
