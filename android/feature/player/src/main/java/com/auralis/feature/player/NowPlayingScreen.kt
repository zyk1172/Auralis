package com.auralis.feature.player

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
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

/**
 * 正在播放全屏页（对齐 Swift `NowPlayingView`，S5）。
 *
 * - 渐变背景 + 顶栏（居中「正在播放」+ 专辑副题，右上关闭）；
 * - 顶部分段（歌词 / 正在播放 / 队列）只切换中部内容区；
 * - **标题·进度·传输区固定在最下方**（切页不跳动）：标题/艺人跑马灯、收藏心形、
 *   可拖动进度条（松手才 seek）、五键传输（模式循环/上一首/播放暂停/下一首/⋯）、音量、音频信息；
 * - 歌词页按真实播放位置高亮并自动滚动，无歌词给空态；
 * - 队列页点行=播放该 occurrence；「编辑」模式可移除/上移/下移（真实 removeOccurrence/moveOccurrence）。
 * 所有动作都是真实调用；播放引擎未就绪时不渲染本页（由 Shell 保证只在播放中打开）。
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
    // 队列被清空/引擎复位时自动退出全屏页（不渲染空壳）。
    LaunchedEffect(track) { if (track == null) onClose() }
    if (track == null) return

    var pageOrdinal by rememberSaveable { mutableStateOf(PlayerTab.Player.ordinal) }
    val page = PlayerTab.entries[pageOrdinal]

    // 拖动中的暂定 seek（Apple Music 行为：拖动只更新显示，松手才 seek）。
    var dragging by remember { mutableStateOf(false) }
    var dragFraction by remember { mutableStateOf(0f) }
    val durationMs = playback.durationMs
    val displayMs = if (dragging) (dragFraction * durationMs).toLong() else tickPosition

    Box(modifier = modifier.fillMaxSize().background(
        Brush.linearGradient(
            listOf(
                colors.accent.copy(alpha = 0.32f),
                colors.background,
                colors.accentSecondary.copy(alpha = 0.16f),
            ),
        ),
    )) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = AuralisSpacing.medium),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // 顶栏：返回下收（Android 模态语义）+ 居中标题 + 关闭。
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = AuralisSpacing.small),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onClose) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "收起正在播放", tint = colors.primaryText)
                }
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("正在播放", style = MaterialTheme.typography.labelMedium, color = colors.primaryText)
                    Text(
                        track.albumTitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.secondaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.size(48.dp))
            }

            // 分段：歌词 / 正在播放 / 队列（对齐 NowPlayingPage）。
            PlayerPageSelector(selected = page, onSelect = { pageOrdinal = it.ordinal })

            // 中部内容区（随页切换；控制区固定在下方不跳）。
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                when (page) {
                    PlayerTab.Lyrics -> LyricsContent(graph, track, positionMs = displayMs)
                    PlayerTab.Player -> HeroContent(track)
                    PlayerTab.Queue -> QueueContent(graph, queue = queue, controller = controller)
                }
            }

            // 固定控制区：标题跑马灯 + 进度 + 传输 + 音量 + 音频信息。
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
                onDragFraction = { dragging = true; dragFraction = it },
                onDragEnd = {
                    if (durationMs > 0) controller.seekTo((dragFraction * durationMs).toLong())
                    dragging = false
                },
                onOpenBrowse = onOpenBrowse,
                onTrackAction = onTrackAction,
            )
            Spacer(Modifier.height(AuralisSpacing.small))
        }
    }
}

// ================================================================ 分段与页面

@Composable
private fun PlayerPageSelector(selected: PlayerTab, onSelect: (PlayerTab) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .widthIn(max = 460.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuralisRadius.large))
            .background(colors.elevated)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        PlayerTab.entries.forEach { tab ->
            val active = tab == selected
            val bg by animateColorAsState(
                targetValue = if (active) colors.accent.copy(alpha = 0.22f) else Color.Transparent,
                label = "tab-bg",
            )
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(AuralisRadius.medium))
                    .background(bg)
                    .clickable { onSelect(tab) }
                    .padding(vertical = AuralisSpacing.small),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    tab.titleZh,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (active) colors.primaryText else colors.secondaryText,
                )
            }
        }
    }
}

@Composable
private fun HeroContent(track: Track) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = minOf(maxWidth * 0.84f, maxHeight * 0.9f, 350.dp)
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.albumTitle,
            titleForFallback = track.albumTitle,
            targetSizeDp = side.value.toInt(),
            shape = RoundedCornerShape(AuralisRadius.large),
            modifier = Modifier
                .size(side)
                .shadow(elevation = 16.dp, shape = RoundedCornerShape(AuralisRadius.large), clip = false),
        )
    }
}

@Composable
private fun LyricsContent(graph: AuralisGraph, track: Track, positionMs: Long) {
    val colors = LocalAuralisTheme.current.colors
    var loadState by remember { mutableStateOf<LyricsLoad>(LyricsLoad.Loading) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(track.globalId, reloadKey) {
        loadState = LyricsLoad.Loading
        runCatching { graph.lyricsService.lyricsFor(track) }
            .onSuccess { doc -> loadState = if (doc == null) LyricsLoad.None else LyricsLoad.Ready(doc) }
            .onFailure { loadState = LyricsLoad.Error("歌词加载失败：${it.message}") }
    }
    val listState = rememberLazyListState()
    when (val state = loadState) {
        LyricsLoad.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = colors.accent)
        }
        is LyricsLoad.Error -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("无法加载歌词", style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
                Spacer(Modifier.height(AuralisSpacing.small))
                Text(state.message, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                Spacer(Modifier.height(AuralisSpacing.medium))
                TextButton(onClick = { reloadKey += 1 }) { Text("重试") }
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
            // 当前行自动滚动到中部（对齐 scrollPosition anchor: .center）。
            LaunchedEffect(activeIndex, doc.globalId) {
                val target = activeIndex
                if (target != null && target >= 0) {
                    val info = listState.layoutInfo
                    if (target < info.totalItemsCount) listState.animateScrollToItem(target.coerceAtLeast(0))
                }
            }
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = AuralisSpacing.large),
            ) {
                itemsIndexed(doc.lines) { index, line ->
                    val isCurrent = index == activeIndex
                    Text(
                        text = line.text,
                        style = MaterialTheme.typography.titleMedium.copy(
                            fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        color = if (isCurrent) colors.accent else colors.secondaryText.copy(alpha = 0.9f),
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = AuralisSpacing.medium, horizontal = AuralisSpacing.large),
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
            Text("暂无歌词", style = MaterialTheme.typography.titleMedium, color = primary)
            Spacer(Modifier.height(AuralisSpacing.small))
            Text(
                "服务器没有返回歌词，可稍后在本地文件或候选源中补全。",
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

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.xSmall),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val windowed = queue.totalCount > entries.size
            Text(
                if (windowed) "队列 ${queue.windowStartLogicalIndex + 1}–${queue.windowStartLogicalIndex + entries.size} / ${queue.totalCount}" else "共 ${queue.totalCount} 首",
                style = MaterialTheme.typography.labelMedium,
                color = colors.secondaryText,
                modifier = Modifier.weight(1f),
            )
            if (entries.isNotEmpty()) {
                TextButton(onClick = { editing = !editing }) {
                    Text(if (editing) "完成" else "编辑")
                }
            }
        }
        if (entries.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text("队列是空的", style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
            }
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize()) {
            itemsIndexed(entries, key = { _, entry -> entry.id.value }) { windowIndex, entry ->
                val track = entry.track
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
                    onMove = { targetLogical ->
                        controller.moveOccurrence(entry.id, targetLogical)
                    },
                )
            }
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
            .padding(horizontal = AuralisSpacing.small, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.albumTitle,
            titleForFallback = track.albumTitle,
            targetSizeDp = 44,
            shape = RoundedCornerShape(AuralisRadius.small),
            modifier = Modifier.size(44.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                color = if (isCurrent) colors.accent else colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${track.artistName} · ${track.albumTitle}",
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (!editing) {
            Text(formatClock((track.durationSeconds * 1000).toLong()), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
            if (isCurrent) {
                Icon(Icons.Filled.GraphicEq, contentDescription = "正在播放", tint = colors.accent, modifier = Modifier.size(16.dp))
            }
        } else {
            IconButton(onClick = { if (canMoveUp) onMove(logicalIndex - 1) }) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "上移", tint = if (canMoveUp) colors.primaryText else colors.secondaryText.copy(alpha = 0.35f))
            }
            IconButton(onClick = { if (canMoveDown) onMove(logicalIndex + 1) }) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "下移", tint = if (canMoveDown) colors.primaryText else colors.secondaryText.copy(alpha = 0.35f))
            }
            IconButton(onClick = onRemove) {
                Icon(Icons.Filled.Delete, contentDescription = "从队列移除", tint = colors.error)
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
    onDragFraction: (Float) -> Unit,
    onDragEnd: () -> Unit,
    onOpenBrowse: (BrowseDestination) -> Unit,
    onTrackAction: PlayerTrackActionHandler?,
) {
    val colors = LocalAuralisTheme.current.colors
    val state = playback.state
    val isPlaying = state is PlaybackState.Playing
    val isBusy = state is PlaybackState.Buffering || state is PlaybackState.Stalled || state is PlaybackState.Preparing
    val canPrev = (queue.currentLogicalIndex ?: 0) > 0
    val canNext = queue.totalCount > (queue.currentLogicalIndex ?: -1) + 1
    // 真实收藏状态（计数信号驱动；可空 = 首帧未就绪，避免闪烁成未收藏）。
    var favIds by remember { mutableStateOf<Set<GlobalId>?>(null) }
    LaunchedEffect(track.serverId) {
        graph.catalogRepository.observeFavoriteTracks(track.serverId).collect { list ->
            favIds = list.map { it.globalId }.toSet()
        }
    }
    val isFavorite = favIds?.contains(track.globalId) == true
    // R4：不喜欢集合（本地状态，Room 表信号驱动；与收藏镜像）。
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
    // 前往专辑/艺术家可用性：真实本地目录里找得到才可用。
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
    ) {
        // 标题 + 不喜欢（左）/ 收藏（右）严格镜像（对齐 Swift：dislike ↔ favorite 两端对称）。
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(
                onClick = {
                    scope.launch {
                        runCatching { graph.libraryActions.toggleDisliked(track) }
                            .onFailure { message = "操作失败：${it.message}" }
                    }
                },
            ) {
                Icon(
                    if (isDisliked) Icons.Filled.ThumbDown else Icons.Outlined.ThumbDown,
                    contentDescription = if (isDisliked) "取消不喜欢" else "不喜欢",
                    tint = if (isDisliked) colors.accent else colors.secondaryText,
                    modifier = Modifier.size(26.dp),
                )
            }
            Column(Modifier.weight(1f)) {
                AutoMarqueeText(
                    text = track.title,
                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    color = colors.primaryText,
                    modifier = Modifier.fillMaxWidth(),
                )
                AutoMarqueeText(
                    text = track.artistName,
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.secondaryText,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            IconButton(
                onClick = {
                    scope.launch {
                        runCatching { graph.libraryActions.toggleTrackFavorite(track) }
                            .onFailure { message = "收藏操作失败：${it.message}" }
                    }
                },
            ) {
                Icon(
                    if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    contentDescription = if (isFavorite) "取消收藏" else "收藏",
                    tint = if (isFavorite) colors.accent else colors.secondaryText,
                    modifier = Modifier.size(26.dp),
                )
            }
        }

        // 进度：拖动只改显示，松手 seek。
        Column(Modifier.fillMaxWidth()) {
            Slider(
                value = if (dragging) dragFraction else if (durationMs > 0) (displayMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f,
                onValueChange = onDragFraction,
                onValueChangeFinished = onDragEnd,
                enabled = durationMs > 0,
                colors = SliderDefaults.colors(
                    thumbColor = colors.accent,
                    activeTrackColor = colors.accent,
                    inactiveTrackColor = colors.separator.copy(alpha = 0.6f),
                ),
            )
            Row(Modifier.fillMaxWidth()) {
                Text(formatClock(displayMs), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
                Spacer(Modifier.weight(1f))
                Text("-" + formatClock((durationMs - displayMs).coerceAtLeast(0)), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
            }
        }
        Spacer(Modifier.height(AuralisSpacing.small))

        // 五键传输区（对齐 Swift transportControls：等宽五键）。
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TransportButton(
                weight = 1f,
                enabled = true,
                onClick = { controller.cyclePlayMode() },
                contentDescription = "播放模式：${playback.playMode.modeTitleZh()}",
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
                contentDescription = "上一首",
            ) {
                Icon(Icons.Filled.SkipPrevious, contentDescription = null, tint = colors.primaryText, modifier = Modifier.size(32.dp))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                if (isBusy) {
                    Box(
                        modifier = Modifier.size(62.dp).clip(CircleShape).background(colors.accent),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(26.dp), strokeWidth = 3.dp, color = colors.background)
                    }
                } else {
                    IconButton(
                        onClick = { controller.togglePlayPause() },
                        modifier = Modifier.size(62.dp).clip(CircleShape).background(colors.accent),
                    ) {
                        Icon(
                            if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (isPlaying) "暂停" else "播放",
                            tint = colors.background,
                            modifier = Modifier.size(34.dp),
                        )
                    }
                }
            }
            TransportButton(
                weight = 1f,
                enabled = canNext,
                onClick = { controller.next() },
                contentDescription = "下一首",
            ) {
                Icon(Icons.Filled.SkipNext, contentDescription = null, tint = colors.primaryText, modifier = Modifier.size(32.dp))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "更多操作", tint = colors.primaryText, modifier = Modifier.size(24.dp))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("添加到歌单") },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null) },
                        onClick = { menuOpen = false; addToPlaylist = true },
                    )
                    HorizontalDivider(color = colors.separator)
                    when {
                        download?.status == DownloadStatus.Downloaded -> DropdownMenuItem(
                            text = { Text("删除下载") },
                            leadingIcon = { Icon(Icons.Filled.Delete, null) },
                            onClick = {
                                menuOpen = false
                                graph.downloadManager.deleteCached(track.globalId)
                            },
                        )
                        download?.status == DownloadStatus.Downloading || download?.status == DownloadStatus.Queued -> DropdownMenuItem(
                            text = { Text("取消下载（${((download?.progress ?: 0f) * 100).toInt()}%）") },
                            leadingIcon = { Icon(Icons.Filled.Close, null) },
                            onClick = {
                                menuOpen = false
                                graph.downloadManager.cancelDownloadOnly(track.globalId)
                            },
                        )
                        else -> DropdownMenuItem(
                            text = { Text("下载到本地") },
                            leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                            onClick = {
                                menuOpen = false
                                scope.launch {
                                    runCatching { graph.downloadManager.enqueue(track) }
                                        .onFailure { message = "下载失败：${it.message}" }
                                }
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("前往专辑") },
                        enabled = albumGlobalId != null,
                        onClick = {
                            menuOpen = false
                            val gid = albumGlobalId
                            if (gid != null) onOpenBrowse(BrowseDestination.Album(gid))
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("前往艺术家") },
                        enabled = artistGlobalId != null,
                        onClick = {
                            menuOpen = false
                            val gid = artistGlobalId
                            if (gid != null) onOpenBrowse(BrowseDestination.Artist(gid))
                        },
                    )
                    // R4（对齐 Swift moreMenu）：由此继续播放 → 相似队列引导会话；
                    // 歌曲鉴赏 → 干净新会话鉴赏。壳层提供 onTrackAction 时才显示（TV 无助理则隐藏）。
                    if (onTrackAction != null) {
                        HorizontalDivider(color = colors.separator)
                        DropdownMenuItem(
                            text = { Text("由此继续播放") },
                            leadingIcon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, null) },
                            onClick = { menuOpen = false; onTrackAction(track, PlayerTrackAction.PlaySimilar) },
                        )
                        DropdownMenuItem(
                            text = { Text("歌曲鉴赏") },
                            leadingIcon = { Icon(Icons.Filled.GraphicEq, null) },
                            onClick = { menuOpen = false; onTrackAction(track, PlayerTrackAction.Appreciate) },
                        )
                    }
                }
            }
        }

        // 音量（真实 setVolume）。
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 420.dp)
                .padding(horizontal = AuralisSpacing.medium),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
        ) {
            Icon(Icons.AutoMirrored.Filled.VolumeDown, null, tint = colors.secondaryText, modifier = Modifier.size(18.dp))
            Slider(
                value = playback.volume.coerceIn(0f, 1f),
                onValueChange = { controller.setVolume(it) },
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(
                    thumbColor = colors.accent,
                    activeTrackColor = colors.accent,
                    inactiveTrackColor = colors.separator.copy(alpha = 0.6f),
                ),
            )
            Icon(Icons.AutoMirrored.Filled.VolumeUp, null, tint = colors.secondaryText, modifier = Modifier.size(18.dp))
        }

        // 底部：音频信息（点击切换 codec / 采样率详情）。输出设备选择（AirPlay）Android 无对应。
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = { showInfo = !showInfo }) {
                Icon(Icons.Filled.GraphicEq, null, tint = colors.secondaryText, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(AuralisSpacing.xSmall))
                Text(audioTechnicalLabel(track, showInfo), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
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
                message = "已加入歌单「$name」"
            },
        )
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text("知道了") } },
            text = { Text(it) },
        )
    }
}

private fun audioTechnicalLabel(track: Track, detail: Boolean): String {
    val info = track.sourceInfo
    val codec = info.normalizedCodec?.uppercase() ?: return "未知"
    if (!detail) return codec
    val sampleRate = info.sampleRate?.let { "${it / 1000} kHz" } ?: "采样率未知"
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
        IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(48.dp)) {
            Box(contentAlignment = Alignment.Center) {
                content()
            }
        }
    }
}

private fun PlayMode.icon(): ImageVector = when (this) {
    PlayMode.Sequential -> Icons.Filled.FormatListNumbered
    PlayMode.Shuffle -> Icons.Filled.Shuffle
    PlayMode.RepeatAll -> Icons.Filled.Repeat
    PlayMode.RepeatOne -> Icons.Filled.RepeatOne
}

private fun PlayMode.modeTitleZh(): String = when (this) {
    PlayMode.Sequential -> "顺序"
    PlayMode.Shuffle -> "随机"
    PlayMode.RepeatAll -> "列表循环"
    PlayMode.RepeatOne -> "单曲循环"
}

// ================================================================ 添加到歌单

/** 正在播放页「添加到歌单」（对齐 Swift AddToPlaylistSheet）：选已有或新建，真实远端先行。 */
@Composable
private fun PlayerAddToPlaylistDialog(
    graph: AuralisGraph,
    track: Track,
    onDismiss: () -> Unit,
    onAdded: (String) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
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
                    error = "操作失败：${it.message}"
                }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(if (createMode) "新建歌单并加入" else "添加到歌单") },
        text = {
            Column {
                if (createMode) {
                    OutlinedTextField(
                        value = newName,
                        onValueChange = { newName = it },
                        label = { Text("歌单名称") },
                        singleLine = true,
                    )
                    Spacer(Modifier.height(AuralisSpacing.small))
                    Text("《${track.title}》将加入新歌单。", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                } else {
                    if (playlists.isEmpty()) {
                        Text("还没有歌单，可以先新建一个。", color = colors.secondaryText)
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
                                    Text("只读歌单，不能添加", style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
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
                            val created = graph.playlistActions.createPlaylist(name, serverId, listOf(track.id.value))
                                ?: error("服务器未返回新歌单")
                        }
                    },
                ) { Text(if (working) "创建中…" else "创建并加入") }
            } else {
                TextButton(onClick = { createMode = true }) { Text("新建歌单") }
            }
        },
        dismissButton = {
            TextButton(onClick = { if (createMode) createMode = false else onDismiss() }) {
                Text(if (createMode) "返回" else "取消")
            }
        },
    )
}
