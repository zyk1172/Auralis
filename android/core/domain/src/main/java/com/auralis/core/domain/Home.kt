package com.auralis.core.domain

/**
 * 首页内容模块注册表。
 *
 * 首页是**模块注册表驱动**的，不是散落在 UI 里的 `if (showRandom) ...`。
 * 默认值逐项对齐 Apple `HomeLayoutStore`：6 开 3 关。
 */
enum class HomeModuleId(
    val defaultEnabled: Boolean,
    /** 该模块支持「换一批」——本地重新采样，**不**发网络请求。 */
    val supportsReshuffle: Boolean,
) {
    RandomSongs(defaultEnabled = true, supportsReshuffle = true),
    RecentlyPlayed(defaultEnabled = true, supportsReshuffle = false),
    LongUnplayed(defaultEnabled = true, supportsReshuffle = false),
    RecentlyAdded(defaultEnabled = true, supportsReshuffle = false),
    FavoriteRandom(defaultEnabled = true, supportsReshuffle = true),
    Downloads(defaultEnabled = true, supportsReshuffle = false),
    NeverPlayed(defaultEnabled = false, supportsReshuffle = false),
    TopArtists(defaultEnabled = false, supportsReshuffle = false),
    TopAlbums(defaultEnabled = false, supportsReshuffle = false),
    ;

    companion object {
        /** 「换一批」的本地重采样样本量，对齐 Apple 的 shuffle 取 18。 */
        const val RESHUFFLE_SAMPLE = 18
    }
}

/** 首页固定三个快捷入口（三列，卡片 = icon + count，不显示长文字标题作为主体）。 */
enum class HomeQuickEntry {
    Playlists,
    Favorites,
    MostPlayed,
}

/** 资料库底部统计四项。 */
data class LibraryStats(
    val artistCount: Int,
    val albumCount: Int,
    val trackCount: Int,
    val playlistCount: Int,
)

/** 资料库的 7 个 scope——一个 Screen + 7 scope，不是 7 个一级页面。 */
enum class LibraryScope { Albums, Tracks, Artists, Playlists, Favorites, Genres, Categories }

data class HomeSection(
    val id: HomeModuleId,
    val title: String,
    val tracks: List<Track> = emptyList(),
    val albums: List<Album> = emptyList(),
    val artists: List<Artist> = emptyList(),
)

data class HomeSnapshot(
    val quickEntries: Map<HomeQuickEntry, Int> = emptyMap(),
    val sections: List<HomeSection> = emptyList(),
    val stats: LibraryStats = LibraryStats(0, 0, 0, 0),
)
