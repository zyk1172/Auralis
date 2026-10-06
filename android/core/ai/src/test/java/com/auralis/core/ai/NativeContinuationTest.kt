// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.ai

import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class NativeContinuationTest {
    private val json = Json
    private fun config(server: MockWebServer, path: String, implicit: Boolean = false) = AiProviderConfiguration(
        id = "test", name = "test", baseUrl = server.url("/").toString(), apiPath = path,
        credentialId = null, model = "m", usesStreaming = false,
        assumesImplicitStreamTermination = implicit,
    )

    @Test fun `Claude signed and redacted blocks replay in original order and model changes discard them`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val cfg = config(server, "/v1/messages")
            val provider = AnthropicMessagesProvider(cfg, apiKeyProvider = { null })
            val output = """[{"type":"text","text":"first"},{"type":"thinking","thinking":"hidden","signature":"sig"},{"type":"redacted_thinking","data":"opaque"},{"type":"tool_use","id":"c","name":"read","input":{}}]"""
            server.enqueue(MockResponse().setBody("""{"model":"m","content":$output,"stop_reason":"tool_use"}"""))
            val response = provider.complete(AiCompletionRequest("m", listOf(AiMessage(AiMessage.Role.User, "q"))))
            val message = AiMessage(AiMessage.Role.Assistant, response.content, toolCalls = response.toolCalls, continuation = response.continuation)
            val replay = provider.requestBody(AiCompletionRequest("m", listOf(message)), false)
            assertEquals(json.parseToJsonElement(output), replay["messages"]!!.jsonArray[0].jsonObject["content"])
            val switched = provider.requestBody(AiCompletionRequest("other", listOf(message)), false)
            assertEquals(listOf("text", "tool_use"), switched["messages"]!!.jsonArray[0].jsonObject["content"]!!.jsonArray.map { it.jsonObject["type"]!!.jsonPrimitive.content })
        }
    }

    @Test fun `Responses replays encrypted reasoning and all output items without duplicate text`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val provider = OpenAiResponsesProvider(config(server, "/v1/responses"), apiKeyProvider = { null })
            val output = """[{"type":"message","id":"msg","role":"assistant","content":[{"type":"output_text","text":"first"}]},{"type":"reasoning","id":"r","encrypted_content":"opaque","summary":[]},{"type":"function_call","id":"fc","call_id":"c","name":"read","arguments":"{}"}]"""
            server.enqueue(MockResponse().setBody("""{"model":"m","status":"completed","output":$output}"""))
            val response = provider.complete(AiCompletionRequest("m", listOf(AiMessage(AiMessage.Role.User, "q"))))
            val assistant = AiMessage(AiMessage.Role.Assistant, response.content, toolCalls = response.toolCalls, continuation = response.continuation)
            val replay = provider.requestBody(AiCompletionRequest("m", listOf(assistant)), false)
            assertEquals(json.parseToJsonElement(output), replay["input"])
            assertEquals("false", replay["store"]!!.jsonPrimitive.content)
        }
    }

    @Test fun `Chat reasoning continuation is discarded across endpoints`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val cfg = config(server, "/v1/chat/completions")
            val provider = OpenAiCompatibleProvider(cfg, apiKeyProvider = { null })
            server.enqueue(MockResponse().setBody("""{"model":"m","choices":[{"message":{"content":"first","reasoning_content":"hidden"},"finish_reason":"stop"}]}"""))
            val response = provider.complete(AiCompletionRequest("m", listOf(AiMessage(AiMessage.Role.User, "q"))))
            val assistant = AiMessage(AiMessage.Role.Assistant, response.content, continuation = response.continuation)
            val replay = provider.requestBody(AiCompletionRequest("m", listOf(assistant)), false)
            assertEquals("hidden", replay["messages"]!!.jsonArray[0].jsonObject["reasoning_content"]!!.jsonPrimitive.content)
            val other = OpenAiCompatibleProvider(cfg.copy(baseUrl = "https://other.example"), apiKeyProvider = { null })
            assertNull(other.requestBody(AiCompletionRequest("m", listOf(assistant)), false)["messages"]!!.jsonArray[0].jsonObject["reasoning_content"])
        }
    }

    @Test fun `all three protocols reject natural EOF by default`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val paths = listOf("/v1/chat/completions", "/v1/messages", "/v1/responses")
            val bodies = listOf(
                "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n",
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
            )
            paths.zip(bodies).forEach { (path, body) ->
                server.enqueue(MockResponse().setHeader("Content-Type", "text/event-stream").setBody(body))
                val provider = AiProviderFactory.create(config(server, path).copy(usesStreaming = true), apiKeyProvider = { null })
                val events = provider.stream(AiCompletionRequest("m", listOf(AiMessage(AiMessage.Role.User, "q")))).toList()
                assertFalse(events.contains(AiStreamEvent.Completed))
                assertEquals(AiStreamTerminationKind.Interrupted, (events.last() as AiStreamEvent.Terminated).termination.kind)
            }
        }
    }

    @Test fun `truncated tool turn has no side effects`() = runBlocking {
        var writes = 0
        val registry = AgentToolRegistry().apply { register(AgentToolDescriptor("write", "write")) { writes++; "done" } }
        val provider = object : AiProvider {
            override val supportsToolCalling = true
            override suspend fun complete(request: AiCompletionRequest) = error("unused")
            override suspend fun testConnection() = AiConnectionResult(0, "m", "ok")
            override fun stream(request: AiCompletionRequest) = flow {
                emit(AiStreamEvent.ToolCall(AiToolCall("c", "write", json.parseToJsonElement("{}"))))
                emit(AiStreamEvent.Terminated(AiStreamTermination(AiStreamTerminationKind.Truncated)))
            }
        }
        try { AgentToolLoop(provider, registry).run(null, "q", "m"); fail("Expected incomplete turn") }
        catch (_: AiProviderException) { }
        assertEquals(0, writes)
    }
    @Test fun `answer inherits source categories even without a new tool call`() = runBlocking {
        val provider = object : AiProvider {
            override val supportsToolCalling = true
            override suspend fun complete(request: AiCompletionRequest) = error("unused")
            override suspend fun testConnection() = AiConnectionResult(0, "m", "ok")
            override fun stream(request: AiCompletionRequest) = flow {
                emit(AiStreamEvent.AnswerDelta("quoted answer"))
                emit(AiStreamEvent.Completed)
            }
        }
        val history = listOf(AiMessage(AiMessage.Role.Assistant, "reference", disclosureCategories = setOf(AiPrivacyCategory.Lyrics)))
        val result = AgentToolLoop(provider, AgentToolRegistry(), privacyPermissions = AiPrivacyPermissions(allowsLyrics = true)).run(null, "q", "m", history = history)
        assertEquals(setOf(AiPrivacyCategory.Lyrics), result.disclosureCategories)
    }

}
