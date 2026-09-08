// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

import kotlinx.serialization.Serializable

/**
 * 强类型身份。Apple 端对应 `Domain/Models.swift` 的 `ServerID/ArtistID/AlbumID/TrackID/PlaylistID`。
 *
 * 这些只是「服务器内部的 remote id」——**不是**全局唯一身份。
 * 真正稳定的身份永远见 [GlobalId]。
 */
@JvmInline
@Serializable
value class ServerId(val value: String)

@JvmInline
@Serializable
value class ArtistId(val value: String)

@JvmInline
@Serializable
value class AlbumId(val value: String)

@JvmInline
@Serializable
value class TrackId(val value: String)

@JvmInline
@Serializable
value class PlaylistId(val value: String)

/**
 * Auralis 的全局实体身份 = serverId + remoteId。
 *
 * Apple 端 `LocalCatalogStore` 的 `global_id` 列存的就是 `"{serverId}:{remoteId}"`，
 * 本类是它的类型化表达。数据库主键、封面 key、歌词 key、下载 key、收藏 key、
 * 播放历史 key 一律使用它，禁止单独用 remoteId 查询。
 */
@Serializable
data class GlobalId(val serverId: ServerId, val remoteId: String) {
    val serialized: String get() = "${serverId.value}:$remoteId"

    companion object {
        private const val SEPARATOR = ":"

        fun parse(raw: String): GlobalId {
            val index = raw.indexOf(SEPARATOR)
            require(index > 0) { "Malformed GlobalId: $raw" }
            return GlobalId(ServerId(raw.substring(0, index)), raw.substring(index + 1))
        }
    }
}

fun ServerId.global(remoteId: String) = GlobalId(this, remoteId)

/** 队列项身份。同一首歌可以出现多次，每次 occurrence 都是独立的 UUID。 */
@JvmInline
@Serializable
value class QueueEntryId(val value: String)
