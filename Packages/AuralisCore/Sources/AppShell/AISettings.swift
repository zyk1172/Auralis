import AIKit
import Domain
import Foundation
import SecurityKit

/// AI 接口协议：把 `apiPath` 从「用户手填字符串」正式类型化。
/// 底层仍保存完整 `apiPath`（UserDefaults key 不变，备份/历史配置不受影响），
/// 这里只负责设置页的选择与展示。
enum AIEndpointMode: String, CaseIterable, Identifiable, Sendable {
    case chatCompletions
    case responses
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatCompletions:
            return "OpenAI 兼容"
        case .responses:
            return "OpenAI 原生"
        case .custom:
            return "自定义"
        }
    }

    var subtitle: String {
        switch self {
        case .chatCompletions:
            return "Chat Completions"
        case .responses:
            return "Responses API"
        case .custom:
            return "自定义 API 路径"
        }
    }

    /// 用户说的「v1 后面的后缀」。
    var suffix: String? {
        switch self {
        case .chatCompletions:
            return "chat/completions"
        case .responses:
            return "responses"
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

        default:
            return .custom
        }
    }
}

/// 设置页与 AI 助手共用的接口配置。普通字段存 UserDefaults，
/// API Key 只存系统 Keychain（见 `credentialID`）。
struct AIConnectionSettings: Sendable {
    var baseURL: String
    var apiPath: String
    var model: String
    /// 模型上下文窗口（token）。不再假设所有 OpenAI 兼容模型都是 256K。
    var maxContextTokens: Int
    /// 单次回复输出上限（token）。
    var maxOutputTokens: Int

    static let credentialID = CredentialID(rawValue: "ai.provider.api-key")

    enum Keys {
        static let baseURL = "auralis.ai.baseURL"
        static let apiPath = "auralis.ai.apiPath"
        static let model = "auralis.ai.model"
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
            && !apiPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 校验未通过时的可读原因，便于设置页给出明确提示。
    var completenessError: String? {
        guard normalizedBaseURL() == nil else {
            return model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "请填写模型名称（如 gpt-4o-mini、deepseek-chat）。" : nil
        }
        return "Base URL 需要是合法地址，例如 https://api.deepseek.com 或 http://localhost:11434。"
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
                name: "OpenAI 兼容接口",
                baseURL: url,
                apiPath: apiPath.trimmingCharacters(in: .whitespacesAndNewlines),
                credentialID: Self.credentialID,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                maxTokens: maxOutputTokens,
                maxContextTokens: maxContextTokens,
                supportsToolCalling: true
            ),
            credentialVault: credentialVault,
            session: session
        )
    }
}
