package com.auralis.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.Genre
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlinx.coroutines.launch

/**
 * 资料库（对齐 Swift `LibraryView.swift`，S4）。
 *
 * - 顶部分段 7 scope（专辑/歌曲/艺术家/歌单/收藏/流派/分类），默认专辑；
 *   「分类」数据源为 AI 推荐索引库（Android 第一版未迁移）→ 展示能力说明，不拿假数据。
 * - 各 scope 数据全部真实：专辑/歌曲/艺术家/歌单/流派 = Room 观察流；
 *   收藏 = favorites 表观察流；下载徽标/菜单态 = downloads 表逐行观察。
 * - 点行 = 当前列表作新队列从该行起播；点专辑/艺术家/歌单卡 = 打开 Browse 详情；
 *   Swift contextMenu 长按 → Android 行尾/卡角 ⋯ 菜单，菜单项动作全部真实
 *   （播放/下一首/加入队列/添加到歌单/下载·取消·删缓存/收藏切换）。
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
                .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("音乐库", style = MaterialTheme.typography.headlineMedium, color = colors.primaryText, modifier = Modifier.weight(1f))
            IconButton(onClick = onOpenSettings) {
                Icon(Icons.Filled.Settings, contentDescription = "设置", tint = colors.primaryText)
            }
        }
        ScopeSelector(selected = scope, onSelect = { scope = it })
        HorizontalDivider(color = colors.separator)
        Box(Modifier.fillMaxSize()) {
            when (scope) {
                LibraryScope.Albums -> AlbumScope(graph, serverId, onPlayTracks, onBrowse)
                LibraryScope.Tracks -> TracksOrFavoritesScope(graph, serverId, isFavorites = false, onPlayTracks, onPlayNext, onAppendToQueue)
                LibraryScope.Artists -> ArtistScope(graph, serverId, onPlayTracks, onBrowse)
                LibraryScope.Playlists -> PlaylistScope(graph, serverId, onBrowse)
                LibraryScope.Favorites -> TracksOrFavoritesScope(graph, serverId, isFavorites = true, onPlayTracks, onPlayNext, onAppendToQueue)
                LibraryScope.Genres -> GenreScope(graph, serverId, onBrowse)
                LibraryScope.Categories -> CategoryScope()
            }
        }
    }
}

/** 分段选择（横向滚动胶囊，近似 Swift segmented picker）。 */
@Composable
private fun ScopeSelector(selected: LibraryScope, onSelect: (LibraryScope) -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        LibraryScope.entries.forEach { item ->
            val isSelected = item == selected
            androidx.compose.material3.Surface(
                color = if (isSelected) colors.accent.copy(alpha = 0.16f) else colors.surface,
                shape = RoundedCornerShape(50),
                onClick = { onSelect(item) },
            ) {
                Text(
                    item.titleZh,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (isSelected) colors.accent else colors.primaryText,
                    modifier = Modifier.padding(horizontal = AuralisSpacing.medium, vertical = 6.dp),
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
) {
    if (serverId == null) return ServerPrompt()
    val albums by remember(serverId) { graph.catalogRepository.observeAlbums(serverId) }.collectAsState(initial = null)
    when {
        albums == null -> LibraryLoadingBox("正在加载专辑…")
        albums!!.isEmpty() -> LibraryEmptyState("还没有专辑", "当前资料库暂无专辑，可能需要同步或扫描音乐库。")
        else -> AlbumGrid(graph, albums!!, onPlayTracks, onBrowse)
    }
}

@Composable
private fun ArtistScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
) {
    if (serverId == null) return ServerPrompt()
    val artists by remember(serverId) { graph.catalogRepository.observeArtists(serverId) }.collectAsState(initial = null)
    when {
        artists == null -> LibraryLoadingBox("正在加载艺术家…")
        artists!!.isEmpty() -> LibraryEmptyState("还没有艺术家", "当前资料库暂无艺术家，可能需要同步或扫描音乐库。")
        else -> ArtistRows(graph, artists!!, onPlayTracks, onBrowse)
    }
}

@Composable
private fun PlaylistScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onBrowse: (BrowseDestination) -> Unit,
) {
    if (serverId == null) return ServerPrompt()
    val playlists by remember(serverId) { graph.catalogRepository.observePlaylists(serverId) }.collectAsState(initial = null)
    when {
        playlists == null -> LibraryLoadingBox("正在加载歌单…")
        playlists!!.isEmpty() -> LibraryEmptyState("还没有歌单", "在服务器上创建歌单后，这里会列出所有歌单。")
        else -> PlaylistGrid(playlists!!, onBrowse)
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
) {
    if (serverId == null) return ServerPrompt()
    val repo = graph.catalogRepository
    val source = remember(serverId, isFavorites) {
        if (isFavorites) repo.observeFavoriteTracks(serverId) else repo.observeTracks(serverId)
    }
    val tracks by source.collectAsState(initial = null)
    when {
        tracks == null -> LibraryLoadingBox(if (isFavorites) "正在加载收藏…" else "正在加载歌曲…")
        tracks!!.isEmpty() -> if (isFavorites) {
            LibraryEmptyState("还没有收藏", "在播放页或歌曲菜单中点心形收藏后，会出现在这里。")
        } else {
            LibraryEmptyState(
                "资料库还没有歌曲",
                "连接服务器并同步后，这里会列出全部歌曲；也可以从「首页」先随机播放几首。",
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
        )
    }
}

@Composable
private fun GenreScope(
    graph: AuralisGraph,
    serverId: ServerId?,
    onBrowse: (BrowseDestination) -> Unit,
) {
    if (serverId == null) return ServerPrompt()
    val repo = graph.catalogRepository
    val genres by remember(serverId) { repo.observeGenres(serverId) }.collectAsState(initial = null)
    val scope = rememberCoroutineScope()
    when {
        genres == null -> LibraryLoadingBox("正在加载流派…")
        genres!!.isEmpty() -> LibraryEmptyState(
            "还没有流派",
            "服务器返回的流派（来自音乐文件内嵌标签）会显示在这里；连接并同步后即可按流派浏览。",
            actionLabel = "从服务器刷新流派",
            onAction = {
                scope.launch {
                    val client = graph.registry.client(serverId)
                    val remote = runCatching { client?.genres() }.getOrNull().orEmpty()
                    if (remote.isNotEmpty()) repo.mergeGenres(serverId, remote)
                }
            },
        )
        else -> GenreGrid(genres!!, serverId, onBrowse)
    }
}

@Composable
private fun CategoryScope() {
    LibraryEmptyState("分类（AI 推荐索引）", com.auralis.core.domain.Categories.NOT_PORTED_MESSAGE)
}

@Composable
private fun ServerPrompt() {
    LibraryEmptyState("还没有连接服务器", "请在「设置 → 服务器」中添加并同步音乐服务器后浏览资料库。")
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
) {
    LazyColumn(modifier = Modifier.fillMaxSize()) {
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
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(AuralisChrome.albumGridMin),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
        modifier = Modifier.fillMaxSize().padding(horizontal = AuralisSpacing.large),
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
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.primaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = AuralisSpacing.xSmall),
            )
            Text(
                album.artistName,
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = { menuOpen = true }, modifier = Modifier.align(Alignment.TopEnd)) {
            Icon(Icons.Filled.MoreVert, contentDescription = "专辑操作", tint = colors.secondaryText)
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text("播放全部") },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val tracks = runCatching { repo.albumTracks(album.globalId) }.getOrDefault(emptyList())
                        busy = false
                        if (tracks.isEmpty()) message = "这张专辑暂无本地歌曲" else onPlayTracks(tracks, 0)
                    }
                },
            )
            DropdownMenuItem(
                text = { Text(if (isFavorite) "取消收藏" else "收藏专辑") },
                leadingIcon = { Icon(if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null) },
                onClick = {
                    menuOpen = false
                    scope.launch {
                        runCatching { graph.libraryActions.toggleAlbumFavorite(album) }
                            .onFailure { message = "收藏操作失败：${it.message}" }
                    }
                },
            )
            DropdownMenuItem(
                text = { Text("下载专辑") },
                leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val tracks = runCatching { repo.albumTracks(album.globalId) }.getOrDefault(emptyList())
                        busy = false
                        if (tracks.isEmpty()) {
                            message = "这张专辑暂无本地歌曲"
                        } else {
                            runCatching { tracks.forEach { graph.downloadManager.enqueue(it) } }
                                .onFailure { message = "下载失败：${it.message}" }
                                .onSuccess { message = "已开始下载 ${tracks.size} 首歌曲" }
                        }
                    }
                },
            )
        }
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text("知道了") } },
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
) {
    LazyColumn(modifier = Modifier.fillMaxSize()) {
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
            Text("${artist.albumCount} 张专辑", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
        }
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = "艺术家操作", tint = colors.secondaryText)
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text("播放全部") },
                    leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
                    enabled = !busy,
                    onClick = {
                        menuOpen = false
                        busy = true
                        scope.launch {
                            val tracks = runCatching { repo.artistTracks(artist.globalId) }.getOrDefault(emptyList())
                            busy = false
                            if (tracks.isEmpty()) message = "该艺术家暂无本地歌曲" else onPlayTracks(tracks, 0)
                        }
                    },
                )
                DropdownMenuItem(
                    text = { Text(if (isFavorite) "取消收藏" else "收藏艺术家") },
                    leadingIcon = { Icon(if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null) },
                    onClick = {
                        menuOpen = false
                        scope.launch {
                            runCatching { graph.libraryActions.toggleArtistFavorite(artist) }
                                .onFailure { message = "收藏操作失败：${it.message}" }
                        }
                    },
                )
                DropdownMenuItem(
                    text = { Text("下载全部") },
                    leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                    enabled = !busy,
                    onClick = {
                        menuOpen = false
                        busy = true
                        scope.launch {
                            val tracks = runCatching { repo.artistTracks(artist.globalId) }.getOrDefault(emptyList())
                            busy = false
                            if (tracks.isEmpty()) {
                                message = "该艺术家暂无本地歌曲"
                            } else {
                                runCatching { tracks.forEach { graph.downloadManager.enqueue(it) } }
                                    .onFailure { message = "下载失败：${it.message}" }
                                    .onSuccess { message = "已开始下载 ${tracks.size} 首歌曲" }
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
            confirmButton = { TextButton(onClick = { message = null }) { Text("知道了") } },
            text = { Text(it) },
        )
    }
}

/** 歌单栅格：点击卡片进入歌单详情（BrowseDestination.Playlist）。 */
@Composable
private fun PlaylistGrid(
    playlists: List<Playlist>,
    onBrowse: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    LazyVerticalGrid(
        columns = GridCells.Adaptive(AuralisChrome.albumGridMin),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
        modifier = Modifier.fillMaxSize().padding(horizontal = AuralisSpacing.large),
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
                    style = MaterialTheme.typography.bodyMedium,
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
) {
    val colors = LocalAuralisTheme.current.colors
    LazyVerticalGrid(
        columns = GridCells.Adaptive(AuralisChrome.genreGridMin),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        modifier = Modifier.fillMaxSize().padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.medium),
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
                Text("${genre.songCount} 首", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
        }
    }
}
