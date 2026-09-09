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
import androidx.compose.material3.HorizontalDivider
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
import com.auralis.core.designsystem.AuralisChrome
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
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import com.auralis.core.playback.awaitPlaybackController
import com.auralis.feature.home.HomeScreen
import com.auralis.feature.library.BrowseDetailScreen
import com.auralis.feature.library.LibraryScreen
import com.auralis.feature.player.NowPlayingScreen
import com.auralis.feature.search.SearchScreen
import com.auralis.tv.R
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * TV 壳（S9/R10）。
 *
 * 除了所有可操作项必须有明确焦点环，还必须保证 overlay 关闭后焦点回到一个确定的、
 * 用户可理解的位置。Android TV/Compose 在移除当前焦点节点后并不会可靠替我们选择下一个
 * 节点；不主动恢复就会出现“按方向键没有任何可见焦点”的假死体验。
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

    // ---- 播放状态（真实绑定；引擎由 AuralisPlaybackService 创建后 available=true）----
    val engineAvailable by LocalPlaybackHost.available.collectAsState()
    val controller = remember { LocalPlaybackHost.controller() }
    var playback by remember { mutableStateOf(PlaybackSnapshot.Empty) }
    var queue by remember { mutableStateOf(QueueSnapshot.Empty) }
    LaunchedEffect(controller, engineAvailable) {
        if (engineAvailable) {
            controller.playback.collect { playback = it }
        } else {
            playback = PlaybackSnapshot.Empty
        }
    }
    LaunchedEffect(controller, engineAvailable) {
        if (engineAvailable) {
            controller.queue.collect { queue = it }
        } else {
            queue = QueueSnapshot.Empty
        }
    }

    val homeFocus = remember { FocusRequester() }
    val libraryFocus = remember { FocusRequester() }
    val searchFocus = remember { FocusRequester() }
    val nowPlayingStripFocus = remember { FocusRequester() }

    // TV 冷启动没有触摸入口；等待首帧节点真正挂载后再请求首页焦点。
    LaunchedEffect(Unit) {
        yield()
        runCatching { homeFocus.requestFocus() }
    }

    // Overlay 被移出 Composition 后下一帧再恢复焦点，避免 requestFocus 命中尚未重新挂载的节点。
    LaunchedEffect(nowPlayingOpen, browseDestination, pendingFocusRestore, playback.track) {
        val target = pendingFocusRestore ?: return@LaunchedEffect
        val canRestore = when (target) {
            TvFocusRestoreTarget.HomeTab -> !nowPlayingOpen && browseDestination == null
            TvFocusRestoreTarget.LibraryTab -> !nowPlayingOpen && browseDestination == null
            TvFocusRestoreTarget.SearchTab -> !nowPlayingOpen && browseDestination == null
            TvFocusRestoreTarget.NowPlayingStrip ->
                !nowPlayingOpen && browseDestination == null && playback.track != null
        }
        if (!canRestore) return@LaunchedEffect
        yield()
        val requester = when (target) {
            TvFocusRestoreTarget.HomeTab -> homeFocus
            TvFocusRestoreTarget.LibraryTab -> libraryFocus
            TvFocusRestoreTarget.SearchTab -> searchFocus
            TvFocusRestoreTarget.NowPlayingStrip -> nowPlayingStripFocus
        }
        if (runCatching { requester.requestFocus() }.isSuccess) {
            pendingFocusRestore = null
        }
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

    fun closeNowPlaying(restoreToStrip: Boolean = true) {
        if (restoreToStrip && playback.track != null) {
            pendingFocusRestore = TvFocusRestoreTarget.NowPlayingStrip
        }
        nowPlayingOpen = false
    }

    fun closeBrowse(restoreToLibrary: Boolean = true) {
        if (restoreToLibrary) {
            pendingFocusRestore = TvFocusRestoreTarget.LibraryTab
        }
        browseDestination = null
    }

    /** 浏览请求 → 切音乐库分区并打开覆盖浏览页。 */
    fun openBrowse(destination: BrowseDestination) {
        // 从 Now Playing 跳转到专辑/艺人时，目标是浏览页而不是底部播放器条，不能排队错误恢复。
        pendingFocusRestore = null
        nowPlayingOpen = false
        browseDestination = destination
        section = TvSection.Library
    }

    /** 切一级分区：关闭覆盖层；音乐库再点 = 回库根。 */
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
        Column(modifier = Modifier.fillMaxSize()) {
            TvTopBar(
                section = section,
                onSelectSection = ::selectSection,
                onOpenSettings = onOpenSettings,
                homeFocusRequester = homeFocus,
                libraryFocusRequester = libraryFocus,
                searchFocusRequester = searchFocus,
            )
            HorizontalDivider(color = colors.separator)

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                when (section) {
                    TvSection.Home -> HomeScreen(
                        graph = graph,
                        onPlayTracks = ::playShelf,
                        onBrowse = ::openBrowse,
                        onManageServers = onOpenServers,
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
                        onPlayTracks = { tracks, start -> playShelf(tracks, start) },
                        onBrowse = ::openBrowse,
                    )
                }
            }

            val track = playback.track
            if (engineAvailable && track != null) {
                TvNowPlayingStrip(
                    track = track,
                    isPlaying = playback.state is PlaybackState.Playing,
                    isBuffering = playback.state is PlaybackState.Buffering ||
                        playback.state is PlaybackState.Stalled ||
                        playback.state is PlaybackState.Preparing,
                    canGoPrevious = (queue.currentLogicalIndex ?: 0) > 0,
                    canGoNext = queue.totalCount > (queue.currentLogicalIndex ?: -1) + 1,
                    controlsEnabled = playback.state is PlaybackState.Playing ||
                        playback.state is PlaybackState.Paused,
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
                        .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
                )
            }
        }

        if (nowPlayingOpen && playback.track != null) {
            NowPlayingScreen(
                graph = graph,
                controller = controller,
                onClose = { closeNowPlaying() },
                onOpenBrowse = ::openBrowse,
                modifier = Modifier.fillMaxSize().background(colors.background),
            )
        }
    }
}

/** TV 顶栏：左「Auralis TV」标识 + 一级分区导航 + 右上设置。 */
@Composable
private fun TvTopBar(
    section: TvSection,
    onSelectSection: (TvSection) -> Unit,
    onOpenSettings: () -> Unit,
    homeFocusRequester: FocusRequester,
    libraryFocusRequester: FocusRequester,
    searchFocusRequester: FocusRequester,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(72.dp)
            .background(colors.background)
            .padding(horizontal = AuralisSpacing.large),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "Auralis TV",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            color = colors.accent,
        )
        Spacer(Modifier.width(AuralisSpacing.xLarge))
        Row(horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small)) {
            TvSection.entries.forEach { entry ->
                val selected = entry == section
                val shape = RoundedCornerShape(AuralisRadius.large)
                val requester = when (entry) {
                    TvSection.Home -> homeFocusRequester
                    TvSection.Library -> libraryFocusRequester
                    TvSection.Search -> searchFocusRequester
                }
                Surface(
                    shape = shape,
                    color = if (selected) colors.accent.copy(alpha = 0.22f) else colors.elevated,
                    modifier = Modifier
                        .focusRequester(requester)
                        .tvFocusVisual(shape)
                        .tvClick { onSelectSection(entry) },
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 22.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            imageVector = entry.icon,
                            contentDescription = null,
                            tint = if (selected) colors.accent else colors.secondaryText,
                            modifier = Modifier.size(22.dp),
                        )
                        Text(
                            text = stringResource(entry.labelRes),
                            style = MaterialTheme.typography.labelLarge,
                            color = if (selected) colors.primaryText else colors.secondaryText,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.weight(1f))
        val settingsShape = RoundedCornerShape(50)
        Surface(
            shape = settingsShape,
            color = colors.elevated,
            modifier = Modifier.tvFocusVisual(settingsShape).tvClick(onOpenSettings).size(56.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Filled.Settings,
                    contentDescription = stringResource(AuralisR.string.settings),
                    tint = colors.primaryText,
                    modifier = Modifier.size(28.dp),
                )
            }
        }
    }
}

/** TV 正在播放条：封面/标题（点击开全屏）+ 上一首 / 播放暂停 / 下一首。 */
@Composable
private fun TvNowPlayingStrip(
    track: Track,
    isPlaying: Boolean,
    isBuffering: Boolean,
    canGoPrevious: Boolean,
    canGoNext: Boolean,
    controlsEnabled: Boolean,
    onOpen: () -> Unit,
    onPrevious: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    openFocusRequester: FocusRequester,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .height(72.dp)
            .widthIn(max = 1400.dp)
            .background(colors.elevated, RoundedCornerShape(AuralisRadius.large))
            .padding(start = AuralisSpacing.small, end = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .focusRequester(openFocusRequester)
                .tvFocusVisual(RoundedCornerShape(AuralisRadius.large))
                .tvClick(onClick = onOpen)
                .padding(horizontal = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AuralisArtwork(
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                contentDescription = stringResource(AuralisR.string.artwork_cover),
                titleForFallback = track.title,
                targetSizeDp = 48,
                shape = RoundedCornerShape(AuralisRadius.small),
                modifier = Modifier.size(48.dp),
            )
            Spacer(Modifier.width(AuralisSpacing.medium))
            Column(verticalArrangement = Arrangement.Center) {
                Text(
                    text = track.title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.primaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = track.artistName,
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(AuralisSpacing.small))
        TvTransportButton(
            icon = { tint -> Icon(Icons.Filled.SkipPrevious, contentDescription = stringResource(AuralisR.string.previous), tint = tint, modifier = Modifier.size(30.dp)) },
            enabled = canGoPrevious,
            onClick = onPrevious,
        )
        TvTransportButton(
            icon = { tint ->
                Icon(
                    imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) stringResource(AuralisR.string.pause) else stringResource(AuralisR.string.play),
                    tint = tint,
                    modifier = Modifier.size(36.dp),
                )
            },
            enabled = controlsEnabled,
            emphasized = true,
            onClick = onTogglePlayPause,
        )
        TvTransportButton(
            icon = { tint -> Icon(Icons.Filled.SkipNext, contentDescription = stringResource(AuralisR.string.next), tint = tint, modifier = Modifier.size(30.dp)) },
            enabled = canGoNext,
            onClick = onNext,
        )
        if (isBuffering) {
            Spacer(Modifier.width(AuralisSpacing.small))
            Text(
                text = stringResource(R.string.tv_buffering),
                style = MaterialTheme.typography.labelMedium,
                color = colors.secondaryText,
            )
        }
    }
}

/** TV 传输控制按钮（圆形、聚焦放大）。 */
@Composable
private fun TvTransportButton(
    icon: @Composable (tint: Color) -> Unit,
    enabled: Boolean,
    emphasized: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(50)
    Surface(
        shape = shape,
        color = if (emphasized) colors.accent.copy(alpha = 0.22f) else Color.Transparent,
        modifier = Modifier
            .tvFocusVisual(shape)
            .size(if (emphasized) 60.dp else 56.dp)
            .then(if (enabled) Modifier.tvClick(onClick = onClick) else Modifier),
    ) {
        Box(contentAlignment = Alignment.Center) {
            icon(if (enabled) colors.primaryText else colors.secondaryText.copy(alpha = 0.5f))
        }
    }
}

private enum class TvFocusRestoreTarget {
    HomeTab,
    LibraryTab,
    SearchTab,
    NowPlayingStrip,
}
