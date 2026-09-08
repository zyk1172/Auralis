// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlinx.coroutines.launch

/**
 * 曲目列表组件（Library 歌曲/收藏 scope 与 BrowseDetail 歌曲清单共用）。
 *
 * 行视觉对齐 Swift `TrackRow`：封面 48 / 圆角 10；标题+「艺术家 · 专辑」；
 * 右侧 = 已下载（success 色）/已收藏（accent 色）/时长（m:ss）。
 * 点行 = 把当前列表作为新队列从该曲起播（Shell 注入回调）；行尾 ⋯ = 真实动作菜单：
 * 立即播放 / 下一首播放 / 加入队列 / 添加到歌单 / 下载·取消·删缓存 / 收藏切换。
 */

/** 收藏曲目 id 集合（null = 首帧未就绪）。收藏表变化自动更新。 */
@Composable
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
internal fun rememberFavoriteIds(graph: AuralisGraph, serverId: ServerId): androidx.compose.runtime.State<Set<GlobalId>?> {
    val flow = remember(serverId) { graph.catalogRepository.observeFavoriteTracks(serverId) }
    val tracks by flow.collectAsState(initial = null)
    return remember(tracks) { mutableStateOf(tracks?.map { it.globalId }?.toSet()) }
}

/** 行组件：徽标态由 downloads 表与 favorites 表实时观察驱动。 */
@Composable
internal fun LibraryTrackRow(
    graph: AuralisGraph,
    serverId: ServerId,
    track: Track,
    onClick: () -> Unit,
    onPlayNext: () -> Unit,
    onAppendToQueue: () -> Unit,
    modifier: Modifier = Modifier,
    showDownloadBadge: Boolean = true,
    isCurrent: Boolean = false,
    /** 追加到行尾 ⋯ 菜单末尾的项（如歌单详情「从歌单移除」）。回调关闭行菜单。 */
    additionalMenuItems: (@Composable (close: () -> Unit) -> Unit)? = null,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val download by remember(track.globalId) { graph.catalogRepository.observe(track.globalId) }.collectAsState(initial = null)
    val favorites = rememberFavoriteIds(graph, serverId)
    val isFavorite = favorites.value?.contains(track.globalId) == true
    var addingToPlaylist by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = AuralisSpacing.large, vertical = 3.dp),
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
        Column(Modifier.weight(1f)) {
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
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (showDownloadBadge && download?.status == DownloadStatus.Downloaded) {
            Icon(Icons.Filled.Download, contentDescription = stringResource(R.string.library_downloaded), tint = colors.success, modifier = Modifier.size(14.dp))
        }
        if (isFavorite) {
            Icon(Icons.Filled.Favorite, contentDescription = stringResource(R.string.library_favorited), tint = colors.accent, modifier = Modifier.size(14.dp))
        }
        Text(formatDurationSeconds(track.durationSeconds), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
        TrackRowMenu(
            graph = graph,
            track = track,
            isFavorite = isFavorite,
            download = download,
            onPlayNow = onClick,
            onPlayNext = onPlayNext,
            onAppendToQueue = onAppendToQueue,
            onAddToPlaylist = { addingToPlaylist = true },
            onMessage = { message = it },
            additionalItems = additionalMenuItems,
        )
    }

    if (addingToPlaylist) {
        PlaylistAddDialog(
            graph = graph,
            serverId = track.serverId,
            tracks = listOf(track),
            onDismiss = { addingToPlaylist = false },
            onAdded = { name ->
                addingToPlaylist = false
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

@Composable
private fun TrackRowMenu(
    graph: AuralisGraph,
    track: Track,
    isFavorite: Boolean,
    download: DownloadRecord?,
    onPlayNow: () -> Unit,
    onPlayNext: () -> Unit,
    onAppendToQueue: () -> Unit,
    onAddToPlaylist: () -> Unit,
    onMessage: (String) -> Unit,
    additionalItems: (@Composable (close: () -> Unit) -> Unit)? = null,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { menuOpen = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.library_track_actions), tint = colors.secondaryText)
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_play_now)) },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
                onClick = { menuOpen = false; onPlayNow() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_play_next)) },
                leadingIcon = { Icon(Icons.Filled.SkipNext, null) },
                onClick = { menuOpen = false; onPlayNext() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_add_to_queue)) },
                leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null) },
                onClick = { menuOpen = false; onAppendToQueue() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(AuralisR.string.add_to_playlist)) },
                leadingIcon = { Icon(Icons.Filled.Add, null) },
                onClick = { menuOpen = false; onAddToPlaylist() },
            )
            HorizontalDivider(color = colors.separator)
            when {
                download?.status == DownloadStatus.Downloaded -> DropdownMenuItem(
                    text = { Text(stringResource(R.string.library_delete_local_cache)) },
                    leadingIcon = { Icon(Icons.Filled.Delete, null) },
                    onClick = {
                        menuOpen = false
                        graph.downloadManager.deleteCached(track.globalId)
                    },
                )
                download?.status == DownloadStatus.Downloading || download?.status == DownloadStatus.Queued -> DropdownMenuItem(
                    text = { Text(stringResource(R.string.library_cancel_download)) },
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
                                .onFailure { onMessage(context.getString(AuralisR.string.download_failed, it.message)) }
                        }
                    },
                )
            }
            HorizontalDivider(color = colors.separator)
            DropdownMenuItem(
                text = { Text(if (isFavorite) stringResource(AuralisR.string.unfavorite) else stringResource(AuralisR.string.favorite)) },
                leadingIcon = { Icon(if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null) },
                onClick = {
                    menuOpen = false
                    scope.launch {
                        runCatching { graph.libraryActions.toggleTrackFavorite(track) }
                            .onFailure { onMessage(context.getString(AuralisR.string.favorite_failed, it.message)) }
                    }
                },
            )
            additionalItems?.invoke { menuOpen = false }
        }
    }
}

/** 歌曲/曲目批量加入歌单：选已有歌单（只读禁用）或新建。远端先行；成功回调歌单名。 */
@Composable
internal fun PlaylistAddDialog(
    graph: AuralisGraph,
    serverId: ServerId,
    tracks: List<Track>,
    onDismiss: () -> Unit,
    onAdded: (String) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val flow = remember(serverId) { graph.catalogRepository.observePlaylists(serverId) }
    val playlists by flow.collectAsState(initial = emptyList())
    var createMode by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

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
        title = { Text(if (createMode) stringResource(AuralisR.string.new_playlist_and_add) else stringResource(AuralisR.string.add_to_playlist)) },
        text = {
            Column {
                if (createMode) {
                    OutlinedTextField(
                        value = newName,
                        onValueChange = { newName = it },
                        label = { Text(stringResource(AuralisR.string.playlist_name_label)) },
                        singleLine = true,
                    )
                    Text(
                        stringResource(R.string.library_add_count_hint, tracks.size),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.secondaryText,
                        modifier = Modifier.padding(top = AuralisSpacing.small),
                    )
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
                                        graph.playlistActions.addTracks(playlist, tracks)
                                    }
                                }
                                .padding(vertical = AuralisSpacing.small),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null, tint = colors.accent)
                            Column(Modifier.weight(1f).padding(start = AuralisSpacing.medium)) {
                                Text(
                                    playlist.name,
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = if (playlist.isReadOnly) colors.secondaryText else colors.primaryText,
                                )
                                if (playlist.isReadOnly) {
                                    Text(stringResource(AuralisR.string.readonly_playlist_hint), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                                }
                            }
                        }
                    }
                    if (playlists.isNotEmpty()) Spacer(Modifier.height(AuralisSpacing.small))
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
                            val created = graph.playlistActions.createPlaylist(name, serverId, tracks.map { it.id.value })
                                ?: error(context.getString(AuralisR.string.server_no_new_playlist))
                        }
                    },
                ) { Text(if (working) stringResource(AuralisR.string.creating) else stringResource(AuralisR.string.create_and_add)) }
            } else {
                TextButton(onClick = { createMode = true }) { Text(stringResource(AuralisR.string.new_playlist)) }
            }
        },
        dismissButton = {
            TextButton(onClick = { if (createMode) createMode = false else onDismiss() }) {
                Text(if (createMode) stringResource(AuralisR.string.back) else stringResource(AuralisR.string.cancel))
            }
        },
    )
}
