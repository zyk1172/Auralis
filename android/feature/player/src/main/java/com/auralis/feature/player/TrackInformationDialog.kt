// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.Track

/**
 * Android 对 Apple `TrackInformationSheet` 的本地信息部分。
 *
 * 只展示真实目录/Room 状态，不暴露 stream/download URL、凭据或内部数据库 key。
 * Apple 的 Music Haptics 和公开音乐数据聚合属于平台/后续能力，不在这里伪造。
 */
@Composable
internal fun TrackInformationDialog(
    graph: AuralisGraph,
    track: Track,
    onDismiss: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val download by remember(track.globalId) { graph.catalogRepository.observe(track.globalId) }
        .collectAsState(initial = null)
    var favorite by remember(track.globalId) { mutableStateOf(track.isFavorite) }
    var rating by remember(track.globalId) { mutableStateOf(track.rating) }
    var playCount by remember(track.globalId) { mutableStateOf(0) }
    var hasLyrics by remember(track.globalId) { mutableStateOf(false) }

    LaunchedEffect(track.globalId) {
        favorite = runCatching { graph.catalogRepository.isFavorite(track.globalId) }.getOrDefault(track.isFavorite)
        rating = runCatching { graph.database.annotationDao().rating(track.globalId.serialized) }.getOrNull() ?: track.rating
        playCount = runCatching { graph.database.annotationDao().history(track.globalId.serialized)?.playCount ?: 0 }.getOrDefault(0)
        hasLyrics = runCatching { graph.database.annotationDao().lyric(track.globalId.serialized) != null }.getOrDefault(false)
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .fillMaxHeight(0.86f)
                .widthIn(max = 560.dp),
            shape = RoundedCornerShape(AuralisRadius.large),
            color = colors.background,
            contentColor = colors.primaryText,
            tonalElevation = 0.dp,
        ) {
            Column {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = AuralisSpacing.small),
                ) {
                    Text(
                        stringResource(R.string.player_track_info_title),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.primaryText,
                        modifier = Modifier.align(Alignment.Center),
                    )
                    TextButton(
                        onClick = onDismiss,
                        modifier = Modifier.align(Alignment.CenterEnd),
                    ) {
                        Text(stringResource(AuralisR.string.done), color = colors.accent)
                    }
                }
                HorizontalDivider(color = colors.separator)

                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = AuralisSpacing.large,
                        vertical = AuralisSpacing.medium,
                    ),
                    verticalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
                ) {
                    item { InfoSectionTitle(stringResource(R.string.player_track_info_basic)) }
                    item { InfoRow(stringResource(R.string.player_track_info_song), track.title) }
                    item { InfoRow(stringResource(R.string.player_track_info_artist), track.artistName) }
                    item { InfoRow(stringResource(R.string.player_track_info_album), track.albumTitle) }
                    item { InfoRow(stringResource(R.string.player_track_info_duration), formatClock((track.durationSeconds * 1000).toLong())) }
                    item { InfoRow(stringResource(R.string.player_track_info_year), track.year?.toString() ?: stringResource(R.string.player_unknown)) }
                    item {
                        InfoRow(
                            stringResource(R.string.player_track_info_genre),
                            track.genres.takeIf { it.isNotEmpty() }?.joinToString("、") ?: stringResource(R.string.player_unknown),
                        )
                    }
                    item { InfoRow(stringResource(R.string.player_track_info_language), track.language ?: stringResource(R.string.player_unknown)) }

                    item { InfoSectionTitle(stringResource(R.string.player_track_info_position)) }
                    item { InfoRow(stringResource(R.string.player_track_info_disc), track.discNumber?.toString() ?: stringResource(R.string.player_unknown)) }
                    item { InfoRow(stringResource(R.string.player_track_info_track_number), track.trackNumber?.toString() ?: stringResource(R.string.player_unknown)) }

                    item { InfoSectionTitle(stringResource(R.string.player_track_info_quality)) }
                    item { InfoRow(stringResource(R.string.player_track_info_format), track.sourceInfo.normalizedCodec?.uppercase() ?: stringResource(R.string.player_unknown)) }
                    item { InfoRow(stringResource(R.string.player_track_info_sample_rate), track.sourceInfo.sampleRate?.let { "$it Hz" } ?: stringResource(R.string.player_unknown)) }
                    item { InfoRow(stringResource(R.string.player_track_info_bit_depth), track.sourceInfo.bitDepth?.let { "$it bit" } ?: stringResource(R.string.player_unknown)) }
                    item { InfoRow(stringResource(R.string.player_track_info_bit_rate), track.sourceInfo.bitRate?.let { "$it kbps" } ?: stringResource(R.string.player_unknown)) }
                    item { InfoRow(stringResource(R.string.player_track_info_channels), track.sourceInfo.channelCount?.toString() ?: stringResource(R.string.player_unknown)) }

                    item { InfoSectionTitle(stringResource(R.string.player_track_info_status)) }
                    item {
                        InfoRow(
                            stringResource(R.string.player_track_info_favorite),
                            stringResource(if (favorite) R.string.player_track_info_favorited else R.string.player_track_info_not_favorited),
                        )
                    }
                    item {
                        InfoRow(
                            stringResource(R.string.player_track_info_rating),
                            rating?.let { stringResource(R.string.player_track_info_rating_value, it) }
                                ?: stringResource(R.string.player_track_info_unrated),
                        )
                    }
                    item { InfoRow(stringResource(R.string.player_track_info_play_count), stringResource(R.string.player_track_info_play_count_value, playCount)) }
                    item {
                        InfoRow(
                            stringResource(R.string.player_track_info_download),
                            stringResource(if (download?.status == DownloadStatus.Downloaded) R.string.player_track_info_downloaded else R.string.player_track_info_not_downloaded),
                        )
                    }
                    item {
                        InfoRow(
                            stringResource(R.string.player_track_info_lyrics),
                            stringResource(if (hasLyrics) R.string.player_track_info_lyrics_available else R.string.player_track_info_lyrics_none),
                        )
                    }
                    item { Spacer(Modifier.padding(bottom = AuralisSpacing.small)) }
                }
            }
        }
    }
}

@Composable
private fun InfoSectionTitle(title: String) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = colors.secondaryText,
        modifier = Modifier.padding(top = AuralisSpacing.medium, bottom = AuralisSpacing.xSmall),
    )
}

@Composable
private fun InfoRow(label: String, value: String) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface.copy(alpha = 0.58f), RoundedCornerShape(AuralisRadius.small))
            .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = colors.secondaryText,
            modifier = Modifier.weight(0.38f),
            maxLines = 2,
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            color = colors.primaryText,
            textAlign = TextAlign.End,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(0.62f),
        )
    }
}
