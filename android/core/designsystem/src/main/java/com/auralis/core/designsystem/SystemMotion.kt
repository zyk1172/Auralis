// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.designsystem

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

/**
 * Maps Android's system animation-scale accessibility/developer preference to Auralis Reduce Motion.
 * A value of 0 for any global animation scale means motion should be eliminated rather than merely
 * shortened. Changes are observed live so the app does not need a process restart.
 */
@Composable
fun rememberSystemReduceMotion(): Boolean {
    val context = LocalContext.current
    val resolver = context.contentResolver

    fun readReduced(): Boolean = MOTION_SCALE_KEYS.any { key ->
        runCatching { Settings.Global.getFloat(resolver, key, 1f) <= 0f }.getOrDefault(false)
    }

    var reduced by remember(resolver) { mutableStateOf(readReduced()) }

    DisposableEffect(resolver) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                reduced = readReduced()
            }
        }
        MOTION_SCALE_KEYS.forEach { key ->
            resolver.registerContentObserver(Settings.Global.getUriFor(key), false, observer)
        }
        onDispose { resolver.unregisterContentObserver(observer) }
    }

    return reduced
}

private val MOTION_SCALE_KEYS = listOf(
    Settings.Global.ANIMATOR_DURATION_SCALE,
    Settings.Global.TRANSITION_ANIMATION_SCALE,
    Settings.Global.WINDOW_ANIMATION_SCALE,
)
