// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

import kotlinx.serialization.Serializable

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


/**
 * 首页布局偏好（P0 第九项）：**有序**结构。
 *
 * 为什么不用 Set：Set 存不了顺序。对应 Apple `quickEntries` / `contentModules`
 * 的 `(id, isVisible, order)` 三要素，这里用列表顺序承载 order。
 */
@Serializable
data class HomeEntryPreference(
    val id: String,
    val visible: Boolean = true,
)

@Serializable
data class HomeLayoutPreference(
    val quickEntries: List<HomeEntryPreference> = HomeLayoutPreference.defaultQuickEntries(),
    val contentModules: List<HomeEntryPreference> = HomeLayoutPreference.defaultContentModules(),
) {
    /** 组内不可见项完全剔除。 */
    val visibleQuickEntries: List<HomeQuickEntry>
        get() = quickEntries.filter { it.visible }.mapNotNull { e -> runCatching { HomeQuickEntry.valueOf(e.id) }.getOrNull() }

    val visibleContentModules: List<HomeModuleId>
        get() = contentModules.filter { it.visible }.mapNotNull { e -> runCatching { HomeModuleId.valueOf(e.id) }.getOrNull() }

    fun isVisible(quickId: HomeQuickEntry): Boolean =
        quickEntries.firstOrNull { it.id == quickId.name }?.visible ?: true

    fun isVisible(moduleId: HomeModuleId): Boolean =
        contentModules.firstOrNull { it.id == moduleId.name }?.visible ?: moduleId.defaultEnabled

    fun withQuickVisibility(id: HomeQuickEntry, visible: Boolean): HomeLayoutPreference =
        copy(quickEntries = quickEntries.map { if (it.id == id.name) it.copy(visible = visible) else it })

    fun withModuleVisibility(id: HomeModuleId, visible: Boolean): HomeLayoutPreference =
        copy(contentModules = contentModules.map { if (it.id == id.name) it.copy(visible = visible) else it })

    /** 组内移动：把 [from] 位置的条目移到 [to] 位置（只允许同组内）。 */
    fun moveQuick(from: Int, to: Int): HomeLayoutPreference =
        copy(quickEntries = quickEntries.move(from, to))

    fun moveContent(from: Int, to: Int): HomeLayoutPreference =
        copy(contentModules = contentModules.move(from, to))

    private fun <T> List<T>.move(from: Int, to: Int): List<T> {
        if (from !in indices || to !in indices || from == to) return this
        val mutable = toMutableList()
        val item = mutable.removeAt(from)
        mutable.add(to, item)
        return mutable
    }

    /**
     * 归一化（对齐 Apple `HomeLayoutStore.normalized`）：
     * 1. 丢弃未知 / 重复模块 ID（旧版本遗留数据不会污染新首页）；
     * 2. 数组顺序为权威（列表顺序即展示顺序）；
     * 3. 补齐注册表里有、但旧配置里没有的新模块（按默认可见性追加到末尾），
     *    保证「以后新增模块只需注册」对已装用户也成立。
     */
    fun normalized(): HomeLayoutPreference {
        fun normalize(
            current: List<HomeEntryPreference>,
            registered: List<String>,
            defaultVisible: (String) -> Boolean,
        ): List<HomeEntryPreference> {
            val seen = LinkedHashSet<String>()
            val result = ArrayList<HomeEntryPreference>()
            current.forEach { pref ->
                if (pref.id in registered && seen.add(pref.id)) result.add(pref.copy(visible = pref.visible))
            }
            registered.forEach { id -> if (seen.add(id)) result.add(HomeEntryPreference(id, defaultVisible(id))) }
            return result
        }
        return copy(
            quickEntries = normalize(
                quickEntries,
                HomeQuickEntry.entries.map { it.name },
                { true },
            ),
            contentModules = normalize(
                contentModules,
                HomeModuleId.entries.map { it.name },
                { id -> HomeModuleId.valueOf(id).defaultEnabled },
            ),
        )
    }

    companion object {
        fun defaultQuickEntries(): List<HomeEntryPreference> =
            HomeQuickEntry.entries.map { HomeEntryPreference(it.name, visible = true) }

        fun defaultContentModules(): List<HomeEntryPreference> =
            HomeModuleId.entries.map { HomeEntryPreference(it.name, visible = it.defaultEnabled) }
    }
}
