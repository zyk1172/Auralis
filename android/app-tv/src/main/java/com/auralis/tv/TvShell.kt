// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import com.auralis.core.playback.LocalPlaybackHost
import com.auralis.core.playback.PlaybackCapabilities
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import com.auralis.core.playback.awaitPlaybackController
import com.auralis.feature.home.HomeScreen
import com.auralis.feature.library.BrowseDetailScreen
import com.auralis.feature.library.LibraryScreen
import com.auralis.feature.search.SearchScreen
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * TV shell uses a permanent left navigation rail and a separate ten-foot Now Playing surface.
 * Shared catalog/business features remain reused, but TV navigation, focus ownership and playback
 * chrome are no longer constrained by the phone shell geometry.
 */
@Composable
fun TvShell(
    graph: AuralisGraph,
    onOpenSettings: () -> Unit,
    onOpenServers: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var section by rememberSaveable { mutableStateOf(TvSection.Home) }
    var browseDestination by remember { mutableStateOf<BrowseDestination?>(null) }
    var nowPlayingOpen by remember { mutableStateOf(false) }
    var pendingFocusRestore by remember { mutableStateOf<TvFocusRestoreTarget?>(null) }
    val context = LocalContext.current
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

    val homeFocus = remember { FocusRequester() }
    val libraryFocus = remember { FocusRequester() }
    val searchFocus = remember { FocusRequester() }
    val nowPlayingStripFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        yield()
        runCatching { homeFocus.requestFocus() }
    }

    LaunchedEffect(nowPlayingOpen, browseDestination, pendingFocusRestore, playback.track) {
        val target = pendingFocusRestore ?: return@LaunchedEffect
        val canRestore = when (target) {
            TvFocusRestoreTarget.Home -> !nowPlayingOpen && browseDestination == null
            TvFocusRestoreTarget.Library -> !nowPlayingOpen && browseDestination == null
            TvFocusRestoreTarget.Search -> !nowPlayingOpen && browseDestination == null
            TvFocusRestoreTarget.NowPlayingStrip -> !nowPlayingOpen && browseDestination == null && playback.track != null
        }
        if (!canRestore) return@LaunchedEffect
        yield()
        val requester = when (target) {
            TvFocusRestoreTarget.Home -> homeFocus
            TvFocusRestoreTarget.Library -> libraryFocus
            TvFocusRestoreTarget.Search -> searchFocus
            TvFocusRestoreTarget.NowPlayingStrip -> nowPlayingStripFocus
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

    fun closeNowPlaying(restoreToStrip: Boolean = true) {
        if (restoreToStrip && playback.track != null) pendingFocusRestore = TvFocusRestoreTarget.NowPlayingStrip
        nowPlayingOpen = false
    }

    fun closeBrowse(restoreToLibrary: Boolean = true) {
        if (restoreToLibrary) pendingFocusRestore = TvFocusRestoreTarget.Library
        browseDestination = null
    }

    fun openBrowse(destination: BrowseDestination) {
        pendingFocusRestore = null
        nowPlayingOpen = false
        browseDestination = destination
        section = TvSection.Library
    }

    fun selectSection(target: TvSection) {
        pendingFocusRestore = null
        nowPlayingOpen = false
        if (target == TvSection.Library && section == TvSection.Library && browseDestination != null) {
            closeBrowse(restoreToLibrary = true)
            return
        }
        browseDestination = null
        section = target
    }

    BackHandler(enabled = nowPlayingOpen || browseDestination != null) {
        when {
            nowPlayingOpen -> closeNowPlaying()
            browseDestination != null -> closeBrowse()
        }
    }

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        Row(Modifier.fillMaxSize()) {
            TvNavigationRail(
                section = section,
                onSelectSection = ::selectSection,
                onOpenSettings = onOpenSettings,
                homeFocusRequester = homeFocus,
                libraryFocusRequester = libraryFocus,
                searchFocusRequester = searchFocus,
                modifier = Modifier.fillMaxHeight().width(132.dp),
            )

            Column(Modifier.weight(1f).fillMaxHeight()) {
                Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                    when (section) {
                        TvSection.Home -> HomeScreen(
                            graph = graph,
                            onPlayTracks = ::playShelf,
                            onBrowse = ::openBrowse,
                            onManageServers = onOpenServers,
                            modifier = Modifier.fillMaxSize(),
                        )

                        TvSection.Library -> Box(Modifier.fillMaxSize()) {
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
                                    onBack = { closeBrowse() },
                                    onPlayTracks = ::playShelf,
                                    onPlayNext = ::playNextShelf,
                                    onAppendToQueue = ::appendQueueShelf,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                        }

                        TvSection.Search -> SearchScreen(
                            graph = graph,
                            onBack = { selectSection(TvSection.Home) },
                            onPlayTracks = ::playShelf,
                            onBrowse = ::openBrowse,
                        )
                    }
                }

                val track = playback.track
                if (engineAvailable && track != null) {
                    TvNowPlayingStrip(
                        track = track,
                        playback = playback,
                        queue = queue,
                        onOpen = {
                            pendingFocusRestore = null
                            nowPlayingOpen = true
                        },
                        onPrevious = { controller.previous() },
                        onTogglePlayPause = { controller.togglePlayPause() },
                        onNext = { controller.next() },
                        openFocusRequester = nowPlayingStripFocus,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 28.dp, end = 36.dp, top = 8.dp, bottom = 20.dp),
                    )
                }
            }
        }

        if (nowPlayingOpen && playback.track != null) {
            TvNowPlayingScreen(
                graph = graph,
                controller = controller,
                onClose = { closeNowPlaying() },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
private fun TvNavigationRail(
    section: TvSection,
    onSelectSection: (TvSection) -> Unit,
    onOpenSettings: () -> Unit,
    homeFocusRequester: FocusRequester,
    libraryFocusRequester: FocusRequester,
    searchFocusRequester: FocusRequester,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .background(colors.elevated.copy(alpha = 0.72f))
            .padding(horizontal = 12.dp, vertical = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "A",
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            color = colors.accent,
        )
        Text("Auralis", style = MaterialTheme.typography.labelMedium, color = colors.secondaryText)
        Spacer(Modifier.height(34.dp))

        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            TvSection.entries.forEach { entry ->
                val requester = when (entry) {
                    TvSection.Home -> homeFocusRequester
                    TvSection.Library -> libraryFocusRequester
                    TvSection.Search -> searchFocusRequester
                }
                TvRailItem(
                    section = entry,
                    selected = section == entry,
                    onClick = { onSelectSection(entry) },
                    modifier = Modifier.focusRequester(requester),
                )
            }
        }

        Spacer(Modifier.weight(1f))
        val shape = RoundedCornerShape(22.dp)
        Surface(
            shape = shape,
            color = colors.surface,
            modifier = Modifier
                .size(72.dp)
                .tvFocusVisual(shape)
                .tvClick(onOpenSettings),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Filled.Settings,
                    contentDescription = stringResource(AuralisR.string.settings),
                    tint = colors.primaryText,
                    modifier = Modifier.size(30.dp),
                )
            }
        }
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
            .width(104.dp)
            .height(84.dp)
            .tvFocusVisual(shape)
            .tvClick(onClick),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                section.icon,
                contentDescription = null,
                tint = if (selected) colors.accent else colors.secondaryText,
                modifier = Modifier.size(28.dp),
            )
            Spacer(Modifier.height(7.dp))
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
private fun TvNowPlayingStrip(
    track: Track,
    playback: PlaybackSnapshot,
    queue: QueueSnapshot,
    onOpen: () -> Unit,
    onPrevious: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    openFocusRequester: FocusRequester,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val isPlaying = playback.state is PlaybackState.Playing
    val isBuffering = playback.state is PlaybackState.Buffering || playback.state is PlaybackState.Stalled || playback.state is PlaybackState.Preparing
    val controlsEnabled = playback.state is PlaybackState.Playing || playback.state is PlaybackState.Paused
    val canGoPrevious = PlaybackCapabilities.canGoPrevious(playback, queue)
    val canGoNext = PlaybackCapabilities.canGoNext(playback, queue)

    Row(
        modifier = modifier
            .height(88.dp)
            .widthIn(max = 1560.dp)
            .background(colors.elevated, RoundedCornerShape(26.dp))
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .focusRequester(openFocusRequester)
                .tvFocusVisual(RoundedCornerShape(22.dp))
                .tvClick(onOpen)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AuralisArtwork(
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                contentDescription = stringResource(AuralisR.string.artwork_cover),
                titleForFallback = track.title,
                targetSizeDp = 64,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.size(64.dp),
            )
            Spacer(Modifier.width(16.dp))
            Column(verticalArrangement = Arrangement.Center) {
                Text(track.title, style = MaterialTheme.typography.titleMedium, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(track.artistName, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        TvTransportButton(
            enabled = canGoPrevious,
            onClick = onPrevious,
        ) { tint -> Icon(Icons.Filled.SkipPrevious, contentDescription = stringResource(AuralisR.string.previous), tint = tint, modifier = Modifier.size(32.dp)) }
        TvTransportButton(
            enabled = controlsEnabled,
            emphasized = true,
            onClick = onTogglePlayPause,
        ) { tint ->
            if (isBuffering) CircularProgressIndicator(modifier = Modifier.size(30.dp), strokeWidth = 3.dp, color = tint)
            else Icon(
                if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                contentDescription = if (isPlaying) stringResource(AuralisR.string.pause) else stringResource(AuralisR.string.play),
                tint = tint,
                modifier = Modifier.size(38.dp),
            )
        }
        TvTransportButton(
            enabled = canGoNext,
            onClick = onNext,
        ) { tint -> Icon(Icons.Filled.SkipNext, contentDescription = stringResource(AuralisR.string.next), tint = tint, modifier = Modifier.size(32.dp)) }
    }
}

@Composable
private fun TvTransportButton(
    enabled: Boolean,
    emphasized: Boolean = false,
    onClick: () -> Unit,
    icon: @Composable (Color) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(50)
    Surface(
        shape = shape,
        color = if (emphasized) colors.accent.copy(alpha = 0.22f) else Color.Transparent,
        modifier = Modifier
            .padding(horizontal = 4.dp)
            .size(if (emphasized) 68.dp else 60.dp)
            .then(if (enabled) Modifier.tvFocusVisual(shape).tvClick(onClick) else Modifier),
    ) {
        Box(contentAlignment = Alignment.Center) {
            icon(if (enabled) colors.primaryText else colors.secondaryText.copy(alpha = 0.38f))
        }
    }
}

private enum class TvFocusRestoreTarget {
    Home,
    Library,
    Search,
    NowPlayingStrip,
}
