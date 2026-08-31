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
            let observed = try await observesToolCall(with: self, tool: tool, toolChoice: nil)
            guard observed else {
                return (.unavailable, .notTested, [String(localized: "原生工具探测未收到工具调用；这不代表模型不支持工具。", bundle: .module)])
            }
            let choice = await probeToolChoice(with: tool)
            return (.passed, choice.status, choice.details)
        } catch let error as AIProviderError {
            if error.explicitlyRejectsNativeTools {
                return (.failed, .notTested, [String(localized: "服务端明确拒绝原生工具：\(error.localizedDescription)", bundle: .module)])
            }
            return (.unavailable, .notTested, [String(localized: "原生工具探测未完成：\(error.localizedDescription)", bundle: .module)])
        } catch {
            return (.unavailable, .notTested, [String(localized: "原生工具探测未完成：\(error.localizedDescription)", bundle: .module)])
        }
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
            supportsReasoningControl: configuration.supportsReasoningControl
        )
        let (data, response) = try await perform(body: body)
        try Self.validate(response, body: data)
        return try Self.parseCompletion(data: data, fallbackModel: request.model)
    }

    public func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try Self.requestBody(
                        request,
                        stream: true,
                        supportsToolChoice: configuration.supportsToolChoice,
                        supportsReasoningControl: configuration.supportsReasoningControl
                    )
                    let (bytes, response) = try await performBytes(body: body)
                    try Self.validate(response)
                    continuation.yield(.started(model: request.model))

                    var parser = SSEParser()
                    var pending = Data()
                    var toolFragments: [Int: ToolFragment] = [:]
                    var inputTokens = 0
                    var outputTokens = 0
                    var ended = false

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
                            }
                        case "content_block_start":
                            guard let index = object["index"] as? Int,
                                  let block = object["content_block"] as? [String: Any],
                                  block["type"] as? String == "tool_use"
                            else { return }
                            toolFragments[index] = ToolFragment(
                                id: block["id"] as? String ?? "anthropic-tool-\(index)",
                                name: block["name"] as? String ?? "",
                                arguments: ""
                            )
                        case "content_block_delta":
                            let delta = object["delta"] as? [String: Any] ?? [:]
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let text = delta["text"] as? String { continuation.yield(.answerDelta(text)) }
                            case "thinking_delta":
                                if let thinking = delta["thinking"] as? String {
                                    continuation.yield(.reasoningDelta(thinking))
                                }
                            case "input_json_delta":
                                if let index = object["index"] as? Int,
                                   var fragment = toolFragments[index],
                                   let partial = delta["partial_json"] as? String {
                                    fragment.arguments += partial
                                    toolFragments[index] = fragment
                                }
                            default:
                                break
                            }
                        case "message_delta":
                            if let usage = object["usage"] as? [String: Any] {
                                outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                            }
                        case "message_stop":
                            // 必须按 content_block.index 恢复原始顺序，不能按
                            // tool_use.id 字典序排序：id 不代表执行顺序。
                            for index in toolFragments.keys.sorted() {
                                guard let fragment = toolFragments[index] else { continue }
                                continuation.yield(.toolCall(Self.decodeToolCall(
                                    id: fragment.id,
                                    name: fragment.name,
                                    rawArguments: fragment.arguments.isEmpty ? "{}" : fragment.arguments
                                )))
                            }
                            ended = true
                            if inputTokens > 0 || outputTokens > 0 {
                                continuation.yield(.usage(input: inputTokens, output: outputTokens))
                            }
                            continuation.yield(.completed)
                            continuation.finish()
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
                    // 兼容没有 message_stop 的网关：不要让 Agent 永远等待。
                    // 同样按 content_block.index 恢复原始顺序。
                    if !ended, !toolFragments.isEmpty {
                        for index in toolFragments.keys.sorted() {
                            guard let fragment = toolFragments[index] else { continue }
                            continuation.yield(.toolCall(Self.decodeToolCall(
                                id: fragment.id,
                                name: fragment.name,
                                rawArguments: fragment.arguments.isEmpty ? "{}" : fragment.arguments
                            )))
                        }
                    }
                    if !ended {
                        continuation.yield(.completed)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    private static func requestBody(
        _ request: AICompletionRequest,
        stream: Bool,
        supportsToolChoice: Bool,
        supportsReasoningControl: Bool
    ) throws -> [String: Any] {
        guard request.hostedTools?.isEmpty != false else {
            throw AIProviderError.unsupportedEndpointProtocol("Anthropic hosted web tools are not enabled")
        }
        let transcript = request.transcript
        var system: [String] = []
        for message in transcript.messages where message.role == .system {
            if !message.content.isEmpty { system.append(message.content) }
        }
        let messages = encodeMessages(transcript)

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens,
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        let reasoningEnabled = request.reasoning?.enabled == true && supportsReasoningControl
        if !reasoningEnabled, request.temperature >= 0 { body["temperature"] = request.temperature }
        if stream { body["stream"] = true }
        if reasoningEnabled, let effort = request.reasoning?.effort {
            let suggestedBudget: Int
            switch effort {
            case .low: suggestedBudget = 1_024
            case .medium: suggestedBudget = 2_048
            case .high: suggestedBudget = 4_096
            case .xhigh: suggestedBudget = 8_192
            case .max: suggestedBudget = 16_384
            }
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": min(suggestedBudget, max(1, request.maxTokens - 1)),
            ]
        }
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

    /// Encode the neutral message projection into Anthropic content blocks.
    /// Parallel tool calls must be answered by one `user` message containing
    /// all `tool_result` blocks; one user message per result is invalid for
    /// the Messages API and loses the call/result association.
    static func encodeMessages(_ transcript: AITranscript) -> [[String: Any]] {
        encodeMessages(transcript.messages)
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

    private static func parseCompletion(data: Data, fallbackModel: String) throws -> AICompletionResponse {
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
            case "text": text += block["text"] as? String ?? ""
            case "thinking": reasoning += block["thinking"] as? String ?? ""
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
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            finishReason: object["stop_reason"] as? String,
            toolCalls: calls.isEmpty ? nil : calls
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
