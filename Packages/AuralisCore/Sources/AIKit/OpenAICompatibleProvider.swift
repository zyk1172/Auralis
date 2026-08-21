import Domain
import Foundation
import SecurityKit

public enum AIProviderError: Error, Equatable, Sendable {
    case missingCredential
    case invalidEndpoint
    /// 当前配置选择了 Auralis 尚未实现的 Provider 协议，例如 Anthropic Messages。
    case unsupportedEndpointProtocol(String)
    /// 接口使用不安全的 HTTP 明文传输，且目标不在本机/局域网内（Bearer Key 会明文外发）。
    case insecureEndpoint
    case transport(String)
    case httpStatus(Int)
    /// 模型因输出上限停止，function-call arguments 不能被当成完整工具调用。
    /// 这不是网络瞬态故障；调用方必须缩小任务分片后重新请求。
    case outputTruncated
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
        case .missingCredential, .invalidEndpoint, .unsupportedEndpointProtocol, .insecureEndpoint, .outputTruncated:
            return false
        }
    }
}

extension AIProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            String(localized: "尚未配置 API Key，请先在设置中填写。", bundle: .module)
        case .invalidEndpoint:
            String(localized: "接口地址无效，请检查 Base URL 与 API 路径。", bundle: .module)
        case let .unsupportedEndpointProtocol(path):
            String(localized: "当前接口协议暂不支持：\(path)。Auralis 目前支持 Chat Completions 与 Responses API，请更换模型或协议。", bundle: .module)
        case .insecureEndpoint:
            String(localized: "接口使用不安全的 HTTP 明文传输，且目标不在本机/局域网内（API Key 会被明文发送）。请改用 HTTPS 地址。", bundle: .module)
        case .outputTruncated:
            String(localized: "模型输出达到长度上限，结构化工具参数可能未完成。请缩小当前批次后重试。", bundle: .module)
        case let .transport(message):
            String(localized: "网络请求失败：\(message)", bundle: .module)
        case let .httpStatus(status):
            switch status {
            case 401, 403:
                String(localized: "服务返回 HTTP \(status)：API Key 无效或权限不足，请检查设置中的 Key。", bundle: .module)
            case 404:
                String(localized: "服务返回 HTTP \(status)：接口路径错误，请检查 Base URL 是否已包含 /v1 等路径前缀。", bundle: .module)
            case 429:
                String(localized: "服务返回 HTTP 429：请求过于频繁被限流，已自动重试仍失败，请稍后重试。", bundle: .module)
            case 500...599:
                String(localized: "服务返回 HTTP \(status)：服务端或中转网关暂不可用（可能过载或维护中）。已自动重试仍失败，请稍后重试；若持续出现，请检查该 Base URL 对应服务的状态。", bundle: .module)
            default:
                String(localized: "服务返回 HTTP \(status)。", bundle: .module)
            }
        case let .malformedResponse(detail, retryable):
            retryable
                ? String(localized: "返回内容无法解析（已自动重试仍失败）：\(detail)", bundle: .module)
                : String(localized: "返回内容无法解析，该服务可能不兼容 OpenAI Chat Completions 格式：\(detail)", bundle: .module)
        }
    }
}

/// OpenAI 兼容实现：同时支持 Chat Completions（`/v1/chat/completions`）与
/// 原生 Responses API（`/v1/responses`），按 apiPath 自动判定、可用配置切换。
/// 适用于 OpenAI、DeepSeek、通义、Ollama、LM Studio 及各类中转网关。
/// API Key 只从 Keychain 读取，明文不会进入配置、日志或导出。
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

    public var supportsToolCalling: Bool {
        !Self.usesAnthropicMessagesAPI(apiPath: configuration.apiPath)
            && configuration.supportsToolCalling
    }
    public var capabilities: ModelCapabilities {
        // 不再把所有 OpenAI 兼容模型假设为 256K：上下文与输出都来自用户配置，
        // 默认仍为 256K / 16K 以维持旧行为，但 DeepSeek / OpenRouter / Ollama /
        // LM Studio 等端点可按实际模型修改。
        ModelCapabilities(
            maxContextTokens: configuration.maxContextTokens,
            maxOutputTokens: configuration.maxOutputTokens,
            supportsToolCalling: supportsToolCalling,
            supportsStreaming: configuration.usesStreaming,
            supportsJSONMode: configuration.supportsJSONMode,
            supportsJSONSchema: configuration.supportsJSONSchema
        )
    }

    public func testConnection() async throws -> AIConnectionResult {
        let started = Date()
        let response = try await complete(
            AICompletionRequest(
                model: configuration.model,
                messages: [AIMessage(role: .user, content: String(localized: "用一句话确认连接正常。", bundle: .module))],
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
        guard !usesAnthropicMessagesAPI else {
            throw AIProviderError.unsupportedEndpointProtocol(configuration.apiPath)
        }
        return try await performRequest(
            body: requestBody(request, stream: false),
            run: { try await session.data(for: $0) },
            transform: { data, _ in
                let response = if usesResponsesAPI {
                    try Self.parseResponsesCompletion(data: data, fallbackModel: request.model)
                } else {
                    try Self.parseCompletion(data: data, fallbackModel: request.model)
                }
                if response.finishReason == "length", response.toolCalls?.isEmpty == false {
                    throw AIProviderError.outputTruncated
                }
                return response
            }
        )
    }

    public func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        if usesAnthropicMessagesAPI {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AIProviderError.unsupportedEndpointProtocol(configuration.apiPath))
            }
        }
        if usesResponsesAPI {
            return responsesStream(request)
        }
        return chatStream(request)
    }

    /// Chat Completions 流式（SSE 按 `choices[0].delta` 解析）。
    ///
    /// 同时补全原生 tool calling：Chat 流式里 `choices[0].delta.tool_calls`
    /// 是**分片片段**（同一 `index` 的 id/name/arguments 分散在多个 chunk，
    /// arguments 需要跨 chunk 拼接），这里按 `index` 合并 fragments，
    /// 到流结束（`[DONE]`、`finish_reason` 或自然结束）时统一产出完整 `.toolCall`，
    /// 保证参数不会因为提前产出而被截断。
    private func chatStream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await performRequestBytes(body: requestBody(request, stream: true))
                    continuation.yield(.started(model: request.model))
                    var parser = SSEParser()
                    var toolCallFragments: [Int: ChatToolCallFragment] = [:]
                    var pendingLine = Data()
                    for try await byte in bytes {
                        pendingLine.append(byte)
                        guard byte == 0x0A else { continue }
                        // 以原始换行切分输入，而不是使用 `bytes.lines`。后者会吞掉
                        // 空行，无法区分 SSE 的事件边界；这里完整保留多段 data:。
                        for message in parser.append(pendingLine) {
                            if message.data == "[DONE]" {
                                Self.yieldAssembledToolCalls(fragments: toolCallFragments, continuation: continuation)
                                continuation.yield(.completed)
                                continuation.finish()
                                return
                            }
                            if let delta = Self.streamDelta(from: message.data) {
                                continuation.yield(.delta(delta))
                            }
                            if let usage = Self.streamUsage(from: message.data) {
                                continuation.yield(.usage(input: usage.input, output: usage.output))
                            }
                            for fragment in Self.streamToolCallFragments(from: message.data) {
                                if var existing = toolCallFragments[fragment.index] {
                                    if existing.id == nil { existing.id = fragment.id }
                                    if existing.name == nil { existing.name = fragment.name }
                                    existing.arguments += fragment.arguments
                                    toolCallFragments[fragment.index] = existing
                                } else {
                                    toolCallFragments[fragment.index] = fragment
                                }
                            }
                            // 一些 OpenAI 兼容网关会发送标准的 finish_reason，但不会
                            // 再补 [DONE] 或主动关闭 SSE 连接。若忽略它，最终文本虽然
                            // 已显示，AgentRunner 仍会一直等待，界面就会卡在“正在执行”。
                            if let finishReason = Self.streamFinishReason(message.data) {
                                if finishReason == "length" { throw AIProviderError.outputTruncated }
                                Self.yieldAssembledToolCalls(fragments: toolCallFragments, continuation: continuation)
                                continuation.yield(.completed)
                                continuation.finish()
                                return
                            }
                        }
                        pendingLine.removeAll(keepingCapacity: true)
                    }
                    // 末尾若没有空行，仍解析缓冲中的最后一个 SSE 事件。
                    if !pendingLine.isEmpty { _ = parser.append(pendingLine) }
                    for message in parser.finish() {
                        if message.data == "[DONE]" {
                            Self.yieldAssembledToolCalls(fragments: toolCallFragments, continuation: continuation)
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }
                        if let delta = Self.streamDelta(from: message.data) {
                            continuation.yield(.delta(delta))
                        }
                        if let usage = Self.streamUsage(from: message.data) {
                            continuation.yield(.usage(input: usage.input, output: usage.output))
                        }
                        for fragment in Self.streamToolCallFragments(from: message.data) {
                            if var existing = toolCallFragments[fragment.index] {
                                if existing.id == nil { existing.id = fragment.id }
                                if existing.name == nil { existing.name = fragment.name }
                                existing.arguments += fragment.arguments
                                toolCallFragments[fragment.index] = existing
                            } else {
                                toolCallFragments[fragment.index] = fragment
                            }
                        }
                        if let finishReason = Self.streamFinishReason(message.data) {
                            if finishReason == "length" { throw AIProviderError.outputTruncated }
                            Self.yieldAssembledToolCalls(fragments: toolCallFragments, continuation: continuation)
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }
                    }
                    // 网关不发 [DONE] 也视为正常结束（沿用既有行为），此时同样补发 tool calls。
                    Self.yieldAssembledToolCalls(fragments: toolCallFragments, continuation: continuation)
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 把按 index 合并好的 tool call fragments 按顺序产出 `.toolCall` 事件。
    private nonisolated static func yieldAssembledToolCalls(
        fragments: [Int: ChatToolCallFragment],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        for call in assembleToolCalls(from: fragments) {
            continuation.yield(.toolCall(call))
        }
    }

    /// Chat Completions 的最后一个 chunk 通常带 `finish_reason`。把它当作
    /// 与 `[DONE]` 等价的结束信号，兼容没有关闭长连接的转发服务。
    private static func streamFinishReason(_ data: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]]
        else { return nil }
        return choices.compactMap { choice in
            guard let reason = choice["finish_reason"] as? String else { return nil }
            return reason
        }.first
    }

    /// Responses API 以 response.status=incomplete + max_output_tokens 表达等价的截断。
    private static func responsesStreamIsTruncated(_ data: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let response = object["response"] as? [String: Any],
              response["status"] as? String == "incomplete",
              let details = response["incomplete_details"] as? [String: Any]
        else { return false }
        return details["reason"] as? String == "max_output_tokens"
    }

    /// Responses API 流式：SSE 事件按 `data: {"type":...}` 解析，
    /// 映射到现有 `AIStreamEvent`：
    /// - `response.output_text.delta` → `.delta`
    /// - `response.output_item.done`（function_call）→ `.toolCall`
    /// - `[DONE]` / `response.completed` / 流自然结束 → `.completed`
    /// - `response.failed` / `error` → 上抛
    private func responsesStream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await performRequestBytes(body: requestBody(request, stream: true))
                    continuation.yield(.started(model: request.model))
                    var parser = SSEParser()
                    var pendingLine = Data()
                    for try await byte in bytes {
                        pendingLine.append(byte)
                        guard byte == 0x0A else { continue }
                        // 保留真实 SSE 事件边界，支持 event:/id: 与多段 data:。
                        for message in parser.append(pendingLine) {
                            if message.data == "[DONE]" {
                                continuation.yield(.completed)
                                continuation.finish()
                                return
                            }
                            if Self.responsesStreamIsTruncated(message.data) { throw AIProviderError.outputTruncated }
                            let parsed = Self.parseResponsesStreamEvent(message.data)
                            switch parsed {
                            case let .text(text):
                                continuation.yield(.delta(text))
                            case let .toolCall(call):
                                continuation.yield(.toolCall(call))
                            case .done:
                                if let usage = Self.responsesUsage(from: message.data) {
                                    continuation.yield(.usage(input: usage.input, output: usage.output))
                                }
                                continuation.yield(.completed)
                                continuation.finish()
                                return
                            case let .failed(detail):
                                throw AIProviderError.malformedResponse(
                                    detail: String(localized: "服务返回错误：\(detail)", bundle: .module),
                                    retryable: false
                                )
                            case .ignore:
                                break
                            }
                        }
                        pendingLine.removeAll(keepingCapacity: true)
                    }
                    // 末尾若没有空行，仍处理最后一个完整 SSE 事件。
                    if !pendingLine.isEmpty { _ = parser.append(pendingLine) }
                    for message in parser.finish() {
                        if message.data == "[DONE]" {
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }
                        if Self.responsesStreamIsTruncated(message.data) { throw AIProviderError.outputTruncated }
                        let parsed = Self.parseResponsesStreamEvent(message.data)
                        switch parsed {
                        case let .text(text):
                            continuation.yield(.delta(text))
                        case let .toolCall(call):
                            continuation.yield(.toolCall(call))
                        case .done:
                            if let usage = Self.responsesUsage(from: message.data) {
                                continuation.yield(.usage(input: usage.input, output: usage.output))
                            }
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        case let .failed(detail):
                            throw AIProviderError.malformedResponse(
                                detail: String(localized: "服务返回错误：\(detail)", bundle: .module),
                                retryable: false
                            )
                        case .ignore:
                            break
                        }
                    }
                    // 网关不发 [DONE] / response.completed 也视为正常结束（沿用 Chat 路径行为）。
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
        var lastError: Error = AIProviderError.transport(String(localized: "请求失败", bundle: .module))
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

    /// 是否使用 OpenAI Responses API（POST /v1/responses）格式。
    ///
    /// 按 apiPath 自动判定：路径以 `/responses` 结尾（覆盖 baseURL 已含 `/v1`、
    /// apiPath 只写 `/responses` 的配置），或路径中包含 `/v1/responses`
    /// （覆盖网关带 `/api/v1/responses` 之类前缀路径的偏差）时走 Responses 格式；
    /// 否则保持 Chat Completions。
    static func usesResponsesAPI(apiPath: String) -> Bool {
        // lowercased：兼容 /V1/RESPONSES 等历史/自定义大小写配置。
        let path = apiPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return path.hasSuffix("/responses") || path.contains("/v1/responses")
    }

    /// 当前仅识别 Messages 协议用于阻止错误发送；Anthropic transport 尚未实现。
    static func usesAnthropicMessagesAPI(apiPath: String) -> Bool {
        let path = apiPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return path == "messages"
            || path == "/messages"
            || path.hasSuffix("/messages")
            || path.contains("/v1/messages")
    }

    private var usesResponsesAPI: Bool {
        Self.usesResponsesAPI(apiPath: configuration.apiPath)
    }

    private var usesAnthropicMessagesAPI: Bool {
        Self.usesAnthropicMessagesAPI(apiPath: configuration.apiPath)
    }

    /// 由 baseURL + apiPath 拼出完整接口地址。
    /// 两端斜杠统一 trim 后按 path segment 处理，覆盖：
    /// - `/v1/chat/completions` 与 `v1/chat/completions`（无前导斜杠的历史配置）；
    /// - baseURL 已含 `/v1`、`/v1/`、`/api/v1/`、`/V1/` 时，消除拼出的 `/v1/v1/...` 重叠段；
    /// - 结尾斜杠与重复斜杠（某些网关对 `//` 返回 503）。
    func endpoint() throws -> URL {
        var component = configuration.apiPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // baseURL 路径以 v1 结尾（覆盖 /v1、/v1/、/api/v1、/api/v1/、/V1/ 等）时，
        // 去掉 apiPath 开头的 v1，避免 https://host/v1/v1/chat/completions 这类地址。
        let basePath = configuration.baseURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let baseEndsInV1 = basePath == "v1" || basePath.hasSuffix("/v1")
        if baseEndsInV1 {
            let lowered = component.lowercased()
            if lowered == "v1" {
                component = ""
            } else if lowered.hasPrefix("v1/") {
                component.removeFirst(3) // 去掉 "v1/"
            }
        }

        let url: URL
        if component.isEmpty {
            url = configuration.baseURL
        } else {
            url = configuration.baseURL.appendingPathComponent(component)
        }
        guard let scheme = url.scheme?.lowercased() else { throw AIProviderError.invalidEndpoint }
        try Self.validate(scheme: scheme, host: url.host)
        return url
    }

    /// AI 接口 URL 安全策略：
    /// - https：允许（推荐，Ollama/LM Studio 等也支持 https 反代）；
    /// - http：只允许本机环回或私有局域网（Ollama 127.0.0.1:11434、LM Studio localhost 等），
    ///   防止 Bearer API Key 被明文发送到公网；
    /// - 其它 scheme：拒绝。
    private static func validate(scheme: String, host: String?) throws {
        switch scheme {
        case "https":
            return
        case "http":
            guard let host, isPrivateOrLoopbackHost(host) else {
                throw AIProviderError.insecureEndpoint
            }
        default:
            throw AIProviderError.invalidEndpoint
        }
    }

    /// 判断主机是否为本机环回或私有局域网（支持 localhost / 127.0.0.0/8 / 10.0.0.0/8 /
    /// 172.16.0.0/12 / 192.168.0.0/16 / ::1）。
    static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "localhost" || trimmed.hasSuffix(".localhost") || trimmed == "::1" || trimmed == "[::1]" {
            return true
        }
        guard let octets = parseIPv4Literal(trimmed) else { return false }
        let firstOctet = Int(octets[0])
        // 127.0.0.0/8 环回
        if firstOctet == 127 { return true }
        // 10.0.0.0/8
        if firstOctet == 10 { return true }
        // 172.16.0.0/12
        if firstOctet == 172, (16...31).contains(Int(octets[1])) {
            return true
        }
        // 192.168.0.0/16
        if firstOctet == 192, octets[1] == 168 {
            return true
        }
        return false
    }

    /// 只接受四段十进制 IPv4 literal，拒绝带数字前缀的普通 hostname。
    private static func parseIPv4Literal(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(UInt8(value))
        }
        return octets
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

    /// 请求体总入口：按 apiPath 自动选择 Responses 或 Chat Completions 格式。
    private func requestBody(_ request: AICompletionRequest, stream: Bool) -> [String: Any] {
        if usesResponsesAPI {
            return responsesRequestBody(request, stream: stream)
        }
        return chatRequestBody(request, stream: stream)
    }

    /// Chat Completions 请求体：`{model, messages, temperature, max_tokens, stream?, tools?}`。
    private func chatRequestBody(_ request: AICompletionRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(Self.encodeMessage),
            "temperature": request.temperature,
            "max_tokens": request.maxTokens,
        ]
        if stream { body["stream"] = true }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = Self.encodeTools(tools)
        }
        return body
    }

    /// Responses API 请求体：`{model, input:[...], temperature, max_output_tokens, stream?, tools?}`。
    /// `max_output_tokens` 使用请求的 maxTokens（默认 `auralisDefaultMaxOutputTokens`），
    /// 与 Chat 版的 `max_tokens` 对齐，避免长回答被截断。
    private func responsesRequestBody(_ request: AICompletionRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "input": request.messages.flatMap(Self.encodeResponsesInputItems),
            "temperature": request.temperature,
            "max_output_tokens": request.maxTokens,
        ]
        if stream { body["stream"] = true }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = Self.encodeResponsesTools(tools)
        }
        return body
    }

    /// 工具定义编码（Chat Completions 版）：
    /// `{"type":"function","function":{name,description,parameters}}`。
    private static func encodeTools(_ tools: [AIToolDefinition]) -> [[String: Any]] {
        tools.map { tool -> [String: Any] in
            var function: [String: Any] = ["name": tool.name, "description": tool.description]
            if let json = tool.parametersJSON,
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                function["parameters"] = object
            }
            return ["type": "function", "function": function]
        }
    }

    /// Responses API 工具定义编码：字段**平铺在顶层**。
    ///
    /// 注意：OpenAI 原生 Responses API 的工具形状与 Chat Completions 不同——
    /// Chat 是 `{"type":"function","function":{name,description,parameters}}`，
    /// Responses 是 `{"type":"function","name":...,"description":...,"parameters":...}`，
    /// **没有嵌套的 `function` 键**。用 Chat 形状发给 /v1/responses 时服务端会忽略
    /// 工具定义，模型因此永远不会返回 function_call，表现为「调不动工具」。
    private static func encodeResponsesTools(_ tools: [AIToolDefinition]) -> [[String: Any]] {
        tools.map { tool -> [String: Any] in
            var item: [String: Any] = [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
            ]
            if let json = tool.parametersJSON,
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                item["parameters"] = object
            }
            return item
        }
    }

    /// 按角色编码 Chat 消息：`.tool` 携带 tool_call_id / name；`.assistant` 携带原生 tool_calls。
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

    /// 按 Responses API 规范编码 input items（一个 AIMessage 可能展开成多个顶层条目）：
    /// - user/system → `{"type":"message","role":...,"content":[{"type":"input_text","text":...}]}`
    /// - assistant 纯文本 → `{"type":"message","role":"assistant","content":[{"type":"output_text","text":...}]}`
    /// - assistant 工具调用 → **顶层** `{"type":"function_call","call_id":...,"name":...,"arguments":"{...}"}`
    ///   （必须与 message 条目平级，不能嵌进 content 数组——否则多轮工具调用时
    ///   Responses API 会因结构非法返回 400，表现为「只能调很少轮次」）
    /// - tool → `{"type":"function_call_output","call_id":...,"output":"<文本>"}`
    ///
    /// `function_call_output.output` 必须是字符串；调用方若持有结构化结果，
    /// 应在构造 `AIMessage` 时用 JSON 序列化成字符串传入。
    static func encodeResponsesInputItems(_ message: AIMessage) -> [[String: Any]] {
        switch message.role {
        case .user, .system:
            return [
                [
                    "type": "message",
                    "role": message.role.rawValue,
                    "content": [["type": "input_text", "text": message.content]],
                ],
            ]
        case .assistant:
            var items: [[String: Any]] = []
            if !message.content.isEmpty {
                items.append(
                    [
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": message.content]],
                    ]
                )
            }
            if let calls = message.toolCalls, !calls.isEmpty {
                items.append(contentsOf: calls.map { call -> [String: Any] in
                    [
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.arguments,
                    ]
                })
            }
            return items
        case .tool:
            return [
                [
                    "type": "function_call_output",
                    "call_id": message.toolCallID ?? "",
                    "output": message.content,
                ],
            ]
        }
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
            throw AIProviderError.malformedResponse(detail: String(localized: "服务返回了空响应体", bundle: .module), retryable: true)
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
                throw AIProviderError.malformedResponse(detail: String(localized: "服务返回错误：\(message)", bundle: .module), retryable: false)
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
        guard !text.isEmpty else { return String(localized: "<\(data.count) 字节非文本内容>", bundle: .module) }
        let suffix = data.count > limit ? String(localized: "…（共 \(data.count) 字节）", bundle: .module) : ""
        return text + suffix
    }

    // MARK: - Responses API (POST /v1/responses)

    /// Responses SSE 单事件解析结果。与现有 stream 事件模型对齐：
    /// `.text` → `.delta`、`.toolCall` → `.toolCall`、`.done` → `.completed`、
    /// `.failed` → 上抛错误、`.ignore` → 跳过。
    enum ResponsesStreamParseResult: Equatable, Sendable {
        case text(String)
        case toolCall(AIToolCall)
        case done
        case failed(String)
        case ignore
    }

    /// 宽容解析 Responses API 非流式响应：
    /// 1. 空响应体 → 判为可重试；
    /// 2. `{object:"response", output:[...], usage, status}` → 正常路径：
    ///    文本 = 拼接 output 中 type=="message" 的 content[].text；
    ///    toolCalls = output 中 type=="function_call"；
    ///    finishReason = status 映射（completed→"stop" 等）；
    /// 3. 请求的是非流式，服务端却回了 SSE（`data: {...}`）→ 就地把 delta 拼起来；
    /// 4. HTTP 200 但 body 里塞了 `{"error": {...}}` → 把服务端原文透出；
    /// 5. 其余（HTML 错误页、截断 JSON）→ 附响应体前 240 字节，便于定位。
    static func parseResponsesCompletion(data: Data, fallbackModel: String) throws -> AICompletionResponse {
        guard !data.isEmpty else {
            throw AIProviderError.malformedResponse(detail: String(localized: "服务返回了空响应体", bundle: .module), retryable: true)
        }

        let jsonObject = try? JSONSerialization.jsonObject(with: data)

        if let object = jsonObject as? [String: Any] {
            if let content = responsesText(from: object) {
                let usage = object["usage"] as? [String: Any]
                return AICompletionResponse(
                    model: object["model"] as? String ?? fallbackModel,
                    content: content,
                    reasoning: responsesReasoning(from: object),
                    inputTokens: (usage?["input_tokens"] as? Int) ?? (usage?["prompt_tokens"] as? Int),
                    outputTokens: (usage?["output_tokens"] as? Int) ?? (usage?["completion_tokens"] as? Int),
                    finishReason: finishReason(fromResponses: object),
                    toolCalls: responsesToolCalls(from: object)
                )
            }
            if let message = errorMessage(from: object) {
                // 网关把错误塞进 200 响应体：这是服务端的确定性回答，重试无益。
                throw AIProviderError.malformedResponse(detail: String(localized: "服务返回错误：\(message)", bundle: .module), retryable: false)
            }
        }

        // 非流式请求却收到 SSE：把各 chunk 的 delta 拼成完整文本，直接当成功返回。
        if let aggregated = aggregateResponsesStreamedBody(data) {
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

    /// 从 Responses 响应的 `output` 数组提取用户可见文本：
    /// 只拼接 type == "message" 的 content[].text（不含 reasoning 条目，避免泄露思考链）。
    /// 结构不认识时返回 nil（用于判定格式兼容），output 为空或只有 function_call 时返回 ""。
    static func responsesText(from object: [String: Any]) -> String? {
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for item in output where (item["type"] as? String) == "message" {
            if let content = item["content"] as? String {
                if !content.isEmpty { parts.append(content) }
            } else if let content = item["content"] as? [[String: Any]] {
                parts.append(contentsOf: content.compactMap { $0["text"] as? String })
            }
        }
        return parts.joined()
    }

    /// 提取 Responses API 的 reasoning 条目（type == "reasoning"）文本，
    /// 仅内部保存，绝不展示给用户（与 Chat 版 `reasoning_content` 语义一致）。
    static func responsesReasoning(from object: [String: Any]) -> String? {
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for item in output where (item["type"] as? String) == "reasoning" {
            if let summary = item["summary"] as? [[String: Any]] {
                parts.append(contentsOf: summary.compactMap { $0["text"] as? String })
            }
            if let content = item["content"] as? [[String: Any]] {
                parts.append(contentsOf: content.compactMap { $0["text"] as? String })
            }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// 解析 Responses 响应 `output` 中的 function_call 条目。
    static func responsesToolCalls(from object: [String: Any]) -> [AIToolCall]? {
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        let parsed = output.compactMap { item -> AIToolCall? in
            guard (item["type"] as? String) == "function_call",
                  let id = item["call_id"] as? String,
                  let name = item["name"] as? String
            else { return nil }
            return AIToolCall(id: id, name: name, arguments: stringify(item["arguments"]) ?? "")
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// Responses 的 finishReason：优先读网关透传的 `finish_reason`，
    /// 否则把 `status` 映射为 Chat 风格（completed→"stop"、超长截断→"length" 等）。
    static func finishReason(fromResponses object: [String: Any]) -> String? {
        if let direct = object["finish_reason"] as? String { return direct }
        guard let status = object["status"] as? String else { return nil }
        switch status {
        case "completed":
            return "stop"
        case "incomplete":
            if let details = object["incomplete_details"] as? [String: Any],
               (details["reason"] as? String) == "max_output_tokens" {
                return "length"
            }
            return "incomplete"
        case "failed":
            return "fail"
        case "cancelled":
            return "cancelled"
        default:
            return status
        }
    }

    /// 把任意值转成 JSON 字符串：已是字符串原样返回；字典/数组等结构化值序列化。
    /// 用于宽容处理网关把 `function_call.arguments` / `function_call_output.output`
    /// 直接返回为对象而非字符串的偏差。
    static func stringify(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解析一条 Responses SSE 事件（`data: {"type":...}`）。
    /// 覆盖 `response.output_text.delta` / `response.output_item.done` /
    /// `response.completed` / `response.incomplete` / `response.failed` / `error`；
    /// 无 `type` 但带 `delta` 字段的网关偏差也兜住。
    static func parseResponsesStreamEvent(_ data: String) -> ResponsesStreamParseResult {
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return .ignore }

        switch object["type"] as? String {
        case "response.output_text.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty { return .text(delta) }
            if let text = object["text"] as? String, !text.isEmpty { return .text(text) }
            return .ignore
        case "response.output_item.done":
            // OpenAI 原生 Responses API 的流式事件把「完整条目」放在 `item` 字段
            // （`{"type":"response.output_item.done","item":{...}}`），不是 `output`。
            // 此前只读 `output`，真实 API 的 function_call 永远解析不出来，
            // 工具调用在流式模式下被整体丢弃 → Agent 只输出文字「我在调用」却没任何动作。
            // 个别网关/旧实现用 `output`，这里两者都兼容（`item` 优先）。
            let item = (object["item"] as? [String: Any]) ?? (object["output"] as? [String: Any])
            guard let item,
                  (item["type"] as? String) == "function_call",
                  let id = item["call_id"] as? String,
                  let name = item["name"] as? String
            else { return .ignore }
            return .toolCall(AIToolCall(id: id, name: name, arguments: stringify(item["arguments"]) ?? ""))
        case "response.completed", "response.incomplete":
            return .done
        case "response.failed":
            return .failed(responseErrorMessage(from: object) ?? String(localized: "响应流失败", bundle: .module))
        case "error":
            return .failed(responseErrorMessage(from: object) ?? String(localized: "未知错误", bundle: .module))
        case let type? where type.hasPrefix("response."):
            // 其余所有语义事件都不是正文，统一忽略，避免掉进下面的默认兜底：
            // - response.reasoning_text.delta / reasoning_summary_text.delta 字段也叫 delta，
            //   是思考链，绝不能输出给用户；
            // - response.function_call_arguments.delta 字段也叫 delta，是工具参数的
            //   增量分片，若当正文输出会把参数 JSON 打在聊天里（工具调用仍会因
            //   output_item.done 解析失败而丢失）；
            // - response.output_item.added / content_part.* / output_text.done 等
            //   同样不是用户正文（正文已由 output_text.delta 增量覆盖）。
            return .ignore
        default:
            // 容错：无 type 字段的网关偏差，看到 delta 就当作文本增量。
            if let delta = object["delta"] as? String, !delta.isEmpty { return .text(delta) }
            return .ignore
        }
    }

    /// 提取 Responses SSE 错误事件的错误文本：
    /// 兼容 `{"error":{...}}`、`{"error":"..."}` 与 `response.failed` 的
    /// `{"response":{"error":{...}}}` 嵌套结构。
    static func responseErrorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let code = error["code"] as? String { return code }
            return String(describing: error)
        }
        if let error = object["error"] as? String { return error }
        if let response = object["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            return String(describing: error)
        }
        return nil
    }

    /// 把「本该非流式却返回 Responses SSE」的响应体拼回完整文本。
    /// 只要至少解析出一个 `data:` 事件就认定成功，避免把普通文本误判成 SSE。
    static func aggregateResponsesStreamedBody(
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
            // 多数网关把 model / usage 嵌在 `response` 对象里，个别直接放在顶层，都兜住。
            let response = object["response"] as? [String: Any]
            if model == nil {
                model = response?["model"] as? String ?? object["model"] as? String
            }
            if let usage = (response?["usage"] as? [String: Any]) ?? (object["usage"] as? [String: Any]) {
                inputTokens = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int) ?? inputTokens
                outputTokens = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int) ?? outputTokens
            }
            switch parseResponsesStreamEvent(payload) {
            case let .text(piece):
                merged += piece
            default:
                break
            }
        }
        return sawEvent ? (merged, model, inputTokens, outputTokens) : nil
    }

    /// Chat Completions 流式 tool_calls 的分片片段。
    /// 同一 `index` 的多个 chunk 合并成一个 `ChatToolCallFragment`：
    /// id / name 通常只在首个 chunk 出现，arguments 需要跨 chunk 拼接。
    struct ChatToolCallFragment: Sendable {
        let index: Int
        var id: String?
        var name: String?
        var arguments: String

        init(index: Int, id: String? = nil, name: String? = nil, arguments: String = "") {
            self.index = index
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    /// 从 Chat Completions 流式 chunk 提取 usage（多数网关在最后一个 chunk 带 `usage`）。
    nonisolated static func streamUsage(from data: String) -> (input: Int, output: Int)? {
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let usage = object["usage"] as? [String: Any]
        else { return nil }
        let input = usage["prompt_tokens"] as? Int
        let output = usage["completion_tokens"] as? Int
        guard input != nil || output != nil else { return nil }
        return (input ?? 0, output ?? 0)
    }

    /// 从 Responses 流式事件提取 usage（挂在 `response.usage` 下）。
    nonisolated static func responsesUsage(from data: String) -> (input: Int, output: Int)? {
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let response = object["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any]
        else { return nil }
        let input = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int)
        let output = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int)
        guard input != nil || output != nil else { return nil }
        return (input ?? 0, output ?? 0)
    }

    /// 解析一条 Chat Completions SSE chunk 里的 `choices[0].delta.tool_calls` 分片。
    /// 结构不认识 / 没有 tool_calls 时返回空数组。
    nonisolated static func streamToolCallFragments(from data: String) -> [ChatToolCallFragment] {
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let rawCalls = delta["tool_calls"] as? [[String: Any]]
        else { return [] }
        return rawCalls.compactMap { raw -> ChatToolCallFragment? in
            guard let index = raw["index"] as? Int else { return nil }
            let id = raw["id"] as? String
            var name: String?
            var arguments = ""
            if let function = raw["function"] as? [String: Any] {
                name = function["name"] as? String
                if let args = function["arguments"] as? String {
                    arguments = args
                } else if let args = function["arguments"] {
                    arguments = stringify(args) ?? ""
                }
            }
            return ChatToolCallFragment(index: index, id: id, name: name, arguments: arguments)
        }
    }

    /// 把按 index 合并好的 fragments 组装成完整的 `AIToolCall`（按 index 升序）。
    /// 缺少 id 或 name 的 fragment（异常网关）直接丢弃，不产出半成品调用。
    nonisolated static func assembleToolCalls(from fragments: [Int: ChatToolCallFragment]) -> [AIToolCall] {
        fragments.keys.sorted().compactMap { index -> AIToolCall? in
            guard let fragment = fragments[index],
                  let id = fragment.id,
                  let name = fragment.name
            else { return nil }
            return AIToolCall(id: id, name: name, arguments: fragment.arguments)
        }
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
