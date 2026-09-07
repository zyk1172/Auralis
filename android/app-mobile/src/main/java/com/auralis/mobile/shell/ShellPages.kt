package com.auralis.mobile.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.BrowseDestination

/**
 * S2/S3 阶段的分区占位页。主页已替换为真实首页（feature:home）；
 * 音乐库页带顶栏齿轮入口（设置→服务器，真实可用）+ 承接 Home 的浏览目的地；
 * 真正的 Library/Browse 页面在 S4 接入。
 */

@Composable
fun LibraryPlaceholderPage(
    onOpenSettings: () -> Unit,
    browseTarget: BrowseDestination? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .padding(horizontal = AuralisSpacing.large),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "音乐库",
                style = MaterialTheme.typography.headlineMedium,
                color = colors.primaryText,
                modifier = Modifier.weight(1f),
            )
            // Settings 入口（audit 06：Library 顶栏齿轮；Settings 不做一级 Tab）。
            IconButton(onClick = onOpenSettings) {
                Icon(Icons.Filled.Settings, contentDescription = "设置", tint = colors.primaryText)
            }
        }
        Spacer(Modifier.height(AuralisSpacing.large))
        if (browseTarget != null) {
            Text(
                "${browseTarget.titleZh()}",
                style = MaterialTheme.typography.titleMedium,
                color = colors.primaryText,
            )
            Spacer(Modifier.height(AuralisSpacing.small))
            Text(
                "「${browseTarget.titleZh()}」完整列表将在 Library 阶段接入（S4）。",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
            )
        } else {
            Text(
                "音乐库（歌曲/专辑/艺人/歌单）将在 Library 阶段接入。",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
            )
        }
    }
}

/** Home 浏览目标 → 中文标题（S4 Browse 页落地前的展示映射）。 */
internal fun BrowseDestination.titleZh(): String = when (this) {
    is BrowseDestination.Album -> "专辑"
    is BrowseDestination.Artist -> "艺人"
    is BrowseDestination.Playlist -> "歌单"
    BrowseDestination.Playlists -> "歌单"
    BrowseDestination.Favorites -> "收藏"
    BrowseDestination.MostPlayed -> "最常听"
    is BrowseDestination.Genre -> "流派：${this.name}"
    is BrowseDestination.RecommendationCategory -> "推荐分类"
    BrowseDestination.Random -> "随机音乐"
    BrowseDestination.RecentlyPlayed -> "最近播放"
    BrowseDestination.RecentlyAdded -> "最近添加"
    BrowseDestination.LongUnplayed -> "很久没听"
    BrowseDestination.FavoriteRandom -> "收藏里随便听"
    BrowseDestination.NeverPlayed -> "从未播放"
    BrowseDestination.TopArtists -> "常听艺术家"
    BrowseDestination.TopAlbums -> "常听专辑"
    BrowseDestination.Downloads -> "下载"
}

@Composable
fun AssistantPlaceholderPage(
    onOpenSearch: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .padding(horizontal = AuralisSpacing.large),
    ) {
        Spacer(Modifier.height(AuralisSpacing.medium))
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "AI 助手",
                style = MaterialTheme.typography.headlineMedium,
                color = colors.primaryText,
                modifier = Modifier.weight(1f),
            )
            // 对齐 Swift AssistantView header：搜索是「助手内的兜底能力」，从这里以
            // sheet 拉起「搜索音乐库」。S6 提前启用真实搜索页；S8 重做助手主体时保留。
            IconButton(onClick = onOpenSearch) {
                Icon(Icons.Filled.Search, contentDescription = "搜索音乐库", tint = colors.primaryText)
            }
        }
        Spacer(Modifier.height(AuralisSpacing.large))
        Text(
            "AI 助手（对话与工具授权）将在 Assistant 阶段接入。搜索音乐库已可用。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
    }
}

/** 设置占位页（S2 含真实「服务器」入口；S3 新增「首页布局」编辑入口；其余在 S7 接入）。 */
@Composable
fun SettingsPlaceholderPage(
    onOpenServers: () -> Unit,
    onEditHomeLayout: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = colors.primaryText)
            }
            Spacer(Modifier.width(AuralisSpacing.small))
            Text("设置", style = MaterialTheme.typography.titleLarge, color = colors.primaryText)
        }
        SettingsRow(title = "服务器", subtitle = "连接音乐服务器与下载服务", onClick = onOpenServers)
        HorizontalDivider(color = colors.separator)
        SettingsRow(title = "首页布局", subtitle = "模块显示与排序", onClick = onEditHomeLayout)
        HorizontalDivider(color = colors.separator)
        Text(
            "其余设置项（主题/流质量/下载/历史等）将在 Settings 阶段接入。",
            style = MaterialTheme.typography.bodySmall,
            color = colors.secondaryText,
            modifier = Modifier.padding(AuralisSpacing.large),
        )
    }
}

@Composable
internal fun SettingsRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = colors.secondaryText)
    }
}
