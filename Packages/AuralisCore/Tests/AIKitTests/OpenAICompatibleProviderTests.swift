@testable import AIKit
import Foundation
import SecurityKit
import Testing

struct OpenAICompatibleProviderTests {
    private func makeProvider(baseURL: String, apiPath: String = "/v1/chat/completions") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: baseURL)!,
                apiPath: apiPath,
                model: "test-model"
            ),
            credentialVault: KeychainCredentialVault()
        )
    }

    @Test func endpointAvoidsDoubleSlashWhenBaseHasTrailingSlash() throws {
        let provider = makeProvider(baseURL: "http://localhost:11434/")
        let url = try provider.endpoint()
        #expect(url.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func endpointAppendsPathToPlainBase() throws {
        let provider = makeProvider(baseURL: "https://api.deepseek.com")
        let url = try provider.endpoint()
        #expect(url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test func endpointKeepsRelativePathWithoutLeadingSlash() throws {
        let provider = makeProvider(baseURL: "https://example.com/api", apiPath: "chat/completions")
        let url = try provider.endpoint()
        #expect(url.absoluteString == "https://example.com/api/chat/completions")
    }

    @Test func retryableClassifiesTransientFailures() {
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(503)) == true)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(502)) == true)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(504)) == true)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(429)) == true)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(500)) == true)
    }

    @Test func retryableRejectsPermanentFailures() {
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(400)) == false)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(404)) == false)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.httpStatus(200)) == false)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.malformedResponse(detail: "not openai", retryable: false)) == false)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.missingCredential) == false)
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.invalidEndpoint) == false)
    }

    @Test func retryableAllowsTransportErrors() {
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.transport("connection reset")) == true)
    }

    /// 偶发空响应 / 截断 JSON 属于网关抖动，必须可重试，
    /// 否则会出现「测试点好几次才成功」这类现象。
    @Test func retryableAllowsTransientParseFailures() {
        #expect(OpenAICompatibleProvider.isRetryable(AIProviderError.malformedResponse(detail: "空响应体", retryable: true)) == true)
    }

    // MARK: - 响应解析容错

    private func parse(_ json: String, model: String = "test-model") throws -> AICompletionResponse {
        try OpenAICompatibleProvider.parseCompletion(data: Data(json.utf8), fallbackModel: model)
    }

    @Test func parsesStandardChatCompletion() throws {
        let response = try parse("""
        {"model":"gpt-x","choices":[{"message":{"role":"assistant","content":"你好"}}],
         "usage":{"prompt_tokens":10,"completion_tokens":3}}
        """)
        #expect(response.content == "你好")
        #expect(response.model == "gpt-x")
        #expect(response.inputTokens == 10)
        #expect(response.outputTokens == 3)
    }

    @Test func emptyBodyIsRetryableMalformed() {
        #expect(throws: AIProviderError.self) {
            try OpenAICompatibleProvider.parseCompletion(data: Data(), fallbackModel: "m")
        }
        do {
            _ = try OpenAICompatibleProvider.parseCompletion(data: Data(), fallbackModel: "m")
            Issue.record("空响应体应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == true)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test func htmlErrorPageIsRetryableMalformed() {
        do {
            _ = try parse("<html><body>502 Bad Gateway</body></html>")
            Issue.record("HTML 错误页应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == true)
            #expect(error.errorDescription?.contains("502 Bad Gateway") == true)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    /// content 为 null（例如只返回 tool_calls）不再判为解析失败。
    @Test func nullContentDegradesToEmptyString() throws {
        let response = try parse("""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[]}}]}
        """)
        #expect(response.content.isEmpty)
        #expect(response.model == "test-model")
    }

    @Test func arrayContentIsFlattened() throws {
        let response = try parse("""
        {"choices":[{"message":{"content":[{"type":"text","text":"前"},{"type":"text","text":"后"}]}}]}
        """)
        #expect(response.content == "前后")
    }

    /// 思考链（reasoning_content）必须单独保存到 reasoning 字段，
    /// 绝不混入用户可见的 content（避免把「思考链」展示出来）。
    @Test func reasoningContentIsKeptOutOfUserVisibleContent() throws {
        let response = try parse("""
        {"choices":[{"message":{"content":"","reasoning_content":"思考结果"}}]}
        """)
        #expect(response.content == "")
        #expect(response.reasoning == "思考结果")
    }

    /// 非流式请求却收到 SSE 时，把 delta 拼回完整文本而不是判死。
    @Test func sseBodyOnNonStreamRequestIsAggregated() throws {
        let sse = """
        data: {"model":"gpt-x","choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: [DONE]
        """
        let response = try parse(sse)
        #expect(response.content == "你好")
        #expect(response.model == "gpt-x")
    }

    /// HTTP 200 但 body 里是错误对象：属于服务端确定性回答，不重试，并把原文透出。
    @Test func embeddedErrorObjectIsSurfacedAndNotRetryable() {
        do {
            _ = try parse("""
            {"error":{"message":"model `foo` does not exist","type":"invalid_request_error"}}
            """)
            Issue.record("内嵌 error 对象应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == false)
            #expect(error.errorDescription?.contains("does not exist") == true)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    /// 合法 JSON 但完全不是 Chat Completions 结构 → 重试无益。
    @Test func incompatibleJSONIsNotRetryable() {
        do {
            _ = try parse(#"{"result":"ok","data":[1,2,3]}"#)
            Issue.record("不兼容结构应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == false)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test func bodyPreviewIsTruncatedWithByteCount() {
        let long = String(repeating: "A", count: 500)
        let preview = OpenAICompatibleProvider.bodyPreview(Data(long.utf8), limit: 240)
        #expect(preview.hasPrefix("AAA"))
        #expect(preview.contains("共 500 字节"))
    }

    // MARK: - 原生 Tool Calling

    @Test func parsesToolCallsAndFinishReason() throws {
        let response = try OpenAICompatibleProvider.parseCompletion(
            data: Data("""
            {"model":"gpt-x","choices":[{"message":{"role":"assistant","content":null,
              "tool_calls":[{"id":"call_abc","type":"function","function":{"name":"playTrack","arguments":"{\\"trackID\\":\\"srv:1\\"}"}}]},
              "finish_reason":"tool_calls"}]}
            """.utf8),
            fallbackModel: "test-model"
        )
        #expect(response.content == "")
        #expect(response.finishReason == "tool_calls")
        #expect(response.toolCalls?.count == 1)
        #expect(response.toolCalls?.first?.id == "call_abc")
        #expect(response.toolCalls?.first?.name == "playTrack")
        #expect(response.toolCalls?.first?.arguments.contains("srv:1") == true)
    }

    @Test func toolMessagesRoundTripPreservesToolCallIDAndToolCalls() throws {
        let toolMessage = AIMessage(role: .tool, content: "执行成功", toolCallID: "call_abc", name: "playTrack")
        let assistantMessage = AIMessage(
            role: .assistant,
            content: "",
            toolCalls: [AIToolCall(id: "call_abc", name: "playTrack", arguments: "{\"trackID\":\"srv:1\"}")]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roundTrippedTool = try decoder.decode(AIMessage.self, from: encoder.encode(toolMessage))
        #expect(roundTrippedTool.role == .tool)
        #expect(roundTrippedTool.toolCallID == "call_abc")
        #expect(roundTrippedTool.name == "playTrack")
        let roundTrippedAssistant = try decoder.decode(AIMessage.self, from: encoder.encode(assistantMessage))
        #expect(roundTrippedAssistant.toolCalls?.first?.id == "call_abc")
        #expect(roundTrippedAssistant.toolCalls?.first?.name == "playTrack")
    }

    @Test func providerDeclaresNativeToolCallingFromConfiguration() {
        let provider = OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: "https://api.openai.com")!,
                model: "gpt-4o-mini",
                supportsToolCalling: true
            ),
            credentialVault: KeychainCredentialVault()
        )
        #expect(provider.supportsToolCalling == true)
    }
}
