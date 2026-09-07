package com.auralis.core.image

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.SubcomposeAsyncImage
import com.auralis.core.domain.ServerId
import com.auralis.core.designsystem.LocalAuralisTheme

/**
 * 封面 URL 生成器。由 App 组合根装配（需要对应 OpenSubsonicClient 的
 * `getCoverArt?id=&size=`）。**key 必须包含 serverId**：不同服务器可能出现相同 ID。
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
    val url = remember(serverId, artworkKey, targetSizeDp) {
        if (artworkKey.isNullOrBlank()) {
            null
        } else {
            ArtworkUrl.provider?.url(serverId, artworkKey, tieredSize(targetSizeDp))
        }
    }
    if (url == null) {
        FallbackArtwork(
            label = titleForFallback,
            accent = theme.colors.accent,
            surface = theme.colors.surface,
            modifier = modifier.clip(shape),
        )
        return
    }
    SubcomposeAsyncImage(
        model = url,
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
