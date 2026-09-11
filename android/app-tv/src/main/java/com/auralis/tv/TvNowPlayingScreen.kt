// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
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
import com.auralis.core.designsystem.AuralisColorScheme
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.PlayMode
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
 * Android TV expanded player derived from MacExpandedPlayerView.
 *
 * TV deliberately drops the Mac window chrome: Back is the only close action and hardware volume
 * keys own system volume. The primary D-pad layer is one horizontal row containing shuffle,
 * previous, play/pause, next, repeat, lyrics and queue so left/right navigation never has to jump
 * between unrelated focus groups.
 *
 * The artwork and every component below it share one exact column width. The square artwork is
 * height-budgeted after title/progress/transport chrome has been reserved, so 540p/720p logical
 * TV viewports cannot push the time labels under the bottom controls.
 */
@Composable
fun TvNowPlayingScreen(
    graph: AuralisGraph,
    controller: PlaybackController,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = LocalReduceMotion.current
    val androidContext = LocalContext.current
    val scope = rememberCoroutineScope()

    var playback by remember { mutableStateOf(controller.playback.value) }
    var queue by remember { mutableStateOf(controller.queue.value) }
    val positionMs by controller.position.collectAsState()
    var playerContext by remember { mutableStateOf(TvPlayerContext.None) }

    // One focus sequence: transport 0...4, lyrics 5, queue 6.
    val primaryFocus = remember { List(7) { FocusRequester() } }
    var pendingPrimaryRestore by remember { mutableIntStateOf(-1) }

    var favoriteIds by remember { mutableStateOf<Set<GlobalId>>(emptySet()) }
    val track = playback.track

    LaunchedEffect(controller) { controller.playback.collect { playback = it } }
    LaunchedEffect(controller) { controller.queue.collect { queue = it } }

    LaunchedEffect(track?.serverId) {
        val currentTrack = track ?: return@LaunchedEffect
        graph.catalogRepository.observeFavoriteTracks(currentTrack.serverId).collect { tracks ->
            favoriteIds = tracks.map { it.globalId }.toSet()
        }
    }

    BackHandler {
        if (playerContext != TvPlayerContext.None) {
            playerContext = TvPlayerContext.None
        } else {
            onClose()
        }
    }

    LaunchedEffect(Unit) {
        yield()
        runCatching { primaryFocus[2].requestFocus() }
    }

    LaunchedEffect(playback.entry?.id?.value) {
        val target = pendingPrimaryRestore
        if (target !in primaryFocus.indices) return@LaunchedEffect
        yield()
        if (runCatching { primaryFocus[target].requestFocus() }.isSuccess) {
            pendingPrimaryRestore = -1
        }
    }

    val currentTrack = track ?: return
    val durationMs = playback.durationMs.coerceAtLeast(0L)
    val isFavorite = favoriteIds.contains(currentTrack.globalId)

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val playerTop = if (maxHeight < 700.dp) 14.dp else (maxHeight * 0.055f).coerceIn(34.dp, 72.dp)
        val targetColumnWidth = (maxWidth * 0.316f).coerceIn(320.dp, 520.dp)

        // Below-artwork budget: identity row + spacing + seek/time + bottom transport clearance.
        // Compute the artwork from the remaining height, then use that same result as column width.
        val heightLimitedArtwork = (maxHeight - playerTop - 166.dp).coerceAtLeast(240.dp)
        val playerWidth = minOf(targetColumnWidth, heightLimitedArtwork).coerceAtLeast(240.dp)
        val artworkSize = playerWidth

        val centeredLeading = ((maxWidth - playerWidth) / 2f).coerceAtLeast(0.dp)
        val contextPlayerLeading = (maxWidth * 0.092f).coerceAtLeast(28.dp)
        val targetLeading = if (playerContext == TvPlayerContext.None) centeredLeading else contextPlayerLeading
        val playerLeading by animateDpAsState(
            targetValue = targetLeading,
            animationSpec = if (reduceMotion) snap() else tween(durationMillis = 250),
            label = "tv-player-leading",
        )

        val contextGap = maxOf(62.dp, maxWidth * 0.065f)
        val contextLeading = contextPlayerLeading + playerWidth + contextGap
        val contextTrailing = maxOf(28.dp, maxWidth * 0.03f)
        val contextWidth = (maxWidth - contextLeading - contextTrailing).coerceAtLeast(260.dp)
        val contextTop = (maxHeight * 0.04f).coerceIn(20.dp, 46.dp)

        TvPlayerAmbience(
            track = currentTrack,
            modifier = Modifier.fillMaxSize(),
        )

        TvPlaybackColumn(
            controller = controller,
            playback = playback,
            track = currentTrack,
            positionMs = positionMs,
            durationMs = durationMs,
            artworkSize = artworkSize,
            isFavorite = isFavorite,
            infoActive = playerContext == TvPlayerContext.Info,
            onToggleFavorite = {
                scope.launch {
                    runCatching { graph.libraryActions.toggleTrackFavorite(currentTrack) }
                        .onFailure { throwable ->
                            val detail = throwable.message?.takeIf { it.isNotBlank() }
                                ?: throwable::class.java.simpleName
                            Toast.makeText(
                                androidContext,
                                androidContext.getString(AuralisR.string.action_failed, detail),
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                }
            },
            onToggleInfo = {
                playerContext = if (playerContext == TvPlayerContext.Info) {
                    TvPlayerContext.None
                } else {
                    TvPlayerContext.Info
                }
            },
            modifier = Modifier
                .width(playerWidth)
                .fillMaxHeight()
                .offset(x = playerLeading)
                .padding(top = playerTop, bottom = 68.dp),
        )

        AnimatedVisibility(
            visible = playerContext != TvPlayerContext.None,
            enter = if (reduceMotion) {
                fadeIn(tween(1))
            } else {
                fadeIn(tween(210)) + slideInHorizontally(
                    animationSpec = tween(250),
                    initialOffsetX = { it / 10 },
                )
            },
            exit = if (reduceMotion) {
                fadeOut(tween(1))
            } else {
                fadeOut(tween(160)) + slideOutHorizontally(
                    animationSpec = tween(210),
                    targetOffsetX = { it / 12 },
                )
            },
            modifier = Modifier
                .width(contextWidth)
                .fillMaxHeight()
                .offset(x = contextLeading)
                .padding(top = contextTop, bottom = 70.dp),
        ) {
            when (playerContext) {
                TvPlayerContext.None -> Unit
                TvPlayerContext.Lyrics -> TvLyricsPanel(
                    graph = graph,
                    controller = controller,
                    track = currentTrack,
                    positionMs = positionMs,
                )
                TvPlayerContext.Queue -> TvQueuePanel(
                    queue = queue,
                    controller = controller,
                )
                TvPlayerContext.Info -> TvTrackInfoPanel(
                    track = currentTrack,
                    playback = playback,
                )
            }
        }

        TvPrimaryControlLayer(
            controller = controller,
            playback = playback,
            queue = queue,
            context = playerContext,
            requesters = primaryFocus,
            playerWidth = playerWidth,
            onTrackChangingAction = { index -> pendingPrimaryRestore = index },
            onLyrics = {
                playerContext = if (playerContext == TvPlayerContext.Lyrics) {
                    TvPlayerContext.None
                } else {
                    TvPlayerContext.Lyrics
                }
            },
            onQueue = {
                playerContext = if (playerContext == TvPlayerContext.Queue) {
                    TvPlayerContext.None
                } else {
                    TvPlayerContext.Queue
                }
            },
            modifier = Modifier
                .align(Alignment.BottomStart)
                .offset(x = playerLeading)
                .width((maxWidth - playerLeading - 18.dp).coerceAtLeast(playerWidth))
                .padding(bottom = 10.dp),
        )
    }
}

@Composable
private fun TvPlayerAmbience(
    track: Track,
    modifier: Modifier = Modifier,
) {
    val theme = LocalAuralisTheme.current
    val colors = theme.colors
    val isLight = theme.colorScheme == AuralisColorScheme.Light

    Box(
        modifier = modifier.background(
            Brush.linearGradient(
                listOf(
                    colors.background,
                    colors.elevated,
                    colors.surface.copy(alpha = if (isLight) 0.82f else 0.90f),
                ),
            ),
        ),
    ) {
        if (!track.artworkKey.isNullOrBlank()) {
            AuralisArtwork(
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                contentDescription = null,
                titleForFallback = null,
                targetSizeDp = 1024,
                shape = RectangleShape,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = 1.15f
                        scaleY = 1.15f
                        alpha = if (isLight) 0.13f else 0.30f
                    }
                    .blur(96.dp),
            )
        }

        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            colors.accent.copy(alpha = 0.30f),
                            colors.accent.copy(alpha = 0.08f),
                            Color.Transparent,
                        ),
                        radius = 1100f,
                    ),
                ),
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.linearGradient(
                        if (isLight) {
                            listOf(Color.White.copy(alpha = 0.12f), Color.White.copy(alpha = 0.34f))
                        } else {
                            listOf(Color.Black.copy(alpha = 0.10f), Color.Black.copy(alpha = 0.34f))
                        },
                    ),
                ),
        )
    }
}

@Composable
private fun TvPlaybackColumn(
    controller: PlaybackController,
    playback: PlaybackSnapshot,
    track: Track,
    positionMs: Long,
    durationMs: Long,
    artworkSize: Dp,
    isFavorite: Boolean,
    infoActive: Boolean,
    onToggleFavorite: () -> Unit,
    onToggleInfo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val artworkExpanded = playback.state.isActive
    val artworkScale by animateFloatAsState(
        targetValue = if (artworkExpanded) 1f else 0.74f,
        animationSpec = if (reduceMotion) {
            snap()
        } else {
            spring(dampingRatio = 0.86f, stiffness = 420f)
        },
        label = "tv-player-artwork-scale",
    )

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.Start,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(artworkSize),
            contentAlignment = Alignment.Center,
        ) {
            AuralisArtwork(
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                contentDescription = track.albumTitle,
                titleForFallback = track.albumTitle,
                targetSizeDp = artworkSize.value.toInt(),
                shape = RoundedCornerShape(18.dp),
                modifier = Modifier
                    .size(artworkSize)
                    .graphicsLayer {
                        scaleX = artworkScale
                        scaleY = artworkScale
                    }
                    .shadow(
                        elevation = 18.dp,
                        shape = RoundedCornerShape(18.dp),
                        clip = false,
                    ),
            )
        }

        Spacer(Modifier.height(10.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    track.title,
                    color = colors.primaryText,
                    fontSize = 20.sp,
                    lineHeight = 24.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${track.artistName} — ${track.albumTitle}",
                    color = colors.secondaryText,
                    fontSize = 13.sp,
                    lineHeight = 17.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            TvGlassIconButton(onClick = onToggleFavorite) {
                Icon(
                    if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    contentDescription = stringResource(
                        if (isFavorite) AuralisR.string.unfavorite else AuralisR.string.favorite,
                    ),
                    tint = if (isFavorite) colors.accent else colors.primaryText.copy(alpha = 0.86f),
                    modifier = Modifier.size(21.dp),
                )
            }
            TvGlassIconButton(
                selected = infoActive,
                onClick = onToggleInfo,
            ) {
                Icon(
                    Icons.Filled.MoreHoriz,
                    contentDescription = stringResource(AuralisR.string.more_actions),
                    tint = if (infoActive) colors.accent else colors.primaryText.copy(alpha = 0.86f),
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        Spacer(Modifier.height(8.dp))

        TvSeekBar(
            positionMs = positionMs,
            durationMs = durationMs,
            onSeek = controller::seekTo,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun TvSeekBar(
    positionMs: Long,
    durationMs: Long,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(10.dp)
    val clampedPosition = positionMs.coerceIn(0L, durationMs.coerceAtLeast(0L))
    val fraction = if (durationMs > 0L) {
        clampedPosition.toFloat() / durationMs.toFloat()
    } else {
        0f
    }

    Column(modifier = modifier) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(20.dp)
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown || durationMs <= 0L) return@onPreviewKeyEvent false
                    when (event.key) {
                        Key.DirectionLeft -> {
                            onSeek((clampedPosition - 5_000L).coerceAtLeast(0L))
                            true
                        }
                        Key.DirectionRight -> {
                            onSeek((clampedPosition + 5_000L).coerceAtMost(durationMs))
                            true
                        }
                        else -> false
                    }
                }
                .tvFocusVisual(shape = shape, stroke = 2.dp)
                .focusable(enabled = durationMs > 0L)
                .padding(horizontal = 6.dp),
            contentAlignment = Alignment.Center,
        ) {
            LinearProgressIndicator(
                progress = { fraction.coerceIn(0f, 1f) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(CircleShape),
                color = colors.accent,
                trackColor = colors.separator.copy(alpha = 0.40f),
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                formatTvClock(clampedPosition),
                color = colors.secondaryText,
                fontSize = 10.sp,
                lineHeight = 12.sp,
            )
            Text(
                "-${formatTvClock((durationMs - clampedPosition).coerceAtLeast(0L))}",
                color = colors.secondaryText,
                fontSize = 10.sp,
                lineHeight = 12.sp,
            )
        }
    }
}

@Composable
private fun TvPrimaryControlLayer(
    controller: PlaybackController,
    playback: PlaybackSnapshot,
    queue: QueueSnapshot,
    context: TvPlayerContext,
    requesters: List<FocusRequester>,
    playerWidth: Dp,
    onTrackChangingAction: (Int) -> Unit,
    onLyrics: () -> Unit,
    onQueue: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TvTransportRow(
            controller = controller,
            playback = playback,
            queue = queue,
            requesters = requesters,
            onTrackChangingAction = onTrackChangingAction,
            modifier = Modifier.width(playerWidth),
        )

        Spacer(Modifier.weight(1f))

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            TvTransportAction(
                enabled = true,
                selected = context == TvPlayerContext.Lyrics,
                onClick = onLyrics,
                modifier = Modifier.focusRequester(requesters[5]),
            ) {
                val colors = LocalAuralisTheme.current.colors
                Icon(
                    Icons.Outlined.ChatBubbleOutline,
                    contentDescription = stringResource(PlayerR.string.player_tab_lyrics),
                    tint = if (context == TvPlayerContext.Lyrics) colors.accent else colors.primaryText,
                    modifier = Modifier.size(21.dp),
                )
            }
            TvTransportAction(
                enabled = true,
                selected = context == TvPlayerContext.Queue,
                onClick = onQueue,
                modifier = Modifier.focusRequester(requesters[6]),
            ) {
                val colors = LocalAuralisTheme.current.colors
                Icon(
                    Icons.AutoMirrored.Filled.QueueMusic,
                    contentDescription = stringResource(PlayerR.string.player_tab_queue),
                    tint = if (context == TvPlayerContext.Queue) colors.accent else colors.primaryText,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

@Composable
private fun TvTransportRow(
    controller: PlaybackController,
    playback: PlaybackSnapshot,
    queue: QueueSnapshot,
    requesters: List<FocusRequester>,
    onTrackChangingAction: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val canPrev = PlaybackCapabilities.canGoPrevious(playback, queue)
    val canNext = PlaybackCapabilities.canGoNext(playback, queue)
    val isPlaying = playback.state is PlaybackState.Playing
    val busy = playback.state is PlaybackState.Buffering ||
        playback.state is PlaybackState.Preparing ||
        playback.state is PlaybackState.Stalled

    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        TvTransportAction(
            enabled = true,
            selected = playback.playMode == PlayMode.Shuffle,
            onClick = {
                controller.setPlayMode(
                    if (playback.playMode == PlayMode.Shuffle) PlayMode.Sequential else PlayMode.Shuffle,
                )
            },
            modifier = Modifier.focusRequester(requesters[0]),
        ) {
            Icon(
                Icons.Filled.Shuffle,
                contentDescription = stringResource(R.string.tv_shuffle),
                tint = if (playback.playMode == PlayMode.Shuffle) colors.accent else colors.primaryText,
                modifier = Modifier.size(20.dp),
            )
        }

        TvTransportAction(
            enabled = canPrev,
            onClick = {
                onTrackChangingAction(1)
                controller.previous()
            },
            modifier = Modifier.focusRequester(requesters[1]),
        ) {
            Icon(
                Icons.Filled.SkipPrevious,
                contentDescription = stringResource(AuralisR.string.previous),
                tint = if (canPrev) colors.primaryText else colors.secondaryText.copy(alpha = 0.38f),
                modifier = Modifier.size(29.dp),
            )
        }

        TvTransportAction(
            enabled = !busy && playback.track != null,
            emphasized = true,
            onClick = controller::togglePlayPause,
            modifier = Modifier.focusRequester(requesters[2]),
        ) {
            if (busy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(26.dp),
                    strokeWidth = 2.5.dp,
                    color = colors.primaryText,
                )
            } else {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = stringResource(
                        if (isPlaying) AuralisR.string.pause else AuralisR.string.play,
                    ),
                    tint = colors.primaryText,
                    modifier = Modifier.size(34.dp),
                )
            }
        }

        TvTransportAction(
            enabled = canNext,
            onClick = {
                onTrackChangingAction(3)
                controller.next()
            },
            modifier = Modifier.focusRequester(requesters[3]),
        ) {
            Icon(
                Icons.Filled.SkipNext,
                contentDescription = stringResource(AuralisR.string.next),
                tint = if (canNext) colors.primaryText else colors.secondaryText.copy(alpha = 0.38f),
                modifier = Modifier.size(29.dp),
            )
        }

        val repeatActive = playback.playMode == PlayMode.RepeatAll ||
            playback.playMode == PlayMode.RepeatOne
        TvTransportAction(
            enabled = true,
            selected = repeatActive,
            onClick = {
                controller.setPlayMode(
                    when (playback.playMode) {
                        PlayMode.RepeatAll -> PlayMode.RepeatOne
                        PlayMode.RepeatOne -> PlayMode.Sequential
                        else -> PlayMode.RepeatAll
                    },
                )
            },
            modifier = Modifier.focusRequester(requesters[4]),
        ) {
            Icon(
                if (playback.playMode == PlayMode.RepeatOne) Icons.Filled.RepeatOne else Icons.Filled.Repeat,
                contentDescription = stringResource(R.string.tv_repeat),
                tint = if (repeatActive) colors.accent else colors.primaryText,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun TvTransportAction(
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    emphasized: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val size = if (emphasized) 54.dp else 44.dp
    Surface(
        shape = CircleShape,
        color = when {
            emphasized -> colors.surface.copy(alpha = 0.44f)
            selected -> colors.accent.copy(alpha = 0.14f)
            else -> Color.Transparent
        },
        border = if (emphasized) {
            BorderStroke(1.dp, colors.separator.copy(alpha = 0.34f))
        } else {
            null
        },
        modifier = modifier
            .size(size)
            .tvFocusableClick(
                shape = CircleShape,
                enabled = enabled,
                onClick = onClick,
            ),
    ) {
        Box(contentAlignment = Alignment.Center) {
            content()
        }
    }
}

@Composable
private fun TvGlassIconButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Surface(
        shape = CircleShape,
        color = if (selected) colors.accent.copy(alpha = 0.14f) else Color.Transparent,
        modifier = modifier
            .size(42.dp)
            .tvFocusableClick(shape = CircleShape, onClick = onClick),
    ) {
        Box(contentAlignment = Alignment.Center) {
            content()
        }
    }
}

@Composable
private fun TvLyricsPanel(
    graph: AuralisGraph,
    controller: PlaybackController,
    track: Track,
    positionMs: Long,
) {
    val theme = LocalAuralisTheme.current
    val colors = theme.colors
    val activeLyricColor = if (theme.colorScheme == AuralisColorScheme.Light) {
        Color(0xFF087D74)
    } else {
        Color(0xFF50D5C8)
    }
    val reduceMotion = LocalReduceMotion.current
    val density = LocalDensity.current
    var document by remember(track.globalId) { mutableStateOf<LyricsDocument?>(null) }
    var loading by remember(track.globalId) { mutableStateOf(true) }
    var error by remember(track.globalId) { mutableStateOf<String?>(null) }
    var focusedLyricIndex by remember(track.globalId) { mutableStateOf<Int?>(null) }
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

    LaunchedEffect(activeIndex, track.globalId, focusedLyricIndex, reduceMotion) {
        val target = activeIndex ?: return@LaunchedEffect
        if (focusedLyricIndex != null || doc?.lines?.indices?.contains(target) != true) {
            return@LaunchedEffect
        }
        yield()
        val viewportHeight = listState.layoutInfo.viewportSize.height
        val estimatedHalfLine = with(density) { 18.dp.roundToPx() }
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

    when {
        loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = colors.accent)
        }

        error != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    stringResource(PlayerR.string.player_lyrics_unavailable),
                    color = colors.primaryText,
                    style = MaterialTheme.typography.titleLarge,
                )
                Text(
                    error.orEmpty(),
                    color = colors.secondaryText,
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        doc == null || doc.lines.isEmpty() -> Box(
            Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                stringResource(PlayerR.string.player_lyrics_none_title),
                color = colors.secondaryText,
                style = MaterialTheme.typography.titleLarge,
            )
        }

        else -> LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 26.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            itemsIndexed(
                items = doc.lines,
                key = { index, _ -> index },
            ) { index, line ->
                val current = index == activeIndex
                val lineScale by animateFloatAsState(
                    targetValue = if (current) 1f else (23f / 29f),
                    animationSpec = if (reduceMotion) snap() else tween(220),
                    label = "tv-lyric-scale-$index",
                )
                val lineAlpha by animateFloatAsState(
                    targetValue = if (current) 1f else 0.55f,
                    animationSpec = if (reduceMotion) snap() else tween(220),
                    label = "tv-lyric-alpha-$index",
                )
                val start = line.startTimeSeconds
                Text(
                    text = line.text,
                    color = if (current) activeLyricColor else colors.primaryText,
                    fontSize = 29.sp,
                    lineHeight = 38.sp,
                    fontWeight = if (current) FontWeight.Bold else FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .widthIn(max = 680.dp)
                        .fillMaxWidth()
                        .graphicsLayer {
                            scaleX = lineScale
                            scaleY = lineScale
                            alpha = lineAlpha
                        }
                        .tvFocusableClick(
                            shape = RoundedCornerShape(12.dp),
                            enabled = start != null,
                            onFocusedChange = { focused ->
                                if (focused) {
                                    focusedLyricIndex = index
                                } else if (focusedLyricIndex == index) {
                                    focusedLyricIndex = null
                                }
                            },
                            onClick = {
                                start?.let { seconds ->
                                    controller.seekTo((seconds * 1000.0).toLong().coerceAtLeast(0L))
                                }
                            },
                        )
                        .padding(horizontal = 12.dp, vertical = 5.dp),
                )
            }
        }
    }
}

@Composable
private fun TvQueuePanel(
    queue: QueueSnapshot,
    controller: PlaybackController,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val currentWindowIndex = queue.currentWindowIndex ?: -1
    val upcoming = remember(queue.entries, currentWindowIndex) {
        queue.entries.drop((currentWindowIndex + 1).coerceAtLeast(0)).toList()
    }
    val hasUpcoming = (queue.currentLogicalIndex ?: -1) < queue.totalCount - 1

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.tv_up_next),
                fontSize = 18.sp,
                lineHeight = 24.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.primaryText,
            )
            Spacer(Modifier.weight(1f))
            if (hasUpcoming) {
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = Color.Transparent,
                    modifier = Modifier.tvFocusableClick(
                        shape = RoundedCornerShape(14.dp),
                        onClick = controller::clearUpcoming,
                    ),
                ) {
                    Text(
                        stringResource(R.string.tv_clear_up_next),
                        color = colors.error,
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
                    )
                }
            }
        }

        HorizontalDivider(color = colors.separator.copy(alpha = 0.62f))

        if (upcoming.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    stringResource(R.string.tv_queue_empty),
                    color = colors.secondaryText,
                    style = MaterialTheme.typography.titleMedium,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                itemsIndexed(
                    items = upcoming,
                    key = { _, entry -> entry.id.value },
                ) { _, entry ->
                    val shape = RoundedCornerShape(14.dp)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .tvFocusableClick(shape = shape) {
                                scope.launch { controller.playOccurrence(entry.id) }
                            }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        AuralisArtwork(
                            serverId = entry.track.serverId,
                            artworkKey = entry.track.artworkKey,
                            contentDescription = null,
                            titleForFallback = entry.track.title,
                            targetSizeDp = 48,
                            shape = RoundedCornerShape(6.dp),
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(Modifier.width(11.dp))
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                entry.track.title,
                                color = colors.primaryText.copy(alpha = 0.88f),
                                fontSize = 14.sp,
                                lineHeight = 18.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                entry.track.artistName,
                                color = colors.secondaryText,
                                fontSize = 12.sp,
                                lineHeight = 16.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Text(
                            formatTvClock((entry.track.durationSeconds * 1000.0).toLong()),
                            color = colors.secondaryText,
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TvTrackInfoPanel(
    track: Track,
    playback: PlaybackSnapshot,
) {
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

    Column(modifier = Modifier.fillMaxSize()) {
        Text(
            stringResource(R.string.tv_audio_info),
            color = colors.primaryText,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 14.dp),
        )
        HorizontalDivider(color = colors.separator.copy(alpha = 0.62f))
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 12.dp),
        ) {
            itemsIndexed(rows) { index, row ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 4.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        row.first,
                        color = colors.secondaryText,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        row.second,
                        color = colors.primaryText,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                if (index != rows.lastIndex) {
                    HorizontalDivider(color = colors.separator.copy(alpha = 0.34f))
                }
            }
        }
    }
}

private enum class TvPlayerContext {
    None,
    Lyrics,
    Queue,
    Info,
}

private fun formatTvClock(ms: Long): String {
    val totalSeconds = ms.coerceAtLeast(0L) / 1000L
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "%d:%02d".format(minutes, seconds)
}
