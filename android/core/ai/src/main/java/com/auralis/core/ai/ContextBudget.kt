// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

// ---------------------------------------------------------------------------
// AI-08：输入上下文预算。
//
// 工具循环每轮把全部消息 + 全量工具 schema 发给模型，工具结果不断追加，
// 长任务会超出上下文窗口。这里提供发送前的原子裁剪：
// - 估算口径（字符近似，不做精确 tokenizer）：中英混合按 ceil(chars / 3) 计
//   （英文约 4 字符/token、中文约 1.5-2 字符/token，取保守偏大估计），
//   每条消息另加固定开销；
// - 预算 = 端点 maxContextTokens - 输出预留（maxTokens）- 工具 schema 估算；
// - 超预算时从最早开始整组裁剪 assistant(tool_calls) + 其 tool 结果
//   （call 与 result 必须成对裁，tool_call_id 配对绝不拆散），
//   并插入一句话摘要占位；system 与当前 user 不在裁剪范围内
//   （裁剪目标只有工具组，天然碰不到它们）。
// ---------------------------------------------------------------------------

object ContextBudget {

    /** 字符近似 token 估算（见文件头口径说明）。 */
    fun estimateTokens(text: String): Int = (text.length + 2) / 3

    /** 单条消息的固定结构开销（role/字段等）。 */
    private const val MESSAGE_OVERHEAD_TOKENS = 4

    fun estimateMessage(message: AiMessage): Int {
        message.continuation?.let { return MESSAGE_OVERHEAD_TOKENS + estimateTokens(it.items.toString()) }
        var tokens = MESSAGE_OVERHEAD_TOKENS + estimateTokens(message.content)
        message.toolCalls.orEmpty().forEach { call ->
            tokens += MESSAGE_OVERHEAD_TOKENS + estimateTokens(call.name) + estimateTokens(call.rawArguments)
        }
        return tokens
    }

    fun estimateTools(tools: List<AiToolDefinition>): Int = tools.sumOf { tool ->
        MESSAGE_OVERHEAD_TOKENS + estimateTokens(tool.name) +
            estimateTokens(tool.description) + estimateTokens(tool.parametersJson.orEmpty())
    }

    fun estimateMessages(messages: List<AiMessage>): Int = messages.sumOf { estimateMessage(it) }

    /**
     * 若消息（含工具 schema 估算）超出预算，从最早开始整组裁剪 tool call/result。
     *
     * @param messages 可变的上下文消息列表（原地裁剪）。
     * @param toolSchemaTokens 工具 schema 的估算 token（schema 列表保持完整，不裁）。
     * @param budgetTokens 输入预算（已扣除输出预留）。
     * @return 裁剪掉的工具组数量（0 表示未裁剪）。
     */
    fun trimToolGroupsToBudget(
        messages: MutableList<AiMessage>,
        toolSchemaTokens: Int,
        budgetTokens: Int,
    ): Int {
        fun overBudget(): Boolean =
            toolSchemaTokens + estimateMessages(messages) > budgetTokens

        var trimmed = 0
        var firstTrimmedIndex = -1
        while (overBudget()) {
            val group = earliestToolGroup(messages) ?: break
            if (firstTrimmedIndex < 0) firstTrimmedIndex = group.first
            repeat(group.last - group.first + 1) { messages.removeAt(group.first) }
            trimmed += 1
        }
        if (trimmed > 0) {
            val at = firstTrimmedIndex.coerceIn(0, messages.size)
            messages.add(
                at,
                AiMessage(
                    role = AiMessage.Role.Assistant,
                    content = "（为控制上下文长度，已省略较早的 $trimmed 组工具调用及其结果。）",
                ),
            )
        }
        return trimmed
    }

    /**
     * 最早的工具组：[assistant(带 toolCalls) 下标, 其 tool 结果的最后下标]。
     * tool 结果必须与 tool_call_id 配对且连续；缺配对的孤儿 tool 消息一并归入组内裁掉，
     * 保证裁剪后不存在悬空的 tool_call_id。
     */
    private fun earliestToolGroup(messages: List<AiMessage>): IntRange? {
        val start = messages.indexOfFirst { it.role == AiMessage.Role.Assistant && !it.toolCalls.isNullOrEmpty() }
        if (start < 0) return null
        val callIds = messages[start].toolCalls.orEmpty().map { it.id }.toSet()
        var end = start
        while (end + 1 < messages.size && messages[end + 1].role == AiMessage.Role.Tool) {
            val id = messages[end + 1].toolCallId
            if (id != null && id !in callIds) break // 不属于本组的结果，停（理论不应发生）
            end += 1
        }
        return start..end
    }
}
