package com.auralis.feature.library

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
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * 浏览详情（对齐 Swift `BrowseDetailSheet` + `PlaylistTracksView`，S4）。
 *
 * - 顶部返回 + 标题 + 右上动作（random/favoriteRandom「换一批」；Playlist 详情歌单管理）。
 * - 列表型目的地（album/artist/favorites/mostPlayed/random/recentlyPlayed/
 *   recentlyAdded/longUnplayed/neverPlayed/favoriteRandom/downloads/genre/
 *   playlist/album detail…）→ 88 头图 + 标题/副标题 + 「播放全部」「下载」（确认弹窗）
 *   + 歌曲清单（点行 = 整组作队列从该行起播）。
 * - `.playlists` → 歌单总览（排序 + 单行删除二次确认；批量删除为后续迭代）。
 * - `.topArtists/.topAlbums` → 按真实播放次数列表，点行推入对应详情（内部返回栈）。
 * - 数据只来自真实本地目录/服务器刷新；失败展示错误与重试，不伪造数据。
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
    // 内部返回栈：topArtists/topAlbums/歌单总览 行点击 → 推入专辑/艺术家/歌单详情。
    var stack by remember { mutableStateOf(listOf(initial)) }
    val current = stack.last()
    val popOrBack = {
        if (stack.size > 1) stack = stack.dropLast(1) else onBack()
    }
    // 随机类目的地「换一批」与实体名标题（由内容加载完成后上抛）提升到壳层。
    var detailReloadKey by remember { mutableStateOf(0) }
    var titleOverride by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(stack) { titleOverride = null }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        // 顶栏
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = popOrBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = colors.primaryText)
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
                    Icon(Icons.Filled.Refresh, contentDescription = "换一批", tint = colors.accent)
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
                    onOpenNested = { stack = stack + it },
                )
            }
        }
    }
}

/** 分派标题（对齐 Swift `BrowseDetailSheet.title`）。 */
internal fun destinationTitle(destination: BrowseDestination): String = when (destination) {
    is BrowseDestination.Album -> "专辑"
    is BrowseDestination.Artist -> "艺术家"
    is BrowseDestination.Playlist -> "歌单"
    BrowseDestination.Playlists -> "歌单"
    BrowseDestination.Favorites -> "收藏"
    BrowseDestination.MostPlayed -> "最常听"
    is BrowseDestination.Genre -> "流派：${destination.name}"
    is BrowseDestination.RecommendationCategory -> "推荐分类"
    BrowseDestination.Random -> "随机音乐"
    BrowseDestination.RecentlyPlayed -> "最近播放"
    BrowseDestination.RecentlyAdded -> "最近添加"
    BrowseDestination.LongUnplayed -> "很久没听"
    BrowseDestination.FavoriteRandom -> "收藏里随便听"
    BrowseDestination.NeverPlayed -> "从未播放"
    BrowseDestination.TopArtists -> "常听艺术家"
    BrowseDestination.TopAlbums -> "常听专辑"
    BrowseDestination.Downloads -> "下载"
}

// ================================================================ 通用列表内容

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
private suspend fun loadDetail(graph: AuralisGraph, destination: BrowseDestination): DetailLoad {
    val repo = graph.catalogRepository
    // 目的地未显式带服务器时，落到当前激活服务器（多服务器隔离：绝不跨服务器合并）。
    val active = graph.preferences.activeServerIdFlow.first()?.let { ServerId(it) }
    fun sid() = destination.serverIdOf() ?: active
    return try {
        when (destination) {
            is BrowseDestination.Album -> {
                val album = repo.album(destination.albumId) ?: return DetailLoad.Error("找不到这张专辑")
                DetailLoad.Ready(
                    tracks = repo.albumTracks(destination.albumId),
                    headerArtworkKey = album.artworkKey,
                    headerTitle = album.title,
                    headerSubtitle = "${album.artistName} · ${album.songCount ?: 0} 首",
                )
            }
            is BrowseDestination.Artist -> {
                val artist = repo.artist(destination.artistId) ?: return DetailLoad.Error("找不到这位艺术家")
                val tracks = repo.artistTracks(destination.artistId)
                DetailLoad.Ready(
                    tracks = tracks,
                    headerArtworkKey = artist.artworkKey,
                    headerTitle = artist.name,
                    headerSubtitle = "${tracks.size} 首歌曲",
                )
            }
            is BrowseDestination.Playlist -> {
                val local = repo.playlist(destination.playlistId)
                    ?: return DetailLoad.Error("找不到这个歌单")
                val remote = try {
                    graph.playlistActions.refreshPlaylist(local)
                } catch (t: Throwable) {
                    null // 离线/失败：仍展示本地已有曲目（若为空则错误态带重试）
                }
                val refreshed = remote ?: local
                val tracks = repo.playlistTracks(refreshed.globalId)
                if (tracks.isEmpty() && remote == null) {
                    DetailLoad.Error("歌单内容加载失败，请检查网络后重试")
                } else {
                    DetailLoad.Ready(
                        tracks = tracks,
                        headerTitle = refreshed.name,
                        headerSubtitle = refreshed.comment ?: "${tracks.size} 首歌曲",
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
            // AI 推荐索引未迁移：能力说明（空态文案承接），不伪造数据。
            is BrowseDestination.RecommendationCategory -> DetailLoad.Ready(emptyList())
            // 其余目的地由上层（总览/列表）处理，不进详情。
            BrowseDestination.Playlists,
            BrowseDestination.TopArtists,
            BrowseDestination.TopAlbums,
            -> DetailLoad.Ready(emptyList())
        }
    } catch (t: Throwable) {
        DetailLoad.Error("加载失败：${t.message}")
    }
}

/** 服务器归属：多数列表目的地的 serverId 为空 → 以 active 服务器解析。 */
private fun BrowseDestination.serverIdOf(): ServerId? = when (this) {
    is BrowseDestination.Genre -> serverId
    else -> null
}

/** 曲目列表详情（含头图 + 播放全部 + 下载确认）。 */
@Composable
private fun DetailTrackContent(
    graph: AuralisGraph,
    destination: BrowseDestination,
    reloadKey: Int,
    onTitleReady: (String) -> Unit,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onPlayNext: (List<Track>) -> Unit,
    onAppendToQueue: (List<Track>) -> Unit,
    onOpenNested: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    var load by remember(destination) { mutableStateOf<DetailLoad>(DetailLoad.Loading) }
    var localReload by remember { mutableStateOf(0) }
    val effectiveReload = reloadKey + localReload
    LaunchedEffect(destination, effectiveReload) {
        load = DetailLoad.Loading
        val result = loadDetail(graph, destination)
        load = result
        if (result is DetailLoad.Ready && result.headerTitle != null) {
            onTitleReady(result.headerTitle)
        }
    }
    val serverId = rememberActiveServerId(graph)

    when (val state = load) {
        DetailLoad.Loading -> LibraryLoadingBox("正在加载…")
        is DetailLoad.Error -> LibraryEmptyState(
            "无法加载",
            state.message,
            actionLabel = "重试",
            onAction = { localReload += 1 },
        )
        is DetailLoad.Ready -> when {
            // AI 推荐索引：第一版未迁移，展示能力说明（不伪造数据、不给无意义重试）。
            destination is BrowseDestination.RecommendationCategory ->
                LibraryEmptyState("AI 推荐索引", emptyMessage(destination))
            state.tracks.isEmpty() -> LibraryEmptyState("暂无歌曲", emptyMessage(destination))
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
    BrowseDestination.Favorites -> "在播放页或歌曲菜单中点心形收藏后，会出现在这里。"
    BrowseDestination.MostPlayed -> "播放过的歌曲会按次数统计在这里。"
    BrowseDestination.LongUnplayed -> "播放过的歌曲会先出现在「最近播放」，过一段时间没听就会回到这里。"
    BrowseDestination.NeverPlayed -> "还没有播放记录时，这里暂时为空。"
    BrowseDestination.FavoriteRandom -> "收藏里的歌曲会随机出现在这里。"
    BrowseDestination.Downloads -> "下载到本地的歌曲会出现在这里。"
    is BrowseDestination.Genre -> "这个流派里暂时没有歌曲。"
    BrowseDestination.Random -> "随机音乐里暂时没有歌曲。"
    is BrowseDestination.Playlist -> "服务器上这个歌单里还没有添加歌曲。"
    is BrowseDestination.RecommendationCategory -> com.auralis.core.domain.Categories.NOT_PORTED_MESSAGE
    else -> "这个清单里暂时没有歌曲。"
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
    var confirmingDownload by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    // 歌单详情行级「从歌单移除」：选中行 index + busy（弹窗确认后执行）。
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
                            Text("播放全部")
                        }
                        OutlinedButton(
                            onClick = { confirmingDownload = true },
                            enabled = load.tracks.isNotEmpty(),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AuralisSpacing.medium, vertical = 6.dp),
                        ) {
                            Icon(Icons.Filled.ArrowDownward, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text("下载")
                        }
                    }
                }
            }
        }
        item(key = "section") {
            Text(
                "歌曲",
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
                            text = { Text("从歌单移除") },
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

    // 「从歌单移除」二次确认（对齐 Swift removeFromPlaylist 守卫；远端先行）。
    if (playlistDestination != null) {
        removingIndex?.let { index ->
            AlertDialog(
                onDismissRequest = { if (!removingBusy) removingIndex = null },
                title = { Text("从歌单移除这首歌？") },
                text = { Text("歌曲会从歌单中移除，歌曲文件不会被删除。") },
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
                                    if (p == null) error("找不到歌单") else graph.playlistActions.removeAt(p, listOf(targetIndex))
                                }
                                    .onSuccess { onRemovedFromPlaylist?.invoke() }
                                    .onFailure { message = "移除失败：${it.message}" }
                                removingBusy = false
                            }
                        },
                    ) { Text(if (removingBusy) "移除中…" else "移除", color = colors.error) }
                },
                dismissButton = {
                    TextButton(enabled = !removingBusy, onClick = { removingIndex = null }) { Text("取消") }
                },
            )
        }
    }

    if (confirmingDownload) {
        val estimatedMb = ((load.tracks.size * 8) / 1024.0).toInt().coerceAtLeast(1)
        AlertDialog(
            onDismissRequest = { confirmingDownload = false },
            title = { Text("下载 ${load.tracks.size} 首歌曲？") },
            text = { Text("预计约 $estimatedMb MB，下载到本地后可离线播放。已下载的歌曲会自动跳过。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDownload = false
                        scope.launch {
                            runCatching { load.tracks.forEach { graph.downloadManager.enqueue(it) } }
                                .onFailure { message = "下载失败：${it.message}" }
                                .onSuccess { message = "已开始下载 ${load.tracks.size} 首歌曲" }
                        }
                    },
                ) { Text("开始下载") }
            },
            dismissButton = { TextButton(onClick = { confirmingDownload = false }) { Text("取消") } },
        )
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text("知道了") } },
            text = { Text(it) },
        )
    }
}

// ================================================================ 歌单总览与详情

/** 歌单总览（.playlists）：本地歌单列表 + 排序 + 单行删除（二次确认）。 */
@Composable
private fun PlaylistOverview(
    graph: AuralisGraph,
    push: (BrowseDestination) -> Unit,
) {
    val serverId = rememberActiveServerId(graph)
    val repo = graph.catalogRepository
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    var sort by remember { mutableStateOf(PlaylistSort.NameAscending) }
    var pendingDelete by remember { mutableStateOf<Playlist?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val playlists by remember(serverId) { repo.observePlaylists(serverId) }.collectAsState(initial = null)

    Column(Modifier.fillMaxSize()) {
        // 排序工具栏（对齐 Swift PlaylistSortOrder）。
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("${playlists?.size ?: 0} 个歌单", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, modifier = Modifier.weight(1f))
            Box {
                var sortMenu by remember { mutableStateOf(false) }
                IconButton(onClick = { sortMenu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "歌单排序", tint = colors.secondaryText)
                }
                DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                    PlaylistSort.entries.forEach { order ->
                        DropdownMenuItem(
                            text = { Text(order.titleZh) },
                            onClick = { sort = order; sortMenu = false },
                        )
                    }
                }
            }
        }
        HorizontalDivider(color = colors.separator)
        when {
            playlists == null -> LibraryLoadingBox("正在加载歌单…")
            playlists!!.isEmpty() -> LibraryEmptyState("还没有歌单", "在服务器上创建歌单后，这里会列出所有歌单。")
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
                                Icon(Icons.Filled.Delete, contentDescription = "删除歌单", tint = if (playlist.isReadOnly) colors.secondaryText.copy(alpha = 0.4f) else colors.secondaryText)
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
            title = { Text("删除歌单「${playlist.name}」？") },
            text = { Text("该歌单会同时从音乐服务器和本地目录删除，歌曲文件不会被删除。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        val target = playlist
                        pendingDelete = null
                        scope.launch {
                            runCatching { graph.playlistActions.delete(target) }
                                .onFailure { message = "无法删除歌单：${it.message}" }
                        }
                    },
                ) { Text("删除", color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("取消") } },
        )
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text("知道了") } },
            text = { Text(it) },
        )
    }
}

private enum class PlaylistSort(val titleZh: String) {
    NameAscending("名称（A 到 Z）"),
    NameDescending("名称（Z 到 A）"),
    RecentlyModified("最近修改"),
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
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val playlist by remember(destination.playlistId) { mutableStateOf<Playlist?>(null) }

    Box {
        IconButton(onClick = { menuOpen = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = "歌单操作", tint = colors.secondaryText)
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text("重命名") },
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
                text = { Text(if (busy) "复制中…" else "复制歌单") },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val p = graph.catalogRepository.playlist(destination.playlistId)
                        if (p == null) {
                            busy = false
                            message = "找不到歌单"
                        } else {
                            runCatching { graph.playlistActions.duplicate(p) }
                                .onFailure { message = "复制失败：${it.message}" }
                                .onSuccess { if (it == null) message = "复制失败：服务器未返回新歌单" else message = "已复制为「${it.name}」" }
                            busy = false
                        }
                    }
                },
            )
            DropdownMenuItem(
                text = { Text("去重歌曲") },
                enabled = !busy,
                onClick = {
                    menuOpen = false
                    busy = true
                    scope.launch {
                        val p = graph.catalogRepository.playlist(destination.playlistId)
                        if (p == null) {
                            busy = false
                            message = "找不到歌单"
                        } else {
                            runCatching { graph.playlistActions.removeDuplicateSongs(p) }
                                .onSuccess { removed ->
                                    message = if (removed) "已移除重复歌曲" else "没有重复歌曲"
                                    if (removed) onChanged()
                                }
                                .onFailure { message = "去重失败：${it.message}" }
                            busy = false
                        }
                    }
                },
            )
            HorizontalDivider(color = colors.separator)
            DropdownMenuItem(
                text = { Text("删除歌单") },
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
            title = { Text("重命名歌单") },
            text = {
                Column {
                    androidx.compose.material3.OutlinedTextField(
                        value = renameText,
                        onValueChange = { renameText = it },
                        label = { Text("歌单名称") },
                        singleLine = true,
                    )
                    Text("修改将同步到服务器。", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText, modifier = Modifier.padding(top = AuralisSpacing.small))
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
                                message = "找不到歌单"
                            } else {
                                runCatching { graph.playlistActions.rename(p, name) }
                                    .onSuccess { if (it) onChanged() }
                                    .onFailure { message = "重命名失败：${it.message}" }
                                busy = false
                            }
                        }
                    },
                ) { Text("保存") }
            },
            dismissButton = { TextButton(onClick = { renaming = false }) { Text("取消") } },
        )
    }
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("删除歌单？") },
            text = { Text("服务器上的歌单也会被删除，此操作不可撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDelete = false
                        busy = true
                        scope.launch {
                            val p = graph.catalogRepository.playlist(destination.playlistId)
                            if (p == null) {
                                busy = false
                                message = "找不到歌单"
                            } else {
                                runCatching { graph.playlistActions.delete(p) }
                                    .onFailure { busy = false; message = "无法删除歌单：${it.message}" }
                                    .onSuccess { busy = false; onDone(true) }
                            }
                        }
                    },
                ) { Text("删除", color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("取消") } },
        )
    }
    message?.let {
        AlertDialog(
            onDismissRequest = { message = null },
            confirmButton = { TextButton(onClick = { message = null }) { Text("知道了") } },
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
    val serverId = rememberActiveServerId(graph)
    var pairs by remember { mutableStateOf<List<Pair<Artist, Int>>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(serverId, reloadKey) {
        pairs = null
        error = null
        if (serverId == null) {
            error = "还没有连接服务器，无法统计常听艺术家"
        } else {
            runCatching { graph.catalogRepository.homeTopArtists(serverId, 500) }
                .onSuccess { pairs = it }
                .onFailure { error = "统计失败：${it.message}" }
        }
    }
    when {
        error != null -> LibraryEmptyState(
            "无法加载",
            error!!,
            actionLabel = "重试",
            onAction = { reloadKey += 1 },
        )
        pairs == null -> LibraryLoadingBox("正在统计常听艺术家…")
        pairs!!.isEmpty() -> LibraryEmptyState("暂无常听艺术家", "播放过的歌曲会按艺术家统计在这里。")
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
                        Text("$count 次播放", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
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
    val serverId = rememberActiveServerId(graph)
    var pairs by remember { mutableStateOf<List<Pair<Album, Int>>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(serverId, reloadKey) {
        pairs = null
        error = null
        if (serverId == null) {
            error = "还没有连接服务器，无法统计常听专辑"
        } else {
            runCatching { graph.catalogRepository.homeTopAlbums(serverId, 500) }
                .onSuccess { pairs = it }
                .onFailure { error = "统计失败：${it.message}" }
        }
    }
    when {
        error != null -> LibraryEmptyState(
            "无法加载",
            error!!,
            actionLabel = "重试",
            onAction = { reloadKey += 1 },
        )
        pairs == null -> LibraryLoadingBox("正在统计常听专辑…")
        pairs!!.isEmpty() -> LibraryEmptyState("暂无常听专辑", "播放过的歌曲会按专辑统计在这里。")
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
                        Text("$count 次播放", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                }
            }
        }
    }
}
