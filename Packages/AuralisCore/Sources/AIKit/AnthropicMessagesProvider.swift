// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SecurityKit

/// Anthropic Messages API Provider。
///
/// 与 OpenAI Chat Completions 的消息/工具结构不同，不能通过改一个 endpoint
/// 字符串复用 OpenAI 编码：system 是顶层字段，tool_use/tool_result 是 content
/// blocks，工具 schema 使用 input_schema。本实现保持 AIProvider 的统一接口，
/// 让 AgentRunner 可以继续使用同一套原生工具 → 结果回灌状态机。
public struct AnthropicMessagesProvider: AIProvider {
    private let configuration: AIProviderConfiguration
    private let credentialVault: any CredentialVault
    private let session: URLSession

    public init(
        configuration: AIProviderConfiguration,
        credentialVault: any CredentialVault,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentialVault = credentialVault
        self.session = session
    }

    public var supportsToolCalling: Bool { configuration.supportsToolCalling }

    public var capabilities: ModelCapabilities {
        ModelCapabilities(
            maxContextTokens: configuration.maxContextTokens,
            hasKnownContextWindow: configuration.hasKnownContextWindow,
            maxOutputTokens: configuration.maxOutputTokens,
            supportsToolCalling: supportsToolCalling,
            supportsParallelTools: configuration.supportsParallelTools,
            supportsToolChoice: configuration.supportsToolChoice,
            supportsStrictSchema: false,
            supportsStreaming: configuration.usesStreaming,
            supportsJSONMode: false,
            supportsJSONSchema: configuration.supportsJSONSchema,
            // The stored flags predate a real server-tool codec. Keep them
            // out of advertised capabilities until the Anthropic server-tool
            // continuation blocks (including pause_turn) are represented by
            // the neutral transcript model.
            supportsHostedWebSearch: false,
            supportsHostedWebFetch: false,
            supportsReasoningMetadata: configuration.supportsReasoningMetadata,
            supportsReasoningControl: configuration.supportsReasoningControl,
            toolMode: supportsToolCalling ? .anthropicMessages : AIProviderToolMode.none
        )
    }

    public func testConnection() async throws -> AIConnectionResult {
        let started = Date()
        let response = try await complete(AICompletionRequest(
            model: configuration.model,
            messages: [AIMessage(role: .user, content: String(localized: "用一句话确认连接正常。", bundle: .module))],
            temperature: 0,
            maxTokens: 32
        ))
        var details: [String] = [String(localized: "Anthropic Messages 未定义通用 /models 目录，模型可用性由实际请求验证。", bundle: .module)]
        let streaming = await probeStreaming()
        details.append(contentsOf: streaming.details)
        let tools = await probeNativeTools()
        details.append(contentsOf: tools.details)
        let reasoning = await probeReasoning()
        details.append(contentsOf: reasoning.details)
        return AIConnectionResult(
            latency: Date().timeIntervalSince(started),
            model: response.model,
            message: response.content,
            diagnostics: .init(
                modelCatalog: .unavailable,
                modelAvailability: .unavailable,
                textCompletion: .passed,
                streaming: streaming.status,
                nativeTools: tools.native,
                toolChoice: tools.toolChoice,
                reasoning: reasoning.status,
                details: details
            )
        )
    }

    private func probeReasoning() async -> (status: AIProbeStatus, details: [String]) {
        guard configuration.supportsReasoningControl else { return (.notTested, []) }
        do {
            _ = try await complete(AICompletionRequest(
                model: configuration.model,
                messages: [AIMessage(role: .user, content: "只回答 OK。")],
                temperature: 0,
                maxTokens: 2_048,
                reasoning: AIReasoningConfiguration(enabled: true, effort: .low)
            ))
            return (.passed, ["thinking 参数已被端点接受；是否返回思考元数据不作为能力判定。"])
        } catch let error as AIProviderError where error.explicitlyRejectsReasoning {
            return (.failed, ["服务端明确拒绝 thinking 参数：\(error.localizedDescription)"])
        } catch {
            return (.degraded, ["thinking 探测未完成：\(error.localizedDescription)；不会据此永久关闭 reasoning。"])
        }
    }

    private func probeStreaming() async -> (status: AIProbeStatus, details: [String]) {
        do {
            var completed = false
            for try await event in stream(AICompletionRequest(
                model: configuration.model,
                messages: [AIMessage(role: .user, content: String(localized: "只回复 OK。", bundle: .module))],
                temperature: 0,
                maxTokens: 8
            )) {
                if case .completed = event { completed = true }
            }
            return completed
                ? (.passed, [])
                : (.degraded, [String(localized: "流式请求没有完成事件；这是瞬时健康观测，不会关闭生产流式协议。", bundle: .module)])
        } catch {
            return (.degraded, [String(localized: "流式输出失败：\(error.localizedDescription)。这是瞬时健康观测，不会关闭生产流式协议。", bundle: .module)])
        }
    }

    private func probeNativeTools() async -> (native: AIProbeStatus, toolChoice: AIProbeStatus, details: [String]) {
        let name = "capabilities_get"
        let tool = AIToolDefinition(
            name: name,
            description: "Return the available Auralis capabilities. Call this read-only function with an empty object.",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
        )
        do {
            let roundTrip = try await observeToolRoundTrip(with: self, tool: tool, toolChoice: nil)
            switch roundTrip {
            case .noToolCallObserved:
                return (.unavailable, .notTested, [String(localized: "原生工具探测未收到工具调用；这不代表模型不支持工具。", bundle: .module)])
            case .roundTripUnanswered:
                // 第一阶段成功但回灌工具结果后没有第二轮回答：只观察到一半
                // round-trip，不能判 passed，也不能据此关闭能力。
                return (.degraded, .notTested, [String(localized: "原生工具探测第一阶段收到工具调用，但回灌模拟工具结果后未收到第二轮回答；这是瞬时观测，不会据此关闭原生工具。", bundle: .module)])
            case .roundTripCompleted:
                let choice = await probeToolChoice(with: tool)
                return (.passed, choice.status, choice.details)
            }
        } catch let error as AIProviderError {
            if error.indicatesToolProtocolFailure {
                return (.failed, .notTested, [String(localized: "工具结果回灌被服务端拒绝（tool_call_id 配对协议失败）：\(error.localizedDescription)", bundle: .module)])
            }
            if error.explicitlyRejectsNativeTools {
                return (.failed, .notTested, [String(localized: "服务端明确拒绝原生工具：\(error.localizedDescription)", bundle: .module)])
            }
            return (.unavailable, .notTested, [String(localized: "原生工具探测未完成：\(error.localizedDescription)", bundle: .module)])
        } catch {
            return (.unavailable, .notTested, [String(localized: "原生工具探测未完成：\(error.localizedDescription)", bundle: .module)])
        }
    }

    /// 原生工具探测的两个阶段。
    private enum ToolRoundTripOutcome {
        /// 第一阶段：未观察到工具调用。
        case noToolCallObserved
        /// 第二阶段：回灌模拟工具结果后，模型没有给出第二轮回答。
        case roundTripUnanswered
        /// 完整 round-trip：调用被观察且第二轮回答到达。
        case roundTripCompleted
    }

    /// 完整 round-trip 探测：观察到工具调用后，把模拟工具结果按同一
    /// tool_call_id 回灌，要求模型给出第二轮回答。只看第一个调用就判
    /// passed 会把「会调用但不会续接」的端点误判为原生工具可用。
    private func observeToolRoundTrip(
        with provider: AnthropicMessagesProvider,
        tool: AIToolDefinition,
        toolChoice: AIToolChoice?
    ) async throws -> ToolRoundTripOutcome {
        let prompt = "Use capabilities_get to inspect the available Auralis capabilities."
        var observedCall: AIToolCall?
        for try await event in provider.stream(AICompletionRequest(
            model: configuration.model,
            messages: [AIMessage(role: .user, content: prompt)],
            temperature: 0,
            maxTokens: configuration.maxOutputTokens,
            tools: [tool],
            toolChoice: toolChoice
        )) {
            if case let .toolCall(call) = event, call.name == tool.name {
                observedCall = call
                break
            }
        }
        guard let call = observedCall else { return .noToolCallObserved }

        // 第二阶段：assistant(tool_use) + tool_result 严格按同一 id 配对回灌。
        var answered = false
        for try await event in provider.stream(AICompletionRequest(
            model: configuration.model,
            messages: [
                AIMessage(role: .user, content: prompt),
                AIMessage(role: .assistant, content: "", toolCalls: [call]),
                AIMessage(
                    role: .tool,
                    content: #"{"ok":true,"capabilities":["library_search","playback_control"]}"#,
                    toolCallID: call.id,
                    name: call.name
                ),
            ],
            temperature: 0,
            maxTokens: min(configuration.maxOutputTokens, 256),
            tools: [tool],
            toolChoice: nil
        )) {
            switch event {
            case let .answerDelta(text) where !text.isEmpty,
                 let .unknownDelta(text) where !text.isEmpty:
                answered = true
            case .toolCall:
                // 第二轮继续调用工具同样证明续接链路完整。
                answered = true
            default:
                break
            }
            if answered { break }
        }
        return answered ? .roundTripCompleted : .roundTripUnanswered
    }

    private func probeToolChoice(with tool: AIToolDefinition) async -> (status: AIProbeStatus, details: [String]) {
        var probeConfiguration = configuration
        probeConfiguration.supportsToolChoice = true
        let probeProvider = AnthropicMessagesProvider(
            configuration: probeConfiguration,
            credentialVault: credentialVault,
            session: session
        )
        do {
            let observed = try await observesToolCall(with: probeProvider, tool: tool, toolChoice: .required)
            return observed
                ? (.passed, [])
                : (.unavailable, [String(localized: "tool_choice 探测未收到工具调用；生产请求将继续省略该字段。", bundle: .module)])
        } catch let error as AIProviderError where error.explicitlyRejectsToolChoice {
            return (.failed, [String(localized: "服务端明确拒绝 tool_choice：\(error.localizedDescription)", bundle: .module)])
        } catch {
            return (.unavailable, [String(localized: "tool_choice 探测未完成：\(error.localizedDescription)", bundle: .module)])
        }
    }

    private func observesToolCall(
        with provider: AnthropicMessagesProvider,
        tool: AIToolDefinition,
        toolChoice: AIToolChoice?
    ) async throws -> Bool {
        for try await event in provider.stream(AICompletionRequest(
            model: configuration.model,
            messages: [AIMessage(role: .user, content: "Use capabilities_get to inspect the available Auralis capabilities.")],
            temperature: 0,
            maxTokens: configuration.maxOutputTokens,
            tools: [tool],
            toolChoice: toolChoice
        )) {
            if case let .toolCall(call) = event, call.name == tool.name {
                return true
            }
        }
        return false
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let body = try Self.requestBody(
            request,
            stream: false,
            supportsToolChoice: configuration.supportsToolChoice,
            supportsReasoningControl: configuration.supportsReasoningControl,
            reasoningDialect: configuration.anthropicReasoningDialect ?? .manual,
            continuationScope: configuration.continuationScope(model: request.model)
        )
        let (data, response) = try await perform(body: body)
        try Self.validate(response, body: data)
        let result = try Self.parseCompletion(
            data: data,
            fallbackModel: request.model,
            requestID: Self.requestID(from: response)
        ).bindingContinuations(to: configuration.continuationScope(model: request.model))
        if ["max_tokens", "model_context_window_exceeded"].contains(result.finishReason ?? "") { throw AIProviderError.outputTruncated }
        if let reason = result.finishReason, !["end_turn", "stop_sequence", "tool_use", "refusal"].contains(reason) {
            throw AIProviderError.malformedResponse(detail: "Unsuccessful completion: " + reason, retryable: true)
        }
        return result
    }

    /// Anthropic 响应级请求 ID（`request-id` 头；兼容网关切到 x-request-id）。
    static func requestID(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        return http.value(forHTTPHeaderField: "request-id")
            ?? http.value(forHTTPHeaderField: "x-request-id")
    }

    /// Diagnostics may explicitly reject SSE while ordinary completion remains usable.
    /// Project that non-streaming request into the neutral stream contract without
    /// collapsing refusal into normal completion.
    private func nonStreamingProjection(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(.started(model: response.model, requestID: response.requestID))
                    if let reasoning = response.reasoning, !reasoning.isEmpty {
                        continuation.yield(.reasoningDelta(reasoning))
                    }
                    if !response.content.isEmpty {
                        continuation.yield(.answerDelta(response.content))
                    }
                    for item in response.continuations ?? [] {
                        continuation.yield(.providerContinuation(
                            item.bound(to: configuration.continuationScope(model: request.model))
                        ))
                    }
                    for toolCall in response.toolCalls ?? [] {
                        continuation.yield(.toolCall(toolCall))
                    }
                    if response.inputTokens != nil || response.outputTokens != nil {
                        continuation.yield(.usage(
                            input: response.inputTokens ?? 0,
                            output: response.outputTokens ?? 0,
                            cacheRead: response.cacheReadTokens,
                            cacheCreation: response.cacheCreationTokens,
                            reasoning: response.reasoningTokens
                        ))
                    }
                    let termination = Self.termination(forStopReason: response.finishReason)
                    switch termination.kind {
                    case .completed, .toolCallsReady:
                        continuation.yield(.completed)
                    default:
                        continuation.yield(.terminated(termination))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        if !configuration.usesStreaming {
            return nonStreamingProjection(request)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try Self.requestBody(
                        request,
                        stream: true,
                        supportsToolChoice: configuration.supportsToolChoice,
                        supportsReasoningControl: configuration.supportsReasoningControl,
                        reasoningDialect: configuration.anthropicReasoningDialect ?? .manual,
            continuationScope: configuration.continuationScope(model: request.model)
                    )
                    let (bytes, response) = try await performBytes(body: body)
                    try Self.validate(response)
                    continuation.yield(.started(model: request.model, requestID: Self.requestID(from: response)))

                    var parser = SSEParser()
                    var pending = Data()
                    var toolFragments: [Int: ToolFragment] = [:]
                    var nativeBlocks: [Int: [String: Any]] = [:]
                    var inputTokens = 0
                    var outputTokens = 0
                    var cacheReadTokens: Int?
                    var cacheCreationTokens: Int?
                    var stopReason: String?
                    var ended = false

                    func yieldUsage() {
                        if inputTokens > 0 || outputTokens > 0 || cacheReadTokens != nil || cacheCreationTokens != nil {
                            continuation.yield(.usage(
                                input: inputTokens,
                                output: outputTokens,
                                cacheRead: cacheReadTokens,
                                cacheCreation: cacheCreationTokens
                            ))
                        }
                    }

                    /// message_stop / EOF 共用的工具调用补发：
                    /// 必须按 content_block.index 恢复原始顺序，不能按
                    /// tool_use.id 字典序排序：id 不代表执行顺序。
                    func finalArguments(_ fragment: ToolFragment, index: Int) -> String {
                        if !fragment.arguments.isEmpty { return fragment.arguments }
                        guard let input = nativeBlocks[index]?["input"],
                              let data = try? JSONSerialization.data(withJSONObject: input),
                              let value = String(data: data, encoding: .utf8) else { return "{}" }
                        return value
                    }

                    func yieldAssembledToolCalls() {
                        for index in toolFragments.keys.sorted() {
                            guard let fragment = toolFragments[index] else { continue }
                            continuation.yield(.toolCall(Self.decodeToolCall(
                                id: fragment.id,
                                name: fragment.name,
                                rawArguments: finalArguments(fragment, index: index)
                            )))
                        }
                    }

                    func finish(termination: AIStreamTermination) {
                        ended = true
                        yieldUsage()
                        if termination.kind == .completed || termination.kind == .toolCallsReady {
                            for (index, fragment) in toolFragments {
                                if let input = try? JSONSerialization.jsonObject(with: Data(finalArguments(fragment, index: index).utf8)) {
                                    nativeBlocks[index]?["input"] = input
                                }
                            }
                            let blocks = nativeBlocks.keys.sorted().compactMap { nativeBlocks[$0] }
                            if !blocks.isEmpty, let data = try? JSONSerialization.data(withJSONObject: blocks), let payload = try? AIJSONValue(jsonData: data) {
                                continuation.yield(.providerContinuation(AIProviderContinuation(vendor: .anthropicMessages, ordinal: 0, payload: payload, originScope: configuration.continuationScope(model: request.model))))
                            }
                        }
                        if termination.kind == .completed || termination.kind == .toolCallsReady {
                            continuation.yield(.completed)
                        } else {
                            continuation.yield(.terminated(termination))
                        }
                        continuation.finish()
                    }

                    func consume(_ message: SSEMessage) {
                        guard !ended else { return }
                        guard let data = message.data.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { return }
                        let type = object["type"] as? String ?? ""
                        switch type {
                        case "message_start":
                            if let usage = object["message"] as? [String: Any] {
                                let messageUsage = usage["usage"] as? [String: Any]
                                inputTokens = messageUsage?["input_tokens"] as? Int ?? inputTokens
                                // Anthropic 的 cache 命中/写入是独立计量，
                                // 不计入 input_tokens（总输入 = 三者相加）。
                                if let read = messageUsage?["cache_read_input_tokens"] as? Int { cacheReadTokens = read }
                                if let created = messageUsage?["cache_creation_input_tokens"] as? Int { cacheCreationTokens = created }
                            }
                        case "content_block_start":
                            guard let index = object["index"] as? Int,
                                  let block = object["content_block"] as? [String: Any]
                            else { return }
                            nativeBlocks[index] = block
                            switch block["type"] as? String {
                            case "tool_use":
                                toolFragments[index] = ToolFragment(
                                    id: block["id"] as? String ?? "anthropic-tool-\(index)",
                                    name: block["name"] as? String ?? "",
                                    arguments: ""
                                )
                            case "text":
                                if let text = block["text"] as? String, !text.isEmpty { continuation.yield(.answerDelta(text)) }
                            default:
                                break
                            }
                        case "content_block_delta":
                            let delta = object["delta"] as? [String: Any] ?? [:]
                            if let index = object["index"] as? Int, var block = nativeBlocks[index] {
                                let key: String? = switch delta["type"] as? String {
                                case "text_delta": "text"
                                case "thinking_delta": "thinking"
                                case "signature_delta": "signature"
                                default: nil
                                }
                                if let key, let piece = delta[key] as? String {
                                    block[key] = (block[key] as? String ?? "") + piece
                                    nativeBlocks[index] = block
                                }
                            }
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let text = delta["text"] as? String { continuation.yield(.answerDelta(text)) }
                            case "thinking_delta":
                                if let text = delta["thinking"] as? String { continuation.yield(.reasoningDelta(text)) }
                            case "input_json_delta":
                                if let index = object["index"] as? Int, var fragment = toolFragments[index], let partial = delta["partial_json"] as? String {
                                    fragment.arguments += partial
                                    toolFragments[index] = fragment
                                }
                            default: break
                            }
                        case "content_block_stop":
                            break
                        case "message_delta":
                            // stop_reason 是真正的终止语义，必须读取：
                            // end_turn/tool_use/max_tokens/pause_turn/refusal。
                            if let delta = object["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }
                            if let usage = object["usage"] as? [String: Any] {
                                outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                                if let read = usage["cache_read_input_tokens"] as? Int { cacheReadTokens = read }
                                if let created = usage["cache_creation_input_tokens"] as? Int { cacheCreationTokens = created }
                            }
                        case "message_stop":
                            yieldAssembledToolCalls()
                            finish(termination: Self.termination(forStopReason: stopReason))
                        default:
                            break
                        }
                    }

                    for try await byte in bytes {
                        pending.append(byte)
                        guard byte == 0x0A else { continue }
                        for message in parser.append(pending) { consume(message) }
                        pending.removeAll(keepingCapacity: true)
                    }
                    if !pending.isEmpty {
                        for message in parser.append(pending) { consume(message) }
                    }
                    for message in parser.finish() { consume(message) }
                    if !ended {
                        // 兼容没有 message_stop 的网关：补发已收集的工具调用与
                        // 推理块，但 EOF 不是显式终止信号——默认按
                        // transportInterrupted 上报；仅当端点被显式配置为
                        // 「以 EOF 为正常结束」时才视为 completed。
                        yieldAssembledToolCalls()
                        let termination: AIStreamTermination = configuration.assumesImplicitStreamTermination
                            ? .completed
                            : AIStreamTermination(kind: .transportInterrupted, rawReason: "eof_without_message_stop")
                        finish(termination: termination)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Anthropic stop_reason → 统一终止语义。message_stop 本身是显式终止
    /// 信号；只有 max_tokens/pause_turn/refusal 需要与正常完成区分。
    static func termination(forStopReason reason: String?) -> AIStreamTermination {
        switch reason {
        case "max_tokens":
            return AIStreamTermination(kind: .truncated, rawReason: reason)
        case "pause_turn":
            return AIStreamTermination(kind: .paused, rawReason: reason)
        case "refusal":
            return AIStreamTermination(kind: .refused, rawReason: reason)
        case "tool_use":
            return AIStreamTermination(kind: .toolCallsReady, rawReason: reason)
        default:
            return AIStreamTermination(kind: .completed, rawReason: reason)
        }
    }

    private struct ToolFragment {
        var id: String
        var name: String
        var arguments: String
    }

    private func perform(body: [String: Any]) async throws -> (Data, URLResponse) {
        let request = try await makeRequest(body: body)
        let (data, response) = try await session.data(for: request)
        return (data, response)
    }

    private func performBytes(body: [String: Any]) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let request = try await makeRequest(body: body)
        return try await session.bytes(for: request)
    }

    private func endpoint() throws -> URL {
        var component = configuration.apiPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = configuration.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if basePath == "v1" || basePath.hasSuffix("/v1") {
            if component.lowercased() == "v1" { component = "" }
            else if component.lowercased().hasPrefix("v1/") { component.removeFirst(3) }
        }
        let url = component.isEmpty ? configuration.baseURL : configuration.baseURL.appendingPathComponent(component)
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || (scheme == "http" && OpenAICompatibleProvider.isPrivateOrLoopbackHost(url.host ?? "")) else {
            throw schemeError(url)
        }
        return url
    }

    private func schemeError(_ url: URL) -> AIProviderError {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return .invalidEndpoint }
        return .insecureEndpoint
    }

    private func makeRequest(body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: try endpoint(), timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if let credentialID = configuration.credentialID {
            do {
                let key = try await credentialVault.retrieve(id: credentialID)
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            } catch {
                throw AIProviderError.missingCredential
            }
        }
        for (name, value) in configuration.customHeaders.values {
            switch value {
            case let .literal(literal): request.setValue(literal, forHTTPHeaderField: name)
            case let .credential(credentialID):
                let secret = try await credentialVault.retrieve(id: credentialID)
                request.setValue(secret, forHTTPHeaderField: name)
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func requestBody(
        _ request: AICompletionRequest,
        stream: Bool,
        supportsToolChoice: Bool,
        supportsReasoningControl: Bool,
        reasoningDialect: AnthropicReasoningDialect = .manual,
        continuationScope: String? = nil
    ) throws -> [String: Any] {
        guard request.hostedTools?.isEmpty != false else {
            throw AIProviderError.unsupportedEndpointProtocol("Anthropic hosted web tools are not enabled")
        }
        let transcript = request.transcript
        var system: [String] = []
        for message in transcript.messages where message.role == .system {
            if !message.content.isEmpty { system.append(message.content) }
        }
        let messages = encodeMessages(transcript, scope: continuationScope)

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens,
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if let thinking = Self.encodeThinking(
            request.reasoning,
            maxTokens: request.maxTokens,
            supportsReasoningControl: supportsReasoningControl,
            dialect: reasoningDialect,
            toolChoice: request.toolChoice
        ) {
            body["thinking"] = thinking
        }
        let thinkingActive = body["thinking"] != nil
        if !thinkingActive, request.temperature >= 0 { body["temperature"] = request.temperature }
        if stream { body["stream"] = true }
        switch request.outputFormat {
        case nil, .text:
            break
        case .jsonObject:
            // Anthropic Messages exposes schema-constrained JSON through
            // output_config.format; it has no schema-free json_object mode.
            throw AIProviderError.unsupportedEndpointProtocol("Anthropic Messages requires a JSON schema for structured output")
        case let .jsonSchema(_, schema, _):
            guard let object = try JSONSerialization.jsonObject(with: schema.jsonData) as? [String: Any] else {
                throw AIProviderError.unsupportedEndpointProtocol("Structured output schema is not a JSON object")
            }
            body["output_config"] = [
                "format": [
                    "type": "json_schema",
                    "schema": object,
                ],
            ]
        }
        // adaptive 方言的 effort 与 output_config.format 共用同一对象，必须合并。
        if let effort = Self.encodeAdaptiveEffort(
            request.reasoning,
            supportsReasoningControl: supportsReasoningControl,
            dialect: reasoningDialect
        ) {
            var outputConfig = body["output_config"] as? [String: Any] ?? [:]
            outputConfig["effort"] = effort
            body["output_config"] = outputConfig
        }
        let toolChoiceDisablesTools = request.toolChoice.map { choice in
            if case .none = choice { return true }
            return false
        } ?? false
        if let tools = request.tools, !tools.isEmpty, !toolChoiceDisablesTools {
            body["tools"] = try tools.map { tool in
                var item: [String: Any] = ["name": tool.name, "description": tool.description]
                if let schema = tool.parametersJSON,
                   let data = schema.data(using: .utf8),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    item["input_schema"] = object
                } else {
                    item["input_schema"] = ["type": "object", "properties": [:]]
                }
                return item
            }
            if supportsToolChoice, let choice = request.toolChoice {
                switch choice {
                case .auto: body["tool_choice"] = ["type": "auto"]
                case .required: body["tool_choice"] = ["type": "any"]
                case let .named(name): body["tool_choice"] = ["type": "tool", "name": name]
                case .none: break
                }
            }
        }
        return body
    }

    /// 按方言编码思考控制。语义约定：
    /// - automatic：不发送 thinking 字段（跟随服务端默认），两种方言一致；
    /// - disabled：manual 发送 `type: disabled` 显式关闭；adaptive 省略
    ///   thinking（adaptive 端点默认不思考）；
    /// - enabled：manual 发送 `type: enabled + budget_tokens`（预算按 effort
    ///   档位并钳制到 maxTokens 以内）；adaptive 发送 `type: adaptive`（不携带
    ///   budget，新模型会拒绝 enabled+budget 组合），effort 通过 output_config
    ///   的 effort 字段表达。
    /// 组合限制由 `AnthropicReasoningDialect` 的能力描述建模（如 manual 思考
    /// 不允许强制 tool_choice）；服务端拒绝某个具体参数时，错误归因依赖
    /// `AIProviderError.rejectedParameter`，不会把整个思考能力永久关闭。
    static func encodeThinking(
        _ reasoning: AIReasoningConfiguration?,
        maxTokens: Int,
        supportsReasoningControl: Bool,
        dialect: AnthropicReasoningDialect,
        toolChoice: AIToolChoice?
    ) -> [String: Any]? {
        guard supportsReasoningControl, let reasoning else { return nil }
        switch reasoning.mode {
        case .automatic:
            return nil
        case .disabled:
            switch dialect {
            case .manual: return ["type": "disabled"]
            case .adaptive: return nil
            }
        case .enabled:
            switch dialect {
            case .manual:
                guard maxTokens > 1_024 else { return nil }
                if let toolChoice {
                    switch toolChoice { case .required, .named: return nil; default: break }
                }
                let suggestedBudget: Int
                switch reasoning.effort {
                case .low: suggestedBudget = 1_024
                case .medium: suggestedBudget = 2_048
                case .high: suggestedBudget = 4_096
                case .xhigh: suggestedBudget = 8_192
                case .max: suggestedBudget = 16_384
                }
                return [
                    "type": "enabled",
                    "budget_tokens": min(suggestedBudget, max(1, maxTokens - 1)),
                ]
            case .adaptive:
                return ["type": "adaptive"]
            }
        }
    }

    /// adaptive 方言下的 effort 线网取值；manual 方言不单独编码 effort
    /// （预算即强度）。
    static func encodeAdaptiveEffort(
        _ reasoning: AIReasoningConfiguration?,
        supportsReasoningControl: Bool,
        dialect: AnthropicReasoningDialect
    ) -> String? {
        guard supportsReasoningControl, dialect == .adaptive,
              let reasoning, reasoning.mode == .enabled
        else { return nil }
        switch reasoning.effort {
        case .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh: return "high"
        case .max: return "max"
        }
    }

    /// Encode the neutral message projection into Anthropic content blocks.
    /// Parallel tool calls must be answered by one `user` message containing
    /// all `tool_result` blocks; one user message per result is invalid for
    /// the Messages API and loses the call/result association.
    ///
    /// Vendor-matched continuations (signed thinking / redacted_thinking)
    /// are replayed verbatim at the start of the assistant content they
    /// belong to — Claude requires the original blocks, in original order,
    /// when a tool loop continues an assistant turn.
    static func encodeMessages(_ transcript: AITranscript, scope: String? = nil) -> [[String: Any]] {
        let source = transcript.messages
        let continuations = transcript.continuationsByAssistantMessageIndex(vendor: .anthropicMessages, scope: scope)
        guard !continuations.isEmpty else { return encodeMessages(source) }

        var messages: [[String: Any]] = []
        var index = 0
        while index < source.count {
            let message = source[index]
            if message.role == .assistant, let blocks = continuations[index] {
                if let native = blocks.first, case .array = native.payload,
                   let content = try? JSONSerialization.jsonObject(with: native.payload.jsonData) as? [[String: Any]] {
                    messages.append(["role": "assistant", "content": content])
                    index += 1
                    continue
                }
                // 与 encodeMessages(_:) 相同的 assistant 编码，但先回放原生块。
                var content: [[String: Any]] = blocks.compactMap { continuation in
                    (try? JSONSerialization.jsonObject(with: continuation.payload.jsonData)) as? [String: Any]
                }
                if !message.content.isEmpty { content.append(["type": "text", "text": message.content]) }
                for call in message.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.jsonString.utf8))) as? [String: Any] ?? [:]
                    content.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                messages.append(["role": "assistant", "content": content.isEmpty ? [["type": "text", "text": ""]] : content])
                index += 1
                continue
            }
            // 非 assistant 条目复用单消息编码，保持并行 tool_result 聚合语义。
            var next = index + 1
            if message.role == .tool {
                while next < source.count, source[next].role == .tool { next += 1 }
            }
            messages.append(contentsOf: encodeMessages(Array(source[index..<next])))
            index = next
        }
        return messages
    }

    static func encodeMessages(_ source: [AIMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var index = 0
        while index < source.count {
            let message = source[index]
            switch message.role {
            case .system:
                index += 1
            case .user:
                messages.append(["role": "user", "content": [["type": "text", "text": message.content]]])
                index += 1
            case .assistant:
                var content: [[String: Any]] = []
                if !message.content.isEmpty { content.append(["type": "text", "text": message.content]) }
                for call in message.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.jsonString.utf8))) as? [String: Any] ?? [:]
                    content.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                messages.append(["role": "assistant", "content": content.isEmpty ? [["type": "text", "text": ""]] : content])
                index += 1
            case .tool:
                var blocks: [[String: Any]] = []
                while index < source.count, source[index].role == .tool {
                    let result = source[index]
                    blocks.append([
                        "type": "tool_result",
                        "tool_use_id": result.toolCallID ?? "",
                        "content": result.content,
                    ])
                    index += 1
                }
                messages.append(["role": "user", "content": blocks])
            }
        }
        return messages
    }

    private static func validate(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        if let body, !body.isEmpty {
            let text = String(data: body, encoding: .utf8)?.prefix(240) ?? ""
            throw AIProviderError.httpStatusDetail(status: http.statusCode, detail: String(text))
        }
        throw AIProviderError.httpStatus(http.statusCode)
    }

    private static func parseCompletion(data: Data, fallbackModel: String, requestID: String? = nil) throws -> AICompletionResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.malformedResponse(detail: "Anthropic Messages 响应不是 JSON", retryable: false)
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIProviderError.malformedResponse(detail: message, retryable: false)
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        var text = ""
        var reasoning = ""
        var calls: [AIToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "thinking":
                reasoning += block["thinking"] as? String ?? ""
            case "tool_use":
                let input = block["input"] ?? [:]
                let data = try JSONSerialization.data(withJSONObject: input)
                calls.append(Self.decodeToolCall(
                    id: block["id"] as? String ?? UUID().uuidString,
                    name: block["name"] as? String ?? "",
                    rawArguments: String(data: data, encoding: .utf8) ?? "{}"
                ))
            default: break
            }
        }
        let usage = object["usage"] as? [String: Any]
        return AICompletionResponse(
            model: object["model"] as? String ?? fallbackModel,
            content: text,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            // Anthropic 的 input_tokens 不含 cache_read/cache_creation；
            // 总输入 = input + cacheRead + cacheCreation。
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            cacheReadTokens: usage?["cache_read_input_tokens"] as? Int,
            cacheCreationTokens: usage?["cache_creation_input_tokens"] as? Int,
            requestID: requestID,
            finishReason: object["stop_reason"] as? String,
            toolCalls: calls.isEmpty ? nil : calls,
            continuations: blocks.isEmpty ? nil : [AIProviderContinuation(vendor: .anthropicMessages, ordinal: 0, payload: try AIJSONValue(jsonData: JSONSerialization.data(withJSONObject: blocks)))]
        )
    }

    private static func decodeToolCall(id: String, name: String, rawArguments: String) -> AIToolCall {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments: AIJSONValue
        if trimmed.isEmpty || trimmed == "null" {
            arguments = .object([:])
        } else {
            arguments = (try? AIJSONValue(jsonString: trimmed)) ?? .string(rawArguments)
        }
        return AIToolCall(id: id, name: name, arguments: arguments)
    }
}
