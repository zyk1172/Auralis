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
import com.auralis.core.domain.RecommendationIndexBatch
import com.auralis.core.domain.RecommendationIndexClassificationInput
import com.auralis.core.domain.RecommendationIndexStatus
import com.auralis.core.domain.RecommendationIndexTag
import com.auralis.core.domain.RecommendationIndexTaxonomy
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlinx.coroutines.flow.first
import java.util.Locale

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

    /**
     * Returns the next bounded closed-transform batch. The caller must classify exactly these
     * IDs and submit them through [replaceClassifications]; no arbitrary track IDs are accepted.
     */
    suspend fun nextBatch(serverId: ServerId, limit: Int = 80): RecommendationIndexBatch {
        require(limit in 1..100) { "Recommendation Index batch size 必须在 1...100" }
        val entities = database.trackDao().observeAll(serverId.value).first()
        val entityIds = entities.map { it.globalId }.toHashSet()
        val valid = validTrackIds(serverId).toHashSet()
        val pendingEntities = entities.filterNot { it.globalId in valid }
        val pendingTracks = pendingEntities.mapNotNull { entity ->
            decodeTrack(entity.payload, expectedServer = serverId)
        }.sortedBy { it.globalId.serialized }
        return RecommendationIndexBatch(
            serverId = serverId,
            tracks = pendingTracks.take(limit),
            totalTracks = entities.size,
            indexedTracks = valid.count { it in entityIds },
            pendingTracks = pendingEntities.size,
            unreadableTracks = pendingEntities.size - pendingTracks.size,
        )
    }

    suspend fun categories(serverId: ServerId): List<RecommendationIndexCategory> {
        val valid = validTrackIds(serverId)
        if (valid.isEmpty()) return emptyList()
        return valid.chunked(SQLITE_IN_CHUNK_SIZE)
            .flatMap { dao.categoriesForValidTracks(it) }
            .groupingBy { it.dimension to it.value }
            .fold(0) { count, row -> count + row.trackCount }
            .map { (key, count) ->
                RecommendationIndexCategory(
                    dimension = key.first,
                    tagId = key.second,
                    trackCount = count,
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
        return valid.chunked(SQLITE_IN_CHUNK_SIZE)
            .flatMap { ids ->
                dao.trackPayloadsForCategory(
                    validGlobalIds = ids,
                    dimension = dimension,
                    value = tagId,
                )
            }
            .mapNotNull { row ->
                decodeTrack(row.payload, expectedServer = serverId)?.let { track ->
                    RankedTrack(track, row.confidence)
                }
            }
            .sortedWith(
                compareByDescending<RankedTrack> { it.confidence }
                    .thenBy { it.track.title.lowercase(Locale.ROOT) }
                    .thenBy { it.track.globalId.serialized },
            )
            .take(limit.coerceIn(1, 2_000))
            .map(RankedTrack::track)
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
        replaceClassifications(
            serverId = serverId,
            classifications = listOf(RecommendationIndexClassificationInput(globalId, tags)),
            classifier = classifier,
            classifiedAtMillis = classifiedAtMillis,
        )
    }

    /**
     * Atomically replaces a complete classifier batch. Validation happens for every item before
     * opening the transaction, so a malformed or partial model response cannot commit a subset.
     */
    suspend fun replaceClassifications(
        serverId: ServerId,
        classifications: List<RecommendationIndexClassificationInput>,
        classifier: String = "configured-agent",
        classifiedAtMillis: Long = System.currentTimeMillis(),
    ) {
        require(classifications.isNotEmpty()) { "Recommendation Index classification batch 不能为空" }
        require(classifications.size <= 100) { "Recommendation Index classification batch 不能超过 100 首" }
        require(classifier.isNotBlank()) { "Recommendation Index classifier 不能为空" }

        val ids = classifications.map { item ->
            require(item.globalId.serverId == serverId) { "Recommendation Index server/global-id 不一致" }
            item.globalId.serialized
        }
        require(ids.size == ids.toSet().size) { "Recommendation Index classification batch 含重复 global-id" }
        val entitiesById = database.trackDao().getMany(ids).associateBy { it.globalId }
        require(entitiesById.size == ids.size) { "Recommendation Index classification batch 含不存在的曲目" }

        val prepared = classifications.map { item ->
            val entity = entitiesById[item.globalId.serialized]
                ?: error("Recommendation Index 曲目不存在: ${item.globalId.serialized}")
            require(entity.serverId == serverId.value) { "Recommendation Index 曲目服务器不一致" }
            val currentTrack = decodeTrack(entity.payload, expectedServer = serverId)
                ?: throw IllegalArgumentException("Recommendation Index 曲目 payload 无法验证: ${item.globalId.serialized}")
            require(currentTrack.globalId == item.globalId) { "Recommendation Index payload/global-id 不一致" }
            PreparedClassification(
                globalId = item.globalId,
                sourceHash = RecommendationIndex.contentHash(currentTrack),
                tags = canonicalizeTags(item.tags),
            )
        }

        database.withTransaction {
            prepared.forEach { item ->
                dao.upsertState(
                    RecommendationIndexStateEntity(
                        globalId = item.globalId.serialized,
                        serverId = serverId.value,
                        sourceHash = item.sourceHash,
                        rulesVersion = RecommendationIndex.RULES_VERSION,
                        classifier = classifier,
                        classifiedAt = classifiedAtMillis,
                        sourceHashVersion = RecommendationIndex.CONTENT_HASH_VERSION,
                        semanticTagRulesVersion = 0,
                    ),
                )
                dao.deleteTags(item.globalId.serialized)
                if (item.tags.isNotEmpty()) {
                    dao.upsertTags(
                        item.tags.map { tag ->
                            RecommendationIndexTagEntity(
                                globalId = item.globalId.serialized,
                                dimension = tag.dimension,
                                value = tag.value,
                                confidence = tag.confidence,
                            )
                        },
                    )
                }
            }
        }
    }

    private fun canonicalizeTags(tags: List<RecommendationIndexTag>): List<RecommendationIndexTag> {
        val canonical = LinkedHashMap<Pair<String, String>, RecommendationIndexTag>()
        tags.forEach { tag ->
            val dimension = tag.dimension.trim()
            require(RecommendationIndex.isFixedDimension(dimension)) {
                "Recommendation Index 非固定维度: ${tag.dimension}"
            }
            require(tag.confidence.isFinite() && tag.confidence in 0.0..1.0) {
                "Recommendation Index confidence 必须在 0...1"
            }
            val value = tag.value.trim()
            require(value.isNotEmpty()) { "Recommendation Index TagID 不能为空" }
            val canonicalValue = when {
                dimension in RecommendationIndex.textualDimensions -> {
                    require(RecommendationIndexTaxonomy.isKnownTextTag(dimension, value)) {
                        "Recommendation Index 未知 taxonomy TagID: $value"
                    }
                    value
                }

                RecommendationIndex.isNumericDimension(dimension) -> {
                    val number = value.toDoubleOrNull()
                    val upperBound = RecommendationIndex.numericUpperBounds.getValue(dimension)
                    require(number != null && number.isFinite() && number % 1.0 == 0.0) {
                        "Recommendation Index 数值特征必须为整数: $dimension=$value"
                    }
                    require(number in 1.0..upperBound.toDouble()) {
                        "Recommendation Index 数值特征超出范围: $dimension=$value"
                    }
                    number.toInt().toString()
                }

                else -> error("Recommendation Index 非固定维度: $dimension")
            }
            val key = dimension to canonicalValue
            val previous = canonical[key]
            if (previous == null || tag.confidence > previous.confidence) {
                canonical[key] = RecommendationIndexTag(dimension, canonicalValue, tag.confidence)
            }
        }
        return canonical.values.toList()
    }

    private data class PreparedClassification(
        val globalId: GlobalId,
        val sourceHash: String,
        val tags: List<RecommendationIndexTag>,
    )

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

    private data class RankedTrack(
        val track: Track,
        val confidence: Double,
    )

    private companion object {
        // Android SQLite 默认最多 999 个 bind 参数；保留余量，防止 Room 后续加筛选参数。
        const val SQLITE_IN_CHUNK_SIZE = 900
    }
}
