// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
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
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
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
 * Full-player/content routes are mutually exclusive. Focus restoration is explicit rather than
 * relying on Compose's experimental focusRestorer pinning across changing Lazy layouts: several TV
 * Compose versions can double-release a pinned item while crossing rail/content, which manifests as
 * a process crash on physical devices. Each top-level destination owns an independent saveable
 * state bucket so an Assistant draft cannot be reused by Home/Library/Search when the branch swaps.
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
    val sectionStateHolder = rememberSaveableStateHolder()
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
        if (engineAvailable) {
            controller.queue.collect { snapshot ->
                queue = snapshot.stableCopy()
            }
        } else {
            queue = QueueSnapshot.Empty
        }
    }

    val sectionFocus = remember { TvSection.entries.associateWith { FocusRequester() } }
    val nowPlayingFocus = remember { FocusRequester() }
    val contentFocus = remember { FocusRequester() }

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
            TvFocusRestoreTarget.Content -> contentFocus
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
        val stableTracks = tracks.stableTrackCopy()
        if (stableTracks.isEmpty()) return
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching {
                ready.playQueue(
                    stableTracks.map { QueueEntry.of(it) },
                    startIndex.coerceIn(0, stableTracks.lastIndex),
                )
            }.onFailure(::notifyPlaybackFailure)
        }
    }

    fun playNextShelf(tracks: List<Track>) {
        val stableTracks = tracks.stableTrackCopy()
        if (stableTracks.isEmpty()) return
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.insertNext(stableTracks.map { QueueEntry.of(it) }) }
                .onFailure(::notifyPlaybackFailure)
        }
    }

    fun appendQueueShelf(tracks: List<Track>) {
        val stableTracks = tracks.stableTrackCopy()
        if (stableTracks.isEmpty()) return
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.appendToQueue(stableTracks.map { QueueEntry.of(it) }) }
                .onFailure(::notifyPlaybackFailure)
        }
    }

    fun openBrowse(destination: BrowseDestination) {
        browseDestination = destination
        section = TvSection.Library
        // The card that opened a detail disappears in the next composition. Explicitly move the
        // focus into the new content tree; otherwise Android's fallback search often chooses the
        // still-mounted navigation rail.
        pendingFocusRestore = TvFocusRestoreTarget.Content
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
                pendingFocusRestore = TvFocusRestoreTarget.Content
            }
        }
    }

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        if (playerOpen && playback.track != null) {
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
                        .fillMaxHeight()
                        .focusRequester(contentFocus)
                        .focusGroup(),
                ) {
                    sectionStateHolder.SaveableStateProvider("tv-section-${section.name}") {
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
                                            pendingFocusRestore = TvFocusRestoreTarget.Content
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
    val itemHeight = 72.dp
    val itemGap = 8.dp

    Column(
        modifier = modifier
            .background(colors.elevated.copy(alpha = 0.76f))
            .padding(horizontal = 12.dp, vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(14.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                painter = painterResource(R.drawable.auralis_apple_icon),
                contentDescription = stringResource(R.string.app_name),
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
        Spacer(Modifier.height(6.dp))
        Text("Auralis", style = MaterialTheme.typography.labelMedium, color = colors.secondaryText)
        Spacer(Modifier.height(18.dp))

        Column(verticalArrangement = Arrangement.spacedBy(itemGap)) {
            TvSection.entries.forEach { entry ->
                TvRailItem(
                    section = entry,
                    selected = section == entry,
                    onClick = { onSelectSection(entry) },
                    modifier = Modifier.focusRequester(sectionFocus.getValue(entry)),
                    height = itemHeight,
                )
            }
            TvNowPlayingRailButton(
                playback = playback,
                onClick = onOpenPlayer,
                modifier = Modifier.focusRequester(nowPlayingFocus),
                height = itemHeight,
            )
        }
    }
}

@Composable
private fun TvRailItem(
    section: TvSection,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    height: androidx.compose.ui.unit.Dp = 72.dp,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(22.dp)
    Surface(
        shape = shape,
        color = if (selected) colors.accent.copy(alpha = 0.20f) else Color.Transparent,
        modifier = modifier
            .width(108.dp)
            .height(height)
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
                modifier = Modifier.size(25.dp),
            )
            Spacer(Modifier.height(5.dp))
            Text(
                stringResource(section.labelRes),
                style = MaterialTheme.typography.labelMedium,
                color = if (selected) colors.primaryText else colors.secondaryText,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun TvNowPlayingRailButton(
    playback: PlaybackSnapshot,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    height: androidx.compose.ui.unit.Dp = 72.dp,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val hasTrack = playback.track != null
    val active = playback.state.isActive && !reduceMotion
    val shape = RoundedCornerShape(22.dp)

    Surface(
        shape = shape,
        color = if (hasTrack) colors.accent.copy(alpha = 0.18f) else colors.surface.copy(alpha = 0.55f),
        modifier = modifier
            .width(108.dp)
            .height(height)
            .tvFocusableClick(shape = shape, enabled = hasTrack, onClick = onClick),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            if (hasTrack) {
                TvEqualizer(active = active)
            } else {
                Icon(
                    Icons.Filled.GraphicEq,
                    contentDescription = null,
                    tint = colors.secondaryText.copy(alpha = 0.55f),
                    modifier = Modifier.size(25.dp),
                )
            }
            Spacer(Modifier.height(4.dp))
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
        initialValue = 0.34f,
        targetValue = if (active) 1f else 0.34f,
        animationSpec = infiniteRepeatable(tween(420), RepeatMode.Reverse),
        label = "eq-a",
    )
    val b by transition.animateFloat(
        initialValue = 0.78f,
        targetValue = if (active) 0.28f else 0.78f,
        animationSpec = infiniteRepeatable(tween(570), RepeatMode.Reverse),
        label = "eq-b",
    )
    val c by transition.animateFloat(
        initialValue = 0.48f,
        targetValue = if (active) 0.94f else 0.48f,
        animationSpec = infiniteRepeatable(tween(500), RepeatMode.Reverse),
        label = "eq-c",
    )
    Row(
        modifier = Modifier.height(23.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf(a, b, c).forEach { fraction ->
            Box(
                Modifier
                    .width(4.dp)
                    .height((21f * fraction.coerceIn(0.25f, 1f)).dp)
                    .background(colors.accent, RoundedCornerShape(50)),
            )
        }
    }
}

private fun QueueSnapshot.stableCopy(): QueueSnapshot =
    runCatching { copy(entries = entries.toList()) }.getOrElse { this }

private fun List<Track>.stableTrackCopy(): List<Track> {
    repeat(3) {
        runCatching { return toList() }
    }
    return emptyList()
}

private sealed interface TvFocusRestoreTarget {
    data class Section(val section: TvSection) : TvFocusRestoreTarget
    data object Content : TvFocusRestoreTarget
    data object NowPlaying : TvFocusRestoreTarget
}
