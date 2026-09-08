// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.designsystem

import androidx.annotation.StringRes
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

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

/** Apple `ThemeContracts` / `AuralisRootView` / `PlayerViews` 的跨页视觉硬规格。 */
object AuralisChrome {
    val miniPlayerHeight: Dp = 56.dp
    val dockHeight: Dp = 56.dp
    val dockSpacing: Dp = 8.dp
    val dockHorizontalPadding: Dp = 16.dp
    val dockBottomPadding: Dp = 6.dp
    val dockGestureThreshold: Dp = 44.dp
    val minTouchTarget: Dp = 44.dp

    const val compactInteractionThreshold: Float = 0.96f
    val compactPlayerWidth: Dp = 128.dp
    val compactInteractionHeight: Dp = 62.dp
    val expandedInteractionHeight: Dp = 126.dp

    val miniPlayerArtwork: Dp = 42.dp
    val compactMiniPlayerArtwork: Dp = 36.dp
    val miniPlayerHorizontalPadding: Dp = 12.dp
    val compactMiniPlayerHorizontalPadding: Dp = 10.dp
    val miniPlayerControlSpacing: Dp = 4.dp

    val homeCardWidth: Dp = 140.dp
    val homeCardSpacing: Dp = 12.dp
    val homeCardTextSpacing: Dp = 3.dp
    val homeCardTitleHeight: Dp = 20.dp

    /** iOS `IOSLayoutMetrics`，窄屏自然取满、宽屏分别封顶。 */
    val floatingChromeMaxWidth: Dp = 760.dp
    val readableContentMaxWidth: Dp = 960.dp
    val playerContentMaxWidth: Dp = 680.dp

    val trackRowArtwork: Dp = 48.dp
    val trackRowArtworkRadius: Dp = 10.dp
    val albumGridMin: Dp = 142.dp
    val genreGridMin: Dp = 150.dp
    val artistArtwork: Dp = 48.dp
}

object AuralisMotion {
    const val DOCK_DURATION_MS = 560
    const val DOCK_REDUCED_DURATION_MS = 180
    const val CARD_DURATION_MS = 220
}

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

fun Color.Companion.fromHex(hex: String): Color {
    val raw = hex.removePrefix("#")
    require(raw.length == 6 || raw.length == 8) { "Unsupported color: $hex" }
    val value = raw.toLong(16)
    return if (raw.length == 6) Color(0xFF000000L or value) else Color(value)
}
