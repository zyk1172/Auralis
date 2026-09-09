// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import androidx.annotation.StringRes
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.LocalReduceMotion
import kotlinx.coroutines.delay
import kotlin.math.max

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
 * 与 Swift `MarqueeLayoutPolicy` 同构：最多允许标题静态缩小到 86%，只有连 86% 都放不下
 * 才启动单向跑马灯。这样轻微超宽的歌名不会不必要地等待动画。
 */
internal object MarqueeLayoutPolicy {
    const val minimumScaleFactor = 0.86f

    fun shouldScroll(textWidth: Float, containerWidth: Float): Boolean {
        if (containerWidth <= 0f) return false
        return textWidth > containerWidth / minimumScaleFactor
    }

    fun staticScale(textWidth: Float, containerWidth: Float): Float {
        if (textWidth <= 0f || containerWidth <= 0f || textWidth <= containerWidth) return 1f
        return (containerWidth / textWidth).coerceIn(minimumScaleFactor, 1f)
    }

    /** Swift 当前速度约 10pt/s，并保证一次滚动至少 9 秒。 */
    fun durationMillis(distancePx: Float, pixelsPerDp: Float): Int {
        if (distancePx <= 0f || pixelsPerDp <= 0f) return 0
        val distanceDp = distancePx / pixelsPerDp
        return max(9_000, (distanceDp / 10f * 1_000f).toInt())
    }
}

/**
 * 单向慢速跑马灯，严格跟随 Swift `OneShotMarqueeText` 的行为：
 *
 * - 静态文本优先真正居中；轻微超宽最多缩小到 86%；
 * - 只有 86% 仍放不下时才滚动；
 * - 等待 1.6 秒后以约 10dp/s 从头移动到末尾一次，至少持续 9 秒，完成后停住；
 * - Reduce Motion 时不启动滚动；
 * - 切歌会重建 `Animatable`，不会继承上一首的末端偏移；
 * - 文本始终裁剪在自己的槽内，不能撑宽播放页。
 */
@Composable
internal fun AutoMarqueeText(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val reduceMotion = LocalReduceMotion.current
    val textMeasurer = rememberTextMeasurer()
    var containerWidth by remember { mutableStateOf<Int?>(null) }
    val measured = remember(text, style) {
        textMeasurer.measure(text, style, constraints = Constraints(maxWidth = 8192))
    }
    val textWidth = measured.size.width.toFloat()
    val intrinsicWidth = with(density) { textWidth.toDp() }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clipToBounds()
            .onSizeChanged { containerWidth = it.width },
    ) {
        val width = containerWidth?.toFloat()
        if (width == null || width <= 0f) {
            Text(
                text = text,
                style = style,
                color = color,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                softWrap = false,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            return@Box
        }

        val shouldScroll = MarqueeLayoutPolicy.shouldScroll(textWidth, width)
        if (!shouldScroll) {
            val scale = MarqueeLayoutPolicy.staticScale(textWidth, width)
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text(
                    text = text,
                    style = style,
                    color = color,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .width(intrinsicWidth)
                        .graphicsLayer {
                            scaleX = scale
                            scaleY = scale
                            transformOrigin = TransformOrigin.Center
                        },
                )
            }
        } else {
            val distance = (textWidth - width).coerceAtLeast(0f)
            val durationMs = MarqueeLayoutPolicy.durationMillis(distance, density.density)
            val anim = remember(text) { Animatable(0f) }
            LaunchedEffect(text, distance, reduceMotion) {
                anim.snapTo(0f)
                if (distance <= 1f || reduceMotion) return@LaunchedEffect
                delay(1_600)
                anim.animateTo(
                    targetValue = -distance,
                    animationSpec = tween(durationMillis = durationMs, easing = LinearEasing),
                )
            }
            Text(
                text = text,
                style = style,
                color = color,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Clip,
                modifier = Modifier
                    .width(intrinsicWidth)
                    .graphicsLayer { translationX = anim.value },
            )
        }
    }
}
