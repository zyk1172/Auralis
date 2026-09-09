// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.repository

import androidx.room.withTransaction
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.db.DataJson
import com.auralis.core.data.db.RecommendationIndexDao
import com.auralis.core.data.db.RecommendationIndexStateEntity
import com.auralis.core.data.db.RecommendationIndexTagEntity
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.RecommendationIndex
import com.auralis.core.domain.RecommendationIndexCategory
import com.auralis.core.domain.RecommendationIndexStatus
import com.auralis.core.domain.RecommendationIndexTag
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/**
 * Recommendation Index v3 的本地事务边界。
 *
 * 关键不变量与 Apple 一致：rulesVersion 相同并不等于索引仍有效；当前 Track payload
 * 重算出来的 v2 content hash 还必须与 state.source_hash 完全一致。标题/专辑/流派等
 * 内容元数据一旦改变，该条目立即 fail-closed 为 pending，Categories 和详情都不会继续
 * 消费旧分类。收藏/评分/播放次数不在 content hash 中，因此个人行为不会触发重建。
 */
class RecommendationIndexStore(
    private val database: AuralisDatabase,
    private val dao: RecommendationIndexDao = database.recommendationIndexDao(),
    private val json: Json = DataJson.json,
) {
    suspend fun status(serverId: ServerId): RecommendationIndexStatus {
        val total = dao.totalTrackCount(serverId.value)
        val valid = validTrackIds(serverId)
        return RecommendationIndexStatus(
            totalTracks = total,
            indexedTracks = valid.size.coerceAtMost(total),
            pendingTracks = (total - valid.size).coerceAtLeast(0),
        )
    }

    suspend fun categories(serverId: ServerId): List<RecommendationIndexCategory> {
        val valid = validTrackIds(serverId)
        if (valid.isEmpty()) return emptyList()
        return dao.categoriesForValidTracks(valid).map { row ->
            RecommendationIndexCategory(
                dimension = row.dimension,
                tagId = row.value,
                trackCount = row.trackCount,
            )
        }
    }

    suspend fun tracksForCategory(
        serverId: ServerId,
        dimension: String,
        tagId: String,
        limit: Int = 500,
    ): List<Track> {
        require(RecommendationIndex.isFixedDimension(dimension)) { "未知推荐索引维度: $dimension" }
        require(tagId.isNotBlank()) { "推荐索引 TagID 不能为空" }
        val valid = validTrackIds(serverId)
        if (valid.isEmpty()) return emptyList()
        return dao.trackPayloadsForCategory(
            validGlobalIds = valid,
            dimension = dimension,
            value = tagId,
            limit = limit.coerceIn(1, 2_000),
        ).mapNotNull { payload -> decodeTrack(payload, expectedServer = serverId) }
    }

    /**
     * 替换单曲的完整固定 taxonomy 分类。
     *
     * source hash 不接受 classifier 外部传入，而是在事务前从当前本地 Track payload 计算；
     * 这样模型/调用方无法把旧 payload 的分类伪装成“当前有效”。`tags` 是整组替换而不是
     * 增量 merge，确保 rulesVersion 更新时不会残留旧维度结果。
     */
    suspend fun replaceClassification(
        serverId: ServerId,
        globalId: GlobalId,
        tags: List<RecommendationIndexTag>,
        classifier: String = "configured-agent",
        classifiedAtMillis: Long = System.currentTimeMillis(),
    ) {
        require(globalId.serverId == serverId) { "Recommendation Index server/global-id 不一致" }
        require(classifier.isNotBlank()) { "Recommendation Index classifier 不能为空" }

        val canonical = tags
            .map { tag ->
                require(RecommendationIndex.isFixedDimension(tag.dimension)) {
                    "Recommendation Index 非固定维度: ${tag.dimension}"
                }
                val value = tag.value.trim()
                require(value.isNotEmpty()) { "Recommendation Index TagID 不能为空" }
                require(tag.confidence.isFinite() && tag.confidence in 0.0..1.0) {
                    "Recommendation Index confidence 必须在 0...1"
                }
                RecommendationIndexTag(tag.dimension, value, tag.confidence)
            }
            .distinctBy { it.dimension to it.value }

        // 事务前确认曲目真实存在且 payload 可解码；孤儿 ID / 损坏 payload 整条拒绝。
        val entity = database.trackDao().byGlobalId(globalId.serialized)
            ?: throw IllegalArgumentException("Recommendation Index 曲目不存在: ${globalId.serialized}")
        require(entity.serverId == serverId.value) { "Recommendation Index 曲目服务器不一致" }
        val currentTrack = decodeTrack(entity.payload, expectedServer = serverId)
            ?: throw IllegalArgumentException("Recommendation Index 曲目 payload 无法验证: ${globalId.serialized}")
        require(currentTrack.globalId == globalId) { "Recommendation Index payload/global-id 不一致" }
        val sourceHash = RecommendationIndex.contentHash(currentTrack)

        database.withTransaction {
            dao.upsertState(
                RecommendationIndexStateEntity(
                    globalId = globalId.serialized,
                    serverId = serverId.value,
                    sourceHash = sourceHash,
                    rulesVersion = RecommendationIndex.RULES_VERSION,
                    classifier = classifier,
                    classifiedAt = classifiedAtMillis,
                    sourceHashVersion = RecommendationIndex.CONTENT_HASH_VERSION,
                    semanticTagRulesVersion = 0,
                ),
            )
            dao.deleteTags(globalId.serialized)
            if (canonical.isNotEmpty()) {
                dao.upsertTags(
                    canonical.map { tag ->
                        RecommendationIndexTagEntity(
                            globalId = globalId.serialized,
                            dimension = tag.dimension,
                            value = tag.value,
                            confidence = tag.confidence,
                        )
                    },
                )
            }
        }
    }

    suspend fun clear(serverId: ServerId) {
        database.withTransaction {
            // tag 表自身没有 server_id，必须先由 state 表限定身份再删 tag，最后再删 state。
            dao.deleteTagsForServer(serverId.value)
            dao.deleteStateForServer(serverId.value)
        }
    }

    /**
     * 当前可消费索引集合。任何 hash/version/payload/server/global-id 异常都 fail closed。
     * 旧 contentHashVersion 不在这里“猜着迁移”；它会进入 pending，由后续索引构建重新写入。
     */
    private suspend fun validTrackIds(serverId: ServerId): List<String> =
        dao.stateTrackRows(serverId.value, RecommendationIndex.RULES_VERSION).mapNotNull { row ->
            if (row.sourceHashVersion != RecommendationIndex.CONTENT_HASH_VERSION) return@mapNotNull null
            val track = decodeTrack(row.payload, expectedServer = serverId) ?: return@mapNotNull null
            if (track.globalId.serialized != row.globalId) return@mapNotNull null
            if (RecommendationIndex.contentHash(track) != row.sourceHash) return@mapNotNull null
            row.globalId
        }

    private fun decodeTrack(payload: String, expectedServer: ServerId): Track? =
        runCatching { json.decodeFromString<Track>(payload) }
            .getOrNull()
            ?.takeIf { it.serverId == expectedServer }
}
