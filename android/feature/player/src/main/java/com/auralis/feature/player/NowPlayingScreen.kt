// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import android.content.Context
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.outlined.ThumbDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisMotion
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * 正在播放全屏页（对齐 Swift `NowPlayingView`，S5/R9）。
 *
 * - 使用与 iOS 相同的 42% accent / background / 22% secondary-accent 环境渐变；
 * - 宽屏内容封顶 680dp，保持 iPad/Android 平板与手机为同一套布局而不是横向拉伸；
 * - 顶部用模态下收语义而非返回导航语义，分段控件按系统 segmented geometry 收紧；
 * - 播放内容按 Apple 的 650pt 高度阈值在 10/15dp 间距和 56/64dp 主播放键之间切换；
 * - **标题·进度·传输区固定在最下方**（切页不跳动）：标题/艺人跑马灯、收藏心形、
 *   可拖动进度条（松手才 seek）、五键传输（模式循环/上一首/播放暂停/下一首/⋯）、音量、音频信息；
 * - 歌词页按真实播放位置高亮并以中心锚点滚动，无歌词给空态；
 * - 队列页复用 Apple TrackRow 密度和 42% surface 容器；编辑仍按 occurrence UUID 操作。
 */
@Composable
fun NowPlayingScreen(
    graph: AuralisGraph,
    controller: PlaybackController,
    onClose: () -> Unit,
    onOpenBrowse: (BrowseDestination) -> Unit,
    onTrackAction: PlayerTrackActionHandler? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val playback by controller.playback.collectAsState()
    val queue by controller.queue.collectAsState()
    val tickPosition by controller.position.collectAsState(initial = playback.positionMs)

    val track = playback.track
    LaunchedEffect(track) { if (track == null) onClose() }
    if (track == null) return

    var pageOrdinal by rememberSaveable { mutableStateOf(PlayerTab.Player.ordinal) }
    val page = PlayerTab.entries[pageOrdinal]

    var dragging by remember { mutableStateOf(false) }
    var dragFraction by remember { mutableStateOf(0f) }
    val durationMs = playback.durationMs
    val displayMs = if (dragging) (dragFraction * durationMs).toLong() else tickPosition

    Box(
        modifier = modifier.fillMaxSize().background(
            Brush.linearGradient(
                listOf(
                    colors.accent.copy(alpha = 0.42f),
                    colors.background,
                    colors.accentSecondary.copy(alpha = 0.22f),
                ),
            ),
        ),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = AuralisChrome.playerContentMaxWidth)
                .fillMaxWidth()
                .fillMaxHeight()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(AuralisSpacing.large),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = onClose,
                    modifier = Modifier.size(44.dp),
                ) {
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = stringResource(R.string.player_dismiss_now_playing),
                        tint = colors.primaryText,
                        modifier = Modifier.size(22.dp),
                    )
                }
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        stringResource(R.string.player_tab_now_playing),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.primaryText,
                    )
                    Text(
                        track.albumTitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.secondaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.size(44.dp))
            }

            Spacer(Modifier.height(AuralisSpacing.large))
            PlayerPageSelector(selected = page, onSelect = { pageOrdinal = it.ordinal })
            Spacer(Modifier.height(AuralisSpacing.large))

            // Swift 的 GeometryReader 同时包住上方内容和固定控制区：剩余高度 <650 时压缩节奏。
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                val compactHeight = maxHeight < 650.dp
                val sectionSpacing = if (compactHeight) 10.dp else 15.dp
                val playButtonSize = if (compactHeight) 56.dp else 64.dp

                Column(
                    modifier = Modifier.fillMaxSize(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(sectionSpacing),
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .padding(horizontal = AuralisSpacing.medium),
                    ) {
                        when (page) {
                            PlayerTab.Lyrics -> LyricsContent(graph, track, positionMs = displayMs)
                            PlayerTab.Player -> HeroContent(
                                track = track,
                                isPlaying = playback.state is PlaybackState.Playing,
                            )
                            PlayerTab.Queue -> QueueContent(graph, queue = queue, controller = controller)
                        }
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = AuralisSpacing.medium),
                        contentAlignment = Alignment.Center,
                    ) {
                        PlaybackControlsArea(
                            graph = graph,
                            controller = controller,
                            playback = playback,
                            queue = queue,
                            track = track,
                            displayMs = displayMs,
                            durationMs = durationMs,
                            dragging = dragging,
                            dragFraction = dragFraction,
                            sectionSpacing = sectionSpacing,
                            playButtonSize = playButtonSize,
                            onDragFraction = { dragging = true; dragFraction = it },
                            onDragEnd = {
                                if (durationMs > 0) controller.seekTo((dragFraction * durationMs).toLong())
                                dragging = false
                            },
                            onOpenBrowse = onOpenBrowse,
                            onTrackAction = onTrackAction,
                        )
                    }
                }
            }
        }
    }
}

// ================================================================ 分段与页面

@Composable
private fun PlayerPageSelector(selected: PlayerTab, onSelect: (PlayerTab) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val outerShape = RoundedCornerShape(10.dp)
    val selectedShape = RoundedCornerShape(8.dp)

    Row(
        modifier = Modifier
            .widthIn(max = 460.dp)
            .fillMaxWidth()
            .clip(outerShape)
            .background(colors.elevated.copy(alpha = 0.82f))
            .padding(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PlayerTab.entries.forEach { tab ->
            val active = tab == selected
            val bg by animateColorAsState(
                targetValue = if (active) colors.surface else Color.Transparent,
                label = "player-segment-bg",
            )
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(32.dp)
                    .clip(selectedShape)
                    .background(bg)
                    .clickable { onSelect(tab) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    stringResource(tab.titleRes),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                    color = if (active) colors.primaryText else colors.secondaryText,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun HeroContent(track: Track, isPlaying: Boolean) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = minOf(maxWidth * 0.84f, maxHeight * 0.88f, 350.dp)
        val glowSide = minOf(side * 1.10f, maxWidth, maxHeight)
        val shape = RoundedCornerShape(AuralisRadius.large)

        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = null,
            titleForFallback = track.albumTitle,
            targetSizeDp = glowSide.value.toInt(),
            shape = shape,
            modifier = Modifier
                .size(glowSide)
                .alpha(if (isPlaying) 0.30f else 0.20f)
                .blur(30.dp),
        )
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.albumTitle,
            titleForFallback = track.albumTitle,
            targetSizeDp = side.value.toInt(),
            shape = shape,
            modifier = Modifier
                .size(side)
                .shadow(elevation = 12.dp, shape = shape, clip = false),
        )
    }
}

@Composable
private fun LyricsContent(graph: AuralisGraph, track: Track, positionMs: Long) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val reduceMotion = LocalReduceMotion.current
    val density = LocalDensity.current
    var loadState by remember { mutableStateOf<LyricsLoad>(LyricsLoad.Loading) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(track.globalId, reloadKey) {
        loadState = LyricsLoad.Loading
        runCatching { graph.lyricsService.lyricsFor(track) }
            .onSuccess { doc -> loadState = if (doc == null) LyricsLoad.None else LyricsLoad.Ready(doc) }
            .onFailure { loadState = LyricsLoad.Error(context.getString(R.string.player_lyrics_load_failed, it.message)) }
    }
    val listState = rememberLazyListState()
    when (val state = loadState) {
        LyricsLoad.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = colors.accent)
        }
        is LyricsLoad.Error -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.player_lyrics_unavailable), style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
                Spacer(Modifier.height(AuralisSpacing.small))
                Text(state.message, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                Spacer(Modifier.height(AuralisSpacing.medium))
                TextButton(onClick = { reloadKey += 1 }) { Text(stringResource(AuralisR.string.retry)) }
            }
        }
        LyricsLoad.None -> EmptyLyricsHint(colors.primaryText, colors.secondaryText)
        is LyricsLoad.Ready -> {
            val doc = state.doc
            val synced = doc.isSynced && doc.lines.all { it.startTimeSeconds != null }
            val activeIndex = if (synced) {
                val sec = positionMs / 1000.0
                val idx = doc.lines.indexOfLast { (it.startTimeSeconds ?: Double.MAX_VALUE) <= sec + 0.05 }
                if (idx < 0) null else idx
            } else {
                null
            }

            // Swift `.scrollPosition(anchor: .center)`：等待一次布局，再把活动行尽量放到视口中心。
            LaunchedEffect(activeIndex, doc.globalId, reduceMotion) {
                val target = activeIndex ?: return@LaunchedEffect
                if (target !in doc.lines.indices) return@LaunchedEffect
                yield()
                val viewportHeight = listState.layoutInfo.viewportSize.height
                val estimatedHalfLine = with(density) { 12.dp.roundToPx() }
                val centerOffset = if (viewportHeight > 0) {
                    -(viewportHeight / 2 - estimatedHalfLine).coerceAtLeast(0)
                } else {
                    0
                }
                if (reduceMotion) {
                    listState.scrollToItem(target, centerOffset)
                } else {
                    listState.animateScrollToItem(target, centerOffset)
                }
            }

            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
                contentPadding = PaddingValues(vertical = AuralisSpacing.huge),
            ) {
                itemsIndexed(doc.lines) { index, line ->
                    val isCurrent = index == activeIndex
                    val lineScale by animateFloatAsState(
                        targetValue = if (isCurrent) 1f else 0.92f,
                        animationSpec = if (reduceMotion) snap() else tween(AuralisMotion.CARD_DURATION_MS),
                        label = "lyric-scale-$index",
                    )
                    val lineAlpha by animateFloatAsState(
                        targetValue = if (isCurrent) 1f else 0.62f,
                        animationSpec = if (reduceMotion) snap() else tween(AuralisMotion.CARD_DURATION_MS),
                        label = "lyric-alpha-$index",
                    )
                    Text(
                        text = line.text,
                        style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
                        color = if (isCurrent) colors.accent else colors.secondaryText,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .widthIn(max = 600.dp)
                            .fillMaxWidth()
                            .padding(horizontal = AuralisSpacing.large)
                            .graphicsLayer {
                                scaleX = lineScale
                                scaleY = lineScale
                                alpha = lineAlpha
                            },
                    )
                }
            }
        }
    }
}

private sealed interface LyricsLoad {
    data object Loading : LyricsLoad
    data object None : LyricsLoad
    data class Ready(val doc: LyricsDocument) : LyricsLoad
    data class Error(val message: String) : LyricsLoad
}

@Composable
private fun EmptyLyricsHint(primary: Color, secondary: Color) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null, tint = secondary, modifier = Modifier.size(36.dp))
            Spacer(Modifier.height(AuralisSpacing.medium))
            Text(stringResource(R.string.player_lyrics_none_title), style = MaterialTheme.typography.titleMedium, color = primary)
            Spacer(Modifier.height(AuralisSpacing.small))
            Text(
                stringResource(R.string.player_lyrics_none_message),
                style = MaterialTheme.typography.bodySmall,
                color = secondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = AuralisSpacing.large),
            )
        }
    }
}

// ================================================================ 队列页

@Composable
private fun QueueContent(
    graph: AuralisGraph,
    queue: QueueSnapshot,
    controller: PlaybackController,
) {
    val colors = LocalAuralisTheme.current.colors
    var editing by rememberSaveable { mutableStateOf(false) }
    val entries = queue.entries
    val scope = rememberCoroutineScope()
    val shape = RoundedCornerShape(AuralisRadius.large)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clip(shape)
            .background(colors.surface.copy(alpha = 0.42f)),
    ) {
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.player_queue_empty), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
            }
            return@Box
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = 38.dp, bottom = AuralisSpacing.small),
        ) {
            itemsIndexed(entries, key = { _, entry -> entry.id.value }) { windowIndex, entry ->
                val isCurrent = queue.currentEntryId == entry.id
                QueueRow(
                    graph = graph,
                    entry = entry,
                    logicalIndex = queue.windowStartLogicalIndex + windowIndex,
                    isCurrent = isCurrent,
                    editing = editing,
                    canMoveUp = queue.windowStartLogicalIndex + windowIndex > 0,
                    canMoveDown = queue.windowStartLogicalIndex + windowIndex < queue.totalCount - 1,
                    onPlay = { scope.launch { controller.playOccurrence(entry.id) } },
                    onRemove = { controller.removeOccurrence(entry.id) },
                    onMove = { targetLogical -> controller.moveOccurrence(entry.id, targetLogical) },
                )
            }
        }

        TextButton(
            onClick = { editing = !editing },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = 4.dp, end = 4.dp)
                .clip(RoundedCornerShape(AuralisRadius.small))
                .background(colors.surface),
        ) {
            Text(
                stringResource(if (editing) AuralisR.string.done else AuralisR.string.edit),
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                color = colors.primaryText,
            )
        }
    }
}

@Composable
private fun QueueRow(
    graph: AuralisGraph,
    entry: QueueEntry,
    logicalIndex: Int,
    isCurrent: Boolean,
    editing: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onPlay: () -> Unit,
    onRemove: () -> Unit,
    onMove: (Int) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val track = entry.track
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !editing, onClick = onPlay)
            .padding(horizontal = AuralisSpacing.medium, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
    ) {
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.albumTitle,
            titleForFallback = track.albumTitle,
            targetSizeDp = AuralisChrome.trackRowArtwork.value.toInt(),
            shape = RoundedCornerShape(AuralisChrome.trackRowArtworkRadius),
            modifier = Modifier.size(AuralisChrome.trackRowArtwork),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                color = if (isCurrent) colors.accent else colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${track.artistName} · ${track.albumTitle}",
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal),
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (!editing) {
            Text(
                formatClock((track.durationSeconds * 1000).toLong()),
                style = MaterialTheme.typography.labelSmall.copy(
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    fontFeatureSettings = "tnum",
                ),
                color = colors.secondaryText,
            )
        } else {
            IconButton(onClick = { if (canMoveUp) onMove(logicalIndex - 1) }, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = stringResource(AuralisR.string.move_up), tint = if (canMoveUp) colors.primaryText else colors.secondaryText.copy(alpha = 0.35f))
            }
            IconButton(onClick = { if (canMoveDown) onMove(logicalIndex + 1) }, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = stringResource(AuralisR.string.move_down), tint = if (canMoveDown) colors.primaryText else colors.secondaryText.copy(alpha = 0.35f))
            }
            IconButton(onClick = onRemove, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.player_remove_from_queue), tint = colors.error)
            }
        }
    }
}

// ================================================================ 固定控制区

@Composable
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
private fun PlaybackControlsArea(
    graph: AuralisGraph,
    controller: PlaybackController,
    playback: PlaybackSnapshot,
    queue: QueueSnapshot,
    track: Track,
    displayMs: Long,
    durationMs: Long,
    dragging: Boolean,
    dragFraction: Float,
    sectionSpacing: Dp,
    playButtonSize: Dp,
    onDragFraction: (Float) -> Unit,
    onDragEnd: () -> Unit,
    onOpenBrowse: (BrowseDestination) -> Unit,
    onTrackAction: PlayerTrackActionHandler?,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val state = playback.state
    val isPlaying = state is PlaybackState.Playing
    val isBusy = state is PlaybackState.Buffering || state is PlaybackState.Stalled || state is PlaybackState.Preparing
    val canPrev = (queue.currentLogicalIndex ?: 0) > 0
    val canNext = queue.totalCount > (queue.currentLogicalIndex ?: -1) + 1
    var favIds by remember { mutableStateOf<Set<GlobalId>?>(null) }
    LaunchedEffect(track.serverId) {
        graph.catalogRepository.observeFavoriteTracks(track.serverId).collect { list ->
            favIds = list.map { it.globalId }.toSet()
        }
    }
    val isFavorite = favIds?.contains(track.globalId) == true
    var dislikedIds by remember { mutableStateOf<Set<GlobalId>?>(null) }
    LaunchedEffect(track.serverId) {
        graph.catalogRepository.observeDislikedIds(track.serverId).collect { ids ->
            dislikedIds = ids.toSet()
        }
    }
    val isDisliked = dislikedIds?.contains(track.globalId) == true
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    var addToPlaylist by remember { mutableStateOf(false) }
    var showInfo by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val download by remember(track.globalId) { graph.catalogRepository.observe(track.globalId) }.collectAsState(initial = null)
    var albumGlobalId by remember { mutableStateOf<GlobalId?>(null) }
    var artistGlobalId by remember { mutableStateOf<GlobalId?>(null) }
    LaunchedEffect(track) {
        albumGlobalId = graph.catalogRepository.album(GlobalId(track.serverId, track.albumId.value))?.globalId
        artistGlobalId = graph.catalogRepository.artist(GlobalId(track.serverId, track.artistId.value))?.globalId
    }

    Column(
        modifier = Modifier
            .widthIn(max = 560.dp)
            .fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(sectionSpacing),
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 56.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xSmall),
            ) {
                AutoMarqueeText(
                    text = track.title,
                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    color = colors.primaryText,
                    modifier = Modifier.fillMaxWidth(),
                )
                AutoMarqueeText(
                    text = track.artistName,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.secondaryText,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = {
                        scope.launch {
                            runCatching { graph.libraryActions.toggleDisliked(track) }
                                .onFailure { message = context.getString(AuralisR.string.action_failed, it.message) }
                        }
                    },
                    modifier = Modifier.size(44.dp),
                ) {
                    Icon(
                        if (isDisliked) Icons.Filled.ThumbDown else Icons.Outlined.ThumbDown,
                        contentDescription = stringResource(if (isDisliked) AuralisR.string.undislike else AuralisR.string.dislike),
                        tint = if (isDisliked) colors.accent else colors.secondaryText,
                        modifier = Modifier.size(24.dp),
                    )
                }
                IconButton(
                    onClick = {
                        scope.launch {
                            runCatching { graph.libraryActions.toggleTrackFavorite(track) }
                                .onFailure { message = context.getString(AuralisR.string.favorite_failed, it.message) }
                        }
                    },
                    modifier = Modifier.size(44.dp),
                ) {
                    Icon(
                        if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                        contentDescription = stringResource(if (isFavorite) AuralisR.string.unfavorite else AuralisR.string.favorite),
                        tint = if (isFavorite) colors.accent else colors.secondaryText,
                        modifier = Modifier.size(24.dp),
                    )
                }
            }
        }

        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xSmall)) {
            Slider(
                value = if (dragging) dragFraction else if (durationMs > 0) (displayMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f,
                onValueChange = onDragFraction,
                onValueChangeFinished = onDragEnd,
                enabled = durationMs > 0,
                colors = SliderDefaults.colors(
                    thumbColor = Color.White,
                    activeTrackColor = colors.accent,
                    inactiveTrackColor = colors.separator.copy(alpha = 0.4f),
                ),
            )
            Row(Modifier.fillMaxWidth()) {
                Text(formatClock(displayMs), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
                Spacer(Modifier.weight(1f))
                Text("-" + formatClock((durationMs - displayMs).coerceAtLeast(0)), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
            }
        }

        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TransportButton(
                weight = 1f,
                enabled = true,
                onClick = { controller.cyclePlayMode() },
                contentDescription = stringResource(R.string.player_play_mode_desc, stringResource(playback.playMode.modeTitleRes())),
            ) {
                Icon(
                    playback.playMode.icon(),
                    contentDescription = null,
                    tint = if (playback.playMode == PlayMode.Sequential) colors.secondaryText else colors.accent,
                    modifier = Modifier.size(24.dp),
                )
            }
            TransportButton(
                weight = 1f,
                enabled = canPrev,
                onClick = { controller.previous() },
                contentDescription = stringResource(AuralisR.string.previous),
            ) {
                Icon(Icons.Filled.SkipPrevious, contentDescription = null, tint = colors.primaryText, modifier = Modifier.size(32.dp))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                if (isBusy) {
                    Box(
                        modifier = Modifier.size(playButtonSize).clip(CircleShape).background(colors.accent),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(playButtonSize * 0.42f),
                            strokeWidth = 3.dp,
                            color = colors.background,
                        )
                    }
                } else {
                    IconButton(
                        onClick = { controller.togglePlayPause() },
                        modifier = Modifier.size(playButtonSize).clip(CircleShape).background(colors.accent),
                    ) {
                        Icon(
                            if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = stringResource(if (isPlaying) AuralisR.string.pause else AuralisR.string.play),
                            tint = colors.background,
                            modifier = Modifier.size(playButtonSize * 0.40f),
                        )
                    }
                }
            }
            TransportButton(
                weight = 1f,
                enabled = canNext,
                onClick = { controller.next() },
                contentDescription = stringResource(AuralisR.string.next),
            ) {
                Icon(Icons.Filled.SkipNext, contentDescription = null, tint = colors.primaryText, modifier = Modifier.size(32.dp))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(44.dp)) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(AuralisR.string.more_actions), tint = colors.primaryText, modifier = Modifier.size(24.dp))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(AuralisR.string.add_to_playlist)) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null) },
                        onClick = { menuOpen = false; addToPlaylist = true },
                    )
                    HorizontalDivider(color = colors.separator)
                    when {
                        download?.status == DownloadStatus.Downloaded -> DropdownMenuItem(
                            text = { Text(stringResource(R.string.player_delete_download)) },
                            leadingIcon = { Icon(Icons.Filled.Delete, null) },
                            onClick = {
                                menuOpen = false
                                graph.downloadManager.deleteCached(track.globalId)
                            },
                        )
                        download?.status == DownloadStatus.Downloading || download?.status == DownloadStatus.Queued -> DropdownMenuItem(
                            text = { Text(stringResource(R.string.player_cancel_download_progress, ((download?.progress ?: 0f) * 100).toInt())) },
                            leadingIcon = { Icon(Icons.Filled.Close, null) },
                            onClick = {
                                menuOpen = false
                                graph.downloadManager.cancelDownloadOnly(track.globalId)
                            },
                        )
                        else -> DropdownMenuItem(
                            text = { Text(stringResource(AuralisR.string.download_to_local)) },
                            leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                            onClick = {
                                menuOpen = false
                                scope.launch {
                                    runCatching { graph.downloadManager.enqueue(track) }
                                        .onFailure { message = context.getString(AuralisR.string.download_failed, it.message) }
                                }
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.player_view_album)) },
                        enabled = albumGlobalId != null,
                        onClick = {
                            menuOpen = false
                            albumGlobalId?.let { onOpenBrowse(BrowseDestination.Album(it)) }
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.player_view_artist)) },
                        enabled = artistGlobalId != null,
                        onClick = {
                            menuOpen = false
                            artistGlobalId?.let { onOpenBrowse(BrowseDestination.Artist(it)) }
                        },
                    )
                    if (onTrackAction != null) {
                        HorizontalDivider(color = colors.separator)
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.player_continue_from_track)) },
                            leadingIcon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, null) },
                            onClick = { menuOpen = false; onTrackAction(track, PlayerTrackAction.PlaySimilar) },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.player_appreciate_song)) },
                            leadingIcon = { Icon(Icons.Filled.GraphicEq, null) },
                            onClick = { menuOpen = false; onTrackAction(track, PlayerTrackAction.Appreciate) },
                        )
                    }
                }
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 420.dp)
                .padding(horizontal = AuralisSpacing.medium),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        ) {
            Icon(Icons.AutoMirrored.Filled.VolumeDown, null, tint = colors.secondaryText, modifier = Modifier.size(18.dp))
            Slider(
                value = playback.volume.coerceIn(0f, 1f),
                onValueChange = { controller.setVolume(it) },
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(
                    thumbColor = Color.White,
                    activeTrackColor = colors.accent,
                    inactiveTrackColor = colors.separator.copy(alpha = 0.4f),
                ),
            )
            Icon(Icons.AutoMirrored.Filled.VolumeUp, null, tint = colors.secondaryText, modifier = Modifier.size(18.dp))
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = { showInfo = !showInfo }) {
                Icon(Icons.Filled.GraphicEq, null, tint = colors.secondaryText, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(AuralisSpacing.xSmall))
                Text(audioTechnicalLabel(context, track, showInfo), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
            }
        }
    }

    if (addToPlaylist) {
        PlayerAddToPlaylistDialog(
            graph = graph,
            track = track,
            onDismiss = { addToPlaylist = false },
            onAdded = { name ->
                addToPlaylist = false
                message = context.getString(AuralisR.string.added_to_playlist, name)
            },
        )
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text(stringResource(AuralisR.string.got_it)) } },
            text = { Text(it) },
        )
    }
}

private fun audioTechnicalLabel(context: Context, track: Track, detail: Boolean): String {
    val info = track.sourceInfo
    val codec = info.normalizedCodec?.uppercase() ?: return context.getString(R.string.player_unknown)
    if (!detail) return codec
    val sampleRate = info.sampleRate?.let { "${it / 1000} kHz" } ?: context.getString(R.string.player_sample_rate_unknown)
    val bitDepth = info.bitDepth
    return if (bitDepth != null) "$bitDepth-bit · $sampleRate" else sampleRate
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TransportButton(
    weight: Float,
    enabled: Boolean,
    onClick: () -> Unit,
    contentDescription: String,
    content: @Composable () -> Unit,
) {
    Box(Modifier.weight(weight), contentAlignment = Alignment.Center) {
        IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(44.dp)) {
            Box(contentAlignment = Alignment.Center) { content() }
        }
    }
}

private fun PlayMode.icon(): ImageVector = when (this) {
    PlayMode.Sequential -> Icons.Filled.FormatListNumbered
    PlayMode.Shuffle -> Icons.Filled.Shuffle
    PlayMode.RepeatAll -> Icons.Filled.Repeat
    PlayMode.RepeatOne -> Icons.Filled.RepeatOne
}

private fun PlayMode.modeTitleRes(): Int = when (this) {
    PlayMode.Sequential -> R.string.player_mode_sequential
    PlayMode.Shuffle -> R.string.player_mode_shuffle
    PlayMode.RepeatAll -> R.string.player_mode_repeat_all
    PlayMode.RepeatOne -> R.string.player_mode_repeat_one
}

// ================================================================ 添加到歌单

@Composable
private fun PlayerAddToPlaylistDialog(
    graph: AuralisGraph,
    track: Track,
    onDismiss: () -> Unit,
    onAdded: (String) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val serverId = track.serverId
    val flow = remember(serverId) { graph.catalogRepository.observePlaylists(serverId) }
    val playlists by flow.collectAsState(initial = emptyList())
    var createMode by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun submit(name: String, action: suspend () -> Unit) {
        scope.launch {
            working = true
            error = null
            runCatching { action() }
                .onSuccess { working = false; onAdded(name) }
                .onFailure {
                    working = false
                    error = context.getString(AuralisR.string.action_failed, it.message)
                }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(stringResource(if (createMode) AuralisR.string.new_playlist_and_add else AuralisR.string.add_to_playlist)) },
        text = {
            Column {
                if (createMode) {
                    OutlinedTextField(
                        value = newName,
                        onValueChange = { newName = it },
                        label = { Text(stringResource(AuralisR.string.playlist_name_label)) },
                        singleLine = true,
                    )
                    Spacer(Modifier.height(AuralisSpacing.small))
                    Text(stringResource(R.string.player_new_playlist_hint, track.title), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                } else {
                    if (playlists.isEmpty()) {
                        Text(stringResource(AuralisR.string.no_playlists_yet), color = colors.secondaryText)
                    }
                    playlists.forEach { playlist ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(enabled = !playlist.isReadOnly && !working) {
                                    submit(playlist.name) {
                                        graph.playlistActions.addTracks(playlist, listOf(track))
                                    }
                                }
                                .padding(vertical = AuralisSpacing.small),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null, tint = colors.accent)
                            Column(Modifier.weight(1f).padding(start = AuralisSpacing.medium)) {
                                Text(
                                    playlist.name,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = if (playlist.isReadOnly) colors.secondaryText else colors.primaryText,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (playlist.isReadOnly) {
                                    Text(stringResource(AuralisR.string.readonly_playlist_hint), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
                                }
                            }
                        }
                    }
                    error?.let { Text(it, color = colors.error, style = MaterialTheme.typography.bodySmall) }
                }
            }
        },
        confirmButton = {
            if (createMode) {
                TextButton(
                    enabled = newName.isNotBlank() && !working,
                    onClick = {
                        val name = newName.trim()
                        submit(name) {
                            graph.playlistActions.createPlaylist(name, serverId, listOf(track.id.value))
                                ?: error(context.getString(AuralisR.string.server_no_new_playlist))
                        }
                    },
                ) { Text(stringResource(if (working) AuralisR.string.creating else AuralisR.string.create_and_add)) }
            } else {
                TextButton(onClick = { createMode = true }) { Text(stringResource(AuralisR.string.new_playlist)) }
            }
        },
        dismissButton = {
            TextButton(onClick = { if (createMode) createMode = false else onDismiss() }) {
                Text(stringResource(if (createMode) AuralisR.string.back else AuralisR.string.cancel))
            }
        },
    )
}
