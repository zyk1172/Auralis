// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.data.recommendation

import com.auralis.core.ai.AiCompletionRequest
import com.auralis.core.ai.AiProvider
import com.auralis.core.ai.AiCompletionResponse
import com.auralis.core.ai.AiProviderException
import com.auralis.core.ai.AiProviderFailureKind
import com.auralis.core.ai.AiReasoningConfiguration
import com.auralis.core.ai.AiStreamEvent
import com.auralis.core.ai.AiStreamTermination
import com.auralis.core.ai.AiStreamTerminationKind
import com.auralis.core.data.repository.RecommendationIndexStore
import com.auralis.core.domain.RecommendationIndex
import com.auralis.core.domain.RecommendationIndexBatch
import com.auralis.core.domain.RecommendationIndexProgress
import com.auralis.core.domain.RecommendationIndexRunResult
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.collect
import java.io.IOException
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
class TagClassificationRunner(
    private val store: RecommendationIndexStore,
    private val provider: AiProvider,
    private val model: String,
    private val json: Json = Json { ignoreUnknownKeys = true },
    private val maxOutputTokens: Int = 8_000,
    private val reasoning: AiReasoningConfiguration? = null,
    private val requestTimeoutMillis: Long = 300_000,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun run(
        serverId: ServerId,
        batchSize: Int = DEFAULT_BATCH_SIZE,
        authorize: suspend () -> Unit = {},
        onRetry: (Long, String) -> Unit = { _, _ -> },
        onProgress: (RecommendationIndexProgress) -> Unit = {},
    ): RecommendationIndexRunResult {
        require(batchSize in 1..MAX_BATCH_SIZE) { "Recommendation Index batch size 必须在 1...$MAX_BATCH_SIZE" }
        val outputTokens = minOf(maxOutputTokens.coerceIn(512, CLASSIFICATION_MAX_OUTPUT_TOKENS),
            provider.capabilities.maxOutputTokens, maxOf(512, provider.capabilities.maxContextTokens / 4))
        var size = minOf(batchSize, DEFAULT_BATCH_SIZE, maxOf(1, outputTokens / 512))
        var batchNumber = 0
        var failures = 0
        var lastSaved = -1
        var lastTotal = 0
        var lastIndexed = 0
        var lastPending = 0

        while (true) {
            currentCoroutineContext().ensureActive()
            authorize()
            val batch = store.nextBatch(serverId, size)
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
            val classifications = try {
                val accumulator = TagClassificationAccumulator()
                classificationRequests(batch, outputTokens).forEachIndexed { index, request ->
                    currentCoroutineContext().ensureActive()
                    authorize()
                    val response = withTimeout(requestTimeoutMillis) {
                        val first = classificationResponse(request)
                        if (first.content.isNotBlank()) first else {
                            currentCoroutineContext().ensureActive()
                            authorize()
                            provider.complete(request).also { recovered ->
                                validateResponse(recovered)
                                if (recovered.content.isBlank()) throw EmptyClassificationResponse()
                            }
                        }
                    }
                    val part = try { RecommendationIndexResponseParser(json).parse(response.content, batch) }
                    catch (error: IllegalArgumentException) { throw InvalidClassificationResponse(error) }
                    accumulator.append(part, includeFeatures = index == 0)
                }
                accumulator.classifications()
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                if (error is CancellationException && error !is TimeoutCancellationException) throw error
                if (error is IllegalArgumentException && batch.tracks.size > 1) {
                    size = maxOf(1, batch.tracks.size / 2); continue
                }
                if (!canRetry(error)) throw error
                authorize()
                val status = store.status(serverId)
                if (status.indexedTracks > lastSaved) failures = 0
                lastSaved = status.indexedTracks
                failures++
                if (error is TimeoutCancellationException || error is EmptyClassificationResponse ||
                    (error is AiProviderException && error.kind == AiProviderFailureKind.ProviderUnavailable)) {
                    size = maxOf(1, size / 2)
                }
                val seconds = minOf(300L, 15L * (1L shl minOf(failures - 1, 5)))
                onRetry(seconds, error.message ?: "网络或模型暂时不可用")
                sleep(seconds * 1000)
                continue
            }
            currentCoroutineContext().ensureActive()
            authorize()
            store.replaceClassifications(
                serverId = serverId,
                classifications = classifications,
                classifier = "background-tags/$model",
                expectedContentHashes = batch.tracks.associate { it.globalId.serialized to RecommendationIndex.contentHash(it) },
            )

            val after = store.status(serverId)
            failures = 0
            lastSaved = after.indexedTracks
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

    private fun classificationRequests(batch: RecommendationIndexBatch, outputTokens: Int): List<AiCompletionRequest> {
        val tracks = buildJsonArray {
            batch.tracks.forEach { track ->
                add(trackEvidence(track))
            }
        }
        val userPayload = buildJsonObject {
            put("items", tracks)
        }.toString()
        return TagClassificationRequestPlan.requests(model.trim(), userPayload, provider.capabilities.maxContextTokens,
            outputTokens, reasoning)
    }

    private suspend fun classificationResponse(request: AiCompletionRequest): AiCompletionResponse {
        if (!provider.capabilities.supportsStreaming) return provider.complete(request).also(::validateResponse)
        val answer = StringBuilder()
        var termination: AiStreamTermination? = null
        provider.stream(request).collect { event ->
            when (event) {
                is AiStreamEvent.AnswerDelta -> answer.append(event.text)
                is AiStreamEvent.UnknownDelta -> Unit // Unclassified text must not turn reasoning into labels.
                is AiStreamEvent.ToolCall -> error("分类模型应返回 JSON，不能调用工具")
                is AiStreamEvent.Terminated -> { termination = event.termination; validateTermination(event.termination) }
                AiStreamEvent.Completed -> if (termination == null) termination = AiStreamTermination.chat("stop")
                else -> Unit // Reasoning and diagnostic events never become labels.
            }
        }
        val ended = termination ?: AiStreamTermination(AiStreamTerminationKind.Interrupted, "EOF")
        validateTermination(ended)
        return AiCompletionResponse(request.model, answer.toString(), termination = ended)
    }

    private fun validateResponse(response: AiCompletionResponse) {
        check(response.toolCalls.isNullOrEmpty()) { "分类模型应返回 JSON，不能调用工具" }
        validateTermination(response.termination)
    }

    private fun validateTermination(termination: AiStreamTermination) {
        check(termination.kind != AiStreamTerminationKind.Refused) { "模型拒绝了分类请求，尚未保存标签" }
        check(termination.kind != AiStreamTerminationKind.ToolCallsReady) { "分类模型应返回 JSON，不能调用工具" }
        termination.requireComplete()
    }

    private fun canRetry(error: Exception): Boolean = error is TimeoutCancellationException ||
        error is EmptyClassificationResponse || error is InvalidClassificationResponse || error is IOException ||
        (error is AiProviderException && error.retryable)

    private class EmptyClassificationResponse : IOException("模型返回了空内容，尚未保存当前批次")
    private class InvalidClassificationResponse(cause: IllegalArgumentException) : IllegalArgumentException(cause.message, cause)

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
        const val DEFAULT_BATCH_SIZE = 8
        const val MAX_BATCH_SIZE = 100
        const val CLASSIFICATION_MAX_OUTPUT_TOKENS = 8_000
        const val MAX_GENRES = 12
    }
}
