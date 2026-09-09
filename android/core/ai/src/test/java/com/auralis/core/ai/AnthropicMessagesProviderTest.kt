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
        ),
        apiKeyProvider = { "sk-ant-test" },
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
}
