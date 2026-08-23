import Foundation

/// A citation that can safely cross the tool/UI boundary. It contains no
/// request headers, cookies, credentials, or raw provider payload.
public struct WebSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String { Self.canonicalURL(url).absoluteString }
    public let title: String
    public let url: URL
    public let domain: String
    public let snippet: String
    public let publishedAt: String?
    public let backend: String?
    public let sourceType: String?

    public init(
        title: String,
        url: URL,
        snippet: String,
        publishedAt: String? = nil,
        backend: String? = nil,
        sourceType: String? = nil
    ) {
        self.title = title
        self.url = url
        self.domain = url.host ?? ""
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.backend = backend
        self.sourceType = sourceType
    }

    public static func canonicalURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url ?? url
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
    case dnsResolutionFailed
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge
    case redirectLimitExceeded
    case unsupportedContentType(String)
    case fetchRequiresSearchResult

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "联网搜索问题不能为空"
        case .invalidURL: "网页地址无效或不是 HTTPS"
        case .privateAddress: "为避免意外访问本机服务，不支持读取私有地址"
        case .dnsResolutionFailed: "网页域名无法安全解析"
        case let .httpStatus(status): "网页返回 HTTP \(status)"
        case .invalidResponse: "网页内容无法解析"
        case .responseTooLarge: "网页内容过大，未读取"
        case .redirectLimitExceeded: "网页重定向次数过多，未读取"
        case let .unsupportedContentType(type): "网页内容类型不受支持：\(type)"
        case .fetchRequiresSearchResult: "为避免 DNS rebinding，网页读取只允许使用本轮搜索结果中的 URL"
        }
    }
}

private enum BoundedLoadResult {
    case response(HTTPURLResponse, Data)
    case redirect(URL)
}

/// A one-request URLSession delegate. URLSession's default redirect behavior is
/// intentionally disabled; the caller validates and follows one hop at a time.
private final class BoundedURLDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maxBytes: Int
    private let allowedContentTypes: Set<String>
    private var continuation: CheckedContinuation<BoundedLoadResult, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false

    init(configuration: URLSessionConfiguration, maxBytes: Int, allowedContentTypes: Set<String>) {
        self.configuration = configuration
        self.maxBytes = maxBytes
        self.allowedContentTypes = allowedContentTypes
    }

    func load(_ request: URLRequest) async throws -> BoundedLoadResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        guard let url = request.url else {
            finish(.failure(WebCapabilityError.invalidURL))
            return
        }
        finish(.success(.redirect(url)))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(WebCapabilityError.invalidResponse))
            return
        }

        if (300...399).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           let base = http.url,
           let target = URL(string: location, relativeTo: base)?.absoluteURL {
            completionHandler(.cancel)
            finish(.success(.redirect(target)))
            return
        }

        if http.expectedContentLength > Int64(maxBytes) {
            completionHandler(.cancel)
            finish(.failure(WebCapabilityError.responseTooLarge))
            return
        }

        guard let mime = http.mimeType?.lowercased(), allowedContentTypes.contains(mime) else {
            completionHandler(.cancel)
            finish(.failure(WebCapabilityError.unsupportedContentType(http.mimeType ?? "missing")))
            return
        }

        self.response = http
        data.reserveCapacity(min(maxBytes, max(0, Int(http.expectedContentLength))))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard data.count <= maxBytes - self.data.count else {
            task?.cancel()
            finish(.failure(WebCapabilityError.responseTooLarge))
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success(.response(response, data)))
        } else {
            finish(.failure(WebCapabilityError.invalidResponse))
        }
    }

    private func finish(_ result: Result<BoundedLoadResult, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
        session?.invalidateAndCancel()
    }
}

/// Key-free generic web capability for providers without hosted search.
///
/// DuckDuckGo's public endpoint is an Instant Answer service, not a complete
/// web index. It is intentionally named and reported as a limited fallback.
public actor DuckDuckGoInstantAnswerService: AgentWebRunScopedService, AgentWebSearchBackend {
    public static let backendIdentifier = "duckduckgo-instant-answer"
    public static let maxRawBodyBytes = 2_000_000
    public static let maxModelCharacters = 20_000

    public nonisolated var capability: WebSearchCapability { .instantAnswerFallback }

    private let configuration: URLSessionConfiguration
    private let userAgent: String
    private let policy: SafeWebURLPolicy
    private let fetchScope: WebFetchURLScope

    public init(
        session: URLSession = .shared,
        userAgent: String = "Auralis/1.0",
        policy: SafeWebURLPolicy = SafeWebURLPolicy(),
        fetchScope: WebFetchURLScope = WebFetchURLScope()
    ) {
        self.configuration = Self.configuration(from: session)
        self.userAgent = userAgent
        self.policy = policy
        self.fetchScope = fetchScope
    }

    public func beginRun(_ runID: UUID) async {
        await fetchScope.beginRun(runID)
    }

    public func register(sources: [WebSource]) async {
        await fetchScope.register(sources: sources)
    }

    private static func configuration(from session: URLSession) -> URLSessionConfiguration {
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return configuration
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
        let (data, _, _) = try await load(request: request, allowedContentTypes: ["application/json"])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebCapabilityError.invalidResponse
        }

        var candidates: [WebSource] = []
        if let abstract = object["AbstractText"] as? String,
           let rawURL = object["AbstractURL"] as? String,
           let sourceURL = URL(string: rawURL),
           !abstract.isEmpty {
            candidates.append(WebSource(
                title: (object["Heading"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? query,
                url: sourceURL,
                snippet: abstract,
                backend: Self.backendIdentifier,
                sourceType: "instant-answer"
            ))
        }
        if let topics = object["RelatedTopics"] as? [[String: Any]] {
            candidates.append(contentsOf: topicSources(topics, limit: max(limit, 1)))
        }

        let sources = await validatedSources(candidates, limit: min(max(limit, 1), 10))
        await fetchScope.record(sources.map(\.url))
        return WebSearchResult(query: query, sources: sources)
    }

    public func fetch(url: URL) async throws -> WebDocument {
        guard await fetchScope.allows(url) else {
            throw WebCapabilityError.fetchRequiresSearchResult
        }
        try await policy.validateInitialURL(url)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _, finalURL) = try await load(request: request, allowedContentTypes: [
            "text/html", "text/plain", "application/xhtml+xml", "application/json",
        ])
        try await policy.validateFinalURL(finalURL)
        let raw = String(decoding: data, as: UTF8.self)
        let text = Self.plainText(fromHTML: raw)
        guard !text.isEmpty else { throw WebCapabilityError.invalidResponse }
        let title = Self.htmlTitle(raw) ?? finalURL.host ?? finalURL.absoluteString
        let source = WebSource(
            title: title,
            url: finalURL,
            snippet: String(text.prefix(320)),
            backend: Self.backendIdentifier,
            sourceType: "document"
        )
        return WebDocument(source: source, text: String(text.prefix(Self.maxModelCharacters)))
    }

    private func load(
        request: URLRequest,
        allowedContentTypes: Set<String>
    ) async throws -> (Data, HTTPURLResponse, URL) {
        guard var currentURL = request.url else { throw WebCapabilityError.invalidURL }
        var redirects = 0

        while true {
            try await policy.validateFinalURL(currentURL)
            var hopRequest = request
            hopRequest.url = currentURL
            hopRequest.timeoutInterval = 20

            let loader = BoundedURLDataLoader(
                configuration: configuration,
                maxBytes: Self.maxRawBodyBytes,
                allowedContentTypes: allowedContentTypes
            )
            switch try await loader.load(hopRequest) {
            case let .response(response, data):
                guard (200...299).contains(response.statusCode) else {
                    throw WebCapabilityError.httpStatus(response.statusCode)
                }
                let finalURL = response.url ?? currentURL
                try await policy.validateFinalURL(finalURL)
                return (data, response, finalURL)
            case let .redirect(target):
                guard redirects < policy.maxRedirects else {
                    throw WebCapabilityError.redirectLimitExceeded
                }
                let absoluteTarget = target.absoluteURL
                try await policy.validateRedirect(from: currentURL, to: absoluteTarget)
                currentURL = absoluteTarget
                redirects += 1
            }
        }
    }

    private func topicSources(_ topics: [[String: Any]], limit: Int) -> [WebSource] {
        var sources: [WebSource] = []
        for topic in topics {
            if sources.count >= limit { break }
            if let nested = topic["Topics"] as? [[String: Any]] {
                sources.append(contentsOf: topicSources(nested, limit: limit - sources.count))
                continue
            }
            guard let rawURL = topic["FirstURL"] as? String,
                  let url = URL(string: rawURL),
                  let text = topic["Text"] as? String,
                  !text.isEmpty else { continue }
            sources.append(WebSource(
                title: text,
                url: url,
                snippet: text,
                backend: Self.backendIdentifier,
                sourceType: "related-topic"
            ))
        }
        return sources
    }

    private func validatedSources(_ candidates: [WebSource], limit: Int) async -> [WebSource] {
        var result: [WebSource] = []
        var seen: Set<String> = []
        for source in candidates {
            guard result.count < limit,
                  (try? await policy.validateFinalURL(source.url)) != nil else { continue }
            let canonical = WebSource.canonicalURL(source.url).absoluteString
            guard seen.insert(canonical).inserted else { continue }
            result.append(source)
        }
        return result
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

/// Source-compatible name for older callers. New code must use the explicit
/// Instant Answer name so it cannot be mistaken for a full web search backend.
@available(*, deprecated, renamed: "DuckDuckGoInstantAnswerService")
public typealias DuckDuckGoWebService = DuckDuckGoInstantAnswerService
