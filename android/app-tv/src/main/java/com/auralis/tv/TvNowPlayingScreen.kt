// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import com.auralis.core.playback.PlaybackCapabilities
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import com.auralis.feature.player.R as PlayerR
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * Native ten-foot Now Playing experience. Mobile's narrow 680dp column and 350dp artwork are not
 * reused on TV: artwork/transport live on the left while lyrics, queue and source details remain
 * visible in a persistent right context panel.
 */
@Composable
fun TvNowPlayingScreen(
    graph: AuralisGraph,
    controller: PlaybackController,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var playback by remember { mutableStateOf(controller.playback.value) }
    var queue by remember { mutableStateOf(controller.queue.value) }
    val positionMs by controller.position.collectAsState()
    var panel by remember { mutableIntStateOf(0) }

    LaunchedEffect(controller) { controller.playback.collect { playback = it } }
    LaunchedEffect(controller) { controller.queue.collect { queue = it } }
    BackHandler(onBack = onClose)

    val track = playback.track ?: return
    val durationMs = playback.durationMs.coerceAtLeast(0L)
    val progress = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    val ambient = Brush.linearGradient(
        listOf(
            colors.background,
            colors.accent.copy(alpha = 0.10f),
            colors.background,
        ),
    )

    Box(modifier.fillMaxSize().background(ambient)) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 56.dp, vertical = 36.dp),
            horizontalArrangement = Arrangement.spacedBy(48.dp),
        ) {
            Column(
                modifier = Modifier
                    .weight(0.44f)
                    .fillMaxHeight(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                AuralisArtwork(
                    serverId = track.serverId,
                    artworkKey = track.artworkKey,
                    contentDescription = track.albumTitle,
                    titleForFallback = track.albumTitle,
                    targetSizeDp = 420,
                    shape = RoundedCornerShape(24.dp),
                    modifier = Modifier
                        .size(420.dp)
                        .clip(RoundedCornerShape(24.dp)),
                )
                Spacer(Modifier.height(28.dp))
                Text(
                    track.title,
                    style = MaterialTheme.typography.displaySmall,
                    fontWeight = FontWeight.Bold,
                    color = colors.primaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "${track.artistName} · ${track.albumTitle}",
                    style = MaterialTheme.typography.titleMedium,
                    color = colors.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(50)),
                    color = colors.accent,
                    trackColor = colors.separator.copy(alpha = 0.35f),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(formatTvClock(positionMs), color = colors.secondaryText, style = MaterialTheme.typography.labelMedium)
                    Text("-${formatTvClock((durationMs - positionMs).coerceAtLeast(0L))}", color = colors.secondaryText, style = MaterialTheme.typography.labelMedium)
                }
                Spacer(Modifier.height(16.dp))
                TvTransportRow(controller, playback, queue, positionMs, durationMs)
            }

            Column(
                modifier = Modifier
                    .weight(0.56f)
                    .fillMaxHeight()
                    .background(colors.surface.copy(alpha = 0.62f), RoundedCornerShape(28.dp))
                    .padding(24.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TvSquareAction(onClick = onClose) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(AuralisR.string.back),
                            tint = colors.primaryText,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                    Spacer(Modifier.width(20.dp))
                    TvPanelTabs(selected = panel, onSelect = { panel = it })
                }
                Spacer(Modifier.height(20.dp))
                Box(Modifier.fillMaxSize()) {
                    when (panel) {
                        0 -> TvLyricsPanel(graph, track, positionMs)
                        1 -> TvQueuePanel(queue, controller)
                        else -> TvTrackInfoPanel(track, playback)
                    }
                }
            }
        }
    }
}

@Composable
private fun TvTransportRow(
    controller: PlaybackController,
    playback: PlaybackSnapshot,
    queue: QueueSnapshot,
    positionMs: Long,
    durationMs: Long,
) {
    val colors = LocalAuralisTheme.current.colors
    val canPrev = PlaybackCapabilities.canGoPrevious(playback, queue)
    val canNext = PlaybackCapabilities.canGoNext(playback, queue)
    val isPlaying = playback.state is PlaybackState.Playing
    val busy = playback.state is PlaybackState.Buffering || playback.state is PlaybackState.Preparing || playback.state is PlaybackState.Stalled

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TvRoundAction(enabled = canPrev, onClick = { controller.previous() }) {
            Icon(Icons.Filled.SkipPrevious, contentDescription = stringResource(AuralisR.string.previous), tint = colors.primaryText, modifier = Modifier.size(34.dp))
        }
        TvRoundAction(enabled = positionMs > 0, onClick = { controller.seekTo((positionMs - 10_000L).coerceAtLeast(0L)) }) {
            Icon(Icons.Filled.FastRewind, contentDescription = "-10s", tint = colors.primaryText, modifier = Modifier.size(32.dp))
        }
        TvRoundAction(
            enabled = !busy && (playback.state is PlaybackState.Playing || playback.state is PlaybackState.Paused),
            emphasized = true,
            onClick = { controller.togglePlayPause() },
        ) {
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(32.dp), strokeWidth = 3.dp, color = colors.primaryText)
            } else {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) stringResource(AuralisR.string.pause) else stringResource(AuralisR.string.play),
                    tint = colors.primaryText,
                    modifier = Modifier.size(42.dp),
                )
            }
        }
        TvRoundAction(enabled = durationMs > 0 && positionMs < durationMs, onClick = { controller.seekTo((positionMs + 10_000L).coerceAtMost(durationMs)) }) {
            Icon(Icons.Filled.FastForward, contentDescription = "+10s", tint = colors.primaryText, modifier = Modifier.size(32.dp))
        }
        TvRoundAction(enabled = canNext, onClick = { controller.next() }) {
            Icon(Icons.Filled.SkipNext, contentDescription = stringResource(AuralisR.string.next), tint = colors.primaryText, modifier = Modifier.size(34.dp))
        }
    }
}

@Composable
private fun TvPanelTabs(selected: Int, onSelect: (Int) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val labels = listOf(
        stringResource(PlayerR.string.player_tab_lyrics),
        stringResource(PlayerR.string.player_tab_queue),
        "音频信息",
    )
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        labels.forEachIndexed { index, label ->
            val shape = RoundedCornerShape(18.dp)
            Surface(
                shape = shape,
                color = if (selected == index) colors.accent.copy(alpha = 0.22f) else colors.elevated,
                modifier = Modifier.tvFocusVisual(shape).tvClick { onSelect(index) },
            ) {
                Text(
                    label,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 14.dp),
                    color = if (selected == index) colors.primaryText else colors.secondaryText,
                    style = MaterialTheme.typography.titleSmall,
                )
            }
        }
    }
}

@Composable
private fun TvLyricsPanel(graph: AuralisGraph, track: Track, positionMs: Long) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    var document by remember(track.globalId) { mutableStateOf<LyricsDocument?>(null) }
    var loading by remember(track.globalId) { mutableStateOf(true) }
    var error by remember(track.globalId) { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()

    LaunchedEffect(track.globalId) {
        loading = true
        error = null
        runCatching { graph.lyricsService.lyricsFor(track) }
            .onSuccess { document = it }
            .onFailure { error = it.message ?: it::class.java.simpleName }
        loading = false
    }

    val doc = document
    val activeIndex = if (doc?.isSynced == true) {
        val seconds = positionMs / 1000.0
        doc.lines.indexOfLast { (it.startTimeSeconds ?: Double.MAX_VALUE) <= seconds + 0.05 }.takeIf { it >= 0 }
    } else null

    LaunchedEffect(activeIndex, track.globalId) {
        val target = activeIndex ?: return@LaunchedEffect
        yield()
        if (reduceMotion) listState.scrollToItem(target) else listState.animateScrollToItem(target)
    }

    when {
        loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = colors.accent)
        }
        error != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(error.orEmpty(), color = colors.secondaryText, textAlign = TextAlign.Center)
        }
        doc == null || doc.lines.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(PlayerR.string.player_lyrics_none_title), color = colors.secondaryText, style = MaterialTheme.typography.titleLarge)
        }
        else -> LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 32.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            itemsIndexed(doc.lines) { index, line ->
                val current = index == activeIndex
                Text(
                    line.text,
                    color = if (current) colors.accent else colors.secondaryText.copy(alpha = if (activeIndex == null) 1f else 0.64f),
                    fontSize = if (current) 30.sp else 24.sp,
                    lineHeight = if (current) 38.sp else 32.sp,
                    fontWeight = if (current) FontWeight.Bold else FontWeight.Medium,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun TvQueuePanel(queue: QueueSnapshot, controller: PlaybackController) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    if (queue.entries.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(PlayerR.string.player_queue_empty), color = colors.secondaryText)
        }
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        itemsIndexed(queue.entries, key = { _, item -> item.id.value }) { _, entry ->
            val current = entry.id == queue.currentEntryId
            val shape = RoundedCornerShape(16.dp)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(if (current) colors.accent.copy(alpha = 0.14f) else colors.elevated.copy(alpha = 0.5f), shape)
                    .tvFocusVisual(shape)
                    .tvClick { scope.launch { controller.playOccurrence(entry.id) } }
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AuralisArtwork(
                    serverId = entry.track.serverId,
                    artworkKey = entry.track.artworkKey,
                    contentDescription = null,
                    titleForFallback = entry.track.title,
                    targetSizeDp = 64,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.size(64.dp),
                )
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(entry.track.title, color = if (current) colors.accent else colors.primaryText, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${entry.track.artistName} · ${entry.track.albumTitle}", color = colors.secondaryText, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(formatTvClock((entry.track.durationSeconds * 1000).toLong()), color = colors.secondaryText, style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun TvTrackInfoPanel(track: Track, playback: PlaybackSnapshot) {
    val colors = LocalAuralisTheme.current.colors
    val source = track.sourceInfo
    val rows = listOf(
        "格式" to (source.normalizedCodec?.uppercase() ?: "—"),
        "采样率" to (source.sampleRate?.let { "${it / 1000.0} kHz" } ?: "—"),
        "位深" to (source.bitDepth?.let { "$it bit" } ?: "—"),
        "码率" to (source.bitRate?.let { "${it / 1000} kbps" } ?: "—"),
        "声道" to (source.channelCount?.toString() ?: "—"),
        "播放速度" to "${playback.speed}×",
        "来源" to if (playback.isLocalSource) "本地下载" else "服务器流媒体",
    )
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Text(track.title, color = colors.primaryText, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        rows.forEach { (label, value) ->
            Row(Modifier.fillMaxWidth()) {
                Text(label, color = colors.secondaryText, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                Text(value, color = colors.primaryText, style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

@Composable
private fun TvSquareAction(onClick: () -> Unit, content: @Composable () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(18.dp)
    Surface(
        shape = shape,
        color = colors.elevated,
        modifier = Modifier.size(58.dp).tvFocusVisual(shape).tvClick(onClick),
    ) {
        Box(contentAlignment = Alignment.Center) { content() }
    }
}

@Composable
private fun TvRoundAction(
    enabled: Boolean,
    emphasized: Boolean = false,
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(50)
    val size = if (emphasized) 82.dp else 66.dp
    Surface(
        shape = shape,
        color = if (emphasized) colors.accent.copy(alpha = 0.28f) else colors.elevated.copy(alpha = 0.8f),
        modifier = Modifier
            .padding(horizontal = 7.dp)
            .size(size)
            .then(if (enabled) Modifier.tvFocusVisual(shape).tvClick(onClick) else Modifier),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Box(Modifier.then(if (enabled) Modifier else Modifier)) { content() }
        }
    }
}

private fun formatTvClock(ms: Long): String {
    val totalSeconds = (ms.coerceAtLeast(0L) / 1000L)
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "%d:%02d".format(minutes, seconds)
}
