package com.auralis.core.ai

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OpenAiResponsesProviderTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer(); server.start() }
    @After fun tearDown() { server.shutdown() }

    private fun provider(streaming: Boolean = true): OpenAiResponsesProvider =
        OpenAiResponsesProvider(
            AiProviderConfiguration(
                id = "responses-test",
                name = "responses-test",
                baseUrl = server.url("/").toString(),
                apiPath = "/v1/responses",
                credentialId = null,
                model = "gpt-test",
                usesStreaming = streaming,
                supportsToolCalling = true,
                supportsToolChoice = true,
                supportsParallelTools = true,
            ),
            apiKeyProvider = { "sk-test" },
        )

    @Test
    fun `request encodes Responses transcript and flattened tools`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody(
            """{"model":"gpt-test","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":4,"output_tokens":1}}""",
        ))
        val call = AiToolCall("call_1", "library_search", Json.parseToJsonElement("{\"q\":\"夜曲\"}"))
        val response = provider(streaming = false).complete(
            AiCompletionRequest(
                model = "gpt-test",
                messages = listOf(
                    AiMessage(AiMessage.Role.System, "system"),
                    AiMessage(AiMessage.Role.Assistant, "", toolCalls = listOf(call)),
                    AiMessage(AiMessage.Role.Tool, "{\"count\":1}", toolCallId = "call_1"),
                ),
                tools = listOf(AiToolDefinition("library_search", "search", "{\"type\":\"object\"}")),
                toolChoice = AiToolChoice.Named("library_search"),
            ),
        )
        assertEquals("ok", response.content)
        assertEquals(4, response.inputTokens)
        assertEquals(1, response.outputTokens)
        assertEquals(AiProviderToolMode.OpenAiResponses, provider(false).capabilities.toolMode)

        val request = server.takeRequest()
        assertEquals("Bearer sk-test", request.getHeader("Authorization"))
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        val input = body["input"]!!.jsonArray
        assertEquals("input_text", input[0].jsonObject["content"]!!.jsonArray[0].jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("function_call", input[1].jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("function_call_output", input[2].jsonObject["type"]!!.jsonPrimitive.content)
        val tool = body["tools"]!!.jsonArray.single().jsonObject
        assertEquals("function", tool["type"]!!.jsonPrimitive.content)
        assertEquals("library_search", tool["name"]!!.jsonPrimitive.content)
        assertTrue("Responses tool must not use Chat nested function shape", !tool.containsKey("function"))
        assertEquals("library_search", body["tool_choice"]!!.jsonObject["name"]!!.jsonPrimitive.content)
    }

    @Test
    fun `completion decodes text reasoning tools citations and usage`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody(
            """{
              "model":"gpt-test","status":"completed",
              "output":[
                {"type":"reasoning","summary":[{"type":"summary_text","text":"内部摘要"}]},
                {"type":"function_call","call_id":"call_9","name":"library_search","arguments":"{\"q\":\"夜曲\"}"},
                {"type":"message","role":"assistant","content":[{"type":"output_text","text":"找到结果","annotations":[{"type":"url_citation","title":"Source","url":"https://example.com/a"}]}]}
              ],
              "usage":{"input_tokens":12,"output_tokens":7}
            }""",
        ))
        val response = provider(false).complete(
            AiCompletionRequest("gpt-test", listOf(AiMessage(AiMessage.Role.User, "找夜曲"))),
        )
        assertEquals("找到结果", response.content)
        assertEquals("内部摘要", response.reasoning)
        assertEquals("library_search", response.toolCalls!!.single().name)
        assertEquals("夜曲", response.toolCalls!!.single().argumentObject!!["q"]!!.jsonPrimitive.contentOrNull)
        assertEquals("https://example.com/a", response.webCitations!!.single().url)
        assertEquals(12, response.inputTokens)
        assertEquals(7, response.outputTokens)
    }

    @Test
    fun `stream assembles function call arguments and completes`() = runBlocking {
        val sse = buildString {
            append("data: {\"type\":\"response.output_text.delta\",\"delta\":\"先查\"}\n\n")
            append("data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"library_search\"}}\n\n")
            append("data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item_1\",\"delta\":\"{\\\"q\\\":\\\"夜\"}\n\n")
            append("data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"item_1\",\"arguments\":\"{\\\"q\\\":\\\"夜曲\\\"}\"}\n\n")
            append("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}\n\n")
        }
        server.enqueue(MockResponse().setResponseCode(200).setBody(sse))
        val events = provider(true).stream(
            AiCompletionRequest("gpt-test", listOf(AiMessage(AiMessage.Role.User, "查"))),
        ).toList()
        assertTrue(events.any { it is AiStreamEvent.AnswerDelta && it.text == "先查" })
        val call = events.filterIsInstance<AiStreamEvent.ToolCall>().single().call
        assertEquals("call_1", call.id)
        assertEquals("夜曲", call.argumentObject!!["q"]!!.jsonPrimitive.content)
        assertTrue(events.any { it is AiStreamEvent.Usage && it.input == 3 && it.output == 2 })
        assertTrue(events.last() is AiStreamEvent.Completed)
    }

    @Test
    fun `factory routes responses path without affecting chat`() {
        val responsesConfig = AiProviderConfiguration(
            id = "r", name = "r", baseUrl = server.url("/").toString(), apiPath = "/v1/responses",
            credentialId = null, model = "m",
        )
        val chatConfig = responsesConfig.copy(id = "c", apiPath = "/v1/chat/completions")
        assertTrue(AiProviderFactory.create(responsesConfig, { null }) is OpenAiResponsesProvider)
        assertTrue(AiProviderFactory.create(chatConfig, { null }) is OpenAiCompatibleProvider)
    }
}
