// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.RecommendationIndex
import com.auralis.core.domain.RecommendationIndexBatch
import com.auralis.core.domain.RecommendationIndexClassificationInput
import com.auralis.core.domain.RecommendationIndexTag
import com.auralis.core.domain.RecommendationIndexTaxonomy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Strict boundary for model output; malformed or partial batches fail before the DB transaction. */
internal class RecommendationIndexResponseParser(
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    fun parse(content: String, batch: RecommendationIndexBatch): List<RecommendationIndexClassificationInput> {
        val objectText = extractJSONObject(content)
            ?: throw IllegalArgumentException("推荐索引分类响应不是 JSON object")
        val root = runCatching { json.parseToJsonElement(objectText).jsonObject }
            .getOrElse { throw IllegalArgumentException("推荐索引分类响应 JSON 无法解析", it) }
        val items = root["items"]?.let { element ->
            runCatching { element.jsonArray }.getOrNull()
        } ?: throw IllegalArgumentException("推荐索引分类响应缺少 items 数组")
        if (items.isEmpty() || items.size > MAX_BATCH_SIZE) {
            throw IllegalArgumentException("推荐索引分类响应 items 数量无效：${items.size}")
        }

        val expected = batch.tracks.associateBy { it.globalId.serialized }
        val seen = LinkedHashSet<String>()
        val result = items.mapIndexed { index, element ->
            val item = runCatching { element.jsonObject }.getOrElse {
                throw IllegalArgumentException("推荐索引 items[$index] 必须是 object", it)
            }
            val id = item["id"]?.jsonPrimitive?.contentOrNull?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: throw IllegalArgumentException("推荐索引 items[$index].id 不能为空")
            require(seen.add(id)) { "推荐索引分类响应含重复 id：$id" }
            require(id in expected) { "推荐索引分类响应含当前 batch 之外的 id：$id" }
            RecommendationIndexClassificationInput(
                globalId = GlobalId.parse(id).also { parsed ->
                    require(parsed.serverId == batch.serverId) { "推荐索引分类响应 serverID 不一致：$id" }
                },
                tags = parseTags(item),
            )
        }
        require(seen == expected.keys) {
            "推荐索引分类响应未完整覆盖当前 batch（应有 ${expected.size} 首，实际 ${seen.size} 首）"
        }
        return result
    }

    private fun parseTags(item: Map<String, JsonElement>): List<RecommendationIndexTag> {
        val confidence = item["confidence"]?.jsonPrimitive?.contentOrNull
            ?.toDoubleOrNull()?.takeIf { it.isFinite() && it in 0.0..1.0 } ?: 0.5
        val tags = ArrayList<RecommendationIndexTag>()
        item["tags"]?.let { element ->
            runCatching { element.jsonArray }.getOrNull()?.forEach { tagElement ->
                val id = runCatching { tagElement.jsonPrimitive.contentOrNull }.getOrNull()?.trim()
                    ?: return@forEach
                val definition = RecommendationIndexTaxonomy.definition(id) ?: return@forEach
                tags += RecommendationIndexTag(definition.dimension, definition.id, confidence)
            }
        }
        item["features"]?.let { element ->
            runCatching { element.jsonObject }.getOrNull()?.forEach { (dimension, valueElement) ->
                val upperBound = RecommendationIndex.numericUpperBounds[dimension] ?: return@forEach
                val number = runCatching { valueElement.jsonPrimitive.contentOrNull?.toDoubleOrNull() }
                    .getOrNull() ?: return@forEach
                if (!number.isFinite() || number % 1.0 != 0.0 || number !in 1.0..upperBound.toDouble()) return@forEach
                tags += RecommendationIndexTag(dimension, number.toInt().toString(), confidence)
            }
        }
        return tags
    }

    private fun extractJSONObject(raw: String): String? {
        val source = raw.trim()
            .removePrefix("```json")
            .removePrefix("```JSON")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        val start = source.indexOf('{')
        if (start < 0) return null
        var depth = 0
        var inString = false
        var escaped = false
        for (index in start until source.length) {
            when (val character = source[index]) {
                '"' -> if (!escaped) inString = !inString
                '\\' -> if (inString) escaped = !escaped
                else -> {
                    escaped = false
                    if (!inString) {
                        if (character == '{') depth += 1
                        if (character == '}') {
                            depth -= 1
                            if (depth == 0) return source.substring(start, index + 1)
                        }
                    }
                }
            }
        }
        return null
    }

    private companion object {
        const val MAX_BATCH_SIZE = 100
    }
}
