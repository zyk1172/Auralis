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
    suspend fun setDisliked(globalId: GlobalId, disliked: Boolean)

    suspend fun isFavorite(globalId: GlobalId): Boolean

    /** 歌曲页/首页派生数据：从未播放、很久没听、最近添加等。 */
    suspend fun neverPlayed(serverId: ServerId?, limit: Int): List<Track>
    suspend fun longUnplayed(serverId: ServerId?, limit: Int): List<Track>
    suspend fun recentlyAdded(serverId: ServerId?, limit: Int): List<Track>
    suspend fun recentlyPlayed(serverId: ServerId?, limit: Int): List<Track>
    suspend fun randomTracks(serverId: ServerId?, limit: Int): List<Track>
    suspend fun favoriteRandom(serverId: ServerId?, limit: Int): List<Track>
    suspend fun topArtists(serverId: ServerId?, limit: Int): List<Artist>
    suspend fun topAlbums(serverId: ServerId?, limit: Int): List<Album>
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
