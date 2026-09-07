package com.auralis.tv

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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.BuiltInThemes
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.home.HomeLayoutEditScreen
import com.auralis.feature.server.ServerFormScreen
import com.auralis.feature.server.ServerListScreen
import com.auralis.feature.settings.AiSettingsPage
import com.auralis.feature.settings.SettingsScreen

/**
 * TV 单 Activity + 顶层路由（S9）。
 *
 * 对齐基准 = 移动端核心能力 + Android TV 惯例：
 * - 有已存服务器 → TvShell（顶栏分区导航 + 正在播放条）；无 → 服务器列表（空态引导）。
 * - 设置 / AI 连接配置 / 首页布局编辑 / 服务器管理 = 覆盖路由（同移动端语义）；
 *   TV 不装配 Assistant（无 AI 助手分区与会话 UI），但保留 AI 连接/授权配置入口。
 * - 整棵 Compose 树包在 [ProvideTvIndication] 下：feature 复用页面的 clickable
 *   聚焦即显示 accent 焦点环（D-pad 全程可见）。
 */
class TvMainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            AuralisTheme(theme = AuralisThemeController.observe()) {
                ProvideTvIndication {
                    val app = application as AuralisTvApp
                    AppRoot(app.graph)
                }
            }
        }
    }
}

private sealed interface Route {
    data object Boot : Route

    /** 服务器列表。showBack = 是否由 Shell/设置 覆盖进入。 */
    data class ManageServers(val showBack: Boolean) : Route
    data class AddServer(val fromManage: Boolean) : Route
    data class EditServer(val account: ServerAccount, val fromManage: Boolean) : Route

    /** 设置（复用 feature:settings，AI 行指向连接配置页）。 */
    data object Settings : Route

    /** AI 连接配置（对齐 Swift AIProviderSettingsPage；仅连接/Key/授权，无会话 UI）。 */
    data object AiSettings : Route

    /** 首页布局编辑（复用 feature:home）。 */
    data object HomeLayoutEdit : Route

    /** TV 壳：首页 / 音乐库 / 搜索 + 正在播放条。 */
    data object Shell : Route
}

@Composable
private fun AppRoot(graph: AuralisGraph) {
    var route by remember { mutableStateOf<Route>(Route.Boot) }

    LaunchedEffect(graph) {
        // Application 已在后台做同一恢复；这里再执行一次幂等本地 bootstrap，作为进入
        // Shell 前的确定性屏障，避免 Activity 首帧先于后台协程而看到空 Registry。
        runCatching { graph.bootstrapFromLocal() }

        // 冷启动恢复上次选择的主题（DataStore 已持久化）。
        val savedTheme = runCatching { graph.preferences.selectedThemeId() }.getOrNull()
        AuralisThemeController.current = BuiltInThemes.byId(savedTheme)
        val saved = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        route = if (saved.isEmpty()) Route.ManageServers(showBack = false) else Route.Shell
    }

    when (val current = route) {
        Route.Boot -> TvSplash()

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

        Route.Shell -> TvShell(
            graph = graph,
            onOpenSettings = { route = Route.Settings },
            onOpenServers = { route = Route.ManageServers(showBack = true) },
        )
    }
}

@Composable
private fun TvSplash() {
    val colors = LocalAuralisTheme.current.colors
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "Auralis TV",
            style = MaterialTheme.typography.headlineMedium,
            color = colors.primaryText,
        )
    }
}
