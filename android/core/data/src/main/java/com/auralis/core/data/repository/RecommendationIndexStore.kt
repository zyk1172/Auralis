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
 * 当前职责刻意只覆盖“可信状态/标签落库 + Categories 查询”，不在这里调用模型。
 * Agent classifier 后续只提交已验证的 [RecommendationIndexTag]；本 Store 在打开事务之前
 * 再做固定维度、TagID、server/global-id 与 confidence 校验，任何一项非法则整批拒绝，
 * 绝不部分写入。
 */
class RecommendationIndexStore(
    private val database: AuralisDatabase,
    private val dao: RecommendationIndexDao = database.recommendationIndexDao(),
    private val json: Json = DataJson.json,
) {
    suspend fun status(serverId: ServerId): RecommendationIndexStatus {
        val total = dao.totalTrackCount(serverId.value)
        val indexed = dao.indexedTrackCount(serverId.value, RecommendationIndex.RULES_VERSION)
        return RecommendationIndexStatus(
            totalTracks = total,
            indexedTracks = indexed.coerceAtMost(total),
            pendingTracks = (total - indexed).coerceAtLeast(0),
        )
    }

    suspend fun categories(serverId: ServerId): List<RecommendationIndexCategory> =
        dao.categories(serverId.value, RecommendationIndex.RULES_VERSION).map { row ->
            RecommendationIndexCategory(
                dimension = row.dimension,
                tagId = row.value,
                trackCount = row.trackCount,
            )
        }

    suspend fun tracksForCategory(
        serverId: ServerId,
        dimension: String,
        tagId: String,
        limit: Int = 500,
    ): List<Track> {
        require(RecommendationIndex.isFixedDimension(dimension)) { "未知推荐索引维度: $dimension" }
        require(tagId.isNotBlank()) { "推荐索引 TagID 不能为空" }
        return dao.trackPayloadsForCategory(
            serverId = serverId.value,
            rulesVersion = RecommendationIndex.RULES_VERSION,
            dimension = dimension,
            value = tagId,
            limit = limit.coerceIn(1, 2_000),
        ).mapNotNull { payload ->
            runCatching { json.decodeFromString<Track>(payload) }.getOrNull()
        }
    }

    /**
     * 替换单曲的完整固定 taxonomy 分类。
     * `tags` 是整组替换而不是增量 merge，确保 rulesVersion 更新时不会残留旧维度结果。
     */
    suspend fun replaceClassification(
        serverId: ServerId,
        globalId: GlobalId,
        sourceHash: String,
        tags: List<RecommendationIndexTag>,
        classifier: String = "configured-agent",
        classifiedAtMillis: Long = System.currentTimeMillis(),
    ) {
        require(globalId.serverId == serverId) { "Recommendation Index server/global-id 不一致" }
        require(sourceHash.isNotBlank()) { "Recommendation Index source hash 不能为空" }
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

        // 写事务前确认该曲目确实属于本地目录；避免 classifier 给出不存在 global id 时留下孤儿状态。
        val track = database.trackDao().byGlobalId(globalId.serialized)
            ?: throw IllegalArgumentException("Recommendation Index 曲目不存在: ${globalId.serialized}")
        require(track.serverId == serverId.value) { "Recommendation Index 曲目服务器不一致" }

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
}
