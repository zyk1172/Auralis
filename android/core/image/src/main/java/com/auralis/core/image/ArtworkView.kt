// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.image

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.SubcomposeAsyncImage
import coil.request.ImageRequest
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

fun interface ArtworkUrlProvider {
    fun url(serverId: ServerId, artworkKey: String, size: Int): String?
}

object ArtworkUrl {
    @Volatile
    var provider: ArtworkUrlProvider? = null
}

fun tieredSize(pixelSize: Int): Int {
    var tier = 64
    while (tier < pixelSize && tier < 2048) tier *= 2
    return tier.coerceIn(1, 4096)
}

/**
 * Auralis 封面。请求策略保持 Android 原有的稳定缓存键/服务端缩放；视觉 fallback
 * 对齐 Apple `AuralisArtwork`：首字标至少 18pt，并随封面边长按 19% 增长、Bold、
 * 使用系统 sans-serif（Android 不捆绑 Apple 字体）。
 */
@Composable
fun AuralisArtwork(
    serverId: ServerId,
    artworkKey: String?,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(8.dp),
    titleForFallback: String? = null,
    targetSizeDp: Int = 200,
) {
    val theme = LocalAuralisTheme.current
    val context = LocalContext.current
    val requestSize = tieredSize(targetSizeDp)
    val provider = ArtworkUrl.provider

    val url by produceState<String?>(
        null,
        serverId,
        artworkKey,
        requestSize,
        provider,
    ) {
        value = if (artworkKey.isNullOrBlank() || provider == null) {
            null
        } else {
            withContext(Dispatchers.IO) {
                runCatching { provider.url(serverId, artworkKey, requestSize) }.getOrNull()
            }
        }
    }

    val stableCacheKey = remember(serverId, artworkKey, requestSize) {
        artworkKey?.takeIf { it.isNotBlank() }?.let {
            "auralis-artwork:${serverId.value}:$it:$requestSize"
        }
    }
    val imageRequest = remember(context, url, stableCacheKey) {
        val resolvedUrl = url
        val cacheKey = stableCacheKey
        if (resolvedUrl == null || cacheKey == null) null
        else ImageRequest.Builder(context)
            .data(resolvedUrl)
            .memoryCacheKey(cacheKey)
            .diskCacheKey(cacheKey)
            .build()
    }

    if (imageRequest == null) {
        FallbackArtwork(
            label = titleForFallback,
            accent = theme.colors.accent,
            surface = theme.colors.surface,
            targetSizeDp = targetSizeDp,
            modifier = modifier.clip(shape),
        )
        return
    }

    SubcomposeAsyncImage(
        model = imageRequest,
        loading = {
            FallbackArtwork(
                label = titleForFallback,
                accent = theme.colors.accent,
                surface = theme.colors.surface,
                targetSizeDp = targetSizeDp,
                modifier = Modifier.fillMaxSize(),
            )
        },
        error = {
            FallbackArtwork(
                label = titleForFallback,
                accent = theme.colors.accent,
                surface = theme.colors.surface,
                targetSizeDp = targetSizeDp,
                modifier = Modifier.fillMaxSize(),
            )
        },
        contentDescription = contentDescription,
        contentScale = ContentScale.Crop,
        modifier = modifier.clip(shape),
    )
}

@Composable
internal fun FallbackArtwork(
    label: String?,
    accent: androidx.compose.ui.graphics.Color,
    surface: androidx.compose.ui.graphics.Color,
    targetSizeDp: Int = 96,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier.background(
            Brush.linearGradient(listOf(surface, surface.copy(alpha = 0.7f))),
        ),
        contentAlignment = Alignment.Center,
    ) {
        val theme = LocalAuralisTheme.current
        androidx.compose.material3.Text(
            text = label?.take(1)?.uppercase() ?: "♪",
            color = if (label.isNullOrBlank()) accent else theme.colors.primaryText.copy(alpha = 0.85f),
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = max(18f, targetSizeDp * 0.19f).sp,
        )
    }
}

fun clearArtworkCaches(context: android.content.Context) {
    runCatching {
        val cacheDir = java.io.File(context.cacheDir, "image_cache")
        if (cacheDir.exists()) cacheDir.listFiles()?.forEach { it.deleteRecursively() }
    }
}
