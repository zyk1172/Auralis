// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.library

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.RecommendationIndexCategory
import com.auralis.core.domain.RecommendationIndexTaxonomy
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.parseRecommendationCategoryId
import com.auralis.core.image.AuralisArtwork
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * 浏览详情（对齐 Swift `BrowseDetailSheet` + `PlaylistTracksView`）。
 *
 * R10 把 `.recommendationCategory` 从占位状态切成真实本地索引查询：稳定 category id
 * 每次进入都会重新解析并通过 RecommendationIndexStore 验证当前 Track content hash，
 * 索引刷新/曲目元数据改变后不会继续展示旧快照。
 */
@Composable
fun BrowseDetailScreen(
    graph: AuralisGraph,
    initial: BrowseDestination,
    onBack: () -> Unit,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var stack by remember { mutableStateOf(listOf(initial)) }
    val current = stack.last()
    val popOrBack = {
        if (stack.size > 1) stack = stack.dropLast(1) else onBack()
    }
    var detailReloadKey by remember { mutableStateOf(0) }
    var titleOverride by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(stack) { titleOverride = null }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = popOrBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(AuralisR.string.back), tint = colors.primaryText)
            }
            Text(
                titleOverride ?: destinationTitle(current),
                style = MaterialTheme.typography.titleLarge,
                color = colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            when (current) {
                is BrowseDestination.Random, is BrowseDestination.FavoriteRandom -> IconButton(onClick = { detailReloadKey += 1 }) {
                    Icon(Icons.Filled.Refresh, contentDescription = stringResource(AuralisR.string.shuffle_more), tint = colors.accent)
                }
                is BrowseDestination.Playlist -> PlaylistManageMenu(
                    graph,
                    current,
                    onChanged = { detailReloadKey += 1 },
                    onDone = { if (it) popOrBack() },
                )
                else -> Unit
            }
        }
        HorizontalDivider(color = colors.separator)

        Box(Modifier.fillMaxSize()) {
            when (current) {
                BrowseDestination.Playlists -> PlaylistOverview(graph, push = { stack = stack + it })
                BrowseDestination.TopArtists -> TopArtistList(graph, push = { stack = stack + it })
                BrowseDestination.TopAlbums -> TopAlbumList(graph, push = { stack = stack + it })
                else -> DetailTrackContent(
                    graph = graph,
                    destination = current,
                    reloadKey = detailReloadKey,
                    onTitleReady = { titleOverride = it },
                    onPlayTracks = onPlayTracks,
                    onPlayNext = onPlayNext,
                    onAppendToQueue = onAppendToQueue,
                )
            }
        }
    }
}

/** 分派标题（对齐 Swift `BrowseDetailSheet.title`）。 */
@Composable
internal fun destinationTitle(destination: BrowseDestination): String = when (destination) {
    is BrowseDestination.Album -> stringResource(AuralisR.string.album)
    is BrowseDestination.Artist -> stringResource(AuralisR.string.artist)
    is BrowseDestination.Playlist -> stringResource(AuralisR.string.playlist)
    BrowseDestination.Playlists -> stringResource(AuralisR.string.playlist)
    BrowseDestination.Favorites -> stringResource(AuralisR.string.favorite)
    BrowseDestination.MostPlayed -> stringResource(AuralisR.string.most_played)
    is BrowseDestination.Genre -> stringResource(R.string.library_dest_genre_format, destination.name)
    is BrowseDestination.RecommendationCategory -> stringResource(R.string.library_dest_recommendation_category)
    BrowseDestination.Random -> stringResource(AuralisR.string.random_music)
    BrowseDestination.RecentlyPlayed -> stringResource(AuralisR.string.recently_played)
    BrowseDestination.RecentlyAdded -> stringResource(AuralisR.string.recently_added)
    BrowseDestination.LongUnplayed -> stringResource(AuralisR.string.long_unplayed)
    BrowseDestination.FavoriteRandom -> stringResource(AuralisR.string.favorite_random)
    BrowseDestination.NeverPlayed -> stringResource(AuralisR.string.never_played)
    BrowseDestination.TopArtists -> stringResource(AuralisR.string.top_artists)
    BrowseDestination.TopAlbums -> stringResource(AuralisR.string.top_albums)
    BrowseDestination.Downloads -> stringResource(AuralisR.string.downloads)
}

private sealed interface DetailLoad {
    data object Loading : DetailLoad
    data class Error(val message: String) : DetailLoad
    data class Ready(
        val tracks: List<Track>,
        val headerArtworkKey: String? = null,
        val headerTitle: String? = null,
        val headerSubtitle: String? = null,
    ) : DetailLoad
}

/** 按目的地加载真实数据（本地目录；Playlist 额外先服务器刷新详情）。 */
private suspend fun loadDetail(context: Context, graph: AuralisGraph, destination: BrowseDestination): DetailLoad {
    val repo = graph.catalogRepository
    val active = graph.preferences.activeServerIdFlow.first()?.let { ServerId(it) }
    fun sid() = destination.serverIdOf() ?: active
    return try {
        when (destination) {
            is BrowseDestination.Album -> {
                val album = repo.album(destination.albumId) ?: return DetailLoad.Error(context.getString(R.string.library_detail_not_found_album))
                DetailLoad.Ready(
                    tracks = repo.albumTracks(destination.albumId),
                    headerArtworkKey = album.artworkKey,
                    headerTitle = album.title,
                    headerSubtitle = context.getString(R.string.library_album_subtitle_format, album.artistName, album.songCount ?: 0),
                )
            }
            is BrowseDestination.Artist -> {
                val artist = repo.artist(destination.artistId) ?: return DetailLoad.Error(context.getString(R.string.library_detail_not_found_artist))
                val tracks = repo.artistTracks(destination.artistId)
                DetailLoad.Ready(
                    tracks = tracks,
                    headerArtworkKey = artist.artworkKey,
                    headerTitle = artist.name,
                    headerSubtitle = context.getString(R.string.library_track_count_format, tracks.size),
                )
            }
            is BrowseDestination.Playlist -> {
                val local = repo.playlist(destination.playlistId)
                    ?: return DetailLoad.Error(context.getString(R.string.library_detail_not_found_playlist))
                val remote = try {
                    graph.playlistActions.refreshPlaylist(local)
                } catch (_: Throwable) {
                    null
                }
                val refreshed = remote ?: local
                val tracks = repo.playlistTracks(refreshed.globalId)
                if (tracks.isEmpty() && remote == null) {
                    DetailLoad.Error(context.getString(R.string.library_detail_playlist_load_failed))
                } else {
                    DetailLoad.Ready(
                        tracks = tracks,
                        headerTitle = refreshed.name,
                        headerSubtitle = refreshed.comment ?: context.getString(R.string.library_track_count_format, tracks.size),
                    )
                }
            }
            BrowseDestination.Favorites -> DetailLoad.Ready(repo.favoriteTracks(sid()))
            BrowseDestination.MostPlayed -> DetailLoad.Ready(repo.mostPlayedTracks(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.RecentlyPlayed -> DetailLoad.Ready(repo.recentlyPlayed(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.RecentlyAdded -> DetailLoad.Ready(repo.recentlyAdded(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.LongUnplayed -> DetailLoad.Ready(repo.longUnplayed(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.NeverPlayed -> DetailLoad.Ready(repo.neverPlayed(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.Random -> DetailLoad.Ready(repo.randomTracks(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.FavoriteRandom -> DetailLoad.Ready(repo.favoriteRandom(sid(), DETAIL_TRACK_CAP))
            BrowseDestination.Downloads -> DetailLoad.Ready(repo.downloadedTracks(sid(), DETAIL_TRACK_CAP))
            is BrowseDestination.Genre -> DetailLoad.Ready(
                repo.genreTracks(destination.serverId ?: active, destination.name),
            )
            is BrowseDestination.RecommendationCategory -> {
                val server = active ?: return DetailLoad.Error(context.getString(R.string.library_server_prompt_help))
                val (dimension, tagId) = parseRecommendationCategoryId(destination.categoryId)
                    ?: return DetailLoad.Error(context.getString(R.string.library_category_invalid))
                val tracks = graph.recommendationIndex.tracksForCategory(server, dimension, tagId, DETAIL_TRACK_CAP)
                val category = RecommendationIndexCategory(dimension, tagId, tracks.size)
                DetailLoad.Ready(
                    tracks = tracks,
                    headerTitle = recommendationCategoryTitleForContext(context, category),
                    headerSubtitle = context.getString(R.string.library_recommendation_ranked) + " · " +
                        context.getString(R.string.library_track_count_format, tracks.size),
                )
            }
            BrowseDestination.Playlists,
            BrowseDestination.TopArtists,
            BrowseDestination.TopAlbums,
            -> DetailLoad.Ready(emptyList())
        }
    } catch (t: Throwable) {
        DetailLoad.Error(context.getString(R.string.library_load_failed_format, t.message))
    }
}

private fun BrowseDestination.serverIdOf(): ServerId? = when (this) {
    is BrowseDestination.Genre -> serverId
    else -> null
}

@Composable
private fun DetailTrackContent(
    graph: AuralisGraph,
    destination: BrowseDestination,
    reloadKey: Int,
    onTitleReady: (String) -> Unit,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
) {
    val context = LocalContext.current
    var load by remember(destination) { mutableStateOf<DetailLoad>(DetailLoad.Loading) }
    var localReload by remember { mutableStateOf(0) }
    val effectiveReload = reloadKey + localReload
    LaunchedEffect(destination, effectiveReload) {
        load = DetailLoad.Loading
        val result = loadDetail(context, graph, destination)
        load = result
        if (result is DetailLoad.Ready && result.headerTitle != null) {
            onTitleReady(result.headerTitle)
        }
    }
    val serverId = rememberActiveServerId(graph)

    when (val state = load) {
        DetailLoad.Loading -> LibraryLoadingBox()
        is DetailLoad.Error -> LibraryEmptyState(
            stringResource(R.string.library_load_failed_title),
            state.message,
            actionLabel = stringResource(AuralisR.string.retry),
            onAction = { localReload += 1 },
        )
        is DetailLoad.Ready -> when {
            state.tracks.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_no_songs_title), emptyMessage(destination))
            else -> TrackListWithHeader(
                graph = graph,
                serverId = serverId ?: destination.serverIdOf(),
                load = state,
                destination = destination,
                onPlayAll = { onPlayTracks(state.tracks, 0) },
                onPlayRow = { index -> onPlayTracks(state.tracks, index) },
                onPlayNext = onPlayNext,
                onAppendToQueue = onAppendToQueue,
                onRemovedFromPlaylist = if (destination is BrowseDestination.Playlist) {
                    { localReload += 1 }
                } else {
                    null
                },
            )
        }
    }
}

@Composable
private fun emptyMessage(destination: BrowseDestination): String = when (destination) {
    BrowseDestination.Favorites -> stringResource(R.string.library_empty_favorites_help)
    BrowseDestination.MostPlayed -> stringResource(R.string.library_empty_most_played)
    BrowseDestination.LongUnplayed -> stringResource(R.string.library_empty_long_unplayed)
    BrowseDestination.NeverPlayed -> stringResource(R.string.library_empty_never_played)
    BrowseDestination.FavoriteRandom -> stringResource(R.string.library_empty_favorite_random)
    BrowseDestination.Downloads -> stringResource(R.string.library_empty_downloads)
    is BrowseDestination.Genre -> stringResource(R.string.library_empty_genre)
    BrowseDestination.Random -> stringResource(R.string.library_empty_random)
    is BrowseDestination.Playlist -> stringResource(R.string.library_empty_playlist_detail)
    is BrowseDestination.RecommendationCategory -> stringResource(R.string.library_category_empty)
    else -> stringResource(R.string.library_empty_misc)
}

/** 头图 + 标题/副标题 + 播放全部 + 下载（确认弹窗）+ 曲目清单。 */
@Composable
private fun TrackListWithHeader(
    graph: AuralisGraph,
    serverId: ServerId?,
    load: DetailLoad.Ready,
    destination: BrowseDestination,
    onPlayAll: () -> Unit,
    onPlayRow: (Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
    onRemovedFromPlaylist: (() -> Unit)?,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    var confirmingDownload by remember { mutableStateOf(false) }
    var creatingRecommendationPlaylist by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    val playlistDestination = destination as? BrowseDestination.Playlist
    var removingIndex by remember { mutableStateOf<Int?>(null) }
    var removingBusy by remember { mutableStateOf(false) }

    LazyColumn(modifier = Modifier.fillMaxSize()) {
        item(key = "header") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.medium),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
            ) {
                val artworkKey = load.headerArtworkKey
                val headerServer = serverId
                if (headerServer != null && artworkKey != null) {
                    AuralisArtwork(
                        serverId = headerServer,
                        artworkKey = artworkKey,
                        contentDescription = load.headerTitle,
                        titleForFallback = load.headerTitle,
                        targetSizeDp = 176,
                        shape = RoundedCornerShape(AuralisRadius.medium),
                        modifier = Modifier.size(88.dp),
                    )
                }
                Column(Modifier.weight(1f)) {
                    load.headerTitle?.let {
                        Text(it, style = MaterialTheme.typography.titleLarge, color = colors.primaryText, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    load.headerSubtitle?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                    Spacer(Modifier.height(AuralisSpacing.small))
                    Row(horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small)) {
                        OutlinedButton(
                            onClick = onPlayAll,
                            enabled = load.tracks.isNotEmpty(),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AuralisSpacing.medium, vertical = 6.dp),
                        ) {
                            Icon(Icons.Filled.PlayArrow, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(stringResource(R.string.library_play_all))
                        }
                        OutlinedButton(
                            onClick = { confirmingDownload = true },
                            enabled = load.tracks.isNotEmpty(),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AuralisSpacing.medium, vertical = 6.dp),
                        ) {
                            Icon(Icons.Filled.ArrowDownward, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(stringResource(R.string.library_download_action))
                        }
                        if (destination is BrowseDestination.RecommendationCategory) {
                            OutlinedButton(
                                onClick = {
                                    if (!creatingRecommendationPlaylist) {
                                        val targetServer = serverId ?: load.tracks.firstOrNull()?.serverId
                                        if (targetServer == null) {
                                            message = context.getString(R.string.library_server_prompt_help)
                                        } else {
                                            creatingRecommendationPlaylist = true
                                            scope.launch {
                                                runCatching {
                                                    graph.playlistActions.createPlaylist(
                                                        name = context.getString(
                                                            R.string.library_recommendation_playlist_name_format,
                                                            load.headerTitle ?: context.getString(R.string.library_dest_recommendation_category),
                                                        ),
                                                        serverId = targetServer,
                                                        trackIds = load.tracks.map { it.id.value },
                                                    )
                                                }
                                                    .onSuccess { playlist ->
                                                        message = if (playlist == null) {
                                                            context.getString(R.string.library_duplicate_server_failed)
                                                        } else {
                                                            context.getString(R.string.library_recommendation_playlist_created_format, playlist.name)
                                                        }
                                                    }
                                                    .onFailure { error ->
                                                        message = context.getString(R.string.library_recommendation_playlist_failed_format, error.message)
                                                    }
                                                creatingRecommendationPlaylist = false
                                            }
                                        }
                                    }
                                },
                                enabled = load.tracks.isNotEmpty() && !creatingRecommendationPlaylist,
                                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AuralisSpacing.medium, vertical = 6.dp),
                            ) {
                                Icon(Icons.AutoMirrored.Filled.QueueMusic, null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(AuralisSpacing.small))
                                Text(
                                    if (creatingRecommendationPlaylist) {
                                        stringResource(R.string.library_recommendation_playlist_creating)
                                    } else {
                                        stringResource(R.string.library_recommendation_playlist)
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
        item(key = "section") {
            Text(
                stringResource(AuralisR.string.song),
                style = MaterialTheme.typography.labelLarge,
                color = colors.secondaryText,
                modifier = Modifier.padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
            )
        }
        items(count = load.tracks.size) { index ->
            val track = load.tracks[index]
            LibraryTrackRow(
                graph = graph,
                serverId = serverId ?: track.serverId,
                track = track,
                onClick = { onPlayRow(index) },
                onPlayNext = { onPlayNext(listOf(track)) },
                onAppendToQueue = { onAppendToQueue(listOf(track)) },
                additionalMenuItems = if (playlistDestination != null) {
                    { close ->
                        HorizontalDivider(color = colors.separator)
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.library_remove_from_playlist)) },
                            leadingIcon = { Icon(Icons.Filled.Delete, null) },
                            enabled = removingIndex == null && !removingBusy,
                            onClick = {
                                close()
                                removingIndex = index
                            },
                        )
                    }
                } else {
                    null
                },
            )
        }
    }

    if (playlistDestination != null) {
        removingIndex?.let { index ->
            AlertDialog(
                onDismissRequest = { if (!removingBusy) removingIndex = null },
                title = { Text(stringResource(R.string.library_remove_confirm_title)) },
                text = { Text(stringResource(R.string.library_remove_confirm_text)) },
                confirmButton = {
                    TextButton(
                        enabled = !removingBusy,
                        onClick = {
                            val targetIndex = index
                            removingIndex = null
                            scope.launch {
                                removingBusy = true
                                runCatching {
                                    val p = graph.catalogRepository.playlist(playlistDestination.playlistId)
                                    if (p == null) error(context.getString(R.string.library_detail_not_found_playlist)) else graph.playlistActions.removeAt(p, listOf(targetIndex))
                                }
                                    .onSuccess { onRemovedFromPlaylist?.invoke() }
                                    .onFailure { message = context.getString(R.string.library_remove_failed_format, it.message) }
                                removingBusy = false
                            }
                        },
                    ) { Text(if (removingBusy) stringResource(R.string.library_removing) else stringResource(R.string.library_remove), color = colors.error) }
                },
                dismissButton = {
                    TextButton(enabled = !removingBusy, onClick = { removingIndex = null }) { Text(stringResource(AuralisR.string.cancel)) }
                },
            )
        }
    }

    if (confirmingDownload) {
        val estimatedMb = ((load.tracks.size * 8) / 1024.0).toInt().coerceAtLeast(1)
        AlertDialog(
            onDismissRequest = { confirmingDownload = false },
            title = { Text(stringResource(R.string.library_confirm_download_title, load.tracks.size)) },
            text = { Text(stringResource(R.string.library_confirm_download_text, estimatedMb)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDownload = false
                        scope.launch {
                            runCatching { load.tracks.forEach { graph.downloadManager.enqueue(it) } }
                                .onFailure { message = context.getString(AuralisR.string.download_failed, it.message) }
                                .onSuccess { message = context.getString(R.string.library_download_started_format, load.tracks.size) }
                        }
                    },
                ) { Text(stringResource(R.string.library_start_download)) }
            },
            dismissButton = { TextButton(onClick = { confirmingDownload = false }) { Text(stringResource(AuralisR.string.cancel)) } },
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

// ================================================================ 歌单总览与详情

@Composable
private fun PlaylistOverview(
    graph: AuralisGraph,
    push: (BrowseDestination) -> Unit,
) {
    val serverId = rememberActiveServerId(graph)
    val repo = graph.catalogRepository
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sort by remember { mutableStateOf(PlaylistSort.NameAscending) }
    var pendingDelete by remember { mutableStateOf<Playlist?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val playlists by remember(serverId) { repo.observePlaylists(serverId) }.collectAsState(initial = null)

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(R.string.library_playlist_count_format, playlists?.size ?: 0), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, modifier = Modifier.weight(1f))
            Box {
                var sortMenu by remember { mutableStateOf(false) }
                IconButton(onClick = { sortMenu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.library_sort_cd), tint = colors.secondaryText)
                }
                DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                    PlaylistSort.entries.forEach { order ->
                        DropdownMenuItem(
                            text = { Text(stringResource(order.titleRes())) },
                            onClick = { sort = order; sortMenu = false },
                        )
                    }
                }
            }
        }
        HorizontalDivider(color = colors.separator)
        when {
            playlists == null -> LibraryLoadingBox(stringResource(R.string.library_loading_playlists))
            playlists!!.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_empty_playlists_title), stringResource(R.string.library_empty_playlists_help))
            else -> {
                val sorted = sort.apply(playlists!!)
                LazyColumn(Modifier.fillMaxSize()) {
                    items(sorted, key = { it.globalId.serialized }) { playlist ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { push(BrowseDestination.Playlist(playlist.globalId)) }
                                .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
                        ) {
                            Box(
                                modifier = Modifier.size(40.dp).clip(RoundedCornerShape(AuralisRadius.small)).background(colors.surface),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
                            }
                            Text(playlist.name, style = MaterialTheme.typography.bodyLarge, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            IconButton(
                                enabled = !playlist.isReadOnly,
                                onClick = { pendingDelete = playlist },
                            ) {
                                Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.library_delete_playlist), tint = if (playlist.isReadOnly) colors.secondaryText.copy(alpha = 0.4f) else colors.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { playlist ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.library_delete_playlist_confirm_title, playlist.name)) },
            text = { Text(stringResource(R.string.library_delete_playlist_confirm_text)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        val target = playlist
                        pendingDelete = null
                        scope.launch {
                            runCatching { graph.playlistActions.delete(target) }
                                .onFailure { message = context.getString(R.string.library_delete_playlist_failed_format, it.message) }
                        }
                    },
                ) { Text(stringResource(AuralisR.string.delete), color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text(stringResource(AuralisR.string.cancel)) } },
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

private enum class PlaylistSort {
    NameAscending, NameDescending, RecentlyModified;

    @StringRes
    fun titleRes(): Int = when (this) {
        NameAscending -> R.string.library_sort_name_asc
        NameDescending -> R.string.library_sort_name_desc
        RecentlyModified -> R.string.library_sort_recently_modified
    }
}

private fun PlaylistSort.apply(playlists: List<Playlist>): List<Playlist> = when (this) {
    PlaylistSort.NameAscending -> playlists.sortedBy { it.name.lowercase() }
    PlaylistSort.NameDescending -> playlists.sortedByDescending { it.name.lowercase() }
    PlaylistSort.RecentlyModified -> playlists.sortedByDescending { it.modifiedAtMillis ?: Long.MIN_VALUE }
}

/** 歌单详情管理菜单（对齐 Swift PlaylistTracksView ellipsis）：重命名/复制/去重/删除。 */
@Composable
private fun PlaylistManageMenu(
    graph: AuralisGraph,
    destination: BrowseDestination.Playlist,
    onChanged: () -> Unit,
    onDone: (Boolean) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    Box {
        IconButton(onClick = { menuOpen = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.library_playlist_actions_cd), tint = colors.secondaryText)
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_rename)) },
                onClick = {
                    menuOpen = false
                    scope.launch {
                        val p = graph.catalogRepository.playlist(destination.playlistId)
                        renameText = p?.name.orEmpty()
                        renaming = true
                    }
                },
            )
            DropdownMenuItem(
                text = { Text(if (busy) stringResource(R.string.library_copying) else stringResource(R.string.library_duplicate_playlist)) },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val p = graph.catalogRepository.playlist(destination.playlistId)
                        if (p == null) {
                            busy = false
                            message = context.getString(R.string.library_detail_not_found_playlist)
                        } else {
                            runCatching { graph.playlistActions.duplicate(p) }
                                .onFailure { message = context.getString(R.string.library_duplicate_failed_format, it.message) }
                                .onSuccess { message = if (it == null) context.getString(R.string.library_duplicate_server_failed) else context.getString(R.string.library_duplicated_format, it.name) }
                            busy = false
                        }
                    }
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_dedupe_songs)) },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val p = graph.catalogRepository.playlist(destination.playlistId)
                        if (p == null) {
                            busy = false
                            message = context.getString(R.string.library_detail_not_found_playlist)
                        } else {
                            runCatching { graph.playlistActions.removeDuplicateSongs(p) }
                                .onSuccess { removed ->
                                    message = if (removed) context.getString(R.string.library_dedupe_removed) else context.getString(R.string.library_dedupe_none)
                                    if (removed) onChanged()
                                }
                                .onFailure { message = context.getString(R.string.library_dedupe_failed_format, it.message) }
                            busy = false
                        }
                    }
                },
            )
            HorizontalDivider(color = colors.separator)
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_delete_playlist)) },
                leadingIcon = { Icon(Icons.Filled.Delete, null) },
                onClick = {
                    menuOpen = false
                    confirmingDelete = true
                },
            )
        }
    }

    if (renaming) {
        AlertDialog(
            onDismissRequest = { if (!busy) renaming = false },
            title = { Text(stringResource(R.string.library_rename_playlist_title)) },
            text = {
                Column {
                    androidx.compose.material3.OutlinedTextField(
                        value = renameText,
                        onValueChange = { renameText = it },
                        label = { Text(stringResource(AuralisR.string.playlist_name_label)) },
                        singleLine = true,
                    )
                    Text(stringResource(R.string.library_rename_sync_hint), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, modifier = Modifier.padding(top = AuralisSpacing.small))
                }
            },
            confirmButton = {
                TextButton(
                    enabled = renameText.isNotBlank() && !busy,
                    onClick = {
                        val name = renameText.trim()
                        renaming = false
                        busy = true
                        scope.launch {
                            val p = graph.catalogRepository.playlist(destination.playlistId)
                            if (p == null) {
                                busy = false
                                message = context.getString(R.string.library_detail_not_found_playlist)
                            } else {
                                runCatching { graph.playlistActions.rename(p, name) }
                                    .onSuccess { if (it) onChanged() }
                                    .onFailure { message = context.getString(R.string.library_rename_failed_format, it.message) }
                                busy = false
                            }
                        }
                    },
                ) { Text(stringResource(AuralisR.string.save)) }
            },
            dismissButton = { TextButton(onClick = { renaming = false }) { Text(stringResource(AuralisR.string.cancel)) } },
        )
    }
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text(stringResource(R.string.library_delete_playlist_question)) },
            text = { Text(stringResource(R.string.library_delete_playlist_irreversible)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDelete = false
                        busy = true
                        scope.launch {
                            val p = graph.catalogRepository.playlist(destination.playlistId)
                            if (p == null) {
                                busy = false
                                message = context.getString(R.string.library_detail_not_found_playlist)
                            } else {
                                runCatching { graph.playlistActions.delete(p) }
                                    .onFailure { busy = false; message = context.getString(R.string.library_delete_playlist_failed_format, it.message) }
                                    .onSuccess { busy = false; onDone(true) }
                            }
                        }
                    },
                ) { Text(stringResource(AuralisR.string.delete), color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text(stringResource(AuralisR.string.cancel)) } },
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

// ================================================================ 常听列表

@Composable
private fun TopArtistList(
    graph: AuralisGraph,
    push: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val serverId = rememberActiveServerId(graph)
    var pairs by remember { mutableStateOf<List<Pair<Artist, Int>>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(serverId, reloadKey) {
        pairs = null
        error = null
        if (serverId == null) {
            error = context.getString(R.string.library_top_artists_no_server)
        } else {
            runCatching { graph.catalogRepository.homeTopArtists(serverId, 500) }
                .onSuccess { pairs = it }
                .onFailure { error = context.getString(R.string.library_stats_failed_format, it.message) }
        }
    }
    when {
        error != null -> LibraryEmptyState(
            stringResource(R.string.library_load_failed_title),
            error!!,
            actionLabel = stringResource(AuralisR.string.retry),
            onAction = { reloadKey += 1 },
        )
        pairs == null -> LibraryLoadingBox(stringResource(R.string.library_stats_loading_top_artists))
        pairs!!.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_empty_top_artists_title), stringResource(R.string.library_empty_top_artists_help))
        else -> LazyColumn(Modifier.fillMaxSize()) {
            val sorted = pairs!!.sortedByDescending { it.second }
            items(sorted, key = { it.first.globalId.serialized }) { (artist, count) ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { push(BrowseDestination.Artist(artist.globalId)) }
                        .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
                ) {
                    AuralisArtwork(
                        serverId = artist.serverId,
                        artworkKey = artist.artworkKey,
                        contentDescription = artist.name,
                        titleForFallback = artist.name,
                        targetSizeDp = 88,
                        shape = RoundedCornerShape(AuralisRadius.small),
                        modifier = Modifier.size(44.dp),
                    )
                    Column(Modifier.weight(1f)) {
                        Text(artist.name, style = MaterialTheme.typography.titleMedium, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(stringResource(R.string.library_plays_count_format, count), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                }
            }
        }
    }
}

@Composable
private fun TopAlbumList(
    graph: AuralisGraph,
    push: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val serverId = rememberActiveServerId(graph)
    var pairs by remember { mutableStateOf<List<Pair<Album, Int>>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(serverId, reloadKey) {
        pairs = null
        error = null
        if (serverId == null) {
            error = context.getString(R.string.library_top_albums_no_server)
        } else {
            runCatching { graph.catalogRepository.homeTopAlbums(serverId, 500) }
                .onSuccess { pairs = it }
                .onFailure { error = context.getString(R.string.library_stats_failed_format, it.message) }
        }
    }
    when {
        error != null -> LibraryEmptyState(
            stringResource(R.string.library_load_failed_title),
            error!!,
            actionLabel = stringResource(AuralisR.string.retry),
            onAction = { reloadKey += 1 },
        )
        pairs == null -> LibraryLoadingBox(stringResource(R.string.library_stats_loading_top_albums))
        pairs!!.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_empty_top_albums_title), stringResource(R.string.library_empty_top_albums_help))
        else -> LazyColumn(Modifier.fillMaxSize()) {
            val sorted = pairs!!.sortedByDescending { it.second }
            items(sorted, key = { it.first.globalId.serialized }) { (album, count) ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { push(BrowseDestination.Album(album.globalId)) }
                        .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
                ) {
                    AuralisArtwork(
                        serverId = album.serverId,
                        artworkKey = album.artworkKey,
                        contentDescription = album.title,
                        titleForFallback = album.title,
                        targetSizeDp = 88,
                        shape = RoundedCornerShape(AuralisRadius.small),
                        modifier = Modifier.size(44.dp),
                    )
                    Column(Modifier.weight(1f)) {
                        Text(album.title, style = MaterialTheme.typography.titleMedium, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(album.artistName, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(stringResource(R.string.library_plays_count_format, count), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                }
            }
        }
    }
}

private fun recommendationCategoryTitleForContext(context: Context, category: RecommendationIndexCategory): String {
    val dimensionRes = when (category.dimension) {
        "mood" -> R.string.library_category_dimension_mood
        "scene" -> R.string.library_category_dimension_scene
        "theme" -> R.string.library_category_dimension_theme
        "genre" -> R.string.library_category_dimension_genre
        "style" -> R.string.library_category_dimension_style
        "vocal" -> R.string.library_category_dimension_vocal
        "instrument" -> R.string.library_category_dimension_instrument
        "texture" -> R.string.library_category_dimension_texture
        "rhythm" -> R.string.library_category_dimension_rhythm
        "energy" -> R.string.library_category_dimension_energy
        "tempo" -> R.string.library_category_dimension_tempo
        "acousticness" -> R.string.library_category_dimension_acousticness
        "danceability" -> R.string.library_category_dimension_danceability
        "instrumentalness" -> R.string.library_category_dimension_instrumentalness
        "liveness" -> R.string.library_category_dimension_liveness
        "speechiness" -> R.string.library_category_dimension_speechiness
        "valence" -> R.string.library_category_dimension_valence
        "complexity" -> R.string.library_category_dimension_complexity
        else -> R.string.library_scope_categories
    }
    val suffix = when (category.dimension) {
        "energy" -> "${category.tagId}/10"
        "tempo", "acousticness", "danceability", "instrumentalness", "liveness", "speechiness", "valence", "complexity" -> "${category.tagId}/5"
        else -> RecommendationIndexTaxonomy.definition(category.tagId)?.displayName ?: category.tagId
    }
    return "${context.getString(dimensionRes)} · $suffix"
}
