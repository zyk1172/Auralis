// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisChromeSurfaceRole
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.auralisChromeSurface
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork

/**
 * 展开态 Mini Player，逐项对齐 Apple `MiniPlayerContent`：
 * - 高 56；封面 42 / r8；外边距 12；信息与控制区最小间距 8；
 * - 标题 subheadline semibold（15sp），艺人 caption（12sp）；
 * - 控制区 spacing=4，上一首/下一首图标 16，播放图标 17，点击目标均 ≥44；
 * - 无进度条；整条点击进入 Now Playing；
 * - 悬浮材质读取 ThemeMaterials.floatingControls。
 */
@Composable
fun MiniPlayerBar(
    track: Track,
    isPlaying: Boolean,
    isBuffering: Boolean,
    canGoPrevious: Boolean,
    canGoNext: Boolean,
    onOpen: () -> Unit,
    onPrevious: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val shape = RoundedCornerShape(AuralisRadius.large)
    val openInteraction = remember { MutableInteractionSource() }

    Row(
        modifier = modifier
            .height(AuralisChrome.miniPlayerHeight)
            .auralisChromeSurface(shape, AuralisChromeSurfaceRole.FloatingControl)
            .clickable(
                interactionSource = openInteraction,
                indication = null,
                onClick = onOpen,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spacer(Modifier.width(AuralisChrome.miniPlayerHorizontalPadding))
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = stringResource(AuralisR.string.artwork_cover),
            titleForFallback = track.title,
            targetSizeDp = AuralisChrome.miniPlayerArtwork.value.toInt(),
            modifier = Modifier.size(AuralisChrome.miniPlayerArtwork),
            shape = RoundedCornerShape(AuralisRadius.small),
        )
        Spacer(Modifier.width(8.dp))
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text = track.title,
                color = colors.primaryText,
                fontSize = 15.sp,
                lineHeight = 20.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = track.artistName,
                color = colors.secondaryText,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                fontWeight = FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(4.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuralisChrome.miniPlayerControlSpacing),
        ) {
            MiniTransportButton(
                enabled = canGoPrevious,
                onClick = onPrevious,
                contentDescription = stringResource(AuralisR.string.previous),
            ) {
                Icon(
                    Icons.Filled.SkipPrevious,
                    contentDescription = null,
                    tint = colors.primaryText,
                    modifier = Modifier.size(16.dp),
                )
            }

            if (isBuffering) {
                Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(17.dp),
                        strokeWidth = 2.dp,
                        color = colors.accent,
                    )
                }
            } else {
                MiniTransportButton(
                    enabled = true,
                    onClick = onTogglePlayPause,
                    contentDescription = if (isPlaying) {
                        stringResource(AuralisR.string.pause)
                    } else {
                        stringResource(AuralisR.string.play)
                    },
                ) {
                    Icon(
                        imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                        contentDescription = null,
                        tint = colors.primaryText,
                        modifier = Modifier.size(17.dp),
                    )
                }
            }

            MiniTransportButton(
                enabled = canGoNext,
                onClick = onNext,
                contentDescription = stringResource(AuralisR.string.next),
            ) {
                Icon(
                    Icons.Filled.SkipNext,
                    contentDescription = null,
                    tint = colors.primaryText,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        Spacer(Modifier.width(AuralisChrome.miniPlayerHorizontalPadding - AuralisChrome.miniPlayerControlSpacing))
    }
}

@Composable
private fun MiniTransportButton(
    enabled: Boolean,
    onClick: () -> Unit,
    contentDescription: String,
    content: @Composable () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .size(44.dp)
            .alpha(if (enabled) 1f else 0.35f)
            .semantics { this.contentDescription = contentDescription }
            .clickable(
                enabled = enabled,
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}
