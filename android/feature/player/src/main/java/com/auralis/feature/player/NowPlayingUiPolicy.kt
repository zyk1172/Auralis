// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import kotlin.math.abs

/** Pure counterparts of the iOS layout, page, artwork and lyrics policies. */
internal object NowPlayingUiPolicy {
    const val lyricsAutoHideDelayMs = 5_000L
    const val lyricsFollowResumeDelayMs = 5_000L

    fun usesLandscape(width: Float, height: Float) =
        width > 0f && height > 0f && width > height && width >= 600f

    fun landscapeHorizontalPadding(isTablet: Boolean) = if (isTablet) 32f else 20f

    fun landscapeColumnSpacing(isTablet: Boolean) = if (isTablet) 36f else 24f

    fun landscapeArtworkSide(width: Float, height: Float, isTablet: Boolean): Float {
        val contentWidth =
            (width - 2 * landscapeHorizontalPadding(isTablet) - landscapeColumnSpacing(isTablet))
                .coerceAtLeast(0f)
        return minOf(
            if (isTablet) 600f else 420f,
            contentWidth * if (isTablet) 0.50f else 0.48f,
            (height - if (isTablet) 64f else 48f).coerceAtLeast(0f),
        )
    }

    fun togglePage(current: PlayerTab, target: PlayerTab) =
        if (current == target) PlayerTab.Player else target

    fun artworkScale(isPlaying: Boolean) = if (isPlaying) 1f else 0.82f

    fun lyricsHiddenForSwipe(x: Float, y: Float): Boolean? =
        if (abs(y) >= 44f && abs(y) > abs(x)) y < 0f else null

    /** Limit prediction to the same 750ms window as iOS when publications stall. */
    fun interpolatedPositionMs(position: Long, elapsed: Long, isPlaying: Boolean, speed: Float): Long =
        if (isPlaying) position + (elapsed.coerceIn(0, 750) * speed).toLong() else position

    fun lineProgress(position: Double, start: Double?, next: Double?): Float? =
        if (start != null && next != null && next > start)
            ((position - start) / (next - start)).toFloat().coerceIn(0f, 1f)
        else null

    fun characterScale(index: Int, count: Int, progress: Float?): Float {
        if (count <= 0) return 1f
        if (progress == null) return 1.06f
        val influence = (1f + progress.coerceIn(0f, 1f) * (count - 1) - index).coerceIn(0f, 1f)
        return 1.02f + (1.1f - 1.02f) * influence
    }
}
