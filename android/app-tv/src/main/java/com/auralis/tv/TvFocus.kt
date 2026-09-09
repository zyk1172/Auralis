// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.zIndex
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import kotlinx.coroutines.launch

/**
 * TV 焦点视觉体系。
 *
 * 移动端 feature 页面在 TV 上复用时，其普通 `clickable` 从 [LocalIndication]
 * 获得统一 accent 焦点环；TV 自有导航、播放器条等则使用 [tvFocusVisual] + [tvClick]。
 * 目标是任何 D-pad 可操作元素都同时具备：明确焦点、足够命中范围、按下反馈。
 */

/**
 * 全局 TV 焦点指示：聚焦 → 3dp accent 描边；按下 → accent 淡底。
 *
 * 描边向内偏移半个 stroke，避免电视 OEM/Compose 图层把外半圈裁掉；按下背景也使用
 * 同一圆角而不是方形 rect，保证复用手机卡片时焦点视觉不会破坏原组件轮廓。
 */
class TvIndication(
    private val focusColor: Color,
    private val stroke: Dp = 3.dp,
) : IndicationNodeFactory {
    override fun create(interactionSource: InteractionSource): DelegatableNode {
        return TvIndicationNode(interactionSource, focusColor, stroke)
    }

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
        drawContent()
        val radius = 12.dp.toPx()
        if (pressed) {
            drawRoundRect(
                color = focusColor.copy(alpha = 0.14f),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
        if (focused) {
            val strokePx = stroke.toPx()
            val inset = strokePx / 2f
            val ringSize = Size(
                width = (size.width - strokePx).coerceAtLeast(0f),
                height = (size.height - strokePx).coerceAtLeast(0f),
            )
            drawRoundRect(
                color = focusColor,
                topLeft = Offset(inset, inset),
                size = ringSize,
                style = Stroke(width = strokePx),
                cornerRadius = CornerRadius(
                    x = (radius - inset).coerceAtLeast(0f),
                    y = (radius - inset).coerceAtLeast(0f),
                ),
            )
        }
    }
}

/** 在 TV 子树根部提供随主题 accent 变化的统一焦点指示。 */
@Composable
fun ProvideTvIndication(content: @Composable () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val indication = remember(colors.accent) { TvIndication(colors.accent) }
    CompositionLocalProvider(LocalIndication provides indication) {
        content()
    }
}

/**
 * TV 自有控件的焦点视觉。
 *
 * 聚焦后 140ms 放大至 1.05，并叠加 3dp accent 描边；系统 Reduce Motion 开启时
 * 立即切换，不做缩放过渡。聚焦控件同时提升 z-order，避免放大后的描边被相邻 Row/Card
 * 覆盖——这在密集横向货架和底部 transport controls 上尤其明显。
 */
@Composable
fun Modifier.tvFocusVisual(
    shape: Shape = RoundedCornerShape(AuralisRadius.medium),
    stroke: Dp = 3.dp,
): Modifier {
    var focused by remember { mutableStateOf(false) }
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val scale by animateFloatAsState(
        targetValue = if (focused) 1.05f else 1f,
        animationSpec = if (reduceMotion) snap() else tween(durationMillis = 140),
        label = "tv-focus-scale",
    )
    return this
        .onFocusChanged { focused = it.isFocused }
        .zIndex(if (focused) 1f else 0f)
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
        }
        .then(if (focused) Modifier.border(stroke, colors.accent, shape) else Modifier)
}

/**
 * TV 自有控件点击入口。
 *
 * 显式加入 [focusable]，不依赖 `clickable` 在不同 Compose/设备组合下隐式建立键盘焦点；
 * Focus 与 Press 共用一个 interaction source，D-pad OK/Enter 可以稳定触发，且不与
 * [tvFocusVisual] 再叠一层默认 indication。
 */
@Composable
fun Modifier.tvClick(onClick: () -> Unit): Modifier {
    val interactionSource = remember { MutableInteractionSource() }
    return this
        .focusable(interactionSource = interactionSource)
        .clickable(
            interactionSource = interactionSource,
            indication = null,
            onClick = onClick,
        )
}
