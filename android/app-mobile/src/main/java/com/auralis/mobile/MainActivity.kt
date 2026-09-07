package com.auralis.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.BuiltInThemes
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.assistant.AssistantCoordinator
import com.auralis.feature.home.HomeLayoutEditScreen
import com.auralis.feature.server.ServerFormScreen
import com.auralis.feature.server.ServerListScreen
import com.auralis.feature.settings.AiSettingsPage
import com.auralis.feature.settings.SettingsScreen
import com.auralis.mobile.shell.MobileShell

/**
 * 单一 Activity + 顶层路由。
 *
 * S2（Mobile Shell）：
 * - 有已存服务器 → Shell（Bottom Dock + Mini Player overlay）；
 *   无服务器 → 服务器列表（空状态引导添加）。
 * - Shell 内 Home 摘要卡 / Library 顶栏齿轮 → 服务器管理 / 设置（覆盖页）。
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            AuralisTheme(theme = AuralisThemeController.observe()) {
                val app = application as AuralisApp
                AppRoot(app.graph)
            }
        }
    }
}

private sealed interface Route {
    data object Boot : Route

    /** 服务器列表。showBack = 是否由 Shell 覆盖进入。 */
    data class ManageServers(val showBack: Boolean) : Route
    data class AddServer(val fromManage: Boolean) : Route
    data class EditServer(val account: ServerAccount, val fromManage: Boolean) : Route

    /** 设置（S7：真实设置页；S8：AI 助手配置已启用）。 */
    data object Settings : Route

    /** AI 助手配置（对齐 Swift AIProviderSettingsPage；入口：设置 → AI 助手 或 助手页 配置）。 */
    data object AiSettings : Route

    /** 首页布局编辑（对齐 Apple HomeLayoutEditView；入口在 设置 → 首页布局）。 */
    data object HomeLayoutEdit : Route

    /** Mobile Shell：三一级分区 + Dock + Mini Player。 */
    data object Shell : Route
}

@Composable
private fun AppRoot(graph: AuralisGraph) {
    var route by remember { mutableStateOf<Route>(Route.Boot) }
    val scope = rememberCoroutineScope()
    // AI 助手协调器：AppRoot 持有（跨分区/路由不中断运行中的对话）。
    val assistantCoordinator = remember(graph, scope) { AssistantCoordinator(graph, scope) }

    LaunchedEffect(graph) {
        // Application 同时在后台恢复；这里用幂等本地 bootstrap 作为 Shell 的确定性屏障，
        // 防止“Room 已有服务器但 Registry 尚为空”时首页/搜索/封面/首播先执行而失败。
        runCatching { graph.bootstrapFromLocal() }

        // 冷启动恢复上次选择的主题（DataStore 已持久化；S7 前未应用导致重启回默认）。
        val savedTheme = runCatching { graph.preferences.selectedThemeId() }.getOrNull()
        AuralisThemeController.current = BuiltInThemes.byId(savedTheme)
        val saved = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        route = if (saved.isEmpty()) Route.ManageServers(showBack = false) else Route.Shell
    }

    when (val current = route) {
        Route.Boot -> BootSplash()

        is Route.ManageServers -> ServerListScreen(
            graph = graph,
            onAdd = { route = Route.AddServer(fromManage = true) },
            onEdit = { account -> route = Route.EditServer(account, fromManage = true) },
            onEnter = { route = Route.Shell },
            onBack = if (current.showBack) ({ route = Route.Shell }) else null,
        )

        is Route.AddServer -> ServerFormScreen(
            graph = graph,
            existing = null,
            onSuccess = { route = Route.Shell },
            onBack = { route = if (current.fromManage) Route.ManageServers(showBack = true) else Route.Shell },
        )

        is Route.EditServer -> ServerFormScreen(
            graph = graph,
            existing = current.account,
            onSuccess = { route = Route.ManageServers(showBack = true) },
            onBack = { route = Route.ManageServers(showBack = true) },
        )

        Route.Settings -> SettingsScreen(
            graph = graph,
            onBack = { route = Route.Shell },
            onOpenServers = { route = Route.ManageServers(showBack = true) },
            onEditHomeLayout = { route = Route.HomeLayoutEdit },
            onOpenAiSettings = { route = Route.AiSettings },
        )

        Route.AiSettings -> AiSettingsPage(
            graph = graph,
            onBack = { route = Route.Settings },
        )

        Route.HomeLayoutEdit -> HomeLayoutEditScreen(
            graph = graph,
            onBack = { route = Route.Settings },
        )

        Route.Shell -> MobileShell(
            graph = graph,
            assistantCoordinator = assistantCoordinator,
            onOpenServers = { route = Route.ManageServers(showBack = true) },
            onOpenSettings = { route = Route.Settings },
            onOpenAiSettings = { route = Route.AiSettings },
            onOpenEditHomeLayout = { route = Route.HomeLayoutEdit },
        )
    }
}

@Composable
private fun BootSplash() {
    val colors = LocalAuralisTheme.current.colors
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
        contentAlignment = Alignment.Center,
    ) {
        Text("Auralis", style = MaterialTheme.typography.headlineMedium, color = colors.primaryText)
    }
}
