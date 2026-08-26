import Domain
import Foundation
import SecurityKit

/// Agent 单次回复的默认输出 token 上限。实际请求始终跟随用户为模型声明的
/// `ModelCapabilities`；这个值只用于没有能力元数据时的兼容默认值，不能作为硬上限。
public let auralisDefaultMaxOutputTokens = 16_000

/// OpenAI-compatible request timeout. 180 秒给本地中转和工具型模型留出足够的
/// 首 token / 长流式响应时间，同时仍能在网络确实不可用时及时返回。
public let auralisDefaultRequestTimeout: TimeInterval = 180

/// OpenAI 兼容接口默认上下文窗口。不再假设所有模型都是 256K：
/// 用户可在 Provider「高级设置」中按实际模型修改 maxContextTokens / maxOutputTokens。
public let auralisDefaultMaxContextTokens = 256_000

/// 原生工具调用的请求偏好。`required` 只在 Runtime 已确认需要真实工具时使用；
/// `named` 用于确定性 Workflow 强制当前步骤的唯一工具，避免模型跳到旁路工具。
/// Provider 协议在请求前确定，工具能力被拒绝时必须报告原协议错误。
public enum AIToolChoice: Codable, Hashable, Sendable {
    case auto
    case required
    case none
    case named(String)

    private enum CodingKeys: String, CodingKey {
        case mode
        case name
    }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "auto": self = .auto
            case "required": self = .required
            case "none": self = .none
            default: self = .named(value)
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self = .named(name)
        } else {
            switch try container.decode(String.self, forKey: .mode) {
            case "auto": self = .auto
            case "required": self = .required
            case "none": self = .none
            default: throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: container,
                debugDescription: "Unknown tool choice mode"
            )
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .required:
            var container = encoder.singleValueContainer()
            try container.encode("required")
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case let .named(name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Provider 原生托管工具。它们不是 Auralis 的 function tool：Provider 必须把
/// 这些值编码成自己的 server-side tool 协议，不能伪装成普通函数交给 ToolRuntime。
public enum AIHostedTool: String, Codable, Hashable, Sendable {
    case webSearch
    case webFetch
}

/// Provider-neutral response format.  A workflow asks for structured data
/// here; each Provider codec is responsible for projecting it onto its own
/// wire protocol.  Keeping this separate from function tools prevents a
/// deterministic transform from being modelled as a synthetic tool call.
public enum AIOutputFormat: Codable, Hashable, Sendable {
    case text
    case jsonObject
    case jsonSchema(name: String, schema: AIJSONValue, strict: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, name, schema, strict
    }

    private enum Kind: String, Codable {
        case text, jsonObject, jsonSchema
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text
        case .jsonObject:
            self = .jsonObject
        case .jsonSchema:
            self = .jsonSchema(
                name: try container.decode(String.self, forKey: .name),
                schema: try container.decode(AIJSONValue.self, forKey: .schema),
                strict: try container.decodeIfPresent(Bool.self, forKey: .strict) ?? true
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text:
            try container.encode(Kind.text, forKey: .kind)
        case .jsonObject:
            try container.encode(Kind.jsonObject, forKey: .kind)
        case let .jsonSchema(name, schema, strict):
            try container.encode(Kind.jsonSchema, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(schema, forKey: .schema)
            try container.encode(strict, forKey: .strict)
        }
    }
}

/// The protocol selected before a model run starts.  A run may use a
/// controlled compatibility retry, but it never silently mixes wire formats
/// inside one transcript.
public enum AIProviderToolMode: String, Codable, Hashable, Sendable {
    case none
    case openAIChat
    case openAIResponses
    case anthropicMessages
    case textualToolProtocol
}

/// Auralis 当前模型能力声明。上下文与输出均由 Provider / 用户配置决定，默认值
/// 只服务于旧配置迁移和未声明能力的兼容端点。
public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var maxContextTokens: Int
    /// Whether the context window is an endpoint/model fact. When false,
    /// callers must use their conservative byte budget instead of treating
    /// the default value as a precise provider limit.
    public var hasKnownContextWindow: Bool
    public var maxOutputTokens: Int
    public var supportsToolCalling: Bool
    public var supportsParallelTools: Bool
    public var supportsToolChoice: Bool
    public var supportsStrictSchema: Bool
    public var supportsStreaming: Bool
    public var supportsJSONMode: Bool
    public var supportsJSONSchema: Bool
    public var supportsHostedWebSearch: Bool
    public var supportsHostedWebFetch: Bool
    public var supportsReasoningMetadata: Bool
    public var toolMode: AIProviderToolMode

    public init(
        maxContextTokens: Int = 256_000,
        hasKnownContextWindow: Bool? = nil,
        maxOutputTokens: Int = auralisDefaultMaxOutputTokens,
        supportsToolCalling: Bool = false,
        supportsParallelTools: Bool = true,
        supportsToolChoice: Bool = false,
        supportsStrictSchema: Bool = false,
        supportsStreaming: Bool = true,
        supportsJSONMode: Bool = false,
        supportsJSONSchema: Bool = false,
        supportsHostedWebSearch: Bool = false,
        supportsHostedWebFetch: Bool = false,
        supportsReasoningMetadata: Bool = false,
        toolMode: AIProviderToolMode? = nil
    ) {
        self.maxContextTokens = max(4_096, maxContextTokens)
        self.hasKnownContextWindow = hasKnownContextWindow ?? (maxContextTokens != auralisDefaultMaxContextTokens)
        // 不再把输出硬性限制为「上下文的一半」：上下文与输出各自按用户配置取值，
        // 由服务端 / Provider 实际能力决定，Auralis 不自设比例限制。
        self.maxOutputTokens = max(512, maxOutputTokens)
        self.supportsToolCalling = supportsToolCalling
        self.supportsParallelTools = supportsParallelTools
        self.supportsToolChoice = supportsToolChoice
        self.supportsStrictSchema = supportsStrictSchema
        self.supportsStreaming = supportsStreaming
        self.supportsJSONMode = supportsJSONMode
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsHostedWebSearch = supportsHostedWebSearch
        self.supportsHostedWebFetch = supportsHostedWebFetch
        self.supportsReasoningMetadata = supportsReasoningMetadata
        self.toolMode = toolMode ?? (supportsToolCalling ? .openAIChat : .textualToolProtocol)
    }

    private enum CodingKeys: String, CodingKey {
        case maxContextTokens, hasKnownContextWindow, maxOutputTokens, supportsToolCalling
        case supportsParallelTools, supportsToolChoice, supportsStrictSchema
        case supportsStreaming, supportsJSONMode, supportsJSONSchema
        case supportsHostedWebSearch, supportsHostedWebFetch, supportsReasoningMetadata
        case toolMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxContextTokens: try container.decodeIfPresent(Int.self, forKey: .maxContextTokens) ?? 256_000,
            hasKnownContextWindow: try container.decodeIfPresent(Bool.self, forKey: .hasKnownContextWindow),
            maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? auralisDefaultMaxOutputTokens,
            supportsToolCalling: try container.decodeIfPresent(Bool.self, forKey: .supportsToolCalling) ?? false,
            supportsParallelTools: try container.decodeIfPresent(Bool.self, forKey: .supportsParallelTools) ?? true,
            supportsToolChoice: try container.decodeIfPresent(Bool.self, forKey: .supportsToolChoice) ?? false,
            supportsStrictSchema: try container.decodeIfPresent(Bool.self, forKey: .supportsStrictSchema) ?? false,
            supportsStreaming: try container.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? true,
            supportsJSONMode: try container.decodeIfPresent(Bool.self, forKey: .supportsJSONMode) ?? false,
            supportsJSONSchema: try container.decodeIfPresent(Bool.self, forKey: .supportsJSONSchema) ?? false,
            supportsHostedWebSearch: try container.decodeIfPresent(Bool.self, forKey: .supportsHostedWebSearch) ?? false,
            supportsHostedWebFetch: try container.decodeIfPresent(Bool.self, forKey: .supportsHostedWebFetch) ?? false,
            supportsReasoningMetadata: try container.decodeIfPresent(Bool.self, forKey: .supportsReasoningMetadata) ?? false,
            toolMode: try container.decodeIfPresent(AIProviderToolMode.self, forKey: .toolMode)
        )
    }

    public static let conservative = ModelCapabilities()
}

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
    /// 单次回复输出上限（沿用旧字段名，兼容旧配置）。
    public var maxTokens: Int
    /// 模型上下文窗口。默认 256K，用户可按实际模型修改；不参与累计任务预算。
    public var maxContextTokens: Int
    public var timeout: TimeInterval
    public var usesStreaming: Bool
    public var supportsJSONMode: Bool
    public var supportsJSONSchema: Bool
    public var supportsToolCalling: Bool
    /// 仅在同一 Base URL / path / model 的能力诊断确认模型目录可用后为 true。
    /// 这不是用户配置，也不参与旧配置的语义推断。
    public var hasVerifiedModelAvailability: Bool
    public var supportsParallelTools: Bool
    public var supportsToolChoice: Bool
    public var supportsStrictSchema: Bool
    public var supportsHostedWebSearch: Bool
    public var supportsHostedWebFetch: Bool
    public var supportsReasoningMetadata: Bool
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
        maxTokens: Int = auralisDefaultMaxOutputTokens,
        maxContextTokens: Int = auralisDefaultMaxContextTokens,
        timeout: TimeInterval = auralisDefaultRequestTimeout,
        usesStreaming: Bool = true,
        supportsJSONMode: Bool = false,
        supportsJSONSchema: Bool = false,
        supportsToolCalling: Bool = false,
        hasVerifiedModelAvailability: Bool = false,
        supportsParallelTools: Bool = true,
        supportsToolChoice: Bool = false,
        supportsStrictSchema: Bool = false,
        supportsHostedWebSearch: Bool = false,
        supportsHostedWebFetch: Bool = false,
        supportsReasoningMetadata: Bool = false,
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
        self.maxContextTokens = max(4_096, maxContextTokens)
        self.timeout = timeout
        self.usesStreaming = usesStreaming
        self.supportsJSONMode = supportsJSONMode
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsToolCalling = supportsToolCalling
        self.hasVerifiedModelAvailability = hasVerifiedModelAvailability
        self.supportsParallelTools = supportsParallelTools
        self.supportsToolChoice = supportsToolChoice
        self.supportsStrictSchema = supportsStrictSchema
        self.supportsHostedWebSearch = supportsHostedWebSearch
        self.supportsHostedWebFetch = supportsHostedWebFetch
        self.supportsReasoningMetadata = supportsReasoningMetadata
        self.supportsImageInput = supportsImageInput
    }

    /// 自定义解码：旧配置 / 旧备份缺少 `maxContextTokens` 时使用当前默认值，
    /// 保证已有用户升级后行为不变。
    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiPath, credentialID, model, customHeaders
        case organization, project, temperature, maxTokens, maxContextTokens
        case timeout, usesStreaming, supportsJSONMode, supportsJSONSchema
        case supportsToolCalling, hasVerifiedModelAvailability, supportsParallelTools, supportsToolChoice
        case supportsStrictSchema, supportsHostedWebSearch, supportsHostedWebFetch
        case supportsReasoningMetadata, supportsImageInput
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        apiPath = try container.decodeIfPresent(String.self, forKey: .apiPath) ?? "/v1/chat/completions"
        credentialID = try container.decodeIfPresent(CredentialID.self, forKey: .credentialID)
        model = try container.decode(String.self, forKey: .model)
        customHeaders = try container.decodeIfPresent(AIProviderHeaders.self, forKey: .customHeaders) ?? AIProviderHeaders()
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.4
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? auralisDefaultMaxOutputTokens
        maxContextTokens = max(4_096, try container.decodeIfPresent(Int.self, forKey: .maxContextTokens) ?? auralisDefaultMaxContextTokens)
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? auralisDefaultRequestTimeout
        usesStreaming = try container.decodeIfPresent(Bool.self, forKey: .usesStreaming) ?? true
        supportsJSONMode = try container.decodeIfPresent(Bool.self, forKey: .supportsJSONMode) ?? false
        supportsJSONSchema = try container.decodeIfPresent(Bool.self, forKey: .supportsJSONSchema) ?? false
        supportsToolCalling = try container.decodeIfPresent(Bool.self, forKey: .supportsToolCalling) ?? false
        hasVerifiedModelAvailability = try container.decodeIfPresent(Bool.self, forKey: .hasVerifiedModelAvailability) ?? false
        supportsParallelTools = try container.decodeIfPresent(Bool.self, forKey: .supportsParallelTools) ?? true
        // Arbitrary OpenAI-compatible gateways frequently accept but ignore
        // `tool_choice`.  Treat missing custom configuration as unsupported;
        // known provider presets opt in explicitly.
        supportsToolChoice = try container.decodeIfPresent(Bool.self, forKey: .supportsToolChoice) ?? false
        supportsStrictSchema = try container.decodeIfPresent(Bool.self, forKey: .supportsStrictSchema) ?? false
        supportsHostedWebSearch = try container.decodeIfPresent(Bool.self, forKey: .supportsHostedWebSearch) ?? false
        supportsHostedWebFetch = try container.decodeIfPresent(Bool.self, forKey: .supportsHostedWebFetch) ?? false
        supportsReasoningMetadata = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoningMetadata) ?? false
        supportsImageInput = try container.decodeIfPresent(Bool.self, forKey: .supportsImageInput) ?? false
    }

    /// 输出上限别名：与既有 `maxTokens` 同一数值，语义上独立于上下文窗口。
    public var maxOutputTokens: Int { maxTokens }
}

public struct AIPrivacyPermissions: Codable, Hashable, Sendable {
    public var allowsMetadata = true
    public var allowsLyrics = false
    public var allowsPlaybackHistory = false
    public var allowsFavoritesAndRatings = false
    public var allowsExternalDiscovery = false
    public var allowsFilePaths = false
    public init() {}

    /// 设置页隐私开关对应的 UserDefaults 键，与 SettingsView /
    /// MacSettingsWindow 的 @AppStorage 保持一致。
    public static let metadataDefaultsKey = "auralis.ai.allowsMetadata"
    public static let lyricsDefaultsKey = "auralis.ai.allowsLyrics"
    public static let historyDefaultsKey = "auralis.ai.allowsHistory"
    public static let favoritesAndRatingsDefaultsKey = "auralis.ai.allowsFavoritesAndRatings"

    /// 读取用户当前的隐私权限（UserDefaults）。键缺失时按 PrivacyModel 的默认值：
    /// 元数据默认允许（true）、歌词、播放历史与收藏/评分默认关闭（false）。
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
        if let value = defaults.object(forKey: favoritesAndRatingsDefaultsKey) as? Bool {
            permissions.allowsFavoritesAndRatings = value
        }
        return permissions
    }
}

/// 一次原生 function calling 调用（来自模型响应 `message.tool_calls`）。
/// `id` 即 OpenAI 的 tool_call_id，后续 `.tool` 角色消息必须携带同一 id 回灌。
public struct AIToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Provider decode 边界之后的 canonical 结构化参数。
    public let arguments: AIJSONValue

    public init(id: String, name: String, arguments: AIJSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// 兼容旧调用点。新 Provider codec 应在 decode 边界使用
    /// `init(id:name:rawArguments:)`，不要把 raw JSON 继续传入 ToolRuntime。
    @available(*, deprecated, message: "Decode raw JSON at the Provider boundary and pass AIJSONValue")
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = (try? AIJSONValue(jsonString: arguments)) ?? .string(arguments)
    }

    public init(id: String, name: String, rawArguments: String) throws {
        self.id = id
        self.name = name
        self.arguments = try AIJSONValue(jsonString: rawArguments)
    }

    public var rawArguments: String { arguments.jsonString }

    public var structuredArguments: AIJSONValue { arguments }

    public var argumentObject: [String: AIJSONValue]? {
        guard case let .object(value) = arguments else { return nil }
        return value
    }
}

/// Provider 原生联网工具返回的中立来源信息。
/// AIKit 不依赖 AgentKit，AgentKit 在 UI / ToolResult 边界将其映射为 WebSource。
public struct AIWebCitation: Codable, Hashable, Sendable {
    public let title: String
    public let url: URL
    public let snippet: String?
    public let publishedAt: String?
    public let backend: String?
    public let sourceType: String?

    public init(
        title: String,
        url: URL,
        snippet: String? = nil,
        publishedAt: String? = nil,
        backend: String? = nil,
        sourceType: String? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.backend = backend
        self.sourceType = sourceType
    }
}

/// 发送给模型的原生工具定义（OpenAI `tools` 数组中的 function 条目）。
/// `parameters` 以 JSON 字符串保存（JSON Schema），Provider 会原样嵌入请求体。
public struct AIToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String?
    public let strict: Bool

    public init(name: String, description: String, parametersJSON: String? = nil, strict: Bool = false) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.strict = strict
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
    /// Provider-neutral transcript. `messages` remains a compatibility
    /// projection for legacy codecs and callers.
    public let transcript: AITranscript
    public var messages: [AIMessage] { transcript.messages }
    public let temperature: Double
    public let maxTokens: Int
    /// 原生 function calling 的工具定义；为空则请求体不携带 `tools` 字段。
    public let tools: [AIToolDefinition]?
    /// 原生工具调用策略；为空则不携带 `tool_choice`，兼容更老的网关。
    public let toolChoice: AIToolChoice?
    /// Provider 原生托管工具。普通 function schema 不应承载这些工具。
    public let hostedTools: [AIHostedTool]?
    /// Provider-neutral output contract.  Nil and `.text` both mean an
    /// unconstrained natural-language response for compatibility.
    public let outputFormat: AIOutputFormat?

    private enum CodingKeys: String, CodingKey {
        case model, transcript, messages, temperature, maxTokens, tools, toolChoice, hostedTools, outputFormat
    }

    public init(
        model: String,
        messages: [AIMessage],
        temperature: Double = 0.4,
        maxTokens: Int = auralisDefaultMaxOutputTokens,
        tools: [AIToolDefinition]? = nil,
        toolChoice: AIToolChoice? = nil,
        hostedTools: [AIHostedTool]? = nil,
        outputFormat: AIOutputFormat? = nil
    ) {
        self.model = model
        self.transcript = AITranscript(messages: messages)
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.tools = tools
        self.toolChoice = toolChoice
        self.hostedTools = hostedTools
        self.outputFormat = outputFormat
    }

    public init(
        model: String,
        transcript: AITranscript,
        temperature: Double = 0.4,
        maxTokens: Int = auralisDefaultMaxOutputTokens,
        tools: [AIToolDefinition]? = nil,
        toolChoice: AIToolChoice? = nil,
        hostedTools: [AIHostedTool]? = nil,
        outputFormat: AIOutputFormat? = nil
    ) {
        self.model = model
        self.transcript = transcript
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.tools = tools
        self.toolChoice = toolChoice
        self.hostedTools = hostedTools
        self.outputFormat = outputFormat
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        if let transcript = try container.decodeIfPresent(AITranscript.self, forKey: .transcript) {
            self.transcript = transcript
        } else {
            self.transcript = AITranscript(messages: try container.decodeIfPresent([AIMessage].self, forKey: .messages) ?? [])
        }
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.4
        self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? auralisDefaultMaxOutputTokens
        self.tools = try container.decodeIfPresent([AIToolDefinition].self, forKey: .tools)
        self.toolChoice = try container.decodeIfPresent(AIToolChoice.self, forKey: .toolChoice)
        self.hostedTools = try container.decodeIfPresent([AIHostedTool].self, forKey: .hostedTools)
        self.outputFormat = try container.decodeIfPresent(AIOutputFormat.self, forKey: .outputFormat)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(hostedTools, forKey: .hostedTools)
        try container.encodeIfPresent(outputFormat, forKey: .outputFormat)
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
    /// Provider hosted web/search 返回的来源，不泄漏 Provider 私有 payload。
    public let webCitations: [AIWebCitation]?

    public init(
        model: String,
        content: String,
        reasoning: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        finishReason: String? = nil,
        toolCalls: [AIToolCall]? = nil,
        webCitations: [AIWebCitation]? = nil
    ) {
        self.model = model
        self.content = content
        self.reasoning = reasoning
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.webCitations = webCitations
    }
}

public enum AIProbeStatus: String, Codable, Hashable, Sendable {
    case passed
    /// A transient observation failure. It is health telemetry only and must
    /// never override a protocol's declared production capability.
    case degraded
    /// The endpoint explicitly rejected the requested capability. This is the
    /// only negative probe result allowed to change effective configuration.
    case failed
    case unavailable
    case notTested
}

/// Provider connectivity is not a single boolean.  These stages intentionally
/// distinguish an authenticated text endpoint from streaming and native tool
/// compatibility so callers can keep ordinary chat available when tools fail.
public struct AIProviderDiagnostics: Codable, Hashable, Sendable {
    public let modelCatalog: AIProbeStatus
    public let modelAvailability: AIProbeStatus
    public let textCompletion: AIProbeStatus
    public let streaming: AIProbeStatus
    public let nativeTools: AIProbeStatus
    public let toolChoice: AIProbeStatus
    public let jsonMode: AIProbeStatus
    public let jsonSchema: AIProbeStatus
    public let details: [String]

    public init(
        modelCatalog: AIProbeStatus = .notTested,
        modelAvailability: AIProbeStatus = .notTested,
        textCompletion: AIProbeStatus = .notTested,
        streaming: AIProbeStatus = .notTested,
        nativeTools: AIProbeStatus = .notTested,
        toolChoice: AIProbeStatus = .notTested,
        jsonMode: AIProbeStatus = .notTested,
        jsonSchema: AIProbeStatus = .notTested,
        details: [String] = []
    ) {
        self.modelCatalog = modelCatalog
        self.modelAvailability = modelAvailability
        self.textCompletion = textCompletion
        self.streaming = streaming
        self.nativeTools = nativeTools
        self.toolChoice = toolChoice
        self.jsonMode = jsonMode
        self.jsonSchema = jsonSchema
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case modelCatalog, modelAvailability, textCompletion, streaming
        case nativeTools, toolChoice, jsonMode, jsonSchema, details
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelCatalog = try container.decode(AIProbeStatus.self, forKey: .modelCatalog)
        modelAvailability = try container.decode(AIProbeStatus.self, forKey: .modelAvailability)
        textCompletion = try container.decode(AIProbeStatus.self, forKey: .textCompletion)
        streaming = try container.decodeIfPresent(AIProbeStatus.self, forKey: .streaming) ?? .notTested
        nativeTools = try container.decodeIfPresent(AIProbeStatus.self, forKey: .nativeTools) ?? .notTested
        toolChoice = try container.decodeIfPresent(AIProbeStatus.self, forKey: .toolChoice) ?? .notTested
        jsonMode = try container.decodeIfPresent(AIProbeStatus.self, forKey: .jsonMode) ?? .notTested
        jsonSchema = try container.decodeIfPresent(AIProbeStatus.self, forKey: .jsonSchema) ?? .notTested
        details = try container.decodeIfPresent([String].self, forKey: .details) ?? []
    }

    public var supportsOrdinaryChat: Bool {
        // 流式探测失败时 Provider 会以同一协议的非流式补全投影为事件流；
        // 因此普通聊天只依赖文本补全，不应被 SSE 兼容性一并禁用。
        textCompletion == .passed
    }

    /// Diagnostic probes are observations. A standard protocol declaration is
    /// only overridden by an explicit server-side rejection, never by EOF,
    /// timeout, 5xx or an incomplete streamed probe.
    public var streamingExplicitlyRejected: Bool { streaming == .failed }
    public var nativeToolsExplicitlyRejected: Bool { nativeTools == .failed }
}

public struct AIConnectionResult: Codable, Hashable, Sendable {
    public let latency: TimeInterval
    public let model: String
    public let message: String
    public let diagnostics: AIProviderDiagnostics?
    public init(
        latency: TimeInterval,
        model: String,
        message: String,
        diagnostics: AIProviderDiagnostics? = nil
    ) {
        self.latency = latency
        self.model = model
        self.message = message
        self.diagnostics = diagnostics
    }
}

public enum AIStreamEvent: Equatable, Sendable {
    case started(model: String)
    case delta(String)
    /// 流式过程中完成的原生工具调用（来自 Responses API 的
    /// `response.output_item.done` / Chat 的 `delta.tool_calls`）。
    /// 复用 `AIToolCall`，不新增重复 DTO。
    case toolCall(AIToolCall)
    /// Provider hosted web/search 返回的来源。
    case webCitations([AIWebCitation])
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
    /// 当前端点可确认的能力；未知时使用保守默认值。
    var capabilities: ModelCapabilities { get }
}

public extension AIProvider {
    var supportsToolCalling: Bool { false }
    var capabilities: ModelCapabilities {
        ModelCapabilities(supportsToolCalling: supportsToolCalling)
    }
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
