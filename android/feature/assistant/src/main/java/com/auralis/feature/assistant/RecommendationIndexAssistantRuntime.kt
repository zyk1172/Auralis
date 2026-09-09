// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.auralis.core.ai.AiCompletionRequest
import com.auralis.core.ai.AiMessage
import com.auralis.core.ai.AiProvider
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.domain.RecommendationIndex
import com.auralis.core.domain.RecommendationIndexBatch
import com.auralis.core.domain.RecommendationIndexProgress
import com.auralis.core.domain.RecommendationIndexRunResult
import com.auralis.core.domain.RecommendationIndexTaxonomy
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

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
            val classifications = RecommendationIndexResponseParser(json).parse(response.content, batch)
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
            putJsonArray("genres") {
                track.genres.take(MAX_GENRES).forEach { genre -> add(JsonPrimitive(genre)) }
            }
        }
        track.language?.takeIf { it.isNotBlank() }?.let { put("language", it) }
        put("durationSeconds", track.durationSeconds)
    }

    private companion object {
        const val DEFAULT_BATCH_SIZE = 24
        const val MAX_BATCH_SIZE = 100
        const val CLASSIFICATION_MAX_OUTPUT_TOKENS = 8_000
        const val MAX_GENRES = 12
    }
}
