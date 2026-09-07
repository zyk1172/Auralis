package com.auralis.mobile.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
 * 迷你播放条（对齐 Apple MiniPlayerContent：56dp 胶囊，封面 + 曲目信息 + 上一首/
 * 播放暂停/下一首）。
 * - 点封面/曲目信息区 = 展开正在播放全屏页（Shell 注入）；
 * - 上一首/下一首 = 真实 engine.previous/next（canPrev/canNext 控制可用）；
 * - 缓冲中在播放键位显示 spinner，切歌按钮保持可用。
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
    Row(
        modifier = modifier
            .height(AuralisChrome.miniPlayerHeight)
            .background(colors.elevated, RoundedCornerShape(AuralisRadius.large))
            .padding(start = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 封面 + 标题区：点击展开正在播放。
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .clickable(onClick = onOpen)
                .padding(start = AuralisSpacing.small, end = AuralisSpacing.small),
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
        }
        IconButton(onClick = onPrevious, enabled = canGoPrevious) {
            Icon(
                Icons.Filled.SkipPrevious,
                contentDescription = "上一首",
                tint = if (canGoPrevious) colors.primaryText else colors.secondaryText.copy(alpha = 0.35f),
                modifier = Modifier.size(22.dp),
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
        IconButton(onClick = onNext, enabled = canGoNext) {
            Icon(
                Icons.Filled.SkipNext,
                contentDescription = "下一首",
                tint = if (canGoNext) colors.primaryText else colors.secondaryText.copy(alpha = 0.35f),
                modifier = Modifier.size(22.dp),
            )
        }
    }
}
