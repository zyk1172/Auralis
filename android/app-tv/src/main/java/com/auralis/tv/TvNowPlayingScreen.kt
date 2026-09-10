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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.data.graph.AuralisGraph
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
 * Dedicated ten-foot player inspired by the Mac expanded-player hierarchy: identity and transport
 * stay in a stable left column, while lyrics/queue/audio information live in a persistent context
 * panel. This is a real route, not an overlay above the browse shell.
 *
 * Focus is explicit state. Entering the page focuses Play/Pause; activating Previous/Next or seek
 * keeps that same control focused after the track/media list changes. This is important on physical
 * TVs where a recomposition can otherwise leave the remote focus on a node that was just replaced.
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

    val transportFocus = remember { List(5) { FocusRequester() } }
    var lastTransportFocus by remember { mutableIntStateOf(2) }
    val backFocus = remember { FocusRequester() }

    LaunchedEffect(controller) { controller.playback.collect { playback = it } }
    LaunchedEffect(controller) { controller.queue.collect { queue = it } }
    BackHandler(onBack = onClose)

    LaunchedEffect(Unit) {
        yield()
        runCatching { transportFocus[2].requestFocus() }
    }

    // Track replacement is exactly where real TVs used to lose the focused Next/Previous node.
    // Re-request the user's last transport target only after the new player state is mounted.
    LaunchedEffect(playback.entry?.id?.value) {
        yield()
        runCatching { transportFocus[lastTransportFocus].requestFocus() }
    }

    val track = playback.track ?: return
    val durationMs = playback.durationMs.coerceAtLeast(0L)
    val progress = if (durationMs > 0) {
        (positionMs.toFloat() / durationMs).coerceIn(0f, 1f)
    } else {
        0f
    }
    val ambient = Brush.linearGradient(
        listOf(
            colors.background,
            colors.accent.copy(alpha = 0.09f),
            colors.background,
        ),
    )

    Box(modifier.fillMaxSize().background(ambient)) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 54.dp, vertical = 34.dp),
            horizontalArrangement = Arrangement.spacedBy(46.dp),
        ) {
            Column(
                modifier = Modifier
                    .weight(0.46f)
                    .fillMaxHeight(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                AuralisArtwork(
                    serverId = track.serverId,
                    artworkKey = track.artworkKey,
                    contentDescription = track.albumTitle,
                    titleForFallback = track.albumTitle,
                    targetSizeDp = 416,
                    shape = RoundedCornerShape(26.dp),
                    modifier = Modifier
                        .size(416.dp)
                        .clip(RoundedCornerShape(26.dp)),
                )
                Spacer(Modifier.height(24.dp))
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
                Spacer(Modifier.height(7.dp))
                Text(
                    "${track.artistName} · ${track.albumTitle}",
                    style = MaterialTheme.typography.titleMedium,
                    color = colors.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(21.dp))
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(6.dp)
                        .clip(RoundedCornerShape(50)),
                    color = colors.accent,
                    trackColor = colors.separator.copy(alpha = 0.34f),
                )
                Spacer(Modifier.height(7.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        formatTvClock(positionMs),
                        color = colors.secondaryText,
                        style = MaterialTheme.typography.labelMedium,
                    )
                    Text(
                        "-${formatTvClock((durationMs - positionMs).coerceAtLeast(0L))}",
                        color = colors.secondaryText,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
                Spacer(Modifier.height(17.dp))
                TvTransportRow(
                    controller = controller,
                    playback = playback,
                    queue = queue,
                    positionMs = positionMs,
                    durationMs = durationMs,
                    requesters = transportFocus,
                    onFocusedIndex = { lastTransportFocus = it },
                )
            }

            Column(
                modifier = Modifier
                    .weight(0.54f)
                    .fillMaxHeight()
                    .background(colors.surface.copy(alpha = 0.66f), RoundedCornerShape(30.dp))
                    .padding(24.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TvSquareAction(
                        onClick = onClose,
                        modifier = Modifier.focusRequester(backFocus),
                    ) {
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
                Spacer(Modifier.height(18.dp))
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
    requesters: List<FocusRequester>,
    onFocusedIndex: (Int) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val canPrev = PlaybackCapabilities.canGoPrevious(playback, queue)
    val canNext = PlaybackCapabilities.canGoNext(playback, queue)
    val isPlaying = playback.state is PlaybackState.Playing
    val busy = playback.state is PlaybackState.Buffering ||
        playback.state is PlaybackState.Preparing ||
        playback.state is PlaybackState.Stalled

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TvRoundAction(
            enabled = canPrev,
            onClick = { controller.previous() },
            modifier = Modifier.focusRequester(requesters[0]),
            onFocusedChange = { if (it) onFocusedIndex(0) },
        ) {
            Icon(
                Icons.Filled.SkipPrevious,
                contentDescription = stringResource(AuralisR.string.previous),
                tint = colors.primaryText,
                modifier = Modifier.size(34.dp),
            )
        }
        TvRoundAction(
            enabled = positionMs > 0,
            onClick = { controller.seekTo((positionMs - 10_000L).coerceAtLeast(0L)) },
            modifier = Modifier.focusRequester(requesters[1]),
            onFocusedChange = { if (it) onFocusedIndex(1) },
        ) {
            Icon(
                Icons.Filled.FastRewind,
                contentDescription = stringResource(R.string.tv_seek_back_10),
                tint = colors.primaryText,
                modifier = Modifier.size(32.dp),
            )
        }
        TvRoundAction(
            enabled = !busy && (playback.state is PlaybackState.Playing || playback.state is PlaybackState.Paused),
            emphasized = true,
            onClick = { controller.togglePlayPause() },
            modifier = Modifier.focusRequester(requesters[2]),
            onFocusedChange = { if (it) onFocusedIndex(2) },
        ) {
            if (busy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(32.dp),
                    strokeWidth = 3.dp,
                    color = colors.primaryText,
                )
            } else {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) {
                        stringResource(AuralisR.string.pause)
                    } else {
                        stringResource(AuralisR.string.play)
                    },
                    tint = colors.primaryText,
                    modifier = Modifier.size(42.dp),
                )
            }
        }
        TvRoundAction(
            enabled = durationMs > 0 && positionMs < durationMs,
            onClick = { controller.seekTo((positionMs + 10_000L).coerceAtMost(durationMs)) },
            modifier = Modifier.focusRequester(requesters[3]),
            onFocusedChange = { if (it) onFocusedIndex(3) },
        ) {
            Icon(
                Icons.Filled.FastForward,
                contentDescription = stringResource(R.string.tv_seek_forward_10),
                tint = colors.primaryText,
                modifier = Modifier.size(32.dp),
            )
        }
        TvRoundAction(
            enabled = canNext,
            onClick = { controller.next() },
            modifier = Modifier.focusRequester(requesters[4]),
            onFocusedChange = { if (it) onFocusedIndex(4) },
        ) {
            Icon(
                Icons.Filled.SkipNext,
                contentDescription = stringResource(AuralisR.string.next),
                tint = colors.primaryText,
                modifier = Modifier.size(34.dp),
            )
        }
    }
}

@Composable
private fun TvPanelTabs(selected: Int, onSelect: (Int) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val labels = listOf(
        stringResource(PlayerR.string.player_tab_lyrics),
        stringResource(PlayerR.string.player_tab_queue),
        stringResource(R.string.tv_audio_info),
    )
    Row(horizontalArrangement = Arrangement.spacedBy(11.dp)) {
        labels.forEachIndexed { index, label ->
            val shape = RoundedCornerShape(18.dp)
            Surface(
                shape = shape,
                color = if (selected == index) {
                    colors.accent.copy(alpha = 0.22f)
                } else {
                    colors.elevated
                },
                modifier = Modifier.tvFocusableClick(shape = shape) { onSelect(index) },
            ) {
                Text(
                    label,
                    modifier = Modifier.padding(horizontal = 22.dp, vertical = 13.dp),
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
        doc.lines.indexOfLast {
            (it.startTimeSeconds ?: Double.MAX_VALUE) <= seconds + 0.05
        }.takeIf { it >= 0 }
    } else {
        null
    }

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
            Text(
                stringResource(PlayerR.string.player_lyrics_none_title),
                color = colors.secondaryText,
                style = MaterialTheme.typography.titleLarge,
            )
        }

        else -> LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 32.dp),
            verticalArrangement = Arrangement.spacedBy(21.dp),
        ) {
            itemsIndexed(doc.lines) { index, line ->
                val current = index == activeIndex
                Text(
                    line.text,
                    color = if (current) {
                        colors.accent
                    } else {
                        colors.secondaryText.copy(alpha = if (activeIndex == null) 1f else 0.64f)
                    },
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
                    .background(
                        if (current) colors.accent.copy(alpha = 0.14f)
                        else colors.elevated.copy(alpha = 0.5f),
                        shape,
                    )
                    .tvFocusableClick(shape = shape) {
                        scope.launch { controller.playOccurrence(entry.id) }
                    }
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
                    Text(
                        entry.track.title,
                        color = if (current) colors.accent else colors.primaryText,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        "${entry.track.artistName} · ${entry.track.albumTitle}",
                        color = colors.secondaryText,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    formatTvClock((entry.track.durationSeconds * 1000).toLong()),
                    color = colors.secondaryText,
                    style = MaterialTheme.typography.labelMedium,
                )
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
        "来源" to if (playback.isLocalSource) "本地文件" else "服务器流",
    )

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        itemsIndexed(rows) { _, row ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colors.elevated.copy(alpha = 0.5f), RoundedCornerShape(14.dp))
                    .padding(horizontal = 18.dp, vertical = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    row.first,
                    style = MaterialTheme.typography.titleSmall,
                    color = colors.secondaryText,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    row.second,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.primaryText,
                )
            }
        }
    }
}

@Composable
private fun TvSquareAction(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(18.dp)
    Surface(
        shape = shape,
        color = colors.elevated,
        modifier = modifier
            .size(58.dp)
            .tvFocusableClick(shape = shape, onClick = onClick),
    ) {
        Box(contentAlignment = Alignment.Center) { content() }
    }
}

@Composable
private fun TvRoundAction(
    enabled: Boolean,
    emphasized: Boolean = false,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onFocusedChange: (Boolean) -> Unit = {},
    content: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(50)
    val size = if (emphasized) 82.dp else 66.dp
    Surface(
        shape = shape,
        color = if (emphasized) {
            colors.accent.copy(alpha = 0.28f)
        } else {
            colors.elevated.copy(alpha = 0.8f)
        },
        modifier = modifier
            .padding(horizontal = 7.dp)
            .size(size)
            .tvFocusableClick(
                shape = shape,
                enabled = enabled,
                onFocusedChange = onFocusedChange,
                onClick = onClick,
            ),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Box(
                modifier = Modifier,
                contentAlignment = Alignment.Center,
            ) {
                content()
            }
        }
    }
}

private fun formatTvClock(ms: Long): String {
    val totalSeconds = ms.coerceAtLeast(0L) / 1000L
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "%d:%02d".format(minutes, seconds)
}
