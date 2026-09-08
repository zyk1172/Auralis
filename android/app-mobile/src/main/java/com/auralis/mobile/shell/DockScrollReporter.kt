// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Velocity
import com.auralis.core.designsystem.AuralisChrome
import kotlin.math.abs

/**
 * Android counterpart of Apple `BottomDockScrollReportingModifier`.
 *
 * The reporter observes vertical scroll already consumed by the child list instead of installing
 * a competing pointer gesture. Horizontal shelves therefore keep their gestures, list taps remain
 * untouched, and a deliberate 44dp vertical travel resolves to one terminal dock state.
 */
fun Modifier.reportsBottomDockScroll(
    enabled: Boolean,
    onTerminalRequest: (compact: Boolean) -> Unit,
): Modifier = composed {
    if (!enabled) return@composed this

    val density = LocalDensity.current
    val thresholdPx = with(density) { AuralisChrome.dockGestureThreshold.toPx() }
    val latestCallback = rememberUpdatedState(onTerminalRequest)
    val accumulator = remember(thresholdPx) { DockScrollAccumulator(thresholdPx) }

    val connection = remember(accumulator) {
        object : NestedScrollConnection {
            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource,
            ): Offset {
                if (source != NestedScrollSource.UserInput) return Offset.Zero
                accumulator.consume(consumed.y)?.let(latestCallback.value)
                return Offset.Zero
            }

            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                accumulator.reset()
                return Velocity.Zero
            }
        }
    }

    this.nestedScroll(connection)
}

/**
 * Pure terminal-state reducer mirroring Apple `BottomDockProgressReducer`.
 * Negative Y is an upward finger/content gesture in Compose nested-scroll coordinates → compact.
 */
internal class DockScrollAccumulator(
    private val thresholdPx: Float,
) {
    private var accumulatedY = 0f

    init {
        require(thresholdPx > 0f) { "thresholdPx must be positive" }
    }

    fun consume(deltaY: Float): Boolean? {
        if (!deltaY.isFinite() || deltaY == 0f) return null

        if (accumulatedY != 0f && (accumulatedY > 0f) != (deltaY > 0f)) {
            accumulatedY = 0f
        }
        accumulatedY += deltaY

        if (abs(accumulatedY) < thresholdPx) return null
        val compact = accumulatedY < 0f
        accumulatedY = 0f
        return compact
    }

    fun reset() {
        accumulatedY = 0f
    }
}
