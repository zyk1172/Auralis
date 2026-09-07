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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.PlaybackState
import com.auralis.core.playback.LocalPlaybackHost
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot

/**
 * 移动端 Shell（对齐 Apple IOSMusicShell）：
 * - 内容根随一级分区切换（Home / Library / Assistant），切分区即回到分区根页；
 * - Bottom Dock 与 Mini Player 作为 **overlay** 固定在底部，宽屏最大约 760dp 居中；
 * - Mini Player 只在 Home / Library 显示（Assistant 分区由自身附件持有底部空间）；
 * - 无正在播放内容时 Mini Player 隐藏，Dock 保持。
 */
@Composable
fun MobileShell(
    graph: AuralisGraph,
    onOpenServers: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var section by rememberSaveable { mutableStateOf(AppSection.Home) }

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

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        // 一级分区内容。
        when (section) {
            AppSection.Home -> HomePlaceholderPage(graph = graph, onManageServers = onOpenServers)
            AppSection.Library -> LibraryPlaceholderPage(onOpenSettings = onOpenSettings)
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
