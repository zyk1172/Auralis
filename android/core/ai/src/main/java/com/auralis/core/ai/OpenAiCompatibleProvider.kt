@file:Suppress("unused")

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
 * OpenAI 兼容实现（Chat Completions：`/v1/chat/completions`）。
 *
 * 对齐 Swift `OpenAICompatibleProvider` 的关键语义：
 * - **端点判定**：`apiPath` 指向 `/responses` 或 Anthropic `/messages` 时抛
 *   [AiProviderException]（`unsupportedEndpointProtocol`）——Android 子集只实现
 *   Chat Completions；
 * - **URL 拼接**：去重叠 `/v1` 段（baseURL 以 v1 结尾时不产生 `/v1/v1/...`）；
 * - **参数降级**：仅当 400/422 且 detail 提及 temperature/max_tokens 时做字段名适配
 *   重试一次；**绝不删除 tools/tool_choice**——网关不支持原生工具时保留原错误，
 *   让上层报告原生协议失败；
 * - **SSE 流式**：tool_calls 按 `index` 跨 chunk 拼接 fragments，到流结束
 *   （`[DONE]` / `finish_reason` / 自然结束）才统一产出完整 [AiStreamEvent.ToolCall]；
 *   `reasoning_content` 归类 [AiStreamEvent.ReasoningDelta]（绝不持久化）；
 *   无法分类的正文归类 [AiStreamEvent.UnknownDelta]（保持可见，绝不静默丢弃）；
 * - **错误分类**：401+模型提示语 → 模型/上游路由而非「API Key 错」。
 */
class OpenAiCompatibleProvider(
    private val configuration: AiProviderConfiguration,
    /** 每次请求时读取当前 API Key；null 表示无鉴权端点。凭据本身不在此层持久化。 */
    private val apiKeyProvider: suspend () -> String?,
    client: OkHttpClient? = null,
) : AiProvider {

    private val json = Json { ignoreUnknownKeys = true }
    private val okHttp: OkHttpClient = (client ?: defaultClient(configuration.timeoutMillis))

    private val baseUrl: okhttp3.HttpUrl = configuration.baseUrl.trim().toHttpUrl()

    private val usesResponsesApi: Boolean = run {
        val p = configuration.apiPath.trim().lowercase()
        p.endsWith("/responses") || p.contains("/v1/responses")
    }
    private val usesAnthropicApi: Boolean = run {
        val p = configuration.apiPath.trim().lowercase()
        p.endsWith("/messages") || p.contains("/v1/messages")
    }

    override val supportsToolCalling: Boolean
        get() = !usesAnthropicApi && configuration.supportsToolCalling

    override val capabilities: ModelCapabilities
        get() = ModelCapabilities(
            maxContextTokens = configuration.maxContextTokens,
            hasKnownContextWindow = configuration.hasKnownContextWindow,
            maxOutputTokens = configuration.maxTokens,
            supportsToolCalling = supportsToolCalling,
            supportsParallelTools = configuration.supportsParallelTools,
            supportsToolChoice = configuration.supportsToolChoice,
            supportsStrictSchema = configuration.supportsStrictSchema,
            supportsStreaming = configuration.usesStreaming,
            supportsJsonMode = configuration.supportsJsonMode,
            supportsJsonSchema = configuration.supportsJsonSchema,
            supportsReasoningMetadata = configuration.supportsReasoningMetadata,
            supportsReasoningControl = configuration.supportsReasoningControl,
            toolMode = if (supportsToolCalling) AiProviderToolMode.OpenAiChat else AiProviderToolMode.None,
        )

    // ------------------------------------------------------------------
    // 端点拼接
    // ------------------------------------------------------------------

    private fun endpoint(): String {
        if (usesAnthropicApi) {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "Android 子集仅支持 Chat Completions，不支持 Anthropic Messages API（${configuration.apiPath}）",
            )
        }
        var component = configuration.apiPath.trim().trim('/')
        // baseURL 路径以 v1 结尾（/v1、/api/v1 等）时去掉 apiPath 开头的 v1。
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
        // 校验 scheme/host（http/https、host 非空）。
        val url = result.toHttpUrl()
        val scheme = url.scheme.lowercase()
        if (scheme != "http" && scheme != "https") {
            throw AiProviderException(AiProviderFailureKind.IncompatibleRequest, "不支持的端点协议: $scheme")
        }
        return result
    }

    // ------------------------------------------------------------------
    // 请求体
    // ------------------------------------------------------------------

    private fun requestBody(request: AiCompletionRequest, stream: Boolean): JsonObject = buildJsonObject {
        put("model", request.model)
        putJsonArray("messages") {
            request.messages.forEach { msg -> add(msg.asRequestObject()) }
        }
        if (request.temperature.isFinite()) put("temperature", request.temperature)
        put("max_tokens", request.maxTokens)
        put("stream", stream)

        request.tools?.takeIf { it.isNotEmpty() && supportsToolCalling }?.let { tools ->
            putJsonArray("tools") {
                tools.forEach { tool ->
                    addJsonObject {
                        put("type", "function")
                        putJsonObject("function") {
                            put("name", tool.name)
                            put("description", tool.description)
                            val schema = tool.parametersJson?.takeIf { it.isNotBlank() }
                            if (schema != null) {
                                put("parameters", runCatching { json.parseToJsonElement(schema) }
                                    .getOrElse { JsonPrimitive(schema) })
                                if (tool.strict) put("strict", true)
                            }
                        }
                    }
                }
            }
            // tool_choice：仅在端点声明支持时携带（null/auto 省略，兼容更老网关）。
            if (configuration.supportsToolChoice) {
                when (val choice = request.toolChoice) {
                    null, AiToolChoice.Auto -> Unit
                    AiToolChoice.None -> put("tool_choice", "none")
                    AiToolChoice.Required -> put("tool_choice", "required")
                    is AiToolChoice.Named -> putJsonObject("tool_choice") {
                        put("type", "function")
                        putJsonObject("function") { put("name", choice.name) }
                    }
                }
            }
        }
        // 推理控制（仅对声明支持 request-side reasoning 的端点发送）。
        val reasoning = request.reasoning
        if (reasoning != null && reasoning.enabled && configuration.supportsReasoningControl) {
            put("reasoning_effort", reasoning.effort.name.lowercase())
        }
    }

    /** 400/422 参数降级：只做 temperature / max_tokens 字段名适配；绝不删除 tools。 */
    internal fun fallbackBody(body: JsonObject, status: Int, detail: String): JsonObject? {
        if (status != 400 && status != 422) return null
        val d = detail.lowercase()
        val mentionsToolChoice = d.contains("tool_choice") || d.contains("tool choice")
        val mentionsTools = d.contains("tools") || d.contains("function calling") || d.contains("function_call")
        val mentionsTemperature = d.contains("temperature") || d.contains("sampling")
        val mentionsMaxTokens = d.contains("max_tokens") || d.contains("max_output_tokens")
        if (mentionsToolChoice || mentionsTools) return null
        if (!mentionsTemperature && !mentionsMaxTokens) return null

        val mutable = body.toMutableMap()
        var changed = false
        if (mentionsTemperature) {
            if (mutable.remove("temperature") != null) changed = true
        }
        if (mentionsMaxTokens) {
            val old = mutable.remove("max_tokens")
            if (old != null) {
                mutable["max_completion_tokens"] = old
                changed = true
            }
        }
        return if (changed) JsonObject(mutable) else null
    }

    // ------------------------------------------------------------------
    // 鉴权与执行
    // ------------------------------------------------------------------

    private suspend fun authHeaders(): Map<String, String> {
        val key = apiKeyProvider()
        return buildMap {
            if (!key.isNullOrBlank()) put("Authorization", "Bearer $key")
            configuration.organization?.takeIf { it.isNotBlank() }?.let { put("OpenAI-Organization", it) }
            configuration.customHeaders.forEach { (k, v) -> put(k, v) }
        }
    }

    private suspend fun executeJson(
        url: String,
        body: JsonObject,
    ): Pair<Int, String> = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url).post(
            body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()),
        )
        for ((k, v) in authHeaders()) builder.header(k, v)
        builder.build().let { okHttp.newCall(it).execute().use { resp ->
            resp.code to (resp.body?.string() ?: "")
        } }
    }

    private suspend fun executeStreaming(
        url: String,
        body: JsonObject,
        onStatus: (Int) -> Unit,
    ): okhttp3.Response = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url).post(
            body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()),
        )
        for ((k, v) in authHeaders()) builder.header(k, v)
        val resp = okHttp.newCall(builder.build()).execute()
        if (!resp.isSuccessful) {
            val code = resp.code
            val detail = resp.body?.string().orEmpty()
            resp.close()
            throw classify(code, detail)
        }
        onStatus(resp.code)
        resp
    }

    // ------------------------------------------------------------------
    // 非流式补全
    // ------------------------------------------------------------------

    override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse {
        if (usesResponsesApi) {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "Android 子集仅支持 Chat Completions（apiPath=${configuration.apiPath}）",
            )
        }
        if (usesAnthropicApi) {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "不支持 Anthropic Messages API（${configuration.apiPath}）",
            )
        }
        val url = endpoint()
        val body = requestBody(request, stream = false)
        val (status, raw) = executeJson(url, body)
        if (status != 200) {
            // 参数降级：仅字段名适配，重试一次。
            val errDetail = runCatching { json.parseToJsonElement(raw).errorDetail() }.getOrNull().orEmpty()
            val fallback = fallbackBody(body, status, errDetail)
            if (fallback != null) {
                val (status2, raw2) = executeJson(url, fallback)
                if (status2 == 200) return parseCompletion(raw2, request.model)
                throw classify(status2, raw2)
            }
            throw classify(status, raw)
        }
        return parseCompletion(raw, request.model)
    }

    private fun parseCompletion(raw: String, fallbackModel: String): AiCompletionResponse {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrElse {
            throw AiProviderException(AiProviderFailureKind.Unknown, "响应不是合法 JSON", retryable = false)
        }
        val obj = root.jsonObject
        val model = obj["model"]?.jsonPrimitive?.contentOrNull() ?: fallbackModel
        val choice = obj["choices"]?.jsonArray?.firstOrNull()?.jsonObject
        val message = choice?.get("message")?.jsonObject
        val content = message?.get("content")?.let { element ->
            if (element is JsonNull) "" else element.jsonPrimitive.contentOrNull() ?: ""
        } ?: ""
        val reasoning = message?.get("reasoning_content")?.let { element ->
            if (element is JsonNull) null else element.jsonPrimitive.contentOrNull()
        }
        val finish = choice?.get("finish_reason")?.jsonPrimitive?.contentOrNull()
        val toolCalls = message?.get("tool_calls")?.jsonArray?.mapNotNull { tc ->
            parseToolCall(tc.jsonObject)
        }?.takeIf { it.isNotEmpty() }
        val usage = obj.usageBlock()
        val response = AiCompletionResponse(
            model = model,
            content = content,
            reasoning = reasoning,
            inputTokens = usage?.first,
            outputTokens = usage?.second,
            finishReason = finish,
            toolCalls = toolCalls,
        )
        if (finish == "length" && !toolCalls.isNullOrEmpty()) {
            throw AiProviderException(
                AiProviderFailureKind.Unknown,
                "输出被截断（finish_reason=length 且存在未完成的工具调用）",
                retryable = true,
            )
        }
        return response
    }

    private fun parseToolCall(tc: JsonObject): AiToolCall? {
        val id = tc["id"]?.jsonPrimitive?.contentOrNull() ?: return null
        val fn = tc["function"]?.jsonObject ?: return null
        val name = fn["name"]?.jsonPrimitive?.contentOrNull() ?: return null
        val argsRaw = fn["arguments"]?.jsonPrimitive?.contentOrNull().orEmpty()
        // decode 边界：raw JSON → 结构化；解析失败保留原串（语义对齐 deprecated init）。
        val args: JsonElement = if (argsRaw.isBlank()) JsonNull else {
            runCatching { json.parseToJsonElement(argsRaw) }.getOrElse { JsonPrimitive(argsRaw) }
        }
        return AiToolCall(id = id, name = name, arguments = args)
    }

    // ------------------------------------------------------------------
    // 流式补全（SSE）
    // ------------------------------------------------------------------

    override fun stream(request: AiCompletionRequest): Flow<AiStreamEvent> {
        if (!configuration.usesStreaming) {
            return nonStreamingProjection(request)
        }
        if (usesResponsesApi) {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "Android 子集仅支持 Chat Completions 流式（apiPath=${configuration.apiPath}）",
            )
        }
        if (usesAnthropicApi) {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "不支持 Anthropic Messages API（${configuration.apiPath}）",
            )
        }
        return chatStream(request)
    }

    /** 端点禁用 SSE 时以非流式补全投影为事件流——普通聊天不因 SSE 失败而禁用。 */
    private fun nonStreamingProjection(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        val response = complete(request)
        emit(AiStreamEvent.Started(response.model))
        response.reasoning?.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
        if (response.content.isNotEmpty()) emit(AiStreamEvent.AnswerDelta(response.content))
        response.toolCalls?.forEach { emit(AiStreamEvent.ToolCall(it)) }
        emit(AiStreamEvent.Completed)
    }

    private data class ChatToolFragment(
        val index: Int,
        var id: String? = null,
        var name: String? = null,
        var arguments: String = "",
    )

    private fun chatStream(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        val url = endpoint()
        val body = requestBody(request, stream = true)
        val fragments = LinkedHashMap<Int, ChatToolFragment>()
        var sawFinishReason = false

        try {
            val resp = executeStreaming(url, body) { }
            resp.use { response ->
                val reader = response.body?.charStream()?.buffered()
                    ?: throw AiProviderException(AiProviderFailureKind.ProviderUnavailable, "响应体为空")
                emit(AiStreamEvent.Started(request.model))

                var dataLine = StringBuilder()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) {
                        // SSE 事件边界：flush 累计 data 行。
                        if (dataLine.isNotEmpty()) {
                            val payload = dataLine.toString()
                            dataLine = StringBuilder()
                            if (handleSsePayload(payload, request.model, fragments) { event ->
                                    emit(event)
                                }) { sawFinishReason = true; break }
                        }
                        continue
                    }
                    if (line.startsWith("data:")) {
                        val piece = line.removePrefix("data:").trimStart(' ')
                        if (dataLine.isNotEmpty()) dataLine.append('\n')
                        dataLine.append(piece)
                    }
                    // event:/id:/retry: 行不影响 Chat Completions 语义，忽略。
                }
            }
        } catch (e: AiProviderException) {
            // 参数降级重试（仅字段名适配）。
            val fallback = fallbackBody(body, e.httpStatus ?: 0, e.message ?: "")
            if (fallback != null) {
                val stream2 = chatStreamRawOnce(request, fallback)
                stream2.collect { emit(it) }
                return@flow
            }
            throw e
        } catch (e: Exception) {
            throw classify(0, e.message ?: e.javaClass.simpleName, cause = e)
        }

        // 自然结束（无 [DONE]）：flush 已拼接的 tool call，再补 completed。
        if (!sawFinishReason) {
            flushToolFragments(fragments) { emit(it) }
            emit(AiStreamEvent.Completed)
        }
    }

    /** 单次 SSE 执行（不含 fallback 逻辑），供降级重试复用。 */
    private suspend fun chatStreamRawOnce(
        request: AiCompletionRequest,
        body: JsonObject,
    ): Flow<AiStreamEvent> = flow {
        val resp = executeStreaming(endpoint(), body) { }
        resp.use { response ->
            val reader = response.body?.charStream()?.buffered()
                ?: throw AiProviderException(AiProviderFailureKind.ProviderUnavailable, "响应体为空")
            emit(AiStreamEvent.Started(request.model))
            val fragments = LinkedHashMap<Int, ChatToolFragment>()
            var dataLine = StringBuilder()
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) {
                    if (dataLine.isNotEmpty()) {
                        val payload = dataLine.toString()
                        dataLine = StringBuilder()
                        val done = handleSsePayload(payload, request.model, fragments) { emit(it) }
                        if (done) break
                    }
                    continue
                }
                if (line.startsWith("data:")) {
                    val piece = line.removePrefix("data:").trimStart(' ')
                    if (dataLine.isNotEmpty()) dataLine.append('\n')
                    dataLine.append(piece)
                }
            }
            flushToolFragments(fragments) { emit(it) }
            emit(AiStreamEvent.Completed)
        }
    }

    /**
     * 处理一条 SSE data 载荷。返回 true 表示流已结束（[DONE] 或 finish_reason）。
     */
    private suspend fun handleSsePayload(
        payload: String,
        fallbackModel: String,
        fragments: MutableMap<Int, ChatToolFragment>,
        emit: suspend (AiStreamEvent) -> Unit,
    ): Boolean {
        if (payload == "[DONE]") {
            flushToolFragments(fragments, emit)
            emit(AiStreamEvent.Completed)
            return true
        }
        val root = runCatching { json.parseToJsonElement(payload) }.getOrElse {
            // 非 JSON 的未知负载绝不静默丢弃：保持可见。
            if (payload.isNotBlank()) emit(AiStreamEvent.UnknownDelta(payload))
            return false
        }
        if (root !is JsonObject) {
            // 合法 JSON 但非对象（裸字符串/数字等网关怪负载）：不静默丢弃。
            if (payload.isNotBlank()) emit(AiStreamEvent.UnknownDelta(payload))
            return false
        }
        val choice = root["choices"]?.jsonArray?.firstOrNull()?.jsonObject
        if (choice != null) {
            val delta = choice["delta"]?.jsonObject
            // 推理 token：仅展示，绝不持久化。
            delta?.get("reasoning_content")?.let { rc ->
                if (rc !is JsonNull) {
                    rc.jsonPrimitive.contentOrNull()?.takeIf { it.isNotEmpty() }
                        ?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
                }
            }
            // tool_calls 分片：按 index 累积。
            delta?.get("tool_calls")?.jsonArray?.forEach { tcElement ->
                val tc = tcElement.jsonObject
                val index = tc["index"]?.jsonPrimitive?.contentOrNull()?.toIntOrNull() ?: return@forEach
                val frag = fragments.getOrPut(index) { ChatToolFragment(index) }
                tc["id"]?.jsonPrimitive?.contentOrNull()?.let { frag.id = it }
                tc["type"]?.jsonPrimitive?.contentOrNull() // type 恒为 function，忽略
                tc["function"]?.jsonObject?.let { fn ->
                    fn["name"]?.jsonPrimitive?.contentOrNull()?.let { frag.name = it }
                    fn["arguments"]?.jsonPrimitive?.contentOrNull()?.let { frag.arguments += it }
                }
            }
            // 正文 delta：in-flight tool call 期间的不明文本归类 Unknown（保留可见）。
            val content = delta?.get("content")?.let {
                if (it is JsonNull) null else it.jsonPrimitive.contentOrNull()
            }
            if (!content.isNullOrEmpty()) {
                if (fragments.isEmpty()) emit(AiStreamEvent.AnswerDelta(content)) else emit(AiStreamEvent.UnknownDelta(content))
            }
            val finish = choice["finish_reason"]?.jsonPrimitive?.contentOrNull()
            if (finish != null) {
                flushToolFragments(fragments, emit)
                emit(AiStreamEvent.Completed)
                return true
            }
        }
        // 非流式 usage（stream_options.include_usage 的最后一个 chunk）。
        root.jsonObject.usageBlock()?.let { (input, output) ->
            if (input != null || output != null) {
                emit(AiStreamEvent.Usage(input ?: 0, output ?: 0))
            }
        }
        return false
    }

    private suspend fun flushToolFragments(
        fragments: MutableMap<Int, ChatToolFragment>,
        emit: suspend (AiStreamEvent) -> Unit,
    ) {
        fragments.values.forEach { frag ->
            val id = frag.id ?: return@forEach
            val name = frag.name ?: return@forEach
            val args: JsonElement = if (frag.arguments.isBlank()) JsonNull else {
                runCatching { json.parseToJsonElement(frag.arguments) }
                    .getOrElse { JsonPrimitive(frag.arguments) }
            }
            emit(AiStreamEvent.ToolCall(AiToolCall(id = id, name = name, arguments = args)))
        }
        fragments.clear()
    }

    // ------------------------------------------------------------------
    // 连接测试与诊断
    // ------------------------------------------------------------------

    override suspend fun testConnection(): AiConnectionResult {
        if (usesAnthropicApi) {
            throw AiProviderException(
                AiProviderFailureKind.IncompatibleRequest,
                "不支持 Anthropic Messages API（${configuration.apiPath}）",
            )
        }
        val started = System.currentTimeMillis()
        val details = mutableListOf<String>()
        // 1) 模型目录探测（失败不致命）。
        var catalogStatus = AiProbeStatus.NotTested
        var modelAvailable = true
        try {
            val catalog = probeModelCatalog()
            details += catalog.second
            catalogStatus = catalog.first
            modelAvailable = catalogStatus != AiProbeStatus.Failed
        } catch (_: Exception) {
            catalogStatus = AiProbeStatus.Unavailable
        }
        if (!modelAvailable) {
            return AiConnectionResult(
                latencyMillis = System.currentTimeMillis() - started,
                model = configuration.model,
                message = "当前模型未在该端点的模型目录中出现。",
                diagnostics = AiProviderDiagnostics(
                    modelCatalog = catalogStatus,
                    modelAvailability = AiProbeStatus.Failed,
                    details = details,
                ),
            )
        }
        // 2) 文本补全探测。
        val response = try {
            complete(
                AiCompletionRequest(
                    model = configuration.model,
                    messages = listOf(
                        AiMessage(AiMessage.Role.System, "You are a connectivity probe. Reply with the single word: ok."),
                        AiMessage(AiMessage.Role.User, "ping"),
                    ),
                    maxTokens = 8,
                    temperature = 0.0,
                ),
            )
        } catch (e: AiProviderException) {
            return AiConnectionResult(
                latencyMillis = System.currentTimeMillis() - started,
                model = configuration.model,
                message = "文本补全探测失败：${e.message}",
                diagnostics = AiProviderDiagnostics(
                    modelCatalog = catalogStatus,
                    modelAvailability = AiProbeStatus.Passed,
                    textCompletion = AiProbeStatus.Failed,
                    details = details,
                ),
            )
        }
        return AiConnectionResult(
            latencyMillis = System.currentTimeMillis() - started,
            model = response.model,
            message = "连接正常（${configuration.model}）",
            diagnostics = AiProviderDiagnostics(
                modelCatalog = catalogStatus,
                modelAvailability = AiProbeStatus.Passed,
                textCompletion = AiProbeStatus.Passed,
                details = details,
            ),
        )
    }

    /** 探测 /models 目录；返回 (catalog 状态, details)。目录缺失视为 notTested 而非 failed。 */
    private suspend fun probeModelCatalog(): Pair<AiProbeStatus, List<String>> = withContext(Dispatchers.IO) {
        val base = baseUrl.newBuilder().addPathSegments("models").build().toString()
        val builder = Request.Builder().url(base)
        for ((k, v) in authHeaders()) builder.header(k, v)
        val detail = try {
            okHttp.newCall(builder.build()).execute().use { resp ->
                when {
                    resp.code == 200 -> {
                        val ids = runCatching {
                            json.parseToJsonElement(resp.body?.string().orEmpty()).jsonObject["data"]
                                ?.jsonArray?.mapNotNull { it.jsonObject["id"]?.jsonPrimitive?.contentOrNull() }
                                .orEmpty()
                        }.getOrDefault(emptyList())
                        if (ids.isEmpty()) {
                            AiProbeStatus.Degraded to listOf("模型目录为空")
                        } else if (configuration.model in ids) {
                            AiProbeStatus.Passed to listOf("模型目录含 ${configuration.model}")
                        } else {
                            AiProbeStatus.Failed to listOf("模型 ${configuration.model} 不在目录中（共 ${ids.size} 个模型）")
                        }
                    }
                    resp.code == 401 || resp.code == 403 -> {
                        AiProbeStatus.Failed to listOf("模型目录鉴权失败（HTTP ${resp.code}）")
                    }
                    resp.code == 404 -> AiProbeStatus.NotTested to listOf("端点无 /models 目录（HTTP 404，跳过）")
                    else -> AiProbeStatus.Degraded to listOf("模型目录 HTTP ${resp.code}")
                }
            }
        } catch (e: Exception) {
            AiProbeStatus.Degraded to listOf("模型目录不可达：${e.message}")
        }
        detail
    }

    // ------------------------------------------------------------------
    // 错误分类
    // ------------------------------------------------------------------

    internal fun classify(status: Int, detail: String, cause: Throwable? = null): AiProviderException {
        val message = if (detail.isBlank()) "HTTP $status" else detail
        // 401 + 模型提示语 → 模型/上游路由问题而非 API Key 错（对齐 Swift classifier）。
        val mentionsModel =
            detail.contains("model", ignoreCase = true) && !detail.contains("api key", ignoreCase = true)
        val kind: AiProviderFailureKind
        var retryable = false
        when {
            status == 401 -> kind = if (mentionsModel) AiProviderFailureKind.ModelRouting else AiProviderFailureKind.Authentication
            status == 403 -> kind = AiProviderFailureKind.Authentication
            status == 404 -> kind = AiProviderFailureKind.ModelRouting
            status == 429 -> { kind = AiProviderFailureKind.RateLimited; retryable = true }
            status == 400 || status == 422 -> kind = AiProviderFailureKind.IncompatibleRequest
            status == 408 || status in 500..599 -> { kind = AiProviderFailureKind.UpstreamRouting; retryable = true }
            status == 0 && cause != null -> kind = AiProviderFailureKind.ProviderUnavailable
            else -> kind = AiProviderFailureKind.Unknown
        }
        return AiProviderException(kind, message, httpStatus = status.takeIf { it != 0 }, retryable = retryable, cause = cause)
    }

    companion object {
        private fun defaultClient(timeoutMillis: Long): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .writeTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .build()
    }
}
