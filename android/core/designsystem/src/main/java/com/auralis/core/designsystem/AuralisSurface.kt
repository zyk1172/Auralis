// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp

/**
 * Apple 端 `BottomGlassBarShell` / 浮动控件统一读取 `ThemeMaterials`。
 * Android 没有 SwiftUI Material 完全等价的跨层 backdrop blur，因此这里不伪造“同名但无效”的 blur：
 * 采用相同 token、相同 0.82/1.0 不透明度，并用极轻边框/阴影表达 subtle/luminous/paper
 * 的层级；这样主题切换时所有底部 Chrome 至少遵循同一材质语义，而不是固定实色卡片。
 */
enum class AuralisChromeSurfaceRole { Navigation, FloatingControl }

@Composable
fun Modifier.auralisChromeSurface(
    shape: Shape,
    role: AuralisChromeSurfaceRole = AuralisChromeSurfaceRole.FloatingControl,
): Modifier {
    val theme = LocalAuralisTheme.current
    val style = when (role) {
        AuralisChromeSurfaceRole.Navigation -> theme.materials.navigation
        AuralisChromeSurfaceRole.FloatingControl -> theme.materials.floatingControls
    }
    val colors = theme.colors
    val opacity = theme.materials.opacity.coerceIn(0f, 1f)

    val fill: Color
    val border: Color
    val elevation = when (style) {
        AuralisMaterialStyle.Solid -> {
            fill = colors.elevated
            border = colors.separator.copy(alpha = 0.55f)
            0.dp
        }

        AuralisMaterialStyle.SubtleGlass -> {
            fill = colors.elevated.copy(alpha = opacity)
            border = colors.primaryText.copy(alpha = 0.08f)
            10.dp
        }

        AuralisMaterialStyle.LuminousGlass -> {
            fill = colors.elevated.copy(alpha = opacity)
            border = colors.accent.copy(alpha = 0.22f + (theme.motion.glowIntensity.toFloat() * 0.18f))
            14.dp
        }

        AuralisMaterialStyle.Paper -> {
            fill = colors.elevated.copy(alpha = opacity)
            border = colors.separator.copy(alpha = 0.42f)
            3.dp
        }
    }

    val shadowColor = when (style) {
        AuralisMaterialStyle.LuminousGlass -> colors.accent.copy(
            alpha = (0.16f + theme.motion.glowIntensity.toFloat() * 0.24f).coerceAtMost(0.28f),
        )
        else -> Color.Black.copy(alpha = if (theme.colorScheme == AuralisColorScheme.Dark) 0.26f else 0.12f)
    }

    return this
        .shadow(
            elevation = elevation,
            shape = shape,
            clip = false,
            ambientColor = shadowColor,
            spotColor = shadowColor,
        )
        .background(fill, shape)
        .border(0.75.dp, border, shape)
}
