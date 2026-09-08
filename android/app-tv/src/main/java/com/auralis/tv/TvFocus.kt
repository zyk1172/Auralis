// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
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
import kotlinx.coroutines.launch

/**
 * TV 焦点视觉体系（S9）。
 *
 * 移动端页面（feature 层）在 TV 上零改动复用：它们的 `clickable` 默认读取
 * `LocalIndication.current`，因此在 TV Activity 根部用 [ProvideTvIndication]
 * 全局替换为 [TvIndication] —— 复用页面里的行/卡/按钮在 D-pad 聚焦时即获得
 * accent 描边焦点环，无需逐项改 feature 代码。
 *
 * TV 自有控件（导航项、正在播放条等）另提供 [Modifier.tvFocusVisual] 显式
 * 叠加「聚焦放大 + accent 描边」，与 indication 环视觉一致。
 */

/** 全局替换用的 TV 焦点指示：聚焦 → accent 描边圆角环；按下 → accent 淡底。 */
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
        if (pressed) {
            drawRect(color = focusColor.copy(alpha = 0.14f))
        }
        if (focused) {
            val strokePx = stroke.toPx()
            drawRoundRect(
                color = focusColor,
                style = Stroke(width = strokePx),
                cornerRadius = CornerRadius(12.dp.toPx(), 12.dp.toPx()),
            )
        }
    }
}

/** 在子树根部提供 TV 焦点指示（对齐当前主题 accent 色；主题切换时重建）。 */
@Composable
fun ProvideTvIndication(content: @Composable () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val indication = remember(colors.accent) { TvIndication(colors.accent) }
    CompositionLocalProvider(LocalIndication provides indication) {
        content()
    }
}

/**
 * 自有 TV 控件的焦点视觉：D-pad 聚焦时轻微放大并画 accent 描边。
 * 元素自身需可聚焦（自带 clickable / 前置 focusable）。
 */
@Composable
fun Modifier.tvFocusVisual(
    shape: Shape = RoundedCornerShape(AuralisRadius.medium),
    stroke: Dp = 3.dp,
): Modifier {
    var focused by remember { mutableStateOf(false) }
    val colors = LocalAuralisTheme.current.colors
    return this
        .onFocusChanged { focused = it.isFocused }
        .graphicsLayer {
            val scale = if (focused) 1.05f else 1f
            scaleX = scale
            scaleY = scale
        }
        .then(if (focused) Modifier.border(stroke, colors.accent, shape) else Modifier)
}

/**
 * TV 自有控件的点击：不叠加 indication（焦点视觉由 [Modifier.tvFocusVisual] 自绘），
 * 避免与全局 [TvIndication] 焦点环双画。元素需先经 tvFocusVisual/可聚焦来源获得焦点能力。
 */
@Composable
fun Modifier.tvClick(onClick: () -> Unit): Modifier {
    val interactionSource = remember { MutableInteractionSource() }
    return this.clickable(
        interactionSource = interactionSource,
        indication = null,
        onClick = onClick,
    )
}
