import AIKit
import Domain
import Foundation
import SecurityKit

/// AI 接口协议：把 `apiPath` 从「用户手填字符串」正式类型化。
/// 底层仍保存完整 `apiPath`（UserDefaults key 不变，备份/历史配置不受影响），
/// 这里只负责设置页的选择与展示。
enum AIEndpointMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chatCompletions
    case responses
    case anthropicMessages
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatCompletions:
            return String(localized: "OpenAI 兼容", bundle: .module)
        case .responses:
            return String(localized: "OpenAI 原生", bundle: .module)
        case .anthropicMessages:
            return String(localized: "Anthropic", bundle: .module)
        case .custom:
            return String(localized: "自定义", bundle: .module)
        }
    }

    var subtitle: String {
        switch self {
        case .chatCompletions:
            return "Chat Completions"
        case .responses:
            return "Responses API"
        case .anthropicMessages:
            return String(localized: "Messages API（暂不支持）", bundle: .module)
        case .custom:
            return String(localized: "自定义 API 路径", bundle: .module)
        }
    }

    /// 用户说的「v1 后面的后缀」。
    var suffix: String? {
        switch self {
        case .chatCompletions:
            return "chat/completions"
        case .responses:
            return "responses"
        case .anthropicMessages:
            return "messages"
        case .custom:
            return nil
        }
    }

    var apiPath: String? {
        suffix.map { "/v1/\($0)" }
    }

    static func infer(from apiPath: String) -> Self {
        let normalized = apiPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "/v1/chat/completions",
             "v1/chat/completions":
            return .chatCompletions

        case "/v1/responses",
             "v1/responses":
            return .responses

        case "/v1/messages",
             "v1/messages",
             "/messages",
             "messages":
            return .anthropicMessages

        default:
            if normalized.hasSuffix("/messages"), normalized.contains("/v1/") {
                return .anthropicMessages
            }
            return .custom
        }
    }

    /// OpenCode Zen / Go 的模型协议不是统一的：同一个 Base URL 下，模型可能分别要求
    /// Responses、Chat Completions 或 Anthropic Messages。这里只对官方明确列出的
    /// OpenCode 路径做自动建议；其它中转服务保留用户选择，不把模型名猜测成协议。
    static func recommended(baseURL: String, model: String) -> Self? {
        let rawURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return nil }
        let url = if let url = URL(string: rawURL), url.host != nil {
            url
        } else {
            URL(string: "https://\(rawURL)")
        }
        guard let url, let host = url.host?.lowercased(),
              host == "opencode.ai" || host.hasSuffix(".opencode.ai") else {
            return nil
        }

        let path = url.path.lowercased()
        let modelID = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        guard !modelID.isEmpty else { return nil }

        // Muse Spark 在 OpenCode 的当前 Responses 路径上运行；同时覆盖用户此前
        // 保存过的 contributor 变体，避免旧 Mac 配置继续用 chat/completions。
        if modelID.contains("muse-spark") {
            return .responses
        }

        let isGo = path.contains("/zen/go")
        let isZen = !isGo && path.contains("/zen")
        guard isGo || isZen else { return nil }

        if isGo {
            if modelID.hasPrefix("qwen") || modelID.hasPrefix("minimax") {
                return .anthropicMessages
            }
            if modelID == "gpt-5.6-luna" {
                return .responses
            }
        } else {
            if modelID.hasPrefix("qwen") || modelID.hasPrefix("claude") {
                return .anthropicMessages
            }
            if modelID.hasPrefix("gpt-5.6-")
                || modelID == "grok-4.6"
                || modelID == "grok-4.5"
                || modelID.hasPrefix("grok-build") {
                return .responses
            }
        }

        let chatPrefixes = ["grok", "glm", "kimi", "deepseek", "mimo", "hy3", "minimax"]
        if chatPrefixes.contains(where: { modelID.hasPrefix($0) }) {
            return .chatCompletions
        }
        return nil
    }

    var supportsToolCalling: Bool {
        self != .anthropicMessages
    }

    var isSupported: Bool {
        self != .anthropicMessages
    }
}

/// 设置页与 AI 助手共用的接口配置。普通字段存 UserDefaults，
/// API Key 只存系统 Keychain（见 `credentialID`）。
struct AIConnectionSettings: Sendable {
    var baseURL: String
    var apiPath: String
    var model: String
    var endpointMode: AIEndpointMode
    /// 模型上下文窗口（token）。不再假设所有 OpenAI 兼容模型都是 256K。
    var maxContextTokens: Int
    /// 单次回复输出上限（token）。
    var maxOutputTokens: Int

    static let credentialID = CredentialID(rawValue: "ai.provider.api-key")

    enum Keys {
        static let baseURL = "auralis.ai.baseURL"
        static let apiPath = "auralis.ai.apiPath"
        static let model = "auralis.ai.model"
        static let endpointMode = "auralis.ai.endpointMode"
        static let maxContextTokens = "auralis.ai.maxContextTokens"
        static let maxOutputTokens = "auralis.ai.maxOutputTokens"
    }

    static let defaultBaseURL = "https://api.openai.com"
    static let defaultAPIPath = "/v1/chat/completions"
    static let defaultModel = "gpt-4o-mini"
    static let defaultMaxContextTokens = auralisDefaultMaxContextTokens
    static let defaultMaxOutputTokens = auralisDefaultMaxOutputTokens

    init(defaults: UserDefaults = .standard) {
        baseURL = defaults.string(forKey: Keys.baseURL) ?? Self.defaultBaseURL
        apiPath = defaults.string(forKey: Keys.apiPath) ?? Self.defaultAPIPath
        model = defaults.string(forKey: Keys.model) ?? Self.defaultModel
        endpointMode = AIEndpointMode(
            rawValue: defaults.string(forKey: Keys.endpointMode) ?? ""
        ) ?? AIEndpointMode.infer(from: apiPath)
        if defaults.object(forKey: Keys.maxContextTokens) != nil {
            maxContextTokens = max(4_096, defaults.integer(forKey: Keys.maxContextTokens))
        } else {
            maxContextTokens = Self.defaultMaxContextTokens
        }
        if defaults.object(forKey: Keys.maxOutputTokens) != nil {
            maxOutputTokens = max(512, defaults.integer(forKey: Keys.maxOutputTokens))
        } else {
            maxOutputTokens = Self.defaultMaxOutputTokens
        }
    }

    /// 把用户可能漏写协议的地址补全为合法 URL。
    /// - `localhost` / `127.0.0.1` / 纯 IP 推断为 `http`；其余推断为 `https`。
    /// - 已带合法 `http(s)` 协议则原样返回。
    private func normalizedBaseURL() -> URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return url
        }
        // 漏写协议：去掉可能误写的前缀后按主机名推断协议。
        let hostPart = raw.replacingOccurrences(
            of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#,
            with: "",
            options: .regularExpression
        )
        let isLocal = hostPart.lowercased().hasPrefix("localhost")
            || hostPart.hasPrefix("127.0.0.1")
            || hostPart.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?"#, options: .regularExpression) != nil
        let scheme = isLocal ? "http" : "https"
        return URL(string: "\(scheme)://\(hostPart)")
    }

    /// 配置完整 = Base URL 可解析为合法 http(s) 地址且模型非空。
    /// 允许省略协议（如 `localhost:11434`、`api.deepseek.com`），会自动补全。
    /// Key 缺失时 Provider 仍会在请求阶段报 `AIProviderError.missingCredential`。
    var isComplete: Bool {
        normalizedBaseURL() != nil
            && !effectiveAPIPath.isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && effectiveEndpointMode.isSupported
    }

    /// OpenCode 等模型网关的最终协议建议。自定义模式永远尊重用户输入；标准模式
    /// 在已知 Provider + Model 时自动纠正旧的错误路径。
    var recommendedEndpointMode: AIEndpointMode? {
        AIEndpointMode.recommended(baseURL: baseURL, model: model)
    }

    var effectiveEndpointMode: AIEndpointMode {
        if endpointMode == .custom {
            let inferred = AIEndpointMode.infer(from: apiPath)
            return inferred == .anthropicMessages ? .anthropicMessages : .custom
        }
        return recommendedEndpointMode ?? endpointMode
    }

    var effectiveAPIPath: String {
        if endpointMode != .custom, let recommendedPath = effectiveEndpointMode.apiPath {
            return recommendedPath
        }
        return apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var endpointSummary: String {
        "\(effectiveEndpointMode.title) · \(effectiveAPIPath)"
    }

    /// 校验未通过时的可读原因，便于设置页给出明确提示。
    var completenessError: String? {
        if normalizedBaseURL() == nil {
            return String(localized: "Base URL 需要是合法地址，例如 https://api.deepseek.com 或 http://localhost:11434。", bundle: .module)
        }
        if effectiveAPIPath.isEmpty {
            return String(localized: "请填写 API 路径（如 /v1/chat/completions 或 /v1/responses）。", bundle: .module)
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "请填写模型名称（如 gpt-4o-mini、deepseek-chat）。", bundle: .module)
        }
        if !effectiveEndpointMode.isSupported {
            return String(localized: "当前模型要求 Anthropic Messages（/v1/messages），Auralis 尚未支持该协议。请换用 Chat/Responses 模型，或选择自定义兼容端点。", bundle: .module)
        }
        return nil
    }

    func makeProvider(
        credentialVault: any CredentialVault = KeychainCredentialVault(),
        session: URLSession = .shared
    ) -> (any AIProvider)? {
        guard isComplete,
              let url = normalizedBaseURL()
        else { return nil }
        return OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
            name: String(localized: "OpenAI 兼容接口", bundle: .module),
                baseURL: url,
                apiPath: effectiveAPIPath,
                credentialID: Self.credentialID,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                maxTokens: maxOutputTokens,
                maxContextTokens: maxContextTokens,
                supportsToolCalling: effectiveEndpointMode.supportsToolCalling
            ),
            credentialVault: credentialVault,
            session: session
        )
    }
}
