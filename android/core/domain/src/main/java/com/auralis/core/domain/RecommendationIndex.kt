// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

/**
 * Android Recommendation Index 的稳定协议面。
 *
 * 对齐 Apple `RecommendationIndex` v3：分类只允许写入固定维度，开放语义 tag 不再是
 * 生产路径。具体 TagID taxonomy 由同一规则版本约束；数据库与 UI 只保存稳定 ID，
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

    /**
     * 与 Apple `recommendationIndexContentHash` 位级一致的 v2 内容指纹。
     *
     * 只包含相对稳定的歌曲内容身份：remote id / 标题 / 艺人 / 专辑 / 年份 /
     * 标准化流派 / 语言 / 整数秒时长。收藏、评分、播放次数、下载状态等个人行为数据
     * 明确不进入 hash，否则一次收藏就会让 mood/scene/style 等 AI 分类全部失效。
     *
     * 算法 = UTF-8 上的 64-bit FNV-1a；分隔符与 Apple 都使用 U+001F。
     */
    fun contentHash(track: Track): String {
        val normalizedGenres = track.genres
            .map(String::trim)
            .filter(String::isNotEmpty)
            .distinct()
            .sorted()
        val parts = listOf(
            track.id.value,
            track.title.trim(),
            track.artistName.trim(),
            track.albumTitle.trim(),
            track.year?.toString().orEmpty(),
            normalizedGenres.joinToString("|"),
            track.language?.trim().orEmpty(),
            track.durationSeconds.toInt().toString(),
        )
        val source = parts.joinToString("\u001F")
        var hash = 14_695_981_039_346_656_037uL
        for (byte in source.encodeToByteArray()) {
            hash = (hash xor byte.toUByte().toULong()) * 1_099_511_628_211uL
        }
        return hash.toString(16)
    }
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
    /** 可安全放进导航值的稳定 id。dimension 是固定枚举，TagID 保留原样。 */
    val id: String get() = "$dimension:$tagId"
}

/** 解析导航中的稳定分类 id；只在第一个冒号处分割，避免未来 TagID 自身扩展时被截断。 */
fun parseRecommendationCategoryId(raw: String): Pair<String, String>? {
    val separator = raw.indexOf(':')
    if (separator <= 0 || separator >= raw.lastIndex) return null
    val dimension = raw.substring(0, separator)
    val tagId = raw.substring(separator + 1)
    if (!RecommendationIndex.isFixedDimension(dimension) || tagId.isBlank()) return null
    return dimension to tagId
}

/** 本地索引覆盖状态。pending 只统计当前 rulesVersion + 当前内容指纹尚无有效 state 的曲目。 */
data class RecommendationIndexStatus(
    val totalTracks: Int,
    val indexedTracks: Int,
    val pendingTracks: Int,
    val rulesVersion: String = RecommendationIndex.RULES_VERSION,
)
