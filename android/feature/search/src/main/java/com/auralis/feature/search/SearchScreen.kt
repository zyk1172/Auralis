package com.auralis.feature.search

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.SearchResults
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 统一搜索（对齐 Swift `SearchView`，Apple 入口：Assistant 顶栏放大镜 →「搜索音乐库」）。
 *
 * - 歌曲 / 专辑 / 艺术家 / 歌单四类**本地持久化资料库**结果（离线可用）；
 * - 150ms 防抖后触发本地查询（Room FTS/索引，不在内存全表遍历）；
 * - 本地无结果时可**在线搜索服务器**（OpenSubsonic search3，只返回歌曲）；
 * - 搜索历史：最近在前、去重、最多 10 条（DataStore），可一键清空；
 * - 服务器在线结果带查询词绑定 + 失败如实呈现（R15：不把网络失败伪装成空结果）。
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

    var query by rememberSaveable { mutableStateOf("") }
    /** 防抖后的查询词：输入停顿约 150ms 后才真正查询，避免逐键全量扫描。 */
    var debounced by remember { mutableStateOf("") }
    /** null = 当前防抖词尚未完成本地查询（显示进行中，不把旧词结果误当新词空结果）。 */
    var local by remember { mutableStateOf<SearchResults?>(SearchResults()) }
    var localError by remember { mutableStateOf<String?>(null) }

    // ---- 服务器在线搜索状态（Swift `serverSearchResults/isServerSearching/serverSearchQuery`）----
    var serverSongs by remember { mutableStateOf<List<Track>>(emptyList()) }
    var serverSearching by remember { mutableStateOf(false) }
    var serverQuery by remember { mutableStateOf("") }
    var serverError by remember { mutableStateOf<String?>(null) }

    val recents by graph.preferences.recentSearchesFlow.collectAsState(initial = emptyList())
    val activeRaw by graph.preferences.activeServerIdFlow.collectAsState(initial = null)
    val activeServer = activeRaw?.let { ServerId(it) }

    /** 新查询开始：服务器结果立即取消/清空（Swift `clearServerSearch`）。 */
    fun resetServerSearch() {
        serverSongs = emptyList()
        serverSearching = false
        serverQuery = ""
        serverError = null
    }

    /** 防抖：输入停顿 150ms 后才更新实际查询词；清空立即生效。 */
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

    /** 本地搜索：真正走 Room FTS/索引。词变或激活服务器变才重查。 */
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
            localError = e.message ?: "本地搜索失败"
            local = SearchResults()
        }
    }

    /** 「在线搜索服务器」：真实 search3，只在当前激活服务器上执行。 */
    fun runServerSearch() {
        val term = query.trim()
        if (term.isEmpty()) return
        val server = activeServer
        if (server == null) {
            serverQuery = term
            serverSongs = emptyList()
            serverError = "尚未连接服务器，无法在线搜索"
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
                    // R15：网络失败如实呈现（可重试），不伪装成「无结果」。
                    if (serverQuery == term) serverError = e.message ?: "在线搜索失败"
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
        // 顶栏（对齐 Swift NavigationStack inline「搜索音乐库」）。
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp),
        ) {
            IconButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart)) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = colors.primaryText)
            }
            Text(
                "搜索音乐库",
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
                .padding(bottom = AuralisSpacing.small),
        )

        when {
            query.isBlank() -> RecentSearchesContent(
                recents = recents,
                onPick = { term ->
                    query = term
                    debounced = term // 点击历史立即搜索（跳过防抖），对齐 Swift
                    recordSearch(term)
                },
                onClear = ::clearHistory,
                modifier = Modifier.weight(1f),
            )

            // 本地搜索进行中（防抖词已定但结果未回）。
            local == null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }

            localError != null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                SearchMessageCard(
                    icon = { Icon(Icons.Filled.Clear, contentDescription = null, tint = colors.secondaryText) },
                    title = "本地搜索失败",
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
                            Text("正在服务器搜索…", style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                        }

                        !hasServerSongs -> {
                            SearchMessageCard(
                                icon = { Icon(Icons.Filled.Search, contentDescription = null, tint = colors.secondaryText) },
                                title = "本地没有匹配结果",
                                message = "本地持久化资料库中没有同时匹配歌曲、专辑、艺术家或歌单的内容。可以尝试在服务器上在线搜索。",
                                actionLabel = "清除搜索",
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
                                Text("在线搜索服务器")
                            }
                        }

                        else -> LocalResultList(
                            results = SearchResults(songs = serverSongs),
                            serverSectionTitle = "服务器在线结果",
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

// ================================================================== 搜索框

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
            .clip(RoundedCornerShape(AuralisRadius.medium))
            .background(colors.surface)
            .padding(horizontal = AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = colors.secondaryText)
        Box(Modifier.weight(1f).padding(horizontal = AuralisSpacing.medium)) {
            if (query.isEmpty()) {
                Text(
                    "歌曲、专辑、艺术家或歌单",
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
            IconButton(onClick = onClear, modifier = Modifier.size(36.dp)) {
                Icon(Icons.Filled.Clear, contentDescription = "清除搜索", tint = colors.secondaryText)
            }
        }
    }
}

// ================================================================== 搜索历史

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
        Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            SearchMessageCard(
                icon = {
                    Icon(
                        Icons.Filled.Search,
                        contentDescription = null,
                        tint = colors.secondaryText,
                        modifier = Modifier.size(44.dp),
                    )
                },
                title = "搜索你的音乐库",
                message = "输入歌曲、专辑、艺术家或歌单名称，Auralis 会在本地持久化资料库中匹配（离线可用）。",
            )
        }
        return
    }
    LazyColumn(modifier = modifier.fillMaxWidth()) {
        item(key = "history-header") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = AuralisSpacing.large, bottom = AuralisSpacing.small),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "最近搜索",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.primaryText,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onClear) {
                    Text("清除", style = MaterialTheme.typography.labelMedium, color = colors.accent)
                }
            }
            HorizontalDivider(color = colors.separator)
        }
        item(key = "history-chips") {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
                modifier = Modifier.padding(top = AuralisSpacing.medium),
            ) {
                recents.forEach { term ->
                    Surface(
                        shape = RoundedCornerShape(AuralisRadius.small),
                        color = colors.surface,
                        modifier = Modifier.clip(RoundedCornerShape(AuralisRadius.small)),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clickable { onPick(term) }
                                .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
                        ) {
                            Icon(Icons.Filled.History, contentDescription = null, tint = colors.secondaryText, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(
                                term,
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.primaryText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.widthIn(max = 220.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

// ================================================================== 结果列表

/** 本地四类结果列表；服务器在线结果为空壳时仅渲染歌曲段。 */
@Composable
private fun LocalResultList(
    results: SearchResults,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    modifier: Modifier = Modifier,
    serverSectionTitle: String? = null,
) {
    LazyColumn(modifier = modifier.fillMaxWidth()) {
        if (results.songs.isNotEmpty()) {
            item(key = "header-songs") {
                SearchSectionHeader(serverSectionTitle ?: "歌曲")
            }
            items(count = results.songs.size, key = { index -> "song-${results.songs[index].globalId.serialized}" }) { index ->
                val track = results.songs[index]
                // 对齐 Swift：搜索结果点歌 = selectAndPlay(track) 单曲播放
                // （组上下文由专辑/歌单详情页承载），不把整个搜索结果排成队列。
                SearchTrackRow(
                    track = track,
                    onClick = { onPlayTracks(listOf(track), 0) },
                )
            }
        }
        if (results.albums.isNotEmpty()) {
            item(key = "header-albums") {
                SearchSectionHeader("专辑")
            }
            items(count = results.albums.size, key = { index -> "album-${results.albums[index].globalId.serialized}" }) { index ->
                val album = results.albums[index]
                SearchAlbumRow(album = album, onClick = { onBrowse(BrowseDestination.Album(album.globalId)) })
            }
        }
        if (results.artists.isNotEmpty()) {
            item(key = "header-artists") {
                SearchSectionHeader("艺术家")
            }
            items(count = results.artists.size, key = { index -> "artist-${results.artists[index].globalId.serialized}" }) { index ->
                val artist = results.artists[index]
                SearchArtistRow(artist = artist, onClick = { onBrowse(BrowseDestination.Artist(artist.globalId)) })
            }
        }
        if (results.playlists.isNotEmpty()) {
            item(key = "header-playlists") {
                SearchSectionHeader("歌单")
            }
            items(count = results.playlists.size, key = { index -> "playlist-${results.playlists[index].globalId.serialized}" }) { index ->
                val playlist = results.playlists[index]
                SearchPlaylistRow(playlist = playlist, onClick = { onBrowse(BrowseDestination.Playlist(playlist.globalId)) })
            }
        }
    }
}

// ================================================================== 空态卡片

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
