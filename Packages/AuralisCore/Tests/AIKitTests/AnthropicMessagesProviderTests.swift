@testable import AIKit
import Foundation
import SecurityKit
import Testing

private final class AnthropicMockURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var responseData = Data()
        var capturedRequests: [URLRequest] = []
    }

    private static let state = State()

    static func reset(data: Data) {
        state.lock.lock()
        state.responseData = data
        state.capturedRequests = []
        state.lock.unlock()
    }

    static var requests: [URLRequest] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        let data = Self.state.responseData
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(buffer, count: count)
            }
            captured.httpBodyStream = nil
            captured.httpBody = bytes
        }
        Self.state.capturedRequests.append(captured)
        Self.state.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// AnthropicMockURLProtocol 使用进程内静态状态；同 suite 内测试必须串行，
// 否则并行测试会互相覆盖 mock 响应。
@Suite(.serialized)
struct AnthropicMessagesProviderTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnthropicMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider(supportsReasoningControl: Bool = false) -> AnthropicMessagesProvider {
        AnthropicMessagesProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: "https://relay.example.com")!,
                apiPath: "/v1/messages",
                model: "claude-test",
                supportsToolCalling: true,
                supportsToolChoice: true,
                supportsReasoningControl: supportsReasoningControl
            ),
            credentialVault: KeychainCredentialVault(),
            session: makeSession()
        )
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func encodesMessagesSystemToolsAndParsesToolUse() async throws {
        let response = #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"我来搜索。"},{"type":"tool_use","id":"tool_1","name":"library_search","input":{"query":"夜曲"}}],"stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":8}}"#
        AnthropicMockURLProtocol.reset(data: Data(response.utf8))

        let tool = AIToolDefinition(
            name: "library_search",
            description: "搜索音乐库",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
        )
        let result = try await makeProvider().complete(AICompletionRequest(
            model: "claude-test",
            messages: [
                AIMessage(role: .system, content: "你是音乐助手"),
                AIMessage(role: .user, content: "搜夜曲"),
            ],
            maxTokens: 256,
            tools: [tool],
            toolChoice: .auto
        ))

        #expect(result.content == "我来搜索。")
        #expect(result.toolCalls?.count == 1)
        #expect(result.toolCalls?.first?.name == "library_search")
        #expect(result.toolCalls?.first?.arguments.contains("夜曲") == true)
        #expect(result.inputTokens == 12)
        #expect(result.outputTokens == 8)

        let request = try #require(AnthropicMockURLProtocol.requests.first)
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try requestObject(request)
        #expect(body["model"] as? String == "claude-test")
        #expect(body["max_tokens"] as? Int == 256)
        #expect(body["system"] as? String == "你是音乐助手")
        #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
        #expect((body["tools"] as? [[String: Any]])?.first?["name"] as? String == "library_search")
        #expect((body["tools"] as? [[String: Any]])?.first?["input_schema"] is [String: Any])
    }

    @Test("Anthropic 将并行 tool result 聚合为一个 user content block")
    func aggregatesParallelToolResults() throws {
        let messages = AnthropicMessagesProvider.encodeMessages(AITranscript(messages: [
            AIMessage(role: .user, content: "搜索两首歌"),
            AIMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    AIToolCall(id: "call-1", name: "searchTracks", arguments: #"{"q":"夜曲"}"#),
                    AIToolCall(id: "call-2", name: "searchTracks", arguments: #"{"q":"晴天"}"#),
                ]
            ),
            AIMessage(role: .tool, content: "夜曲结果", toolCallID: "call-1", name: "searchTracks"),
            AIMessage(role: .tool, content: "晴天结果", toolCallID: "call-2", name: "searchTracks"),
        ]))

        #expect(messages.count == 3)
        let toolMessage = try #require(messages.last)
        #expect(toolMessage["role"] as? String == "user")
        let blocks = try #require(toolMessage["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks.map { $0["type"] as? String } == ["tool_result", "tool_result"])
        #expect(blocks.map { $0["tool_use_id"] as? String } == ["call-1", "call-2"])
    }

    @Test("Anthropic 的 toolChoice.none 不发送 tools")
    func noneToolChoiceOmitsTools() async throws {
        AnthropicMockURLProtocol.reset(data: Data(#"{"id":"msg_none","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"完成"}],"stop_reason":"end_turn"}"#.utf8))

        _ = try await makeProvider().complete(AICompletionRequest(
            model: "claude-test",
            messages: [AIMessage(role: .user, content: "只回答文本")],
            maxTokens: 64,
            tools: [AIToolDefinition(name: "library_search", description: "搜索")],
            toolChoice: AIToolChoice.none
        ))

        let request = try #require(AnthropicMockURLProtocol.requests.first)
        let body = try requestObject(request)
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
    }

    @Test("Anthropic reasoning uses a viable thinking budget")
    func reasoningRequestUsesViableThinkingBudget() async throws {
        AnthropicMockURLProtocol.reset(data: Data(#"{"id":"msg_reasoning","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"完成"}],"stop_reason":"end_turn"}"#.utf8))

        _ = try await makeProvider(supportsReasoningControl: true).complete(AICompletionRequest(
            model: "claude-test",
            messages: [AIMessage(role: .user, content: "只回答文本")],
            maxTokens: 2_048,
            reasoning: AIReasoningConfiguration(mode: .enabled, effort: .low)
        ))

        let request = try #require(AnthropicMockURLProtocol.requests.first)
        let body = try requestObject(request)
        #expect(body["max_tokens"] as? Int == 2_048)
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 1_024)
    }

    /// 并行 tool_use 的 id 与 content_block.index 顺序不一致时，必须按 index
    /// 恢复原始顺序（index 0 = firstTool，index 1 = secondTool），不能按
    /// tool_use.id 字典序（tool-a < tool-z）交换顺序。
    @Test("K Anthropic 并行 tool call 按 content_block.index 恢复顺序")
    func parallelToolCallsPreserveIndexOrder() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-z","name":"firstTool"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-a","name":"secondTool"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}

        event: message_stop
        data: {"type":"message_stop"}
        """
        AnthropicMockURLProtocol.reset(data: Data(sse.utf8))

        let tool = AIToolDefinition(
            name: "firstTool",
            description: "第一个工具",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
        )
        var received: [AIToolCall] = []
        for try await event in makeProvider().stream(AICompletionRequest(
            model: "claude-test",
            messages: [AIMessage(role: .user, content: "并行调用")],
            maxTokens: 256,
            tools: [tool]
        )) {
            if case let .toolCall(call) = event {
                received.append(call)
            }
        }
        #expect(received.map(\.name) == ["firstTool", "secondTool"],
                "必须按 content_block.index 恢复顺序，实际：\(received.map(\.name))")
        #expect(received.map(\.id) == ["tool-z", "tool-a"])
    }
}
