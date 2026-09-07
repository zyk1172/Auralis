package com.auralis.mobile.shell

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
import com.auralis.feature.home.HomeScreen
import kotlinx.coroutines.launch

/**
 * 移动端 Shell（对齐 Apple IOSMusicShell）：
 * - 内容根随一级分区切换（Home / Library / Assistant），切分区即回到分区根页；
 * - Bottom Dock 与 Mini Player 作为 **overlay** 固定在底部，宽屏最大约 760dp 居中；
 * - Mini Player 只在 Home / Library 显示（Assistant 分区由自身附件持有底部空间）；
 * - 无正在播放内容时 Mini Player 隐藏，Dock 保持。
 *
 * S3：Home 分区已接入真实首页（模块注册表驱动 + 真实数据 + 播放/换一批/编辑入口）。
 * Home 内的浏览跳转（快捷入口 / 数量 › / 艺人·专辑卡）切换到 Library 分区并携带
 * BrowseDestination —— 完整浏览页在 S4（Library + Browse Detail）实现，在此之前
 * Library 分区显示该目标对应的占位（非假数据，是阶段过渡）。
 */
@Composable
fun MobileShell(
    graph: AuralisGraph,
    onOpenServers: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenEditHomeLayout: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var section by rememberSaveable { mutableStateOf(AppSection.Home) }
    // 从 Home 进入的浏览目的地（快捷入口/数量›/艺人·专辑卡）。Library 分区承接。
    var pendingBrowse by remember { mutableStateOf<BrowseDestination?>(null) }
    val scope = rememberCoroutineScope()

    // ---- 播放状态（真实绑定；引擎由 AuralisPlaybackService 创建后 available=true）----
    val engineAvailable by LocalPlaybackHost.available.collectAsState()
    val controller = remember { LocalPlaybackHost.controller() }
    var playback by remember { mutableStateOf(PlaybackSnapshot.Empty) }
    LaunchedEffect(controller, engineAvailable) {
        if (engineAvailable) {
            controller.playback.collect { playback = it }
        } else {
            playback = PlaybackSnapshot.Empty
        }
    }

    /** 把货架作为新队列并从点中的那首开始播放（真实动作）。 */
    fun playShelf(tracks: List<Track>, startIndex: Int) {
        if (!engineAvailable) {
            // 引擎未就绪：先启动播放服务（幂等），引擎就绪后用户再点即播——不假装已播放。
            graph.startPlaybackService()
            return
        }
        scope.launch {
            runCatching {
                controller.playQueue(tracks.map { QueueEntry.of(it) }, startIndex.coerceIn(0, tracks.lastIndex))
            }
        }
    }

    /** Home 内的浏览请求 → 切 Library 分区并携带目的地（页面内容在 S4 实现）。 */
    fun openBrowse(destination: BrowseDestination) {
        pendingBrowse = destination
        section = AppSection.Library
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

            AppSection.Library -> LibraryPlaceholderPage(
                browseTarget = pendingBrowse,
                onOpenSettings = onOpenSettings,
            )

            AppSection.Assistant -> AssistantPlaceholderPage()
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
                        onTogglePlayPause = {
                            if (playback.state is PlaybackState.Playing ||
                                playback.state is PlaybackState.Paused
                            ) {
                                controller.togglePlayPause()
                            }
                        },
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
                    onSelect = { section = it },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
