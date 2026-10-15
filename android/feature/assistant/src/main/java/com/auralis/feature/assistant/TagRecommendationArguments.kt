// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.assistant

import com.auralis.core.domain.RecommendationIndex
import com.auralis.core.domain.TagRecommendationQuery
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

internal object TagRecommendationArguments {
    private val properties = Json.parseToJsonElement("""{
        "includeTags":{"type":"array","items":{"type":"string"},"maxItems":200,"description":"必须同时匹配的稳定 TagID，AND，不放宽"},
        "preferTags":{"type":"array","items":{"type":"string"},"maxItems":200,"description":"偏好TagID，跨维度平衡、多个独立命中奖励；同义词不重复计分；无正向硬条件时至少命中一项"},
        "anyTagGroups":{"type":"array","maxItems":20,"items":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"string"}},"description":"组内AND、组间OR，至少完整满足一组，同时执行includeTags及排除/范围；如[[scene.study,instrument.piano],[scene.late_night,instrument.acoustic_guitar]]"},
        "minimumPreferredMatches":{"type":"integer","minimum":0,"maximum":200,"description":"至少命中N个不同preferTags；默认0：有正向硬条件时偏好可不命中，否则至少1；同义词只算一个"},
        "excludeTags":{"type":"array","items":{"type":"string"},"maxItems":200,"description":"排除任一命中的标签"},
        "numericRanges":{"type":"object","additionalProperties":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2},"description":"数值维度到[min,max]；energy 1..10，其余特征1..5；tempo不是BPM"},
        "excludeTrackIDs":{"type":"array","items":{"type":"string"},"maxItems":200,"description":"已展示歌曲的GlobalTrackID字符串"},
        "minimumConfidence":{"type":"number","minimum":0,"maximum":1},
        "maxPerAlbum":{"type":"integer","minimum":1,"maximum":10},
        "maxPerArtist":{"type":"integer","minimum":1,"maximum":10},
        "limit":{"type":"integer","minimum":1,"maximum":100}
    }""").jsonObject

    val schema: String = buildJsonObject { put("type", "object"); put("properties", properties) }.toString()

    fun collisionSchema(original: String): String {
        val objectValue = Json.parseToJsonElement(original).jsonObject
        // Collision uses targetCount; advertising a second ignored limit would make model calls ambiguous.
        return JsonObject(objectValue + ("properties" to JsonObject((properties - "limit") + objectValue.getValue("properties").jsonObject))).toString()
    }

    fun query(args: Map<String, JsonElement>, limit: Int): TagRecommendationQuery {
        fun strings(key: String): List<String> {
            val raw = args[key]?.takeUnless { it == JsonNull } ?: return emptyList()
            require(raw is JsonArray && raw.size <= 200) { "$key 必须为字符串数组，最多200项" }
            return raw.map { node ->
                require(node is JsonPrimitive && node.isString && node.content.isNotBlank()) { "$key 含无效字符串" }
                node.content
            }
        }
        val ranges = args["numericRanges"]?.takeUnless { it == JsonNull }?.let { raw ->
            require(raw is JsonObject) { "numericRanges 必须为对象" }
            raw.mapValues { (dimension, node) ->
                val upper = RecommendationIndex.numericUpperBounds[dimension]
                require(upper != null && node is JsonArray && node.size == 2) { "无效范围：$dimension" }
                val lower = (node[0] as? JsonPrimitive)?.intOrNull
                val higher = (node[1] as? JsonPrimitive)?.intOrNull
                require(lower != null && higher != null && lower >= 1 && higher <= upper && lower <= higher) { "无效范围：$dimension" }
                lower..higher
            }
        }.orEmpty()
        val confidence = args["minimumConfidence"]?.takeUnless { it == JsonNull }?.let {
            (it as? JsonPrimitive)?.doubleOrNull ?: throw IllegalArgumentException("无效 minimumConfidence")
        } ?: 0.35
        val groups = args["anyTagGroups"]?.takeUnless { it == JsonNull }?.let { raw ->
            require(raw is JsonArray && raw.size <= 20) { "anyTagGroups 最多20组" }
            raw.map { group ->
                require(group is JsonArray && group.isNotEmpty() && group.size <= 20) { "anyTagGroups 每组1..20个标签" }
                group.map { node ->
                    require(node is JsonPrimitive && node.isString && node.content.isNotBlank()) { "anyTagGroups 含无效标签" }
                    node.content
                }
            }
        }.orEmpty()
        val minimumMatches = args["minimumPreferredMatches"]?.takeUnless { it == JsonNull }?.let {
            require(it is JsonPrimitive && !it.isString) { "minimumPreferredMatches 必须为整数" }
            requireNotNull(it.intOrNull) { "minimumPreferredMatches 必须为整数" }
        } ?: 0
        return TagRecommendationQuery(includeTags = strings("includeTags"), preferTags = strings("preferTags"),
            excludeTags = strings("excludeTags"), anyTagGroups = groups, minimumPreferredMatches = minimumMatches,
            numericRanges = ranges, excludedTrackIds = strings("excludeTrackIDs").toSet(),
            minimumConfidence = confidence, maxPerArtist = (args["maxPerArtist"] as? JsonPrimitive)?.intOrNull ?: 2,
            maxPerAlbum = (args["maxPerAlbum"] as? JsonPrimitive)?.intOrNull ?: 2, limit = limit)
    }
}
