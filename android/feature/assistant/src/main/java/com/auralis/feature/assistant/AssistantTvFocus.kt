// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import android.content.res.Configuration
import android.content.res.Resources
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion

/** True only for the ten-foot Android UI. Safe to query from focus-launch coroutines too. */
internal fun assistantIsTelevision(): Boolean {
    val configuration = Resources.getSystem().configuration
    return configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_TELEVISION
}

/**
 * High-contrast D-pad focus treatment for shared Assistant UI.
 *
 * Material3's phone buttons do not provide a sufficiently visible TV focus state on every theme.
 * This modifier leaves touch UI unchanged and, on televisions only, adds a contrast outline,
 * translucent fill and a small focus scale. It observes Reduce Motion and therefore never forces
 * animation when the system asks for reduced motion.
 */
@Composable
internal fun Modifier.assistantTvFocus(
    shape: Shape,
    enabled: Boolean = true,
): Modifier {
    if (!assistantIsTelevision() || !enabled) return this

    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (focused) 1.055f else 1f,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = if (reduceMotion) 10_000f else 520f),
        label = "assistant-tv-focus-scale",
    )
    val outline = if (focused) colors.primaryText else colors.separator.copy(alpha = 0.38f)
    val fill = if (focused) colors.accent.copy(alpha = 0.20f) else colors.surface.copy(alpha = 0.08f)

    return this
        .onFocusChanged { focused = it.hasFocus }
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
        }
        .clip(shape)
        .background(fill, shape)
        .border(if (focused) 3.dp else 1.dp, outline, shape)
}
