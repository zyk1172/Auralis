// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.connector

import com.auralis.core.data.local.AndroidLocalMusicLibrary
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
 * 远端对象保持“远端先行，成功后落本地”的 OpenSubsonic 语义；真正的本地 Track
 * (`auralis-local`) 则只写本地 catalog/state，绝不尝试构造服务器客户端。
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
     * 收藏 Track：
     * - 本地 Track：直接写统一 catalog 的本地状态；
     * - 远端 Track：服务器成功后才写 Room；
     * - 收藏与“不喜欢”互斥。
     */
    suspend fun setTrackFavorite(track: Track, favorite: Boolean): Boolean {
        if (track.serverId == AndroidLocalMusicLibrary.LOCAL_SERVER_ID) {
            catalog.setFavorite(track.globalId, FavoriteKind.Track, favorite)
            if (favorite) catalog.setDisliked(track.globalId, false)
            return true
        }

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
     * 设置/取消「不喜欢」：
     * - 设置不喜欢时若当前已收藏，先取消收藏；
     * - 对本地 Track 全程只落本地；远端 Track 仍按原有服务器语义处理收藏互斥；
     * - 取消不喜欢不恢复旧收藏；不改变当前播放/队列。
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
     * 评分 1..5：本地 Track 直接落本地；远端 Track 仍先调用服务器 setRating。
     * rating == null 时两类来源都只清本地状态。
     */
    suspend fun setRating(track: Track, rating: Int?) {
        if (track.serverId != AndroidLocalMusicLibrary.LOCAL_SERVER_ID && rating != null && rating > 0) {
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
