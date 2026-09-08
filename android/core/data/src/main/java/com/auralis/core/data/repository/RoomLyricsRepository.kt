// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.repository

import com.auralis.core.data.db.AnnotationDao
import com.auralis.core.data.db.DataJson
import com.auralis.core.data.db.LyricEntity
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.LyricsRepository
import com.auralis.core.domain.Track
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Room 落地的歌词仓储（P0 第八项）。
 *
 * key 一律是 **serverID + trackID** 组成的 [GlobalId]——同 remote id 在不同服务器
 * 之间的歌词绝不共享（多服务器隔离）。
 */
class RoomLyricsRepository(
    private val annotationDao: AnnotationDao,
    private val json: Json = DataJson.json,
) : LyricsRepository {
    override suspend fun load(track: Track): LyricsDocument? {
        val entity = annotationDao.lyric(track.globalId.serialized) ?: return null
        return runCatching { json.decodeFromString<LyricsDocument>(entity.payload) }.getOrNull()
    }

    override suspend fun save(document: LyricsDocument) {
        val globalId: GlobalId = document.globalId
        annotationDao.upsertLyric(
            LyricEntity(
                globalId = globalId.serialized,
                serverId = globalId.serverId.value,
                payload = json.encodeToString(document),
            ),
        )
    }

    override suspend fun clearCache() {
        annotationDao.clearAllLyrics()
    }
}
