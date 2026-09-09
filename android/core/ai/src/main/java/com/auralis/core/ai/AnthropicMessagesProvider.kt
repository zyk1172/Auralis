// SPDX-License-Identifier: GPL-3.0-only
@file:Suppress("unused")

package com.auralis.core.ai

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Anthropic Messages API provider。
 *
 * Messages 与 OpenAI Chat/Responses 不能只靠替换 endpoint 复用编码：system 是顶层字段，
 * tool_use/tool_result 是 content blocks，工具 schema 使用 input_schema，鉴权使用 x-api-key。
 * 该实现保持 [AiProvider] 的中立消息/工具模型，因此 Android Assistant 可继续复用同一个
 * [AgentToolLoop]，不引入第二套 Agent 执行边界。
 */
class AnthropicMessagesProvider(
    private val configuration: AiProviderConfiguration,
    private val apiKeyProvider: suspend () -> String?,
    client: OkHttpClient? = null,
) : AiProvider {

    private val json = Json { ignoreUnknownKeys = true }
    private val okHttp = client ?: defaultClient(configuration.timeoutMillis)
    private val baseUrl = configuration.baseUrl.trim().toHttpUrl()

    override val supportsToolCalling: Boolean
        get() = configuration.supportsToolCalling

    override val capabilities: ModelCapabilities
        get() = ModelCapabilities(
            maxContextTokens = configuration.maxContextTokens,
            hasKnownContextWindow = configuration.hasKnownContextWindow,
            maxOutputTokens = configuration.maxTokens,
            supportsToolCalling = supportsToolCalling,
            supportsParallelTools = configuration.supportsParallelTools,
            supportsToolChoice = configuration.supportsToolChoice,
            supportsStrictSchema = false,
            supportsStreaming = configuration.usesStreaming,
            supportsJsonMode = false,
            supportsJsonSchema = configuration.supportsJsonSchema,
            supportsReasoningMetadata = configuration.supportsReasoningMetadata,
            supportsReasoningControl = configuration.supportsReasoningControl,
            toolMode = if (supportsToolCalling) AiProviderToolMode.AnthropicMessages else AiProviderToolMode.None,
        )

    private fun endpoint(): String {
        var component = configuration.apiPath.trim().trim('/')
        val basePath = baseUrl.encodedPath.trim('/').lowercase()
        val baseEndsInV1 = basePath == "v1" || basePath.endsWith("/v1")
        if (baseEndsInV1) {
            val lowered = component.lowercase()
            when {
                lowered == "v1" -> component = ""
                lowered.startsWith("v1/") -> component = component.substring(3)
            }
        }
        val result = if (component.isEmpty()) baseUrl.toString() else {
            baseUrl.newBuilder().addPathSegments(component).build().toString()
        }
        val url = result.toHttpUrl()
        if (url.scheme != "http" && url.scheme != "https") {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "不支持的 Anthropic 端点协议：${url.scheme}",
            )
        }
        return result
    }

    private suspend fun headers(stream: Boolean): Map<String, String> = buildMap {
        put("Content-Type", "application/json")
        if (stream) put("Accept", "text/event-stream")
        put("anthropic-version", "2023-06-01")
        apiKeyProvider()?.takeIf { it.isNotBlank() }?.let { put("x-api-key", it) }
        configuration.customHeaders.forEach { (name, value) -> put(name, value) }
    }

    internal fun requestBody(request: AiCompletionRequest, stream: Boolean): JsonObject {
        val system = request.messages
            .filter { it.role == AiMessage.Role.System }
            .map { it.content.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n\n")
        val disableTools = request.toolChoice == AiToolChoice.None
        val reasoningEnabled = request.reasoning?.enabled == true &&
            configuration.supportsReasoningControl && request.maxTokens > 1

        return buildJsonObject {
            put("model", request.model)
            put("max_tokens", request.maxTokens)
            put("messages", encodeMessages(request.messages))
            if (system.isNotEmpty()) put("system", system)
            if (!reasoningEnabled && request.temperature.isFinite()) put("temperature", request.temperature)
            if (stream) put("stream", true)

            if (reasoningEnabled) {
                val suggested = when (request.reasoning?.effort) {
                    AiReasoningEffort.Minimal, AiReasoningEffort.Low -> 1_024
                    AiReasoningEffort.Medium -> 2_048
                    AiReasoningEffort.High -> 4_096
                    null -> 2_048
                }
                putJsonObject("thinking") {
                    put("type", "enabled")
                    put("budget_tokens", suggested.coerceAtMost(request.maxTokens - 1).coerceAtLeast(1))
                }
            }

            val tools = request.tools.orEmpty()
            if (supportsToolCalling && tools.isNotEmpty() && !disableTools) {
                putJsonArray("tools") {
                    tools.forEach { tool ->
                        addJsonObject {
                            put("name", tool.name)
                            put("description", tool.description)
                            val schema = tool.parametersJson
                                ?.takeIf { it.isNotBlank() }
                                ?.let { raw -> runCatching { json.parseToJsonElement(raw) }.getOrNull() as? JsonObject }
                                ?: buildJsonObject {
                                    put("type", "object")
                                    put("properties", buildJsonObject {})
                                }
                            put("input_schema", schema)
                        }
                    }
                }
                if (configuration.supportsToolChoice) {
                    when (val choice = request.toolChoice) {
                        null -> Unit
                        AiToolChoice.Auto -> putJsonObject("tool_choice") { put("type", "auto") }
                        AiToolChoice.Required -> putJsonObject("tool_choice") { put("type", "any") }
                        is AiToolChoice.Named -> putJsonObject("tool_choice") {
                            put("type", "tool")
                            put("name", choice.name)
                        }
                        AiToolChoice.None -> Unit
                    }
                }
            }
        }
    }

    /**
     * 将中立 transcript 投影成 Anthropic content blocks。
     * 连续 tool 结果必须合并到同一个 user message，避免破坏并行工具调用与结果的关联。
     */
    internal fun encodeMessages(source: List<AiMessage>): JsonArray = buildJsonArray {
        var index = 0
        while (index < source.size) {
            val message = source[index]
            when (message.role) {
                AiMessage.Role.System -> index += 1

                AiMessage.Role.User -> {
                    addJsonObject {
                        put("role", "user")
                        putJsonArray("content") {
                            addJsonObject {
                                put("type", "text")
                                put("text", message.content)
                            }
                        }
                    }
                    index += 1
                }

                AiMessage.Role.Assistant -> {
                    addJsonObject {
                        put("role", "assistant")
                        putJsonArray("content") {
                            if (message.content.isNotEmpty()) {
                                addJsonObject {
                                    put("type", "text")
                                    put("text", message.content)
                                }
                            }
                            message.toolCalls.orEmpty().forEach { call ->
                                addJsonObject {
                                    put("type", "tool_use")
                                    put("id", call.id)
                                    put("name", call.name)
                                    put("input", call.arguments as? JsonObject ?: buildJsonObject {})
                                }
                            }
                            if (message.content.isEmpty() && message.toolCalls.isNullOrEmpty()) {
                                addJsonObject {
                                    put("type", "text")
                                    put("text", "")
                                }
                            }
                        }
                    }
                    index += 1
                }

                AiMessage.Role.Tool -> {
                    addJsonObject {
                        put("role", "user")
                        putJsonArray("content") {
                            while (index < source.size && source[index].role == AiMessage.Role.Tool) {
                                val result = source[index]
                                addJsonObject {
                                    put("type", "tool_result")
                                    put("tool_use_id", result.toolCallId.orEmpty())
                                    put("content", result.content)
                                }
                                index += 1
                            }
                        }
                    }
                }
            }
        }
    }

    private suspend fun executeJson(body: JsonObject): Pair<Int, String> = withContext(Dispatchers.IO) {
        val builder = Request.Builder()
            .url(endpoint())
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
        headers(stream = false).forEach { (name, value) -> builder.header(name, value) }
        okHttp.newCall(builder.build()).execute().use { response ->
            response.code to response.body?.string().orEmpty()
        }
    }

    private suspend fun executeStreaming(body: JsonObject): okhttp3.Response = withContext(Dispatchers.IO) {
        val builder = Request.Builder()
            .url(endpoint())
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
        headers(stream = true).forEach { (name, value) -> builder.header(name, value) }
        val response = okHttp.newCall(builder.build()).execute()
        if (!response.isSuccessful) {
            val status = response.code
            val detail = response.body?.string().orEmpty()
            response.close()
            throw classify(status, detail)
        }
        response
    }

    override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse {
        val (status, raw) = try {
            executeJson(requestBody(request, stream = false))
        } catch (e: AiProviderException) {
            throw e
        } catch (e: Exception) {
            throw classify(0, e.message ?: e.javaClass.simpleName, e)
        }
        if (status !in 200..299) throw classify(status, raw)
        return parseCompletion(raw, request.model)
    }

    private fun parseCompletion(raw: String, fallbackModel: String): AiCompletionResponse {
        val root = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrElse {
            throw AiProviderException(AiProviderFailureKind.Unknown, "Anthropic Messages 响应不是合法 JSON")
        }
        root["error"]?.jsonObject?.get("message")?.jsonPrimitive?.contentOrNull()?.let { detail ->
            throw AiProviderException(AiProviderFailureKind.Unknown, detail)
        }

        var answer = ""
        var reasoning = ""
        val calls = mutableListOf<AiToolCall>()
        root["content"]?.jsonArray.orEmpty().forEach { blockElement ->
            val block = blockElement.jsonObject
            when (block["type"]?.jsonPrimitive?.contentOrNull()) {
                "text" -> answer += block["text"]?.jsonPrimitive?.contentOrNull().orEmpty()
                "thinking" -> reasoning += block["thinking"]?.jsonPrimitive?.contentOrNull().orEmpty()
                "tool_use" -> {
                    val id = block["id"]?.jsonPrimitive?.contentOrNull() ?: return@forEach
                    val name = block["name"]?.jsonPrimitive?.contentOrNull() ?: return@forEach
                    val input = block["input"] ?: buildJsonObject {}
                    calls += AiToolCall(id, name, input)
                }
            }
        }
        val usage = root["usage"]?.jsonObject
        return AiCompletionResponse(
            model = root["model"]?.jsonPrimitive?.contentOrNull() ?: fallbackModel,
            content = answer,
            reasoning = reasoning.takeIf { it.isNotEmpty() },
            inputTokens = usage?.get("input_tokens")?.jsonPrimitive?.contentOrNull()?.toIntOrNull(),
            outputTokens = usage?.get("output_tokens")?.jsonPrimitive?.contentOrNull()?.toIntOrNull(),
            finishReason = root["stop_reason"]?.let { if (it is JsonNull) null else it.jsonPrimitive.contentOrNull() },
            toolCalls = calls.takeIf { it.isNotEmpty() },
        )
    }

    private data class ToolFragment(
        val index: Int,
        var id: String? = null,
        var name: String? = null,
        var initialInput: JsonElement = buildJsonObject {},
        var arguments: String = "",
    )

    override fun stream(request: AiCompletionRequest): Flow<AiStreamEvent> {
        if (!configuration.usesStreaming) return nonStreamingProjection(request)
        return anthropicStream(request)
    }

    private fun nonStreamingProjection(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        val response = complete(request)
        emit(AiStreamEvent.Started(response.model))
        response.reasoning?.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
        response.content.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.AnswerDelta(it)) }
        response.toolCalls.orEmpty().forEach { emit(AiStreamEvent.ToolCall(it)) }
        if (response.inputTokens != null || response.outputTokens != null) {
            emit(AiStreamEvent.Usage(response.inputTokens ?: 0, response.outputTokens ?: 0))
        }
        emit(AiStreamEvent.Completed)
    }

    private fun anthropicStream(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        val body = requestBody(request, stream = true)
        val fragments = linkedMapOf<Int, ToolFragment>()
        var inputTokens = 0
        var outputTokens = 0
        var completed = false
        try {
            val response = executeStreaming(body)
            response.use { resp ->
                val reader = resp.body?.charStream()?.buffered()
                    ?: throw AiProviderException(AiProviderFailureKind.ProviderUnavailable, "Anthropic 流式响应体为空")
                emit(AiStreamEvent.Started(request.model))
                var dataLine = StringBuilder()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) {
                        if (dataLine.isNotEmpty()) {
                            val payload = dataLine.toString()
                            dataLine = StringBuilder()
                            val result = handleSsePayload(payload, fragments) { event -> emit(event) }
                            inputTokens = result.inputTokens ?: inputTokens
                            outputTokens = result.outputTokens ?: outputTokens
                            if (result.completed) {
                                completed = true
                                break
                            }
                        }
                        continue
                    }
                    if (line.startsWith("data:")) {
                        if (dataLine.isNotEmpty()) dataLine.append('\n')
                        dataLine.append(line.removePrefix("data:").trimStart(' '))
                    }
                }
                if (!completed && dataLine.isNotEmpty()) {
                    val result = handleSsePayload(dataLine.toString(), fragments) { emit(it) }
                    inputTokens = result.inputTokens ?: inputTokens
                    outputTokens = result.outputTokens ?: outputTokens
                    completed = result.completed
                }
            }
        } catch (e: AiProviderException) {
            throw e
        } catch (e: Exception) {
            throw classify(0, e.message ?: e.javaClass.simpleName, e)
        }

        if (!completed) {
            flushToolFragments(fragments) { emit(it) }
            if (inputTokens > 0 || outputTokens > 0) emit(AiStreamEvent.Usage(inputTokens, outputTokens))
            emit(AiStreamEvent.Completed)
        }
    }

    private data class SseResult(
        val completed: Boolean = false,
        val inputTokens: Int? = null,
        val outputTokens: Int? = null,
    )

    private suspend fun handleSsePayload(
        payload: String,
        fragments: MutableMap<Int, ToolFragment>,
        emit: suspend (AiStreamEvent) -> Unit,
    ): SseResult {
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrElse {
            if (payload.isNotBlank()) emit(AiStreamEvent.UnknownDelta(payload))
            return SseResult()
        }
        return when (root["type"]?.jsonPrimitive?.contentOrNull()) {
            "message_start" -> {
                val usage = root["message"]?.jsonObject?.get("usage")?.jsonObject
                SseResult(inputTokens = usage?.get("input_tokens")?.jsonPrimitive?.contentOrNull()?.toIntOrNull())
            }

            "content_block_start" -> {
                val index = root["index"]?.jsonPrimitive?.contentOrNull()?.toIntOrNull()
                val block = root["content_block"]?.jsonObject
                if (index != null && block != null) {
                    when (block["type"]?.jsonPrimitive?.contentOrNull()) {
                        "tool_use" -> fragments[index] = ToolFragment(
                            index = index,
                            id = block["id"]?.jsonPrimitive?.contentOrNull(),
                            name = block["name"]?.jsonPrimitive?.contentOrNull(),
                            initialInput = block["input"] ?: buildJsonObject {},
                        )
                        "text" -> block["text"]?.jsonPrimitive?.contentOrNull()?.takeIf { it.isNotEmpty() }
                            ?.let { emit(AiStreamEvent.AnswerDelta(it)) }
                        "thinking" -> block["thinking"]?.jsonPrimitive?.contentOrNull()?.takeIf { it.isNotEmpty() }
                            ?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
                    }
                }
                SseResult()
            }

            "content_block_delta" -> {
                val delta = root["delta"]?.jsonObject
                when (delta?.get("type")?.jsonPrimitive?.contentOrNull()) {
                    "text_delta" -> delta["text"]?.jsonPrimitive?.contentOrNull()?.takeIf { it.isNotEmpty() }
                        ?.let { emit(AiStreamEvent.AnswerDelta(it)) }
                    "thinking_delta" -> delta["thinking"]?.jsonPrimitive?.contentOrNull()?.takeIf { it.isNotEmpty() }
                        ?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
                    "input_json_delta" -> {
                        val index = root["index"]?.jsonPrimitive?.contentOrNull()?.toIntOrNull()
                        val partial = delta["partial_json"]?.jsonPrimitive?.contentOrNull()
                        if (index != null && partial != null) fragments[index]?.let { it.arguments += partial }
                    }
                }
                SseResult()
            }

            "message_delta" -> {
                val usage = root["usage"]?.jsonObject
                SseResult(outputTokens = usage?.get("output_tokens")?.jsonPrimitive?.contentOrNull()?.toIntOrNull())
            }

            "message_stop" -> {
                flushToolFragments(fragments, emit)
                emit(AiStreamEvent.Completed)
                SseResult(completed = true)
            }

            "error" -> {
                val detail = root["error"]?.jsonObject?.get("message")?.jsonPrimitive?.contentOrNull()
                    ?: "Anthropic 流式端点返回错误事件"
                throw AiProviderException(
                    AiProviderFailureKind.UpstreamRouting,
                    detail,
                    retryable = true,
                )
            }

            else -> SseResult()
        }
    }

    private suspend fun flushToolFragments(
        fragments: MutableMap<Int, ToolFragment>,
        emit: suspend (AiStreamEvent) -> Unit,
    ) {
        fragments.toSortedMap().values.forEach { fragment ->
            val id = fragment.id ?: return@forEach
            val name = fragment.name ?: return@forEach
            val arguments = if (fragment.arguments.isBlank()) {
                fragment.initialInput
            } else {
                runCatching { json.parseToJsonElement(fragment.arguments) }
                    .getOrElse { JsonPrimitive(fragment.arguments) }
            }
            emit(AiStreamEvent.ToolCall(AiToolCall(id, name, arguments)))
        }
        fragments.clear()
    }

    override suspend fun testConnection(): AiConnectionResult {
        val started = System.currentTimeMillis()
        val response = complete(
            AiCompletionRequest(
                model = configuration.model,
                messages = listOf(AiMessage(AiMessage.Role.User, "Reply with OK.")),
                temperature = 0.0,
                maxTokens = 8,
            ),
        )
        return AiConnectionResult(
            latencyMillis = System.currentTimeMillis() - started,
            model = response.model,
            message = "连接正常（Anthropic Messages · ${response.model}）",
            diagnostics = AiProviderDiagnostics(
                modelCatalog = AiProbeStatus.Unavailable,
                modelAvailability = AiProbeStatus.Passed,
                textCompletion = AiProbeStatus.Passed,
                details = listOf("Anthropic Messages 不提供通用 /models 目录；模型可用性已由实际请求验证。"),
            ),
        )
    }

    private fun classify(status: Int, detail: String, cause: Throwable? = null): AiProviderException {
        val readable = runCatching {
            json.parseToJsonElement(detail).jsonObject["error"]?.jsonObject?.get("message")?.jsonPrimitive?.contentOrNull()
        }.getOrNull()?.takeIf { it.isNotBlank() } ?: detail.takeIf { it.isNotBlank() } ?: "HTTP $status"
        val mentionsModel = readable.contains("model", ignoreCase = true) &&
            !readable.contains("api key", ignoreCase = true)
        var retryable = false
        val kind = when {
            status == 401 -> if (mentionsModel) AiProviderFailureKind.ModelRouting else AiProviderFailureKind.Authentication
            status == 403 -> AiProviderFailureKind.Authentication
            status == 404 -> AiProviderFailureKind.ModelRouting
            status == 429 -> {
                retryable = true
                AiProviderFailureKind.RateLimited
            }
            status == 400 || status == 422 -> AiProviderFailureKind.IncompatibleRequest
            status == 408 || status in 500..599 -> {
                retryable = true
                AiProviderFailureKind.UpstreamRouting
            }
            status == 0 && cause != null -> AiProviderFailureKind.ProviderUnavailable
            else -> AiProviderFailureKind.Unknown
        }
        return AiProviderException(
            kind = kind,
            message = readable,
            httpStatus = status.takeIf { it != 0 },
            retryable = retryable,
            cause = cause,
        )
    }

    companion object {
        private fun defaultClient(timeoutMillis: Long): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .writeTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .build()
    }
}
