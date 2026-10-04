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
        /** AI-08 测试用：覆盖默认 capabilities（默认 256k 窗口）。 */
        var caps: ModelCapabilities? = null

        override val capabilities: ModelCapabilities
            get() = caps ?: ModelCapabilities(supportsToolCalling = true)

        private fun next(request: AiCompletionRequest): AiCompletionResponse {
            requests += request
            val r = queue[index.coerceAtMost(queue.size - 1)]
            if (index < queue.size - 1) index++
            return r
        }

        override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse {
            if (delayNextRequest) { delayNextRequest = false; delay(5_000) }
            return next(request)
        }

        override suspend fun testConnection(): AiConnectionResult =
            AiConnectionResult(0, "m", "ok")

        // 工具循环走 stream：与真实 Provider 的非流式投影一致地回放预置响应。
        override fun stream(request: AiCompletionRequest) = kotlinx.coroutines.flow.flow {
            requests += request
            if (delayNextRequest) { delayNextRequest = false; delay(5_000) }
            val r = queue[index.coerceAtMost(queue.size - 1)]
            if (index < queue.size - 1) index++
            emit(AiStreamEvent.Started(r.model))
            r.reasoning?.takeIf { it.isNotEmpty() }?.let { emit(AiStreamEvent.ReasoningDelta(it)) }
            if (r.content.isNotEmpty()) emit(AiStreamEvent.AnswerDelta(r.content))
            r.toolCalls.orEmpty().forEach { emit(AiStreamEvent.ToolCall(it)) }
            emit(AiStreamEvent.Completed)
        }
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

    // ------------------------------------------------------------ AI-05：会话历史投影

    @Test
    fun `会话历史插在 system 之后当前 user 之前`() = runBlocking {
        val provider = FakeLoopProvider(final("已加入"))
        val loop = AgentToolLoop(provider, registry())
        loop.run(
            systemPrompt = "SYS",
            userText = "把刚才第三首加入队列",
            model = "m",
            history = listOf(
                AiMessage(AiMessage.Role.User, "帮我选几首周杰伦"),
                AiMessage(AiMessage.Role.Assistant, "已选：1.晴天 2.夜曲 3.稻香"),
            ),
        )
        val msgs = provider.requests[0].messages
        assertEquals(4, msgs.size)
        assertEquals(AiMessage.Role.System, msgs[0].role)
        assertEquals("SYS", msgs[0].content)
        assertEquals(AiMessage.Role.User, msgs[1].role)
        assertEquals("帮我选几首周杰伦", msgs[1].content)
        assertEquals(AiMessage.Role.Assistant, msgs[2].role)
        assertEquals("已选：1.晴天 2.夜曲 3.稻香", msgs[2].content)
        assertEquals(AiMessage.Role.User, msgs[3].role)
        assertEquals("把刚才第三首加入队列", msgs[3].content)
    }

    // ------------------------------------------------------------ AI-07：畸形工具参数

    private fun searchRegistry(executions: () -> Unit): AgentToolRegistry = AgentToolRegistry().apply {
        register(
            AgentToolDescriptor(
                name = "search",
                description = "搜索",
                parametersJson = """{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}""",
            ),
        ) { executions(); "结果" }
    }

    @Test
    fun `解析失败的 JsonPrimitive 参数不再降级为空对象执行`() = runBlocking {
        var executions = 0
        // 模拟 provider decode 边界保留的畸形 raw 串（非 object）。
        val badCall = AiToolCall("c1", "search", kotlinx.serialization.json.JsonPrimitive("{broken"))
        val provider = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls", toolCalls = listOf(badCall)),
            final("已改用其它方式"),
        )
        val events = ArrayList<AgentRunEvent>()
        val result = AgentToolLoop(provider, searchRegistry { executions += 1 })
            .run(null, "搜索", "m", onEvent = { events += it })
        assertEquals(0, executions)
        assertTrue(events.any { it is AgentRunEvent.ToolDenied })
        val toolMsg = provider.requests[1].messages.first { it.role == AiMessage.Role.Tool }
        assertTrue(toolMsg.content.contains("malformed_arguments"))
        assertTrue(toolMsg.content.contains("期望格式"))
        assertEquals("c1", toolMsg.toolCallId)
        assertEquals("已改用其它方式", result.finalAnswer)
    }

    @Test
    fun `缺必填与错误类型的参数不执行`() = runBlocking {
        var executions = 0
        val missing = AiToolCall("c1", "search", buildJsonObject { })
        val wrongType = AiToolCall("c2", "search", buildJsonObject { put("q", 5) })
        val provider = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls", toolCalls = listOf(missing, wrongType)),
            final("无法执行"),
        )
        AgentToolLoop(provider, searchRegistry { executions += 1 }).run(null, "搜索", "m")
        assertEquals(0, executions)
        val toolMsgs = provider.requests[1].messages.filter { it.role == AiMessage.Role.Tool }
        assertEquals(2, toolMsgs.size)
        assertTrue(toolMsgs.all { it.content.contains("malformed_arguments") })
    }

    @Test
    fun `无参工具接受空对象但拒绝非对象与垃圾字段`() = runBlocking {
        var executions = 0
        val tools = AgentToolRegistry().apply {
            register(AgentToolDescriptor(name = "next", description = "下一首")) { executions += 1; "已切歌" }
        }
        // {} → 执行
        val okCall = AiToolCall("c1", "next", buildJsonObject { })
        val p1 = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls", toolCalls = listOf(okCall)),
            final("好"),
        )
        AgentToolLoop(provider = p1, registry = tools).run(null, "下一首", "m")
        assertEquals(1, executions)
        // 垃圾字段 → malformed，不执行
        val junkCall = AiToolCall("c2", "next", buildJsonObject { put("positionSeconds", "abc") })
        val p2 = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls", toolCalls = listOf(junkCall)),
            final("参数有误"),
        )
        AgentToolLoop(provider = p2, registry = tools).run(null, "下一首", "m")
        assertEquals(1, executions)
        assertTrue(p2.requests[1].messages.any { it.role == AiMessage.Role.Tool && it.content.contains("malformed_arguments") })
        // 数组根 → malformed，不执行
        val arrayCall = AiToolCall("c3", "next", kotlinx.serialization.json.JsonArray(emptyList()))
        val p3 = FakeLoopProvider(
            AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls", toolCalls = listOf(arrayCall)),
            final("参数有误"),
        )
        AgentToolLoop(provider = p3, registry = tools).run(null, "下一首", "m")
        assertEquals(1, executions)
    }

    // ------------------------------------------------------------ AI-08：流式与上下文预算

    /** 直接以流式事件回复的假 Provider。 */
    private class FakeStreamProvider(
        val script: List<List<AiStreamEvent>>,
    ) : AiProvider {
        override val supportsToolCalling: Boolean = true
        val requests = ArrayList<AiCompletionRequest>()
        private var index = 0

        override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse =
            throw UnsupportedOperationException("loop 必须走 stream")

        override suspend fun testConnection(): AiConnectionResult = AiConnectionResult(0, "m", "ok")

        override fun stream(request: AiCompletionRequest) = kotlinx.coroutines.flow.flow {
            requests += request
            val events = script[index.coerceAtMost(script.size - 1)]
            if (index < script.size - 1) index++
            for (event in events) {
                if (event is AiStreamEvent.UnknownDelta && event.text == "HANG") {
                    delay(60_000) // 模拟挂起（可取消）
                } else {
                    emit(event)
                }
            }
        }
    }

    @Test
    fun `流式正文 delta 在收敛前逐步下发且定稿一致`() = runBlocking {
        val provider = FakeStreamProvider(
            listOf(
                listOf(
                    AiStreamEvent.Started("m"),
                    AiStreamEvent.AnswerDelta("你"),
                    AiStreamEvent.AnswerDelta("好"),
                    AiStreamEvent.ReasoningDelta("想一下"),
                    AiStreamEvent.Completed,
                ),
            ),
        )
        val events = ArrayList<AgentRunEvent>()
        val result = AgentToolLoop(provider, AgentToolRegistry())
            .run(null, "hi", "m", onEvent = { events += it })
        val deltas = events.filterIsInstance<AgentRunEvent.AssistantTextDelta>()
        assertEquals(listOf("你", "好"), deltas.map { it.text })
        assertTrue(events.any { it is AgentRunEvent.ReasoningDelta && it.text == "想一下" })
        // 定稿事件在 delta 之后到达，且与 delta 拼接一致。
        val full = events.filterIsInstance<AgentRunEvent.AssistantText>().single()
        assertEquals("你好", full.text)
        assertTrue(events.indexOf(full) > events.indexOf(deltas.last()))
        assertEquals("你好", result.finalAnswer)
    }

    @Test
    fun `流式挂起被超时取消后走更短路径恢复`() = runBlocking {
        val provider = FakeStreamProvider(
            listOf(
                listOf(AiStreamEvent.Started("m"), AiStreamEvent.AnswerDelta("partial"), AiStreamEvent.UnknownDelta("HANG")),
                listOf(AiStreamEvent.AnswerDelta("恢复"), AiStreamEvent.Completed),
            ),
        )
        val events = ArrayList<AgentRunEvent>()
        val result = AgentToolLoop(provider, AgentToolRegistry(), roundTimeoutMillis = 100)
            .run(null, "hi", "m", onEvent = { events += it })
        assertEquals("恢复", result.finalAnswer)
        assertEquals(2, provider.requests.size)
        // 第一轮的部分 delta 已下过，取消后回灌了换路径提示。
        assertTrue(events.any { it is AgentRunEvent.AssistantTextDelta && it.text == "partial" })
        assertTrue(provider.requests[1].messages.any { it.content.contains("上一轮模型请求超时") })
    }

    @Test
    fun `超预算时最早工具组成对裁剪且 schema 保持完整`() = runBlocking {
        val big = "x".repeat(3_000)
        val tools = AgentToolRegistry().apply {
            register(AgentToolDescriptor(name = "big", description = "大结果查询")) { big }
        }
        val r1 = AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls",
            toolCalls = listOf(AiToolCall("c1", "big", buildJsonObject { })))
        val r2 = AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls",
            toolCalls = listOf(AiToolCall("c2", "big", buildJsonObject { })))
        val provider = FakeLoopProvider(r1, r2, final("总结")).apply {
            caps = ModelCapabilities(supportsToolCalling = true, maxContextTokens = 16_500)
        }
        val result = AgentToolLoop(provider, tools).run(null, "go", "m")
        assertEquals("总结", result.finalAnswer)
        val finalMessages = provider.requests.last().messages
        // 配对不悬空：tool 消息与 assistant call 一一对应。
        val callIds = finalMessages.filter { it.role == AiMessage.Role.Assistant }
            .flatMap { it.toolCalls.orEmpty().map { c -> c.id } }.toSet()
        val resultIds = finalMessages.filter { it.role == AiMessage.Role.Tool }
            .mapNotNull { it.toolCallId }.toSet()
        assertEquals(callIds, resultIds)
        // 预算 500 token 容不下两组 1000+ token 的结果 → 必有裁剪与摘要占位。
        assertTrue(finalMessages.any { it.content.contains("已省略较早的") })
        // schema 列表保持完整，不裁工具定义。
        assertTrue(provider.requests.last().tools.orEmpty().any { it.name == "big" })
        // 当前 user 不被动。
        assertTrue(finalMessages.any { it.role == AiMessage.Role.User && it.content == "go" })
    }

    // ------------------------------------------------------------ AI-12：披露权限投影

    @Test
    fun `受限类别的工具结果只回元信息给模型且本地事件不受限`() = runBlocking {
        val lyricJson = """{"ok":true,"synced":true,"language":"zh","lineCount":42,"preview":[{"text":"私密歌词正文"}]}"""
        val tools = AgentToolRegistry().apply {
            register(
                AgentToolDescriptor(
                    name = "lyrics_get",
                    description = "歌词",
                    disclosureCategory = AiPrivacyCategory.Lyrics,
                ),
            ) { lyricJson }
        }
        val response = AiCompletionResponse(model = "m", content = "", finishReason = "tool_calls",
            toolCalls = listOf(AiToolCall("c1", "lyrics_get", buildJsonObject { })))
        // 默认权限（lyrics 关）
        val p1 = FakeLoopProvider(response, final("好的"))
        val events = ArrayList<AgentRunEvent>()
        AgentToolLoop(p1, tools).run(null, "歌词", "m", onEvent = { events += it })
        val toolMsg = p1.requests[1].messages.first { it.role == AiMessage.Role.Tool }
        assertTrue(toolMsg.content.contains("隐藏"))
        assertTrue(toolMsg.content.contains("42"))
        assertTrue(!toolMsg.content.contains("私密歌词正文"))
        // 本地 UI 事件不受限：ToolCompleted 仍携带完整结果。
        val completed = events.filterIsInstance<AgentRunEvent.ToolCompleted>().single()
        assertTrue(completed.result.contains("私密歌词正文"))
        // 权限打开后正文可回灌
        val p2 = FakeLoopProvider(response, final("好的"))
        AgentToolLoop(p2, tools, privacyPermissions = AiPrivacyPermissions(allowsLyrics = true))
            .run(null, "歌词", "m")
        val toolMsg2 = p2.requests[1].messages.first { it.role == AiMessage.Role.Tool }
        assertTrue(toolMsg2.content.contains("私密歌词正文"))
    }

}
