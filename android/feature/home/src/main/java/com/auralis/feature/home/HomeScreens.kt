package com.auralis.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork
import kotlinx.coroutines.launch

/**
 * 首页（对齐 Apple `HomeView`）：
 * - 快捷入口 3 列（icon + 数量），点击进入对应浏览列表；
 * - 内容模块：模块标题行 + 横向卡片货架（固定 140dp 卡片，不拉伸）；
 * - 「换一批」= 本地重采样（SQL RANDOM，不发网络）；「数量 ›」进入完整列表；
 * - 底部资料库统计四项。
 */
@Composable
fun HomeScreen(
    graph: AuralisGraph,
    onPlayTracks: (tracks: List<Track>, startIndex: Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    onManageServers: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val state = remember(graph) { HomeState(scope, graph) }

    LaunchedEffect(state) { state.start() }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        HomeHeader(serverName = state.serverName, onManageServers = onManageServers)
        HorizontalDivider(color = colors.separator)

        when {
            !state.loaded -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }

            !state.hasServer -> NoServerHome(onManageServers)

            state.lastError != null -> HomeError(message = state.lastError.orEmpty(), onRetry = { state.reload() })

            state.quickModules.isEmpty() && state.contentModules.isEmpty() && !state.refreshing ->
                EmptyLibraryHome(onManageServers)

            else -> HomeContent(
                state = state,
                onPlayTracks = onPlayTracks,
                onBrowse = onBrowse,
            )
        }
    }
}

@Composable
private fun HomeHeader(serverName: String?, onManageServers: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("首页", style = MaterialTheme.typography.headlineMedium, color = colors.primaryText)
            if (serverName != null) {
                Text(serverName, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
        }
        // 服务器入口（与 S2 摘要卡等价：真实跳转服务器管理）。
        IconButton(onClick = onManageServers) {
            Icon(Icons.Filled.Add, contentDescription = "管理服务器", tint = colors.primaryText)
        }
    }
}

@Composable
private fun HomeContent(
    state: HomeState,
    onPlayTracks: (tracks: List<Track>, startIndex: Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = AuralisSpacing.large,
            end = AuralisSpacing.large,
            top = AuralisSpacing.medium,
            bottom = AuralisChrome.dockHeight + AuralisChrome.dockBottomPadding + AuralisSpacing.xLarge,
        ),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xLarge),
    ) {
        if (state.quickModules.isNotEmpty()) {
            item(key = "quick") {
                QuickEntriesGrid(
                    modules = state.quickModules,
                    onOpen = { entry ->
                        onBrowse(
                            when (entry.id) {
                                com.auralis.core.domain.HomeQuickEntry.Playlists -> BrowseDestination.Playlists
                                com.auralis.core.domain.HomeQuickEntry.Favorites -> BrowseDestination.Favorites
                                com.auralis.core.domain.HomeQuickEntry.MostPlayed -> BrowseDestination.MostPlayed
                            },
                        )
                    },
                )
            }
        }
        items(state.contentModules, key = { "module-${it.id.name}" }) { module ->
            HomeModuleSection(
                module = module,
                onPlayTracks = onPlayTracks,
                onBrowse = onBrowse,
                onReshuffle = { state.reshuffle(module.id) },
            )
        }
        item(key = "stats") {
            LibrarySummaryCard(stats = state.stats)
        }
    }
}

/** 快捷入口：一行最多 3 个，图标 + 数量（不显示长标题，避免截断）。 */
@Composable
private fun QuickEntriesGrid(
    modules: List<QuickEntryModule>,
    onOpen: (QuickEntryModule) -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
    ) {
        modules.take(3).forEach { module ->
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(AuralisRadius.medium))
                    .background(colors.surface)
                    .clickable { onOpen(module) }
                    .padding(vertical = AuralisSpacing.medium),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
            ) {
                Icon(
                    module.id.icon,
                    contentDescription = module.id.titleZh,
                    tint = colors.accent,
                    modifier = Modifier.size(26.dp),
                )
                Text(
                    "${module.count}",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.primaryText,
                    maxLines = 1,
                )
            }
        }
    }
}

/** 内容模块：模块标题行 + 横向货架。 */
@Composable
private fun HomeModuleSection(
    module: HomeModuleSnapshot,
    onPlayTracks: (tracks: List<Track>, startIndex: Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    onReshuffle: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium)) {
        ModuleHeader(module = module, onBrowse = onBrowse, onReshuffle = onReshuffle)
        when {
            module.tracks.isNotEmpty() -> TrackShelf(
                module = module,
                onPlayTracks = onPlayTracks,
            )

            module.artists.isNotEmpty() -> ArtistShelf(
                artists = module.artists,
                onOpen = { artist -> onBrowse(BrowseDestination.Artist(artist.globalId)) },
            )

            module.albums.isNotEmpty() -> AlbumShelf(
                albums = module.albums,
                onOpen = { album -> onBrowse(BrowseDestination.Album(album.globalId)) },
            )
        }
    }
}

/** 模块标题行：左标题；右侧「换一批」（random/favoriteRandom）或「数量 ›」。 */
@Composable
private fun ModuleHeader(
    module: HomeModuleSnapshot,
    onBrowse: (BrowseDestination) -> Unit,
    onReshuffle: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            module.id.titleZh,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            color = colors.primaryText,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (module.id.supportsReshuffle) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(AuralisRadius.small))
                    .clickable(onClick = onReshuffle)
                    .padding(horizontal = AuralisSpacing.small, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = null,
                    tint = colors.secondaryText,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(2.dp))
                Text(
                    "换一批",
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.secondaryText,
                )
            }
        }
        val countLabel = moduleCountLabel(module)
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(AuralisRadius.small))
                .clickable(onClick = { onBrowse(module.id.toBrowseDestination()) })
                .padding(horizontal = AuralisSpacing.small, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                countLabel,
                style = MaterialTheme.typography.labelMedium,
                color = colors.secondaryText,
            )
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = colors.secondaryText,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

private fun moduleCountLabel(module: HomeModuleSnapshot): String = when {
    module.tracks.isNotEmpty() -> "${module.itemCount} 首"
    module.artists.isNotEmpty() -> "${module.itemCount} 位艺人"
    else -> "${module.itemCount} 张专辑"
}

private fun HomeModuleId.toBrowseDestination(): BrowseDestination = when (this) {
    HomeModuleId.RandomSongs -> BrowseDestination.Random
    HomeModuleId.RecentlyPlayed -> BrowseDestination.RecentlyPlayed
    HomeModuleId.RecentlyAdded -> BrowseDestination.RecentlyAdded
    HomeModuleId.LongUnplayed -> BrowseDestination.LongUnplayed
    HomeModuleId.NeverPlayed -> BrowseDestination.NeverPlayed
    HomeModuleId.FavoriteRandom -> BrowseDestination.FavoriteRandom
    HomeModuleId.Downloads -> BrowseDestination.Downloads
    HomeModuleId.TopArtists -> BrowseDestination.TopArtists
    HomeModuleId.TopAlbums -> BrowseDestination.TopAlbums
}

/** 歌曲横向货架。点卡片 = 把整个货架设为队列并播放点中的那首。 */
@Composable
private fun TrackShelf(
    module: HomeModuleSnapshot,
    onPlayTracks: (tracks: List<Track>, startIndex: Int) -> Unit,
) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing)) {
        items(module.tracks, key = { it.globalId.serialized }) { track ->
            val index = module.tracks.indexOfFirst { it.globalId.serialized == track.globalId.serialized }
            HomeTrackCard(
                track = track,
                onClick = { onPlayTracks(module.tracks, index.coerceAtLeast(0)) },
            )
        }
    }
}

/** 常听艺术家横向货架（点卡片进入艺术家详情）。 */
@Composable
private fun ArtistShelf(
    artists: List<Pair<Artist, Int>>,
    onOpen: (Artist) -> Unit,
) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing)) {
        items(artists, key = { it.first.globalId.serialized }) { (artist, playCount) ->
            HomeArtistCard(artist = artist, playCount = playCount, onClick = { onOpen(artist) })
        }
    }
}

/** 常听专辑横向货架（点卡片进入专辑详情）。 */
@Composable
private fun AlbumShelf(
    albums: List<Pair<Album, Int>>,
    onOpen: (Album) -> Unit,
) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing)) {
        items(albums, key = { it.first.globalId.serialized }) { (album, playCount) ->
            HomeAlbumCard(album = album, playCount = playCount, onClick = { onOpen(album) })
        }
    }
}

/** 统一歌曲卡：封面方形 + 标题/艺术家各一行尾部截断。宽度固定 140dp。 */
@Composable
private fun HomeTrackCard(
    track: Track,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .width(AuralisChrome.homeCardWidth)
            .clip(RoundedCornerShape(AuralisRadius.artwork))
            .clickable(onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardTextSpacing),
    ) {
        AuralisArtwork(
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            contentDescription = track.albumTitle,
            titleForFallback = track.albumTitle,
            targetSizeDp = AuralisChrome.homeCardWidth.value.toInt(),
            shape = RoundedCornerShape(AuralisRadius.artwork),
            modifier = Modifier.size(AuralisChrome.homeCardWidth),
        )
        Text(
            track.title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.primaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.height(AuralisChrome.homeCardTitleHeight),
        )
        Text(
            track.artistName,
            style = MaterialTheme.typography.bodySmall,
            color = colors.secondaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 常听艺术家卡：副标题显示真实播放次数。 */
@Composable
private fun HomeArtistCard(
    artist: Artist,
    playCount: Int,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .width(AuralisChrome.homeCardWidth)
            .clip(RoundedCornerShape(AuralisRadius.artwork))
            .clickable(onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardTextSpacing),
    ) {
        AuralisArtwork(
            serverId = artist.serverId,
            artworkKey = artist.artworkKey,
            contentDescription = artist.name,
            titleForFallback = artist.name,
            targetSizeDp = AuralisChrome.homeCardWidth.value.toInt(),
            shape = RoundedCornerShape(AuralisRadius.artwork),
            modifier = Modifier.size(AuralisChrome.homeCardWidth),
        )
        Text(
            artist.name,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.primaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.height(AuralisChrome.homeCardTitleHeight),
        )
        Text(
            "播放 $playCount 次",
            style = MaterialTheme.typography.bodySmall,
            color = colors.secondaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 常听专辑卡：副标题显示真实播放次数。 */
@Composable
private fun HomeAlbumCard(
    album: Album,
    playCount: Int,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .width(AuralisChrome.homeCardWidth)
            .clip(RoundedCornerShape(AuralisRadius.artwork))
            .clickable(onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardTextSpacing),
    ) {
        AuralisArtwork(
            serverId = album.serverId,
            artworkKey = album.artworkKey,
            contentDescription = album.title,
            titleForFallback = album.title,
            targetSizeDp = AuralisChrome.homeCardWidth.value.toInt(),
            shape = RoundedCornerShape(AuralisRadius.artwork),
            modifier = Modifier.size(AuralisChrome.homeCardWidth),
        )
        Text(
            album.title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.primaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.height(AuralisChrome.homeCardTitleHeight),
        )
        Text(
            "播放 $playCount 次",
            style = MaterialTheme.typography.bodySmall,
            color = colors.secondaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 资料库统计四项（艺术家/专辑/歌曲/歌单）。 */
@Composable
private fun LibrarySummaryCard(stats: com.auralis.core.domain.LibraryStats) {
    val colors = LocalAuralisTheme.current.colors
    val entries = listOf(
        stats.artistCount to "艺术家",
        stats.albumCount to "专辑",
        stats.trackCount to "歌曲",
        stats.playlistCount to "歌单",
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        entries.forEach { (value, label) ->
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(AuralisRadius.medium))
                    .background(colors.surface)
                    .padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.medium),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    "$value",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = colors.primaryText,
                    maxLines = 1,
                )
                Text(
                    label,
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.secondaryText,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun NoServerHome(onManageServers: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(AuralisSpacing.large),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
    ) {
        Text("尚未连接服务器", style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
        Text(
            "连接 OpenSubsonic 服务器后，你的音乐库会出现在这里。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
        Button(onClick = onManageServers) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(AuralisSpacing.small))
            Text("添加服务器")
        }
    }
}

@Composable
private fun EmptyLibraryHome(onManageServers: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(AuralisSpacing.large),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        Text("音乐库还是空的", style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
        Text(
            "同步完成后，首页模块会自动出现（打开你不需要的模块可去 设置 → 首页布局 调整）。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
    }
}

@Composable
private fun HomeError(message: String, onRetry: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(AuralisSpacing.large),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
    ) {
        Text("加载失败", style = MaterialTheme.typography.titleMedium, color = colors.error)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
        Button(onClick = onRetry) { Text("重试") }
    }
}
