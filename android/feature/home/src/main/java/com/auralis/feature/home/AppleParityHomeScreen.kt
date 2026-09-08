// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.BrowseDestination
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.HomeQuickEntry
import com.auralis.core.domain.LibraryStats
import com.auralis.core.domain.Track
import com.auralis.core.image.AuralisArtwork

/**
 * Apple `HomeView.swift` 的 Android 同构实现。
 *
 * 与旧 Android HomeScreen 的关键差异：
 * - Apple 首页没有额外的“首页 + 服务器名 + 添加”顶栏，因此这里移除 Android 自创 Header；
 * - 根背景使用 `[background, accent@12%, background]` 斜向环境渐变；
 * - 内容 20dp 横边距 / 12dp 顶边距 / 960dp 最大可读宽度；
 * - 快捷入口、140dp 货架卡片、字号和间距按 Apple 源码逐项映射。
 */
@Composable
fun AppleParityHomeScreen(
    graph: AuralisGraph,
    onPlayTracks: (tracks: List<Track>, startIndex: Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    onManageServers: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val theme = LocalAuralisTheme.current
    val colors = theme.colors
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current.applicationContext
    val state = remember(graph) { HomeState(scope, graph, context) }

    LaunchedEffect(state) { state.start() }

    val ambient = Brush.linearGradient(
        colors = listOf(
            colors.background,
            colors.accent.copy(alpha = 0.12f),
            colors.background,
        ),
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(ambient)
            .statusBarsPadding(),
        contentAlignment = Alignment.TopCenter,
    ) {
        when {
            !state.loaded -> CircularProgressIndicator(
                color = colors.accent,
                modifier = Modifier.align(Alignment.Center),
            )

            !state.hasServer -> AppleHomeMessage(
                title = stringResource(AuralisR.string.servers),
                action = stringResource(AuralisR.string.add_server),
                onAction = onManageServers,
            )

            state.lastError != null -> AppleHomeMessage(
                title = state.lastError.orEmpty(),
                action = stringResource(AuralisR.string.retry),
                onAction = state::reload,
            )

            else -> AppleHomeContent(
                state = state,
                onPlayTracks = onPlayTracks,
                onBrowse = onBrowse,
            )
        }
    }
}

@Composable
private fun AppleHomeContent(
    state: HomeState,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .widthIn(max = AuralisChrome.readableContentMaxWidth),
        contentPadding = PaddingValues(
            start = AuralisSpacing.large,
            end = AuralisSpacing.large,
            top = AuralisSpacing.medium,
            // Apple expanded chrome=126；再保留页面自身 large(20) 底部空间。
            bottom = AuralisChrome.expandedInteractionHeight + AuralisSpacing.large,
        ),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xLarge),
    ) {
        if (state.quickModules.isNotEmpty()) {
            item(key = "quick") {
                AppleQuickEntries(
                    modules = state.quickModules,
                    onOpen = { module -> onBrowse(module.id.toBrowseDestination()) },
                )
            }
        }

        items(state.contentModules, key = { "module-${it.id.name}" }) { module ->
            AppleModuleSection(
                module = module,
                onPlayTracks = onPlayTracks,
                onBrowse = onBrowse,
                onReshuffle = { state.reshuffle(module.id) },
            )
        }

        item(key = "stats") { AppleLibrarySummary(state.stats) }
    }
}

@Composable
private fun AppleQuickEntries(
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
                    imageVector = module.id.icon,
                    contentDescription = stringResource(module.id.titleRes),
                    tint = colors.accent,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = module.count.toString(),
                    color = colors.primaryText,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun AppleModuleSection(
    module: HomeModuleSnapshot,
    onPlayTracks: (List<Track>, Int) -> Unit,
    onBrowse: (BrowseDestination) -> Unit,
    onReshuffle: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium)) {
        AppleModuleHeader(module, onBrowse, onReshuffle)
        when {
            module.tracks.isNotEmpty() -> LazyRow(
                horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing),
            ) {
                items(module.tracks, key = { it.globalId.serialized }) { track ->
                    val index = module.tracks.indexOfFirst { it.globalId == track.globalId }.coerceAtLeast(0)
                    AppleTrackCard(track = track) { onPlayTracks(module.tracks, index) }
                }
            }

            module.artists.isNotEmpty() -> LazyRow(
                horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing),
            ) {
                items(module.artists, key = { it.first.globalId.serialized }) { (artist, playCount) ->
                    AppleArtistCard(artist, playCount) {
                        onBrowse(BrowseDestination.Artist(artist.globalId))
                    }
                }
            }

            module.albums.isNotEmpty() -> LazyRow(
                horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing),
            ) {
                items(module.albums, key = { it.first.globalId.serialized }) { (album, playCount) ->
                    AppleAlbumCard(album, playCount) {
                        onBrowse(BrowseDestination.Album(album.globalId))
                    }
                }
            }
        }
    }
}

@Composable
private fun AppleModuleHeader(
    module: HomeModuleSnapshot,
    onBrowse: (BrowseDestination) -> Unit,
    onReshuffle: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = stringResource(module.id.titleRes),
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
                    .padding(horizontal = AuralisSpacing.small, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Icon(Icons.Filled.Refresh, contentDescription = null, tint = colors.secondaryText, modifier = Modifier.size(12.dp))
                Text(stringResource(AuralisR.string.shuffle_more), fontSize = 12.sp, color = colors.secondaryText)
            }
        }
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(AuralisRadius.small))
                .clickable { onBrowse(module.id.toBrowseDestination()) }
                .padding(horizontal = AuralisSpacing.small, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = if (module.tracks.isNotEmpty()) {
                    stringResource(AuralisR.string.count_songs, module.itemCount)
                } else {
                    module.itemCount.toString()
                },
                fontSize = 12.sp,
                color = colors.secondaryText,
            )
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = colors.secondaryText, modifier = Modifier.size(11.dp))
        }
    }
}

@Composable
private fun AppleTrackCard(track: Track, onClick: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .width(AuralisChrome.homeCardWidth)
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
            color = colors.primaryText,
            fontSize = 15.sp,
            lineHeight = 20.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.height(AuralisChrome.homeCardTitleHeight),
        )
        Text(track.artistName, color = colors.secondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun AppleArtistCard(artist: Artist, playCount: Int, onClick: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier.width(AuralisChrome.homeCardWidth).clickable(onClick = onClick),
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
        Text(artist.name, color = colors.primaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(playCount.toString(), color = colors.secondaryText, fontSize = 12.sp, maxLines = 1)
    }
}

@Composable
private fun AppleAlbumCard(album: Album, playCount: Int, onClick: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier.width(AuralisChrome.homeCardWidth).clickable(onClick = onClick),
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
        Text(album.title, color = colors.primaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(playCount.toString(), color = colors.secondaryText, fontSize = 12.sp, maxLines = 1)
    }
}

@Composable
private fun AppleLibrarySummary(stats: LibraryStats) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        AppleStat(stats.artistCount, stringResource(AuralisR.string.artist), Modifier.weight(1f))
        AppleStat(stats.albumCount, stringResource(AuralisR.string.album), Modifier.weight(1f))
        AppleStat(stats.trackCount, stringResource(AuralisR.string.song), Modifier.weight(1f))
        AppleStat(stats.playlistCount, stringResource(AuralisR.string.playlist), Modifier.weight(1f))
    }
}

@Composable
private fun AppleStat(value: Int, label: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value.toString(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.primaryText, maxLines = 1)
        Text(label, fontSize = 11.sp, color = colors.secondaryText, maxLines = 1)
    }
}

@Composable
private fun AppleHomeMessage(title: String, action: String, onAction: () -> Unit) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier.fillMaxSize().padding(AuralisSpacing.xLarge),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, color = colors.secondaryText, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(AuralisSpacing.medium))
        Button(onClick = onAction) { Text(action) }
    }
}

private fun HomeQuickEntry.toBrowseDestination(): BrowseDestination = when (this) {
    HomeQuickEntry.Playlists -> BrowseDestination.Playlists
    HomeQuickEntry.Favorites -> BrowseDestination.Favorites
    HomeQuickEntry.MostPlayed -> BrowseDestination.MostPlayed
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
