// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

/**
 * Android Recommendation Index 的稳定协议面。
 *
 * 对齐 Apple `RecommendationIndex` v3：分类只允许写入固定维度，开放语义 tag 不再是
 * 生产路径。具体 TagID taxonomy 后续由同一规则版本扩展；数据库与 UI 只保存稳定 ID，
 * 不把展示文案当主键。
 */
object RecommendationIndex {
    const val RULES_VERSION = "3.0"
    const val CONTENT_HASH_VERSION = 2

    val fixedDimensions: Set<String> = setOf(
        "mood", "scene", "theme", "genre", "style",
        "vocal", "instrument", "texture", "rhythm",
        "energy", "tempo", "acousticness", "danceability",
        "instrumentalness", "liveness", "speechiness", "valence", "complexity",
    )

    fun isFixedDimension(value: String): Boolean = value in fixedDimensions
}

/** 一条固定 taxonomy 标签。value 应为稳定 TagID，而不是本地化展示名。 */
data class RecommendationIndexTag(
    val dimension: String,
    val value: String,
    val confidence: Double,
)

/** Library Categories 展示用聚合项。 */
data class RecommendationIndexCategory(
    val dimension: String,
    val tagId: String,
    val trackCount: Int,
) {
    /** 可安全放进导航值的稳定 id。 */
    val id: String get() = "$dimension:$tagId"
}

/** 本地索引覆盖状态。pending 这里只统计当前 rulesVersion 尚无有效 state 的曲目。 */
data class RecommendationIndexStatus(
    val totalTracks: Int,
    val indexedTracks: Int,
    val pendingTracks: Int,
    val rulesVersion: String = RecommendationIndex.RULES_VERSION,
)
