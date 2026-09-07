package com.auralis.mobile.shell

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.BrowseDestination
import com.auralis.mobile.R

/**
 * S2/S3 阶段的分区占位页。主页已替换为真实首页（feature:home）；
 * 音乐库页带顶栏齿轮入口（设置→服务器，真实可用）+ 承接 Home 的浏览目的地；
 * 真正的 Library/Browse 页面在 S4 接入。
 */

@Composable
fun LibraryPlaceholderPage(
    onOpenSettings: () -> Unit,
    browseTarget: BrowseDestination? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .padding(horizontal = AuralisSpacing.large),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(AuralisR.string.library_title),
                style = MaterialTheme.typography.headlineMedium,
                color = colors.primaryText,
                modifier = Modifier.weight(1f),
            )
            // Settings 入口（audit 06：Library 顶栏齿轮；Settings 不做一级 Tab）。
            IconButton(onClick = onOpenSettings) {
                Icon(Icons.Filled.Settings, contentDescription = stringResource(AuralisR.string.settings), tint = colors.primaryText)
            }
        }
        Spacer(Modifier.height(AuralisSpacing.large))
        if (browseTarget != null) {
            Text(
                browseTargetTitle(browseTarget),
                style = MaterialTheme.typography.titleMedium,
                color = colors.primaryText,
            )
            Spacer(Modifier.height(AuralisSpacing.small))
            Text(
                stringResource(R.string.mobile_browse_full_list_coming, browseTargetTitle(browseTarget)),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
            )
        } else {
            Text(
                stringResource(R.string.mobile_library_stage_coming),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
            )
        }
    }
}

/** 占位页当前浏览目标的标题（流派带名称插值）。 */
@Composable
private fun browseTargetTitle(destination: BrowseDestination): String =
    if (destination is BrowseDestination.Genre) {
        stringResource(R.string.mobile_dest_genre, destination.name)
    } else {
        stringResource(destination.titleRes())
    }

/** Home 浏览目标 → 标题资源（S4 Browse 页落地前的展示映射）。 */
@StringRes
internal fun BrowseDestination.titleRes(): Int = when (this) {
    is BrowseDestination.Album -> AuralisR.string.album
    is BrowseDestination.Artist -> R.string.mobile_dest_artist
    is BrowseDestination.Playlist -> AuralisR.string.playlist
    BrowseDestination.Playlists -> AuralisR.string.playlist
    BrowseDestination.Favorites -> AuralisR.string.favorite
    BrowseDestination.MostPlayed -> AuralisR.string.most_played
    is BrowseDestination.Genre -> R.string.mobile_dest_genre
    is BrowseDestination.RecommendationCategory -> R.string.mobile_dest_recommendation
    BrowseDestination.Random -> AuralisR.string.random_music
    BrowseDestination.RecentlyPlayed -> AuralisR.string.recently_played
    BrowseDestination.RecentlyAdded -> AuralisR.string.recently_added
    BrowseDestination.LongUnplayed -> AuralisR.string.long_unplayed
    BrowseDestination.FavoriteRandom -> AuralisR.string.favorite_random
    BrowseDestination.NeverPlayed -> AuralisR.string.never_played
    BrowseDestination.TopArtists -> AuralisR.string.top_artists
    BrowseDestination.TopAlbums -> AuralisR.string.top_albums
    BrowseDestination.Downloads -> AuralisR.string.downloads
}
