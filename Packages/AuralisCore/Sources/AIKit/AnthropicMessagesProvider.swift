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
            maxOutputTokens: configuration.maxOutputTokens,
            supportsToolCalling: supportsToolCalling,
            supportsStreaming: configuration.usesStreaming,
            supportsJSONMode: false,
            supportsJSONSchema: configuration.supportsJSONSchema
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
        return AIConnectionResult(
            latency: Date().timeIntervalSince(started),
            model: response.model,
            message: response.content
        )
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let body = try Self.requestBody(request, stream: false)
        let (data, response) = try await perform(body: body)
        try Self.validate(response, body: data)
        return try Self.parseCompletion(data: data, fallbackModel: request.model)
    }

    public func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try Self.requestBody(request, stream: true)
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
                                if let text = delta["text"] as? String { continuation.yield(.delta(text)) }
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
                            for fragment in toolFragments.values.sorted(by: { $0.id < $1.id }) {
                                continuation.yield(.toolCall(AIToolCall(
                                    id: fragment.id,
                                    name: fragment.name,
                                    arguments: fragment.arguments.isEmpty ? "{}" : fragment.arguments
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
                    if !ended, !toolFragments.isEmpty {
                        for fragment in toolFragments.values.sorted(by: { $0.id < $1.id }) {
                            continuation.yield(.toolCall(AIToolCall(
                                id: fragment.id,
                                name: fragment.name,
                                arguments: fragment.arguments.isEmpty ? "{}" : fragment.arguments
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

    private static func requestBody(_ request: AICompletionRequest, stream: Bool) throws -> [String: Any] {
        var system: [String] = []
        var messages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system:
                if !message.content.isEmpty { system.append(message.content) }
            case .user:
                messages.append(["role": "user", "content": [["type": "text", "text": message.content]]])
            case .assistant:
                var content: [[String: Any]] = []
                if !message.content.isEmpty { content.append(["type": "text", "text": message.content]) }
                for call in message.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                    content.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                messages.append(["role": "assistant", "content": content.isEmpty ? [["type": "text", "text": ""]] : content])
            case .tool:
                messages.append(["role": "user", "content": [[
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.content,
                ]]])
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens,
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if request.temperature >= 0 { body["temperature"] = request.temperature }
        if stream { body["stream"] = true }
        if let tools = request.tools, !tools.isEmpty {
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
            if let choice = request.toolChoice {
                switch choice {
                case .auto: body["tool_choice"] = ["type": "auto"]
                case .required: body["tool_choice"] = ["type": "any"]
                case .none: break
                }
            }
        }
        return body
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
        var calls: [AIToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text": text += block["text"] as? String ?? ""
            case "tool_use":
                let input = block["input"] ?? [:]
                let data = try JSONSerialization.data(withJSONObject: input)
                calls.append(AIToolCall(
                    id: block["id"] as? String ?? UUID().uuidString,
                    name: block["name"] as? String ?? "",
                    arguments: String(data: data, encoding: .utf8) ?? "{}"
                ))
            default: break
            }
        }
        let usage = object["usage"] as? [String: Any]
        return AICompletionResponse(
            model: object["model"] as? String ?? fallbackModel,
            content: text,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            finishReason: object["stop_reason"] as? String,
            toolCalls: calls.isEmpty ? nil : calls
        )
    }
}
