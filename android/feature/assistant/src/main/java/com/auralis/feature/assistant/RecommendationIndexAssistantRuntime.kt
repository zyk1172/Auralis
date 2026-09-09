// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.auralis.core.ai.AiCompletionRequest
import com.auralis.core.ai.AiMessage
import com.auralis.core.ai.AiProvider
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.RecommendationIndex
import com.auralis.core.domain.RecommendationIndexBatch
import com.auralis.core.domain.RecommendationIndexClassificationInput
import com.auralis.core.domain.RecommendationIndexTag
import com.auralis.core.domain.RecommendationIndexTaxonomy
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** Progress emitted while the explicit Assistant index-build workflow is running. */
data class RecommendationIndexProgress(
    val batchNumber: Int,
    val batchSize: Int,
    val indexedTracks: Int,
    val totalTracks: Int,
    val pendingTracks: Int,
)

data class RecommendationIndexRunResult(
    val totalTracks: Int,
    val indexedTracks: Int,
    val pendingTracks: Int,
)

/**
 * Closed-transform classifier for the Android Recommendation Index.
 *
 * This is deliberately separate from AgentToolLoop: the model receives only a bounded metadata
 * batch and a fixed taxonomy, and can return no tool calls. The store then validates and commits
 * the complete batch atomically before the next batch is requested.
 */
class RecommendationIndexAssistantRuntime(
    private val graph: AuralisGraph,
    private val provider: AiProvider,
    private val model: String,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    suspend fun run(
        serverId: ServerId,
        batchSize: Int = DEFAULT_BATCH_SIZE,
        onProgress: (RecommendationIndexProgress) -> Unit = {},
    ): RecommendationIndexRunResult {
        require(batchSize in 1..MAX_BATCH_SIZE) { "Recommendation Index batch size 必须在 1...$MAX_BATCH_SIZE" }
        var batchNumber = 0
        var lastTotal = 0
        var lastIndexed = 0
        var lastPending = 0

        while (true) {
            currentCoroutineContext().ensureActive()
            val batch = graph.recommendationIndex.nextBatch(serverId, batchSize)
            lastTotal = batch.totalTracks
            lastIndexed = batch.indexedTracks
            lastPending = batch.pendingTracks
            if (batch.pendingTracks == 0) {
                return RecommendationIndexRunResult(lastTotal, lastIndexed, lastPending)
            }
            if (batch.tracks.isEmpty()) {
                val reason = if (batch.unreadableTracks > 0) {
                    "有 ${batch.unreadableTracks} 首曲目的本地 payload 无法解码"
                } else {
                    "没有可提交的待分类曲目"
                }
                throw IllegalStateException("推荐索引无法继续：$reason")
            }

            batchNumber += 1
            onProgress(
                RecommendationIndexProgress(
                    batchNumber = batchNumber,
                    batchSize = batch.tracks.size,
                    indexedTracks = batch.indexedTracks,
                    totalTracks = batch.totalTracks,
                    pendingTracks = batch.pendingTracks,
                ),
            )
            val response = provider.complete(classificationRequest(batch))
            val classifications = parseResponse(response.content, batch)
            graph.recommendationIndex.replaceClassifications(
                serverId = serverId,
                classifications = classifications,
                classifier = "android-recommendation-index/$model",
            )

            val after = graph.recommendationIndex.status(serverId)
            lastTotal = after.totalTracks
            lastIndexed = after.indexedTracks
            lastPending = after.pendingTracks
            onProgress(
                RecommendationIndexProgress(
                    batchNumber = batchNumber,
                    batchSize = classifications.size,
                    indexedTracks = after.indexedTracks,
                    totalTracks = after.totalTracks,
                    pendingTracks = after.pendingTracks,
                ),
            )
        }
    }

    private fun classificationRequest(batch: RecommendationIndexBatch): AiCompletionRequest {
        val tracks = buildJsonArray {
            batch.tracks.forEach { track ->
                add(trackEvidence(track))
            }
        }
        val userPayload = buildJsonObject {
            put("items", tracks)
        }.toString()
        val system = """
            你是 Auralis 推荐索引分类器。你只做一个闭合转换：根据输入曲目元数据，为每首曲目返回固定 taxonomy 标签和有证据的数值特征。
            只能输出一个 JSON object，不能输出 Markdown、解释、工具调用或额外文字，形状必须是 {"items":[...]}。
            items 必须逐一覆盖输入中的全部 id，不能新增、删除、重复或改写 id。每个 item 至少包含 id；tags 是固定 taxonomy ID 的字符串数组；features 只能使用下列数值字段。
            不确定的标签或没有充分证据的字段省略，不要臆造；没有可判断标签时仍返回空 tags/features。confidence 是 0 到 1 的数字，可省略。
            数值范围：energy=1..10，其余 tempo/acousticness/danceability/instrumentalness/liveness/speechiness/valence/complexity=1..5，且必须是整数。
            固定 taxonomy（ID=中文名）：
            ${RecommendationIndexTaxonomy.compactCatalog()}
        """.trimIndent()
        return AiCompletionRequest(
            model = model,
            messages = listOf(
                AiMessage(AiMessage.Role.System, system),
                AiMessage(AiMessage.Role.User, userPayload),
            ),
            temperature = 0.2,
            maxTokens = CLASSIFICATION_MAX_OUTPUT_TOKENS,
            tools = null,
            toolChoice = null,
        )
    }

    private fun trackEvidence(track: Track): JsonElement = buildJsonObject {
        put("id", track.globalId.serialized)
        putJsonObject("globalID") {
            put("serverID", track.serverId.value)
            put("remoteID", track.id.value)
        }
        put("title", track.title)
        put("artist", track.artistName)
        put("album", track.albumTitle)
        track.year?.let { put("year", it) }
        if (track.genres.isNotEmpty()) {
            putJsonArray("genres") { track.genres.take(MAX_GENRES).forEach { genre -> add(genre) } }
        }
        track.language?.takeIf { it.isNotBlank() }?.let { put("language", it) }
        put("durationSeconds", track.durationSeconds)
    }

    private fun parseResponse(content: String, batch: RecommendationIndexBatch): List<RecommendationIndexClassificationInput> {
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
        const val DEFAULT_BATCH_SIZE = 24
        const val MAX_BATCH_SIZE = 100
        const val CLASSIFICATION_MAX_OUTPUT_TOKENS = 8_000
        const val MAX_GENRES = 12
    }
}
