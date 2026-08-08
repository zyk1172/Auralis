import Domain
import Foundation
import SecurityKit

public enum AIProviderError: Error, Equatable, Sendable {
    case missingCredential
    case invalidEndpoint
    case transport(String)
    case httpStatus(Int)
    /// 响应无法解析。
    /// - detail: 响应体前若干字节（或说明），便于定位是空响应、HTML 错误页还是格式不兼容。
    /// - retryable: 空响应 / 截断 JSON / 非 JSON 错误页属于网关瞬时抖动，可重试；
    ///   合法 JSON 但结构不兼容（真的不是 OpenAI 格式）不重试，重试也没用。
    case malformedResponse(detail: String, retryable: Bool)
}

public extension AIProviderError {
    /// 是否属于「瞬时故障」——值得再试一次，而不是配置或业务层面的确定性错误。
    /// 供 Provider 内部重试与上层（如 AgentRunner）判定是否补一次重试共用。
    var isTransient: Bool {
        switch self {
        case let .httpStatus(status):
            return status == 429 || (500...599).contains(status)
        case .transport:
            return true
        case let .malformedResponse(_, retryable):
            return retryable
        case .missingCredential, .invalidEndpoint:
            return false
        }
    }
}

extension AIProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            "尚未配置 API Key，请先在设置中填写。"
        case .invalidEndpoint:
            "接口地址无效，请检查 Base URL 与 API 路径。"
        case let .transport(message):
            "网络请求失败：\(message)"
        case let .httpStatus(status):
            switch status {
            case 401, 403:
                "服务返回 HTTP \(status)：API Key 无效或权限不足，请检查设置中的 Key。"
            case 404:
                "服务返回 HTTP \(status)：接口路径错误，请检查 Base URL 是否已包含 /v1 等路径前缀。"
            case 429:
                "服务返回 HTTP 429：请求过于频繁被限流，已自动重试仍失败，请稍后重试。"
            case 500...599:
                "服务返回 HTTP \(status)：服务端或中转网关暂不可用（可能过载或维护中）。已自动重试仍失败，请稍后重试；若持续出现，请检查该 Base URL 对应服务的状态。"
            default:
                "服务返回 HTTP \(status)。"
            }
        case let .malformedResponse(detail, retryable):
            retryable
                ? "返回内容无法解析（已自动重试仍失败）：\(detail)"
                : "返回内容无法解析，该服务可能不兼容 OpenAI Chat Completions 格式：\(detail)"
        }
    }
}

/// OpenAI Chat Completions 兼容实现：适用于 OpenAI、DeepSeek、通义、
/// Ollama、LM Studio 及各类中转网关。API Key 只从 Keychain 读取，
/// 明文不会进入配置、日志或导出。
public struct OpenAICompatibleProvider: AIProvider {
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

    public func testConnection() async throws -> AIConnectionResult {
        let started = Date()
        let response = try await complete(
            AICompletionRequest(
                model: configuration.model,
                messages: [AIMessage(role: .user, content: "用一句话确认连接正常。")],
                temperature: 0,
                maxTokens: 32
            )
        )
        return AIConnectionResult(
            latency: Date().timeIntervalSince(started),
            model: response.model,
            message: response.content
        )
    }

    /// 非流式补全。
    ///
    /// 解析放在重试循环**内部**：中转网关偶发返回空响应体、HTML 错误页或被截断的
    /// JSON 时，这类瞬时故障也能自动重试，而不是一次解析失败就直接判死。
    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        try await performRequest(
            body: requestBody(request, stream: false),
            run: { try await session.data(for: $0) },
            transform: { data, _ in
                try Self.parseCompletion(data: data, fallbackModel: request.model)
            }
        )
    }

    public func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await performRequestBytes(body: requestBody(request, stream: true))
                    continuation.yield(.started(model: request.model))
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        // URLSession 按行吐出，SSEParser 以空行分块；
                        // 逐行补 "\n" 后再补一个空行切出完整事件。
                        for message in parser.append(Data((line + "\n\n").utf8)) {
                            if message.data == "[DONE]" {
                                continuation.yield(.completed)
                                continuation.finish()
                                return
                            }
                            if let delta = Self.streamDelta(from: message.data) {
                                continuation.yield(.delta(delta))
                            }
                        }
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request execution with retry

    /// 流式请求：字节流本身无需二次解析，`transform` 原样透传。
    private func performRequestBytes(body: [String: Any]) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await performRequest(body: body, run: { try await session.bytes(for: $0) }, transform: { ($0, $1) })
    }

    /// 对瞬时故障（503/502/504/429/网络抖动/空响应/截断 JSON）自动重试，
    /// 避免偶发抖动直接把用户打回降级路径。任务被取消时不重试、立即上抛。
    ///
    /// `transform` 在重试循环**内部**执行，因此响应体解析失败同样受重试保护——
    /// 这正是「测试要点好多次才成功」的根因之一：解析失败原本在循环外，一次即死。
    private func performRequest<Raw, Value>(
        body: [String: Any],
        run: (URLRequest) async throws -> (Raw, URLResponse),
        transform: (Raw, URLResponse) throws -> Value
    ) async throws -> Value {
        var attempt = 0
        var lastError: Error = AIProviderError.transport("请求失败")
        while attempt < Self.maxRetries {
            do {
                let urlRequest = try await makeRequest(body: body)
                let (raw, response) = try await run(urlRequest)
                try validate(response)
                return try transform(raw, response)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                lastError = Self.mapError(error)
                attempt += 1
                if attempt < Self.maxRetries, Self.isRetryable(lastError) {
                    try await Self.sleepBackoff(attempt: attempt)
                    continue
                }
                throw lastError
            }
        }
        throw lastError
    }

    // MARK: - Request building

    /// 由 baseURL + apiPath 拼出完整接口地址。
    /// 用 `appendingPathComponent` 处理结尾斜杠，避免产出 `//v1/...` 这类
    /// 某些网关会拒绝（返回 503）的重复斜杠。
    func endpoint() throws -> URL {
        let path = configuration.apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let component = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = configuration.baseURL.appendingPathComponent(component)
        guard url.scheme != nil else { throw AIProviderError.invalidEndpoint }
        return url
    }

    private static let maxRetries = 3
    private static let backoffBaseSeconds: Double = 1.0

    /// 仅对瞬时故障重试：5xx、限流(429)、网络抖动，以及空响应/截断 JSON 这类
    /// 可恢复的解析失败；确定性业务错误（鉴权、路径、格式不兼容）与取消不重试。
    static func isRetryable(_ error: Error) -> Bool {
        if let providerError = error as? AIProviderError {
            return providerError.isTransient
        }
        return true
    }

    private static func mapError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return error }
            return AIProviderError.transport(urlError.localizedDescription)
        }
        if error is AIProviderError { return error }
        return AIProviderError.transport(error.localizedDescription)
    }

    private static func sleepBackoff(attempt: Int) async throws {
        let seconds = backoffBaseSeconds * pow(2.0, Double(attempt - 1))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func makeRequest(body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: try endpoint(), timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        if let organization = configuration.organization, !organization.isEmpty {
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let project = configuration.project, !project.isEmpty {
            request.setValue(project, forHTTPHeaderField: "OpenAI-Project")
        }
        for (name, value) in configuration.customHeaders.values {
            switch value {
            case let .literal(literal):
                request.setValue(literal, forHTTPHeaderField: name)
            case let .credential(credentialID):
                let secret = try await credentialVault.retrieve(id: credentialID)
                request.setValue(secret, forHTTPHeaderField: name)
            }
        }

        if let credentialID = configuration.credentialID {
            let key: String
            do {
                key = try await credentialVault.retrieve(id: credentialID)
            } catch {
                throw AIProviderError.missingCredential
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func requestBody(_ request: AICompletionRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(Self.encodeMessage),
            "temperature": request.temperature,
            "max_tokens": request.maxTokens,
        ]
        if stream { body["stream"] = true }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                var function: [String: Any] = ["name": tool.name, "description": tool.description]
                if let json = tool.parametersJSON,
                   let data = json.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    function["parameters"] = object
                }
                return ["type": "function", "function": function]
            }
        }
        return body
    }

    /// 按角色编码消息：`.tool` 携带 tool_call_id / name；`.assistant` 携带原生 tool_calls。
    private static func encodeMessage(_ message: AIMessage) -> [String: Any] {
        var result: [String: Any] = ["role": message.role.rawValue]
        switch message.role {
        case .tool:
            result["content"] = message.content
            result["tool_call_id"] = message.toolCallID ?? ""
            if let name = message.name, !name.isEmpty { result["name"] = name }
        case .assistant:
            result["content"] = message.content
            if let calls = message.toolCalls, !calls.isEmpty {
                result["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments],
                    ]
                }
            }
        default:
            result["content"] = message.content
        }
        return result
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw AIProviderError.httpStatus(http.statusCode)
        }
    }

    // MARK: - Response parsing

    /// 宽容解析 Chat Completions 响应。中转网关 / 本地模型的常见偏差都在这里兜住：
    /// 1. 空响应体 → 判为可重试；
    /// 2. 合法 JSON + `choices[0].message` → 正常路径，`content` 为 null / 数组 /
    ///    只有 `reasoning_content` 时不再判死，退化成空串或推理文本；
    /// 3. 请求的是非流式，服务端却回了 SSE（`data: {...}`）→ 就地把 delta 拼起来；
    /// 4. HTTP 200 但 body 里塞了 `{"error": {...}}` → 把服务端原文透出；
    /// 5. 其余（HTML 错误页、截断 JSON）→ 附响应体前 240 字节，便于定位。
    static func parseCompletion(data: Data, fallbackModel: String) throws -> AICompletionResponse {
        guard !data.isEmpty else {
            throw AIProviderError.malformedResponse(detail: "服务返回了空响应体", retryable: true)
        }

        let jsonObject = try? JSONSerialization.jsonObject(with: data)

        if let object = jsonObject as? [String: Any] {
            if let content = extractContent(from: object) {
                let usage = object["usage"] as? [String: Any]
                return AICompletionResponse(
                    model: object["model"] as? String ?? fallbackModel,
                    content: content,
                    reasoning: reasoningContent(from: object),
                    inputTokens: usage?["prompt_tokens"] as? Int,
                    outputTokens: usage?["completion_tokens"] as? Int,
                    finishReason: finishReason(from: object),
                    toolCalls: toolCalls(from: object)
                )
            }
            if let message = errorMessage(from: object) {
                // 网关把错误塞进 200 响应体：这是服务端的确定性回答，重试无益。
                throw AIProviderError.malformedResponse(detail: "服务返回错误：\(message)", retryable: false)
            }
        }

        // 非流式请求却收到 SSE：把各 chunk 的 delta 拼成完整文本，直接当成功返回。
        if let aggregated = aggregateStreamedBody(data) {
            return AICompletionResponse(
                model: aggregated.model ?? fallbackModel,
                content: aggregated.content,
                inputTokens: aggregated.inputTokens,
                outputTokens: aggregated.outputTokens
            )
        }

        // 合法 JSON 但结构完全不认识 → 服务确实不兼容，重试没意义；
        // 连 JSON 都不是（HTML 错误页、被截断的响应）→ 多半是网关抖动，允许重试。
        throw AIProviderError.malformedResponse(
            detail: bodyPreview(data),
            retryable: jsonObject == nil
        )
    }

    /// 从 `choices[0]` 提取文本。只要能认出 message/delta/text 结构就视为格式兼容，
    /// `content` 缺失或为 null 时返回空字符串而非报错（例如仅返回 tool_calls 的响应）。
    static func extractContent(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        if let message = first["message"] as? [String: Any] {
            // 只返回 content。思考链（reasoning_content）由 reasoningContent(from:) 单独提取，
            // 绝不作为用户可见内容（避免把「思考链」展示出来）。
            return plainText(from: message["content"]) ?? ""
        }
        if let delta = first["delta"] as? [String: Any] {
            return plainText(from: delta["content"]) ?? ""
        }
        if let legacy = first["text"] as? String {
            return legacy // 旧版 /v1/completions 风格
        }
        return nil
    }

    /// 提取思考链（reasoning_content），仅内部保存，不展示给用户。
    static func reasoningContent(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any],
              let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty
        else { return nil }
        return reasoning
    }

    /// 解析 `choices[0].message.tool_calls`（原生 function calling）。
    static func toolCalls(from object: [String: Any]) -> [AIToolCall]? {
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let calls = message["tool_calls"] as? [[String: Any]]
        else { return nil }
        let parsed = calls.compactMap { call -> AIToolCall? in
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String
            else { return nil }
            let arguments = function["arguments"] as? String ?? ""
            return AIToolCall(id: id, name: name, arguments: arguments)
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// 解析 `choices[0].finish_reason`。
    static func finishReason(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }
        return first["finish_reason"] as? String
    }

    /// `content` 既可能是字符串，也可能是 `[{"type":"text","text":"..."}]` 多模态数组。
    static func plainText(from field: Any?) -> String? {
        if let string = field as? String { return string }
        if let parts = field as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// 兼容 `{"error":{"message":...}}` 与 `{"error":"..."}` 两种网关错误格式。
    static func errorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            return String(describing: error)
        }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String, object["choices"] == nil { return message }
        return nil
    }

    /// 把「本该非流式却返回 SSE」的响应体拼回完整文本。
    /// 只要至少解析出一个 `data:` 事件就认定成功，避免把普通文本误判成 SSE。
    static func aggregateStreamedBody(
        _ data: Data
    ) -> (content: String, model: String?, inputTokens: Int?, outputTokens: Int?)? {
        guard let raw = String(data: data, encoding: .utf8), raw.contains("data:") else { return nil }
        var merged = ""
        var model: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var sawEvent = false

        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawEvent = true; continue }
            guard let chunk = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any]
            else { continue }
            sawEvent = true
            if model == nil { model = object["model"] as? String }
            if let usage = object["usage"] as? [String: Any] {
                inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
                outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
            }
            if let piece = extractContent(from: object) { merged += piece }
        }
        return sawEvent ? (merged, model, inputTokens, outputTokens) : nil
    }

    /// 截取响应体前若干字节用于错误提示。响应体不含凭据，可安全展示。
    static func bodyPreview(_ data: Data, limit: Int = 240) -> String {
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "<\(data.count) 字节非文本内容>" }
        let suffix = data.count > limit ? "…（共 \(data.count) 字节）" : ""
        return text + suffix
    }

    private nonisolated static func streamDelta(from data: String) -> String? {
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any]
        else {
            return nil
        }
        return plainText(from: delta["content"])
    }
}
