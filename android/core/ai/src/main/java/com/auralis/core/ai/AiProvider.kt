// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.ai

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** AI 服务端点能力声明；未知能力走保守默认。 */
interface AiProvider {
    /** 是否支持原生 function calling（tools / tool_calls / tool 消息）。 */
    val supportsToolCalling: Boolean get() = false

    /** 当前端点可确认的能力；未知时使用保守默认值。 */
    val capabilities: ModelCapabilities
        get() = ModelCapabilities(supportsToolCalling = supportsToolCalling)

    suspend fun testConnection(): AiConnectionResult

    suspend fun complete(request: AiCompletionRequest): AiCompletionResponse

    /** 流式补全。实现方在端点不支持 SSE 时以非流式补全投影为事件流（普通聊天不因 SSE 失败而禁用）。 */
    fun stream(request: AiCompletionRequest): Flow<AiStreamEvent>
}

/** 一个 OpenAI 兼容端点的完整配置（用户可编辑、可持久化）。 */
data class AiProviderConfiguration(
    val id: String,
    val name: String,
    val baseUrl: String,
    /** 相对 baseUrl 的接口路径，如 `/v1/chat/completions` 或 `chat/completions`。 */
    val apiPath: String,
    /** 凭据引用（安全存储中的条目 id）；为 null 表示无鉴权端点（如本地 Ollama）。 */
    val credentialId: String? = null,
    val model: String,
    val customHeaders: Map<String, String> = emptyMap(),
    val organization: String? = null,
    val temperature: Double = 0.4,
    val maxTokens: Int = AURALIS_DEFAULT_MAX_OUTPUT_TOKENS,
    val maxContextTokens: Int = AURALIS_DEFAULT_MAX_CONTEXT_TOKENS,
    val hasKnownContextWindow: Boolean = false,
    val timeoutMillis: Long = AURALIS_DEFAULT_REQUEST_TIMEOUT_MS,
    val usesStreaming: Boolean = true,
    val supportsJsonMode: Boolean = false,
    val supportsJsonSchema: Boolean = false,
    val supportsToolCalling: Boolean = false,
    val supportsParallelTools: Boolean = false,
    val supportsToolChoice: Boolean = false,
    val supportsStrictSchema: Boolean = false,
    val supportsReasoningMetadata: Boolean = false,
    val supportsReasoningControl: Boolean = false,
    /** 思考参数方言（AI-02）；默认 [AiReasoningDialect.Automatic] 按协议选保守形态。 */
    val reasoningDialect: AiReasoningDialect = AiReasoningDialect.Automatic,
    val assumesImplicitStreamTermination: Boolean = false,
    val hasVerifiedModelAvailability: Boolean = false,
)

internal fun AiProviderConfiguration.continuationScope(model: String): String =
    listOf(baseUrl.trimEnd('/'), apiPath.trim('/'), model).joinToString("|")

internal fun AiProviderConfiguration.nativeItems(message: AiMessage, vendor: AiProviderToolMode, model: String): List<kotlinx.serialization.json.JsonObject>? =
    message.continuation?.takeIf { it.vendor == vendor && it.scope == continuationScope(model) }?.items

/**
 * 测试用 Provider：不联网，返回固定回答。
 * 隐私确认流程对它不生效（审计 §5.4：注入式 Mock 不走外发）。
 */
class MockAiProvider(
    private val model: String = "auralis-test-curator",
) : AiProvider {
    override suspend fun testConnection(): AiConnectionResult =
        AiConnectionResult(latencyMillis = 12, model = model, message = "Test provider is ready")

    override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse =
        AiCompletionResponse(
            model = request.model,
            content = "已从本地测试音乐库生成策展结果。",
            inputTokens = 42,
            outputTokens = 18,
        )

    override fun stream(request: AiCompletionRequest): Flow<AiStreamEvent> = flow {
        emit(AiStreamEvent.Started(request.model))
        emit(AiStreamEvent.AnswerDelta("理解需求 → 搜索音乐库 → 筛选候选 → 安排顺序"))
        emit(AiStreamEvent.Completed)
    }
}
