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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
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

/**
 * TV 壳（S9）。对齐基准 = 移动端核心能力（页面层零改动复用 feature）+ Android TV 惯例：
 * - 顶栏横向一级分区：首页 / 音乐库 / 搜索（无 Assistant）；右上设置入口；
 * - 播放中时底部常驻「正在播放条」（封面/标题 + 上一首/播放暂停/下一首，点条身开全屏）；
 * - 正在播放全屏页覆盖整个壳；Browse 详情在音乐库分区上覆盖（同移动端语义）；
 * - D-pad 全程可操作：复用页面 item 焦点环由根部 ProvideTvIndication 提供，
 *   自有控件用 tvFocusVisual。
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
    // 浏览详情（同移动端 S4）：非 null 时在音乐库分区上方覆盖真实浏览页。
    var browseDestination by remember { mutableStateOf<BrowseDestination?>(null) }
    // 正在播放全屏页：覆盖整个壳。
    var nowPlayingOpen by remember { mutableStateOf(false) }
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

    // 冷启动给「首页」导航项初始焦点（TV 无触摸，首次 D-pad 即能操作）。
    val homeFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { homeFocus.requestFocus() } }

    /**
     * P0-1 统一取控制器：引擎未就绪则启动播放服务并等待就绪（最多 8s），
     * 保证用户第一次点击一定执行原意图；超时用 Toast 如实告知失败（可重试），不静默丢弃。
     */
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

    /** 整组作为新队列并从点中的那首开始播放（真实动作，P0-1：首击不丢）。 */
    fun playShelf(tracks: List<Track>, startIndex: Int) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching {
                ready.playQueue(tracks.map { QueueEntry.of(it) }, startIndex.coerceIn(0, tracks.lastIndex))
            }
        }
    }

    /** 「下一首播放」：整组插到当前曲之后（P0-1：首击不丢）。 */
    fun playNextShelf(tracks: List<Track>) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.insertNext(tracks.map { QueueEntry.of(it) }) }
        }
    }

    /** 「加入队列」：整组追加到队尾（P0-1：首击不丢）。 */
    fun appendQueueShelf(tracks: List<Track>) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.appendToQueue(tracks.map { QueueEntry.of(it) }) }
        }
    }

    /** 浏览请求 → 切音乐库分区并打开覆盖浏览页。 */
    fun openBrowse(destination: BrowseDestination) {
        nowPlayingOpen = false
        browseDestination = destination
        section = TvSection.Library
    }

    /** 切一级分区：关闭覆盖层；音乐库再点 = 回库根。 */
    fun selectSection(target: TvSection) {
        nowPlayingOpen = false
        if (target == TvSection.Library && section == TvSection.Library && browseDestination != null) {
            browseDestination = null
            return
        }
        browseDestination = null
        section = target
    }

    // 系统返回：正在播放全屏页 > 浏览详情（单处理器保证正确优先级）。
    BackHandler(enabled = nowPlayingOpen || browseDestination != null) {
        when {
            nowPlayingOpen -> nowPlayingOpen = false
            browseDestination != null -> browseDestination = null
        }
    }

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        Column(modifier = Modifier.fillMaxSize()) {
            TvTopBar(
                section = section,
                onSelectSection = ::selectSection,
                onOpenSettings = onOpenSettings,
                homeFocusRequester = homeFocus,
            )
            HorizontalDivider(color = colors.separator)

            // 一级分区内容。
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
                                onBack = { browseDestination = null },
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

            // 正在播放条：TV 惯例常驻底部（有播放内容时）。
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
                    onOpen = { nowPlayingOpen = true },
                    onPrevious = { controller.previous() },
                    onTogglePlayPause = { controller.togglePlayPause() },
                    onNext = { controller.next() },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
                )
            }
        }

        // 正在播放全屏页：覆盖整个壳。
        if (nowPlayingOpen && playback.track != null) {
            NowPlayingScreen(
                graph = graph,
                controller = controller,
                onClose = { nowPlayingOpen = false },
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
                Surface(
                    shape = shape,
                    color = if (selected) colors.accent.copy(alpha = 0.22f) else colors.elevated,
                    modifier = if (entry == TvSection.Home) {
                        Modifier.tvFocusVisual(shape).tvClick { onSelectSection(entry) }
                            .focusRequester(homeFocusRequester)
                    } else {
                        Modifier.tvFocusVisual(shape).tvClick { onSelectSection(entry) }
                    },
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
        // 封面 + 标题区：点击展开正在播放。
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
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
