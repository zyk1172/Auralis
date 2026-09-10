// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.designsystem

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp

/**
 * Keeps the last visible content anchored while the floating Dock changes height.
 *
 * Compensation is only applied while the user is not actively scrolling. This matters when a Dock
 * animation overlaps a new drag: programmatic padding compensation must immediately yield to user
 * input instead of pulling the list back toward the old bottom anchor.
 */
@Composable
fun LazyListState.rememberDockBottomReservation(bottomPadding: Dp) {
    val density = LocalDensity.current
    val latestPadding = rememberUpdatedState(bottomPadding)

    LaunchedEffect(this, density) {
        var previousPaddingPx = with(density) { latestPadding.value.toPx() }
        var preserveBottom = !canScrollForward

        snapshotFlow { Triple(latestPadding.value, !canScrollForward, isScrollInProgress) }
            .collect { (padding, atBottom, scrolling) ->
                val nextPaddingPx = with(density) { padding.toPx() }
                val delta = nextPaddingPx - previousPaddingPx
                when {
                    scrolling -> preserveBottom = false
                    delta != 0f && preserveBottom -> scrollBy(delta)
                    else -> preserveBottom = atBottom
                }
                previousPaddingPx = nextPaddingPx
            }
    }
}

/** Grid counterpart of [LazyListState.rememberDockBottomReservation]. */
@Composable
fun LazyGridState.rememberDockBottomReservation(bottomPadding: Dp) {
    val density = LocalDensity.current
    val latestPadding = rememberUpdatedState(bottomPadding)

    LaunchedEffect(this, density) {
        var previousPaddingPx = with(density) { latestPadding.value.toPx() }
        var preserveBottom = !canScrollForward

        snapshotFlow { Triple(latestPadding.value, !canScrollForward, isScrollInProgress) }
            .collect { (padding, atBottom, scrolling) ->
                val nextPaddingPx = with(density) { padding.toPx() }
                val delta = nextPaddingPx - previousPaddingPx
                when {
                    scrolling -> preserveBottom = false
                    delta != 0f && preserveBottom -> scrollBy(delta)
                    else -> preserveBottom = atBottom
                }
                previousPaddingPx = nextPaddingPx
            }
    }
}
