// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

import kotlinx.coroutines.flow.Flow

/**
 * 本地权威目录（不是缓存垃圾桶）。
 *
 * Android 对应 Apple `LocalCatalogStore` → `AuralisDatabase` + `CatalogRepository`。
 * 所有人（ServerConnector / Search / Home / AI Tool Runtime）必须用**同一个**实例。
 */
interface CatalogRepository {
    fun observeServer(serverId: ServerId): Flow<ServerAccount?>

    suspend fun servers(): List<ServerAccount>

    suspend fun upsertServer(account: ServerAccount)

    suspend fun deleteServer(serverId: ServerId)

    fun observeArtists(serverId: ServerId?): Flow<List<Artist>>
    fun observeAlbums(serverId: ServerId?): Flow<List<Album>>
    fun observeTracks(serverId: ServerId?): Flow<List<Track>>
    fun observeGenres(serverId: ServerId?): Flow<List<Genre>>
    fun observePlaylists(serverId: ServerId?): Flow<List<Playlist>>

    suspend fun artist(globalId: GlobalId): Artist?
    suspend fun album(globalId: GlobalId): Album?
    suspend fun track(globalId: GlobalId): Track?
    suspend fun playlist(globalId: GlobalId): Playlist?

    suspend fun albumTracks(albumGlobalId: GlobalId): List<Track>
    suspend fun artistAlbums(artistGlobalId: GlobalId): List<Album>
    suspend fun artistTracks(artistGlobalId: GlobalId): List<Track>
    suspend fun playlistTracks(playlistGlobalId: GlobalId): List<Track>

    suspend fun favoriteTracks(serverId: ServerId?): List<Track>
    suspend fun mostPlayedTracks(serverId: ServerId?, limit: Int): List<Track>

    /** 本地搜索。实现走 Room FTS/索引查询，绝不能在内存中 filter 一万首。 */
    suspend fun search(serverId: ServerId?, query: String, limit: Int): SearchResults

    /** 资料库统计（首页底部四项）。 */
    suspend fun stats(serverId: ServerId?): LibraryStats

    suspend fun setFavorite(globalId: GlobalId, kind: FavoriteKind, value: Boolean)
    suspend fun setRating(globalId: GlobalId, rating: Int?)
    suspend fun recordPlay(globalId: GlobalId, completed: Boolean)

    /** 自然播完：completed 置位，不改变 playCount。 */
    suspend fun markCompleted(globalId: GlobalId)
    suspend fun setDisliked(globalId: GlobalId, disliked: Boolean)

    /**
     * 是否「不喜欢」（本地私人状态，GlobalID 权威）。
     * 语义与 Apple 一致：只影响自动推荐/发现（随机/智能队列），
     * 搜索、浏览与显式播放不受影响。
     */
    suspend fun isDisliked(globalId: GlobalId): Boolean

    /** 指定服务器全部「不喜欢」的 GlobalID（自动排除逻辑用）。 */
    suspend fun dislikedIds(serverId: ServerId): Set<GlobalId>

    /** 不喜欢集合变化信号（播放页镜像按钮用）。 */
    fun observeDislikedIds(serverId: ServerId?): Flow<List<GlobalId>>

    suspend fun isFavorite(globalId: GlobalId): Boolean

    /** 按实体类型查收藏（专辑/艺术家菜单动态 label 用）。 */
    suspend fun isFavorite(globalId: GlobalId, kind: FavoriteKind): Boolean

    /** 歌曲页/首页派生数据：从未播放、很久没听、最近添加等。 */
    suspend fun neverPlayed(serverId: ServerId?, limit: Int): List<Track>
    suspend fun longUnplayed(serverId: ServerId?, limit: Int): List<Track>
    suspend fun recentlyAdded(serverId: ServerId?, limit: Int): List<Track>
    suspend fun recentlyPlayed(serverId: ServerId?, limit: Int): List<Track>
    suspend fun randomTracks(serverId: ServerId?, limit: Int): List<Track>
    suspend fun favoriteRandom(serverId: ServerId?, limit: Int): List<Track>
    suspend fun topArtists(serverId: ServerId?, limit: Int): List<Artist>
    suspend fun topAlbums(serverId: ServerId?, limit: Int): List<Album>

    // ---- 首页（Home）专用聚合，语义对齐 Apple HomeSnapshotBuilder ----

    /** 收藏歌曲总数（快捷入口「收藏」徽标）。 */
    suspend fun favoriteCount(serverId: ServerId?): Int

    /** 播放过的曲目总数（快捷入口「最常听」徽标）。 */
    suspend fun playedTrackCount(serverId: ServerId?): Int

    /** 已下载曲目（下载完整文件；首页「下载」模块数据源）。 */
    suspend fun downloadedTracks(serverId: ServerId?, limit: Int): List<Track>

    /** 近 [days] 天同步入库的曲目（首页「最近添加」30 天窗口）。 */
    suspend fun recentlyAddedWithin(serverId: ServerId?, days: Int, limit: Int): List<Track>

    /** 常听艺术家：按播放量真实聚合降序，返回 (艺人, 播放量)。 */
    suspend fun homeTopArtists(serverId: ServerId?, limit: Int): List<Pair<Artist, Int>>

    /** 常听专辑：语义同上。 */
    suspend fun homeTopAlbums(serverId: ServerId?, limit: Int): List<Pair<Album, Int>>

    // ---- Library（S4）专用：收藏曲目观察 / 流派筛选 / 歌单本地落盘 ----

    /** 收藏曲目（kind='Track' 且 value=1），收藏表变化即重发。 */
    fun observeFavoriteTracks(serverId: ServerId?): Flow<List<Track>>

    /** 本地按曲目 genres 筛选（对齐 Swift `tracks(for:)`：大小写不敏感；不在内存遍历一万首之外另做全表解码则无用——一次性查询）。 */
    suspend fun genreTracks(serverId: ServerId?, genreName: String): List<Track>

    /**
     * 歌单详情落盘（对齐 Swift `store.setPlaylistTracks` + 更新歌单头）：
     * 单事务 upsert 歌单行（name/modifiedAt/payload）并整体替换 playlist_tracks。
     * 只在远端操作成功后被 [PlaylistCoordinator] 调用，绝不把服务器没确认的列表写本地。
     */
    suspend fun upsertPlaylist(playlist: Playlist)

    /** 删除歌单本地行及其曲目关联（单事务；远端已确认删除后调用）。 */
    suspend fun deletePlaylistLocally(globalId: GlobalId)
}

enum class FavoriteKind { Track, Album, Artist }

/** 播放源解析：本地缓存优先，其次远端流。 */
interface PlaybackSourceResolver {
    suspend fun resolve(track: Track, forceRefresh: Boolean = false): ResolvedSource
}

sealed interface ResolvedSource {
    data class Local(val path: String) : ResolvedSource
    data class Remote(val url: String) : ResolvedSource
    data object Unavailable : ResolvedSource
}

interface LyricsRepository {
    suspend fun load(track: Track): LyricsDocument?
    suspend fun save(document: LyricsDocument)

    /**
     * 清空本地歌词缓存（对齐 Swift `clearLyricsCache`）。
     * 默认空实现：仅需要真实落盘清理的仓储覆盖（RoomLyricsRepository）。
     */
    suspend fun clearCache() {}
}

interface DownloadRepository {
    fun observe(globalId: GlobalId): Flow<DownloadRecord?>
    fun observeAll(serverId: ServerId?): Flow<List<DownloadRecord>>
    suspend fun localPath(globalId: GlobalId): String?
    suspend fun record(record: DownloadRecord)
    suspend fun remove(globalId: GlobalId)
}

/**
 * 播放源提供器：由 App 组合根按 serverID 找到对应 OpenSubsonicClient 后即时解析。
 * 领域层不持有客户端，也不需要知道 HTTP。
 */
fun interface StreamUrlProvider {
    suspend fun streamUrl(track: Track, forceRefresh: Boolean): String?
}
