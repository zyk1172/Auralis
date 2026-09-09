// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork

/**
 * 搜索结果行，直接对照 Swift `SearchView.resultList`：
 *
 * - 歌曲复用 `TrackRow` 的 48pt 封面 / 10pt 圆角 / body + caption 密度；
 * - 专辑为 40pt 封面 + body/caption + caption2 chevron；
 * - 艺术家与歌单只使用 title3 级符号，不额外包 Android 风格的 40dp 方形底板；
 * - Section 标题保持系统 List Section 的次级、小字号语义，不做 17sp 大标题。
 */

@Composable
internal fun SearchSectionHeader(title: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        title,
        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
        color = colors.secondaryText,
        modifier = modifier
            .fillMaxWidth()
            .padding(top = AuralisSpacing.large, bottom = AuralisSpacing.xSmall),
    )
}

@Composable
internal fun SearchTrackRow(
    track: Track,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.title,
            titleForFallback = track.albumTitle,
            targetSizeDp = 96,
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Column(Modifier.weight(1f)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyLarge,
                color = colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${track.artistName} · ${track.albumTitle}",
                style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp),
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
internal fun SearchAlbumRow(
    album: Album,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AuralisArtwork(
            serverId = album.serverId,
            artworkKey = album.artworkKey,
            contentDescription = album.title,
            titleForFallback = album.title,
            targetSizeDp = 80,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(8.dp)),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Column(Modifier.weight(1f)) {
            Text(
                album.title,
                style = MaterialTheme.typography.bodyLarge,
                color = colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                album.artistName,
                style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp),
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = colors.secondaryText,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
internal fun SearchArtistRow(
    artist: Artist,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable(onClick = onClick)
            .padding(vertical = AuralisSpacing.xSmall),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.Person,
            contentDescription = null,
            tint = colors.secondaryText,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Text(
            artist.name,
            style = MaterialTheme.typography.bodyLarge,
            color = colors.primaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = colors.secondaryText,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
internal fun SearchPlaylistRow(
    playlist: Playlist,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable(onClick = onClick)
            .padding(vertical = AuralisSpacing.xSmall),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.AutoMirrored.Filled.QueueMusic,
            contentDescription = null,
            tint = colors.secondaryText,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Text(
            playlist.name,
            style = MaterialTheme.typography.bodyLarge,
            color = colors.primaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}