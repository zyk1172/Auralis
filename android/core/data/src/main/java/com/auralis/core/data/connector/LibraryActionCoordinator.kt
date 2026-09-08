// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.connector

import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.CatalogRepository
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.opensubsonic.OpenSubsonicClient
import com.auralis.core.opensubsonic.OpenSubsonicException
import com.auralis.core.opensubsonic.StarTarget

/** 收藏/评分协调器没有可用客户端（服务器未连接/已删除）。 */
class ServerNotConnectedException(serverId: ServerId) :
    IllegalStateException("服务器未连接或已被删除：${serverId.value}")

/** 远端操作失败（网络/协议/认证）。本地目录保持不变，由 UI 回滚乐观状态。 */
class LibraryRemoteOperationException(cause: Throwable) :
    IllegalStateException("远端写操作失败", cause)

/**
 * 资料库动作协调器（P0 第五项）。
 *
 * 对齐 Apple `ProductionServerConnector.setFavorite/setRating` 语义：
 * **远端先行，成功后落本地**——
 * 1. 按实体的 `serverId` 从 [ServerClientRegistry] 取当前真正可用的客户端
 *    （内网/外网路由由注册表决定，不在这里重新猜测地址）；
 * 2. `star / unstar / setRating` 成功后才写 Room；
 * 3. 远端失败 → 抛 [LibraryRemoteOperationException]，本地**不留**“收藏成功”的假状态，
 *    UI 负责把按钮回滚或提示失败。
 *
 * 收藏“以服务器为准”的冷启动回流由 connector 的 starred() 全量替换负责，
 * 这里只处理单次用户动作。
 */
class LibraryActionCoordinator(
    private val registry: ServerClientRegistry,
    private val catalog: CatalogRepository,
) {
    suspend fun toggleTrackFavorite(track: Track): Boolean =
        setTrackFavorite(track, !catalog.isFavorite(track.globalId))

    suspend fun toggleAlbumFavorite(album: Album): Boolean =
        toggleRemoteKind(album.globalId, album.serverId, FavoriteKind.Album) { client, favorite ->
            if (favorite) client.star(StarTarget.Album(album.id.value))
            else client.unstar(StarTarget.Album(album.id.value))
        }

    suspend fun toggleArtistFavorite(artist: Artist): Boolean =
        toggleRemoteKind(artist.globalId, artist.serverId, FavoriteKind.Artist) { client, favorite ->
            if (favorite) client.star(StarTarget.Artist(artist.id.value))
            else client.unstar(StarTarget.Artist(artist.id.value))
        }

    /**
     * 收藏 Track：远端成功后写 Room；收藏与不喜欢互斥（对齐 Apple：
     * 点击收藏时若该曲处于「不喜欢」，先清除不喜欢再收藏）。
     */
    suspend fun setTrackFavorite(track: Track, favorite: Boolean): Boolean {
        val client = requireClient(track.serverId)
        val result = remoteThenLocal(
            remote = {
                if (favorite) client.star(StarTarget.Song(track.id.value))
                else client.unstar(StarTarget.Song(track.id.value))
            },
            local = { catalog.setFavorite(track.globalId, FavoriteKind.Track, favorite) },
        )
        if (result && favorite) {
            catalog.setDisliked(track.globalId, false)
        }
        return result
    }

    // ------------------------------------------------------------ 不喜欢（本地状态）

    /**
     * 设置/取消「不喜欢」（对齐 Apple `toggleDisliked` 产品规则）：
     * - 设置不喜欢时若当前已收藏，先取消收藏（收藏与不喜欢互斥）；
     *   远端取消收藏失败**不回滚本地不喜欢**——dislike 是本地私人状态，
     *   用户意图必须落盘；收藏残留由下次 starred() 全量回流纠正（与 Apple 一致：
     *   `_ = await connector.setFavorite(...)` 忽略远端结果）。
     * - 取消不喜欢不恢复旧收藏；
     * - 不改变当前播放、不改变队列、不跳歌、不删除任何内容。
     */
    suspend fun setDisliked(track: Track, disliked: Boolean) {
        if (disliked && catalog.isFavorite(track.globalId)) {
            runCatching { setTrackFavorite(track, false) }
        }
        catalog.setDisliked(track.globalId, disliked)
    }

    suspend fun toggleDisliked(track: Track): Boolean {
        val target = !catalog.isDisliked(track.globalId)
        setDisliked(track, target)
        return target
    }

    private suspend fun toggleRemoteKind(
        globalId: GlobalId,
        serverId: ServerId,
        kind: FavoriteKind,
        remote: suspend (OpenSubsonicClient, Boolean) -> Unit,
    ): Boolean {
        val client = requireClient(serverId)
        val target = !catalog.isFavorite(globalId)
        return remoteThenLocal(
            remote = { remote(client, target) },
            local = { catalog.setFavorite(globalId, kind, target) },
        )
    }

    /**
     * 评分 1..5：远端 setRating 成功后写 Room。
     * rating == null：OpenSubsonic 没有“清除评分”端点，只清本地（与 Apple 行为一致：
     * 服务器不支持的操作不回传）。
     */
    suspend fun setRating(track: Track, rating: Int?) {
        if (rating != null && rating > 0) {
            val client = requireClient(track.serverId)
            try {
                client.setRating(track.id.value, rating.coerceIn(1, 5))
            } catch (e: OpenSubsonicException) {
                throw LibraryRemoteOperationException(e)
            }
        }
        catalog.setRating(track.globalId, rating?.takeIf { it > 0 })
    }

    // ------------------------------------------------------------------

    private fun requireClient(serverId: ServerId): OpenSubsonicClient =
        registry.client(serverId) ?: throw ServerNotConnectedException(serverId)

    private suspend fun remoteThenLocal(
        remote: suspend () -> Unit,
        local: suspend () -> Unit,
    ): Boolean {
        try {
            remote()
        } catch (e: OpenSubsonicException) {
            throw LibraryRemoteOperationException(e)
        }
        local()
        return true
    }
}
