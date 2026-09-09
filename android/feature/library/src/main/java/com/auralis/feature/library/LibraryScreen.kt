// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.Genre
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.RecommendationIndexCategory
import com.auralis.core.domain.RecommendationIndexUiState
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlinx.coroutines.launch

/**
 * Android Library mirrors iOS `LibraryView` and the surrounding `IOSMusicShell` navigation chrome.
 *
 * The iOS source of truth is a large navigation title + 44pt accent settings target, followed by a
 * single segmented picker and divider. Scrollable scopes reserve the same dynamic bottom-chrome
 * clearance as Apple's `reportsBottomDockScroll`, so the final row/card never sits underneath the
 * morphing dock while wide screens stay inside the shared 960pt readable width.
 *
 * R10: Categories 不再是占位页；直接读取与 Apple 同表语义的 Recommendation Index v3，
 * 平铺所有有效分类并按歌曲数排序，点击后使用稳定 category id 进入真实歌曲详情。
 */
@Composable
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
fun LibraryScreen(
    graph: AuralisGraph,
    onOpenSettings: () -> Unit,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    recommendationIndexState: RecommendationIndexUiState = RecommendationIndexUiState(),
    onStartRecommendationIndex: () -> Unit = {},
    onCancelRecommendationIndex: () -> Unit = {},
    onRefreshRecommendationIndex: () -> Unit = {},
    bottomChromeClearance: Dp = AuralisChrome.expandedInteractionHeight,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var scope by remember { mutableStateOf(LibraryScope.Albums) }
    val serverId = rememberActiveServerId(graph)

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = AuralisSpacing.large, end = 16.dp, top = 6.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(AuralisR.string.library_title),
                style = MaterialTheme.typography.displayLarge,
                color = colors.primaryText,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Box(
                modifier = Modifier
                    .size(AuralisChrome.minTouchTarget)
                    .clip(CircleShape)
                    .clickable(onClick = onOpenSettings),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Settings,
                    contentDescription = stringResource(AuralisR.string.settings),
                    tint = colors.accent,
                    modifier = Modifier.size(16.dp),
                )
            }
        }

        ScopeSelector(selected = scope, onSelect = { scope = it })
        HorizontalDivider(color = colors.separator)

        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.TopCenter,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .widthIn(max = AuralisChrome.readableContentMaxWidth),
            ) {
                when (scope) {
                    LibraryScope.Albums -> AlbumScope(
                        graph = graph,
                        serverId = serverId,
                        onPlayTracks = onPlayTracks,
                        onBrowse = onBrowse,
                        bottomPadding = bottomChromeClearance,
                    )
                    LibraryScope.Tracks -> TracksOrFavoritesScope(
                        graph = graph,
                        serverId = serverId,
                        isFavorites = false,
                        onPlayTracks = onPlayTracks,
                        onPlayNext = onPlayNext,
                        onAppendToQueue = onAppendToQueue,
                        bottomPadding = bottomChromeClearance,
                    )
                    LibraryScope.Artists -> ArtistScope(
                        graph = graph,
                        serverId = serverId,
                        onPlayTracks = onPlayTracks,
                        onBrowse = onBrowse,
                        bottomPadding = bottomChromeClearance,
                    )
                    LibraryScope.Playlists -> PlaylistScope(
                        graph = graph,
                        serverId = serverId,
                        onBrowse = onBrowse,
                        bottomPadding = bottomChromeClearance,
                    )
                    LibraryScope.Favorites -> TracksOrFavoritesScope(
                        graph = graph,
                        serverId = serverId,
                        isFavorites = true,
                        onPlayTracks = onPlayTracks,
                        onPlayNext = onPlayNext,
                        onAppendToQueue = onAppendToQueue,
                        bottomPadding = bottomChromeClearance,
                    )
                    LibraryScope.Genres -> GenreScope(
                        graph = graph,
                        serverId = serverId,
                        onBrowse = onBrowse,
                        bottomPadding = bottomChromeClearance,
                    )
                    LibraryScope.Categories -> CategoryScope(
                        graph = graph,
                        serverId = serverId,
                        onBrowse = onBrowse,
                        recommendationIndexState = recommendationIndexState,
                        onStartRecommendationIndex = onStartRecommendationIndex,
                        onCancelRecommendationIndex = onCancelRecommendationIndex,
                        onRefreshRecommendationIndex = onRefreshRecommendationIndex,
                        bottomPadding = bottomChromeClearance,
                    )
                }
            }
        }
    }
}

/** iOS `.pickerStyle(.segmented)` geometry: one shared trough, no independent pill gaps. */
@Composable
private fun ScopeSelector(selected: LibraryScope, onSelect: (LibraryScope) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    val outerShape = RoundedCornerShape(10.dp)
    val selectedShape = RoundedCornerShape(8.dp)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small)
            .clip(outerShape)
            .background(colors.elevated.copy(alpha = 0.82f))
            .padding(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LibraryScope.entries.forEach { item ->
            val isSelected = item == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 32.dp)
                    .clip(selectedShape)
                    .background(if (isSelected) colors.surface else androidx.compose.ui.graphics.Color.Transparent)
                    .clickable { onSelect(item) }
                    .padding(horizontal = 2.dp, vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = stringResource(item.titleRes()),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                    color = if (isSelected) colors.accent else colors.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                )
            }
        }
    }
}

// ------------------------------------------------------------------ scopes

@Composable
private fun AlbumScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    if (serverId == null) return ServerPrompt()
    val albums by remember(serverId) { graph.catalogRepository.observeAlbums(serverId) }.collectAsState(initial = null)
    when {
        albums == null -> LibraryLoadingBox(stringResource(R.string.library_loading_albums))
        albums!!.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_empty_albums_title), stringResource(R.string.library_empty_albums_help))
        else -> AlbumGrid(graph, albums!!, onPlayTracks, onBrowse, bottomPadding)
    }
}

@Composable
private fun ArtistScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    if (serverId == null) return ServerPrompt()
    val artists by remember(serverId) { graph.catalogRepository.observeArtists(serverId) }.collectAsState(initial = null)
    when {
        artists == null -> LibraryLoadingBox(stringResource(R.string.library_loading_artists))
        artists!!.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_empty_artists_title), stringResource(R.string.library_empty_artists_help))
        else -> ArtistRows(graph, artists!!, onPlayTracks, onBrowse, bottomPadding)
    }
}

@Composable
private fun PlaylistScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    if (serverId == null) return ServerPrompt()
    val playlists by remember(serverId) { graph.catalogRepository.observePlaylists(serverId) }.collectAsState(initial = null)
    when {
        playlists == null -> LibraryLoadingBox(stringResource(R.string.library_loading_playlists))
        playlists!!.isEmpty() -> LibraryEmptyState(stringResource(R.string.library_empty_playlists_title), stringResource(R.string.library_empty_playlists_help))
        else -> PlaylistGrid(playlists!!, onBrowse, bottomPadding)
    }
}

@Composable
@kotlinx.coroutines.ExperimentalCoroutinesApi
private fun TracksOrFavoritesScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    isFavorites: Boolean,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
    bottomPadding: Dp,
) {
    if (serverId == null) return ServerPrompt()
    val repo = graph.catalogRepository
    val source = remember(serverId, isFavorites) {
        if (isFavorites) repo.observeFavoriteTracks(serverId) else repo.observeTracks(serverId)
    }
    val tracks by source.collectAsState(initial = null)
    when {
        tracks == null -> LibraryLoadingBox(stringResource(if (isFavorites) R.string.library_loading_favorites else R.string.library_loading_tracks))
        tracks!!.isEmpty() -> if (isFavorites) {
            LibraryEmptyState(stringResource(R.string.library_empty_favorites_title), stringResource(R.string.library_empty_favorites_help))
        } else {
            LibraryEmptyState(
                stringResource(R.string.library_empty_tracks_title),
                stringResource(R.string.library_empty_tracks_help),
            )
        }
        else -> TrackRows(
            graph = graph,
            serverId = serverId,
            tracks = tracks!!,
            onPlayTracks = onPlayTracks,
            onPlayNext = onPlayNext,
            onAppendToQueue = onAppendToQueue,
            showDownloadBadge = !isFavorites,
            bottomPadding = bottomPadding,
        )
    }
}

@Composable
private fun GenreScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    if (serverId == null) return ServerPrompt()
    val repo = graph.catalogRepository
    val genres by remember(serverId) { repo.observeGenres(serverId) }.collectAsState(initial = null)
    val scope = rememberCoroutineScope()
    when {
        genres == null -> LibraryLoadingBox(stringResource(R.string.library_loading_genres))
        genres!!.isEmpty() -> LibraryEmptyState(
            stringResource(R.string.library_empty_genres_title),
            stringResource(R.string.library_empty_genres_help),
            actionLabel = stringResource(R.string.library_genres_refresh_action),
            onAction = {
                scope.launch {
                    val client = graph.registry.client(serverId)
                    val remote = runCatching { client?.genres() }.getOrNull().orEmpty()
                    if (remote.isNotEmpty()) repo.mergeGenres(serverId, remote)
                }
            },
        )
        else -> GenreGrid(genres!!, serverId, onBrowse, bottomPadding)
    }
}

/**
 * Apple Categories = 所有固定 taxonomy 分类直接平铺，不先选维度。
 * 只展示 RecommendationIndexStore 判定 content hash 仍有效的分类，旧元数据分类不会漏进 UI。
 */
@Composable
private fun CategoryScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onBrowse: (BrowseDestination) -> Unit,
    recommendationIndexState: RecommendationIndexUiState,
    onStartRecommendationIndex: () -> Unit,
    onCancelRecommendationIndex: () -> Unit,
    onRefreshRecommendationIndex: () -> Unit,
    bottomPadding: Dp,
) {
    if (serverId == null) return ServerPrompt()
    var categories by remember(serverId) { mutableStateOf<List<RecommendationIndexCategory>?>(null) }
    var error by remember(serverId) { mutableStateOf<String?>(null) }
    var reload by remember(serverId) { mutableIntStateOf(0) }

    LaunchedEffect(serverId, reload) {
        categories = null
        error = null
        runCatching { graph.recommendationIndex.categories(serverId) }
            .onSuccess { categories = it.sortedWith(compareByDescending<RecommendationIndexCategory> { item -> item.trackCount }.thenBy { item -> item.id }) }
            .onFailure { throwable -> error = throwable.message ?: throwable::class.java.simpleName }
    }
    LaunchedEffect(recommendationIndexState.lastCompletedAtMillis) {
        if (recommendationIndexState.lastCompletedAtMillis != null) reload += 1
    }

    val refreshIndexAndCategories = {
        onRefreshRecommendationIndex()
        reload += 1
    }

    val loadError = error
    when {
        loadError != null -> LibraryEmptyState(
            stringResource(R.string.library_load_failed_title),
            stringResource(R.string.library_load_failed_format, loadError),
            actionLabel = stringResource(AuralisR.string.retry),
            onAction = { reload += 1 },
        )
        categories == null -> LibraryLoadingBox(stringResource(R.string.library_loading_categories))
        categories!!.isEmpty() -> Column(Modifier.fillMaxSize()) {
            RecommendationIndexStatusCard(
                state = recommendationIndexState,
                onStart = onStartRecommendationIndex,
                onCancel = onCancelRecommendationIndex,
                onRefresh = refreshIndexAndCategories,
            )
            LibraryEmptyState(
                stringResource(R.string.library_categories_ai_empty_title),
                stringResource(R.string.library_categories_ai_empty_help),
                modifier = Modifier.weight(1f),
            )
        }
        else -> Column(Modifier.fillMaxSize()) {
            RecommendationIndexStatusCard(
                state = recommendationIndexState,
                onStart = onStartRecommendationIndex,
                onCancel = onCancelRecommendationIndex,
                onRefresh = refreshIndexAndCategories,
            )
            LazyVerticalGrid(
                columns = GridCells.Adaptive(158.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                contentPadding = PaddingValues(
                    start = 20.dp,
                    end = 20.dp,
                    top = 12.dp,
                    bottom = bottomPadding + 20.dp,
                ),
                modifier = Modifier.weight(1f),
            ) {
                items(categories!!, key = { it.id }) { category ->
                    RecommendationCategoryCard(category = category) {
                        onBrowse(BrowseDestination.RecommendationCategory(category.id))
                    }
                }
            }
        }
    }
}

@Composable
private fun RecommendationIndexStatusCard(
    state: RecommendationIndexUiState,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onRefresh: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val statusText = when {
        state.isRunning -> stringResource(
            R.string.library_recommendation_index_running_format,
            state.indexedTracks,
            state.totalTracks,
        )
        state.error != null -> stringResource(R.string.library_recommendation_index_error_format, state.error)
        state.totalTracks == 0 -> stringResource(R.string.library_recommendation_index_no_tracks)
        state.pendingTracks > 0 -> stringResource(
            R.string.library_recommendation_index_pending_format,
            state.pendingTracks,
            state.totalTracks,
        )
        else -> stringResource(R.string.library_recommendation_index_complete_format, state.indexedTracks)
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 12.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surface)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.library_recommendation_index_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.primaryText,
                )
                Text(statusText, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
            if (state.isRunning) {
                TextButton(onClick = onCancel) { Text(stringResource(AuralisR.string.cancel)) }
            } else if (state.pendingTracks > 0) {
                TextButton(onClick = onStart) { Text(stringResource(R.string.library_recommendation_index_start)) }
            } else if (state.error != null) {
                TextButton(onClick = onStart) { Text(stringResource(AuralisR.string.retry)) }
            } else {
                TextButton(onClick = onRefresh) { Text(stringResource(R.string.library_recommendation_index_refresh)) }
            }
        }
        if (state.isRunning && state.totalTracks > 0) {
            androidx.compose.material3.LinearProgressIndicator(
                progress = { (state.indexedTracks.toFloat() / state.totalTracks).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
                color = colors.accent,
            )
        }
    }
}

@Composable
private fun RecommendationCategoryCard(
    category: RecommendationIndexCategory,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 94.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surface)
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Android 没有 SF Symbols；使用音乐分类的稳定平台等价图标，不复制 Apple 字体资源。
            Icon(
                Icons.AutoMirrored.Filled.QueueMusic,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.weight(1f))
            Text(
                category.trackCount.toString(),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = colors.secondaryText,
            )
        }
        Text(
            recommendationCategoryTitle(category),
            style = MaterialTheme.typography.titleSmall,
            color = colors.primaryText,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            stringResource(R.string.library_track_count_format, category.trackCount),
            style = MaterialTheme.typography.labelSmall,
            color = colors.secondaryText,
        )
    }
}

@Composable
internal fun recommendationCategoryTitle(category: RecommendationIndexCategory): String {
    val dimension = stringResource(recommendationDimensionTitleRes(category.dimension))
    val suffix = when (category.dimension) {
        "energy" -> "${category.tagId}/10"
        "tempo", "acousticness", "danceability", "instrumentalness", "liveness", "speechiness", "valence", "complexity" -> "${category.tagId}/5"
        else -> com.auralis.core.domain.RecommendationIndexTaxonomy.definition(category.tagId)?.displayName ?: category.tagId
    }
    return "$dimension · $suffix"
}

private fun recommendationDimensionTitleRes(dimension: String): Int = when (dimension) {
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

@Composable
private fun ServerPrompt() {
    LibraryEmptyState(stringResource(R.string.library_server_prompt_title), stringResource(R.string.library_server_prompt_help))
}

/** 曲目行列表（歌曲 scope / 收藏 scope）。整列表为新队列，点行从该行起播。 */
@Composable
internal fun TrackRows(
    graph: AuralisGraph,
    serverId: ServerId,
    tracks: List<Track>,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
    showDownloadBadge: Boolean = true,
    bottomPadding: Dp = AuralisChrome.expandedInteractionHeight,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = bottomPadding + AuralisSpacing.large),
    ) {
        items(tracks, key = { it.globalId.serialized }) { track ->
            LibraryTrackRow(
                graph = graph,
                serverId = serverId,
                track = track,
                showDownloadBadge = showDownloadBadge,
                onClick = { onPlayTracks(tracks, tracks.indexOfFirst { it.globalId == track.globalId }.coerceAtLeast(0)) },
                onPlayNext = { onPlayNext(listOf(track)) },
                onAppendToQueue = { onAppendToQueue(listOf(track)) },
            )
        }
    }
}

// ================================================================== 网格

@Composable
private fun AlbumGrid(
    graph: AuralisGraph,
    albums: List<Album>,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(AuralisChrome.albumGridMin),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
        contentPadding = PaddingValues(
            start = AuralisSpacing.large,
            end = AuralisSpacing.large,
            top = AuralisSpacing.medium,
            bottom = bottomPadding + AuralisSpacing.large,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(albums, key = { it.globalId.serialized }) { album ->
            AlbumCard(
                graph = graph,
                album = album,
                onPlayTracks = onPlayTracks,
                onBrowse = onBrowse,
            )
        }
    }
}

/** 专辑卡：点击打开详情；卡角 ⋯ = 播放全部 / 收藏专辑 / 下载专辑（真实动作）。 */
@Composable
private fun AlbumCard(
    graph: AuralisGraph,
    album: Album,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val repo = graph.catalogRepository
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    var isFavorite by remember(album.globalId) { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(menuOpen) {
        if (menuOpen) {
            isFavorite = runCatching { repo.isFavorite(album.globalId, FavoriteKind.Album) }.getOrDefault(false)
        }
    }

    Box {
        Column(modifier = Modifier.fillMaxWidth()) {
            AuralisArtwork(
                serverId = album.serverId,
                artworkKey = album.artworkKey,
                contentDescription = album.title,
                titleForFallback = album.title,
                targetSizeDp = 280,
                shape = cardShape(),
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .clip(cardShape())
                    .clickable { onBrowse(BrowseDestination.Album(album.globalId)) },
            )
            Text(
                album.title,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold,
                color = colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = AuralisSpacing.xSmall),
            )
            Text(
                album.artistName,
                style = MaterialTheme.typography.labelMedium,
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = { menuOpen = true }, modifier = Modifier.align(Alignment.TopEnd)) {
            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.library_album_actions), tint = colors.secondaryText)
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_play_all)) },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val tracks = runCatching { repo.albumTracks(album.globalId) }.getOrDefault(emptyList())
                        busy = false
                        if (tracks.isEmpty()) message = context.getString(R.string.library_album_no_local_tracks) else onPlayTracks(tracks, 0)
                    }
                },
            )
            DropdownMenuItem(
                text = { Text(if (isFavorite) stringResource(AuralisR.string.unfavorite) else stringResource(R.string.library_favorite_album)) },
                leadingIcon = { Icon(if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null) },
                onClick = {
                    menuOpen = false
                    scope.launch {
                        runCatching { graph.libraryActions.toggleAlbumFavorite(album) }
                            .onFailure { message = context.getString(AuralisR.string.favorite_failed, it.message) }
                    }
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_download_album)) },
                leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val tracks = runCatching { repo.albumTracks(album.globalId) }.getOrDefault(emptyList())
                        busy = false
                        if (tracks.isEmpty()) {
                            message = context.getString(R.string.library_album_no_local_tracks)
                        } else {
                            runCatching { tracks.forEach { graph.downloadManager.enqueue(it) } }
                                .onFailure { message = context.getString(AuralisR.string.download_failed, it.message) }
                                .onSuccess { message = context.getString(R.string.library_download_started_format, tracks.size) }
                        }
                    }
                },
            )
        }
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
private fun ArtistRows(
    graph: AuralisGraph,
    artists: List<Artist>,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = bottomPadding + AuralisSpacing.large),
    ) {
        items(artists, key = { it.globalId.serialized }) { artist ->
            ArtistRow(graph, artist, onPlayTracks, onBrowse)
        }
    }
}

/** 艺术家行：点击打开详情；行尾 ⋯ = 播放全部 / 收藏艺术家 / 下载全部。 */
@Composable
private fun ArtistRow(
    graph: AuralisGraph,
    artist: Artist,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val context = LocalContext.current
    val repo = graph.catalogRepository
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    var isFavorite by remember(artist.globalId) { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(menuOpen) {
        if (menuOpen) {
            isFavorite = runCatching { repo.isFavorite(artist.globalId, FavoriteKind.Artist) }.getOrDefault(false)
        }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onBrowse(BrowseDestination.Artist(artist.globalId)) }
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
    ) {
        AuralisArtwork(
            serverId = artist.serverId,
            artworkKey = artist.artworkKey,
            contentDescription = artist.name,
            titleForFallback = artist.name,
            targetSizeDp = AuralisChrome.artistArtwork.value.toInt(),
            shape = CircleShape,
            modifier = Modifier.size(AuralisChrome.artistArtwork),
        )
        Column(Modifier.weight(1f)) {
            Text(artist.name, style = MaterialTheme.typography.titleMedium, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(stringResource(AuralisR.string.album_count_format, artist.albumCount), style = MaterialTheme.typography.labelMedium, color = colors.secondaryText)
        }
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.library_artist_actions), tint = colors.secondaryText)
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.library_play_all)) },
                    leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
                    enabled = !busy,
                    onClick = {
                        menuOpen = false
                        busy = true
                        scope.launch {
                            val tracks = runCatching { repo.artistTracks(artist.globalId) }.getOrDefault(emptyList())
                            busy = false
                            if (tracks.isEmpty()) message = context.getString(R.string.library_artist_no_local_tracks) else onPlayTracks(tracks, 0)
                        }
                    },
                )
                DropdownMenuItem(
                    text = { Text(if (isFavorite) stringResource(AuralisR.string.unfavorite) else stringResource(R.string.library_favorite_artist)) },
                    leadingIcon = { Icon(if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null) },
                    onClick = {
                        menuOpen = false
                        scope.launch {
                            runCatching { graph.libraryActions.toggleArtistFavorite(artist) }
                                .onFailure { message = context.getString(AuralisR.string.favorite_failed, it.message) }
                        }
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.library_download_all)) },
                    leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                    enabled = !busy,
                    onClick = {
                        menuOpen = false
                        busy = true
                        scope.launch {
                            val tracks = runCatching { repo.artistTracks(artist.globalId) }.getOrDefault(emptyList())
                            busy = false
                            if (tracks.isEmpty()) {
                                message = context.getString(R.string.library_artist_no_local_tracks)
                            } else {
                                runCatching { tracks.forEach { graph.downloadManager.enqueue(it) } }
                                    .onFailure { message = context.getString(AuralisR.string.download_failed, it.message) }
                                    .onSuccess { message = context.getString(R.string.library_download_started_format, tracks.size) }
                            }
                        }
                    },
                )
            }
        }
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text(stringResource(AuralisR.string.got_it)) } },
            text = { Text(it) },
        )
    }
}

/** 歌单栅格：点击卡片进入歌单详情（BrowseDestination.Playlist）。 */
@Composable
private fun PlaylistGrid(
    playlists: List<Playlist>,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    val colors = LocalAuralisTheme.current.colors
    LazyVerticalGrid(
        columns = GridCells.Adaptive(AuralisChrome.albumGridMin),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
        contentPadding = PaddingValues(
            start = AuralisSpacing.large,
            end = AuralisSpacing.large,
            top = AuralisSpacing.medium,
            bottom = bottomPadding + AuralisSpacing.large,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(playlists, key = { it.globalId.serialized }) { playlist ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onBrowse(BrowseDestination.Playlist(playlist.globalId)) },
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(1f)
                        .clip(cardShape())
                        .background(colors.surface),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null, tint = colors.accent, modifier = Modifier.size(40.dp))
                }
                Text(
                    playlist.name,
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.primaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = AuralisSpacing.xSmall),
                )
            }
        }
    }
}

@Composable
private fun GenreGrid(
    genres: List<Genre>,
    serverId: ServerId,
    onBrowse: (BrowseDestination) -> Unit,
    bottomPadding: Dp,
) {
    val colors = LocalAuralisTheme.current.colors
    LazyVerticalGrid(
        columns = GridCells.Adaptive(AuralisChrome.genreGridMin),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        contentPadding = PaddingValues(
            start = AuralisSpacing.medium,
            end = AuralisSpacing.medium,
            top = AuralisSpacing.medium,
            bottom = bottomPadding + AuralisSpacing.large,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(genres, key = { it.id }) { genre ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(AuralisRadius.medium))
                    .background(colors.surface)
                    .clickable { onBrowse(BrowseDestination.Genre(genre.name, serverId)) }
                    .padding(AuralisSpacing.medium),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, null, tint = colors.accent)
                    Spacer(Modifier.weight(1f))
                    Text("${genre.songCount}", style = MaterialTheme.typography.labelMedium, color = colors.secondaryText)
                }
                Spacer(Modifier.height(AuralisSpacing.small))
                Text(genre.name, style = MaterialTheme.typography.titleSmall, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(stringResource(AuralisR.string.count_songs, genre.songCount), style = MaterialTheme.typography.labelMedium, color = colors.secondaryText)
            }
        }
    }
}
