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

struct AnthropicMessagesProviderTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnthropicMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider() -> AnthropicMessagesProvider {
        AnthropicMessagesProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: "https://relay.example.com")!,
                apiPath: "/v1/messages",
                model: "claude-test",
                supportsToolCalling: true
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
}
