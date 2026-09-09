// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.matchParentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.LocalReduceMotion
import kotlin.math.max

/**
 * Apple `ThinSlider` 的 Compose 等价实现。
 *
 * 几何和交互以 Swift 为准：
 * - 30dp 总命中高度；
 * - 3dp 胶囊轨道；
 * - 静止 9dp 白色圆点，拖动时放大到 16dp；
 * - 拖动期间实时回传值，但提交时机由 [onEditingChanged] 的 false 决定；
 * - 从按下第一帧就响应，等价于 Swift `DragGesture(minimumDistance: 0)`；
 * - TalkBack 通过 `setProgress` 走同一 begin/change/end 提交路径。
 */
@Composable
internal fun AuralisThinSlider(
    value: Float,
    accent: Color,
    track: Color,
    thumb: Color = Color.White,
    enabled: Boolean = true,
    onEditingChanged: (Boolean) -> Unit,
    onValueChanged: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = LocalReduceMotion.current
    val currentOnEditingChanged by rememberUpdatedState(onEditingChanged)
    val currentOnValueChanged by rememberUpdatedState(onValueChanged)
    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(value.coerceIn(0f, 1f)) }
    val fraction = if (dragging) dragValue else value.coerceIn(0f, 1f)
    val thumbSize by animateDpAsState(
        targetValue = if (dragging) 16.dp else 9.dp,
        animationSpec = if (reduceMotion) snap() else tween(120),
        label = "auralis-thin-slider-thumb",
    )

    fun updateFraction(raw: Float) {
        val next = raw.coerceIn(0f, 1f)
        dragValue = next
        currentOnValueChanged(next)
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(30.dp)
            .semantics {
                progressBarRangeInfo = ProgressBarRangeInfo(fraction, 0f..1f)
                if (enabled) {
                    setProgress { target ->
                        val next = target.coerceIn(0f, 1f)
                        currentOnEditingChanged(true)
                        currentOnValueChanged(next)
                        currentOnEditingChanged(false)
                        true
                    }
                }
            }
            // Callback lambdas are intentionally not pointerInput keys. Dragging updates parent state every frame;
            // restarting this gesture detector on every recomposition would cancel the gesture mid-drag.
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    dragging = true
                    currentOnEditingChanged(true)
                    updateFraction(down.position.x / max(size.width.toFloat(), 1f))
                    down.consume()

                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        updateFraction(change.position.x / max(size.width.toFloat(), 1f))
                        val released = !change.pressed
                        change.consume()
                        if (released) break
                    }
                    dragging = false
                    currentOnEditingChanged(false)
                }
            },
    ) {
        Canvas(Modifier.matchParentSize()) {
            val centerY = size.height / 2f
            val trackHeight = 3.dp.toPx()
            val radius = trackHeight / 2f
            val clamped = fraction.coerceIn(0f, 1f)
            val thumbPx = thumbSize.toPx()
            val thumbRadius = thumbPx / 2f
            val thumbCenterX = (size.width * clamped).coerceIn(thumbRadius, max(thumbRadius, size.width - thumbRadius))

            drawRoundRect(
                color = track,
                topLeft = Offset(0f, centerY - trackHeight / 2f),
                size = Size(size.width, trackHeight),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius),
            )
            drawRoundRect(
                color = accent,
                topLeft = Offset(0f, centerY - trackHeight / 2f),
                size = Size((size.width * clamped).coerceAtLeast(0f), trackHeight),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius),
            )
            // Swift 阴影在 Android Canvas 中用低透明外圈近似，避免引入独立图层模糊成本。
            drawCircle(
                color = Color.Black.copy(alpha = if (dragging) 0.18f else 0.10f),
                radius = thumbRadius + if (dragging) 2.dp.toPx() else 1.dp.toPx(),
                center = Offset(thumbCenterX, centerY + 1.dp.toPx()),
            )
            drawCircle(
                color = thumb,
                radius = thumbRadius,
                center = Offset(thumbCenterX, centerY),
            )
            if (!enabled) {
                drawCircle(
                    color = track.copy(alpha = 0.35f),
                    radius = thumbRadius,
                    center = Offset(thumbCenterX, centerY),
                    style = Stroke(width = 1.dp.toPx()),
                )
            }
        }
    }
}
