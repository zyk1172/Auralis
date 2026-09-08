// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import androidx.annotation.StringRes
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.rememberTextMeasurer
import kotlinx.coroutines.delay

/** Now Playing 顶部分段页（对齐 Swift `NowPlayingPage`：lyrics/player/queue）。 */
internal enum class PlayerTab(@StringRes val titleRes: Int) {
    Lyrics(R.string.player_tab_lyrics),
    Player(R.string.player_tab_now_playing),
    Queue(R.string.player_tab_queue),
}

/** 毫秒 → m:ss（进度两侧时间显示；对齐 Swift formatDuration）。 */
internal fun formatClock(ms: Long): String {
    val totalSeconds = (ms.coerceAtLeast(0) + 500) / 1000
    val m = totalSeconds / 60
    val s = totalSeconds % 60
    return "$m:${s.toString().padStart(2, '0')}"
}

/**
 * 单向慢速跑马灯（对齐 Swift OneShotMarqueeText）：标题不超宽时等价单行 Text；
 * 超宽时等 900ms 后以约 40px/s 从头滚到结尾并**停在末尾**（不循环，避免持续干扰）。
 */
@Composable
internal fun AutoMarqueeText(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val textMeasurer = rememberTextMeasurer()
    var containerWidth by remember { mutableStateOf<Int?>(null) }
    val measured = remember(text, style) {
        textMeasurer.measure(text, style, constraints = Constraints(maxWidth = 8192))
    }
    val textWidth = measured.size.width
    val gapPx = with(density) { 24.dp.toPx() }.toInt()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .onSizeChanged { containerWidth = it.width },
    ) {
        val width = containerWidth
        if (width == null || textWidth <= width) {
            Text(
                text = text,
                style = style,
                color = color,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                softWrap = false,
            )
        } else {
            val distance = (textWidth + gapPx - width).toFloat().coerceAtLeast(0f)
            val durationMs = (distance / (40f / 1000f)).toInt().coerceIn(1500, 30000)
            val anim = remember { Animatable(0f) }
            LaunchedEffect(distance) {
                anim.snapTo(0f)
                delay(900)
                anim.animateTo(-distance, animationSpec = tween(durationMillis = durationMs, easing = LinearEasing))
            }
            Text(
                text = text,
                style = style,
                color = color,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Clip,
                modifier = Modifier.graphicsLayer { translationX = anim.value },
            )
        }
    }
}
