// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.ai

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AI-08：上下文预算裁剪 —— tool call/result 成对原子裁剪、
 * tool_call_id 不悬空、摘要占位、system 与当前 user 不被动。
 */
class ContextBudgetTest {

    private fun call(id: String, name: String = "tool") = AiToolCall(
        id = id,
        name = name,
        arguments = buildJsonObject { put("k", "v") },
    )

    private fun group(id: String, resultSize: Int): List<AiMessage> = listOf(
        AiMessage(AiMessage.Role.Assistant, "", toolCalls = listOf(call(id))),
        AiMessage(AiMessage.Role.Tool, "x".repeat(resultSize), toolCallId = id, name = "tool"),
    )

    /** 校验不存在悬空的 tool_call_id（tool 消息必有对应 assistant call，反之亦然）。 */
    private fun assertNoDanglingToolPairs(messages: List<AiMessage>) {
        val callIds = messages.filter { it.role == AiMessage.Role.Assistant }
            .flatMap { it.toolCalls.orEmpty().map { c -> c.id } }.toSet()
        val resultIds = messages.filter { it.role == AiMessage.Role.Tool }
            .mapNotNull { it.toolCallId }.toSet()
        assertEquals(callIds, resultIds)
    }

    @Test
    fun `超预算时最早的组被成对裁剪并插入摘要`() {
        val messages = mutableListOf(
            AiMessage(AiMessage.Role.System, "sys"),
            AiMessage(AiMessage.Role.User, "当前请求"),
        )
        messages += group("c1", 3000)
        messages += group("c2", 3000)
        // 预算只够留下当前 user + 摘要 + 至多一组（粗估）。
        val trimmed = ContextBudget.trimToolGroupsToBudget(
            messages,
            toolSchemaTokens = 0,
            budgetTokens = 1_200,
        )
        assertTrue(trimmed >= 1)
        // c1 必被裁掉；占位摘要存在。
        assertTrue(messages.none { it.toolCalls.orEmpty().any { c -> c.id == "c1" } })
        assertTrue(messages.none { it.role == AiMessage.Role.Tool && it.toolCallId == "c1" })
        assertTrue(messages.any { it.content.contains("已省略较早的") })
        assertNoDanglingToolPairs(messages)
        // system 与当前 user 不动。
        assertEquals(AiMessage.Role.System, messages.first().role)
        assertTrue(messages.any { it.role == AiMessage.Role.User && it.content == "当前请求" })
    }

    @Test
    fun `预算充足时不裁剪`() {
        val messages = mutableListOf(
            AiMessage(AiMessage.Role.System, "sys"),
            AiMessage(AiMessage.Role.User, "hi"),
        )
        messages += group("c1", 100)
        val before = messages.toList()
        val trimmed = ContextBudget.trimToolGroupsToBudget(messages, toolSchemaTokens = 0, budgetTokens = 100_000)
        assertEquals(0, trimmed)
        assertEquals(before, messages)
    }

    @Test
    fun `全部组裁完后仍超预算也不产生悬空配对`() {
        val messages = mutableListOf(
            AiMessage(AiMessage.Role.System, "s".repeat(9000)),
            AiMessage(AiMessage.Role.User, "u".repeat(9000)),
        )
        messages += group("c1", 3000)
        messages += group("c2", 3000)
        ContextBudget.trimToolGroupsToBudget(messages, toolSchemaTokens = 0, budgetTokens = 10)
        assertNoDanglingToolPairs(messages)
        assertFalse(messages.any { it.role == AiMessage.Role.Tool })
        assertFalse(messages.any { !it.toolCalls.isNullOrEmpty() })
    }

    @Test
    fun `一个 assistant 的多个并发调用与其结果作为同组裁剪`() {
        val calls = listOf(call("a1"), call("a2"))
        val messages = mutableListOf(
            AiMessage(AiMessage.Role.System, "sys"),
            AiMessage(AiMessage.Role.User, "当前请求"),
            AiMessage(AiMessage.Role.Assistant, "", toolCalls = calls),
            AiMessage(AiMessage.Role.Tool, "r".repeat(2000), toolCallId = "a1", name = "tool"),
            AiMessage(AiMessage.Role.Tool, "r".repeat(2000), toolCallId = "a2", name = "tool"),
        )
        val trimmed = ContextBudget.trimToolGroupsToBudget(messages, toolSchemaTokens = 0, budgetTokens = 200)
        assertEquals(1, trimmed)
        assertNoDanglingToolPairs(messages)
        assertFalse(messages.any { it.role == AiMessage.Role.Tool })
    }
}
