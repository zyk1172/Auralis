// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.search

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.SearchResults
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 统一搜索（对齐 Swift `SearchView`，Apple 入口：Assistant 顶栏放大镜 →「搜索音乐库」）。
 *
 * - 歌曲 / 专辑 / 艺术家 / 歌单四类本地持久化结果（离线可用）；
 * - 150ms 防抖后触发 Room FTS / 索引查询；
 * - 本地无结果时可使用 OpenSubsonic `search3` 在线搜索；
 * - 搜索框、历史、List Section 密度与当前 iOS `SearchView` 保持同一视觉规则。
 */
@Composable
fun SearchScreen(
    graph: AuralisGraph,
    onBack: () -> Unit,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    var query by rememberSaveable { mutableStateOf("") }
    var debounced by remember { mutableStateOf("") }
    var local by remember { mutableStateOf<SearchResults?>(SearchResults()) }
    var localError by remember { mutableStateOf<String?>(null) }

    var serverSongs by remember { mutableStateOf<List<Track>>(emptyList()) }
    var serverSearching by remember { mutableStateOf(false) }
    var serverQuery by remember { mutableStateOf("") }
    var serverError by remember { mutableStateOf<String?>(null) }

    val recents by graph.preferences.recentSearchesFlow.collectAsState(initial = emptyList())
    val activeRaw by graph.preferences.activeServerIdFlow.collectAsState(initial = null)
    val activeServer = activeRaw?.let { ServerId(it) }

    fun resetServerSearch() {
        serverSongs = emptyList()
        serverSearching = false
        serverQuery = ""
        serverError = null
    }

    LaunchedEffect(query) {
        resetServerSearch()
        val trimmed = query.trim()
        if (trimmed.isEmpty()) {
            debounced = ""
            local = SearchResults()
            localError = null
            return@LaunchedEffect
        }
        delay(150)
        debounced = trimmed
    }

    LaunchedEffect(debounced, activeServer) {
        if (debounced.isBlank()) {
            local = SearchResults()
            localError = null
            return@LaunchedEffect
        }
        local = null
        localError = null
        val result = runCatching {
            graph.catalogRepository.search(activeServer, debounced, LOCAL_RESULT_LIMIT)
        }
        result.onSuccess { local = it }
        result.onFailure { e ->
            localError = e.message ?: context.getString(R.string.search_error_local)
            local = SearchResults()
        }
    }

    fun runServerSearch() {
        val term = query.trim()
        if (term.isEmpty()) return
        val server = activeServer
        if (server == null) {
            serverQuery = term
            serverSongs = emptyList()
            serverError = context.getString(R.string.search_error_no_server)
            return
        }
        scope.launch {
            serverQuery = term
            serverSongs = emptyList()
            serverSearching = true
            serverError = null
            runCatching { graph.serverSearch(server, term, SERVER_RESULT_LIMIT) }
                .onSuccess { if (serverQuery == term) serverSongs = it }
                .onFailure { e ->
                    if (serverQuery == term) serverError = e.message ?: context.getString(R.string.search_error_server)
                }
            if (serverQuery == term) serverSearching = false
        }
    }

    fun recordSearch(term: String) {
        val t = term.trim()
        if (t.isEmpty()) return
        scope.launch { runCatching { graph.preferences.recordSearch(t) } }
    }

    fun clearHistory() {
        scope.launch { runCatching { graph.preferences.clearSearchHistory() } }
    }

    val trimmedQuery = query.trim()
    val hasServerSongs = serverSongs.isNotEmpty() && serverQuery == debounced

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        // Swift NavigationStack 的 inline 标题高度接近 44pt；返回保持 Android 系统语义。
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            IconButton(
                onClick = onBack,
                modifier = Modifier.align(Alignment.CenterStart).size(44.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(AuralisR.string.back),
                    tint = colors.primaryText,
                    modifier = Modifier.size(20.dp),
                )
            }
            Text(
                stringResource(R.string.search_library_title),
                style = MaterialTheme.typography.titleMedium,
                color = colors.primaryText,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        SearchField(
            query = query,
            onQueryChange = { query = it },
            onClear = { query = "" },
            onSubmit = { recordSearch(trimmedQuery) },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.large)
                .padding(top = AuralisSpacing.large, bottom = AuralisSpacing.small),
        )

        when {
            query.isBlank() -> RecentSearchesContent(
                recents = recents,
                onPick = { term ->
                    query = term
                    debounced = term
                    recordSearch(term)
                },
                onClear = ::clearHistory,
                modifier = Modifier.weight(1f),
            )

            local == null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }

            localError != null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                SearchMessageCard(
                    icon = { Icon(Icons.Filled.Clear, contentDescription = null, tint = colors.secondaryText) },
                    title = stringResource(R.string.search_error_local),
                    message = localError.orEmpty(),
                )
            }

            local!!.isEmpty -> Box(Modifier.weight(1f).fillMaxWidth()) {
                Column(
                    modifier = Modifier.align(Alignment.Center).fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    when {
                        serverSearching -> {
                            CircularProgressIndicator(color = colors.accent)
                            Spacer(Modifier.height(AuralisSpacing.medium))
                            Text(
                                stringResource(R.string.search_server_progress),
                                style = MaterialTheme.typography.bodyMedium,
                                color = colors.secondaryText,
                            )
                        }

                        !hasServerSongs -> {
                            SearchMessageCard(
                                icon = { Icon(Icons.Filled.Search, contentDescription = null, tint = colors.secondaryText) },
                                title = stringResource(R.string.search_local_empty_title),
                                message = stringResource(R.string.search_local_empty_message),
                                actionLabel = stringResource(AuralisR.string.clear_search),
                                onAction = { query = "" },
                            )
                            if (serverError != null) {
                                Text(
                                    serverError.orEmpty(),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.error,
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier.padding(horizontal = AuralisSpacing.huge, vertical = AuralisSpacing.small),
                                )
                            }
                            OutlinedButton(
                                onClick = ::runServerSearch,
                                enabled = !serverSearching,
                                modifier = Modifier.padding(top = AuralisSpacing.small),
                            ) {
                                Icon(Icons.Filled.Wifi, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(AuralisSpacing.small))
                                Text(stringResource(R.string.search_server_button))
                            }
                        }

                        else -> LocalResultList(
                            results = SearchResults(songs = serverSongs),
                            serverSectionTitle = stringResource(R.string.search_server_section),
                            onPlayTracks = { tracks, index ->
                                recordSearch(trimmedQuery)
                                onPlayTracks(tracks, index)
                            },
                            onBrowse = {
                                recordSearch(trimmedQuery)
                                onBrowse(it)
                            },
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }

            else -> LocalResultList(
                results = local!!,
                onPlayTracks = { tracks, index ->
                    recordSearch(trimmedQuery)
                    onPlayTracks(tracks, index)
                },
                onBrowse = {
                    recordSearch(trimmedQuery)
                    onBrowse(it)
                },
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        }
    }
}

private const val LOCAL_RESULT_LIMIT = 60
private const val SERVER_RESULT_LIMIT = 50

@Composable
private fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    onClear: () -> Unit,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            // Swift 用的是 AuralisSpacing.medium (=12) 作为搜索框圆角，不是卡片 radius token。
            .clip(RoundedCornerShape(AuralisSpacing.medium))
            .background(colors.surface)
            .padding(AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        Icon(
            Icons.Filled.Search,
            contentDescription = null,
            tint = colors.secondaryText,
            modifier = Modifier.size(18.dp),
        )
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) {
                Text(
                    stringResource(R.string.search_field_placeholder),
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.primaryText),
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (query.isNotEmpty()) {
            IconButton(onClick = onClear, modifier = Modifier.size(44.dp)) {
                Icon(
                    Icons.Filled.Cancel,
                    contentDescription = stringResource(AuralisR.string.clear_search),
                    tint = colors.secondaryText,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RecentSearchesContent(
    recents: List<String>,
    onPick: (String) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    if (recents.isEmpty()) {
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            SearchMessageCard(
                icon = {
                    Icon(
                        Icons.Filled.Search,
                        contentDescription = null,
                        tint = colors.secondaryText,
                        modifier = Modifier.size(44.dp),
                    )
                },
                title = stringResource(R.string.search_empty_title),
                message = stringResource(R.string.search_empty_message),
            )
        }
        return
    }
    LazyColumn(modifier = modifier.fillMaxWidth()) {
        item(key = "history-header") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large)
                    .padding(top = AuralisSpacing.medium, bottom = AuralisSpacing.small),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.search_recent_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.primaryText,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onClear) {
                    Text(
                        stringResource(AuralisR.string.clear),
                        style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp),
                        color = colors.accent,
                    )
                }
            }
        }
        item(key = "history-chips") {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
                verticalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large),
            ) {
                recents.forEach { term ->
                    Surface(
                        shape = RoundedCornerShape(AuralisRadius.small),
                        color = colors.surface,
                        modifier = Modifier
                            .widthIn(min = 120.dp, max = 220.dp)
                            .clip(RoundedCornerShape(AuralisRadius.small)),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clickable { onPick(term) }
                                .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
                        ) {
                            Icon(
                                Icons.Filled.History,
                                contentDescription = null,
                                tint = colors.secondaryText,
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(
                                term,
                                style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp),
                                color = colors.primaryText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** 本地四类结果列表；服务器在线结果为空壳时仅渲染歌曲段。 */
@Composable
private fun LocalResultList(
    results: SearchResults,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    modifier: Modifier = Modifier,
    serverSectionTitle: String? = null,
) {
    LazyColumn(
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = AuralisSpacing.large),
    ) {
        if (results.songs.isNotEmpty()) {
            item(key = "header-songs") {
                SearchSectionHeader(serverSectionTitle ?: stringResource(AuralisR.string.song))
            }
            items(count = results.songs.size, key = { index -> "song-${results.songs[index].globalId.serialized}" }) { index ->
                val track = results.songs[index]
                SearchTrackRow(
                    track = track,
                    onClick = { onPlayTracks(listOf(track), 0) },
                )
            }
        }
        if (results.albums.isNotEmpty()) {
            item(key = "header-albums") {
                SearchSectionHeader(stringResource(AuralisR.string.album))
            }
            items(count = results.albums.size, key = { index -> "album-${results.albums[index].globalId.serialized}" }) { index ->
                val album = results.albums[index]
                SearchAlbumRow(album = album, onClick = { onBrowse(BrowseDestination.Album(album.globalId)) })
            }
        }
        if (results.artists.isNotEmpty()) {
            item(key = "header-artists") {
                SearchSectionHeader(stringResource(AuralisR.string.artist))
            }
            items(count = results.artists.size, key = { index -> "artist-${results.artists[index].globalId.serialized}" }) { index ->
                val artist = results.artists[index]
                SearchArtistRow(artist = artist, onClick = { onBrowse(BrowseDestination.Artist(artist.globalId)) })
            }
        }
        if (results.playlists.isNotEmpty()) {
            item(key = "header-playlists") {
                SearchSectionHeader(stringResource(AuralisR.string.playlist))
            }
            items(count = results.playlists.size, key = { index -> "playlist-${results.playlists[index].globalId.serialized}" }) { index ->
                val playlist = results.playlists[index]
                SearchPlaylistRow(playlist = playlist, onClick = { onBrowse(BrowseDestination.Playlist(playlist.globalId)) })
            }
        }
    }
}

/** 对齐 Swift `AuralisEmptyState`：icon + 标题 + 说明 + 可选动作。 */
@Composable
private fun SearchMessageCard(
    icon: @Composable () -> Unit,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.xLarge, vertical = AuralisSpacing.large),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        icon()
        Spacer(Modifier.height(AuralisSpacing.medium))
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            color = colors.primaryText,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(AuralisSpacing.small))
        Text(
            message,
            style = MaterialTheme.typography.bodySmall,
            color = colors.secondaryText,
            textAlign = TextAlign.Center,
        )
        if (actionLabel != null && onAction != null) {
            TextButton(onClick = onAction, modifier = Modifier.padding(top = AuralisSpacing.small)) {
                Text(actionLabel, color = colors.accent)
            }
        }
    }
}