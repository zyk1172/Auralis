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
 * iOS `safeAreaInset` keeps the scroll position pinned to the same content edge when its inset
 * animates. Compose's lazy containers update their maximum scroll range when content padding
 * changes, but leave the current offset untouched. Without this compensation, expanding the Dock
 * after the user reached the end moves the last row underneath the player/navigation chrome.
 */
@Composable
fun LazyListState.rememberDockBottomReservation(bottomPadding: Dp) {
    val density = LocalDensity.current
    val latestPadding = rememberUpdatedState(bottomPadding)

    LaunchedEffect(this, density) {
        var previousPaddingPx = with(density) { latestPadding.value.toPx() }
        var preserveBottom = !canScrollForward

        snapshotFlow { latestPadding.value to !canScrollForward }
            .collect { (padding, atBottom) ->
                val nextPaddingPx = with(density) { padding.toPx() }
                val delta = nextPaddingPx - previousPaddingPx
                if (delta != 0f && preserveBottom) {
                    scrollBy(delta)
                    // Keep the anchor for every frame of the Dock animation. The scroll itself
                    // may briefly publish a layout update before the next padding frame arrives.
                    preserveBottom = true
                } else {
                    preserveBottom = atBottom
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

        snapshotFlow { latestPadding.value to !canScrollForward }
            .collect { (padding, atBottom) ->
                val nextPaddingPx = with(density) { padding.toPx() }
                val delta = nextPaddingPx - previousPaddingPx
                if (delta != 0f && preserveBottom) {
                    scrollBy(delta)
                    preserveBottom = true
                } else {
                    preserveBottom = atBottom
                }
                previousPaddingPx = nextPaddingPx
            }
    }
}
