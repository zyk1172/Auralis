// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import android.os.SystemClock
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
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
import androidx.compose.material.icons.filled.FormatQuote
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
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
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.PlaybackSnapshot
import com.auralis.core.playback.QueueSnapshot
import kotlin.math.abs
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * 正在播放全屏页（对齐 Swift `NowPlayingView`，S5/R10）。
 * - 使用与 iOS 相同的 42% accent / background / 22% secondary-accent 环境渐变；
 * - 按窗口实际宽高采用竖屏布局或左封面/右控件的横屏双栏；
 * - 顶部下收手柄和底部歌词/队列切换对齐最新 iOS 全屏播放页；
 * - 紧凑窗口收紧控制区，宽高充足时采用更舒展的间距与 64dp 主播放键；
 * - Hero 使用独立 `NowPlayingArtworkGlow`，真实封面作为环境光源并支持播放态低速呼吸；
 * - 标题、歌词、队列、ThinSlider 和更多菜单均以 Swift 当前实现为产品规格。
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

    val pagerState =
        rememberPagerState(initialPage = PlayerTab.Player.ordinal) { PlayerTab.entries.size }
    val page = PlayerTab.entries[pagerState.currentPage]
    val scope = rememberCoroutineScope()
    var chromeHidden by remember { mutableStateOf(false) }
    var lyricsActivity by remember { mutableStateOf(0) }
    var dragging by remember(track.globalId) { mutableStateOf(false) }
    fun registerActivity() {
        chromeHidden = false
        lyricsActivity++
    }
    LaunchedEffect(page, track.globalId, lyricsActivity, dragging) {
        chromeHidden = false
        if (page == PlayerTab.Lyrics && !dragging) {
            delay(NowPlayingUiPolicy.lyricsAutoHideDelayMs)
            chromeHidden = true
        }
    }

    var dragFraction by remember(track.globalId) { mutableStateOf(0f) }
    val durationMs = playback.durationMs
    val displayMs = if (dragging) (dragFraction * durationMs).toLong() else tickPosition
    val immersive = page == PlayerTab.Lyrics && chromeHidden
    val density = LocalDensity.current
    val thresholdPx = with(density) { 44.dp.toPx() }
    val activityModifier =
        Modifier.pointerInput(page, thresholdPx) {
            if (page != PlayerTab.Lyrics) return@pointerInput
            // Observe after child controls without consuming their events. Taps, scrolling,
            // sliders and horizontal paging keep their native gesture handling.
            awaitEachGesture {
                val down =
                    awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                var last = down.position
                do {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                    last = change.position
                } while (event.changes.any { it.pressed })
                val travel = last - down.position
                when {
                    abs(travel.y) >= thresholdPx && abs(travel.y) > abs(travel.x) -> {
                        if (travel.y < 0) chromeHidden = true else registerActivity()
                    }
                    abs(travel.x) < thresholdPx -> registerActivity()
                }
            }
        }

    Box(
        modifier =
            modifier
                .fillMaxSize()
                .background(
                    Brush.linearGradient(
                        listOf(
                            colors.accent.copy(alpha = 0.42f),
                            colors.background,
                            colors.accentSecondary.copy(alpha = 0.22f),
                        )
                    )
                )
    ) {
        NowPlayingChromeLayout(
            page = page,
            chromeHidden = immersive,
            onClose = onClose,
            artwork = { side -> HeroContent(track, playback.state is PlaybackState.Playing, side) },
            pageContent = { landscape ->
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize().then(activityModifier),
                ) { index ->
                    when (PlayerTab.entries[index]) {
                        PlayerTab.Lyrics ->
                            LyricsContent(
                                graph,
                                track,
                                positionMs = displayMs,
                                isPlaying = playback.state is PlaybackState.Playing,
                            )
                        PlayerTab.Player ->
                            if (!landscape)
                                HeroContent(track, playback.state is PlaybackState.Playing)
                            else Spacer(Modifier.fillMaxSize())
                        PlayerTab.Queue -> QueueContent(queue, controller)
                    }
                }
            },
            controls = { sectionSpacing, playButtonSize ->
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
                    onDragFraction = {
                        dragging = true
                        dragFraction = it
                        registerActivity()
                    },
                    onDragEnd = {
                        if (durationMs > 0) controller.seekTo((dragFraction * durationMs).toLong())
                        dragging = false
                        registerActivity()
                    },
                    onOpenBrowse = onOpenBrowse,
                    onTrackAction = onTrackAction,
                    chromeHidden = immersive,
                    bottomNavigation = {
                        PlayerBottomNavigation(page) { target ->
                            registerActivity()
                            scope.launch {
                                pagerState.animateScrollToPage(
                                    NowPlayingUiPolicy.togglePage(page, target).ordinal
                                )
                            }
                        }
                    },
                    modifier = activityModifier,
                )
            },
        )
    }
}

/** Geometry comes from this window, including split-screen and rotation. */
@Composable
internal fun NowPlayingChromeLayout(
    page: PlayerTab,
    chromeHidden: Boolean,
    onClose: () -> Unit,
    artwork: @Composable (Dp) -> Unit,
    pageContent: @Composable (Boolean) -> Unit,
    controls: @Composable (Dp, Dp) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val dismissDescription = stringResource(R.string.player_dismiss_now_playing)
    val latestClose by rememberUpdatedState(onClose)
    val reduceMotion = LocalReduceMotion.current
    BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        val landscape = NowPlayingUiPolicy.usesLandscape(maxWidth.value, maxHeight.value)
        val landscapeSide =
            NowPlayingUiPolicy.landscapeArtworkSide(
                    maxWidth.value,
                    maxHeight.value,
                    isTablet = minOf(maxWidth, maxHeight) >= 600.dp,
                )
                .dp
        val compactLandscape = landscape && maxHeight < 460.dp
        val compactPortrait = maxHeight < 700.dp || (maxWidth >= 600.dp && maxWidth < 620.dp)
        Column(
            Modifier.align(Alignment.TopCenter)
                .widthIn(max = if (landscape) Dp.Unspecified else 900.dp)
                .fillMaxSize()
                .padding(horizontal = if (landscape) 16.dp else AuralisSpacing.large)
                .padding(top = 2.dp, bottom = if (compactLandscape) 6.dp else AuralisSpacing.large),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement =
                Arrangement.spacedBy(if (landscape) 2.dp else AuralisSpacing.medium),
        ) {
            AnimatedVisibility(
                visible = !chromeHidden,
                enter = fadeIn(tween(if (reduceMotion) 160 else 420)),
                exit = fadeOut(tween(if (reduceMotion) 160 else 420)),
            ) {
                var drag by remember { mutableStateOf(0f) }
                val density = LocalDensity.current
                IconButton(
                    onClick = onClose,
                    modifier =
                        Modifier.size(44.dp)
                            .testTag("player.dismiss")
                            .semantics { contentDescription = dismissDescription }
                            .pointerInput(density) {
                                detectVerticalDragGestures(
                                    onDragStart = { drag = 0f },
                                    onDragEnd = {
                                        if (drag >= with(density) { 44.dp.toPx() }) latestClose()
                                    },
                                ) { _, delta ->
                                    drag += delta
                                }
                            },
                ) {
                    Box(
                        Modifier.size(width = 44.dp, height = 5.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(colors.secondaryText.copy(alpha = 0.36f))
                    )
                }
            }
            if (landscape) {
                val side = landscapeSide
                Row(
                    Modifier.weight(1f).fillMaxWidth().testTag("player.landscape"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    Box(Modifier.size(side).testTag("player.artwork")) { artwork(side) }
                    Column(
                        Modifier.weight(1f).fillMaxHeight().widthIn(max = 600.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // The landscape player keeps artwork on the left. Lyrics/queue
                        // occupy the right column; the artwork page needs only controls.
                        Box(Modifier.weight(1f).fillMaxWidth()) { pageContent(true) }
                        controls(
                            if (compactLandscape) 10.dp else 15.dp,
                            if (compactLandscape) 48.dp else 56.dp,
                        )
                        if (page == PlayerTab.Player) Spacer(Modifier.weight(1f))
                    }
                }
            } else {
                Column(
                    Modifier.weight(1f).fillMaxWidth().testTag("player.portrait"),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(
                        Modifier.weight(1f)
                            .fillMaxWidth()
                            .padding(horizontal = AuralisSpacing.medium)
                    ) {
                        pageContent(false)
                    }
                    Box(Modifier.padding(horizontal = AuralisSpacing.medium)) {
                        controls(
                            if (compactPortrait) 14.dp else 20.dp,
                            if (compactPortrait) 56.dp else 64.dp,
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun PlayerBottomNavigation(page: PlayerTab, onSelect: (PlayerTab) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        for (tab in listOf(PlayerTab.Lyrics, PlayerTab.Queue)) {
            val active = page == tab
            val description =
                stringResource(
                    if (active) R.string.player_page_open else R.string.player_page_closed
                )
            IconButton(
                onClick = { onSelect(tab) },
                modifier =
                    Modifier.size(44.dp).testTag("player.${tab.name.lowercase()}").semantics {
                        selected = active
                        stateDescription = description
                    },
            ) {
                Icon(
                    if (tab == PlayerTab.Lyrics) Icons.Filled.FormatQuote
                    else Icons.AutoMirrored.Filled.QueueMusic,
                    stringResource(tab.titleRes),
                    tint = if (active) colors.accent else colors.secondaryText,
                )
            }
            if (tab == PlayerTab.Lyrics) {
                AndroidView(
                    factory = { context ->
                        android.app.MediaRouteButton(context).apply {
                            setRouteTypes(android.media.MediaRouter.ROUTE_TYPE_LIVE_AUDIO)
                            contentDescription = context.getString(R.string.player_audio_output)
                        }
                    },
                    modifier = Modifier.size(44.dp).testTag("player.audioOutput"),
                )
            }
        }
    }
}

// ================================================================ 分段与页面

@Composable
private fun HeroContent(track: Track, isPlaying: Boolean, artworkSide: Dp? = null) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side =
            artworkSide
                ?: minOf(
                    maxWidth * 0.84f,
                    maxHeight * 0.88f,
                    if (maxWidth >= 600.dp) minOf(460.dp, maxOf(350.dp, maxWidth * 0.58f))
                    else 350.dp,
                )
        val reduceMotion = LocalReduceMotion.current
        val artworkScale by
            animateFloatAsState(
                targetValue = NowPlayingUiPolicy.artworkScale(isPlaying),
                animationSpec = if (reduceMotion) snap() else tween(420),
                label = "player-artwork-scale",
            )
        val maxGlowCanvas = minOf(maxWidth, maxHeight)
        val shape = RoundedCornerShape(AuralisRadius.large)

        Box(
            Modifier.size(side).graphicsLayer {
                scaleX = artworkScale
                scaleY = artworkScale
            },
            contentAlignment = Alignment.Center,
        ) {
            NowPlayingArtworkGlow(
                track = track,
                artworkSize = side,
                maxCanvasSize = maxGlowCanvas,
                isPlaying = isPlaying,
            )
            AuralisArtwork(
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                contentDescription = track.albumTitle,
                titleForFallback = track.albumTitle,
                targetSizeDp = side.value.toInt(),
                shape = shape,
                modifier =
                    Modifier.size(side)
                        .shadow(
                            elevation = if (isPlaying) 14.dp else 9.dp,
                            shape = shape,
                            clip = false,
                        ),
            )
        }
    }
}

@Composable
private fun LyricsContent(graph: AuralisGraph, track: Track, positionMs: Long, isPlaying: Boolean) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val reduceMotion = LocalReduceMotion.current
    val density = LocalDensity.current
    var loadState by remember { mutableStateOf<LyricsLoad>(LyricsLoad.Loading) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(track.globalId, reloadKey) {
        loadState = LyricsLoad.Loading
        runCatching { graph.lyricsService.lyricsFor(track) }
            .onSuccess { doc ->
                loadState = if (doc == null) LyricsLoad.None else LyricsLoad.Ready(doc)
            }
            .onFailure {
                loadState =
                    LyricsLoad.Error(
                        context.getString(R.string.player_lyrics_load_failed, it.message)
                    )
            }
    }
    val listState = rememberLazyListState()
    when (val state = loadState) {
        LyricsLoad.Loading ->
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }
        is LyricsLoad.Error ->
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        stringResource(R.string.player_lyrics_unavailable),
                        style = MaterialTheme.typography.titleMedium,
                        color = colors.primaryText,
                    )
                    Spacer(Modifier.height(AuralisSpacing.small))
                    Text(
                        state.message,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.secondaryText,
                    )
                    Spacer(Modifier.height(AuralisSpacing.medium))
                    TextButton(onClick = { reloadKey += 1 }) {
                        Text(stringResource(AuralisR.string.retry))
                    }
                }
            }
        LyricsLoad.None -> EmptyLyricsHint(colors.primaryText, colors.secondaryText)
        is LyricsLoad.Ready -> {
            val doc = state.doc
            val synced = doc.isSynced && doc.lines.all { it.startTimeSeconds != null }
            val activeIndex =
                if (synced) {
                    val sec = positionMs / 1000.0
                    val idx =
                        doc.lines.indexOfLast {
                            (it.startTimeSeconds ?: Double.MAX_VALUE) <= sec + 0.05
                        }
                    if (idx < 0) null else idx
                } else {
                    null
                }

            LaunchedEffect(activeIndex, doc.globalId, reduceMotion) {
                val target = activeIndex ?: return@LaunchedEffect
                if (target !in doc.lines.indices) return@LaunchedEffect
                yield()
                val viewportHeight = listState.layoutInfo.viewportSize.height
                val estimatedHalfLine = with(density) { 12.dp.roundToPx() }
                val centerOffset =
                    if (viewportHeight > 0) {
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
                    AnimatedLyricLine(
                        text = line.text,
                        isCurrent = isCurrent,
                        isPlaying = isPlaying,
                        positionMs = positionMs,
                        start = line.startTimeSeconds,
                        nextStart =
                            doc.lines.drop(index + 1).firstNotNullOfOrNull { it.startTimeSeconds },
                    )
                }
            }
        }
    }
}

/** Only the active line owns a 30fps clock; playback publications stay unchanged. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun AnimatedLyricLine(
    text: String,
    isCurrent: Boolean,
    isPlaying: Boolean,
    positionMs: Long,
    start: Double?,
    nextStart: Double?,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val anchor = remember(positionMs) { positionMs to SystemClock.uptimeMillis() }
    val latestAnchor by rememberUpdatedState(anchor)
    var now by remember { mutableStateOf(SystemClock.uptimeMillis()) }
    LaunchedEffect(isCurrent, isPlaying, reduceMotion, start, nextStart) {
        if (isCurrent && isPlaying && !reduceMotion && start != null && nextStart != null) {
            while (true) {
                now = SystemClock.uptimeMillis()
                delay(33)
            }
        }
    }
    val position =
        if (isPlaying) latestAnchor.first + (now - latestAnchor.second).coerceAtLeast(0)
        else positionMs
    val progress = NowPlayingUiPolicy.lineProgress(position / 1000.0, start, nextStart)
    val characters =
        remember(text) {
            val iterator = android.icu.text.BreakIterator.getCharacterInstance()
            iterator.setText(text)
            buildList {
                var begin = iterator.first()
                var end = iterator.next()
                while (end != android.icu.text.BreakIterator.DONE) {
                    add(text.substring(begin, end))
                    begin = end
                    end = iterator.next()
                }
            }
        }
    if (isCurrent && !reduceMotion && progress != null) {
        val count = characters.count { it.isNotBlank() }
        var ordinal = 0
        FlowRow(
            modifier =
                Modifier.widthIn(max = 600.dp)
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large)
                    .semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.Center,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            characters.forEach { character ->
                val scale =
                    if (character.isBlank()) 1f
                    else NowPlayingUiPolicy.characterScale(ordinal++, count, progress)
                Text(
                    character,
                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    color = colors.accent,
                    modifier =
                        Modifier.graphicsLayer {
                            scaleX = scale
                            scaleY = scale
                        },
                )
            }
        }
    } else {
        val scale = if (isCurrent && !reduceMotion) 1.06f else 1f
        Text(
            text,
            style =
                MaterialTheme.typography.titleLarge.copy(
                    fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.SemiBold
                ),
            color = if (isCurrent) colors.accent else colors.secondaryText,
            textAlign = TextAlign.Center,
            modifier =
                Modifier.widthIn(max = 600.dp)
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large)
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        alpha = if (isCurrent) 1f else 0.62f
                    },
        )
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
            Icon(
                Icons.AutoMirrored.Filled.QueueMusic,
                contentDescription = null,
                tint = secondary,
                modifier = Modifier.size(36.dp),
            )
            Spacer(Modifier.height(AuralisSpacing.medium))
            Text(
                stringResource(R.string.player_lyrics_none_title),
                style = MaterialTheme.typography.titleMedium,
                color = primary,
            )
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
private fun QueueContent(queue: QueueSnapshot, controller: PlaybackController) {
    val colors = LocalAuralisTheme.current.colors
    var editing by rememberSaveable { mutableStateOf(false) }
    val entries = queue.entries
    val scope = rememberCoroutineScope()
    val shape = RoundedCornerShape(AuralisRadius.large)

    Box(
        modifier = Modifier.fillMaxSize().clip(shape).background(colors.surface.copy(alpha = 0.42f))
    ) {
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    stringResource(R.string.player_queue_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.secondaryText,
                )
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
                    entry = entry,
                    logicalIndex = queue.windowStartLogicalIndex + windowIndex,
                    isCurrent = isCurrent,
                    editing = editing,
                    canMoveUp = queue.windowStartLogicalIndex + windowIndex > 0,
                    canMoveDown =
                        queue.windowStartLogicalIndex + windowIndex < queue.totalCount - 1,
                    onPlay = { scope.launch { controller.playOccurrence(entry.id) } },
                    onRemove = { controller.removeOccurrence(entry.id) },
                    onMove = { targetLogical -> controller.moveOccurrence(entry.id, targetLogical) },
                )
            }
        }

        TextButton(
            onClick = { editing = !editing },
            modifier =
                Modifier.align(Alignment.TopEnd)
                    .padding(top = 4.dp, end = 4.dp)
                    .clip(RoundedCornerShape(AuralisRadius.small))
                    .background(colors.surface),
        ) {
            Text(
                stringResource(if (editing) AuralisR.string.done else AuralisR.string.edit),
                style =
                    MaterialTheme.typography.labelSmall.copy(
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    ),
                color = colors.primaryText,
            )
        }
    }
}

@Composable
private fun QueueRow(
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
        modifier =
            Modifier.fillMaxWidth()
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
                style =
                    MaterialTheme.typography.labelSmall.copy(
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                        fontWeight = FontWeight.Normal,
                    ),
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (!editing) {
            Text(
                formatClock((track.durationSeconds * 1000).toLong()),
                style =
                    MaterialTheme.typography.labelSmall.copy(
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                        fontFeatureSettings = "tnum",
                    ),
                color = colors.secondaryText,
            )
        } else {
            IconButton(
                onClick = { if (canMoveUp) onMove(logicalIndex - 1) },
                modifier = Modifier.size(44.dp),
            ) {
                Icon(
                    Icons.Filled.KeyboardArrowUp,
                    contentDescription = stringResource(AuralisR.string.move_up),
                    tint =
                        if (canMoveUp) colors.primaryText
                        else colors.secondaryText.copy(alpha = 0.35f),
                )
            }
            IconButton(
                onClick = { if (canMoveDown) onMove(logicalIndex + 1) },
                modifier = Modifier.size(44.dp),
            ) {
                Icon(
                    Icons.Filled.KeyboardArrowDown,
                    contentDescription = stringResource(AuralisR.string.move_down),
                    tint =
                        if (canMoveDown) colors.primaryText
                        else colors.secondaryText.copy(alpha = 0.35f),
                )
            }
            IconButton(onClick = onRemove, modifier = Modifier.size(44.dp)) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = stringResource(R.string.player_remove_from_queue),
                    tint = colors.error,
                )
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
    chromeHidden: Boolean = false,
    bottomNavigation: @Composable () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val state = playback.state
    val isPlaying = state is PlaybackState.Playing
    val isBusy =
        state is PlaybackState.Buffering ||
            state is PlaybackState.Stalled ||
            state is PlaybackState.Preparing
    val canPrev = com.auralis.core.playback.PlaybackCapabilities.canGoPrevious(playback, queue)
    val canNext = com.auralis.core.playback.PlaybackCapabilities.canGoNext(playback, queue)
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
    var showTrackInfo by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val download by
        remember(track.globalId) { graph.catalogRepository.observe(track.globalId) }
            .collectAsState(initial = null)
    var albumGlobalId by remember { mutableStateOf<GlobalId?>(null) }
    var artistGlobalId by remember { mutableStateOf<GlobalId?>(null) }
    LaunchedEffect(track) {
        albumGlobalId =
            graph.catalogRepository.album(GlobalId(track.serverId, track.albumId.value))?.globalId
        artistGlobalId =
            graph.catalogRepository.artist(GlobalId(track.serverId, track.artistId.value))?.globalId
    }

    Column(
        modifier = modifier.widthIn(max = 560.dp).fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(sectionSpacing),
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier =
                    Modifier.fillMaxWidth()
                        .padding(horizontal = 56.dp)
                        .testTag("player.trackIdentity")
                        .semantics(mergeDescendants = true) {},
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
            if (!chromeHidden)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = {
                            scope.launch {
                                runCatching { graph.libraryActions.toggleDisliked(track) }
                                    .onFailure {
                                        message =
                                            context.getString(
                                                AuralisR.string.action_failed,
                                                it.message,
                                            )
                                    }
                            }
                        },
                        modifier = Modifier.size(44.dp),
                    ) {
                        DislikeIcon(
                            active = isDisliked,
                            tint = if (isDisliked) colors.accent else colors.secondaryText,
                        )
                    }
                    IconButton(
                        onClick = {
                            scope.launch {
                                runCatching { graph.libraryActions.toggleTrackFavorite(track) }
                                    .onFailure {
                                        message =
                                            context.getString(
                                                AuralisR.string.favorite_failed,
                                                it.message,
                                            )
                                    }
                            }
                        },
                        modifier = Modifier.size(44.dp),
                    ) {
                        Icon(
                            if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                            contentDescription =
                                stringResource(
                                    if (isFavorite) AuralisR.string.unfavorite
                                    else AuralisR.string.favorite
                                ),
                            tint = if (isFavorite) colors.accent else colors.secondaryText,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
        }

        AnimatedVisibility(
            visible = !chromeHidden,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(sectionSpacing),
            ) {
                Column(
                    Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xSmall),
                ) {
                    val progress =
                        if (dragging) {
                            dragFraction
                        } else if (durationMs > 0) {
                            (displayMs.toFloat() / durationMs).coerceIn(0f, 1f)
                        } else {
                            0f
                        }
                    AuralisThinSlider(
                        value = progress,
                        accent = colors.accent,
                        track = colors.separator.copy(alpha = 0.4f),
                        enabled = durationMs > 0,
                        onEditingChanged = { editing -> if (!editing) onDragEnd() },
                        onValueChanged = onDragFraction,
                    )
                    Row(Modifier.fillMaxWidth()) {
                        Text(
                            formatClock(displayMs),
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.secondaryText,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            "-" + formatClock((durationMs - displayMs).coerceAtLeast(0)),
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.secondaryText,
                        )
                    }
                }

                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    TransportButton(
                        weight = 1f,
                        enabled = true,
                        onClick = { controller.cyclePlayMode() },
                        contentDescription =
                            stringResource(
                                R.string.player_play_mode_desc,
                                stringResource(playback.playMode.modeTitleRes()),
                            ),
                        tag = "player.playMode",
                    ) {
                        Icon(
                            playback.playMode.icon(),
                            contentDescription = null,
                            tint =
                                if (playback.playMode == PlayMode.Sequential) colors.secondaryText
                                else colors.accent,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                    TransportButton(
                        weight = 1f,
                        enabled = canPrev,
                        onClick = { controller.previous() },
                        contentDescription = stringResource(AuralisR.string.previous),
                        tag = "player.previous",
                    ) {
                        Icon(
                            Icons.Filled.SkipPrevious,
                            contentDescription = null,
                            tint = colors.primaryText,
                            modifier = Modifier.size(32.dp),
                        )
                    }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        if (isBusy) {
                            Box(
                                modifier =
                                    Modifier.size(playButtonSize)
                                        .clip(CircleShape)
                                        .background(colors.accent)
                                        .testTag("player.playPause"),
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
                                modifier =
                                    Modifier.size(playButtonSize)
                                        .clip(CircleShape)
                                        .background(colors.accent)
                                        .testTag("player.playPause"),
                            ) {
                                Icon(
                                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                    contentDescription =
                                        stringResource(
                                            if (isPlaying) AuralisR.string.pause
                                            else AuralisR.string.play
                                        ),
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
                        tag = "player.next",
                    ) {
                        Icon(
                            Icons.Filled.SkipNext,
                            contentDescription = null,
                            tint = colors.primaryText,
                            modifier = Modifier.size(32.dp),
                        )
                    }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(44.dp)) {
                            Icon(
                                Icons.Filled.MoreVert,
                                contentDescription = stringResource(AuralisR.string.more_actions),
                                tint = colors.primaryText,
                                modifier = Modifier.size(24.dp),
                            )
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(AuralisR.string.add_to_playlist)) },
                                leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null) },
                                onClick = {
                                    menuOpen = false
                                    addToPlaylist = true
                                },
                            )
                            HorizontalDivider(color = colors.separator)
                            when {
                                download?.status == DownloadStatus.Downloaded ->
                                    DropdownMenuItem(
                                        text = {
                                            Text(stringResource(R.string.player_delete_download))
                                        },
                                        leadingIcon = { Icon(Icons.Filled.Delete, null) },
                                        onClick = {
                                            menuOpen = false
                                            graph.downloadManager.deleteCached(track.globalId)
                                        },
                                    )
                                download?.status == DownloadStatus.Downloading ||
                                    download?.status == DownloadStatus.Queued ->
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                stringResource(
                                                    R.string.player_cancel_download_progress,
                                                    ((download?.progress ?: 0f) * 100).toInt(),
                                                )
                                            )
                                        },
                                        leadingIcon = { Icon(Icons.Filled.Close, null) },
                                        onClick = {
                                            menuOpen = false
                                            graph.downloadManager.cancelDownloadOnly(track.globalId)
                                        },
                                    )
                                else ->
                                    DropdownMenuItem(
                                        text = {
                                            Text(stringResource(AuralisR.string.download_to_local))
                                        },
                                        leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                                        onClick = {
                                            menuOpen = false
                                            scope.launch {
                                                runCatching { graph.downloadManager.enqueue(track) }
                                                    .onFailure {
                                                        message =
                                                            context.getString(
                                                                AuralisR.string.download_failed,
                                                                it.message,
                                                            )
                                                    }
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
                                    artistGlobalId?.let {
                                        onOpenBrowse(BrowseDestination.Artist(it))
                                    }
                                },
                            )
                            if (onTrackAction != null) {
                                DropdownMenuItem(
                                    text = {
                                        Text(stringResource(R.string.player_continue_from_track))
                                    },
                                    leadingIcon = {
                                        Icon(Icons.AutoMirrored.Filled.QueueMusic, null)
                                    },
                                    onClick = {
                                        menuOpen = false
                                        onTrackAction(track, PlayerTrackAction.PlaySimilar)
                                    },
                                )
                                DropdownMenuItem(
                                    text = {
                                        Text(stringResource(R.string.player_appreciate_song))
                                    },
                                    leadingIcon = { Icon(Icons.Filled.GraphicEq, null) },
                                    onClick = {
                                        menuOpen = false
                                        onTrackAction(track, PlayerTrackAction.Appreciate)
                                    },
                                )
                            }
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.player_track_info_menu)) },
                                leadingIcon = { Icon(Icons.Filled.GraphicEq, null) },
                                onClick = {
                                    menuOpen = false
                                    showTrackInfo = true
                                },
                            )
                        }
                    }
                }

                Row(
                    modifier =
                        Modifier.fillMaxWidth()
                            .widthIn(max = 420.dp)
                            .padding(horizontal = AuralisSpacing.medium),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.VolumeDown,
                        null,
                        tint = colors.secondaryText,
                        modifier = Modifier.size(18.dp),
                    )
                    AuralisThinSlider(
                        value = playback.volume.coerceIn(0f, 1f),
                        accent = colors.accent,
                        track = colors.separator.copy(alpha = 0.4f),
                        onEditingChanged = {},
                        onValueChanged = controller::setVolume,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        Icons.AutoMirrored.Filled.VolumeUp,
                        null,
                        tint = colors.secondaryText,
                        modifier = Modifier.size(18.dp),
                    )
                }

                bottomNavigation()
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
    if (showTrackInfo) {
        TrackInformationDialog(graph = graph, track = track, onDismiss = { showTrackInfo = false })
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = {
                TextButton(onClick = { message = null }) {
                    Text(stringResource(AuralisR.string.got_it))
                }
            },
            text = { Text(it) },
        )
    }
}

@Composable
private fun DislikeIcon(active: Boolean, tint: Color) {
    Box(modifier = Modifier.size(24.dp), contentAlignment = Alignment.Center) {
        Icon(
            if (active) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(22.dp),
        )
        Canvas(Modifier.fillMaxSize()) {
            val inset = size.minDimension * 0.16f
            drawLine(
                color = tint,
                start = Offset(inset, size.height - inset),
                end = Offset(size.width - inset, inset),
                strokeWidth = 2.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TransportButton(
    weight: Float,
    enabled: Boolean,
    onClick: () -> Unit,
    contentDescription: String,
    tag: String = "",
    content: @Composable () -> Unit,
) {
    Box(Modifier.weight(weight), contentAlignment = Alignment.Center) {
        IconButton(
            onClick = onClick,
            enabled = enabled,
            modifier =
                Modifier.size(44.dp).testTag(tag).semantics {
                    this.contentDescription = contentDescription
                },
        ) {
            Box(contentAlignment = Alignment.Center) { content() }
        }
    }
}

private fun PlayMode.icon(): ImageVector =
    when (this) {
        PlayMode.Sequential -> Icons.Filled.FormatListNumbered
        PlayMode.Shuffle -> Icons.Filled.Shuffle
        PlayMode.RepeatAll -> Icons.Filled.Repeat
        PlayMode.RepeatOne -> Icons.Filled.RepeatOne
    }

private fun PlayMode.modeTitleRes(): Int =
    when (this) {
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
                .onSuccess {
                    working = false
                    onAdded(name)
                }
                .onFailure {
                    working = false
                    error = context.getString(AuralisR.string.action_failed, it.message)
                }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = {
            Text(
                stringResource(
                    if (createMode) AuralisR.string.new_playlist_and_add
                    else AuralisR.string.add_to_playlist
                )
            )
        },
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
                    Text(
                        stringResource(R.string.player_new_playlist_hint, track.title),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.secondaryText,
                    )
                } else {
                    if (playlists.isEmpty()) {
                        Text(
                            stringResource(AuralisR.string.no_playlists_yet),
                            color = colors.secondaryText,
                        )
                    }
                    playlists.forEach { playlist ->
                        Row(
                            modifier =
                                Modifier.fillMaxWidth()
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
                                    color =
                                        if (playlist.isReadOnly) colors.secondaryText
                                        else colors.primaryText,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (playlist.isReadOnly) {
                                    Text(
                                        stringResource(AuralisR.string.readonly_playlist_hint),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = colors.secondaryText,
                                    )
                                }
                            }
                        }
                    }
                    error?.let {
                        Text(it, color = colors.error, style = MaterialTheme.typography.bodySmall)
                    }
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
                            graph.playlistActions.createPlaylist(
                                name,
                                serverId,
                                listOf(track.id.value),
                            ) ?: error(context.getString(AuralisR.string.server_no_new_playlist))
                        }
                    },
                ) {
                    Text(
                        stringResource(
                            if (working) AuralisR.string.creating
                            else AuralisR.string.create_and_add
                        )
                    )
                }
            } else {
                TextButton(onClick = { createMode = true }) {
                    Text(stringResource(AuralisR.string.new_playlist))
                }
            }
        },
        dismissButton = {
            TextButton(onClick = { if (createMode) createMode = false else onDismiss() }) {
                Text(
                    stringResource(if (createMode) AuralisR.string.back else AuralisR.string.cancel)
                )
            }
        },
    )
}
