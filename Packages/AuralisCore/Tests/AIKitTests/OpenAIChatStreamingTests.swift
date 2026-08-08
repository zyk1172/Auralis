@testable import AIKit
import Foundation
import SecurityKit
import Testing

/// Chat Completions 流式端到端测试。
///
/// 使用**本文件私有**的 `ChatMockURLProtocol`（独立状态），避免与
/// OpenAIResponsesProviderTests 里共享的 `AIKitMockURLProtocol` 全局状态
/// 在并行测试时互相消费 stub。
@Suite("OpenAI Chat streaming network tests", .serialized)
struct OpenAIChatStreamingTests {
    /// 私有 Mock URLProtocol：与 Responses 测试的全局 Mock 互不干扰。
    private final class ChatMockURLProtocol: URLProtocol, @unchecked Sendable {
        struct Stub: Sendable {
            let statusCode: Int
            let headers: [String: String]
            let data: Data

            static func response(
                statusCode: Int = 200,
                headers: [String: String] = ["Content-Type": "application/json"],
                data: Data
            ) -> Stub {
                Stub(statusCode: statusCode, headers: headers, data: data)
            }
        }

        private static let state = State()

        private final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var stubs: [Stub] = []

            func reset(stubs: [Stub]) {
                lock.lock()
                self.stubs = stubs
                lock.unlock()
            }

            func next() -> Stub? {
                lock.lock()
                defer { lock.unlock() }
                guard !stubs.isEmpty else { return nil }
                return stubs.removeFirst()
            }
        }

        static func reset(stubs: [Stub]) {
            state.reset(stubs: stubs)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let stub = Self.state.next() else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: "http://localhost:11434")!,
                apiPath: "/v1/chat/completions",
                model: "test-model",
                supportsToolCalling: true
            ),
            credentialVault: KeychainCredentialVault(),
            session: makeMockSession()
        )
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// 分片 tool_calls 在流结束（[DONE]）时被拼成完整 `.toolCall`，且先于 `.completed` 产出。
    @Test func streamsChatToolCallsAcrossFragments() async throws {
        let sse = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"我"}}]}

        data: {"choices":[{"delta":{"content":"来"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"searchTrack","arguments":""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\":\\""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"夜曲\\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]
        """
        ChatMockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], data: Data(sse.utf8))
        ])
        let provider = makeProvider()

        var events: [AIStreamEvent] = []
        for try await event in provider.stream(
            AICompletionRequest(model: "test-model", messages: [AIMessage(role: .user, content: "搜歌")])
        ) {
            events.append(event)
        }

        #expect(events.first == .started(model: "test-model"))
        #expect(events.contains(.delta("我")))
        #expect(events.contains(.delta("来")))
        let expectedCall = AIToolCall(id: "call_1", name: "searchTrack", arguments: "{\"q\":\"夜曲\"}")
        #expect(events.contains(.toolCall(expectedCall)))
        // toolCall 必须在 completed 之前产出。
        if let callIndex = events.firstIndex(where: { if case .toolCall = $0 { return true } else { return false } }),
           let doneIndex = events.lastIndex(of: .completed) {
            #expect(callIndex < doneIndex)
        } else {
            Issue.record("缺少 .toolCall 或 .completed 事件")
        }
        #expect(events.last == .completed)
    }

    /// 网关不发 [DONE] 也视为正常结束，并把已收集的 tool calls 补发。
    @Test func streamsToolCallsWithoutTerminalEvent() async throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","type":"function","function":{"name":"playTrack","arguments":"{\\"trackID\\":\\"srv:1\\"}"}}]}}]}

        data: {"choices":[{"delta":{"content":"收"}}]}
        """
        ChatMockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], data: Data(sse.utf8))
        ])
        let provider = makeProvider()

        var events: [AIStreamEvent] = []
        for try await event in provider.stream(
            AICompletionRequest(model: "test-model", messages: [AIMessage(role: .user, content: "hi")])
        ) {
            events.append(event)
        }

        #expect(events.contains(.delta("收")))
        #expect(events.contains(.toolCall(AIToolCall(id: "call_2", name: "playTrack", arguments: "{\"trackID\":\"srv:1\"}"))))
        #expect(events.last == .completed)
    }

    /// 纯文本流：只有 delta + completed，不产出任何 toolCall。
    @Test func streamsPlainTextWithoutToolCalls() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2}}

        data: [DONE]
        """
        ChatMockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], data: Data(sse.utf8))
        ])
        let provider = makeProvider()

        var events: [AIStreamEvent] = []
        for try await event in provider.stream(
            AICompletionRequest(model: "test-model", messages: [AIMessage(role: .user, content: "hi")])
        ) {
            events.append(event)
        }

        #expect(events.contains(.delta("你")))
        #expect(events.contains(.delta("好")))
        #expect(events.contains { if case .toolCall = $0 { return true } else { return false } } == false)
        #expect(events.contains(.usage(input: 5, output: 2)))
        #expect(events.last == .completed)
    }
}
