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
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.HomeQuickEntry

/**
 * 首页模块标题与图标注册表（UI 层；对齐 Apple `HomeModuleRegistry` 的 title/icon）。
 *
 * domain 的 [HomeModuleId] / [HomeQuickEntry] 只表达 id 与默认可见性，不携带展示元数据；
 * 标题/图标是纯 UI 关注点，放在 feature 层，避免 domain 依赖 Compose。
 * 内容模块顺序由 domain 枚举声明顺序决定 = Apple defaultOrder（已在 P0 核对）。
 */

val HomeQuickEntry.titleZh: String
    get() = when (this) {
        HomeQuickEntry.Playlists -> "歌单"
        HomeQuickEntry.Favorites -> "收藏"
        HomeQuickEntry.MostPlayed -> "最常听"
    }

val HomeQuickEntry.icon: ImageVector
    get() = when (this) {
        HomeQuickEntry.Playlists -> Icons.AutoMirrored.Filled.QueueMusic
        HomeQuickEntry.Favorites -> Icons.Filled.Favorite
        HomeQuickEntry.MostPlayed -> Icons.Filled.PlayCircle
    }

/** 内容模块中文标题。 */
val HomeModuleId.titleZh: String
    get() = when (this) {
        HomeModuleId.RandomSongs -> "随机音乐"
        HomeModuleId.RecentlyPlayed -> "最近播放"
        HomeModuleId.LongUnplayed -> "很久没听"
        HomeModuleId.RecentlyAdded -> "最近添加"
        HomeModuleId.FavoriteRandom -> "收藏里随便听"
        HomeModuleId.Downloads -> "下载"
        HomeModuleId.NeverPlayed -> "从未播放"
        HomeModuleId.TopArtists -> "常听艺术家"
        HomeModuleId.TopAlbums -> "常听专辑"
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
