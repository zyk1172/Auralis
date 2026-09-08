// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

/**
 * 浏览目的地。逐项对齐 Apple `AuralisAppModel.BrowseDestination`（17 个 case）。
 * 只允许走这些入口，不允许退化成「只有 AlbumDetail」。
 */
sealed interface BrowseDestination {
    data class Album(val albumId: GlobalId) : BrowseDestination
    data class Artist(val artistId: GlobalId) : BrowseDestination
    data class Playlist(val playlistId: GlobalId) : BrowseDestination
    data object Playlists : BrowseDestination
    data object Favorites : BrowseDestination
    data object MostPlayed : BrowseDestination
    data class Genre(val name: String, val serverId: ServerId?) : BrowseDestination
    data class RecommendationCategory(val categoryId: String) : BrowseDestination
    data object Random : BrowseDestination
    data object RecentlyPlayed : BrowseDestination
    data object RecentlyAdded : BrowseDestination
    data object LongUnplayed : BrowseDestination
    data object FavoriteRandom : BrowseDestination
    data object NeverPlayed : BrowseDestination
    data object TopArtists : BrowseDestination
    data object TopAlbums : BrowseDestination
    data object Downloads : BrowseDestination
}

/** 资料库 7 个 scope 中，只有这两个是 AI/推荐索引驱动的，不能拿 Genre 假数据填充。 */
object Categories {
    const val NOT_PORTED_MESSAGE = "推荐索引（Categories）依赖 AI 推荐索引库，Android 第一版尚未迁移"
}

enum class SearchScope { Songs, Albums, Artists, Playlists }

data class SearchResults(
    val songs: List<Track> = emptyList(),
    val albums: List<Album> = emptyList(),
    val artists: List<Artist> = emptyList(),
    val playlists: List<Playlist> = emptyList(),
) {
    val isEmpty: Boolean get() = songs.isEmpty() && albums.isEmpty() && artists.isEmpty() && playlists.isEmpty()
}
