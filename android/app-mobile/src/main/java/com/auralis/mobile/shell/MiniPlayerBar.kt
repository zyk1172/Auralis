package com.auralis.mobile.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork

/**
 * 迷你播放条（对齐 Apple 的 Mini Player：Dock 上方 56dp 胶囊）。
 * 展示**真实**当前曲目（封面/标题/艺人）+ 播放暂停；点击区行为（展开 Now Playing）
 * 在播放器阶段（S5）接入。
 */
@Composable
fun MiniPlayerBar(
    track: Track,
    isPlaying: Boolean,
    isBuffering: Boolean,
    onTogglePlayPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .height(AuralisChrome.miniPlayerHeight)
            .background(colors.elevated, RoundedCornerShape(AuralisRadius.large))
            .padding(start = AuralisSpacing.medium, end = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = "封面",
            titleForFallback = track.title,
            targetSizeDp = 40,
            modifier = Modifier.size(40.dp),
            shape = RoundedCornerShape(AuralisRadius.small),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text = track.title,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = track.artistName,
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (isBuffering) {
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = colors.accent,
                )
            }
        } else {
            IconButton(onClick = onTogglePlayPause) {
                Icon(
                    imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) "暂停" else "播放",
                    tint = colors.primaryText,
                    modifier = Modifier.size(26.dp),
                )
            }
        }
    }
}
