// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/** Library Categories 聚合行。 */
data class RecommendationCategoryRow(
    val dimension: String,
    val value: String,
    val trackCount: Int,
)

/**
 * Recommendation Index 的唯一 Room 访问边界。
 *
 * 所有 category/track 查询都通过 state 表约束 server_id + rules_version，避免两个服务器
 * 出现相同 remote id / TagID 时互相污染，也不会把旧 taxonomy 的行混进当前分类页。
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
        SELECT COUNT(DISTINCT s.global_id)
        FROM recommendation_index_v2_state s
        INNER JOIN tracks t ON t.global_id = s.global_id
        WHERE s.server_id = :serverId AND s.rules_version = :rulesVersion
        """,
    )
    suspend fun indexedTrackCount(serverId: String, rulesVersion: String): Int

    @Query(
        """
        SELECT tag.dimension AS dimension,
               tag.value AS value,
               COUNT(DISTINCT tag.global_id) AS trackCount
        FROM recommendation_index_v2_tags tag
        INNER JOIN recommendation_index_v2_state state
            ON state.global_id = tag.global_id
        INNER JOIN tracks track
            ON track.global_id = tag.global_id
        WHERE state.server_id = :serverId
          AND state.rules_version = :rulesVersion
        GROUP BY tag.dimension, tag.value
        ORDER BY trackCount DESC, tag.dimension ASC, tag.value ASC
        """,
    )
    suspend fun categories(serverId: String, rulesVersion: String): List<RecommendationCategoryRow>

    @Query(
        """
        SELECT track.payload
        FROM tracks track
        INNER JOIN recommendation_index_v2_tags tag
            ON tag.global_id = track.global_id
        INNER JOIN recommendation_index_v2_state state
            ON state.global_id = track.global_id
        WHERE state.server_id = :serverId
          AND state.rules_version = :rulesVersion
          AND tag.dimension = :dimension
          AND tag.value = :value
        ORDER BY tag.confidence DESC, track.title COLLATE NOCASE ASC
        LIMIT :limit
        """,
    )
    suspend fun trackPayloadsForCategory(
        serverId: String,
        rulesVersion: String,
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
