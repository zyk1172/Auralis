// SPDX-License-Identifier: GPL-3.0-only
@file:Suppress("unused")

package com.auralis.core.ai

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// ---------------------------------------------------------------------------
// AgentTool 层：Swift `AgentToolkit / AgentToolRegistry / ToolLoop` 的语义对齐子集。
//
// 核心不变式（审计 §5.2/5.3）：
// - 唯一副作用边界在注册表 execute：先按 descriptor 校验参数，再执行；不存在两套执行系统；
// - 最小授权：SideEffectAuthorizationContext 只来自原始用户请求（lineage）解析出的
//   canonical operation；网页/搜索/模型文本永远不能产生授权；
// - 写操作未精确授权 → fail closed（抛 [ToolExecutionDenied]）；
// - 仅 `confirmationPolicy == Destructive` 的不可逆删除工具在副作用执行前挂起等待批准，
//   确认属于具体 runID（UI 层负责把确认绑到 run）。
// ---------------------------------------------------------------------------

/** 工具副作用边界。 */
enum class ToolSideEffect { ReadOnly, Write }

/** 二次确认策略：仅 Destructive 在副作用执行前挂起等待 UI 批准。 */
enum class ToolConfirmationPolicy { None, Destructive }

/** 需要 UI 确认的不可逆操作描述（标题/正文，按钮「批准并执行」/「取消」）。 */
data class OperationConfirmation(
    val title: String,
    val detail: String,
)

/** 模型可见的确定性工具（name 即 canonical operation）。 */
data class AgentToolDescriptor(
    val name: String,
    val description: String,
    val parametersJson: String? = null,
    val sideEffect: ToolSideEffect = ToolSideEffect.ReadOnly,
    val confirmationPolicy: ToolConfirmationPolicy = ToolConfirmationPolicy.None,
    /** AI-12：结果回灌模型前按此披露类别投影（受限类别只回元信息/计数）。 */
    val disclosureCategory: AiPrivacyCategory? = null,
)

/** 最小授权上下文：来自原始用户请求的授权 canonical operation 集合。 */
class SideEffectAuthorizationContext(
    private val authorized: Set<String>,
) {
    fun allows(operation: String): Boolean = operation in authorized
}

class ToolExecutionDenied(val operation: String) :
    Exception("写操作未获授权，fail closed: $operation")

/** 拒绝用户确认时回灌给模型的结构化失败（跳过桥接层）。 */
class ToolExecutionFailure(
    val operation: String,
    reason: String,
) : Exception(reason)

class UnknownToolException(val operation: String) :
    Exception("未知工具: $operation")

/** 注册表：模型可见工具在此集中登记，执行是唯一副作用边界。 */
class AgentToolRegistry {
    private val tools = LinkedHashMap<String, AgentToolDescriptor>()
    private val executors = LinkedHashMap<String, suspend (Map<String, JsonElement>) -> String>()

    fun register(
        descriptor: AgentToolDescriptor,
        executor: suspend (Map<String, JsonElement>) -> String,
    ) {
        tools[descriptor.name] = descriptor
        executors[descriptor.name] = executor
    }

    fun descriptors(): List<AgentToolDescriptor> = tools.values.toList()

    fun descriptor(name: String): AgentToolDescriptor? = tools[name]

    fun contains(name: String): Boolean = tools.containsKey(name)

    /**
     * 执行工具（唯一副作用边界）。
     *
     * AI-07：先按 descriptor.parametersJson 校验参数（畸形参数抛 [MalformedToolArguments]，
     * 绝不静默降级为空对象执行）；写操作必须通过 [authorization] 授权；
     * Destructive 工具在写之前还须经 [confirm] 批准（由 UI 绑定到具体 runID）。
     */
    suspend fun execute(
        name: String,
        arguments: AiJsonValue,
        authorization: SideEffectAuthorizationContext,
        confirm: suspend (OperationConfirmation) -> Boolean = { true },
    ): String {
        val descriptor = tools[name] ?: throw UnknownToolException(name)
        ToolArgumentValidator.validate(name, descriptor.parametersJson, arguments)?.let { reason ->
            throw MalformedToolArguments(name, reason)
        }
        val executor = executors[name] ?: throw UnknownToolException(name)
        if (descriptor.sideEffect == ToolSideEffect.Write) {
            if (!authorization.allows(name)) throw ToolExecutionDenied(name)
            if (descriptor.confirmationPolicy == ToolConfirmationPolicy.Destructive) {
                val approved = confirm(
                    OperationConfirmation(
                        title = "执行「${descriptor.name}」",
                        detail = descriptor.description,
                    ),
                )
                if (!approved) {
                    throw ToolExecutionFailure(
                        operation = name,
                        reason = "用户取消了该操作",
                    )
                }
            }
        }
        // 校验通过后根必是 object（validate 已拒绝非 object 根）。
        return executor((arguments as? JsonObject) ?: emptyMap())
    }
}

// ---------------------------------------------------------------------------
// ToolLoop：普通聊天 / 确定性任务共用的工具循环。
// ---------------------------------------------------------------------------

/** 一次 Agent 运行的结果（工具循环收敛后）。 */
data class AgentRunResult(
    val finalAnswer: String,
    val rounds: Int,
    val model: String,
    /** 执行成功的写操作（供 AgentActionLog 记录/undo）。 */
    val writeOperations: List<AiToolCall> = emptyList(),
    val disclosureCategories: Set<AiPrivacyCategory> = emptySet(),
)

/** 运行期间逐轮下发的模型原生事件流。 */
sealed interface AgentRunEvent {
    /** 收敛后的完整正文（AI-08 流式下为增量 delta 之后的定稿信号）。 */
    data class AssistantText(val text: String) : AgentRunEvent

    /** AI-08：流式正文增量；Coordinator 端增量渲染，绝不落盘。 */
    data class AssistantTextDelta(val text: String) : AgentRunEvent

    data class Reasoning(val text: String) : AgentRunEvent

    /** AI-08：流式思考增量；只瞬态展示，绝不持久化。 */
    data class ReasoningDelta(val text: String) : AgentRunEvent
    data class ToolInvoked(val call: AiToolCall) : AgentRunEvent
    data class ToolCompleted(val call: AiToolCall, val result: String) : AgentRunEvent
    data class ToolDenied(val call: AiToolCall, val reason: String) : AgentRunEvent
    data object Finished : AgentRunEvent
}

/**
 * 工具调用循环：
 * 1. 请求模型 → 若返回 tool_calls：逐个经注册表执行（fail-closed），
 *    assistant(tool_calls) + tool(结果) 回灌，再次请求；
 * 2. 无 tool_calls（finish_reason=stop）→ 收敛，返回最终文本；
 * 3. maxRounds 保护；Provider 流式/非流式由 [AiProvider] 自身投影处理。
 *
 * 注意：循环本身是纯逻辑、无 UI；运行权/会话隔离（迟到 runID 丢弃）
 * 由上层 AgentCoordinator 负责。
 */
class AgentToolLoop(
    private val provider: AiProvider,
    private val registry: AgentToolRegistry,
    private val maxRounds: Int = 8,
    private val roundTimeoutMillis: Long = 360_000,
    private val toolTimeoutMillis: Long = 360_000,
    /** AI-12：工具结果回灌模型前的披露权限（默认仅 metadata 开，与 Swift/设置一致）。 */
    private val privacyPermissions: AiPrivacyPermissions = AiPrivacyPermissions(),
) {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * @param history AI-05：会话历史投影（已按披露权限过滤），插在 system 之后、
     *   当前 user 之前；只含当前会话的用户消息与助手定稿正文。
     * @param authorizeOperations 授权来源。从原始用户请求解析授权的
     *   canonical 操作；不传表示仅执行只读工具。
     */
    suspend fun run(
        systemPrompt: String?,
        userText: String,
        model: String,
        history: List<AiMessage> = emptyList(),
        authorizeOperations: Set<String> = emptySet(),
        confirm: suspend (OperationConfirmation) -> Boolean = { true },
        onEvent: suspend (AgentRunEvent) -> Unit = {},
        reasoning: AiReasoningConfiguration? = null,
    ): AgentRunResult {
        val authorization = SideEffectAuthorizationContext(authorizeOperations)
        val messages = ArrayList<AiMessage>()
        if (!systemPrompt.isNullOrBlank()) {
            messages += AiMessage(AiMessage.Role.System, systemPrompt)
        }
        messages += history
        messages += AiMessage(AiMessage.Role.User, userText)
        val writeOps = ArrayList<AiToolCall>()
        var rounds = 0
        var lastModel = model
        val indeterminateWrites = HashSet<String>()
        val disclosed = history.flatMap { it.disclosureCategories }.toMutableSet()

        while (rounds < maxRounds) {
            rounds += 1
            suspend fun requestRound(): AiCompletionResponse? = withTimeoutOrNull(roundTimeoutMillis) {
                val tools = registry.descriptors().map { d ->
                    AiToolDefinition(d.name, d.description, d.parametersJson)
                }.takeIf { provider.supportsToolCalling }
                // AI-08：发送前按输入预算原子裁剪最早的 tool call/result 组
                // （schema 列表保持完整；预算 = 上下文窗口 - 输出预留 - schema 估算）。
                val contextBudget = provider.capabilities.maxContextTokens -
                    provider.capabilities.maxOutputTokens
                if (contextBudget > 0) {
                    ContextBudget.trimToolGroupsToBudget(
                        messages = messages,
                        toolSchemaTokens = ContextBudget.estimateTools(tools.orEmpty()),
                        budgetTokens = contextBudget,
                    )
                }
                val request = AiCompletionRequest(
                    model = model,
                    messages = messages.toList(),
                    tools = tools,
                    toolChoice = if (provider.capabilities.supportsToolChoice) {
                        AiToolChoice.Auto
                    } else {
                        null
                    },
                    reasoning = reasoning,
                    maxTokens = provider.capabilities.maxOutputTokens,
                )
                requestStreaming(request, onEvent)
            }
            val response = requestRound() ?: run {
                onEvent(AgentRunEvent.Reasoning("模型响应已达到等待上限，正在尝试更短的路径继续。"))
                messages += AiMessage(
                    role = AiMessage.Role.User,
                    content = "上一轮模型请求超时。请改用更短规划或已有本地查询完成原请求，不要重复同一路径。",
                )
                requestRound()
            } ?: return AgentRunResult(
                finalAnswer = "模型响应超时，换路径后仍未取得结果。本次任务未完成，可以稍后继续。",
                rounds = rounds, model = lastModel, writeOperations = writeOps,
                disclosureCategories = disclosed.toSet(),
            ).also { onEvent(AgentRunEvent.Finished) }
            lastModel = response.model
            val calls = if (response.termination.kind == AiStreamTerminationKind.Refused) emptyList() else response.toolCalls.orEmpty()
            if (calls.isEmpty()) {
                // 收敛：最终可见回答。
                if (response.content.isNotEmpty()) {
                    onEvent(AgentRunEvent.AssistantText(response.content))
                }
                onEvent(AgentRunEvent.Finished)
                return AgentRunResult(
                    finalAnswer = response.content,
                    rounds = rounds,
                    model = lastModel,
                    writeOperations = writeOps,
                    disclosureCategories = disclosed.toSet(),
                )
            }
            // 回灌 assistant tool_calls 消息。
            messages += AiMessage(
                role = AiMessage.Role.Assistant,
                content = response.content,
                toolCalls = calls,
                continuation = response.continuation,
            )
            // 逐个执行工具（可并行，但保留串行以稳定回灌顺序；顺序语义与 Swift 一致）。
            for (call in calls) {
                onEvent(AgentRunEvent.ToolInvoked(call))
                try {
                    val isWrite = registry.descriptor(call.name)?.sideEffect == ToolSideEffect.Write
                    val signature = call.name + ":" + call.rawArguments
                    val result = if (signature in indeterminateWrites) {
                        "tool_timeout: 上一次相同写操作结果未知，请先查询核验，不要重复执行。"
                    } else {
                        val completed = withTimeoutOrNull(toolTimeoutMillis) {
                            // AI-07：传原始结构化参数；畸形参数由执行边界统一拒绝，
                            // 绝不 `?: emptyMap()` 放行成空调用。
                            registry.execute(call.name, call.arguments, authorization, confirm)
                        }
                        if (completed == null) {
                            if (isWrite) indeterminateWrites += signature
                            if (isWrite) "tool_timeout: 操作超时，结果可能未知。请先查询核验，再选择其它路径。"
                            else "tool_timeout: 查询超时，请换用其它可用查询路径继续原请求。"
                        } else {
                            if (isWrite) writeOps += call
                            completed
                        }
                    }
                    onEvent(AgentRunEvent.ToolCompleted(call, result))
                    // AI-12：只在发给模型的投影层按披露类别过滤；本地事件/ UI 不受限。
                    val projected = AiPrivacyProjection.projectToolResult(
                        registry.descriptor(call.name)?.disclosureCategory,
                        result,
                        privacyPermissions,
                    )
                    registry.descriptor(call.name)?.disclosureCategory?.let { category ->
                        if (privacyPermissions.allows(category)) disclosed += category
                    }
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = projected,
                        toolCallId = call.id,
                        name = call.name,
                    )
                } catch (malformed: MalformedToolArguments) {
                    // AI-07：畸形参数不执行，回灌明确错误与期望格式让模型修正。
                    onEvent(AgentRunEvent.ToolDenied(call, "参数格式错误，未执行"))
                    val descriptor = registry.descriptor(call.name)
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = "malformed_arguments: ${malformed.reason}。期望格式：" +
                            "${ToolArgumentValidator.expectedFormat(descriptor?.parametersJson)}。" +
                            "请按 schema 修正参数后重试，不要静默补全未知字段。",
                        toolCallId = call.id,
                        name = call.name,
                    )
                } catch (denied: ToolExecutionDenied) {
                    onEvent(AgentRunEvent.ToolDenied(call, "该操作未获你的授权（fail closed）"))
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = "错误：写操作 ${call.name} 未获授权（fail closed）。请用可授权的表述重试。",
                        toolCallId = call.id,
                        name = call.name,
                    )
                } catch (failure: ToolExecutionFailure) {
                    onEvent(AgentRunEvent.ToolDenied(call, failure.message ?: "用户取消"))
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = "错误：${failure.message ?: "用户取消"}",
                        toolCallId = call.id,
                        name = call.name,
                    )
                } catch (unknown: UnknownToolException) {
                    onEvent(AgentRunEvent.ToolDenied(call, "未知工具"))
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = "错误：工具 ${call.name} 不存在。",
                        toolCallId = call.id,
                        name = call.name,
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (e: Exception) {
                    onEvent(AgentRunEvent.ToolDenied(call, e.message ?: "执行失败"))
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = "错误：${e.message ?: "工具执行失败"}",
                        toolCallId = call.id,
                        name = call.name,
                    )
                }
            }
        }
        // 达到 maxRounds：不静默截断，明确返回未收敛状态。
        onEvent(AgentRunEvent.Finished)
        return AgentRunResult(
            finalAnswer = "已达到最大工具轮次（$maxRounds），任务未收敛。请精简请求或拆分步骤。",
            rounds = rounds,
            model = lastModel,
            writeOperations = writeOps,
            disclosureCategories = disclosed.toSet(),
        )
    }

    /**
     * AI-08：消费 provider.stream 聚合成一轮响应。
     * 正文/思考 delta 实时经 [onEvent] 下发（慢模型下用户尽快看到首文本），
     * 工具调用事件保持；UnknownDelta 不静默丢弃（计入正文并保持可见）。
     * 端点禁用 SSE 时 provider 内部以非流式投影为事件流，本函数无需分支。
     */
    private suspend fun requestStreaming(
        request: AiCompletionRequest,
        onEvent: suspend (AgentRunEvent) -> Unit,
    ): AiCompletionResponse {
        val answer = StringBuilder()
        val reasoningBuf = StringBuilder()
        val calls = ArrayList<AiToolCall>()
        var responseModel = request.model
        var inputTokens: Int? = null
        var outputTokens: Int? = null
        var continuation: AiProviderContinuation? = null
        var termination: AiStreamTermination? = null
        provider.stream(request).collect { event ->
            when (event) {
                is AiStreamEvent.Started -> responseModel = event.model
                is AiStreamEvent.AnswerDelta -> {
                    answer.append(event.text)
                    onEvent(AgentRunEvent.AssistantTextDelta(event.text))
                }
                is AiStreamEvent.ReasoningDelta -> {
                    reasoningBuf.append(event.text)
                    onEvent(AgentRunEvent.ReasoningDelta(event.text))
                }
                is AiStreamEvent.UnknownDelta -> {
                    answer.append(event.text)
                    onEvent(AgentRunEvent.AssistantTextDelta(event.text))
                }
                is AiStreamEvent.ToolCall -> calls += event.call
                is AiStreamEvent.Usage -> {
                    inputTokens = event.input
                    outputTokens = event.output
                }
                is AiStreamEvent.WebCitations -> Unit
                is AiStreamEvent.Continuation -> continuation = event.value
                is AiStreamEvent.Terminated -> {
                    event.termination.requireComplete()
                    termination = event.termination
                }
                AiStreamEvent.Completed -> termination = AiStreamTermination.chat(if (calls.isEmpty()) "stop" else "tool_calls")
            }
        }
        val ended = termination ?: AiStreamTermination(AiStreamTerminationKind.Interrupted, "EOF")
        ended.requireComplete()
        return AiCompletionResponse(
            model = responseModel,
            content = answer.toString(),
            reasoning = reasoningBuf.toString().takeIf { it.isNotEmpty() },
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            finishReason = if (calls.isEmpty()) "stop" else "tool_calls",
            toolCalls = calls.takeIf { it.isNotEmpty() },
            continuation = continuation,
            termination = ended,
        )
    }
}

/** SSE 片段拼装与 JSON 解析共用的 Json 实例。 */
internal fun agentJson(): Json = Json { ignoreUnknownKeys = true }
