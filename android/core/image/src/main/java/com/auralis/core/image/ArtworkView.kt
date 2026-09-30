// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.image

import androidx.compose.foundation.Image
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
import coil.compose.AsyncImagePainter
import coil.compose.rememberAsyncImagePainter
import coil.imageLoader
import coil.request.ImageRequest
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerId
import kotlin.math.max

/**
 * 封面 URL 解析入口。
 *
 * 声明为 `suspend` 而不是普通函数：实现需要读取服务器凭据（Keystore 解密）并构造带签名的
 * URL，历史上用 `runBlocking` 包了一个 suspend 调用 —— 一旦调用点位于 Main，就会直接阻塞
 * 主线程。保持挂起语义后，任何调用方都必须在自己的协程/调度器上等待。
 */
interface ArtworkUrlProvider {
    suspend fun url(serverId: ServerId, artworkKey: String, size: Int): String?
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
 *
 * ## 为什么不再使用 `SubcomposeAsyncImage`
 *
 * `SubcomposeAsyncImage` 通过 `SubcomposeLayout` 在测量阶段**再次组合** loading/error/success
 * 三个槽位，Coil 官方明确说明它比 `AsyncImage` 慢。资料库网格与首页货架一屏可以同时挂载
 * 40–90 张封面，这份子组合成本会直接体现在滚动帧率上。
 *
 * 这里改为 `rememberAsyncImagePainter` + `Image`：不引入子组合，同时通过 `painter.state`
 * 精确决定何时显示首字标 fallback（成功后不再叠加 fallback 图层）。
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
            // 保持挂起：provider 内部会读取凭据并构造签名 URL。
            runCatching { provider.url(serverId, artworkKey, requestSize) }.getOrNull()
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

    val painter = rememberAsyncImagePainter(imageRequest)

    Box(
        modifier = modifier.clip(shape),
        contentAlignment = Alignment.Center,
    ) {
        // Coil 2.x 的 `AsyncImagePainter.state` 就是 Compose 可观察状态（不是 Flow），
        // 因此可以直接在这里读取：只有 state 变化时才会重组这一层。
        // 只在尚未成功时绘制 fallback，避免它长期停留在成功图层下方参与合成。
        if (painter.state !is AsyncImagePainter.State.Success) {
            FallbackArtwork(
                label = titleForFallback,
                accent = theme.colors.accent,
                surface = theme.colors.surface,
                targetSizeDp = targetSizeDp,
                modifier = Modifier.fillMaxSize(),
            )
        }
        Image(
            painter = painter,
            contentDescription = contentDescription,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
    }
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

/**
 * 清空封面缓存。
 *
 * 优先走 Coil 自己的 `ImageLoader`：直接删除 `cacheDir/image_cache` 下的文件会与正在运行的
 * `DiskLruCache` journal 失配。文件删除仅作为兜底保留。
 */
@OptIn(coil.annotation.ExperimentalCoilApi::class)
fun clearArtworkCaches(context: android.content.Context) {
    runCatching {
        val loader = context.imageLoader
        loader.memoryCache?.clear()
        loader.diskCache?.clear()
    }.onFailure {
        runCatching {
            val cacheDir = java.io.File(context.cacheDir, "image_cache")
            if (cacheDir.exists()) cacheDir.listFiles()?.forEach { it.deleteRecursively() }
        }
    }
}
