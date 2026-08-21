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

    @Test func messagesProtocolIsDetectedByOpenAIProvider() async {
        #expect(OpenAICompatibleProvider.usesAnthropicMessagesAPI(apiPath: "/v1/messages"))
        let provider = makeProvider(baseURL: "https://example.com", apiPath: "/v1/messages")
        #expect(provider.supportsToolCalling == false)
        #expect(provider.capabilities.supportsToolCalling == false)
        do {
            _ = try await provider.testConnection()
            Issue.record("OpenAI Provider 不应接管 Messages 协议")
        } catch let error as AIProviderError {
            #expect(error == .unsupportedEndpointProtocol("/v1/messages"))
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
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
        // 截断提示必须包含真实字节数（不依赖具体语言文案）。
        #expect(preview.contains("500"))
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

    @Test func parsesLegacyFunctionCallAndSynthesizesMissingID() throws {
        let response = try OpenAICompatibleProvider.parseCompletion(
            data: Data("""
            {"choices":[{"message":{"role":"assistant","content":null,
              "function_call":{"name":"playTrack","arguments":{"trackID":"srv:1"}}}}]}
            """.utf8),
            fallbackModel: "test-model"
        )
        #expect(response.toolCalls?.count == 1)
        #expect(response.toolCalls?.first?.id == "call-0")
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

    // MARK: - Chat 流式 tool_calls 分片拼装

    @Test func parsesToolCallFragmentWithIdNameAndEmptyArguments() {
        let fragments = OpenAICompatibleProvider.streamToolCallFragments(
            from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"playTrack","arguments":""}}]}}]}"#
        )
        #expect(fragments.count == 1)
        #expect(fragments[0].index == 0)
        #expect(fragments[0].id == "call_1")
        #expect(fragments[0].name == "playTrack")
        #expect(fragments[0].arguments == "")
    }

    /// arguments 分片：后续 chunk 只有 index + function.arguments，没有 id / name。
    @Test func parsesArgumentOnlyToolCallFragment() {
        let fragments = OpenAICompatibleProvider.streamToolCallFragments(
            from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"trackID\":\"srv"}}]}}]}"#
        )
        #expect(fragments.count == 1)
        #expect(fragments[0].index == 0)
        #expect(fragments[0].id == nil)
        #expect(fragments[0].name == nil)
        #expect(fragments[0].arguments == "{\"trackID\":\"srv")
    }

    @Test func parsesLegacyStreamingFunctionCallWithoutIndex() {
        let fragments = OpenAICompatibleProvider.streamToolCallFragments(
            from: #"{"choices":[{"delta":{"function_call":{"name":"searchTrack","arguments":"{\"q\":\"夜曲\"}"}}}]}"#
        )
        #expect(fragments.count == 1)
        #expect(fragments[0].index == 0)
        #expect(fragments[0].name == "searchTrack")
        #expect(fragments[0].arguments.contains("夜曲"))
    }

    /// 同一 index 的多个 fragment 跨 chunk 合并后拼成完整 tool call。
    @Test func mergesToolCallFragmentsAndAssembles() {
        var fragments: [Int: OpenAICompatibleProvider.ChatToolCallFragment] = [:]
        func merge(_ list: [OpenAICompatibleProvider.ChatToolCallFragment]) {
            for fragment in list {
                if var existing = fragments[fragment.index] {
                    if existing.id == nil { existing.id = fragment.id }
                    if existing.name == nil { existing.name = fragment.name }
                    existing.arguments += fragment.arguments
                    fragments[fragment.index] = existing
                } else {
                    fragments[fragment.index] = fragment
                }
            }
        }
        merge(OpenAICompatibleProvider.streamToolCallFragments(
            from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"searchTrack","arguments":""}}]}}]}"#
        ))
        merge(OpenAICompatibleProvider.streamToolCallFragments(
            from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":\""}}]}}]}"#
        ))
        merge(OpenAICompatibleProvider.streamToolCallFragments(
            from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"夜曲\"}"}}]}}]}"#
        ))

        let calls = OpenAICompatibleProvider.assembleToolCalls(from: fragments)
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_1")
        #expect(calls[0].name == "searchTrack")
        #expect(calls[0].arguments == "{\"q\":\"夜曲\"}")
    }

    /// 多个 tool call（不同 index）并行分片：各自独立拼装且按 index 升序返回。
    @Test func assemblesMultipleToolCallsInIndexOrder() {
        let fragments: [Int: OpenAICompatibleProvider.ChatToolCallFragment] = [
            1: .init(index: 1, id: "call_2", name: "playTrack", arguments: "{}"),
            0: .init(index: 0, id: "call_1", name: "searchTrack", arguments: "{\"q\":\"夜曲\"}"),
        ]
        let calls = OpenAICompatibleProvider.assembleToolCalls(from: fragments)
        #expect(calls.map(\.id) == ["call_1", "call_2"])
    }

    /// 缺 id 时合成稳定调用 ID；缺 name 仍不会产出无法执行的半成品调用。
    @Test func dropsFragmentsMissingIdentity() {
        let fragments: [Int: OpenAICompatibleProvider.ChatToolCallFragment] = [
            0: .init(index: 0, id: nil, name: "searchTrack", arguments: "{}"),
        ]
        let calls = OpenAICompatibleProvider.assembleToolCalls(from: fragments)
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call-0")
        #expect(calls.first?.name == "searchTrack")
    }

    @Test func ignoresChunksWithoutToolCalls() {
        #expect(OpenAICompatibleProvider.streamToolCallFragments(from: #"{"choices":[{"delta":{"content":"你好"}}]}"#).isEmpty)
        #expect(OpenAICompatibleProvider.streamToolCallFragments(from: #"{"choices":[{"message":{"content":"hi"}}]}"#).isEmpty)
        #expect(OpenAICompatibleProvider.streamToolCallFragments(from: "not json").isEmpty)
    }

    /// 流式 usage：Chat 网关在末尾 chunk 带 `usage`，Responses 挂在 `response.usage` 下。
    @Test func parsesStreamingUsage() {
        let chat = OpenAICompatibleProvider.streamUsage(
            from: #"{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7}}"#
        )
        #expect(chat?.input == 11)
        #expect(chat?.output == 7)

        let responses = OpenAICompatibleProvider.responsesUsage(
            from: #"{"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":9}}}"#
        )
        #expect(responses?.input == 3)
        #expect(responses?.output == 9)

        #expect(OpenAICompatibleProvider.streamUsage(from: #"{"choices":[{"delta":{"content":"x"}}]}"#) == nil)
        #expect(OpenAICompatibleProvider.responsesUsage(from: #"{"type":"response.output_text.delta","delta":"x"}"#) == nil)
    }

    // MARK: - AI Endpoint HTTP 安全策略（P2-8）

    @Test func endpointAllowsHTTPSPublic() throws {
        let provider = makeProvider(baseURL: "https://api.example.com")
        _ = try provider.endpoint()
    }

    @Test func endpointAllowsHTTPSWithPath() throws {
        let provider = makeProvider(baseURL: "https://example.com/api", apiPath: "v1/chat/completions")
        _ = try provider.endpoint()
    }

    @Test func endpointAllowsHTTPLoopback() throws {
        for base in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            let provider = makeProvider(baseURL: base)
            _ = try provider.endpoint()
        }
    }

    @Test func endpointAllowsHTTPPrivateLAN() throws {
        for base in ["http://192.168.1.10:11434", "http://10.0.0.5:11434", "http://172.16.0.4:11434", "http://172.31.255.1:11434"] {
            let provider = makeProvider(baseURL: base)
            _ = try provider.endpoint()
        }
    }

    @Test func endpointRejectsHTTPPublic() {
        let provider = makeProvider(baseURL: "http://public.example.com")
        #expect(throws: AIProviderError.insecureEndpoint) {
            try provider.endpoint()
        }
    }

    @Test func endpointRejectsPublicHostClassifier() {
        #expect(OpenAICompatibleProvider.isPrivateOrLoopbackHost("public.example.com") == false)
        #expect(OpenAICompatibleProvider.isPrivateOrLoopbackHost("8.8.8.8") == false)
        #expect(OpenAICompatibleProvider.isPrivateOrLoopbackHost("172.32.0.1") == false)
        #expect(OpenAICompatibleProvider.isPrivateOrLoopbackHost("192.169.0.1") == false)
    }

    @Test func endpointRejectsUnsupportedScheme() {
        let provider = makeProvider(baseURL: "ftp://example.com")
        #expect(throws: AIProviderError.invalidEndpoint) {
            try provider.endpoint()
        }
    }
}
