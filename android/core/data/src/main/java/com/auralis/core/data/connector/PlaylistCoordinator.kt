// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.connector

import com.auralis.core.domain.CatalogRepository
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.PlaylistId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.opensubsonic.OpenSubsonicClient
import com.auralis.core.opensubsonic.OpenSubsonicException

/** 远端歌单操作失败（网络/协议/认证/只读）。本地目录保持不变，由 UI 回滚乐观状态。 */
class PlaylistRemoteOperationException(cause: Throwable) :
    IllegalStateException("远端歌单操作失败", cause)

/**
 * 歌单协调器（S4）。
 *
 * 对齐 Apple `AuralisAppModel` 的歌单操作语义（R06）：
 * - **远端先行，成功后落本地**——与 [LibraryActionCoordinator] 同一铁律；
 * - `readonly` 歌单禁止修改/删除（Swift 守卫），只读歌单仍可被复制；
 * - 需要完整列表的操作（rename/add/remove）在远端成功后调 `getPlaylist`（单数）
 *   拿服务器确认后的最新曲目整表替换本地（对齐 `loadPlaylistTracks` 的
 *   `fetchPlaylistTracks` + `setPlaylistTracks`），绝不本地猜测列表；
 * - 删除歌单是破坏性操作：调用方（UI）必须先完成二次确认再进这里。
 */
class PlaylistCoordinator(
    private val registry: ServerClientRegistry,
    private val catalog: CatalogRepository,
) {
    /** 从服务器拉取歌单完整详情并落本地。返回服务器确认后的歌单（可能带 trackIds）。 */
    suspend fun refreshPlaylist(playlist: Playlist): Playlist {
        val client = requireClient(playlist.serverId)
        val remote = try {
            client.playlist(playlist.id.value)
        } catch (e: OpenSubsonicException) {
            throw PlaylistRemoteOperationException(e)
        }
        val merged = remote ?: playlist
        catalog.upsertPlaylist(merged)
        return merged
    }

    /** 新建歌单（可带初始曲目）。远端确认后拉一次完整详情落本地。 */
    suspend fun createPlaylist(name: String, serverId: ServerId, trackIds: List<String> = emptyList()): Playlist? {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return null
        val client = requireClient(serverId)
        val createdId = try {
            client.createPlaylist(trimmed, trackIds)
        } catch (e: OpenSubsonicException) {
            throw PlaylistRemoteOperationException(e)
        } ?: return null
        val skeleton = Playlist(
            id = PlaylistId(createdId.value),
            serverId = serverId,
            name = trimmed,
        )
        return refreshPlaylist(skeleton)
    }

    /** 重命名（对齐 Swift `renamePlaylist`）：只读歌单禁止；远端成功后落本地。 */
    suspend fun rename(playlist: Playlist, to: String): Boolean {
        val trimmed = to.trim()
        if (trimmed.isEmpty() || trimmed == playlist.name) return false
        requireEditable(playlist)
        val client = requireClient(playlist.serverId)
        try {
            client.updatePlaylist(playlist.id.value, name = trimmed)
        } catch (e: OpenSubsonicException) {
            throw PlaylistRemoteOperationException(e)
        }
        catalog.upsertPlaylist(
            playlist.copy(
                name = trimmed,
                modifiedAtMillis = System.currentTimeMillis(),
            ),
        )
        return true
    }

    /** 追加曲目（对齐 Swift `addTracksToPlaylist`）。 */
    suspend fun addTracks(playlist: Playlist, tracks: List<Track>): Boolean {
        if (tracks.isEmpty()) return false
        requireEditable(playlist)
        val client = requireClient(playlist.serverId)
        try {
            client.updatePlaylist(playlist.id.value, appendTrackIds = tracks.map { it.id.value })
        } catch (e: OpenSubsonicException) {
            throw PlaylistRemoteOperationException(e)
        }
        refreshPlaylist(playlist)
        return true
    }

    /** 按下标批量移除（对齐 Swift `removeFromPlaylist`；曲目本身保留）。 */
    suspend fun removeAt(playlist: Playlist, indices: List<Int>): Boolean {
        val sorted = indices.filter { it >= 0 }.distinct().sorted()
        if (sorted.isEmpty()) return false
        requireEditable(playlist)
        val client = requireClient(playlist.serverId)
        try {
            client.updatePlaylist(playlist.id.value, removeIndexes = sorted)
        } catch (e: OpenSubsonicException) {
            throw PlaylistRemoteOperationException(e)
        }
        refreshPlaylist(playlist)
        return true
    }

    /** 删除歌单（破坏性，远端 + 本地）。调用方必须已二次确认。 */
    suspend fun delete(playlist: Playlist): Boolean {
        requireEditable(playlist)
        val client = requireClient(playlist.serverId)
        try {
            client.deletePlaylist(playlist.id.value)
        } catch (e: OpenSubsonicException) {
            throw PlaylistRemoteOperationException(e)
        }
        catalog.deletePlaylistLocally(playlist.globalId)
        return true
    }

    /** 复制歌单（对齐 Swift `duplicatePlaylist`：副本命名「原名 副本」，只读歌单也允许复制）。 */
    suspend fun duplicate(source: Playlist): Playlist? =
        createPlaylist(
            name = "${source.name} 副本",
            serverId = source.serverId,
            trackIds = source.trackIds.map { it.value },
        )

    /** 按服务器曲目 ID 首次出现去重（对齐 Swift `removeDuplicateSongs`）。 */
    suspend fun removeDuplicateSongs(playlist: Playlist): Boolean {
        val seen = HashSet<String>()
        val duplicates = ArrayList<Int>()
        playlist.trackIds.forEachIndexed { index, id ->
            if (!seen.add(id.value)) duplicates.add(index)
        }
        if (duplicates.isEmpty()) return false
        return removeAt(playlist, duplicates)
    }

    // ------------------------------------------------------------------

    private fun requireClient(serverId: ServerId): OpenSubsonicClient =
        registry.client(serverId) ?: throw ServerNotConnectedException(serverId)

    private fun requireEditable(playlist: Playlist) {
        if (playlist.isReadOnly) {
            throw PlaylistRemoteOperationException(
                IllegalStateException("只读歌单禁止修改：${playlist.name}"),
            )
        }
    }
}
