// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AnthropicMessagesProviderTest {
    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun provider(
        streaming: Boolean = true,
        supportsToolChoice: Boolean = true,
        supportsReasoningControl: Boolean = false,
        reasoningDialect: AiReasoningDialect = AiReasoningDialect.Automatic,
        client: okhttp3.OkHttpClient? = null,
    ): AnthropicMessagesProvider = AnthropicMessagesProvider(
        AiProviderConfiguration(
            id = "anthropic-test",
            name = "anthropic-test",
            baseUrl = server.url("/").toString(),
            apiPath = "/v1/messages",
            credentialId = null,
            model = "claude-test",
            usesStreaming = streaming,
            supportsToolCalling = true,
            supportsToolChoice = supportsToolChoice,
            supportsParallelTools = true,
            supportsReasoningControl = supportsReasoningControl,
            reasoningDialect = reasoningDialect,
        ),
        apiKeyProvider = { "sk-ant-test" },
        client = client,
    )

    @Test
    fun `request uses Anthropic blocks headers and grouped tool results`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"id":"msg_1","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}""",
            ),
        )
        val call1 = AiToolCall("tool_1", "library_search", Json.parseToJsonElement("{\"query\":\"夜曲\"}"))
        val call2 = AiToolCall("tool_2", "library_get_playlist", Json.parseToJsonElement("{\"id\":\"p1\"}"))
        provider(streaming = false).complete(
            AiCompletionRequest(
                model = "claude-test",
                messages = listOf(
                    AiMessage(AiMessage.Role.System, "system rules"),
                    AiMessage(AiMessage.Role.User, "inspect library"),
                    AiMessage(AiMessage.Role.Assistant, "", toolCalls = listOf(call1, call2)),
                    AiMessage(AiMessage.Role.Tool, "{\"count\":1}", toolCallId = "tool_1"),
                    AiMessage(AiMessage.Role.Tool, "{\"name\":\"Mix\"}", toolCallId = "tool_2"),
                ),
                tools = listOf(
                    AiToolDefinition(
                        "library_search",
                        "search",
                        "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}",
                    ),
                ),
                toolChoice = AiToolChoice.Named("library_search"),
            ),
        )

        val request = server.takeRequest()
        assertEquals("sk-ant-test", request.getHeader("x-api-key"))
        assertEquals("2023-06-01", request.getHeader("anthropic-version"))
        assertNull(request.getHeader("Authorization"))

        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("system rules", body["system"]!!.jsonPrimitive.content)
        val messages = body["messages"]!!.jsonArray
        assertEquals(3, messages.size)
        assertEquals("user", messages[0].jsonObject["role"]!!.jsonPrimitive.content)
        assertEquals("assistant", messages[1].jsonObject["role"]!!.jsonPrimitive.content)
        val assistantBlocks = messages[1].jsonObject["content"]!!.jsonArray
        assertEquals(listOf("tool_use", "tool_use"), assistantBlocks.map { it.jsonObject["type"]!!.jsonPrimitive.content })
        val resultBlocks = messages[2].jsonObject["content"]!!.jsonArray
        assertEquals(2, resultBlocks.size)
        assertEquals("tool_1", resultBlocks[0].jsonObject["tool_use_id"]!!.jsonPrimitive.content)
        assertEquals("tool_2", resultBlocks[1].jsonObject["tool_use_id"]!!.jsonPrimitive.content)

        val tool = body["tools"]!!.jsonArray.single().jsonObject
        assertEquals("library_search", tool["name"]!!.jsonPrimitive.content)
        assertEquals("object", tool["input_schema"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("tool", body["tool_choice"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("library_search", body["tool_choice"]!!.jsonObject["name"]!!.jsonPrimitive.content)
    }

    @Test
    fun `completion decodes text thinking tool call and usage`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{
                  "id":"msg_1","type":"message","role":"assistant","model":"claude-test",
                  "content":[
                    {"type":"thinking","thinking":"先检查本地库"},
                    {"type":"tool_use","id":"tool_9","name":"library_search","input":{"query":"夜曲"}},
                    {"type":"text","text":"找到结果"}
                  ],
                  "stop_reason":"tool_use",
                  "usage":{"input_tokens":12,"output_tokens":7}
                }""",
            ),
        )

        val response = provider(streaming = false).complete(
            AiCompletionRequest("claude-test", listOf(AiMessage(AiMessage.Role.User, "找夜曲"))),
        )
        assertEquals("找到结果", response.content)
        assertEquals("先检查本地库", response.reasoning)
        assertEquals("tool_use", response.finishReason)
        assertEquals(12, response.inputTokens)
        assertEquals(7, response.outputTokens)
        assertEquals("library_search", response.toolCalls!!.single().name)
        assertEquals("夜曲", response.toolCalls!!.single().argumentObject!!["query"]!!.jsonPrimitive.content)
        assertEquals(AiProviderToolMode.AnthropicMessages, provider(false).capabilities.toolMode)
    }

    @Test
    fun `stream assembles Anthropic tool input in content block order`() = runBlocking {
        val sse = buildString {
            append("data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-test\",\"usage\":{\"input_tokens\":3}}}\n\n")
            append("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"先查\"}}\n\n")
            append("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"library_search\",\"input\":{}}}\n\n")
            append("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"夜\"}}\n\n")
            append("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"曲\\\"}\"}}\n\n")
            append("data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":2}}\n\n")
            append("data: {\"type\":\"message_stop\"}\n\n")
        }
        server.enqueue(MockResponse().setResponseCode(200).setBody(sse))

        val events = provider(streaming = true).stream(
            AiCompletionRequest("claude-test", listOf(AiMessage(AiMessage.Role.User, "查"))),
        ).toList()
        assertTrue(events.any { it is AiStreamEvent.AnswerDelta && it.text == "先查" })
        val call = events.filterIsInstance<AiStreamEvent.ToolCall>().single().call
        assertEquals("tool_1", call.id)
        assertEquals("library_search", call.name)
        assertEquals("夜曲", call.argumentObject!!["query"]!!.jsonPrimitive.content)
        assertTrue(events.last() is AiStreamEvent.Completed)
    }

    @Test
    fun `factory routes messages responses and chat independently`() {
        val base = AiProviderConfiguration(
            id = "p",
            name = "p",
            baseUrl = server.url("/").toString(),
            apiPath = "/v1/messages",
            credentialId = null,
            model = "m",
        )
        assertTrue(AiProviderFactory.create(base, { null }) is AnthropicMessagesProvider)
        assertTrue(AiProviderFactory.create(base.copy(apiPath = "/v1/responses"), { null }) is OpenAiResponsesProvider)
        assertTrue(AiProviderFactory.create(base.copy(apiPath = "/v1/chat/completions"), { null }) is OpenAiCompatibleProvider)
    }

    // ------------------------------------------------------------------
    // AI-02：思考方言矩阵（dialect × effort × 低预算 × tool_choice）。
    // ------------------------------------------------------------------

    private fun thinkingBody(
        dialect: AiReasoningDialect,
        effort: AiReasoningEffort = AiReasoningEffort.Medium,
        mode: AiReasoningMode = AiReasoningMode.Enabled,
        maxTokens: Int = 16_000,
        supportsReasoningControl: Boolean = true,
        toolChoice: AiToolChoice? = null,
    ): kotlinx.serialization.json.JsonObject = provider(
        streaming = false,
        supportsReasoningControl = supportsReasoningControl,
        reasoningDialect = dialect,
    ).requestBody(
        AiCompletionRequest(
            model = "claude-test",
            messages = listOf(AiMessage(AiMessage.Role.User, "hi")),
            maxTokens = maxTokens,
            reasoning = AiReasoningConfiguration(mode = mode, effort = effort),
            tools = listOf(AiToolDefinition("library_search", "search", """{"type":"object"}""")),
            toolChoice = toolChoice,
        ),
        stream = false,
    )

    @Test
    fun `automatic 解析为 manual 且 effort 映射 budget`() {
        val body = thinkingBody(AiReasoningDialect.Automatic, AiReasoningEffort.High)
        val thinking = body["thinking"]!!.jsonObject
        assertEquals("enabled", thinking["type"]!!.jsonPrimitive.content)
        assertEquals(4_096, thinking["budget_tokens"]!!.jsonPrimitive.content.toInt())
        assertEquals(2_048, thinkingBody(AiReasoningDialect.Manual, AiReasoningEffort.Medium)["thinking"]!!
            .jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
        assertEquals(1_024, thinkingBody(AiReasoningDialect.Manual, AiReasoningEffort.Low)["thinking"]!!
            .jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
        assertEquals(1_024, thinkingBody(AiReasoningDialect.Manual, AiReasoningEffort.Minimal)["thinking"]!!
            .jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun `manual 低预算时 budget 收敛到 maxTokens-1`() {
        val body = thinkingBody(AiReasoningDialect.Manual, AiReasoningEffort.High, maxTokens = 2_000)
        assertEquals(1_999, body["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
        // maxTokens<=1 无法容纳 budget → 不发送 thinking，恢复 temperature。
        val tiny = thinkingBody(AiReasoningDialect.Manual, AiReasoningEffort.High, maxTokens = 1)
        assertNull(tiny["thinking"])
        assertTrue(tiny.containsKey("temperature"))
    }

    @Test
    fun `adaptive 方言无 budget_tokens`() {
        val body = thinkingBody(AiReasoningDialect.Adaptive, AiReasoningEffort.High)
        val thinking = body["thinking"]!!.jsonObject
        assertEquals("adaptive", thinking["type"]!!.jsonPrimitive.content)
        assertNull(thinking["budget_tokens"])
    }

    @Test
    fun `disabled 不发送 thinking 且恢复 temperature`() {
        val body = thinkingBody(AiReasoningDialect.Disabled, AiReasoningEffort.High)
        assertNull(body["thinking"])
        assertTrue(body.containsKey("temperature"))
        // 端点未声明支持 / 用户关思考 → 同样不发送。
        assertNull(thinkingBody(AiReasoningDialect.Manual, supportsReasoningControl = false)["thinking"])
        assertNull(thinkingBody(AiReasoningDialect.Manual, mode = AiReasoningMode.Disabled)["thinking"])
    }

    @Test
    fun `手动思考与强制 tool_choice 不能组合`() {
        val body = thinkingBody(
            AiReasoningDialect.Manual,
            AiReasoningEffort.Medium,
            toolChoice = AiToolChoice.Named("library_search"),
        )
        assertNull(body["thinking"])
        assertEquals("tool", body["tool_choice"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("library_search", body["tool_choice"]!!.jsonObject["name"]!!.jsonPrimitive.content)
    }

    @Test
    fun `端点拒绝 thinking 参数时仅本次降级重试不永久关闭`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(400)
                .setBody("""{"error":{"message":"thinking.budget_tokens: not supported for this model"}}"""),
        )
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"id":"msg_1","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}""",
            ),
        )
        val p = provider(streaming = false, supportsReasoningControl = true, reasoningDialect = AiReasoningDialect.Manual)
        val response = p.complete(
            AiCompletionRequest(
                model = "claude-test",
                messages = listOf(AiMessage(AiMessage.Role.User, "hi")),
                reasoning = AiReasoningConfiguration(AiReasoningMode.Enabled, AiReasoningEffort.Medium),
            ),
        )
        assertEquals("ok", response.content)
        assertEquals(2, server.requestCount)
        val first = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        val second = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertTrue(first.containsKey("thinking"))
        assertNull(second["thinking"])
        // 不永久关闭：下一次请求仍携带 thinking。
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"id":"msg_2","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"ok2"}],"stop_reason":"end_turn"}""",
            ),
        )
        p.complete(
            AiCompletionRequest(
                model = "claude-test",
                messages = listOf(AiMessage(AiMessage.Role.User, "hi")),
                reasoning = AiReasoningConfiguration(AiReasoningMode.Enabled, AiReasoningEffort.Medium),
            ),
        )
        val third = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertTrue(third.containsKey("thinking"))
    }

    // ------------------------------------------------------------------
    // AI-06：硬期限（非 delay 型假测试；client callTimeout 故意很大）。
    // ------------------------------------------------------------------

    private fun slowClient(): okhttp3.OkHttpClient = okhttp3.OkHttpClient.Builder()
        .callTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .connectTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .build()

    @Test
    fun `连接不回应时 withTimeout 及时恢复且连接被关闭`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setHeadersDelay(1500, java.util.concurrent.TimeUnit.MILLISECONDS)
                .setBody("{}"),
        )
        val client = slowClient()
        val p = provider(streaming = false, client = client)
        val started = System.currentTimeMillis()
        val result = kotlinx.coroutines.withTimeoutOrNull(300) {
            p.complete(AiCompletionRequest("claude-test", listOf(AiMessage(AiMessage.Role.User, "hi"))))
        }
        val elapsed = System.currentTimeMillis() - started
        assertNull(result)
        assertTrue("300ms 期限必须及时恢复（实际 ${elapsed}ms）", elapsed < 5_000)
        assertEquals(0, client.connectionPool.idleConnectionCount())
    }

    @Test
    fun `滴字节的流式读取可被取消`() = runBlocking {
        // 字节持续滴（全程 >300ms 但有限）：readTimeout 不会触发，只能靠取消打断。
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody("data: {\"type\":\"message_start\",\"message\":{\"model\":\"m\"}}\n\n" + " ".repeat(8_192))
                .throttleBody(512, 100, java.util.concurrent.TimeUnit.MILLISECONDS),
        )
        val p = provider(streaming = true, client = slowClient())
        val started = System.currentTimeMillis()
        val events = kotlinx.coroutines.withTimeoutOrNull(300) {
            p.stream(AiCompletionRequest("claude-test", listOf(AiMessage(AiMessage.Role.User, "hi")))).toList()
        }
        val elapsed = System.currentTimeMillis() - started
        assertNull(events)
        assertTrue("流式读取必须可中断（实际 ${elapsed}ms）", elapsed < 5_000)
    }

    @Test
    fun `非流式 refusal 保留拒绝终止语义`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"id":"msg_refused","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"不能处理该请求"}],"stop_reason":"refusal","usage":{"input_tokens":3,"output_tokens":2}}""",
            ),
        )
        val events = provider(streaming = false).stream(
            AiCompletionRequest(
                model = "claude-test",
                messages = listOf(AiMessage(AiMessage.Role.User, "test")),
            ),
        ).toList()

        val request = server.takeRequest()
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertNull(body["stream"])
        assertTrue(events.any { it is AiStreamEvent.AnswerDelta && it.text == "不能处理该请求" })
        val terminal = events.last() as AiStreamEvent.Terminated
        assertEquals(AiStreamTerminationKind.Refused, terminal.termination.kind)
        assertEquals("refusal", terminal.termination.rawReason)
        assertTrue(events.none { it is AiStreamEvent.Completed })
    }

}
