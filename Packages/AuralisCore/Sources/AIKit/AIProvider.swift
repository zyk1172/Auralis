import Domain
import Foundation
import SecurityKit

public enum AIProviderHeaderValue: Codable, Hashable, Sendable {
    case literal(String)
    case credential(CredentialID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case credentialID
    }

    private enum Kind: String, Codable {
        case literal
        case credential
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .literal:
            self = .literal(try container.decode(String.self, forKey: .value))
        case .credential:
            self = .credential(try container.decode(CredentialID.self, forKey: .credentialID))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .literal(value):
            try container.encode(Kind.literal, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .credential(credentialID):
            try container.encode(Kind.credential, forKey: .kind)
            try container.encode(credentialID, forKey: .credentialID)
        }
    }
}

public enum AIProviderHeaderError: Error, Equatable, Sendable {
    case invalidName(String)
    case duplicateName(String)
    case invalidLiteralValue(header: String)
    case invalidCredentialReference(header: String)
    case sensitiveHeaderRequiresCredential(String)
}

extension AIProviderHeaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            "The custom header name is invalid: \(name)."
        case let .duplicateName(name):
            "The custom header is duplicated with different casing: \(name)."
        case let .invalidLiteralValue(header):
            "The custom header contains an invalid literal value: \(header)."
        case let .invalidCredentialReference(header):
            "The custom header has an invalid credential reference: \(header)."
        case let .sensitiveHeaderRequiresCredential(header):
            "The sensitive custom header must use a credential reference: \(header)."
        }
    }
}

/// A validated, Codable collection of provider headers. Sensitive values are
/// represented only by `CredentialID`; their plaintext never enters a provider
/// configuration, archive, or export.
public struct AIProviderHeaders: Codable, Hashable, Sendable {
    private var storage: [String: AIProviderHeaderValue]

    public init() {
        storage = [:]
    }

    public init(_ values: [String: AIProviderHeaderValue]) throws {
        storage = [:]
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            try set(value, for: name, replacingExisting: false)
        }
    }

    public var values: [String: AIProviderHeaderValue] { storage }

    public subscript(name: String) -> AIProviderHeaderValue? {
        let normalized = Self.normalized(name)
        return storage.first { Self.normalized($0.key) == normalized }?.value
    }

    public mutating func set(_ value: AIProviderHeaderValue, for name: String) throws {
        try set(value, for: name, replacingExisting: true)
    }

    public mutating func removeValue(for name: String) {
        let normalized = Self.normalized(name)
        guard let existing = storage.keys.first(where: { Self.normalized($0) == normalized }) else {
            return
        }
        storage.removeValue(forKey: existing)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try AIProviderHeaders(container.decode([String: AIProviderHeaderValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    public static func isSensitive(name: String) -> Bool {
        let value = normalized(name)
        return value == "authorization"
            || value == "proxyauthorization"
            || value == "cookie"
            || value == "setcookie"
            || value.contains("authorization")
            || value.contains("apikey")
            || value.hasSuffix("token")
            || value.contains("secret")
            || value.contains("password")
            || value.contains("credential")
    }

    private mutating func set(
        _ value: AIProviderHeaderValue,
        for name: String,
        replacingExisting: Bool
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.unicodeScalars.allSatisfy(Self.isHTTPTokenScalar) else {
            throw AIProviderHeaderError.invalidName(name)
        }

        switch value {
        case let .literal(literal):
            guard !Self.isSensitive(name: trimmedName) else {
                throw AIProviderHeaderError.sensitiveHeaderRequiresCredential(trimmedName)
            }
            guard !literal.unicodeScalars.contains(where: {
                $0.value == 0 || $0.value == 10 || $0.value == 13
            }) else {
                throw AIProviderHeaderError.invalidLiteralValue(header: trimmedName)
            }
        case let .credential(credentialID):
            guard !credentialID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !credentialID.rawValue.contains("\0")
            else {
                throw AIProviderHeaderError.invalidCredentialReference(header: trimmedName)
            }
        }

        let normalizedName = Self.normalized(trimmedName)
        if let existing = storage.keys.first(where: { Self.normalized($0) == normalizedName }) {
            guard replacingExisting else { throw AIProviderHeaderError.duplicateName(trimmedName) }
            storage.removeValue(forKey: existing)
        }
        storage[trimmedName] = value
    }

    private static func normalized(_ name: String) -> String {
        name.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            switch scalar.value {
            case 65...90:
                UnicodeScalar(scalar.value + 32)
            case 97...122, 48...57:
                scalar
            default:
                nil
            }
        }.map(String.init).joined()
    }

    private static func isHTTPTokenScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122,
             33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            true
        default:
            false
        }
    }
}

public struct AIProviderConfiguration: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var apiPath: String
    public var credentialID: CredentialID?
    public var model: String
    public var customHeaders: AIProviderHeaders
    public var organization: String?
    public var project: String?
    public var temperature: Double
    public var maxTokens: Int
    public var timeout: TimeInterval
    public var usesStreaming: Bool
    public var supportsJSONMode: Bool
    public var supportsJSONSchema: Bool
    public var supportsToolCalling: Bool
    public var supportsImageInput: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        apiPath: String = "/v1/chat/completions",
        credentialID: CredentialID? = nil,
        model: String,
        customHeaders: AIProviderHeaders = AIProviderHeaders(),
        organization: String? = nil,
        project: String? = nil,
        temperature: Double = 0.4,
        maxTokens: Int = 1_200,
        timeout: TimeInterval = 60,
        usesStreaming: Bool = true,
        supportsJSONMode: Bool = false,
        supportsJSONSchema: Bool = false,
        supportsToolCalling: Bool = false,
        supportsImageInput: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiPath = apiPath
        self.credentialID = credentialID
        self.model = model
        self.customHeaders = customHeaders
        self.organization = organization
        self.project = project
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeout = timeout
        self.usesStreaming = usesStreaming
        self.supportsJSONMode = supportsJSONMode
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsToolCalling = supportsToolCalling
        self.supportsImageInput = supportsImageInput
    }
}

public struct AIPrivacyPermissions: Codable, Hashable, Sendable {
    public var allowsMetadata = true
    public var allowsLyrics = false
    public var allowsPlaybackHistory = false
    public var allowsFavoritesAndRatings = false
    public var allowsExternalDiscovery = false
    public var allowsFilePaths = false
    public init() {}

    /// 设置页三个隐私开关对应的 UserDefaults 键，与 SettingsView /
    /// MacSettingsWindow 的 @AppStorage 保持一致。
    public static let metadataDefaultsKey = "auralis.ai.allowsMetadata"
    public static let lyricsDefaultsKey = "auralis.ai.allowsLyrics"
    public static let historyDefaultsKey = "auralis.ai.allowsHistory"

    /// 读取用户当前的隐私权限（UserDefaults）。键缺失时按 PrivacyModel 的默认值：
    /// 元数据默认允许（true）、歌词与播放历史默认关闭（false）。
    /// 用 `object(forKey:)` 区分「从未设置」与「显式 false」，
    /// 避免 `bool(forKey:)` 把缺失键一律当成 false 而覆盖元数据的默认 true。
    public static func current(defaults: UserDefaults = .standard) -> AIPrivacyPermissions {
        var permissions = AIPrivacyPermissions()
        if let value = defaults.object(forKey: metadataDefaultsKey) as? Bool {
            permissions.allowsMetadata = value
        }
        if let value = defaults.object(forKey: lyricsDefaultsKey) as? Bool {
            permissions.allowsLyrics = value
        }
        if let value = defaults.object(forKey: historyDefaultsKey) as? Bool {
            permissions.allowsPlaybackHistory = value
        }
        return permissions
    }
}

/// 一次原生 function calling 调用（来自模型响应 `message.tool_calls`）。
/// `id` 即 OpenAI 的 tool_call_id，后续 `.tool` 角色消息必须携带同一 id 回灌。
public struct AIToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// 参数 JSON 字符串（如 `{"trackID":"server:1"}`），由调用方自行解析。
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 发送给模型的原生工具定义（OpenAI `tools` 数组中的 function 条目）。
/// `parameters` 以 JSON 字符串保存（JSON Schema），Provider 会原样嵌入请求体。
public struct AIToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String?

    public init(name: String, description: String, parametersJSON: String? = nil) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct AIMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Hashable, Sendable { case system, user, assistant, tool }
    public let id: UUID
    public let role: Role
    public let content: String
    /// `.tool` 角色消息对应的 tool_call_id；原生 function calling 下必须与
    /// assistant 消息里的某个 tool call 精确匹配，否则 OpenAI 兼容 API 会拒绝上下文。
    public let toolCallID: String?
    /// `.assistant` 角色消息携带的原生 tool calls（模型要求执行的工具）。
    public let toolCalls: [AIToolCall]?
    /// `.tool` 角色消息可选的函数名（部分服务要求回传）。
    public let name: String?

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCallID: String? = nil,
        toolCalls: [AIToolCall]? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.name = name
    }
}

public struct AICompletionRequest: Codable, Hashable, Sendable {
    public let model: String
    public let messages: [AIMessage]
    public let temperature: Double
    public let maxTokens: Int
    /// 原生 function calling 的工具定义；为空则请求体不携带 `tools` 字段。
    public let tools: [AIToolDefinition]?

    public init(
        model: String,
        messages: [AIMessage],
        temperature: Double = 0.4,
        maxTokens: Int = 1_200,
        tools: [AIToolDefinition]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.tools = tools
    }
}

public struct AICompletionResponse: Codable, Hashable, Sendable {
    public let model: String
    /// 用户可见的最终回答（绝不包含思考链）。
    public let content: String
    /// 模型思考链（reasoning_content）——仅内部保存，绝不展示给用户。
    public let reasoning: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// `choices[0].finish_reason`（如 "stop" / "tool_calls"）。原生 function calling 下，
    /// `tool_calls` 表示模型要求 App 执行工具后继续，而不是任务完成。
    public let finishReason: String?
    /// 模型要求的原生工具调用；非空时表示需要执行工具并回灌结果。
    public let toolCalls: [AIToolCall]?

    public init(
        model: String,
        content: String,
        reasoning: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        finishReason: String? = nil,
        toolCalls: [AIToolCall]? = nil
    ) {
        self.model = model
        self.content = content
        self.reasoning = reasoning
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
        self.toolCalls = toolCalls
    }
}

public struct AIConnectionResult: Codable, Hashable, Sendable {
    public let latency: TimeInterval
    public let model: String
    public let message: String
    public init(latency: TimeInterval, model: String, message: String) {
        self.latency = latency
        self.model = model
        self.message = message
    }
}

public enum AIStreamEvent: Equatable, Sendable {
    case started(model: String)
    case delta(String)
    case completed
    case usage(input: Int, output: Int)
}

public protocol AIProvider: Sendable {
    func testConnection() async throws -> AIConnectionResult
    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// 是否支持原生 function calling（tools / tool_calls / tool 消息）。
    /// 默认 false：保持文本 ACTION 协议行为；支持方（OpenAICompatibleProvider 等）
    /// 自行覆盖为 true，AgentLoop 才会启用原生 tool calling。
    var supportsToolCalling: Bool { get }
}

public extension AIProvider {
    var supportsToolCalling: Bool { false }
}

public struct MockAIProvider: AIProvider {
    public let model: String
    public init(model: String = "auralis-test-curator") { self.model = model }

    public func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0.012, model: model, message: "Test provider is ready")
    }

    public func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        AICompletionResponse(model: request.model, content: "已从本地测试音乐库生成策展结果。", inputTokens: 42, outputTokens: 18)
    }

    public func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(model: request.model))
            continuation.yield(.delta("理解需求 → 搜索音乐库 → 筛选候选 → 安排顺序"))
            continuation.yield(.completed)
            continuation.finish()
        }
    }
}
