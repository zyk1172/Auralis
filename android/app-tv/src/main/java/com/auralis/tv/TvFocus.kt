// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import android.view.KeyEvent as AndroidKeyEvent
import android.view.SoundEffectConstants
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.FocusInteraction
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.nativeKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import kotlinx.coroutines.launch

/**
 * TV focus/remote feedback layer.
 *
 * Shared mobile-derived cards still use ordinary clickable(), therefore the LocalIndication must
 * provide a strong ten-foot focus state. Native TV controls additionally use [tvFocusableClick]
 * for a subtle focus-scale and pressed pulse. Remote key sounds are emitted once at the root so
 * every D-pad action gets consistent feedback without each feature having to implement it again.
 */
class TvIndication(
    private val focusColor: Color,
    private val stroke: Dp = 3.dp,
) : IndicationNodeFactory {
    override fun create(interactionSource: InteractionSource): DelegatableNode =
        TvIndicationNode(interactionSource, focusColor, stroke)

    override fun equals(other: Any?): Boolean =
        other is TvIndication && other.focusColor == focusColor && other.stroke == stroke

    override fun hashCode(): Int = focusColor.hashCode() * 31 + stroke.hashCode()
}

private class TvIndicationNode(
    private val interactionSource: InteractionSource,
    private val focusColor: Color,
    private val stroke: Dp,
) : Modifier.Node(), DrawModifierNode {
    private var focused by mutableStateOf(false)
    private var pressed by mutableStateOf(false)

    override fun onAttach() {
        coroutineScope.launch {
            interactionSource.interactions.collect { interaction ->
                when (interaction) {
                    is FocusInteraction.Focus -> focused = true
                    is FocusInteraction.Unfocus -> focused = false
                    is PressInteraction.Press -> pressed = true
                    is PressInteraction.Release, is PressInteraction.Cancel -> pressed = false
                }
            }
        }
    }

    override fun ContentDrawScope.draw() {
        val radius = 14.dp.toPx()
        if (focused) {
            drawRoundRect(
                color = focusColor.copy(alpha = 0.08f),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
        drawContent()
        if (pressed) {
            drawRoundRect(
                color = focusColor.copy(alpha = 0.15f),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
        if (focused) {
            val strokePx = stroke.toPx()
            val inset = strokePx / 2f
            drawRoundRect(
                color = focusColor,
                topLeft = Offset(inset, inset),
                size = Size(
                    width = (size.width - strokePx).coerceAtLeast(0f),
                    height = (size.height - strokePx).coerceAtLeast(0f),
                ),
                style = Stroke(width = strokePx),
                cornerRadius = CornerRadius(
                    x = (radius - inset).coerceAtLeast(0f),
                    y = (radius - inset).coerceAtLeast(0f),
                ),
            )
        }
    }
}

/**
 * Installs the shared focus indication and TV remote sound feedback. SoundEffectConstants route
 * through the TV system UI-sound channel and respect the device's own UI-sound policy/volume.
 * The handler never consumes a key, so normal Compose focus movement remains authoritative.
 */
@Composable
fun ProvideTvIndication(content: @Composable () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val indication = remember(colors.accent) { TvIndication(colors.accent) }
    val view = LocalView.current

    CompositionLocalProvider(LocalIndication provides indication) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .onPreviewKeyEvent { event ->
                    if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.repeatCount == 0) {
                        val effect = when (event.nativeKeyEvent.keyCode) {
                            AndroidKeyEvent.KEYCODE_DPAD_LEFT -> SoundEffectConstants.NAVIGATION_LEFT
                            AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> SoundEffectConstants.NAVIGATION_RIGHT
                            AndroidKeyEvent.KEYCODE_DPAD_UP -> SoundEffectConstants.NAVIGATION_UP
                            AndroidKeyEvent.KEYCODE_DPAD_DOWN -> SoundEffectConstants.NAVIGATION_DOWN
                            AndroidKeyEvent.KEYCODE_DPAD_CENTER,
                            AndroidKeyEvent.KEYCODE_ENTER,
                            AndroidKeyEvent.KEYCODE_NUMPAD_ENTER,
                            AndroidKeyEvent.KEYCODE_BUTTON_A,
                            -> SoundEffectConstants.CLICK
                            else -> null
                        }
                        effect?.let(view::playSoundEffect)
                    }
                    false
                },
        ) {
            content()
        }
    }
}

/**
 * Visual-only TV focus effect. Focused targets grow slightly; while D-pad OK is held they dip
 * inward instead of losing the marker, keeping the active target obvious after activation.
 */
@Composable
fun Modifier.tvFocusVisual(
    shape: Shape = RoundedCornerShape(AuralisRadius.medium),
    stroke: Dp = 3.dp,
    interactionSource: MutableInteractionSource? = null,
    onFocusedChange: (Boolean) -> Unit = {},
): Modifier {
    var focused by remember { mutableStateOf(false) }
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val pressed = interactionSource?.collectIsPressedAsState()?.value == true
    val targetScale = when {
        pressed -> 0.985f
        focused -> 1.045f
        else -> 1f
    }
    val scale by animateFloatAsState(
        targetValue = targetScale,
        animationSpec = if (reduceMotion) snap() else tween(durationMillis = 110),
        label = "tv-focus-scale",
    )
    return this
        .onFocusChanged {
            if (focused != it.isFocused) {
                focused = it.isFocused
                onFocusedChange(focused)
            }
        }
        .zIndex(if (focused) 1f else 0f)
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
        }
        .then(
            if (focused) Modifier.border(stroke, colors.accent, shape)
            else Modifier,
        )
}

/** D-pad click target. Focus and click share one interaction source when supplied. */
@Composable
fun Modifier.tvClick(
    onClick: () -> Unit,
    interactionSource: MutableInteractionSource? = null,
): Modifier {
    val source = interactionSource ?: remember { MutableInteractionSource() }
    return this
        .focusable(interactionSource = source)
        .clickable(
            interactionSource = source,
            indication = null,
            onClick = onClick,
        )
}

/** Preferred modifier for TV-native buttons: visible focus + pressed pulse + stable click target. */
@Composable
fun Modifier.tvFocusableClick(
    shape: Shape = RoundedCornerShape(AuralisRadius.medium),
    enabled: Boolean = true,
    onFocusedChange: (Boolean) -> Unit = {},
    onClick: () -> Unit,
): Modifier {
    if (!enabled) return this
    val source = remember { MutableInteractionSource() }
    return this
        .tvFocusVisual(
            shape = shape,
            interactionSource = source,
            onFocusedChange = onFocusedChange,
        )
        .tvClick(onClick = onClick, interactionSource = source)
}
