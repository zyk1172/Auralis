// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * OpenAICompatibleProvider 集成测试（MockWebServer）：
 * 非流式解析、SSE 流式 tool_calls 碎片拼接、参数降级、错误分类。
 */
class OpenAiCompatibleProviderTest {

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
        apiPath: String = "/v1/chat/completions",
        supportsToolCalling: Boolean = true,
        supportsToolChoice: Boolean = true,
        usesStreaming: Boolean = true,
    ): OpenAiCompatibleProvider {
        val cfg = AiProviderConfiguration(
            id = "test",
            name = "test",
            baseUrl = server.url("/").toString(),
            apiPath = apiPath,
            credentialId = null,
            model = "test-model",
            supportsToolCalling = supportsToolCalling,
            supportsToolChoice = supportsToolChoice,
            usesStreaming = usesStreaming,
            supportsParallelTools = true,
        )
        return OpenAiCompatibleProvider(cfg, apiKeyProvider = { "sk-test" })
    }

    private fun jsonBody(body: String): JsonObject =
        kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject

    // ------------------------------------------------------------------

    @Test
    fun `非流式补全解析工具调用与用量`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{
                  "model":"test-model",
                  "choices":[{"message":{
                    "role":"assistant",
                    "content":"",
                    "tool_calls":[{"id":"call_1","type":"function",
                      "function":{"name":"set_favorite","arguments":"{\"trackId\":\"t1\"}"}}]
                  },"finish_reason":"tool_calls"}],
                  "usage":{"prompt_tokens":10,"completion_tokens":5}
                }""",
            ),
        )
        val p = provider()
        val response = p.complete(
            AiCompletionRequest(
                model = "test-model",
                messages = listOf(AiMessage(AiMessage.Role.User, "收藏 t1")),
            ),
        )
        assertEquals("tool_calls", response.finishReason)
        assertEquals(10, response.inputTokens)
        assertEquals(5, response.outputTokens)
        val call = response.toolCalls!!.single()
        assertEquals("call_1", call.id)
        assertEquals("set_favorite", call.name)
        assertEquals("t1", call.argumentObject?.get("trackId")?.jsonPrimitive?.contentOrNull())
        // 请求体校验：消息、鉴权头。
        val recorded = server.takeRequest()
        assertEquals("Bearer sk-test", recorded.getHeader("Authorization"))
        val body = jsonBody(recorded.body.readUtf8())
        assertEquals("test-model", body["model"]?.jsonPrimitive?.contentOrNull())
        assertTrue(body.containsKey("messages"))
    }

    @Test
    fun `流式 tool_calls 跨 chunk 拼接且 reasoning 不混淆`() = runBlocking {
        // 分三个 chunk 的 SSE：reasoning、tool_call id/name、arguments 碎片、[DONE]。
        val sse = buildString {
            append("data: ")
            append("""{"choices":[{"delta":{"reasoning_content":"先查目录"}}]}""")
            append("\n\n")
            append("data: ")
            append(
                """{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","""
                    + """"function":{"name":"queue_append_many","arguments":"{\"ids\":[\"a\","}}]}}]}""",
            )
            append("\n\n")
            append("data: ")
            append(
                """{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"b\"]}"}}]}}]}""",
            )
            append("\n\n")
            append("data: [DONE]")
            append("\n\n")
        }
        server.enqueue(MockResponse().setResponseCode(200).setBody(sse))
        val p = provider()
        val events = p.stream(
            AiCompletionRequest(model = "test-model", messages = listOf(AiMessage(AiMessage.Role.User, "播放")), tools = emptyList()),
        ).toList()

        assertTrue(events.any { it is AiStreamEvent.ReasoningDelta && it.text == "先查目录" })
        val toolCalls = events.filterIsInstance<AiStreamEvent.ToolCall>()
        assertEquals(1, toolCalls.size)
        val call = toolCalls[0].call
        assertEquals("call_x", call.id)
        assertEquals("queue_append_many", call.name)
        // 跨 chunk 的 arguments 必须完整拼接并可解析为对象。
        assertEquals("b", call.argumentObject?.get("ids")?.jsonArray?.get(1)?.jsonPrimitive?.contentOrNull())
        assertTrue(events.last() is AiStreamEvent.Completed)
    }

    @Test
    fun `未知正文不静默丢弃`() = runBlocking {
        val sse = "data: {\"choices\":[{\"delta\":{\"content\":\"回答\"}}]}\n\n" +
            "data: gateway-nonstandard-hello\n\n" +
            "data: [DONE]\n\n"
        server.enqueue(MockResponse().setResponseCode(200).setBody(sse))
        val p = provider()
        val events = p.stream(
            AiCompletionRequest(model = "m", messages = listOf(AiMessage(AiMessage.Role.User, "hi"))),
        ).toList()
        assertTrue(events.any { it is AiStreamEvent.AnswerDelta && it.text == "回答" })
        // 非标准负载保留可见性。
        assertTrue(events.filterIsInstance<AiStreamEvent.UnknownDelta>().isNotEmpty())
    }

    @Test
    fun `400 参数降级只移除 temperature 且不删除工具`() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(400).setBody(
                """{"error":{"message":"unsupported parameter: 'temperature'"}}""",
            ),
        )
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"model":"m","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}""",
            ),
        )
        val p = provider()
        val response = p.complete(
            AiCompletionRequest(
                model = "m",
                messages = listOf(AiMessage(AiMessage.Role.User, "hi")),
                tools = listOf(AiToolDefinition("x", "xx")),
                temperature = 0.7,
            ),
        )
        assertEquals("ok", response.content)
        assertEquals(2, server.requestCount)
        val first = jsonBody(server.takeRequest().body.readUtf8())
        val second = jsonBody(server.takeRequest().body.readUtf8())
        assertTrue(first.containsKey("temperature"))
        assertTrue(second.containsKey("tools"))      // 绝不删除工具语义
        assertTrue(!second.containsKey("temperature")) // 仅移除温度
    }

    @Test
    fun `错误分类语义`() {
        val p = provider()
        // 401 + model 提示语 → 模型/上游路由问题，而非 API Key 错。
        val modelErr = p.classify(401, "The model 'gpt-x' does not exist")
        assertEquals(AiProviderFailureKind.ModelRouting, modelErr.kind)
        // 401 + api key → 鉴权。
        val keyErr = p.classify(401, "Incorrect API key provided")
        assertEquals(AiProviderFailureKind.Authentication, keyErr.kind)
        assertEquals(AiProviderFailureKind.ModelRouting, p.classify(404, "not found").kind)
        assertEquals(AiProviderFailureKind.RateLimited, p.classify(429, "rate limit").kind)
        assertTrue(p.classify(503, "upstream").retryable)
        assertEquals(AiProviderFailureKind.Authentication, p.classify(403, "forbidden").kind)
    }

    @Test
    fun `messages 编码形状正确`() {
        val call = AiToolCall(
            id = "call_1",
            name = "set_favorite",
            arguments = kotlinx.serialization.json.buildJsonObject { put("trackId", "t1") },
        )
        val assistant = AiMessage(
            role = AiMessage.Role.Assistant,
            content = "",
            toolCalls = listOf(call),
        ).asRequestObject()
        assertEquals("assistant", assistant["role"]?.jsonPrimitive?.contentOrNull())
        val tc = assistant["tool_calls"]?.jsonArray?.get(0)?.jsonObject
        assertEquals("call_1", tc?.get("id")?.jsonPrimitive?.contentOrNull())
        assertEquals(
            "set_favorite",
            tc?.get("function")?.jsonObject?.get("name")?.jsonPrimitive?.contentOrNull(),
        )

        val tool = AiMessage(
            role = AiMessage.Role.Tool,
            content = "已收藏",
            toolCallId = "call_1",
            name = "set_favorite",
        ).asRequestObject()
        assertEquals("tool", tool["role"]?.jsonPrimitive?.contentOrNull())
        assertEquals("call_1", tool["tool_call_id"]?.jsonPrimitive?.contentOrNull())
        assertEquals("已收藏", tool["content"]?.jsonPrimitive?.contentOrNull())
    }
}
