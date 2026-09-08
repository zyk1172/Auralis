// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.Track
import com.auralis.core.playback.LocalPlaybackHost
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import com.auralis.core.playback.awaitPlaybackController
import com.auralis.feature.assistant.AssistantCoordinator
import com.auralis.feature.assistant.AssistantScreen
import com.auralis.feature.assistant.GuidedSessions
import com.auralis.feature.home.AppleParityHomeScreen
import com.auralis.feature.library.BrowseDetailScreen
import com.auralis.feature.library.LibraryScreen
import com.auralis.feature.player.NowPlayingScreen
import com.auralis.feature.player.PlayerTrackAction
import com.auralis.feature.search.SearchScreen
import kotlinx.coroutines.launch
import com.auralis.core.designsystem.R as AuralisR

@Composable
fun MobileShell(
    graph: AuralisGraph,
    assistantCoordinator: AssistantCoordinator,
    onOpenServers: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAiSettings: () -> Unit,
    onOpenEditHomeLayout: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var section by rememberSaveable { mutableStateOf(AppSection.Home) }
    var browseDestination by remember { mutableStateOf<BrowseDestination?>(null) }
    var nowPlayingOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()

    val engineAvailable by LocalPlaybackHost.available.collectAsState()
    val controller = remember { LocalPlaybackHost.controller() }
    var playback by remember { mutableStateOf(PlaybackSnapshot.Empty) }
    var queue by remember { mutableStateOf(QueueSnapshot.Empty) }
    LaunchedEffect(controller, engineAvailable) {
        if (engineAvailable) controller.playback.collect { playback = it }
        else playback = PlaybackSnapshot.Empty
    }
    LaunchedEffect(controller, engineAvailable) {
        if (engineAvailable) controller.queue.collect { queue = it }
        else queue = QueueSnapshot.Empty
    }

    suspend fun awaitControllerOrNotify(): PlaybackController? =
        runCatching { awaitPlaybackController(startService = { graph.startPlaybackService() }) }
            .onFailure {
                android.widget.Toast.makeText(
                    context,
                    context.getString(AuralisR.string.playback_start_timeout),
                    android.widget.Toast.LENGTH_SHORT,
                ).show()
            }
            .getOrNull()

    fun playShelf(tracks: List<Track>, startIndex: Int) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching {
                ready.playQueue(tracks.map { QueueEntry.of(it) }, startIndex.coerceIn(0, tracks.lastIndex))
            }
        }
    }

    fun playNextShelf(tracks: List<Track>) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.insertNext(tracks.map { QueueEntry.of(it) }) }
        }
    }

    fun appendQueueShelf(tracks: List<Track>) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.appendToQueue(tracks.map { QueueEntry.of(it) }) }
        }
    }

    fun openBrowse(destination: BrowseDestination) {
        nowPlayingOpen = false
        searchOpen = false
        browseDestination = destination
        section = AppSection.Library
    }

    fun openGuidedAssistant(track: Track, action: PlayerTrackAction) {
        nowPlayingOpen = false
        searchOpen = false
        browseDestination = null
        section = AppSection.Assistant
        val seed = when (action) {
            PlayerTrackAction.PlaySimilar -> GuidedSessions.playSimilarSeed(track)
            PlayerTrackAction.Appreciate -> GuidedSessions.appreciateSeed(track)
        }
        assistantCoordinator.startGuidedSession(seed)
    }

    BackHandler(enabled = nowPlayingOpen || searchOpen || browseDestination != null) {
        when {
            nowPlayingOpen -> nowPlayingOpen = false
            searchOpen -> searchOpen = false
            browseDestination != null -> browseDestination = null
        }
    }

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        when (section) {
            AppSection.Home -> AppleParityHomeScreen(
                graph = graph,
                onPlayTracks = ::playShelf,
                onBrowse = ::openBrowse,
                onManageServers = onOpenServers,
            )

            AppSection.Library -> Box(Modifier.fillMaxSize()) {
                LibraryScreen(
                    graph = graph,
                    onOpenSettings = onOpenSettings,
                    onPlayTracks = ::playShelf,
                    onPlayNext = ::playNextShelf,
                    onAppendToQueue = ::appendQueueShelf,
                    onBrowse = ::openBrowse,
                )
                browseDestination?.let { destination ->
                    BrowseDetailScreen(
                        graph = graph,
                        initial = destination,
                        onBack = { browseDestination = null },
                        onPlayTracks = ::playShelf,
                        onPlayNext = ::playNextShelf,
                        onAppendToQueue = ::appendQueueShelf,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            AppSection.Assistant -> AssistantScreen(
                coordinator = assistantCoordinator,
                onOpenSearch = { searchOpen = true },
                onOpenAiSettings = onOpenAiSettings,
                modifier = Modifier.fillMaxSize(),
            )
        }

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = AuralisChrome.dockBottomPadding),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val showMini = engineAvailable &&
                section != AppSection.Assistant &&
                playback.entry != null && playback.track != null
            if (showMini && playback.track != null) {
                val currentLogical = queue.currentLogicalIndex
                Row(
                    modifier = Modifier
                        .widthIn(max = AuralisChrome.floatingChromeMaxWidth)
                        .fillMaxWidth()
                        .padding(horizontal = AuralisChrome.dockHorizontalPadding),
                ) {
                    MiniPlayerBar(
                        track = playback.track!!,
                        isPlaying = playback.state is PlaybackState.Playing,
                        isBuffering = playback.state is PlaybackState.Buffering ||
                            playback.state is PlaybackState.Stalled ||
                            playback.state is PlaybackState.Preparing,
                        canGoPrevious = (currentLogical ?: 0) > 0,
                        canGoNext = queue.totalCount > (currentLogical ?: -1) + 1,
                        onOpen = { nowPlayingOpen = true },
                        onPrevious = { controller.previous() },
                        onTogglePlayPause = {
                            if (playback.state is PlaybackState.Playing || playback.state is PlaybackState.Paused) {
                                controller.togglePlayPause()
                            }
                        },
                        onNext = { controller.next() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Spacer(Modifier.height(AuralisChrome.dockSpacing))
            }
            Row(
                modifier = Modifier
                    .widthIn(max = AuralisChrome.floatingChromeMaxWidth)
                    .fillMaxWidth()
                    .padding(horizontal = AuralisChrome.dockHorizontalPadding),
            ) {
                BottomDock(
                    selected = section,
                    onSelect = { sel ->
                        nowPlayingOpen = false
                        searchOpen = false
                        if (sel == AppSection.Library) {
                            if (section == AppSection.Library && browseDestination != null) {
                                browseDestination = null
                            } else {
                                section = sel
                            }
                        } else {
                            browseDestination = null
                            section = sel
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        if (nowPlayingOpen && playback.track != null) {
            NowPlayingScreen(
                graph = graph,
                controller = controller,
                onClose = { nowPlayingOpen = false },
                onOpenBrowse = ::openBrowse,
                onTrackAction = ::openGuidedAssistant,
                modifier = Modifier.fillMaxSize().background(colors.background),
            )
        }

        if (searchOpen) {
            SearchScreen(
                graph = graph,
                onBack = { searchOpen = false },
                onPlayTracks = { tracks, start -> playShelf(tracks, start) },
                onBrowse = ::openBrowse,
                modifier = Modifier.fillMaxSize().background(colors.background),
            )
        }
    }
}
