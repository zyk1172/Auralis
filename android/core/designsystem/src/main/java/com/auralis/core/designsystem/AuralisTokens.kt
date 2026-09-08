// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.designsystem

import androidx.annotation.StringRes
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Auralis 设计 token。
 *
 * Apple 对应 `DesignSystem/ThemeContracts.swift`：
 * - `AuralisSpacing` = 4 / 8 / 12 / 20 / 28 / 40
 * - `AuralisRadius`  = 8 / 14 / 22 / 18(artwork)
 *
 * Android 直接按 dp 映射（与 iOS pt 1:1），**不要**改成 4/8/16/24/32 那套。
 */
object AuralisSpacing {
    val xSmall: Dp = 4.dp
    val small: Dp = 8.dp
    val medium: Dp = 12.dp
    val large: Dp = 20.dp
    val xLarge: Dp = 28.dp
    val huge: Dp = 40.dp
}

object AuralisRadius {
    val small: Dp = 8.dp
    val medium: Dp = 14.dp
    val large: Dp = 22.dp
    val artwork: Dp = 18.dp
}

/** 底部 Dock / Mini Player 的硬规格（Apple `AuralisRootView.swift`）。 */
object AuralisChrome {
    val miniPlayerHeight: Dp = 56.dp
    val dockHeight: Dp = 56.dp
    val dockSpacing: Dp = 8.dp
    val dockBottomPadding: Dp = 6.dp
    /** 判定为 Dock 手势的最小纵向位移。 */
    val dockGestureThreshold: Dp = 44.dp
    /** 触控目标下限。 */
    val minTouchTarget: Dp = 44.dp

    /** 首页卡片固定视觉宽度（Phone 固定尺寸，让下一张自然露出；Tablet 只是显示更多张）。 */
    val homeCardWidth: Dp = 140.dp
    val homeCardSpacing: Dp = 12.dp
    val homeCardTextSpacing: Dp = 3.dp
    val homeCardTitleHeight: Dp = 20.dp
    /** iPad / Tablet 可读内容最大宽度。 */
    val readableContentMaxWidth: Dp = 960.dp

    val trackRowArtwork: Dp = 48.dp
    val trackRowArtworkRadius: Dp = 10.dp
    val albumGridMin: Dp = 142.dp
    val genreGridMin: Dp = 150.dp
    val artistArtwork: Dp = 48.dp
}

/**
 * 两套动画时长，必须分开实现（Apple 审计结论）：
 * 1. `BottomDockMotion`：Dock / 浮层 / 避让空间，0.56s smooth，reduce-motion 时 0.18s linear；
 * 2. 主题自身 `MotionTokens.standardDuration`：0.18–0.42s easeInOut，reduce-motion 时**完全无动画**。
 */
object AuralisMotion {
    const val DOCK_DURATION_MS = 560
    const val DOCK_REDUCED_DURATION_MS = 180
    const val CARD_DURATION_MS = 220
}

/** 11 个颜色 token。Apple `ThemeColors` 实际是 11 个，不是 12 个。 */
@Immutable
data class AuralisColors(
    val background: Color,
    val elevated: Color,
    val surface: Color,
    val primaryText: Color,
    val secondaryText: Color,
    val accent: Color,
    val accentSecondary: Color,
    val success: Color,
    val warning: Color,
    val error: Color,
    val separator: Color,
)

enum class AuralisColorScheme { Light, Dark }

enum class AuralisMaterialStyle { Solid, SubtleGlass, LuminousGlass, Paper }

@Immutable
data class AuralisMaterials(
    val navigation: AuralisMaterialStyle,
    val floatingControls: AuralisMaterialStyle,
    /** solid → 1.0，其余 → 0.82。navigation 与 floatingControls 恒等。 */
    val opacity: Float,
)

enum class AuralisArtworkStyle { SoftShadow, Crisp, Framed, Luminous }

@Immutable
data class AuralisMotionTokens(
    val standardDurationSeconds: Double,
    val ambientDurationSeconds: Double,
    val glowIntensity: Double,
)

enum class AuralisVisualizerStyle { FluidBars, LineSpectrum, VuMeter, Minimal, Disabled }

@Immutable
data class AuralisTypography(
    val displayWeight: AuralisFontWeight,
    val bodyWeight: AuralisFontWeight,
    val usesMonospacedMetrics: Boolean,
)

enum class AuralisFontWeight { Regular, Medium, SemiBold, Bold }

@Immutable
data class AuralisTheme(
    val id: String,
    @StringRes val nameRes: Int,
    val colorScheme: AuralisColorScheme,
    val colors: AuralisColors,
    val typography: AuralisTypography,
    val materials: AuralisMaterials,
    val artworkStyle: AuralisArtworkStyle,
    val motion: AuralisMotionTokens,
    val visualizer: AuralisVisualizerStyle,
)

val LocalAuralisTheme = staticCompositionLocalOf { BuiltInThemes.default }

/** hex → Color。支持 6 位（alpha=1）与 8 位 AARRGGBB。 */
fun Color.Companion.fromHex(hex: String): Color {
    val raw = hex.removePrefix("#")
    require(raw.length == 6 || raw.length == 8) { "Unsupported color: $hex" }
    val value = raw.toLong(16)
    return if (raw.length == 6) Color(0xFF000000L or value) else Color(value)
}
