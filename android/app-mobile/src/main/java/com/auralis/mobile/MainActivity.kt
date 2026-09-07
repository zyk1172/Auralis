package com.auralis.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.server.ServerFormScreen
import com.auralis.feature.server.ServerListScreen

/**
 * 单一 Activity + 顶层路由。
 *
 * S1（服务器添加/恢复链路）阶段的页面状态机：
 * Boot → 无已存服务器 → 服务器列表（空状态引导添加）；
 * 已有服务器 → Main（占位主界面，Shell 阶段替换为 Bottom Dock）。
 * 服务器列表 / 表单从任意入口进入；编辑成功回列表，添加成功进主界面。
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

private sealed interface Screen {
    data object Boot : Screen
    data object Servers : Screen
    data object AddServer : Screen
    data class EditServer(val account: ServerAccount) : Screen

    /** 主界面占位：Mobile Shell（S2）接入前的过渡态。 */
    data object Main : Screen
}

@Composable
private fun AppRoot(graph: AuralisGraph) {
    var screen by remember { mutableStateOf<Screen>(Screen.Boot) }

    LaunchedEffect(graph) {
        val saved = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        screen = if (saved.isEmpty()) Screen.Servers else Screen.Main
    }

    when (val current = screen) {
        Screen.Boot -> BootSplash()
        Screen.Servers -> ServerListScreen(
            graph = graph,
            onAdd = { screen = Screen.AddServer },
            onEdit = { account -> screen = Screen.EditServer(account) },
            onEnter = { screen = Screen.Main },
        )

        Screen.AddServer -> ServerFormScreen(
            graph = graph,
            existing = null,
            onSuccess = { screen = Screen.Main },
            onBack = { screen = Screen.Servers },
        )

        is Screen.EditServer -> ServerFormScreen(
            graph = graph,
            existing = current.account,
            onSuccess = { screen = Screen.Servers },
            onBack = { screen = Screen.Servers },
        )

        Screen.Main -> MainPlaceholder(
            graph = graph,
            onManageServers = { screen = Screen.Servers },
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

/** S2 之前的主界面占位：展示当前服务器与入口，不伪造数据。 */
@Composable
private fun MainPlaceholder(graph: AuralisGraph, onManageServers: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    var activeName by remember { mutableStateOf<String?>(null) }
    var activeUrl by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(graph) {
        val servers = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        val active = graph.preferences.activeServerIdValue()
        val account = servers.firstOrNull { it.id.value == active } ?: servers.firstOrNull()
        if (account != null) {
            if (graph.preferences.activeServerIdValue() != account.id.value) {
                graph.preferences.setActiveServerId(account.id.value)
            }
            activeName = account.displayName
            activeUrl = account.baseUrl
        } else {
            activeName = null
            activeUrl = null
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Auralis", style = MaterialTheme.typography.headlineMedium, color = colors.primaryText)
        Spacer(Modifier.height(12.dp))
        Text(
            "当前服务器",
            style = MaterialTheme.typography.titleSmall,
            color = colors.secondaryText,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            activeName ?: "（无）",
            style = MaterialTheme.typography.bodyLarge,
            color = colors.primaryText,
        )
        if (activeUrl != null) {
            Text(
                com.auralis.feature.server.maskedUrl(activeUrl),
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
            )
        }
        Spacer(Modifier.height(24.dp))
        Text(
            "主界面（Bottom Dock）将在 Mobile Shell 阶段接入。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium)) {
            OutlinedButton(onClick = onManageServers) {
                Text("管理服务器")
            }
            Button(onClick = {}, enabled = false) {
                Text("音乐库（待接入）")
            }
        }
    }
}
