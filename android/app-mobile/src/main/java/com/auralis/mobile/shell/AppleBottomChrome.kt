// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisChromeSurfaceRole
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.auralisChromeSurface
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlin.math.abs

/**
 * Android counterpart of Apple `MorphingBottomDockProgressHost`.
 *
 * The collapse state is owned by [MobileShell], not by the chrome itself. This is deliberate:
 * Apple has one `HomeChromeState` shared by the dock and every vertically scrolling section, so a
 * swipe in Home/Library/Assistant and a swipe directly on the dock must drive the exact same 0/1
 * state and 0.56s terminal animation.
 */
@Composable
fun AppleBottomChrome(
    section: AppSection,
    track: Track?,
    playbackState: PlaybackState,
    canGoPrevious: Boolean,
    canGoNext: Boolean,
    collapseProgress: Float,
    onCompactRequest: (compact: Boolean) -> Unit,
    onSelectSection: (AppSection) -> Unit,
    onOpenPlayer: () -> Unit,
    onPrevious: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val canCompact = section == AppSection.Assistant || track != null
    val progress = if (canCompact) collapseProgress.coerceIn(0f, 1f) else 0f
    val dragX = remember { mutableFloatStateOf(0f) }
    val dragY = remember { mutableFloatStateOf(0f) }

    val thresholdPx = with(density) { AuralisChrome.dockGestureThreshold.toPx() }
    val gestureModifier = Modifier.pointerInput(canCompact) {
        detectDragGestures(
            onDragStart = {
                dragX.floatValue = 0f
                dragY.floatValue = 0f
            },
            onDrag = { change, amount ->
                change.consume()
                dragX.floatValue += amount.x
                dragY.floatValue += amount.y
            },
            onDragEnd = {
                if (
                    canCompact &&
                    abs(dragY.floatValue) > abs(dragX.floatValue) &&
                    abs(dragY.floatValue) >= thresholdPx
                ) {
                    onCompactRequest(dragY.floatValue < 0f)
                }
                dragX.floatValue = 0f
                dragY.floatValue = 0f
            },
            onDragCancel = {
                dragX.floatValue = 0f
                dragY.floatValue = 0f
            },
        )
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .then(gestureModifier),
        contentAlignment = Alignment.BottomCenter,
    ) {
        if (progress >= AuralisChrome.compactInteractionThreshold && canCompact) {
            CollapsedBottomChrome(
                section = section,
                track = track,
                playbackState = playbackState,
                onExpand = { onCompactRequest(false) },
                onAssistant = {
                    onSelectSection(AppSection.Assistant)
                    onCompactRequest(false)
                },
                onOpenPlayer = onOpenPlayer,
                onTogglePlayPause = onTogglePlayPause,
            )
        } else {
            MorphingBottomChrome(
                progress = progress,
                section = section,
                track = track,
                playbackState = playbackState,
                canGoPrevious = canGoPrevious,
                canGoNext = canGoNext,
                onSelectSection = onSelectSection,
                onOpenPlayer = onOpenPlayer,
                onPrevious = onPrevious,
                onTogglePlayPause = onTogglePlayPause,
                onNext = onNext,
            )
        }
    }
}

@Composable
private fun MorphingBottomChrome(
    progress: Float,
    section: AppSection,
    track: Track?,
    playbackState: PlaybackState,
    canGoPrevious: Boolean,
    canGoNext: Boolean,
    onSelectSection: (AppSection) -> Unit,
    onOpenPlayer: () -> Unit,
    onPrevious: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
) {
    val p = progress.coerceIn(0f, 1f)
    val eased = smoothstep(0f, 1f, p)
    val chromeFade = smoothstep(0.38f, 1f, p)
    val endpointFade = smoothstep(0.44f, 0.82f, p)
    val accessory = section == AppSection.Assistant || track != null

    if (!accessory) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisChrome.dockHorizontalPadding)
                .padding(bottom = AuralisChrome.dockBottomPadding),
        ) {
            BottomDock(selected = section, onSelect = onSelectSection, modifier = Modifier.fillMaxWidth())
        }
        return
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .height(AuralisChrome.expandedInteractionHeight),
    ) {
        val fullWidth = (maxWidth - AuralisChrome.dockHorizontalPadding * 2)
            .coerceAtLeast(AuralisChrome.dockHeight)
        val playerWidth = interpolateDp(
            fullWidth,
            AuralisChrome.compactPlayerWidth.coerceAtLeast(AuralisChrome.dockHeight),
            eased,
        )
        val playerBottom = interpolateDp(
            AuralisChrome.dockBottomPadding + AuralisChrome.dockHeight + AuralisChrome.dockSpacing,
            AuralisChrome.dockBottomPadding,
            eased,
        )

        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = AuralisChrome.dockHorizontalPadding)
                .padding(bottom = AuralisChrome.dockBottomPadding)
                .fillMaxWidth()
                .alpha(1f - chromeFade)
                .graphicsLayer { scaleX = 1f - 0.16f * chromeFade },
        ) {
            BottomDock(selected = section, onSelect = onSelectSection, modifier = Modifier.fillMaxWidth())
        }

        if (track != null && section != AppSection.Assistant) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = playerBottom)
                    .width(playerWidth),
            ) {
                MiniPlayerBar(
                    track = track,
                    isPlaying = playbackState is PlaybackState.Playing,
                    isBuffering = playbackState is PlaybackState.Buffering ||
                        playbackState is PlaybackState.Stalled ||
                        playbackState is PlaybackState.Preparing,
                    canGoPrevious = canGoPrevious,
                    canGoNext = canGoNext,
                    onOpen = onOpenPlayer,
                    onPrevious = onPrevious,
                    onTogglePlayPause = onTogglePlayPause,
                    onNext = onNext,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        CircularChromeButton(
            onClick = { onSelectSection(AppSection.Home) },
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(
                    start = AuralisChrome.dockHorizontalPadding,
                    bottom = AuralisChrome.dockBottomPadding,
                )
                .alpha(endpointFade),
            tintAccent = true,
            icon = {
                Icon(
                    Icons.Filled.Home,
                    contentDescription = stringResource(AuralisR.string.home_title),
                    modifier = Modifier.size(19.dp),
                )
            },
        )
        CircularChromeButton(
            onClick = { onSelectSection(AppSection.Assistant) },
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(
                    end = AuralisChrome.dockHorizontalPadding,
                    bottom = AuralisChrome.dockBottomPadding,
                )
                .alpha(endpointFade),
            tintAccent = false,
            icon = {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = stringResource(AuralisR.string.ai_assistant),
                    modifier = Modifier.size(21.dp),
                )
            },
        )
    }
}

@Composable
private fun CollapsedBottomChrome(
    section: AppSection,
    track: Track?,
    playbackState: PlaybackState,
    onExpand: () -> Unit,
    onAssistant: () -> Unit,
    onOpenPlayer: () -> Unit,
    onTogglePlayPause: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(AuralisChrome.compactInteractionHeight)
            .padding(horizontal = AuralisChrome.dockHorizontalPadding)
            .padding(bottom = AuralisChrome.dockBottomPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularChromeButton(
            onClick = onExpand,
            tintAccent = true,
            icon = {
                Icon(
                    Icons.Filled.Home,
                    contentDescription = stringResource(AuralisR.string.home_title),
                    modifier = Modifier.size(19.dp),
                )
            },
        )
        Spacer(Modifier.width(8.dp))
        Box(
            modifier = Modifier.weight(1f).height(AuralisChrome.dockHeight),
            contentAlignment = Alignment.Center,
        ) {
            if (section != AppSection.Assistant && track != null) {
                CompactMiniPlayer(
                    track = track,
                    playbackState = playbackState,
                    onOpen = onOpenPlayer,
                    onTogglePlayPause = onTogglePlayPause,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        CircularChromeButton(
            onClick = onAssistant,
            tintAccent = false,
            icon = {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = stringResource(AuralisR.string.ai_assistant),
                    modifier = Modifier.size(21.dp),
                )
            },
        )
    }
}

@Composable
private fun CompactMiniPlayer(
    track: Track,
    playbackState: PlaybackState,
    onOpen: () -> Unit,
    onTogglePlayPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val interaction = remember { MutableInteractionSource() }
    val shape = RoundedCornerShape(AuralisRadius.large)
    Row(
        modifier = modifier
            .auralisChromeSurface(shape, AuralisChromeSurfaceRole.FloatingControl)
            .clip(shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onOpen)
            .padding(horizontal = AuralisChrome.compactMiniPlayerHorizontalPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.albumTitle,
            titleForFallback = track.title,
            targetSizeDp = AuralisChrome.compactMiniPlayerArtwork.value.toInt(),
            modifier = Modifier.size(AuralisChrome.compactMiniPlayerArtwork),
            shape = RoundedCornerShape(AuralisRadius.small),
        )
        Spacer(Modifier.width(10.dp))
        androidx.compose.material3.Text(
            text = track.title,
            color = colors.primaryText,
            fontSize = androidx.compose.ui.unit.TextUnit.Unspecified,
            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Box(
            modifier = Modifier
                .width(42.dp)
                .height(44.dp)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onTogglePlayPause,
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (
                playbackState is PlaybackState.Buffering ||
                playbackState is PlaybackState.Stalled ||
                playbackState is PlaybackState.Preparing
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(17.dp),
                    strokeWidth = 2.dp,
                    color = colors.accent,
                )
            } else {
                Icon(
                    imageVector = if (playbackState is PlaybackState.Playing) {
                        Icons.Filled.Pause
                    } else {
                        Icons.Filled.PlayArrow
                    },
                    contentDescription = if (playbackState is PlaybackState.Playing) {
                        stringResource(AuralisR.string.pause)
                    } else {
                        stringResource(AuralisR.string.play)
                    },
                    tint = colors.primaryText,
                    modifier = Modifier.size(17.dp),
                )
            }
        }
    }
}

@Composable
private fun CircularChromeButton(
    onClick: () -> Unit,
    tintAccent: Boolean,
    modifier: Modifier = Modifier,
    icon: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .size(AuralisChrome.dockHeight)
            .auralisChromeSurface(CircleShape, AuralisChromeSurfaceRole.Navigation)
            .clip(CircleShape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.material3.LocalContentColor provides if (tintAccent) {
                colors.accent
            } else {
                colors.primaryText
            },
        ) { icon() }
    }
}

private fun smoothstep(start: Float, end: Float, value: Float): Float {
    if (end <= start) return if (value >= end) 1f else 0f
    val t = ((value - start) / (end - start)).coerceIn(0f, 1f)
    return t * t * (3f - 2f * t)
}

private fun interpolateDp(start: Dp, end: Dp, amount: Float): Dp =
    (start.value + (end.value - start.value) * amount.coerceIn(0f, 1f)).dp
