// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AgentToolLoop 语义测试：fail-closed 授权、destructive 二次确认、
 * 工具结果回灌、收敛与轮次保护。
 */
class AgentToolLoopTest {

    /** 预置响应的假 Provider：按调用次数出队，耗尽后重复最后一个。 */
    private class FakeLoopProvider(
        vararg val queue: AiCompletionResponse,
    ) : AiProvider {
        override val supportsToolCalling: Boolean = true
        val requests = ArrayList<AiCompletionRequest>()
        private var index = 0
        var delayNextRequest = false

        override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse {
            requests += request
            if (delayNextRequest) { delayNextRequest = false; delay(5_000) }
            val r = queue[index.coerceAtMost(queue.size - 1)]
            if (index < queue.size - 1) index++
            return r
        }

        override suspend fun testConnection(): AiConnectionResult =
            AiConnectionResult(0, "m", "ok")

        override fun stream(request: AiCompletionRequest) = kotlinx.coroutines.flow.emptyFlow<AiStreamEvent>()
    }

    private fun toolCall(name: String, vararg kv: Pair<String, String>): AiToolCall {
        val obj = buildJsonObject { kv.forEach { (k, v) -> put(k, v) } }
        return AiToolCall(id = "call-$name", name = name, arguments = obj)
    }

    private fun registry(): AgentToolRegistry = AgentToolRegistry().apply {
        register(
            AgentToolDescriptor(
                name = "set_favorite",
                description = "收藏一首歌（写操作）",
                parametersJson = """{"type":"object","properties":{"trackId":{"type":"string"}}}""",
                sideEffect = ToolSideEffect.Write,
            ),
        ) { args -> "已收藏 ${args["trackId"]}" }
        register(
            AgentToolDescriptor(
                name = "delete_playlist",
                description = "删除歌单（不可逆）",
                parametersJson = """{"type":"object","properties":{"playlistId":{"type":"string"}}}""",
                sideEffect = ToolSideEffect.Write,
                confirmationPolicy = ToolConfirmationPolicy.Destructive,
            ),
        ) { args -> "已删除歌单 ${args["playlistId"]}" }
        register(
            AgentToolDescriptor(name = "library_stats", description = "统计音乐库（只读）"),
        ) { "共 120 首" }
    }

    private fun final(text: String) = AiCompletionResponse(
        model = "m", content = text, finishReason = "stop",
    )

    @Test
    fun `未授权写操作 fail closed 并回灌错误`() = runBlocking {
        val provider = FakeLoopProvider(
            AiCompletionResponse(
                model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("set_favorite", "trackId" to "t1")),
            ),
            final("完成"),
        )
        val loop = AgentToolLoop(provider, registry())
        val events = ArrayList<AgentRunEvent>()
        val result = loop.run(
            systemPrompt = null,
            userText = "收藏这首歌",
            model = "m",
            authorizeOperations = emptySet(), // 未授权 → fail closed
            onEvent = { events.add(it) },
        )
        // 第一次模型要执行写工具但未获授权 → ToolDenied，绝不真正执行。
        assertTrue(events.any { it is AgentRunEvent.ToolDenied })
        assertEquals(0, result.writeOperations.size)
        // 第二轮请求必须包含 .tool 角色的错误回灌。
        assertEquals(2, provider.requests.size)
        val toolMsg = provider.requests[1].messages.first { it.role == AiMessage.Role.Tool }
        assertTrue(toolMsg.content.contains("未获授权"))
        assertEquals("call-set_favorite", toolMsg.toolCallId)
        assertTrue(result.finalAnswer.isNotEmpty())
    }

    @Test
    fun `destructive 工具确认被拒时回灌取消原因且不执行`() = runBlocking {
        val provider = FakeLoopProvider(
            AiCompletionResponse(
                model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("delete_playlist", "playlistId" to "p9")),
            ),
            final("好，保留歌单"),
        )
        val loop = AgentToolLoop(provider, registry())
        var confirmed: OperationConfirmation? = null
        val result = loop.run(
            systemPrompt = null,
            userText = "删除歌单 p9",
            model = "m",
            authorizeOperations = setOf("delete_playlist"),
            confirm = { pending -> confirmed = pending; false }, // 用户拒绝
        )
        assertEquals("执行「delete_playlist」", confirmed?.title)
        assertTrue(result.writeOperations.isEmpty())
        val denied = provider.requests[1].messages.first { it.role == AiMessage.Role.Tool }
        assertTrue(denied.content.contains("取消"))
    }

    @Test
    fun `授权并批准后工具成功执行并写入记录`() = runBlocking {
        val provider = FakeLoopProvider(
            AiCompletionResponse(
                model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("set_favorite", "trackId" to "t1")),
            ),
            final("已收藏"),
        )
        val loop = AgentToolLoop(provider, registry())
        val result = loop.run(
            systemPrompt = null,
            userText = "收藏 t1",
            model = "m",
            authorizeOperations = setOf("set_favorite"),
        )
        assertEquals(1, result.writeOperations.size)
        assertEquals("set_favorite", result.writeOperations[0].name)
        assertEquals("已收藏", result.finalAnswer)
        // 第二轮回灌的 tool 消息是成功结果。
        val toolMsg = provider.requests[1].messages.first { it.role == AiMessage.Role.Tool }
        assertTrue(toolMsg.content.contains("已收藏"))
    }

    @Test
    fun `只读工具无需授权即可执行`() = runBlocking {
        val provider = FakeLoopProvider(
            AiCompletionResponse(
                model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("library_stats")),
            ),
            final("知道了"),
        )
        val loop = AgentToolLoop(provider, registry())
        val result = loop.run(
            systemPrompt = null, userText = "库里有几首？", model = "m",
            authorizeOperations = emptySet(),
        )
        assertEquals(0, result.writeOperations.size)
        assertTrue(result.finalAnswer.isNotEmpty())
    }

    @Test
    fun `超过最大轮次返回未收敛提示`() = runBlocking {
        // 模型永远要求执行只读工具（合法），循环必须被 maxRounds 兜住。
        val provider = FakeLoopProvider(
            AiCompletionResponse(
                model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("library_stats")),
            ),
        )
        val loop = AgentToolLoop(provider, registry(), maxRounds = 3)
        val result = loop.run(
            systemPrompt = null, userText = "循环", model = "m",
            authorizeOperations = emptySet(),
        )
        assertEquals(3, provider.requests.size)
        assertTrue(result.finalAnswer.contains("未收敛"))
    }

    @Test
    fun `工具取消直接传播而不是回灌成工具失败`() = runBlocking {
        val provider = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("cancelled"))), final("不应执行"),
        )
        val tools = AgentToolRegistry().apply {
            register(AgentToolDescriptor(name = "cancelled", description = "test")) {
                throw CancellationException("cancelled")
            }
        }
        var propagated = false
        val events = ArrayList<AgentRunEvent>()
        try {
            AgentToolLoop(provider, tools).run(null, "query", "m", onEvent = { events += it })
        } catch (_: CancellationException) { propagated = true }
        assertTrue(propagated)
        assertEquals(1, provider.requests.size)
        assertTrue(events.none { it is AgentRunEvent.ToolDenied })
    }

    @Test
    fun `只读工具超时回灌并继续模型换路径`() = runBlocking {
        val provider = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls",
                toolCalls = listOf(toolCall("slow"))), final("改用已有结果"),
        )
        val tools = AgentToolRegistry().apply {
            register(AgentToolDescriptor(name = "slow", description = "test")) { delay(5_000); "late" }
        }
        val result = AgentToolLoop(provider, tools, toolTimeoutMillis = 50).run(null, "query", "m")
        assertEquals("改用已有结果", result.finalAnswer)
        assertTrue(provider.requests[1].messages.any { it.role == AiMessage.Role.Tool && it.content.contains("tool_timeout") })
    }

    @Test
    fun `写工具超时不会再次执行相同未知结果操作`() = runBlocking {
        val call = toolCall("write")
        val response = AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls", toolCalls = listOf(call))
        val provider = FakeLoopProvider(response, response, final("需要核验"))
        var executions = 0
        val tools = AgentToolRegistry().apply {
            register(AgentToolDescriptor(name = "write", description = "test", sideEffect = ToolSideEffect.Write)) {
                executions += 1
                delay(5_000)
                "late"
            }
        }
        val result = AgentToolLoop(provider, tools, toolTimeoutMillis = 50).run(null, "write", "m", authorizeOperations = setOf("write"))
        assertEquals(1, executions)
        assertTrue(result.writeOperations.isEmpty())
        assertTrue(provider.requests[2].messages.any { it.content.contains("先查询核验") })
    }

    @Test
    fun `模型响应超时后尝试更短规划并返回结果`() = runBlocking {
        val provider = FakeLoopProvider(final("恢复成功")).apply { delayNextRequest = true }
        val result = AgentToolLoop(provider, AgentToolRegistry(), roundTimeoutMillis = 50).run(null, "query", "m")
        assertEquals("恢复成功", result.finalAnswer)
        assertEquals(2, provider.requests.size)
        assertTrue(provider.requests[1].messages.any { it.content.contains("上一轮模型请求超时") })
    }

}
