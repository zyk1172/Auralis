package com.auralis.core.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Auralis 主题容器。
 *
 * MaterialTheme 只是**底层组件**；Auralis Token（[LocalAuralisTheme]）才是产品视觉权威。
 * UI 一律从 `LocalAuralisTheme.current` 取色，不要直接用 MaterialTheme.colorScheme。
 */
@Composable
fun AuralisTheme(
    theme: AuralisTheme = BuiltInThemes.default,
    reduceMotion: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colors = theme.colors
    val scheme = if (theme.colorScheme == AuralisColorScheme.Dark || isSystemInDarkTheme()) {
        darkColorScheme(
            primary = colors.accent,
            secondary = colors.accentSecondary,
            background = colors.background,
            surface = colors.surface,
            error = colors.error,
            onPrimary = colors.background,
            onBackground = colors.primaryText,
            onSurface = colors.primaryText,
        )
    } else {
        lightColorScheme(
            primary = colors.accent,
            secondary = colors.accentSecondary,
            background = colors.background,
            surface = colors.surface,
            error = colors.error,
            onPrimary = colors.background,
            onBackground = colors.primaryText,
            onSurface = colors.primaryText,
        )
    }
    CompositionLocalProvider(
        LocalAuralisTheme provides theme,
        LocalReduceMotion provides reduceMotion,
    ) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
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
