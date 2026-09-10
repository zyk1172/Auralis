// SPDX-License-Identifier: GPL-3.0-only
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
import androidx.compose.runtime.collectAsState
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
import com.auralis.core.designsystem.rememberSystemReduceMotion
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.assistant.AssistantCoordinator
import com.auralis.feature.home.HomeLayoutEditScreen
import com.auralis.feature.server.ServerFormScreen
import com.auralis.feature.server.ServerListScreen
import com.auralis.feature.settings.AiSettingsPage
import com.auralis.feature.settings.SettingsScreen
import com.auralis.mobile.shell.MobileShell

/**
 * Single-activity mobile composition root.
 *
 * The long-lived [MobileShell] remains composed behind settings/server overlays so transient shell
 * state (browse destination, Now Playing, scroll positions and dock state) is not destroyed merely
 * because the user opens Settings. Playback itself remains owned by MediaSessionService.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            val reduceMotion = rememberSystemReduceMotion()
            AuralisTheme(
                theme = AuralisThemeController.observe(),
                reduceMotion = reduceMotion,
            ) {
                val app = application as AuralisApp
                AppRoot(app.graph)
            }
        }
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
    var route by remember { mutableStateOf<Route>(Route.Boot) }
    var shellReady by remember { mutableStateOf(false) }
    var startRecommendationIndexToken by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()
    val assistantCoordinator = remember(graph, scope) { AssistantCoordinator(graph, scope) }
    val recommendationIndexState by assistantCoordinator.recommendationIndex.collectAsState()

    LaunchedEffect(graph) {
        runCatching { graph.bootstrapFromLocal() }
        val savedTheme = runCatching { graph.preferences.selectedThemeId() }.getOrNull()
        AuralisThemeController.current = BuiltInThemes.byId(savedTheme)
        val saved = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        shellReady = saved.isNotEmpty()
        route = if (shellReady) Route.Shell else Route.ManageServers(showBack = false)
    }

    Box(Modifier.fillMaxSize()) {
        // Keep the shell alive under opaque overlays. This deliberately preserves remember/saveable
        // state and lazy-list positions while settings/server pages are open.
        if (shellReady && route !is Route.Boot) {
            MobileShell(
                graph = graph,
                assistantCoordinator = assistantCoordinator,
                onOpenServers = { route = Route.ManageServers(showBack = true) },
                onOpenSettings = { route = Route.Settings },
                onOpenAiSettings = { route = Route.AiSettings },
                onOpenEditHomeLayout = { route = Route.HomeLayoutEdit },
                recommendationIndexState = recommendationIndexState,
                startRecommendationIndexToken = startRecommendationIndexToken,
                onRecommendationIndexStartConsumed = { startRecommendationIndexToken = 0 },
            )
        }

        when (val current = route) {
            Route.Boot -> BootSplash()
            Route.Shell -> Unit

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

            is Route.AddServer -> ServerFormScreen(
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

            is Route.EditServer -> ServerFormScreen(
                graph = graph,
                existing = current.account,
                onSuccess = {
                    shellReady = true
                    route = Route.ManageServers(showBack = true)
                },
                onBack = { route = Route.ManageServers(showBack = true) },
            )

            Route.Settings -> SettingsScreen(
                graph = graph,
                onBack = { route = Route.Shell },
                onOpenServers = { route = Route.ManageServers(showBack = true) },
                onEditHomeLayout = { route = Route.HomeLayoutEdit },
                onOpenAiSettings = { route = Route.AiSettings },
                recommendationIndexState = recommendationIndexState,
                onStartRecommendationIndex = {
                    startRecommendationIndexToken += 1
                    route = Route.Shell
                },
                onCancelRecommendationIndex = assistantCoordinator::cancelRecommendationIndexBuild,
                onRefreshRecommendationIndex = assistantCoordinator::refreshRecommendationIndexStatus,
            )

            Route.AiSettings -> AiSettingsPage(
                graph = graph,
                onBack = { route = Route.Settings },
            )

            Route.HomeLayoutEdit -> HomeLayoutEditScreen(
                graph = graph,
                onBack = { route = Route.Settings },
            )
        }
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
