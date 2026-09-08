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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.SubcomposeAsyncImage
import coil.request.ImageRequest
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 封面 URL 生成器。由 App 组合根装配（需要对应 OpenSubsonicClient 的
 * `getCoverArt?id=&size=`）。**key 必须包含 serverId**：不同服务器可能出现相同 ID。
 *
 * provider 目前是同步接口，但真实实现可能读取 Keystore 并生成认证签名；调用方必须
 * 把它视为潜在阻塞操作，不能直接在 Compose 主线程执行。
 */
fun interface ArtworkUrlProvider {
    fun url(serverId: ServerId, artworkKey: String, size: Int): String?
}

object ArtworkUrl {
    @Volatile
    var provider: ArtworkUrlProvider? = null
}

/** 尺寸档位（对齐 Apple getCoverArt size 1..4096）：取最近 ≥2 幂档。 */
fun tieredSize(pixelSize: Int): Int {
    var tier = 64
    while (tier < pixelSize && tier < 2048) tier *= 2
    return tier.coerceIn(1, 4096)
}

/**
 * Auralis 封面。
 *
 * - 请求 = `getCoverArt&size=`（服务端缩放），不要永远下原图再缩放；
 * - URL 解析放到 IO dispatcher，避免 Token/Keystore 读取阻塞 Compose 主线程；
 * - OpenSubsonic token URL 每次可能带不同 salt，Coil 缓存键因此不能直接使用完整 URL；
 *   使用 serverId + artworkKey + size 的稳定键，避免同一封面因签名变化反复下载；
 * - 无封面 / 加载失败 → 圆角渐变占位 + 首字母字标。
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
        if (resolvedUrl == null || cacheKey == null) {
            null
        } else {
            ImageRequest.Builder(context)
                .data(resolvedUrl)
                .memoryCacheKey(cacheKey)
                .diskCacheKey(cacheKey)
                .build()
        }
    }

    if (imageRequest == null) {
        FallbackArtwork(
            label = titleForFallback,
            accent = theme.colors.accent,
            surface = theme.colors.surface,
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
                modifier = Modifier.fillMaxSize(),
            )
        },
        error = {
            FallbackArtwork(
                label = titleForFallback,
                accent = theme.colors.accent,
                surface = theme.colors.surface,
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
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier.background(
            Brush.linearGradient(listOf(surface, surface.copy(alpha = 0.7f)))
        ),
        contentAlignment = Alignment.Center,
    ) {
        val theme = LocalAuralisTheme.current
        androidx.compose.material3.Text(
            text = label?.take(1)?.uppercase() ?: "♪",
            color = if (label.isNullOrBlank()) accent else theme.colors.primaryText.copy(alpha = 0.85f),
            fontWeight = FontWeight.Bold,
            fontSize = 18.sp,
        )
    }
}

/**
 * 清空封面图片磁盘缓存（coil 默认 `cacheDir/image_cache`），对齐 Swift `clearArtworkCache`。
 * 封面只按需从服务器重新加载，不删除任何音乐库元数据；coil 下次加载时会自动重建目录。
 */
fun clearArtworkCaches(context: android.content.Context) {
    runCatching {
        val cacheDir = java.io.File(context.cacheDir, "image_cache")
        if (cacheDir.exists()) {
            cacheDir.listFiles()?.forEach { it.deleteRecursively() }
        }
    }
}
