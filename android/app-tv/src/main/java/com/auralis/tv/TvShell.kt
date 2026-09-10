// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.RecommendationIndexUiState
import com.auralis.core.domain.Track
import com.auralis.core.playback.LocalPlaybackHost
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import com.auralis.core.playback.awaitPlaybackController
import com.auralis.feature.assistant.AssistantCoordinator
import com.auralis.feature.assistant.AssistantScreen
import com.auralis.feature.home.HomeScreen
import com.auralis.feature.library.BrowseDetailScreen
import com.auralis.feature.library.LibraryScreen
import com.auralis.feature.search.SearchScreen
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * Real-device TV shell.
 *
 * The content shell and the full player are mutually exclusive in Composition, so D-pad focus can
 * never remain on controls hidden behind the player. The old bottom playback strip is removed;
 * Now Playing is a permanent rail destination that remains one-dimensional and reachable without
 * scrolling the current content to its end.
 */
@Composable
fun TvShell(
    graph: AuralisGraph,
    assistantCoordinator: AssistantCoordinator,
    onOpenSettings: () -> Unit,
    onOpenServers: () -> Unit,
    onOpenAiSettings: () -> Unit,
    recommendationIndexState: RecommendationIndexUiState = RecommendationIndexUiState(),
    startRecommendationIndexToken: Int = 0,
    onRecommendationIndexStartConsumed: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var section by rememberSaveable { mutableStateOf(TvSection.Home) }
    var browseDestination by remember { mutableStateOf<BrowseDestination?>(null) }
    var playerOpen by rememberSaveable { mutableStateOf(false) }
    var pendingFocusRestore by remember { mutableStateOf<TvFocusRestoreTarget?>(null) }
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

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

    val sectionFocus = remember { TvSection.entries.associateWith { FocusRequester() } }
    val nowPlayingFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        yield()
        runCatching { sectionFocus.getValue(section).requestFocus() }
    }

    LaunchedEffect(startRecommendationIndexToken) {
        if (startRecommendationIndexToken > 0) {
            section = TvSection.Assistant
            browseDestination = null
            playerOpen = false
            onRecommendationIndexStartConsumed()
            yield()
            runCatching { sectionFocus.getValue(TvSection.Assistant).requestFocus() }
        }
    }

    LaunchedEffect(playerOpen, browseDestination, pendingFocusRestore) {
        if (playerOpen) return@LaunchedEffect
        val target = pendingFocusRestore ?: return@LaunchedEffect
        yield()
        val requester = when (target) {
            is TvFocusRestoreTarget.Section -> sectionFocus.getValue(target.section)
            TvFocusRestoreTarget.NowPlaying -> nowPlayingFocus
        }
        if (runCatching { requester.requestFocus() }.isSuccess) pendingFocusRestore = null
    }

    fun notifyPlaybackFailure(throwable: Throwable) {
        val detail = throwable.message?.takeIf { it.isNotBlank() } ?: throwable::class.java.simpleName
        android.widget.Toast.makeText(
            context,
            context.getString(AuralisR.string.action_failed, detail),
            android.widget.Toast.LENGTH_SHORT,
        ).show()
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
        if (tracks.isEmpty()) return
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching {
                ready.playQueue(tracks.map { QueueEntry.of(it) }, startIndex.coerceIn(0, tracks.lastIndex))
            }.onFailure(::notifyPlaybackFailure)
        }
    }

    fun playNextShelf(tracks: List<Track>) {
        if (tracks.isEmpty()) return
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.insertNext(tracks.map { QueueEntry.of(it) }) }
                .onFailure(::notifyPlaybackFailure)
        }
    }

    fun appendQueueShelf(tracks: List<Track>) {
        if (tracks.isEmpty()) return
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.appendToQueue(tracks.map { QueueEntry.of(it) }) }
                .onFailure(::notifyPlaybackFailure)
        }
    }

    fun openBrowse(destination: BrowseDestination) {
        browseDestination = destination
        section = TvSection.Library
    }

    fun selectSection(target: TvSection) {
        playerOpen = false
        browseDestination = null
        section = target
    }

    fun closePlayer() {
        playerOpen = false
        pendingFocusRestore = TvFocusRestoreTarget.NowPlaying
    }

    BackHandler(enabled = playerOpen || browseDestination != null) {
        when {
            playerOpen -> closePlayer()
            browseDestination != null -> {
                browseDestination = null
                pendingFocusRestore = TvFocusRestoreTarget.Section(TvSection.Library)
            }
        }
    }

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        if (playerOpen && playback.track != null) {
            // Dedicated full-screen route: the shell is not mounted behind it, eliminating focus
            // fall-through into visually hidden menus/buttons on real televisions.
            TvNowPlayingScreen(
                graph = graph,
                controller = controller,
                onClose = ::closePlayer,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Row(Modifier.fillMaxSize()) {
                TvNavigationRail(
                    section = section,
                    playback = playback,
                    sectionFocus = sectionFocus,
                    nowPlayingFocus = nowPlayingFocus,
                    onSelectSection = ::selectSection,
                    onOpenPlayer = {
                        if (playback.track != null) {
                            pendingFocusRestore = null
                            playerOpen = true
                        }
                    },
                    modifier = Modifier
                        .fillMaxHeight()
                        .width(138.dp),
                )

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                ) {
                    when (section) {
                        TvSection.Home -> HomeScreen(
                            graph = graph,
                            onPlayTracks = ::playShelf,
                            onBrowse = ::openBrowse,
                            onManageServers = onOpenServers,
                            modifier = Modifier.fillMaxSize(),
                        )

                        TvSection.Library -> {
                            val destination = browseDestination
                            if (destination == null) {
                                LibraryScreen(
                                    graph = graph,
                                    onOpenSettings = onOpenSettings,
                                    onPlayTracks = ::playShelf,
                                    onPlayNext = ::playNextShelf,
                                    onAppendToQueue = ::appendQueueShelf,
                                    onBrowse = ::openBrowse,
                                    recommendationIndexState = recommendationIndexState,
                                    onStartRecommendationIndex = {
                                        section = TvSection.Assistant
                                        assistantCoordinator.startRecommendationIndexBuild()
                                    },
                                    onCancelRecommendationIndex = assistantCoordinator::cancelRecommendationIndexBuild,
                                    onRefreshRecommendationIndex = assistantCoordinator::refreshRecommendationIndexStatus,
                                    bottomChromeClearance = 24.dp,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else {
                                BrowseDetailScreen(
                                    graph = graph,
                                    initial = destination,
                                    onBack = {
                                        browseDestination = null
                                        pendingFocusRestore = TvFocusRestoreTarget.Section(TvSection.Library)
                                    },
                                    onPlayTracks = ::playShelf,
                                    onPlayNext = ::playNextShelf,
                                    onAppendToQueue = ::appendQueueShelf,
                                    bottomChromeClearance = 24.dp,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                        }

                        TvSection.Search -> SearchScreen(
                            graph = graph,
                            onBack = { selectSection(TvSection.Home) },
                            onPlayTracks = ::playShelf,
                            onBrowse = ::openBrowse,
                            modifier = Modifier.fillMaxSize(),
                        )

                        TvSection.Assistant -> AssistantScreen(
                            coordinator = assistantCoordinator,
                            onOpenSearch = { selectSection(TvSection.Search) },
                            onOpenAiSettings = onOpenAiSettings,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TvNavigationRail(
    section: TvSection,
    playback: PlaybackSnapshot,
    sectionFocus: Map<TvSection, FocusRequester>,
    nowPlayingFocus: FocusRequester,
    onSelectSection: (TvSection) -> Unit,
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .background(colors.elevated.copy(alpha = 0.76f))
            .padding(horizontal = 12.dp, vertical = 26.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "A",
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            color = colors.accent,
        )
        Text("Auralis", style = MaterialTheme.typography.labelMedium, color = colors.secondaryText)
        Spacer(Modifier.height(30.dp))

        Column(verticalArrangement = Arrangement.spacedBy(11.dp)) {
            TvSection.entries.forEach { entry ->
                TvRailItem(
                    section = entry,
                    selected = section == entry,
                    onClick = { onSelectSection(entry) },
                    modifier = Modifier.focusRequester(sectionFocus.getValue(entry)),
                )
            }
        }

        Spacer(Modifier.weight(1f))
        TvNowPlayingRailButton(
            playback = playback,
            onClick = onOpenPlayer,
            modifier = Modifier.focusRequester(nowPlayingFocus),
        )
    }
}

@Composable
private fun TvRailItem(
    section: TvSection,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(22.dp)
    Surface(
        shape = shape,
        color = if (selected) colors.accent.copy(alpha = 0.20f) else Color.Transparent,
        modifier = modifier
            .width(108.dp)
            .height(78.dp)
            .tvFocusableClick(shape = shape, onClick = onClick),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                section.icon,
                contentDescription = null,
                tint = if (selected) colors.accent else colors.secondaryText,
                modifier = Modifier.size(27.dp),
            )
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(section.labelRes),
                style = MaterialTheme.typography.labelMedium,
                color = if (selected) colors.primaryText else colors.secondaryText,
                maxLines = 1,
            )
        }
    }
}

/**
 * Bottom rail playback destination. It replaces the duplicated Settings button. The equalizer is
 * intentionally restrained: it only animates while music is actually playing and freezes under
 * Reduce Motion.
 */
@Composable
private fun TvNowPlayingRailButton(
    playback: PlaybackSnapshot,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val hasTrack = playback.track != null
    val isPlaying = playback.state is PlaybackState.Playing
    val shape = RoundedCornerShape(24.dp)

    Surface(
        shape = shape,
        color = if (hasTrack) colors.accent.copy(alpha = 0.18f) else colors.surface.copy(alpha = 0.55f),
        modifier = modifier
            .width(108.dp)
            .height(88.dp)
            .tvFocusableClick(shape = shape, enabled = hasTrack, onClick = onClick),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            if (hasTrack) {
                TvEqualizer(active = isPlaying && !reduceMotion)
            } else {
                Icon(
                    Icons.Filled.GraphicEq,
                    contentDescription = null,
                    tint = colors.secondaryText.copy(alpha = 0.55f),
                    modifier = Modifier.size(29.dp),
                )
            }
            Spacer(Modifier.height(7.dp))
            Text(
                stringResource(if (hasTrack) R.string.tv_now_playing else R.string.tv_no_playback),
                style = MaterialTheme.typography.labelSmall,
                color = if (hasTrack) colors.primaryText else colors.secondaryText.copy(alpha = 0.6f),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun TvEqualizer(active: Boolean) {
    val colors = LocalAuralisTheme.current.colors
    val transition = rememberInfiniteTransition(label = "tv-now-playing-eq")
    val a by transition.animateFloat(
        initialValue = 0.38f,
        targetValue = if (active) 1f else 0.38f,
        animationSpec = infiniteRepeatable(tween(460), RepeatMode.Reverse),
        label = "eq-a",
    )
    val b by transition.animateFloat(
        initialValue = 0.76f,
        targetValue = if (active) 0.32f else 0.76f,
        animationSpec = infiniteRepeatable(tween(610), RepeatMode.Reverse),
        label = "eq-b",
    )
    val c by transition.animateFloat(
        initialValue = 0.52f,
        targetValue = if (active) 0.92f else 0.52f,
        animationSpec = infiniteRepeatable(tween(540), RepeatMode.Reverse),
        label = "eq-c",
    )
    Row(
        modifier = Modifier.height(31.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf(a, b, c).forEach { fraction ->
            Box(
                Modifier
                    .width(5.dp)
                    .height((28f * fraction.coerceIn(0.25f, 1f)).dp)
                    .background(colors.accent, RoundedCornerShape(50)),
            )
        }
    }
}

private sealed interface TvFocusRestoreTarget {
    data class Section(val section: TvSection) : TvFocusRestoreTarget
    data object NowPlaying : TvFocusRestoreTarget
}
