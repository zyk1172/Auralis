// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.library

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track

/** 时长格式化（对齐 Swift `formatDuration`：m:ss）。 */
fun formatDurationSeconds(seconds: Double): String {
    val total = seconds.toInt().coerceAtLeast(0)
    return "%d:%02d".format(total / 60, total % 60)
}

/**
 * 资料库 7 个 scope（对齐 Swift `LibraryScope`，默认 = Albums）。
 * Categories（AI 推荐索引分类）在 Android 第一版不提供数据源（见
 * [com.auralis.core.domain.Categories]），scope 保留但显示能力说明，不拿假数据。
 */
enum class LibraryScope {
    Albums, Tracks, Artists, Playlists, Favorites, Genres, Categories;

    /** 分段标题资源。专辑/歌曲/艺术家/歌单/收藏 与共享层同词 → 复用 AuralisR；流派/分类为模块独有。 */
    @StringRes
    fun titleRes(): Int = when (this) {
        Albums -> AuralisR.string.album
        Tracks -> AuralisR.string.song
        Artists -> AuralisR.string.artist
        Playlists -> AuralisR.string.playlist
        Favorites -> AuralisR.string.favorite
        Genres -> R.string.library_scope_genres
        Categories -> R.string.library_scope_categories
    }
}

fun LibraryScope.icon(): ImageVector = when (this) {
    LibraryScope.Albums -> Icons.Filled.Album
    LibraryScope.Tracks -> Icons.Filled.MusicNote
    LibraryScope.Artists -> Icons.Filled.Person
    LibraryScope.Playlists -> Icons.AutoMirrored.Filled.QueueMusic
    LibraryScope.Favorites -> Icons.Filled.Favorite
    LibraryScope.Genres -> Icons.Filled.Headphones
    LibraryScope.Categories -> Icons.Filled.GridView
}

/** 数据已就绪的 Flow 收集；未就绪返回 null（用于 loading 首帧区分）。 */
@Composable
fun <T> rememberFlowValue(producer: () -> kotlinx.coroutines.flow.Flow<T>): T? {
    val flow = remember(producer) { producer() }
    val value by flow.collectAsState(initial = null)
    return value
}

/** 当前激活服务器（preferences 观察；null = 未设置）。 */
@Composable
fun rememberActiveServerId(graph: AuralisGraph): ServerId? {
    val raw by graph.preferences.activeServerIdFlow.collectAsState(initial = null)
    return raw?.let { ServerId(it) }
}

/** 单曲下载状态（行级观察；record == null 表示从未下载）。 */
@Composable
fun rememberDownloadRecord(graph: AuralisGraph, track: Track): DownloadRecord? {
    val record by remember(track.globalId) { graph.catalogRepository.observe(track.globalId) }
        .collectAsState(initial = null)
    return record
}

/** 加载中占位（资料库各级内容共用）；message == null 用默认「正在加载…」。 */
@Composable
fun LibraryLoadingBox(message: String? = null, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            androidx.compose.material3.CircularProgressIndicator(color = colors.accent)
            Text(
                message ?: stringResource(R.string.library_loading),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
                modifier = Modifier.padding(top = AuralisSpacing.medium),
            )
        }
    }
}

/**
 * 资料库空状态（对齐 Swift `AuralisEmptyState`）。
 * 只负责展示文案；数据永远来自真实查询结果，禁止拿占位/假数据冒充空态。
 */
@Composable
fun LibraryEmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.xLarge, vertical = AuralisSpacing.huge),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.LibraryMusic,
            contentDescription = null,
            tint = colors.secondaryText.copy(alpha = 0.7f),
            modifier = Modifier.size(44.dp),
        )
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.primaryText,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = AuralisSpacing.medium),
        )
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = AuralisSpacing.small),
        )
        if (actionLabel != null && onAction != null) {
            androidx.compose.material3.TextButton(onClick = onAction) {
                Text(actionLabel, color = colors.accent)
            }
        }
    }
}

/** 供列表组/详情页使用的统一「从某列表播放」去重语义：保持顺序、按 globalId 去重。 */
fun uniquedByGlobalId(tracks: List<Track>): List<Track> {
    val seen = HashSet<String>()
    return tracks.filter { seen.add(it.globalId.serialized) }
}

/** 详情页列表「限长」（对齐 Swift BrowseDetail 的 prefix 200 / 常规整组）。 */
const val DETAIL_TRACK_CAP = 1000

/** 卡片统一圆角（对齐 Apple `AuralisRadius.artwork` = 18 的卡片风格）。 */
fun cardShape() = RoundedCornerShape(AuralisRadius.artwork)

/** 状态色辅助：分隔线颜色由主题统一提供，这里只做间距常数。 */
object LibraryDimens {
    val gridSpacingH: androidx.compose.ui.unit.Dp = AuralisSpacing.medium
    val gridSpacingV: androidx.compose.ui.unit.Dp = AuralisSpacing.large
}
