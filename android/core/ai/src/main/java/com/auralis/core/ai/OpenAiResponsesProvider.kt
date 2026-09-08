// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
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
 * OpenAI Responses API (`/v1/responses`) 实现。
 *
 * 与 Apple `OpenAICompatibleProvider` 的 Responses 路径保持相同的 transcript 语义：
 * - user/system → message + input_text；assistant 正文 → message + output_text；
 * - assistant 原生工具调用 → 顶层 function_call；tool 回灌 → function_call_output；
 * - function 工具定义在 Responses 中是**顶层平铺**结构，不复用 Chat 的 function 嵌套；
 * - 流式支持 output_text / reasoning / function_call arguments / usage；
 * - reasoning 仅通过瞬态事件暴露，不进入最终回答正文。
 */
class OpenAiResponsesProvider(
    private val configuration: AiProviderConfiguration,
    private val apiKeyProvider: suspend () -> String?,
    client: OkHttpClient? = null,
) : AiProvider {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val okHttp = client ?: OkHttpClient.Builder()
        .connectTimeout(configuration.timeoutMillis, TimeUnit.MILLISECONDS)
        .readTimeout(configuration.timeoutMillis, TimeUnit.MILLISECONDS)
        .writeTimeout(configuration.timeoutMillis, TimeUnit.MILLISECONDS)
        .build()
    private val baseUrl = configuration.baseUrl.trim().toHttpUrl()

    override val supportsToolCalling: Boolean get() = configuration.supportsToolCalling

    override val capabilities: ModelCapabilities
        get() = ModelCapabilities(
            maxContextTokens = configuration.maxContextTokens,
            hasKnownContextWindow = configuration.hasKnownContextWindow,
            maxOutputTokens = configuration.maxTokens,
            supportsToolCalling = configuration.supportsToolCalling,
            supportsParallelTools = configuration.supportsParallelTools,
            supportsToolChoice = configuration.supportsToolChoice,
            supportsStrictSchema = configuration.supportsStrictSchema,
            supportsStreaming = configuration.usesStreaming,
            supportsJsonMode = configuration.supportsJsonMode,
            supportsJsonSchema = configuration.supportsJsonSchema,
            supportsReasoningMetadata = configuration.supportsReasoningMetadata,
            supportsReasoningControl = configuration.supportsReasoningControl,
            toolMode = if (configuration.supportsToolCalling) AiProviderToolMode.OpenAiResponses else AiProviderToolMode.None,
        )

    private fun endpoint(): String {
        var component = configuration.apiPath.trim().trim('/')
        val basePath = baseUrl.encodedPath.trim('/').lowercase()
        if (basePath == "v1" || basePath.endsWith("/v1")) {
            val lower = component.lowercase()
            if (lower == "v1") component = ""
            else if (lower.startsWith("v1/")) component = component.substring(3)
        }
        return if (component.isEmpty()) baseUrl.toString()
        else baseUrl.newBuilder().addPathSegments(component).build().toString()
    }

    private suspend fun headers(): Map<String, String> {
        val key = apiKeyProvider()
        return buildMap {
            if (!key.isNullOrBlank()) put("Authorization", "Bearer $key")
            configuration.organization?.takeIf { it.isNotBlank() }?.let { put("OpenAI-Organization", it) }
            configuration.customHeaders.forEach { (k, v) -> put(k, v) }
        }
    }

    internal fun requestBody(request: AiCompletionRequest, stream: Boolean): JsonObject = buildJsonObject {
        put("model", request.model)
        putJsonArray("input") {
            request.messages.forEach { message -> encodeInputItems(message).forEach(::add) }
        }
        if (request.temperature.isFinite()) put("temperature", request.temperature)
        put("max_output_tokens", request.maxTokens)
        if (stream) put("stream", true)

        request.tools?.takeIf { it.isNotEmpty() && configuration.supportsToolCalling }?.let { tools ->
            putJsonArray("tools") {
                tools.forEach { tool ->
                    addJsonObject {
                        put("type", "function")
                        put("name", tool.name)
                        put("description", tool.description)
                        tool.parametersJson?.takeIf { it.isNotBlank() }?.let { schema ->
                            put("parameters", runCatching { json.parseToJsonElement(schema) }
                                .getOrElse { JsonPrimitive(schema) })
                        }
                        if (tool.strict) put("strict", true)
                    }
                }
            }
            if (configuration.supportsToolChoice) {
                when (val choice = request.toolChoice) {
                    null, AiToolChoice.Auto -> Unit
                    AiToolChoice.None -> put("tool_choice", "none")
                    AiToolChoice.Required -> put("tool_choice", "required")
                    is AiToolChoice.Named -> putJsonObject("tool_choice") {
                        put("type", "function")
                        put("name", choice.name)
                    }
                }
            }
        }

        request.reasoning?.let { reasoning ->
            if (configuration.supportsReasoningControl) {
                putJsonObject("reasoning") {
                    put("effort", if (reasoning.enabled) reasoning.effort.name.lowercase() else "none")
                }
            }
        }
    }

    private fun encodeInputItems(message: AiMessage): List<JsonObject> = when (message.role) {
        AiMessage.Role.System, AiMessage.Role.User -> listOf(
            buildJsonObject {
                put("type", "message")
                put("role", if (message.role == AiMessage.Role.System) "system" else "user")
                putJsonArray("content") {
                    addJsonObject {
                        put("type", "input_text")
                        put("text", message.content)
                    }
                }
            },
        )

        AiMessage.Role.Assistant -> buildList {
            if (message.content.isNotEmpty()) {
                add(buildJsonObject {
                    put("type", "message")
                    put("role", "assistant")
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", "output_text")
                            put("text", message.content)
                        }
                    }
                })
            }
            message.toolCalls.orEmpty().forEach { call ->
                add(buildJsonObject {
                    put("type", "function_call")
                    put("call_id", call.id)
                    put("name", call.name)
                    put("arguments", call.rawArguments)
                })
            }
        }

        AiMessage.Role.Tool -> listOf(
            buildJsonObject {
                put("type", "function_call_output")
                put("call_id", message.toolCallId.orEmpty())
                put("output", message.content)
            },
        )
    }

    private suspend fun execute(body: JsonObject): Pair<Int, String> = withContext(Dispatchers.IO) {
        val builder = Request.Builder()
            .url(endpoint())
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .header("Accept", "application/json")
        headers().forEach { (k, v) -> builder.header(k, v) }
        okHttp.newCall(builder.build()).execute().use { response ->
            response.code to response.body?.string().orEmpty()
        }
    }

    override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse {
        val (status, raw) = execute(requestBody(request, stream = false))
        if (status !in 200..299) throw classify(status, raw)
        return parseCompletion(raw, request.model)
    }

    internal fun parseCompletion(raw: String, fallbackModel: String): AiCompletionResponse {
        val root = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrElse {
            throw AiProviderException(AiProviderFailureKind.Unknown, "Responses API 返回内容不是合法 JSON", retryable = true)
        }
        val status = root["status"]?.jsonPrimitive?.contentOrNull
        val incompleteReason = root["incomplete_details"]?.let { detail ->
            runCatching { detail.jsonObject["reason"]?.jsonPrimitive?.contentOrNull }.getOrNull()
        }
        if (status == "incomplete" && incompleteReason == "max_output_tokens") {
            throw AiProviderException(
                AiProviderFailureKind.Unknown,
                "Responses API 输出达到 max_output_tokens 上限",
                retryable = true,
            )
        }

        val output = root["output"]?.jsonArray.orEmpty()
        val answer = buildString {
            output.forEach { element ->
                val item = element as? JsonObject ?: return@forEach
                if (item["type"]?.jsonPrimitive?.contentOrNull != "message") return@forEach
                val content = item["content"]
                when (content) {
                    is JsonPrimitive -> append(content.contentOrNull.orEmpty())
                    else -> runCatching { content?.jsonArray }.getOrNull()?.forEach { partElement ->
                        val part = partElement as? JsonObject ?: return@forEach
                        part["text"]?.jsonPrimitive?.contentOrNull?.let(::append)
                    }
                }
            }
        }
        val reasoning = buildList {
            output.forEach { element ->
                val item = element as? JsonObject ?: return@forEach
                if (item["type"]?.jsonPrimitive?.contentOrNull != "reasoning") return@forEach
                for (key in listOf("summary", "content")) {
                    runCatching { item[key]?.jsonArray }.getOrNull()?.forEach { partElement ->
                        val text = (partElement as? JsonObject)?.get("text")?.jsonPrimitive?.contentOrNull
                        if (!text.isNullOrBlank()) add(text)
                    }
                }
            }
        }.joinToString("\n").ifBlank { null }
        val toolCalls = output.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            if (item["type"]?.jsonPrimitive?.contentOrNull != "function_call") return@mapNotNull null
            val name = item["name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            val id = item["call_id"]?.jsonPrimitive?.contentOrNull
                ?: item["id"]?.jsonPrimitive?.contentOrNull
                ?: return@mapNotNull null
            val rawArgs = item["arguments"]?.jsonPrimitive?.contentOrNull.orEmpty()
            AiToolCall(id = id, name = name, arguments = decodeArguments(rawArgs))
        }.takeIf { it.isNotEmpty() }
        val usage = root["usage"] as? JsonObject
        val inputTokens = usage?.get("input_tokens")?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val outputTokens = usage?.get("output_tokens")?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val citations = parseCitations(output)

        return AiCompletionResponse(
            model = root["model"]?.jsonPrimitive?.contentOrNull ?: fallbackModel,
            content = answer,
            reasoning = reasoning,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            finishReason = when (status) {
                "completed" -> "stop"
                "incomplete" -> "length"
                else -> status
            },
            toolCalls = toolCalls,
            webCitations = citations,
        )
    }

    private fun decodeArguments(raw: String): JsonElement =
        if (raw.isBlank()) JsonNull
        else runCatching { json.parseToJsonElement(raw) }.getOrElse { JsonPrimitive(raw) }

    private fun parseCitations(output: List<JsonElement>): List<AiWebCitation>? {
        val seen = linkedSetOf<String>()
        val result = mutableListOf<AiWebCitation>()
        output.forEach { element ->
            val item = element as? JsonObject ?: return@forEach
            if (item["type"]?.jsonPrimitive?.contentOrNull != "message") return@forEach
            runCatching { item["content"]?.jsonArray }.getOrNull()?.forEach { partElement ->
                val part = partElement as? JsonObject ?: return@forEach
                runCatching { part["annotations"]?.jsonArray }.getOrNull()?.forEach { annotationElement ->
                    val annotation = annotationElement as? JsonObject ?: return@forEach
                    if (annotation["type"]?.jsonPrimitive?.contentOrNull != "url_citation") return@forEach
                    val url = annotation["url"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                    if (!seen.add(url.substringBefore('#'))) return@forEach
                    result += AiWebCitation(
                        title = annotation["title"]?.jsonPrimitive?.contentOrNull ?: url,
                        url = url,
                        backend = "openai-responses",
                        sourceType = "hosted-web-search",
                    )
                }
            }
        }
        return result.takeIf { it.isNotEmpty() }
    }

    private data class ResponseToolFragment(
        var callId: String? = null,
        var name: String? = null,
        var arguments: String = "",
    )

    override fun stream(request: AiCompletionRequest): Flow<AiStreamEvent> {
        if (!configuration.usesStreaming) return nonStreamingProjection(request)
        return responsesStream(request)
    }

    private fun nonStreamingProjection(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        val response = complete(request)
        emit(AiStreamEvent.Started(response.model))
        response.reasoning?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
        if (response.content.isNotEmpty()) emit(AiStreamEvent.AnswerDelta(response.content))
        response.toolCalls.orEmpty().forEach { emit(AiStreamEvent.ToolCall(it)) }
        response.webCitations?.let { emit(AiStreamEvent.WebCitations(it)) }
        if (response.inputTokens != null || response.outputTokens != null) {
            emit(AiStreamEvent.Usage(response.inputTokens ?: 0, response.outputTokens ?: 0))
        }
        emit(AiStreamEvent.Completed)
    }

    private fun responsesStream(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        val body = requestBody(request, stream = true)
        val builder = Request.Builder()
            .url(endpoint())
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .header("Accept", "text/event-stream, application/json")
        headers().forEach { (k, v) -> builder.header(k, v) }

        val response = withContext(Dispatchers.IO) { okHttp.newCall(builder.build()).execute() }
        response.use { resp ->
            if (!resp.isSuccessful) throw classify(resp.code, resp.body?.string().orEmpty())
            val reader = resp.body?.charStream()?.buffered()
                ?: throw AiProviderException(AiProviderFailureKind.ProviderUnavailable, "Responses API 响应体为空")
            emit(AiStreamEvent.Started(request.model))
            val fragments = linkedMapOf<String, ResponseToolFragment>()
            val emitted = mutableSetOf<String>()
            var data = StringBuilder()
            var completed = false
            while (true) {
                val line = withContext(Dispatchers.IO) { reader.readLine() } ?: break
                if (line.isEmpty()) {
                    if (data.isNotEmpty()) {
                        val payload = data.toString()
                        data = StringBuilder()
                        if (handleStreamPayload(payload, fragments, emitted) { emit(it) }) {
                            completed = true
                            break
                        }
                    }
                    continue
                }
                if (line.startsWith("data:")) {
                    if (data.isNotEmpty()) data.append('\n')
                    data.append(line.removePrefix("data:").trimStart())
                }
            }
            if (data.isNotEmpty() && !completed) {
                completed = handleStreamPayload(data.toString(), fragments, emitted) { emit(it) }
            }
            if (!completed) {
                if (fragments.isNotEmpty()) {
                    throw AiProviderException(
                        AiProviderFailureKind.ProviderUnavailable,
                        "Responses 流在工具调用参数完成前中断",
                        retryable = true,
                    )
                }
                emit(AiStreamEvent.Completed)
            }
        }
    }

    private suspend fun handleStreamPayload(
        payload: String,
        fragments: MutableMap<String, ResponseToolFragment>,
        emitted: MutableSet<String>,
        emit: suspend (AiStreamEvent) -> Unit,
    ): Boolean {
        if (payload == "[DONE]") {
            emit(AiStreamEvent.Completed)
            return true
        }
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrElse {
            if (payload.isNotBlank()) emit(AiStreamEvent.UnknownDelta(payload))
            return false
        }
        val type = root["type"]?.jsonPrimitive?.contentOrNull
        when (type) {
            "response.output_text.delta" -> root["delta"]?.jsonPrimitive?.contentOrNull
                ?.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.AnswerDelta(it)) }

            "response.reasoning_text.delta", "response.reasoning_summary_text.delta" ->
                root["delta"]?.jsonPrimitive?.contentOrNull
                    ?.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.ReasoningDelta(it)) }

            "response.output_item.added", "response.output_item.done" -> {
                val item = root["item"] as? JsonObject
                if (item?.get("type")?.jsonPrimitive?.contentOrNull == "function_call") {
                    val key = item["id"]?.jsonPrimitive?.contentOrNull
                        ?: item["call_id"]?.jsonPrimitive?.contentOrNull
                        ?: (root["output_index"]?.jsonPrimitive?.contentOrNull ?: "0")
                    val fragment = fragments.getOrPut(key) { ResponseToolFragment() }
                    item["call_id"]?.jsonPrimitive?.contentOrNull?.let { fragment.callId = it }
                    item["name"]?.jsonPrimitive?.contentOrNull?.let { fragment.name = it }
                    if (type == "response.output_item.done") {
                        item["arguments"]?.jsonPrimitive?.contentOrNull?.let { fragment.arguments = it }
                        emitToolIfReady(key, fragment, fragments, emitted, emit)
                    }
                }
            }

            "response.function_call_arguments.delta" -> {
                val key = root["item_id"]?.jsonPrimitive?.contentOrNull
                    ?: root["call_id"]?.jsonPrimitive?.contentOrNull
                    ?: (root["output_index"]?.jsonPrimitive?.contentOrNull ?: "0")
                val fragment = fragments.getOrPut(key) { ResponseToolFragment() }
                root["call_id"]?.jsonPrimitive?.contentOrNull?.let { fragment.callId = it }
                root["name"]?.jsonPrimitive?.contentOrNull?.let { fragment.name = it }
                fragment.arguments += root["delta"]?.jsonPrimitive?.contentOrNull.orEmpty()
            }

            "response.function_call_arguments.done" -> {
                val key = root["item_id"]?.jsonPrimitive?.contentOrNull
                    ?: root["call_id"]?.jsonPrimitive?.contentOrNull
                    ?: (root["output_index"]?.jsonPrimitive?.contentOrNull ?: "0")
                val fragment = fragments.getOrPut(key) { ResponseToolFragment() }
                root["call_id"]?.jsonPrimitive?.contentOrNull?.let { fragment.callId = it }
                root["name"]?.jsonPrimitive?.contentOrNull?.let { fragment.name = it }
                root["arguments"]?.jsonPrimitive?.contentOrNull?.let { fragment.arguments = it }
                emitToolIfReady(key, fragment, fragments, emitted, emit)
            }

            "response.completed" -> {
                val responseObj = root["response"] as? JsonObject
                val usage = responseObj?.get("usage") as? JsonObject
                val input = usage?.get("input_tokens")?.jsonPrimitive?.contentOrNull?.toIntOrNull()
                val output = usage?.get("output_tokens")?.jsonPrimitive?.contentOrNull?.toIntOrNull()
                if (input != null || output != null) emit(AiStreamEvent.Usage(input ?: 0, output ?: 0))
                emit(AiStreamEvent.Completed)
                return true
            }

            "response.failed", "error" -> {
                val detail = root["response"]?.let { responseElement ->
                    runCatching { responseElement.jsonObject["error"]?.toString() }.getOrNull()
                } ?: root["error"]?.toString() ?: payload
                throw AiProviderException(AiProviderFailureKind.ProviderUnavailable, detail)
            }

            null -> root["delta"]?.jsonPrimitive?.contentOrNull
                ?.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.UnknownDelta(it)) }
        }
        return false
    }

    private suspend fun emitToolIfReady(
        key: String,
        fragment: ResponseToolFragment,
        fragments: MutableMap<String, ResponseToolFragment>,
        emitted: MutableSet<String>,
        emit: suspend (AiStreamEvent) -> Unit,
    ) {
        if (key in emitted) return
        val name = fragment.name ?: return
        val id = fragment.callId ?: key
        emitted += key
        fragments.remove(key)
        emit(AiStreamEvent.ToolCall(AiToolCall(id, name, decodeArguments(fragment.arguments))))
    }

    override suspend fun testConnection(): AiConnectionResult {
        val started = System.currentTimeMillis()
        val response = complete(
            AiCompletionRequest(
                model = configuration.model,
                messages = listOf(
                    AiMessage(AiMessage.Role.System, "You are a connectivity probe. Reply with the single word: ok."),
                    AiMessage(AiMessage.Role.User, "ping"),
                ),
                temperature = 0.0,
                maxTokens = 8,
            ),
        )
        return AiConnectionResult(
            latencyMillis = System.currentTimeMillis() - started,
            model = response.model,
            message = "Responses API 连接正常（${response.model}）",
            diagnostics = AiProviderDiagnostics(
                modelAvailability = AiProbeStatus.NotTested,
                textCompletion = AiProbeStatus.Passed,
                streaming = if (configuration.usesStreaming) AiProbeStatus.Passed else AiProbeStatus.NotTested,
                nativeTools = if (configuration.supportsToolCalling) AiProbeStatus.Passed else AiProbeStatus.NotTested,
            ),
        )
    }

    private fun classify(status: Int, detail: String): AiProviderException {
        val kind = when {
            status == 401 || status == 403 -> AiProviderFailureKind.Authentication
            status == 429 -> AiProviderFailureKind.RateLimited
            status == 400 || status == 422 -> AiProviderFailureKind.IncompatibleRequest
            status == 404 -> AiProviderFailureKind.ModelRouting
            status == 408 || status in 500..599 -> AiProviderFailureKind.UpstreamRouting
            else -> AiProviderFailureKind.Unknown
        }
        return AiProviderException(
            kind = kind,
            message = detail.ifBlank { "HTTP $status" },
            httpStatus = status,
            retryable = status == 429 || status == 408 || status in 500..599,
        )
    }
}
