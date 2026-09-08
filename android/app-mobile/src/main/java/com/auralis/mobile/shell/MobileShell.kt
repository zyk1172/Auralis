// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisSpacing
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
import com.auralis.feature.home.HomeScreen
import com.auralis.feature.library.BrowseDetailScreen
import com.auralis.feature.library.LibraryScreen
import com.auralis.feature.player.NowPlayingScreen
import com.auralis.feature.player.PlayerTrackAction
import com.auralis.feature.search.SearchScreen
import com.auralis.mobile.R
import kotlinx.coroutines.launch
import com.auralis.core.designsystem.R as AuralisR

/**
 * 移动端 Shell（对齐 Apple IOSMusicShell）：
 * - 内容根随一级分区切换（Home / Library / Assistant），切分区即回到分区根页；
 * - Bottom Dock 与 Mini Player 作为 **overlay** 固定在底部，宽屏最大约 760dp 居中；
 * - Mini Player 只在 Home / Library 显示（Assistant 分区由自身附件持有底部空间）；
 * - 无正在播放内容时 Mini Player 隐藏，Dock 保持。
 *
 * S3：Home 分区已接入真实首页（模块注册表驱动 + 真实数据 + 播放/换一批/编辑入口）。
 * S4：Library 分区接入真实音乐库（scope 切换 + Browse 详情覆盖路由）。Home 内浏览跳转
 * （快捷入口 / 数量 › / 艺人·专辑卡）→ 切到 Library 分区并在其上打开 BrowseDetailScreen
 * 覆盖页；页面内部自带返回栈（常听 → 专辑/艺术家）。
 */
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
    // 浏览详情（S4）：非 null 时在 Library 分区内容上方覆盖真实浏览页。
    var browseDestination by remember { mutableStateOf<BrowseDestination?>(null) }
    // 正在播放全屏页（S5）：点 Mini Player 打开，覆盖整个 Shell（含 Dock）。
    var nowPlayingOpen by remember { mutableStateOf(false) }
    // 搜索覆盖页（S6）：对齐 Swift「搜索是助手内的兜底能力」，从 Assistant 顶栏
    // 放大镜以 sheet 拉起「搜索音乐库」；Android 侧用全屏覆盖实现同一语义。
    var searchOpen by remember { mutableStateOf(false) }
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

    /** 把货架作为新队列并从点中的那首开始播放（真实动作，P0-1：首击不丢）。 */
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

    /** 「加入队列」：整组追加到队尾，不打断当前播放（P0-1：首击不丢）。 */
    fun appendQueueShelf(tracks: List<Track>) {
        scope.launch {
            val ready = awaitControllerOrNotify() ?: return@launch
            runCatching { ready.appendToQueue(tracks.map { QueueEntry.of(it) }) }
        }
    }

    /** 浏览请求 → 切 Library 分区并打开覆盖浏览页。 */
    fun openBrowse(destination: BrowseDestination) {
        nowPlayingOpen = false
        searchOpen = false
        browseDestination = destination
        section = AppSection.Library
    }

    /**
     * R4 播放页转交动作：关闭播放页 → 切到 Assistant 分区 → 干净新会话并自动发送引导文案。
     * （Swift「由此继续播放」留在播放页后台跑；Android 的 consent/确认对话框只渲染在
     * Assistant 页，故统一先切页再运行，避免引导会话静默挂起等待授权——R8 记录此差异。）
     */
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

    // 系统返回：正在播放全屏页 > 搜索覆盖页 > 浏览详情（单处理器保证正确优先级）。
    BackHandler(enabled = nowPlayingOpen || searchOpen || browseDestination != null) {
        when {
            nowPlayingOpen -> nowPlayingOpen = false
            searchOpen -> searchOpen = false
            browseDestination != null -> browseDestination = null
        }
    }

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        // 一级分区内容。
        when (section) {
            AppSection.Home -> HomeScreen(
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

        // 底部 Chrome（Dock 恒显；Mini Player 有内容且非 Assistant 分区时显示）。
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = AuralisSpacing.small),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val showMini = engineAvailable &&
                section != AppSection.Assistant &&
                playback.entry != null && playback.track != null
            if (showMini && playback.track != null) {
                val currentLogical = queue.currentLogicalIndex
                Row(
                    modifier = Modifier
                        .widthIn(max = 760.dp)
                        .fillMaxWidth()
                        .padding(horizontal = AuralisSpacing.large),
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
                            if (playback.state is PlaybackState.Playing ||
                                playback.state is PlaybackState.Paused
                            ) {
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
                    .widthIn(max = 760.dp)
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large),
            ) {
                BottomDock(
                    selected = section,
                    onSelect = { sel ->
                        nowPlayingOpen = false
                        searchOpen = false
                        if (sel == AppSection.Library) {
                            if (section == AppSection.Library && browseDestination != null) {
                                browseDestination = null // 再点 Library：回到库根
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

        // 正在播放全屏页：覆盖整个 Shell（含 Dock/Mini Player）。
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

        // 搜索覆盖页（S6）：从 Assistant 顶栏放大镜进入，覆盖整个 Shell（含 Dock）。
        // 播放/浏览动作复用分区语义：点歌曲播放；点专辑/艺术家/歌单 → 切库打开详情。
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
