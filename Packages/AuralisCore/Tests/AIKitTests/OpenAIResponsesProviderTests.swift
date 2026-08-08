@testable import AIKit
import Foundation
import SecurityKit
import Testing

// MARK: - Mock URLProtocol（Responses 网络测试共用）

final class AIKitMockURLProtocol: URLProtocol, @unchecked Sendable {
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
        private var capturedRequests: [URLRequest] = []

        func reset(stubs: [Stub]) {
            lock.lock()
            self.stubs = stubs
            capturedRequests = []
            lock.unlock()
        }

        func next(for request: URLRequest) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            capturedRequests.append(materialized(request))
            guard !stubs.isEmpty else { return nil }
            return stubs.removeFirst()
        }

        /// URLSession 会把 `httpBody` 转成 `httpBodyStream` 再交给 URLProtocol；
        /// 捕获时把流读回成 `httpBody`，便于断言请求体内容。
        private func materialized(_ request: URLRequest) -> URLRequest {
            guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
            stream.open()
            defer { stream.close() }

            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(buffer, count: count)
            }
            var copy = request
            copy.httpBodyStream = nil
            copy.httpBody = bytes
            return copy
        }

        func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }
    }

    static func reset(stubs: [Stub]) {
        state.reset(stubs: stubs)
    }

    static var requests: [URLRequest] {
        state.requests()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.state.next(for: request) else {
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

private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIKitMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - 纯解析 / 编码 / 端点判定

struct OpenAIResponsesProviderTests {
    private func makeProvider(baseURL: String, apiPath: String = "/v1/responses") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: baseURL)!,
                apiPath: apiPath,
                model: "test-model",
                supportsToolCalling: true
            ),
            credentialVault: KeychainCredentialVault()
        )
    }

    private func parse(_ json: String, model: String = "test-model") throws -> AICompletionResponse {
        try OpenAICompatibleProvider.parseResponsesCompletion(data: Data(json.utf8), fallbackModel: model)
    }

    // MARK: 端点选择

    @Test func detectsResponsesAPIFromAPIPath() {
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/v1/responses") == true)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/responses") == true)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/api/v1/responses") == true)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "v1/responses") == true)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/v1/responses/") == true)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/v1/chat/completions") == false)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/v1/completions") == false)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "") == false)
        #expect(OpenAICompatibleProvider.usesResponsesAPI(apiPath: "/responses/extra") == false)
    }

    @Test func endpointUsesResponsesPath() throws {
        let provider = makeProvider(baseURL: "https://api.openai.com/")
        #expect(try provider.endpoint().absoluteString == "https://api.openai.com/v1/responses")
    }

    // MARK: input 编码

    @Test func encodesSystemMessageAsInputText() throws {
        let items = OpenAICompatibleProvider.encodeResponsesInputItems(AIMessage(role: .system, content: "你是音乐助手"))
        #expect(items.count == 1)
        let encoded = items[0]
        #expect(encoded["type"] as? String == "message")
        #expect(encoded["role"] as? String == "system")
        let content = try #require(encoded["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "你是音乐助手")
    }

    @Test func encodesUserMessageAsInputText() throws {
        let items = OpenAICompatibleProvider.encodeResponsesInputItems(AIMessage(role: .user, content: "搜夜曲"))
        #expect(items.count == 1)
        let encoded = items[0]
        #expect(encoded["role"] as? String == "user")
        let content = try #require(encoded["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "搜夜曲")
    }

    @Test func encodesAssistantMessageWithToolCalls() throws {
        let assistant = AIMessage(
            role: .assistant,
            content: "我来查",
            toolCalls: [AIToolCall(id: "call_1", name: "searchTrack", arguments: "{\"q\":\"夜曲\"}")]
        )
        // 有文本 → message 条目 + 顶层 function_call 条目（不嵌进 content）。
        let items = OpenAICompatibleProvider.encodeResponsesInputItems(assistant)
        #expect(items.count == 2)
        let message = items[0]
        #expect(message["type"] as? String == "message")
        #expect(message["role"] as? String == "assistant")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "output_text")
        #expect(content[0]["text"] as? String == "我来查")
        let call = items[1]
        #expect(call["type"] as? String == "function_call")
        #expect(call["call_id"] as? String == "call_1")
        #expect(call["name"] as? String == "searchTrack")
        #expect(call["arguments"] as? String == "{\"q\":\"夜曲\"}")
    }

    @Test func encodesAssistantWithOnlyToolCallsSkipsEmptyText() throws {
        let assistant = AIMessage(
            role: .assistant,
            content: "",
            toolCalls: [AIToolCall(id: "call_2", name: "playTrack", arguments: "{}")]
        )
        // 无文本 → 只产出顶层 function_call 条目（多轮工具调用合法的结构）。
        let items = OpenAICompatibleProvider.encodeResponsesInputItems(assistant)
        #expect(items.count == 1)
        #expect(items[0]["type"] as? String == "function_call")
        #expect(items[0]["name"] as? String == "playTrack")
        #expect(items[0]["call_id"] as? String == "call_2")
    }

    @Test func encodesToolResultAsFunctionCallOutput() throws {
        let tool = AIMessage(role: .tool, content: "找到 3 首", toolCallID: "call_1", name: "searchTrack")
        let items = OpenAICompatibleProvider.encodeResponsesInputItems(tool)
        #expect(items.count == 1)
        let encoded = items[0]
        #expect(encoded["type"] as? String == "function_call_output")
        #expect(encoded["call_id"] as? String == "call_1")
        #expect(encoded["output"] as? String == "找到 3 首")
    }

    // MARK: 非流式响应解析

    @Test func parsesResponsesMessageTextAndTokens() throws {
        let response = try parse("""
        {"id":"resp_1","object":"response","model":"gpt-4.1","status":"completed",
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"你好"}]}],
         "usage":{"input_tokens":11,"output_tokens":4}}
        """)
        #expect(response.content == "你好")
        #expect(response.model == "gpt-4.1")
        #expect(response.inputTokens == 11)
        #expect(response.outputTokens == 4)
        #expect(response.finishReason == "stop")
        #expect(response.toolCalls == nil)
    }

    /// 文本与 function_call 混合输出：文本照常拼接，工具调用单独落到 toolCalls。
    @Test func parsesResponsesMixedMessageAndFunctionCall() throws {
        let response = try parse("""
        {"id":"resp_2","object":"response","model":"gpt-4.1","status":"completed",
         "output":[
           {"type":"message","role":"assistant","content":[{"type":"output_text","text":"正在搜索"}]},
           {"type":"function_call","call_id":"call_abc","name":"searchTrack","arguments":"{\\"q\\":\\"夜曲\\"}"}
         ],
         "usage":{"input_tokens":20,"output_tokens":8}}
        """)
        #expect(response.content == "正在搜索")
        #expect(response.finishReason == "stop")
        #expect(response.toolCalls?.count == 1)
        #expect(response.toolCalls?.first?.id == "call_abc")
        #expect(response.toolCalls?.first?.name == "searchTrack")
        #expect(response.toolCalls?.first?.arguments.contains("夜曲") == true)
    }

    @Test func mapsResponsesIncompleteMaxTokensToLength() throws {
        let response = try parse("""
        {"object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"截断"}]}]}
        """)
        #expect(response.finishReason == "length")
    }

    @Test func mapsResponsesFailedAndCancelledStatuses() throws {
        let failed = try parse("""
        {"object":"response","status":"failed",
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"失败"}]}]}
        """)
        #expect(failed.finishReason == "fail")

        let cancelled = try parse("""
        {"object":"response","status":"cancelled",
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"取消"}]}]}
        """)
        #expect(cancelled.finishReason == "cancelled")
    }

    /// 网关透传 finish_reason 时优先使用。
    @Test func prefersDirectFinishReason() throws {
        let response = try parse("""
        {"object":"response","status":"completed","finish_reason":"tool_calls",
         "output":[{"type":"function_call","call_id":"c1","name":"playTrack","arguments":"{}"}]}
        """)
        #expect(response.finishReason == "tool_calls")
        #expect(response.toolCalls?.count == 1)
    }

    /// reasoning 条目不得混入用户可见 content（与 Chat 版 reasoning_content 语义一致）。
    @Test func responsesReasoningIsKeptOutOfUserVisibleContent() throws {
        let response = try parse("""
        {"object":"response","status":"completed",
         "output":[
           {"type":"reasoning","summary":[{"type":"summary_text","text":"内部思考"}]},
           {"type":"message","role":"assistant","content":[{"type":"output_text","text":"最终回答"}]}
         ]}
        """)
        #expect(response.content == "最终回答")
        #expect(response.reasoning?.contains("内部思考") == true)
    }

    @Test func responsesEmptyBodyIsRetryableMalformed() {
        do {
            _ = try OpenAICompatibleProvider.parseResponsesCompletion(data: Data(), fallbackModel: "m")
            Issue.record("空响应体应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == true)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test func responsesEmbeddedErrorObjectIsNotRetryable() {
        do {
            _ = try parse(#"{"error":{"message":"model not found","type":"invalid_request_error"}}"#)
            Issue.record("内嵌 error 对象应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == false)
            #expect(error.errorDescription?.contains("model not found") == true)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test func responsesIncompatibleJSONIsNotRetryable() {
        do {
            _ = try parse(#"{"result":"ok","data":[1,2,3]}"#)
            Issue.record("不兼容结构应当抛错")
        } catch let error as AIProviderError {
            #expect(error.isTransient == false)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    /// 非流式请求却收到 Responses SSE 时，把 delta 拼回完整文本而不是判死。
    @Test func responsesSSEOnNonStreamRequestIsAggregated() throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"你"}

        data: {"type":"response.output_text.delta","delta":"好"}

        data: {"type":"response.completed","response":{"model":"gpt-4.1","usage":{"input_tokens":5,"output_tokens":3}}}
        """
        let response = try parse(sse)
        #expect(response.content == "你好")
        #expect(response.model == "gpt-4.1")
        #expect(response.inputTokens == 5)
        #expect(response.outputTokens == 3)
    }

    // MARK: 流式事件解析

    @Test func parsesOutputTextDeltaEvents() {
        let result = OpenAICompatibleProvider.parseResponsesStreamEvent(
            #"{"type":"response.output_text.delta","item_id":"i1","output_index":0,"content_index":0,"delta":"你好"}"#
        )
        #expect(result == .text("你好"))
    }

    @Test func parsesOutputItemDoneFunctionCall() {
        let result = OpenAICompatibleProvider.parseResponsesStreamEvent(
            #"{"type":"response.output_item.done","output":{"type":"function_call","call_id":"call_x","name":"playTrack","arguments":"{\"trackID\":\"srv:1\"}"}}"#
        )
        guard case let .toolCall(call) = result else {
            Issue.record("应当解析为 toolCall：\(result)")
            return
        }
        #expect(call.id == "call_x")
        #expect(call.name == "playTrack")
        #expect(call.arguments.contains("srv:1"))
    }

    @Test func parsesCompletedFailedAndErrorEvents() {
        #expect(OpenAICompatibleProvider.parseResponsesStreamEvent(#"{"type":"response.completed"}"#) == .done)
        #expect(OpenAICompatibleProvider.parseResponsesStreamEvent(#"{"type":"response.incomplete"}"#) == .done)

        let failed = OpenAICompatibleProvider.parseResponsesStreamEvent(
            #"{"type":"response.failed","response":{"error":{"message":"上游超时"}}}"#
        )
        guard case let .failed(message) = failed else {
            Issue.record("response.failed 应当解析为 failed：\(failed)")
            return
        }
        #expect(message.contains("上游超时"))

        let errorEvent = OpenAICompatibleProvider.parseResponsesStreamEvent(
            #"{"type":"error","error":{"message":"bad request"}}"#
        )
        guard case let .failed(errorMessage) = errorEvent else {
            Issue.record("error 事件应当解析为 failed：\(errorEvent)")
            return
        }
        #expect(errorMessage.contains("bad request"))
    }

    @Test func ignoresNonTextResponsesEvents() {
        let created = OpenAICompatibleProvider.parseResponsesStreamEvent(
            #"{"type":"response.created","response":{"id":"resp_1"}}"#
        )
        #expect(created == .ignore)

        let outputTextDone = OpenAICompatibleProvider.parseResponsesStreamEvent(
            #"{"type":"response.output_text.done","text":"你好"}"#
        )
        #expect(outputTextDone == .ignore)
    }

    /// 无 type 字段但带 delta 的网关偏差也兜住。
    @Test func toleratesTypelessDeltaEvent() {
        let result = OpenAICompatibleProvider.parseResponsesStreamEvent(#"{"delta":"容错"}"#)
        #expect(result == .text("容错"))
    }
}

// MARK: - 端到端网络测试（共享 Mock，串行执行）

@Suite("OpenAI Responses network tests", .serialized)
struct OpenAIResponsesNetworkTests {
    private func makeProvider(session: URLSession, apiPath: String = "/v1/responses") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
                name: "test",
                baseURL: URL(string: "https://api.openai.com")!,
                apiPath: apiPath,
                model: "test-model",
                supportsToolCalling: true
            ),
            credentialVault: KeychainCredentialVault(),
            session: session
        )
    }

    private func requestObject(from request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// 完整对话（system/user/assistant+toolCalls/tool/user）编码为 Responses input，
    /// 请求体使用 max_output_tokens 且不带 messages/max_tokens。
    @Test func responsesRequestBodyEncodesToolConversation() async throws {
        let stubBody = """
        {"id":"resp_1","object":"response","model":"gpt-4.1","status":"completed",
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}]}]}
        """
        AIKitMockURLProtocol.reset(stubs: [.response(data: Data(stubBody.utf8))])
        let provider = makeProvider(session: makeMockSession())

        let messages = [
            AIMessage(role: .system, content: "你是音乐助手"),
            AIMessage(role: .user, content: "搜夜曲"),
            AIMessage(role: .assistant, content: "", toolCalls: [AIToolCall(id: "call_1", name: "searchTrack", arguments: "{\"q\":\"夜曲\"}")]),
            AIMessage(role: .tool, content: "找到 1 首", toolCallID: "call_1", name: "searchTrack"),
            AIMessage(role: .user, content: "播放第一首"),
        ]
        let tools = [AIToolDefinition(
            name: "searchTrack",
            description: "搜索曲目",
            parametersJSON: #"{"type":"object","properties":{"q":{"type":"string"}}}"#
        )]
        _ = try await provider.complete(
            AICompletionRequest(model: "gpt-4.1", messages: messages, maxTokens: 1_024, tools: tools)
        )

        let object = try requestObject(from: try #require(AIKitMockURLProtocol.requests.first))
        #expect(object["model"] as? String == "gpt-4.1")
        #expect(object["max_output_tokens"] as? Int == 1_024)
        #expect(object["max_tokens"] == nil)
        #expect(object["messages"] == nil)
        #expect(object["stream"] == nil)

        // 多轮工具调用：assistant 的 function_call 必须是顶层条目（不在 content 里）。
        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input.count == 5)
        #expect(input[0]["role"] as? String == "system")
        #expect((input[0]["content"] as? [[String: Any]])?.first?["type"] as? String == "input_text")
        #expect(input[1]["role"] as? String == "user")
        #expect(input[2]["type"] as? String == "function_call")
        #expect(input[2]["call_id"] as? String == "call_1")
        #expect(input[2]["name"] as? String == "searchTrack")
        #expect(input[2]["arguments"] as? String == "{\"q\":\"夜曲\"}")
        #expect(input[3]["type"] as? String == "function_call_output")
        #expect(input[3]["call_id"] as? String == "call_1")
        #expect(input[3]["output"] as? String == "找到 1 首")
        #expect(input[4]["role"] as? String == "user")

        // Responses API 工具字段平铺在顶层（无嵌套 "function" 键），
        // 与 Chat Completions 的形状不同——这是「Responses 调不动工具」的回归锚点。
        let toolsBody = try #require(object["tools"] as? [[String: Any]])
        #expect(toolsBody.count == 1)
        #expect(toolsBody[0]["type"] as? String == "function")
        #expect(toolsBody[0]["name"] as? String == "searchTrack")
        #expect(toolsBody[0]["description"] as? String == "搜索曲目")
        #expect(toolsBody[0]["parameters"] is [String: Any])
        #expect(toolsBody[0]["function"] == nil)
    }

    @Test func completesWithResponsesNonStream() async throws {
        let stubBody = """
        {"id":"resp_1","object":"response","model":"gpt-4.1","status":"completed",
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"收到"}]}],
         "usage":{"input_tokens":7,"output_tokens":2}}
        """
        AIKitMockURLProtocol.reset(stubs: [.response(data: Data(stubBody.utf8))])
        let provider = makeProvider(session: makeMockSession())

        let response = try await provider.complete(
            AICompletionRequest(model: "gpt-4.1", messages: [AIMessage(role: .user, content: "hi")])
        )
        #expect(response.content == "收到")
        #expect(response.model == "gpt-4.1")
        #expect(response.inputTokens == 7)
        #expect(response.outputTokens == 2)

        let object = try requestObject(from: try #require(AIKitMockURLProtocol.requests.first))
        #expect(object["max_output_tokens"] as? Int == 8_192)
        #expect(object["max_tokens"] == nil)
    }

    /// testConnection 跟随端点判定：Responses 路径发 max_output_tokens=32 的小请求。
    @Test func testConnectionFollowsResponsesEndpoint() async throws {
        let stubBody = """
        {"id":"resp_1","object":"response","model":"gpt-4.1","status":"completed",
         "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"连接正常"}]}],
         "usage":{"input_tokens":5,"output_tokens":3}}
        """
        AIKitMockURLProtocol.reset(stubs: [.response(data: Data(stubBody.utf8))])
        let provider = makeProvider(session: makeMockSession())

        let result = try await provider.testConnection()
        #expect(result.message.contains("连接正常"))
        #expect(result.model == "gpt-4.1")

        let object = try requestObject(from: try #require(AIKitMockURLProtocol.requests.first))
        #expect(object["max_output_tokens"] as? Int == 32)
        #expect(object["input"] != nil)
        #expect(object["messages"] == nil)
    }

    /// Chat 路径回归：apiPath 为 chat/completions 时仍用旧格式，不受 Responses 改动影响。
    @Test func chatPathStillUsesChatRequestBody() async throws {
        let stubBody = """
        {"model":"gpt-4.1","choices":[{"message":{"role":"assistant","content":"好"}}],
         "usage":{"prompt_tokens":3,"completion_tokens":1}}
        """
        AIKitMockURLProtocol.reset(stubs: [.response(data: Data(stubBody.utf8))])
        let provider = makeProvider(session: makeMockSession(), apiPath: "/v1/chat/completions")

        let response = try await provider.complete(
            AICompletionRequest(model: "gpt-4.1", messages: [AIMessage(role: .user, content: "hi")])
        )
        #expect(response.content == "好")

        let object = try requestObject(from: try #require(AIKitMockURLProtocol.requests.first))
        #expect(object["max_tokens"] as? Int == 8_192)
        #expect(object["max_output_tokens"] == nil)
        #expect(object["input"] == nil)
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
    }

    /// 流式 SSE 事件序列：output_text.delta → output_item.done(function_call) → completed。
    @Test func streamsResponsesSSESequence() async throws {
        let sse = """
        data: {"type":"response.created","response":{"id":"resp_1"}}

        data: {"type":"response.output_text.delta","delta":"你"}

        data: {"type":"response.output_text.delta","delta":"好"}

        data: {"type":"response.output_item.done","output":{"type":"function_call","call_id":"call_1","name":"searchTrack","arguments":"{\\"q\\":\\"夜曲\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_1"}}

        data: [DONE]
        """
        AIKitMockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], data: Data(sse.utf8))
        ])
        let provider = makeProvider(session: makeMockSession())

        var events: [AIStreamEvent] = []
        for try await event in provider.stream(
            AICompletionRequest(model: "test-model", messages: [AIMessage(role: .user, content: "搜歌")])
        ) {
            events.append(event)
        }

        #expect(events.first == .started(model: "test-model"))
        #expect(events.contains(.delta("你")))
        #expect(events.contains(.delta("好")))
        #expect(events.contains(.toolCall(AIToolCall(id: "call_1", name: "searchTrack", arguments: "{\"q\":\"夜曲\"}"))))
        #expect(events.last == .completed)
    }

    /// 网关不发 [DONE] / response.completed 也视为正常结束（沿用 Chat 路径行为）。
    @Test func streamsEndingWithoutTerminalEventStillCompletes() async throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"收"}

        data: {"type":"response.output_text.delta","delta":"到"}
        """
        AIKitMockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], data: Data(sse.utf8))
        ])
        let provider = makeProvider(session: makeMockSession())

        var events: [AIStreamEvent] = []
        for try await event in provider.stream(
            AICompletionRequest(model: "test-model", messages: [AIMessage(role: .user, content: "hi")])
        ) {
            events.append(event)
        }
        #expect(events.contains(.delta("收")))
        #expect(events.contains(.delta("到")))
        #expect(events.last == .completed)
    }

    @Test func streamsFailedEventThrowsMalformed() async {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"你"}

        data: {"type":"response.failed","response":{"error":{"message":"上游超时"}}}

        data: [DONE]
        """
        AIKitMockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], data: Data(sse.utf8))
        ])
        let provider = makeProvider(session: makeMockSession())

        do {
            var events: [AIStreamEvent] = []
            for try await event in provider.stream(
                AICompletionRequest(model: "test-model", messages: [AIMessage(role: .user, content: "hi")])
            ) {
                events.append(event)
            }
            Issue.record("response.failed 应当让流上抛错误")
        } catch let error as AIProviderError {
            #expect(error.isTransient == false)
            #expect(error.errorDescription?.contains("上游超时") == true)
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }
}
