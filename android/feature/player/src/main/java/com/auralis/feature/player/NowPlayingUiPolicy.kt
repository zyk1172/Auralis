// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import kotlin.math.abs

/** Pure counterparts of the iOS layout, page, artwork and lyrics policies. */
internal object NowPlayingUiPolicy {
    const val lyricsAutoHideDelayMs = 5_000L

    fun usesLandscape(width: Float, height: Float) =
        width > 0f && height > 0f && width > height && width >= 600f

    fun landscapeArtworkSide(width: Float, height: Float, isTablet: Boolean): Float =
        minOf(if (isTablet) 520f else 360f, width * if (isTablet) 0.40f else 0.42f, height * 0.78f)
            .coerceAtLeast(0f)

    fun togglePage(current: PlayerTab, target: PlayerTab) =
        if (current == target) PlayerTab.Player else target

    fun artworkScale(isPlaying: Boolean) = if (isPlaying) 1f else 0.82f

    fun lyricsHiddenForSwipe(x: Float, y: Float): Boolean? =
        if (abs(y) >= 44f && abs(y) > abs(x)) y < 0f else null

    fun lineProgress(position: Double, start: Double?, next: Double?): Float? =
        if (start != null && next != null && next > start)
            ((position - start) / (next - start)).toFloat().coerceIn(0f, 1f)
        else null

    fun characterScale(index: Int, count: Int, progress: Float?): Float {
        if (count <= 0) return 1f
        if (progress == null) return 1.06f
        val influence = (1f - abs(index - progress * (count - 1))).coerceAtLeast(0f)
        return 1.02f + 0.10f * influence
    }
}
