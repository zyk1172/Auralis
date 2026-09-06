@file:Suppress("unused")

package com.auralis.core.ai

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

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
     * 执行工具（唯一副作用边界）。写操作必须通过 [authorization] 授权；
     * Destructive 工具在写之前还须经 [confirm] 批准（由 UI 绑定到具体 runID）。
     */
    suspend fun execute(
        name: String,
        arguments: Map<String, JsonElement>,
        authorization: SideEffectAuthorizationContext,
        confirm: suspend (OperationConfirmation) -> Boolean = { true },
    ): String {
        val descriptor = tools[name] ?: throw UnknownToolException(name)
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
        return executor(arguments)
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
)

/** 运行期间逐轮下发的模型原生事件流。 */
sealed interface AgentRunEvent {
    data class AssistantText(val text: String) : AgentRunEvent
    data class Reasoning(val text: String) : AgentRunEvent
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
) {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * @param lineage 授权来源。`authorizeOperations` 从原始用户请求解析授权的
     *   canonical 操作；不传表示仅执行只读工具。
     */
    suspend fun run(
        systemPrompt: String?,
        userText: String,
        model: String,
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
        messages += AiMessage(AiMessage.Role.User, userText)
        val writeOps = ArrayList<AiToolCall>()
        var rounds = 0
        var lastModel = model

        while (rounds < maxRounds) {
            rounds += 1
            val response = provider.complete(
                AiCompletionRequest(
                    model = model,
                    messages = messages.toList(),
                    tools = registry.descriptors().map { d ->
                        AiToolDefinition(d.name, d.description, d.parametersJson)
                    }.takeIf { provider.supportsToolCalling },
                    toolChoice = if (provider.capabilities.supportsToolChoice) {
                        AiToolChoice.Auto
                    } else {
                        null
                    },
                    reasoning = reasoning,
                ),
            )
            lastModel = response.model
            val calls = response.toolCalls.orEmpty()
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
                )
            }
            // 回灌 assistant tool_calls 消息。
            messages += AiMessage(
                role = AiMessage.Role.Assistant,
                content = response.content,
                toolCalls = calls,
            )
            // 逐个执行工具（可并行，但保留串行以稳定回灌顺序；顺序语义与 Swift 一致）。
            for (call in calls) {
                onEvent(AgentRunEvent.ToolInvoked(call))
                val arguments = call.argumentObject ?: emptyMap()
                try {
                    val result = registry.execute(call.name, arguments, authorization, confirm)
                    if (registry.descriptor(call.name)?.sideEffect == ToolSideEffect.Write) {
                        writeOps += call
                    }
                    onEvent(AgentRunEvent.ToolCompleted(call, result))
                    messages += AiMessage(
                        role = AiMessage.Role.Tool,
                        content = result,
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
        )
    }
}

/** SSE 片段拼装与 JSON 解析共用的 Json 实例。 */
internal fun agentJson(): Json = Json { ignoreUnknownKeys = true }
