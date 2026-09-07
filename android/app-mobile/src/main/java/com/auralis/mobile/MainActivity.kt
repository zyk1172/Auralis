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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.home.HomeLayoutEditScreen
import com.auralis.feature.server.ServerFormScreen
import com.auralis.feature.server.ServerListScreen
import com.auralis.mobile.shell.MobileShell
import com.auralis.mobile.shell.SettingsPlaceholderPage

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

    /** 设置（S3：含「首页布局」编辑入口；其余项在 S7 接入）。 */
    data object Settings : Route

    /** 首页布局编辑（对齐 Apple HomeLayoutEditView；入口在 设置 → 首页布局）。 */
    data object HomeLayoutEdit : Route

    /** Mobile Shell：三一级分区 + Dock + Mini Player。 */
    data object Shell : Route
}

@Composable
private fun AppRoot(graph: AuralisGraph) {
    var route by remember { mutableStateOf<Route>(Route.Boot) }

    LaunchedEffect(graph) {
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

        Route.Settings -> SettingsPlaceholderPage(
            onOpenServers = { route = Route.ManageServers(showBack = true) },
            onEditHomeLayout = { route = Route.HomeLayoutEdit },
            onBack = { route = Route.Shell },
        )

        Route.HomeLayoutEdit -> HomeLayoutEditScreen(
            graph = graph,
            onBack = { route = Route.Settings },
        )

        Route.Shell -> MobileShell(
            graph = graph,
            onOpenServers = { route = Route.ManageServers(showBack = true) },
            onOpenSettings = { route = Route.Settings },
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
