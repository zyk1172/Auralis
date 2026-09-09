// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlin.math.max

/**
 * Android 对 Apple `NowPlayingArtworkGlowView` / `ArtworkAmbientLight` 的等价实现。
 *
 * 产品语义直接以 Swift 为准：
 * - 主光源是真实封面的低分辨率副本，而不是纯 accent 矩形；
 * - Glow 画布约为封面 1.5 倍，主光副本约 1.28 倍；
 * - blur = max(12dp, artworkSize * 0.10)；
 * - 播放中以 0.99↔1.04、0.30↔0.44 做低速呼吸；暂停保持 1.0 / 0.30；
 * - Reduce Motion 时完全静止；
 * - 用离屏径向 DstIn mask 把真实封面光晕淡出到透明，避免形成矩形底板；
 * - artworkKey 缺失时退化为主题 accent / accentSecondary 的极轻径向补光。
 *
 * Apple 端还会对实际封面做一次 24×24 调色板采样。Android 目前不重复做图像 CPU
 * 分析，避免在 Now Playing 热路径增加解码开销；真实封面本身仍是主要光源，主题色只用于
 * 无封面兜底和极轻方向补光。
 */
@Composable
internal fun NowPlayingArtworkGlow(
    track: Track,
    artworkSize: Dp,
    maxCanvasSize: Dp,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current

    val requestedCanvas = artworkSize * 1.5f
    val canvasSize = minOf(requestedCanvas, maxCanvasSize).coerceAtLeast(artworkSize)
    val lightFrame = canvasSize * 1.28f
    val blurRadius = max(12f, artworkSize.value * 0.10f).dp

    val animates = isPlaying && !reduceMotion
    val infinite = rememberInfiniteTransition(label = "now-playing-artwork-glow")
    val animatedScale = infinite.animateFloat(
        initialValue = 0.99f,
        targetValue = 1.04f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1_800),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "now-playing-artwork-glow-scale",
    ).value
    val animatedAlpha = infinite.animateFloat(
        initialValue = 0.30f,
        targetValue = 0.44f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1_800),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "now-playing-artwork-glow-alpha",
    ).value

    val glowScale = if (animates) animatedScale else 1f
    val glowAlpha = if (animates) animatedAlpha else 0.30f
    val shape = RoundedCornerShape(artworkSize * 0.0514f) // 350dp artwork ≈ Apple 18pt artwork radius.

    Box(
        modifier = modifier.size(artworkSize),
        contentAlignment = Alignment.Center,
    ) {
        if (track.artworkKey != null) {
            AuralisArtwork(
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                contentDescription = null,
                titleForFallback = track.albumTitle,
                targetSizeDp = lightFrame.value.toInt().coerceAtLeast(64),
                shape = shape,
                modifier = Modifier
                    .requiredSize(lightFrame)
                    .graphicsLayer {
                        scaleX = glowScale
                        scaleY = glowScale
                        alpha = glowAlpha
                        compositingStrategy = CompositingStrategy.Offscreen
                    }
                    .blur(blurRadius)
                    .drawWithCache {
                        val maskCenter = Offset(size.width / 2f, size.height / 2f)
                        val radialMask = Brush.radialGradient(
                            0.0f to Color.White,
                            0.56f to Color.White.copy(alpha = 0.72f),
                            1.0f to Color.Transparent,
                            center = maskCenter,
                            radius = size.minDimension * 0.50f,
                        )
                        onDrawWithContent {
                            drawContent()
                            drawRect(
                                brush = radialMask,
                                blendMode = BlendMode.DstIn,
                            )
                        }
                    },
            )
        } else {
            Canvas(Modifier.requiredSize(canvasSize)) {
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            colors.accent.copy(alpha = 0.16f * glowAlpha / 0.30f),
                            colors.accentSecondary.copy(alpha = 0.06f * glowAlpha / 0.30f),
                            Color.Transparent,
                        ),
                        center = center,
                        radius = size.minDimension * 0.50f,
                    ),
                    radius = size.minDimension * 0.50f,
                    center = center,
                )
            }
        }

        // Swift 的低透明方向补光椭圆：只提供环境亮度，不形成独立卡片。
        Canvas(
            Modifier
                .requiredSize(canvasSize)
                .graphicsLayer {
                    scaleX = glowScale
                    scaleY = glowScale
                    alpha = glowAlpha * 0.35f
                },
        ) {
            val ellipseWidth = size.width * 0.90f
            val ellipseHeight = size.height * 0.55f
            val topLeft = Offset(
                x = (size.width - ellipseWidth) / 2f,
                y = (size.height - ellipseHeight) / 2f - size.height * 0.04f,
            )
            drawOval(
                brush = Brush.radialGradient(
                    colors = listOf(
                        colors.accentSecondary.copy(alpha = 0.12f),
                        colors.accentSecondary.copy(alpha = 0.04f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width / 2f, size.height / 2f - size.height * 0.04f),
                    radius = size.minDimension * 0.42f,
                ),
                topLeft = topLeft,
                size = Size(ellipseWidth, ellipseHeight),
            )
        }
    }
}
