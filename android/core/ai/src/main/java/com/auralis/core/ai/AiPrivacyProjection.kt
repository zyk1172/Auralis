// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

// ---------------------------------------------------------------------------
// AI-12：披露权限的模型投影层。
//
// 工具结果在回灌模型前经过这里：受限类别只回元信息/计数，正文不外发。
// 只在「发给模型的投影」生效；本地 UI 与本地数据不受限。
// ---------------------------------------------------------------------------

object AiPrivacyProjection {

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * 把工具结果投影为可外发给模型的文本。
     * [category] 为 null 或权限允许时原样返回；否则按类别摘要化/字段剥离。
     */
    fun projectToolResult(
        category: AiPrivacyCategory?,
        result: String,
        permissions: AiPrivacyPermissions,
    ): String {
        if (category == null || permissions.allows(category)) return result
        val parsed = runCatching { json.parseToJsonElement(result) as? JsonObject }.getOrNull()
        return when (category) {
            AiPrivacyCategory.Lyrics -> {
                // 歌词正文不外发：只回有/无、行数、语言、是否滚动。
                if (parsed == null) return "歌词正文已按隐私设置隐藏，未外发。"
                val ok = parsed["ok"]?.jsonPrimitive?.contentOrNull == "true"
                if (!ok) return result // 「没有可用歌词」本身不含正文
                buildString {
                    append("歌词正文已按隐私设置隐藏。元信息：")
                    append("有歌词，行数=").append(parsed["lineCount"]?.jsonPrimitive?.intOrNull ?: 0)
                    append("，语言=").append(parsed["language"]?.jsonPrimitive?.contentOrNull?.ifBlank { "未知" } ?: "未知")
                    append("，滚动=").append(parsed["synced"]?.jsonPrimitive?.contentOrNull ?: "false")
                }
            }

            AiPrivacyCategory.PlaybackHistory -> {
                // 播放历史/队列：只回条目数，不回具体曲目。
                val count = parsed?.get("count")?.jsonPrimitive?.intOrNull
                    ?: parsed?.get("totalCount")?.jsonPrimitive?.intOrNull
                if (count != null) "播放队列/历史内容已按隐私设置隐藏（共 $count 条）。"
                else "播放历史相关内容已按隐私设置隐藏，未外发。"
            }

            AiPrivacyCategory.FavoritesAndRatings -> {
                // 收藏/评分：列表只回数量；单条结果剥离 isFavorite/rating 字段；纯文本确认脱敏。
                if (parsed == null) return "收藏/评分操作结果已按隐私设置隐藏。"
                val tracksNode = parsed["tracks"]
                val count = parsed["count"]?.jsonPrimitive?.intOrNull
                    ?: (tracksNode as? kotlinx.serialization.json.JsonArray)?.size
                    ?: (tracksNode as? JsonObject)?.get("count")?.jsonPrimitive?.intOrNull
                if (tracksNode != null || count != null) {
                    return "收藏/评分内容已按隐私设置隐藏（共 ${count ?: "?"} 条）。"
                }
                if ("isFavorite" in parsed || "rating" in parsed) {
                    return JsonObject(
                        parsed.toMutableMap().apply {
                            remove("isFavorite")
                            remove("rating")
                        },
                    ).toString()
                }
                "收藏/评分内容已按隐私设置隐藏，未外发。"
            }

            else -> "该结果类别已按隐私设置隐藏，未外发。"
        }
    }
}
