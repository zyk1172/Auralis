// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/** 当前 rulesVersion 的 state + 当前 Track payload；Store 用 Apple 同源内容 hash 判定是否仍有效。 */
data class RecommendationStateTrackRow(
    val globalId: String,
    val sourceHash: String,
    val sourceHashVersion: Int,
    val payload: String,
)

/** Library Categories 聚合行。 */
data class RecommendationCategoryRow(
    val dimension: String,
    val value: String,
    val trackCount: Int,
)

/**
 * Recommendation Index 的唯一 Room 访问边界。
 *
 * SQL 只负责 server/rulesVersion/TagID 范围；“state 是否仍匹配当前歌曲内容”不能只靠
 * rulesVersion 判断，必须由 Store 解码当前 Track payload 并重算 v2 content hash。
 * 这样改标题/专辑/流派后旧分类会自然变 pending，不会继续污染 Categories。
 */
@Dao
interface RecommendationIndexDao {
    @Query(
        """
        SELECT COUNT(*) FROM tracks
        WHERE server_id = :serverId
        """,
    )
    suspend fun totalTrackCount(serverId: String): Int

    @Query(
        """
        SELECT state.global_id AS globalId,
               state.source_hash AS sourceHash,
               state.source_hash_version AS sourceHashVersion,
               track.payload AS payload
        FROM recommendation_index_v2_state state
        INNER JOIN tracks track ON track.global_id = state.global_id
        WHERE state.server_id = :serverId
          AND state.rules_version = :rulesVersion
        ORDER BY state.global_id ASC
        """,
    )
    suspend fun stateTrackRows(serverId: String, rulesVersion: String): List<RecommendationStateTrackRow>

    /**
     * Categories 只对 Store 已验证过 content hash 的 global id 做聚合。
     * Room 支持 collection 展开为 IN (...)；调用方保证 ids 非空。
     */
    @Query(
        """
        SELECT tag.dimension AS dimension,
               tag.value AS value,
               COUNT(DISTINCT tag.global_id) AS trackCount
        FROM recommendation_index_v2_tags tag
        WHERE tag.global_id IN (:validGlobalIds)
        GROUP BY tag.dimension, tag.value
        ORDER BY trackCount DESC, tag.dimension ASC, tag.value ASC
        """,
    )
    suspend fun categoriesForValidTracks(validGlobalIds: List<String>): List<RecommendationCategoryRow>

    @Query(
        """
        SELECT track.payload
        FROM tracks track
        INNER JOIN recommendation_index_v2_tags tag
            ON tag.global_id = track.global_id
        WHERE tag.global_id IN (:validGlobalIds)
          AND tag.dimension = :dimension
          AND tag.value = :value
        ORDER BY tag.confidence DESC, track.title COLLATE NOCASE ASC
        LIMIT :limit
        """,
    )
    suspend fun trackPayloadsForCategory(
        validGlobalIds: List<String>,
        dimension: String,
        value: String,
        limit: Int,
    ): List<String>

    @Query("SELECT * FROM recommendation_index_v2_state WHERE global_id = :globalId LIMIT 1")
    suspend fun state(globalId: String): RecommendationIndexStateEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertState(entity: RecommendationIndexStateEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertTags(entities: List<RecommendationIndexTagEntity>)

    @Query("DELETE FROM recommendation_index_v2_tags WHERE global_id = :globalId")
    suspend fun deleteTags(globalId: String)

    @Query(
        """
        DELETE FROM recommendation_index_v2_tags
        WHERE global_id IN (
            SELECT global_id FROM recommendation_index_v2_state WHERE server_id = :serverId
        )
        """,
    )
    suspend fun deleteTagsForServer(serverId: String)

    @Query("DELETE FROM recommendation_index_v2_state WHERE server_id = :serverId")
    suspend fun deleteStateForServer(serverId: String)
}
