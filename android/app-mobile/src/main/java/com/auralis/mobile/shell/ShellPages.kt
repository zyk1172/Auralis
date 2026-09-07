package com.auralis.mobile.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme

/**
 * S2 阶段的分区占位页。主页展示**真实**服务器摘要（无 Fake），
 * 音乐库页带顶栏齿轮入口（设置→服务器，真实可用）；真正的页面在 S3/S4/S8 替换。
 */

@Composable
fun HomePlaceholderPage(
    graph: AuralisGraph,
    onManageServers: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var servers by remember { mutableStateOf<List<com.auralis.core.domain.ServerAccount>>(emptyList()) }
    var activeId by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(graph) {
        servers = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        activeId = graph.preferences.activeServerIdValue()
        loaded = true
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .padding(horizontal = AuralisSpacing.large),
    ) {
        Spacer(Modifier.height(AuralisSpacing.medium))
        Text("首页", style = MaterialTheme.typography.headlineMedium, color = colors.primaryText)
        Spacer(Modifier.height(AuralisSpacing.large))

        if (!loaded) return@Column
        val active = servers.firstOrNull { it.id.value == activeId } ?: servers.firstOrNull()
        if (active == null) {
            // 无服务器：引导添加（真实动作）。
            Column(verticalArrangement = Arrangement.spacedBy(AuralisSpacing.small)) {
                Text("尚未连接服务器", style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
                Text(
                    "连接 OpenSubsonic 服务器后，你的音乐库会出现在这里。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.secondaryText,
                )
                Spacer(Modifier.height(AuralisSpacing.medium))
                Button(onClick = onManageServers) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text("添加服务器")
                }
            }
        } else {
            ServerSummaryCard(
                displayName = active.displayName,
                masked = com.auralis.feature.server.maskedUrl(active.baseUrl),
                onClick = onManageServers,
            )
            Spacer(Modifier.height(AuralisSpacing.large))
            Text(
                "首页内容（快捷入口/各模块）将在 Home 阶段接入。",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
            )
        }
    }
}

@Composable
private fun ServerSummaryCard(
    displayName: String,
    masked: String,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .clickable(onClick = onClick)
            .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("当前服务器", style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
            Text(displayName, style = MaterialTheme.typography.bodyLarge, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (masked.isNotEmpty()) {
                Text(masked, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = "管理服务器", tint = colors.secondaryText)
    }
}

@Composable
fun LibraryPlaceholderPage(
    onOpenSettings: () -> Unit,
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
        Text(
            "音乐库（歌曲/专辑/艺人/歌单）将在 Library 阶段接入。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
    }
}

@Composable
fun AssistantPlaceholderPage(modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .padding(horizontal = AuralisSpacing.large),
    ) {
        Spacer(Modifier.height(AuralisSpacing.medium))
        Text("AI 助手", style = MaterialTheme.typography.headlineMedium, color = colors.primaryText)
        Spacer(Modifier.height(AuralisSpacing.large))
        Text(
            "AI 助手（对话与工具授权）将在 Assistant 阶段接入。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
    }
}

/** 设置占位页（S2 仅含真实可用的「服务器」入口行；其余设置项在 S7 接入）。 */
@Composable
fun SettingsPlaceholderPage(
    onOpenServers: () -> Unit,
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
