import Foundation

/// A citation that can safely cross the tool/UI boundary.  It contains no
/// request headers, cookies, credentials, or raw provider payload.
public struct WebSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let domain: String
    public let snippet: String
    public let publishedAt: String?

    public init(title: String, url: URL, snippet: String, publishedAt: String? = nil) {
        self.title = title
        self.url = url
        self.domain = url.host ?? ""
        self.snippet = snippet
        self.publishedAt = publishedAt
    }
}

public struct WebSearchResult: Codable, Hashable, Sendable {
    public let query: String
    public let sources: [WebSource]

    public init(query: String, sources: [WebSource]) {
        self.query = query
        self.sources = sources
    }
}

public struct WebDocument: Codable, Hashable, Sendable {
    public let source: WebSource
    public let text: String

    public init(source: WebSource, text: String) {
        self.source = source
        self.text = text
    }
}

public protocol AgentWebService: Sendable {
    func search(query: String, limit: Int) async throws -> WebSearchResult
    func fetch(url: URL) async throws -> WebDocument
}

public enum WebCapabilityError: Error, LocalizedError, Sendable, Equatable {
    case emptyQuery
    case invalidURL
    case privateAddress
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "联网搜索问题不能为空"
        case .invalidURL: "网页地址无效或不是 HTTPS"
        case .privateAddress: "为避免意外访问本机服务，不支持读取私有地址"
        case let .httpStatus(status): "网页返回 HTTP \(status)"
        case .invalidResponse: "网页内容无法解析"
        case .responseTooLarge: "网页内容过大，未读取"
        }
    }
}

/// Key-free generic web capability for providers without hosted search.
/// DuckDuckGo's public Instant Answer endpoint is intentionally kept behind a
/// small protocol so a future configured backend or hosted-provider adapter
/// can replace it without touching the conversation loop.
public actor DuckDuckGoWebService: AgentWebService {
    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "Auralis/1.0") {
        self.session = session
        self.userAgent = userAgent
    }

    public func search(query: String, limit: Int = 5) async throws -> WebSearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw WebCapabilityError.emptyQuery }
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = components?.url else { throw WebCapabilityError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebCapabilityError.invalidResponse
        }

        var sources: [WebSource] = []
        if let abstract = object["AbstractText"] as? String,
           let rawURL = object["AbstractURL"] as? String,
           let sourceURL = URL(string: rawURL),
           !abstract.isEmpty {
            sources.append(WebSource(
                title: (object["Heading"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? query,
                url: sourceURL,
                snippet: abstract
            ))
        }
        if let topics = object["RelatedTopics"] as? [[String: Any]] {
            appendTopics(topics, to: &sources, limit: max(limit, 1))
        }
        return WebSearchResult(query: query, sources: Array(sources.prefix(min(max(limit, 1), 10))))
    }

    public func fetch(url: URL) async throws -> WebDocument {
        guard Self.isAllowed(url) else {
            if url.scheme?.lowercased() != "https" || url.host == nil { throw WebCapabilityError.invalidURL }
            throw WebCapabilityError.privateAddress
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard data.count <= 2_000_000 else { throw WebCapabilityError.responseTooLarge }
        let raw = String(decoding: data, as: UTF8.self)
        let text = Self.plainText(fromHTML: raw)
        guard !text.isEmpty else { throw WebCapabilityError.invalidResponse }
        let title = Self.htmlTitle(raw) ?? url.host ?? url.absoluteString
        let source = WebSource(title: title, url: url, snippet: String(text.prefix(320)))
        return WebDocument(source: source, text: String(text.prefix(20_000)))
    }

    private func appendTopics(_ topics: [[String: Any]], to sources: inout [WebSource], limit: Int) {
        for topic in topics {
            if sources.count >= limit { return }
            if let nested = topic["Topics"] as? [[String: Any]] {
                appendTopics(nested, to: &sources, limit: limit)
                continue
            }
            guard let rawURL = topic["FirstURL"] as? String,
                  let url = URL(string: rawURL),
                  let text = topic["Text"] as? String,
                  !text.isEmpty else { continue }
            sources.append(WebSource(title: text, url: url, snippet: text))
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw WebCapabilityError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw WebCapabilityError.httpStatus(http.statusCode) }
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return false }
        if host == "127.0.0.1" || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return false }
        if host.hasPrefix("172."),
           let second = Int(host.split(separator: ".").dropFirst().first ?? "0"),
           (16...31).contains(second) { return false }
        return true
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let range = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        let match = String(html[range])
            .replacingOccurrences(of: #"(?is)^<title[^>]*>|</title>$"#, with: "", options: .regularExpression)
        let title = plainText(fromHTML: match)
        return title.isEmpty ? nil : title
    }

    private static func plainText(fromHTML html: String) -> String {
        var value = html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }
        return value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
