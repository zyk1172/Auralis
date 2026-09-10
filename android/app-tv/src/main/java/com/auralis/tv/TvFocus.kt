// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

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
import androidx.compose.runtime.staticCompositionLocalOf
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
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.auralis.core.designsystem.AuralisColors
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import kotlinx.coroutines.launch

/**
 * TV focus/remote feedback layer.
 *
 * Selection and focus are deliberately different concepts. Product selection keeps the theme
 * accent, while remote focus uses a contrast-resolved color that remains legible even when a theme
 * uses nearly the same accent and surface hues. This avoids the real-TV failure where the focus
 * rectangle visually disappeared into the selected background.
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
                color = focusColor.copy(alpha = 0.11f),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
        drawContent()
        if (pressed) {
            drawRoundRect(
                color = focusColor.copy(alpha = 0.18f),
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

private val LocalTvFocusColor = staticCompositionLocalOf { Color.White }

/** WCAG-style contrast ratio, kept internal so unit tests can exercise every built-in theme. */
internal fun tvContrastRatio(a: Color, b: Color): Float {
    val lighter = maxOf(a.luminance(), b.luminance())
    val darker = minOf(a.luminance(), b.luminance())
    return (lighter + 0.05f) / (darker + 0.05f)
}

/**
 * Resolve a focus color independently from the theme's primary accent. The score is the weaker of
 * its contrast against the normal surface and the selected-accent surface; this guarantees that a
 * focus outline stays visible in both selected and unselected states.
 */
internal fun resolveTvFocusColor(colors: AuralisColors): Color {
    val selectedSurface = compositeOver(colors.accent.copy(alpha = 0.24f), colors.surface)
    val candidates = listOf(colors.accentSecondary, colors.primaryText, Color.White, Color.Black)
    return candidates.maxBy { candidate ->
        minOf(
            tvContrastRatio(candidate, colors.surface),
            tvContrastRatio(candidate, selectedSurface),
        )
    }
}

private fun compositeOver(foreground: Color, background: Color): Color {
    val alpha = foreground.alpha + background.alpha * (1f - foreground.alpha)
    if (alpha <= 0f) return Color.Transparent
    return Color(
        red = (foreground.red * foreground.alpha + background.red * background.alpha * (1f - foreground.alpha)) / alpha,
        green = (foreground.green * foreground.alpha + background.green * background.alpha * (1f - foreground.alpha)) / alpha,
        blue = (foreground.blue * foreground.alpha + background.blue * background.alpha * (1f - foreground.alpha)) / alpha,
        alpha = alpha,
    )
}

/**
 * Installs shared focus indication and TV remote sound feedback. Sound effects respect the device's
 * own UI-sound setting. The handler never consumes a key, so normal Compose focus movement remains
 * authoritative.
 */
@Composable
fun ProvideTvIndication(content: @Composable () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val focusColor = remember(colors) { resolveTvFocusColor(colors) }
    val indication = remember(focusColor) { TvIndication(focusColor) }
    val view = LocalView.current
    var soundKeyDown by remember { mutableStateOf<Key?>(null) }

    CompositionLocalProvider(
        LocalIndication provides indication,
        LocalTvFocusColor provides focusColor,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .onPreviewKeyEvent { event ->
                    val key = event.key
                    when (event.type) {
                        KeyEventType.KeyDown -> {
                            if (soundKeyDown != key) {
                                soundKeyDown = key
                                val effect = when (key) {
                                    Key.DirectionLeft -> SoundEffectConstants.NAVIGATION_LEFT
                                    Key.DirectionRight -> SoundEffectConstants.NAVIGATION_RIGHT
                                    Key.DirectionUp -> SoundEffectConstants.NAVIGATION_UP
                                    Key.DirectionDown -> SoundEffectConstants.NAVIGATION_DOWN
                                    Key.DirectionCenter,
                                    Key.Enter,
                                    Key.NumPadEnter,
                                    Key.ButtonA,
                                    -> SoundEffectConstants.CLICK
                                    else -> null
                                }
                                effect?.let(view::playSoundEffect)
                            }
                        }

                        KeyEventType.KeyUp -> if (soundKeyDown == key) soundKeyDown = null
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
    val focusColor = LocalTvFocusColor.current
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
            if (focused) Modifier.border(stroke, focusColor, shape)
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
