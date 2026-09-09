// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/**
 * Recommendation Index v3 状态表。表名与 Apple catalog.sqlite 保持一致，便于后续
 * 导入/导出与双平台审计；server_id 显式保留以维持 Android 的 server-scoped 清理策略。
 */
@Entity(
    tableName = "recommendation_index_v2_state",
    primaryKeys = ["global_id"],
    indices = [Index("server_id")],
)
data class RecommendationIndexStateEntity(
    @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "server_id") val serverId: String,
    @ColumnInfo(name = "source_hash") val sourceHash: String,
    @ColumnInfo(name = "rules_version") val rulesVersion: String,
    @ColumnInfo(name = "classifier") val classifier: String,
    @ColumnInfo(name = "classified_at") val classifiedAt: Long,
    @ColumnInfo(name = "source_hash_version") val sourceHashVersion: Int,
    @ColumnInfo(name = "semantic_tag_rules_version") val semanticTagRulesVersion: Int,
)

/**
 * 固定 taxonomy 标签。value 存稳定 TagID（例如 `mood.sacred`），不存本地化展示名。
 * server 归属由 state.global_id 关联得到，避免在 tag 行重复维护 server_id。
 */
@Entity(
    tableName = "recommendation_index_v2_tags",
    primaryKeys = ["global_id", "dimension", "value"],
    indices = [Index(value = ["dimension", "value"])],
)
data class RecommendationIndexTagEntity(
    @ColumnInfo(name = "global_id") val globalId: String,
    @ColumnInfo(name = "dimension") val dimension: String,
    @ColumnInfo(name = "value") val value: String,
    @ColumnInfo(name = "confidence") val confidence: Double,
)
