// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.BuiltInThemes
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.rememberSystemReduceMotion
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.assistant.AssistantCoordinator
import com.auralis.feature.home.HomeLayoutEditScreen
import com.auralis.feature.server.ServerListScreen
import com.auralis.feature.settings.AiSettingsPage
import com.auralis.feature.settings.SettingsScreen

/**
 * TV single-activity composition root.
 *
 * Full-screen routes are mutually exclusive in the focus tree. Shell/settings keep their own
 * saveable state buckets while they are temporarily removed, so entering a detail route no longer
 * forces the user to start again from the top-level destination. Hardware Back is handled here for
 * top-level TV routes; only the first-run server picker may fall through to Activity exit.
 */
class TvMainActivity : ComponentActivity() {
    /**
     * Android 13+ 需要运行时授权 `POST_NOTIFICATIONS`，否则播放/下载前台服务的通知在 TV 上
     * 不可见（服务仍可运行）。清单已声明该权限，但历史上从未在代码里请求过。
     */
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 结果只决定通知可见性 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
        setContent {
            val reduceMotion = rememberSystemReduceMotion()
            AuralisTheme(
                theme = AuralisThemeController.observe(),
                reduceMotion = reduceMotion,
            ) {
                ProvideTvIndication {
                    val app = application as AuralisTvApp
                    AppRoot(app.graph)
                }
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        runCatching { notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }
    }
}

private sealed interface Route {
    data object Boot : Route
    data class ManageServers(val showBack: Boolean) : Route
    data class AddServer(val fromManage: Boolean) : Route
    data class EditServer(val account: ServerAccount, val fromManage: Boolean) : Route
    data object Settings : Route
    data object AiSettings : Route
    data object HomeLayoutEdit : Route
    data object Shell : Route
}

@Composable
private fun AppRoot(graph: AuralisGraph) {
    // 顶层路由必须可跨配置变化/进程重建存活：TV 上切换语言、分辨率或 HDMI 重协商都会重建
    // Activity，历史上 `remember` 会把它重置为 Boot 并重新 bootstrapFromLocal，用户被弹回启动画面。
    var route by rememberSaveable(stateSaver = TvRouteSaver) { mutableStateOf<Route>(Route.Boot) }
    var shellReady by rememberSaveable { mutableStateOf(false) }
    var startRecommendationIndexToken by remember { mutableIntStateOf(0) }
    val shellStateHolder = rememberSaveableStateHolder()
    val settingsStateHolder = rememberSaveableStateHolder()
    val scope = rememberCoroutineScope()
    val assistantCoordinator = remember(graph, scope) { AssistantCoordinator(graph, scope) }
    val recommendationIndexState by assistantCoordinator.recommendationIndex.collectAsState()

    LaunchedEffect(graph) {
        val restoredServers = runCatching { graph.bootstrapFromLocal() }.getOrDefault(emptyList())
        val savedTheme = runCatching { graph.preferences.selectedThemeId() }.getOrNull()
        AuralisThemeController.current = BuiltInThemes.byId(savedTheme)
        shellReady = restoredServers.isNotEmpty()
        // 只有仍停留在 Boot 时才决定首屏路由；否则恢复出来的路由会被冷启动逻辑覆盖。
        if (route == Route.Boot) {
            route = if (shellReady) Route.Shell else Route.ManageServers(showBack = false)
        }
    }

    val currentRoute = route
    val handleBackAtRoot = when (currentRoute) {
        Route.Boot, Route.Shell -> false
        is Route.ManageServers -> currentRoute.showBack
        else -> true
    }
    BackHandler(enabled = handleBackAtRoot) {
        route = when (val current = route) {
            Route.Settings -> Route.Shell
            Route.AiSettings -> Route.Settings
            Route.HomeLayoutEdit -> Route.Settings
            is Route.ManageServers -> if (current.showBack) Route.Shell else current
            is Route.AddServer -> Route.ManageServers(showBack = shellReady)
            is Route.EditServer -> Route.ManageServers(showBack = true)
            Route.Boot, Route.Shell -> current
        }
    }

    Box(Modifier.fillMaxSize()) {
        when (val current = route) {
            Route.Boot -> TvSplash()

            Route.Shell -> {
                if (shellReady) {
                    shellStateHolder.SaveableStateProvider("tv-shell") {
                        TvShell(
                            graph = graph,
                            assistantCoordinator = assistantCoordinator,
                            onOpenSettings = { route = Route.Settings },
                            onOpenServers = { route = Route.ManageServers(showBack = true) },
                            onOpenAiSettings = { route = Route.AiSettings },
                            recommendationIndexState = recommendationIndexState,
                            startRecommendationIndexToken = startRecommendationIndexToken,
                            onRecommendationIndexStartConsumed = { startRecommendationIndexToken = 0 },
                        )
                    }
                } else {
                    TvSplash()
                }
            }

            is Route.ManageServers -> ServerListScreen(
                graph = graph,
                onAdd = { route = Route.AddServer(fromManage = true) },
                onEdit = { account -> route = Route.EditServer(account, fromManage = true) },
                onEnter = {
                    shellReady = true
                    route = Route.Shell
                },
                onBack = if (current.showBack) ({ route = Route.Shell }) else null,
            )

            is Route.AddServer -> TvServerFormScreen(
                graph = graph,
                existing = null,
                onSuccess = {
                    shellReady = true
                    route = Route.Shell
                },
                onBack = {
                    route = if (current.fromManage) Route.ManageServers(showBack = shellReady) else Route.Shell
                },
            )

            is Route.EditServer -> TvServerFormScreen(
                graph = graph,
                existing = current.account,
                onSuccess = {
                    shellReady = true
                    route = Route.ManageServers(showBack = true)
                },
                onBack = { route = Route.ManageServers(showBack = true) },
            )

            Route.Settings -> settingsStateHolder.SaveableStateProvider("tv-settings") {
                SettingsScreen(
                    graph = graph,
                    onBack = { route = Route.Shell },
                    onOpenServers = { route = Route.ManageServers(showBack = true) },
                    onEditHomeLayout = { route = Route.HomeLayoutEdit },
                    onOpenAiSettings = { route = Route.AiSettings },
                    recommendationIndexState = recommendationIndexState,
                    onStartRecommendationIndex = {
                        assistantCoordinator.startRecommendationIndexBuild()
                        startRecommendationIndexToken += 1
                        route = Route.Shell
                    },
                    onCancelRecommendationIndex = assistantCoordinator::cancelRecommendationIndexBuild,
                    onRefreshRecommendationIndex = assistantCoordinator::refreshRecommendationIndexStatus,
                    modifier = Modifier.fillMaxSize(),
                )
            }

            Route.AiSettings -> AiSettingsPage(
                graph = graph,
                onBack = { route = Route.Settings },
                modifier = Modifier.fillMaxSize(),
            )

            Route.HomeLayoutEdit -> HomeLayoutEditScreen(
                graph = graph,
                onBack = { route = Route.Settings },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/**
 * [Route] 的可保存表示。
 *
 * 只有能够无损重建的路由才会被恢复；`AddServer` / `EditServer` 携带 `ServerAccount`
 * （不可序列化、且可能已被删除），因此退化为服务器列表页而不是回到启动画面。
 */
private val TvRouteSaver: Saver<Route, String> = Saver(
    save = { route ->
        when (route) {
            Route.Boot -> "boot"
            Route.Shell -> "shell"
            Route.Settings -> "settings"
            Route.AiSettings -> "ai-settings"
            Route.HomeLayoutEdit -> "home-layout"
            is Route.ManageServers -> if (route.showBack) "servers-back" else "servers"
            is Route.AddServer -> "servers-back"
            is Route.EditServer -> "servers-back"
        }
    },
    restore = { tag ->
        when (tag) {
            "shell" -> Route.Shell
            "settings" -> Route.Settings
            "ai-settings" -> Route.AiSettings
            "home-layout" -> Route.HomeLayoutEdit
            "servers" -> Route.ManageServers(showBack = false)
            "servers-back" -> Route.ManageServers(showBack = true)
            else -> Route.Boot
        }
    },
)

@Composable
private fun TvSplash() {
    val colors = LocalAuralisTheme.current.colors
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Image(
                painter = painterResource(R.drawable.auralis_apple_icon),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.size(112.dp),
            )
            Spacer(Modifier.height(18.dp))
            Text(
                text = "Auralis",
                style = MaterialTheme.typography.headlineMedium,
                color = colors.primaryText,
            )
        }
    }
}
