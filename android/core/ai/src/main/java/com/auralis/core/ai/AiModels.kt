@file:Suppress("unused")

package com.auralis.core.ai

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.addJsonObject

/**
 * Auralis AI 层的核心模型 —— Swift `AIProvider.swift` 的语义对齐子集。
 *
 * 对齐原则：
 * - Provider 解码边界之外一律使用结构化 [JsonElement]（对应 Swift `AIJSONValue`），
 *   工具参数绝不以 raw JSON 字符串继续向后传递；
 * - 流式事件 [AiStreamEvent] 区分 reasoning/answer/unknown，reasoning 只做瞬态展示，
 *   绝不写入聊天记录；
 * - [AIToolCall] 的 `id` 即 OpenAI tool_call_id，`.tool` 角色消息必须携带同一 id 回灌。
 */

/** 默认上下文窗口与输出上限（与 Swift 常量一致）。 */
const val AURALIS_DEFAULT_MAX_OUTPUT_TOKENS = 16_000
const val AURALIS_DEFAULT_REQUEST_TIMEOUT_MS = 180_000L
const val AURALIS_DEFAULT_MAX_CONTEXT_TOKENS = 256_000

// ---------------------------------------------------------------------------
// JSON 值别名：直接使用 kotlinx.serialization 的 JsonElement，语义对应 AIJSONValue。
// ---------------------------------------------------------------------------

/** canonical JSON 值；对应 Swift `AIJSONValue`。 */
typealias AiJsonValue = JsonElement

/** JsonElement 的规范文本（kotlinx `toString()` 即紧凑 JSON）。 */
fun AiJsonValue.canonicalString(): String = toString()

/** 若为 JSON object 则返回其字段表。 */
fun AiJsonValue.asObject(): Map<String, JsonElement>? = (this as? JsonObject)?.let { it }

// ---------------------------------------------------------------------------
// 推理配置
// ---------------------------------------------------------------------------

enum class AiReasoningEffort { Minimal, Low, Medium, High }

enum class AiReasoningMode { Disabled, Enabled }

data class AiReasoningConfiguration(
    val mode: AiReasoningMode = AiReasoningMode.Enabled,
    val effort: AiReasoningEffort = AiReasoningEffort.Medium,
) {
    val enabled: Boolean get() = mode == AiReasoningMode.Enabled
}

// ---------------------------------------------------------------------------
// 工具调用策略
// ---------------------------------------------------------------------------

/** OpenAI `tool_choice`。为空时不携带该字段，兼容更老的网关。 */
sealed interface AiToolChoice {
    data object Auto : AiToolChoice
    data object None : AiToolChoice
    data object Required : AiToolChoice
    data class Named(val name: String) : AiToolChoice
}

// ---------------------------------------------------------------------------
// 能力与工具模式
// ---------------------------------------------------------------------------

enum class AiProviderToolMode { None, OpenAiChat }

/** 当前端点可确认的能力；未知时使用保守默认值（见 [ModelCapabilities.conservative]）。 */
data class ModelCapabilities(
    val maxContextTokens: Int = AURALIS_DEFAULT_MAX_CONTEXT_TOKENS,
    val hasKnownContextWindow: Boolean = false,
    val maxOutputTokens: Int = AURALIS_DEFAULT_MAX_OUTPUT_TOKENS,
    val supportsToolCalling: Boolean = false,
    val supportsParallelTools: Boolean = false,
    val supportsToolChoice: Boolean = false,
    val supportsStrictSchema: Boolean = false,
    val supportsStreaming: Boolean = true,
    val supportsJsonMode: Boolean = false,
    val supportsJsonSchema: Boolean = false,
    val supportsReasoningMetadata: Boolean = false,
    val supportsReasoningControl: Boolean = false,
    val toolMode: AiProviderToolMode = AiProviderToolMode.None,
) {
    companion object {
        val conservative = ModelCapabilities()
    }
}

// ---------------------------------------------------------------------------
// 隐私权限（首次外发 consent 的字段来源）
// ---------------------------------------------------------------------------

enum class AiPrivacyCategory { Metadata, Lyrics, PlaybackHistory, FavoritesAndRatings, ExternalDiscovery }

/** 外发隐私权限。默认：仅元数据允许，其余关闭。 */
data class AiPrivacyPermissions(
    var allowsMetadata: Boolean = true,
    var allowsLyrics: Boolean = false,
    var allowsPlaybackHistory: Boolean = false,
    var allowsFavoritesAndRatings: Boolean = false,
    var allowsExternalDiscovery: Boolean = false,
    var allowsFilePaths: Boolean = false,
) {
    /** 重放已持久化的助手文本是否安全：仅当所有本地披露类别仍开启。 */
    val allowPersistedAssistantText: Boolean
        get() = allowsMetadata && allowsPlaybackHistory && allowsFavoritesAndRatings && allowsLyrics

    fun allows(category: AiPrivacyCategory): Boolean = when (category) {
        AiPrivacyCategory.Metadata -> allowsMetadata
        AiPrivacyCategory.Lyrics -> allowsLyrics
        AiPrivacyCategory.PlaybackHistory -> allowsPlaybackHistory
        AiPrivacyCategory.FavoritesAndRatings -> allowsFavoritesAndRatings
        AiPrivacyCategory.ExternalDiscovery -> allowsExternalDiscovery
    }
}

// ---------------------------------------------------------------------------
// 消息与工具调用
// ---------------------------------------------------------------------------

/** 发送给模型的原生工具定义（OpenAI `tools` 数组中的 function 条目）。 */
data class AiToolDefinition(
    val name: String,
    val description: String,
    /** JSON Schema 文本；为空则不携带 parameters 字段。 */
    val parametersJson: String? = null,
    val strict: Boolean = false,
)

/** 一次原生 function calling 调用。`id` 即 OpenAI 的 tool_call_id。 */
data class AiToolCall(
    val id: String,
    val name: String,
    /** Provider decode 边界之后的 canonical 结构化参数。 */
    val arguments: AiJsonValue,
) {
    val rawArguments: String get() = arguments.canonicalString()
    val argumentObject: Map<String, JsonElement>? get() = arguments.asObject()
}

/** Provider 原生联网工具返回的中立来源信息（UI 可点击来源卡片）。 */
data class AiWebCitation(
    val title: String,
    val url: String,
    val snippet: String? = null,
    val publishedAt: String? = null,
    val backend: String? = null,
    val sourceType: String? = null,
)

/** Provider-neutral 聊天消息。 */
data class AiMessage(
    val role: Role,
    val content: String,
    val toolCallId: String? = null,
    val toolCalls: List<AiToolCall>? = null,
    val name: String? = null,
) {
    enum class Role { System, User, Assistant, Tool }
}

// ---------------------------------------------------------------------------
// 请求 / 响应
// ---------------------------------------------------------------------------

data class AiCompletionRequest(
    val model: String,
    val messages: List<AiMessage>,
    val temperature: Double = 0.4,
    val maxTokens: Int = AURALIS_DEFAULT_MAX_OUTPUT_TOKENS,
    /** 原生 function calling 的工具定义；为空则请求体不携带 `tools` 字段。 */
    val tools: List<AiToolDefinition>? = null,
    /** 原生工具调用策略；为空则不携带 `tool_choice`。 */
    val toolChoice: AiToolChoice? = null,
    val reasoning: AiReasoningConfiguration? = null,
)

data class AiCompletionResponse(
    val model: String,
    /** 用户可见的最终回答（绝不混入思考链）。 */
    val content: String,
    /** 模型思考文本，绝不写入聊天记录。 */
    val reasoning: String? = null,
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
    /** `choices[0].finish_reason`（如 "stop" / "tool_calls"）。 */
    val finishReason: String? = null,
    /** 模型要求的原生工具调用；非空表示需要执行工具并回灌结果。 */
    val toolCalls: List<AiToolCall>? = null,
    val webCitations: List<AiWebCitation>? = null,
)

// ---------------------------------------------------------------------------
// 诊断与连接结果
// ---------------------------------------------------------------------------

enum class AiProbeStatus { Passed, Degraded, Failed, Unavailable, NotTested }

data class AiProviderDiagnostics(
    val modelCatalog: AiProbeStatus = AiProbeStatus.NotTested,
    val modelAvailability: AiProbeStatus = AiProbeStatus.NotTested,
    val textCompletion: AiProbeStatus = AiProbeStatus.NotTested,
    val streaming: AiProbeStatus = AiProbeStatus.NotTested,
    val nativeTools: AiProbeStatus = AiProbeStatus.NotTested,
    val toolChoice: AiProbeStatus = AiProbeStatus.NotTested,
    val jsonMode: AiProbeStatus = AiProbeStatus.NotTested,
    val jsonSchema: AiProbeStatus = AiProbeStatus.NotTested,
    val reasoning: AiProbeStatus = AiProbeStatus.NotTested,
    val details: List<String> = emptyList(),
) {
    /** 流式探测失败时 Provider 会以同一协议的非流式补全投影为事件流；普通聊天只依赖文本补全。 */
    val supportsOrdinaryChat: Boolean get() = textCompletion == AiProbeStatus.Passed

    /** 仅显式服务端拒绝会改变有效配置；EOF/超时/5xx 只是观测失败。 */
    val streamingExplicitlyRejected: Boolean get() = streaming == AiProbeStatus.Failed
    val nativeToolsExplicitlyRejected: Boolean get() = nativeTools == AiProbeStatus.Failed
}

data class AiConnectionResult(
    val latencyMillis: Long,
    val model: String,
    val message: String,
    val diagnostics: AiProviderDiagnostics? = null,
)

// ---------------------------------------------------------------------------
// 流式事件
// ---------------------------------------------------------------------------

sealed interface AiStreamEvent {
    data class Started(val model: String) : AiStreamEvent

    /** 已明确分类为 reasoning/thinking 的 token：仅展示，绝不持久化为对话。 */
    data class ReasoningDelta(val text: String) : AiStreamEvent

    /** 已明确分类为最终用户可见文本的 token。 */
    data class AnswerDelta(val text: String) : AiStreamEvent

    /** 网关发出的无法自信分类的文本：保持可见，绝不静默丢弃。 */
    data class UnknownDelta(val text: String) : AiStreamEvent

    /** 流式过程中完成的原生工具调用（按 index 拼接碎片后统一产出）。 */
    data class ToolCall(val call: AiToolCall) : AiStreamEvent

    data class WebCitations(val citations: List<AiWebCitation>) : AiStreamEvent

    data class Usage(val input: Int, val output: Int) : AiStreamEvent

    data object Completed : AiStreamEvent
}

// ---------------------------------------------------------------------------
// 错误模型（对齐 Swift `AIProviderError` / `AIProviderFailureKind` 的语义）
// ---------------------------------------------------------------------------

enum class AiProviderFailureKind {
    Authentication, ModelRouting, UpstreamRouting, RateLimited,
    IncompatibleRequest, ProviderUnavailable, Unknown,
}

/**
 * AI 请求失败。`kind` 供 UI 区分「模型 ID 问题」与「鉴权问题」：
 * 401 + ModelRouting/Unknown → 报「模型/上游路由问题」而非「API Key 错」。
 */
class AiProviderException(
    val kind: AiProviderFailureKind,
    message: String,
    val httpStatus: Int? = null,
    val retryable: Boolean = false,
    cause: Throwable? = null,
) : Exception(message, cause)

// ---------------------------------------------------------------------------
// JSON 辅助：请求体字段与响应提取的零散扩展
// ---------------------------------------------------------------------------

/** 从响应 JSON 提取 `error.message` 作为可读 detail。 */
internal fun JsonElement.errorDetail(): String? =
    runCatching { jsonObject["error"]?.jsonObject?.get("message")?.jsonPrimitive?.content }.getOrNull()

/** 从响应 JSON 提取 usage（非流式）。 */
internal fun JsonElement.usageBlock(): Pair<Int?, Int?>? {
    val usage = jsonObject["usage"]?.jsonObject ?: return null
    val input = usage["prompt_tokens"]?.jsonPrimitive?.contentOrNull()?.toIntOrNull()
    val output = usage["completion_tokens"]?.jsonPrimitive?.contentOrNull()?.toIntOrNull()
    return input to output
}

internal fun kotlinx.serialization.json.JsonPrimitive.contentOrNull(): String? =
    runCatching { content }.getOrNull()

/** 便捷构造：把 AiMessage 列表折叠为可序列化结构供 provider 手工编码。 */
internal fun AiMessage.asRequestObject(): JsonObject = buildJsonObject {
    put("role", when (role) {
        AiMessage.Role.System -> "system"
        AiMessage.Role.User -> "user"
        AiMessage.Role.Assistant -> "assistant"
        AiMessage.Role.Tool -> "tool"
    })
    when (role) {
        AiMessage.Role.Tool -> {
            toolCallId?.let { put("tool_call_id", it) }
            put("content", content)
            name?.let { put("name", it) }
        }

        AiMessage.Role.Assistant -> {
            toolCalls?.let { calls ->
                if (calls.isNotEmpty()) {
                    putJsonArray("tool_calls") {
                        calls.forEach { call ->
                            addJsonObject {
                                put("id", call.id)
                                put("type", "function")
                                putJsonObject("function") {
                                    put("name", call.name)
                                    put("arguments", call.rawArguments)
                                }
                            }
                        }
                    }
                }
            }
            if (content.isNotEmpty()) put("content", content)
        }

        else -> put("content", content)
    }
}
