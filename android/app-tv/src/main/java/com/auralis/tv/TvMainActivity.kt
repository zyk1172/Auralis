// SPDX-License-Identifier: GPL-3.0-only
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
import com.auralis.core.designsystem.rememberSystemReduceMotion
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.home.HomeLayoutEditScreen
import com.auralis.feature.server.ServerFormScreen
import com.auralis.feature.server.ServerListScreen
import com.auralis.feature.settings.AiSettingsPage
import com.auralis.feature.settings.SettingsScreen

/**
 * TV single-activity composition root. The shell stays alive behind route overlays so focus,
 * selected section and browse state survive settings/server management round-trips.
 */
class TvMainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
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

    LaunchedEffect(graph) {
        runCatching { graph.bootstrapFromLocal() }
        val savedTheme = runCatching { graph.preferences.selectedThemeId() }.getOrNull()
        AuralisThemeController.current = BuiltInThemes.byId(savedTheme)
        val saved = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        shellReady = saved.isNotEmpty()
        route = if (shellReady) Route.Shell else Route.ManageServers(showBack = false)
    }

    Box(Modifier.fillMaxSize()) {
        if (shellReady && route != Route.Boot) {
            TvShell(
                graph = graph,
                onOpenSettings = { route = Route.Settings },
                onOpenServers = { route = Route.ManageServers(showBack = true) },
            )
        }

        when (val current = route) {
            Route.Boot -> TvSplash()
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
