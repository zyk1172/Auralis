// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.home

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.ui.graphics.vector.ImageVector
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.HomeQuickEntry

/**
 * 首页模块标题与图标注册表（UI 层；对齐 Apple `HomeModuleRegistry` 的 title/icon）。
 *
 * domain 的 [HomeModuleId] / [HomeQuickEntry] 只表达 id 与默认可见性，不携带展示元数据；
 * 标题/图标是纯 UI 关注点，放在 feature 层，避免 domain 依赖 Compose。
 * 内容模块顺序由 domain 枚举声明顺序决定 = Apple defaultOrder（已在 P0 核对）。
 * R5d：标题改为 string resource id（titleRes），Composable 内 stringResource(titleRes) 取文。
 */

val HomeQuickEntry.titleRes: Int
    get() = when (this) {
        HomeQuickEntry.Playlists -> AuralisR.string.playlist
        HomeQuickEntry.Favorites -> AuralisR.string.favorite
        HomeQuickEntry.MostPlayed -> AuralisR.string.most_played
    }

val HomeQuickEntry.icon: ImageVector
    get() = when (this) {
        HomeQuickEntry.Playlists -> Icons.AutoMirrored.Filled.QueueMusic
        HomeQuickEntry.Favorites -> Icons.Filled.Favorite
        HomeQuickEntry.MostPlayed -> Icons.Filled.PlayCircle
    }

/** 内容模块标题资源。 */
val HomeModuleId.titleRes: Int
    get() = when (this) {
        HomeModuleId.RandomSongs -> AuralisR.string.random_music
        HomeModuleId.RecentlyPlayed -> AuralisR.string.recently_played
        HomeModuleId.LongUnplayed -> AuralisR.string.long_unplayed
        HomeModuleId.RecentlyAdded -> AuralisR.string.recently_added
        HomeModuleId.FavoriteRandom -> AuralisR.string.favorite_random
        HomeModuleId.Downloads -> AuralisR.string.downloads
        HomeModuleId.NeverPlayed -> AuralisR.string.never_played
        HomeModuleId.TopArtists -> AuralisR.string.top_artists
        HomeModuleId.TopAlbums -> AuralisR.string.top_albums
    }

/** 内容模块图标（对齐 SF Symbols 语义：shuffle/clock/moon/add/heart/download/…）。 */
val HomeModuleId.icon: ImageVector
    get() = when (this) {
        HomeModuleId.RandomSongs -> Icons.Filled.Shuffle
        HomeModuleId.RecentlyPlayed -> Icons.Filled.History
        HomeModuleId.LongUnplayed -> Icons.Filled.Bedtime
        HomeModuleId.RecentlyAdded -> Icons.Filled.AddCircle
        HomeModuleId.FavoriteRandom -> Icons.Filled.Favorite
        HomeModuleId.Downloads -> Icons.Filled.Download
        HomeModuleId.NeverPlayed -> Icons.Filled.MusicNote
        HomeModuleId.TopArtists -> Icons.Filled.Person
        HomeModuleId.TopAlbums -> Icons.Filled.Album
    }
