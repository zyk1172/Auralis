// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Auralis 主题容器。
 *
 * Apple 的 `ThemeStore.current.colorScheme` 是产品主题的权威；选择浅色主题时，即使系统
 * 处于深色模式也必须保持该主题的浅色视觉。MaterialTheme 仅作为 Compose 组件底座，
 * 所有产品颜色仍由 [LocalAuralisTheme] 提供。
 *
 * 主题切换与 Apple `AuralisRootView` 一致：
 * - 正常：按当前主题 `motion.standardDuration` 做 easeInOut 颜色过渡；
 * - reduce-motion：不做主题切换动画，直接落到目标 token。
 */
@Composable
fun AuralisTheme(
    theme: AuralisTheme = BuiltInThemes.default,
    reduceMotion: Boolean = false,
    content: @Composable () -> Unit,
) {
    val durationMillis = (theme.motion.standardDurationSeconds * 1_000.0).toInt().coerceAtLeast(0)
    val colorSpec: AnimationSpec<Color> = if (reduceMotion) {
        snap()
    } else {
        tween(durationMillis = durationMillis, easing = AppleEaseInOut)
    }

    // 把动画放在 token 边界：业务页面继续只读取 Auralis token，就能和 Apple 一样
    // 在切换主题时整体渐变，而不是只有 Material 组件变化。
    val background by animateColorAsState(theme.colors.background, colorSpec, label = "auralis-background")
    val elevated by animateColorAsState(theme.colors.elevated, colorSpec, label = "auralis-elevated")
    val surface by animateColorAsState(theme.colors.surface, colorSpec, label = "auralis-surface")
    val primaryText by animateColorAsState(theme.colors.primaryText, colorSpec, label = "auralis-primary-text")
    val secondaryText by animateColorAsState(theme.colors.secondaryText, colorSpec, label = "auralis-secondary-text")
    val accent by animateColorAsState(theme.colors.accent, colorSpec, label = "auralis-accent")
    val accentSecondary by animateColorAsState(theme.colors.accentSecondary, colorSpec, label = "auralis-accent-secondary")
    val success by animateColorAsState(theme.colors.success, colorSpec, label = "auralis-success")
    val warning by animateColorAsState(theme.colors.warning, colorSpec, label = "auralis-warning")
    val error by animateColorAsState(theme.colors.error, colorSpec, label = "auralis-error")
    val separator by animateColorAsState(theme.colors.separator, colorSpec, label = "auralis-separator")

    val resolvedTheme = theme.copy(
        colors = AuralisColors(
            background = background,
            elevated = elevated,
            surface = surface,
            primaryText = primaryText,
            secondaryText = secondaryText,
            accent = accent,
            accentSecondary = accentSecondary,
            success = success,
            warning = warning,
            error = error,
            separator = separator,
        ),
    )

    val colors = resolvedTheme.colors
    val scheme = if (resolvedTheme.colorScheme == AuralisColorScheme.Dark) {
        darkColorScheme(
            primary = colors.accent,
            secondary = colors.accentSecondary,
            background = colors.background,
            surface = colors.surface,
            surfaceVariant = colors.elevated,
            error = colors.error,
            onPrimary = colors.background,
            onSecondary = colors.background,
            onBackground = colors.primaryText,
            onSurface = colors.primaryText,
            onSurfaceVariant = colors.secondaryText,
            outline = colors.separator,
        )
    } else {
        lightColorScheme(
            primary = colors.accent,
            secondary = colors.accentSecondary,
            background = colors.background,
            surface = colors.surface,
            surfaceVariant = colors.elevated,
            error = colors.error,
            onPrimary = colors.background,
            onSecondary = colors.background,
            onBackground = colors.primaryText,
            onSurface = colors.primaryText,
            onSurfaceVariant = colors.secondaryText,
            outline = colors.separator,
        )
    }

    CompositionLocalProvider(
        LocalAuralisTheme provides resolvedTheme,
        LocalReduceMotion provides reduceMotion,
    ) {
        MaterialTheme(
            colorScheme = scheme,
            typography = appleLikeTypography(resolvedTheme.typography),
            content = content,
        )
    }
}

/** SwiftUI `.easeInOut` 的标准三次贝塞尔近似。 */
private val AppleEaseInOut = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

/**
 * SwiftUI 默认 Dynamic Type 基准字号的 Compose 映射。
 *
 * Apple 端没有“字号主题 token”，业务页直接使用 `.body/.subheadline/.caption/...`；
 * Android 不能继续使用 Material 3 默认 14sp body，否则同一布局的文字密度明显偏小。
 * 这里把 Material 语义角色映射到 iOS 常用基准字号，并保留主题声明的 display/body 字重。
 * 字体家族使用 Android 系统 sans-serif；不在仓库内捆绑 Apple 专有字体文件。
 */
private fun appleLikeTypography(themeTypography: AuralisTypography): Typography {
    val displayWeight = themeTypography.displayWeight.toComposeWeight()
    val bodyWeight = themeTypography.bodyWeight.toComposeWeight()
    val family = FontFamily.SansSerif

    fun style(sizeSp: Int, weight: FontWeight = bodyWeight, lineHeightSp: Int = sizeSp + 4) = TextStyle(
        fontFamily = family,
        fontWeight = weight,
        fontSize = sizeSp.sp,
        lineHeight = lineHeightSp.sp,
    )

    return Typography(
        displayLarge = style(34, displayWeight, 41),       // SwiftUI largeTitle
        displayMedium = style(28, displayWeight, 34),      // title
        displaySmall = style(22, displayWeight, 28),       // title2
        headlineLarge = style(28, displayWeight, 34),
        headlineMedium = style(22, displayWeight, 28),
        headlineSmall = style(20, displayWeight, 25),      // title3
        titleLarge = style(22, displayWeight, 28),
        titleMedium = style(17, FontWeight.SemiBold, 22),  // headline
        titleSmall = style(15, FontWeight.SemiBold, 20),   // subheadline emphasized
        bodyLarge = style(17, bodyWeight, 22),             // body
        bodyMedium = style(17, bodyWeight, 22),            // body（现有页面大量使用）
        bodySmall = style(15, bodyWeight, 20),              // subheadline
        labelLarge = style(16, FontWeight.Medium, 21),      // callout
        labelMedium = style(13, FontWeight.Medium, 18),     // footnote
        labelSmall = style(11, FontWeight.Medium, 14),      // caption2
    )
}

private fun AuralisFontWeight.toComposeWeight(): FontWeight = when (this) {
    AuralisFontWeight.Regular -> FontWeight.Normal
    AuralisFontWeight.Medium -> FontWeight.Medium
    AuralisFontWeight.SemiBold -> FontWeight.SemiBold
    AuralisFontWeight.Bold -> FontWeight.Bold
}

val LocalReduceMotion = androidx.compose.runtime.staticCompositionLocalOf { false }

/** 当前主题（进程内可观察），由 App 组合根持有。 */
object AuralisThemeController {
    private val selected = mutableStateOf(BuiltInThemes.default)

    var current: AuralisTheme
        get() = selected.value
        set(value) { selected.value = value }

    @Composable
    fun observe(): AuralisTheme = selected.value
}
