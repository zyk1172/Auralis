package com.auralis.feature.home

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.HomeLayoutPreference
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.HomeQuickEntry
import com.auralis.core.domain.LibraryStats
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * 首页状态（对齐 Swift `HomeStore` / `HomeView`）：
 * - 由模块注册表 + 布局偏好驱动：关闭的模块不查询数据（不渲染）；
 * - 开启但当前无数据 → 暂不渲染，配置保持；
 * - 每个模块的数据都来自**真实 SQL**（随机/最近播放/未播放/最近添加/下载/常听…）；
 * - 「换一批」= 重新查询（SQL `ORDER BY RANDOM()`），本地完成，不发网络；
 * - 目录/歌单/收藏/播放/下载变化 → 自动重建快照（room 信号）。
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class HomeState(
    private val scope: CoroutineScope,
    private val graph: AuralisGraph,
    private val context: Context,
) {
    private val repo get() = graph.catalogRepository
    private val prefs get() = graph.preferences

    var loaded by mutableStateOf(false)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var hasServer by mutableStateOf(false)
        private set
    var serverName by mutableStateOf<String?>(null)
        private set

    /** 快捷入口按用户布局顺序，已过滤「开启 && 有数据」。 */
    var quickModules by mutableStateOf<List<QuickEntryModule>>(emptyList())
        private set

    /** 内容模块按用户布局顺序，已过滤「开启 && 有数据」。 */
    var contentModules by mutableStateOf<List<HomeModuleSnapshot>>(emptyList())
        private set

    /** 资料库底部四项统计。 */
    var stats by mutableStateOf(LibraryStats(0, 0, 0, 0))
        private set

    var lastError by mutableStateOf<String?>(null)
        private set

    private var layout: HomeLayoutPreference = HomeLayoutPreference()
    private var activeServer: ServerId? = null

    /** 进入 Home 后启动：观察 active 服务器 + 布局 + 目录信号自动刷新。 */
    fun start() {
        scope.launch {
            prefs.activeServerIdFlow.collect { sid ->
                if (sid == null) {
                    refresh(null)
                } else {
                    val serverId = ServerId(sid)
                    combine(
                        prefs.homeLayoutFlow,
                        repo.homeChangeSignals(serverId),
                    ) { layout, _ -> layout }
                        .collect { layoutValue ->
                            layout = layoutValue
                            refresh(serverId)
                        }
                }
            }
        }
    }

    /** 手动全量刷新（首帧 / 失败重试）。 */
    fun reload() {
        val sid = activeServer ?: return
        scope.launch { refresh(sid) }
    }

    /** 换一批：random / favoriteRandom 本地重采样（SQL RANDOM，不发网络）。 */
    fun reshuffle(moduleId: HomeModuleId) {
        val sid = activeServer ?: return
        scope.launch {
            val sampled = when (moduleId) {
                HomeModuleId.RandomSongs -> repo.randomTracks(sid, HomeModuleId.RESHUFFLE_SAMPLE)
                HomeModuleId.FavoriteRandom -> repo.favoriteRandom(sid, HomeModuleId.RESHUFFLE_SAMPLE)
                else -> return@launch
            }
            // 把换一批结果写回对应模块快照。
            contentModules = contentModules.map { module ->
                if (module.id == moduleId) module.withTracks(sampled) else module
            }
        }
    }

    private suspend fun refresh(serverId: ServerId?) {
        activeServer = serverId
        if (serverId == null) {
            hasServer = false
            loaded = true
            refreshing = false
            return
        }
        val accounts = runCatching { repo.servers() }.getOrDefault(emptyList())
        hasServer = accounts.isNotEmpty()
        serverName = accounts.firstOrNull { it.id == serverId }?.displayName
        refreshing = true
        try {
            stats = repo.stats(serverId)
            buildQuickModules(serverId)
            buildContentModules(serverId)
            lastError = null
        } catch (t: Throwable) {
            lastError = context.getString(R.string.home_load_failed, t.message)
        } finally {
            refreshing = false
            loaded = true
        }
    }

    /** 快捷入口：按布局顺序渲染「开启 && 有数据」。 */
    private suspend fun buildQuickModules(serverId: ServerId) {
        val playlistCount = stats.playlistCount
        val favoriteCount = repo.favoriteCount(serverId)
        val playedCount = repo.playedTrackCount(serverId)
        val counts = mapOf(
            HomeQuickEntry.Playlists to playlistCount,
            HomeQuickEntry.Favorites to favoriteCount,
            HomeQuickEntry.MostPlayed to playedCount,
        )
        quickModules = layout.quickEntries
            .filter { it.visible }
            .mapNotNull { entry ->
                val id = runCatching { HomeQuickEntry.valueOf(entry.id) }.getOrNull() ?: return@mapNotNull null
                val count = counts[id] ?: 0
                if (count <= 0) return@mapNotNull null // 开启但无数据 → 暂不渲染（配置保持）
                QuickEntryModule(id = id, count = count)
            }
    }

    /** 内容模块：只查询「开启」的模块；有数据才渲染。 */
    private suspend fun buildContentModules(serverId: ServerId) {
        val built = ArrayList<HomeModuleSnapshot>()
        for (entry in layout.contentModules) {
            if (!entry.visible) continue // 关闭的模块完全不查询数据
            val id = runCatching { HomeModuleId.valueOf(entry.id) }.getOrNull() ?: continue
            val snapshot = when (id) {
                HomeModuleId.RandomSongs -> tracksModule(id, repo.randomTracks(serverId, HomeModuleId.RESHUFFLE_SAMPLE))
                HomeModuleId.RecentlyPlayed -> tracksModule(id, repo.recentlyPlayed(serverId, MODULE_SHELF_LIMIT))
                HomeModuleId.RecentlyAdded -> tracksModule(id, repo.recentlyAddedWithin(serverId, 30, MODULE_SHELF_LIMIT))
                HomeModuleId.LongUnplayed -> tracksModule(id, repo.longUnplayed(serverId, MODULE_SHELF_LIMIT))
                HomeModuleId.NeverPlayed -> tracksModule(id, repo.neverPlayed(serverId, MODULE_SHELF_LIMIT))
                HomeModuleId.FavoriteRandom -> tracksModule(id, repo.favoriteRandom(serverId, HomeModuleId.RESHUFFLE_SAMPLE))
                HomeModuleId.Downloads -> tracksModule(id, repo.downloadedTracks(serverId, MODULE_SHELF_LIMIT))
                HomeModuleId.TopArtists -> artistsModule(id, repo.homeTopArtists(serverId, MODULE_SHELF_LIMIT))
                HomeModuleId.TopAlbums -> albumsModule(id, repo.homeTopAlbums(serverId, MODULE_SHELF_LIMIT))
            }
            if (snapshot.hasData) built.add(snapshot) // 无数据 → 暂不渲染（配置保持）
        }
        contentModules = built
    }

    private fun tracksModule(id: HomeModuleId, tracks: List<Track>) =
        HomeModuleSnapshot(id = id, tracks = tracks)

    private fun artistsModule(id: HomeModuleId, artists: List<Pair<Artist, Int>>) =
        HomeModuleSnapshot(id = id, artists = artists)

    private fun albumsModule(id: HomeModuleId, albums: List<Pair<Album, Int>>) =
        HomeModuleSnapshot(id = id, albums = albums)

    companion object {
        /** 内容货架单模块条数上限（对齐 Apple 各 prefix 24）。 */
        const val MODULE_SHELF_LIMIT = 24
    }
}

/** 快捷入口渲染单元：icon + count。 */
data class QuickEntryModule(
    val id: HomeQuickEntry,
    val count: Int,
)

/**
 * 内容模块渲染快照：歌曲货架 / 艺人货架 / 专辑货架三选一，
 * 与 Apple `HomeView.moduleSection` 的 trackShelf / artistShelf / albumShelf 对应。
 */
data class HomeModuleSnapshot(
    val id: HomeModuleId,
    val tracks: List<Track> = emptyList(),
    val artists: List<Pair<Artist, Int>> = emptyList(),
    val albums: List<Pair<Album, Int>> = emptyList(),
) {
    val hasData: Boolean
        get() = tracks.isNotEmpty() || artists.isNotEmpty() || albums.isNotEmpty()

    val itemCount: Int
        get() = when {
            tracks.isNotEmpty() -> tracks.size
            artists.isNotEmpty() -> artists.size
            else -> albums.size
        }

    fun withTracks(sampled: List<Track>): HomeModuleSnapshot =
        if (sampled.isEmpty()) this.copy(tracks = emptyList()) else this.copy(tracks = sampled)
}
