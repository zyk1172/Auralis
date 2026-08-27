import Foundation
import SecurityKit

/// Tavily's response is adapted to Auralis' existing WebCapability boundary.
/// The API key is read from CredentialVault for each request and never enters
/// a WebSource, diagnostic, prompt, or persisted search result.
public actor TavilyWebSearchService: AgentWebRunScopedService, AgentWebSearchOptionsBackend {
    public static let backendIdentifier = "tavily"
    public static let defaultCredentialID = CredentialID(rawValue: "web.tavily.api-key")
    public static let defaultEndpoint = URL(string: "https://api.tavily.com/search")!
    public static let maxResponseBytes = 1_000_000
    public static let maxModelCharacters = 1_200

    private struct CacheEntry {
        let expiresAt: Date
        let result: WebSearchResult
    }

    private let endpoint: URL
    private let credentialID: CredentialID
    private let credentialVault: any CredentialVault
    private let configuration: URLSessionConfiguration
    private let policy: SafeWebURLPolicy
    private let fetchScope: WebFetchURLScope
    private var cache: [String: CacheEntry] = [:]

    public nonisolated var capability: WebSearchCapability { .configuredFullSearch }

    public init(
        endpoint: URL = TavilyWebSearchService.defaultEndpoint,
        credentialID: CredentialID = TavilyWebSearchService.defaultCredentialID,
        credentialVault: any CredentialVault = KeychainCredentialVault(),
        session: URLSession = .shared,
        policy: SafeWebURLPolicy = SafeWebURLPolicy(),
        fetchScope: WebFetchURLScope = WebFetchURLScope()
    ) {
        self.endpoint = endpoint
        self.credentialID = credentialID
        self.credentialVault = credentialVault
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.configuration = configuration
        self.policy = policy
        self.fetchScope = fetchScope
    }

    public func beginRun(_ runID: UUID) async {
        await fetchScope.beginRun(runID)
    }

    public func register(sources: [WebSource], runID: UUID) async {
        await fetchScope.register(sources: sources, runID: runID)
    }

    public func search(query: String, limit: Int) async throws -> WebSearchResult {
        try await search(query: query, options: WebSearchOptions(limit: limit))
    }

    public func search(query: String, options: WebSearchOptions) async throws -> WebSearchResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { throw WebCapabilityError.emptyQuery }
        let cacheKey = Self.cacheKey(query: normalizedQuery, options: options)
        if let cached = cache[cacheKey], cached.expiresAt > .now {
            await record(cached.result.sources)
            return cached.result
        }

        let key: String
        do {
            key = try await credentialVault.retrieve(id: credentialID)
        } catch {
            // Do not expose the credential ID or Keychain implementation detail
            // to the model-facing tool result.
            throw WebCapabilityError.invalidResponse
        }
        try await policy.validateInitialURL(endpoint)
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "api_key": key,
            "query": normalizedQuery,
            "search_depth": options.searchDepth,
            "max_results": options.limit,
            "include_answer": false,
            "include_raw_content": false,
            "include_images": false,
        ].merging(options.includeDomains.isEmpty ? [:] : ["include_domains": options.includeDomains]) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response, finalURL) = try await load(request: request, allowedContentTypes: ["application/json"])
        try await policy.validateFinalURL(finalURL)
        guard (200...299).contains(response.statusCode) else {
            // Deliberately discard the response body: Tavily error payloads can
            // echo request material and must not cross the model boundary.
            throw WebCapabilityError.httpStatus(response.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = object["results"] as? [[String: Any]] else {
            throw WebCapabilityError.invalidResponse
        }

        var sources: [WebSource] = []
        var seen = Set<String>()
        for raw in rawResults.prefix(options.limit) {
            guard let rawURL = raw["url"] as? String,
                  let url = URL(string: rawURL),
                  (try? await policy.validateFinalURL(url)) != nil else { continue }
            let canonical = WebSource.canonicalURL(url).absoluteString
            guard seen.insert(canonical).inserted else { continue }
            let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = (raw["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(title?.isEmpty ?? true), !(content?.isEmpty ?? true) else { continue }
            sources.append(WebSource(
                title: String(title!.prefix(Self.maxModelCharacters)),
                url: WebSource.canonicalURL(url),
                snippet: String(content!.prefix(Self.maxModelCharacters)),
                publishedAt: raw["published_date"] as? String,
                backend: Self.backendIdentifier,
                sourceType: "tavily-search"
            ))
        }
        let result = WebSearchResult(query: normalizedQuery, sources: sources)
        cache[cacheKey] = CacheEntry(expiresAt: Date().addingTimeInterval(14 * 24 * 60 * 60), result: result)
        await record(sources)
        return result
    }

    /// Performs a bounded, metadata-free probe used by Settings. The probe
    /// deliberately uses a fixed query so testing the credential never sends
    /// the user's library contents to Tavily.
    public func testConnection() async throws -> WebSearchResult {
        try await search(
            query: "Auralis connection test",
            options: WebSearchOptions(limit: 1, searchDepth: "basic")
        )
    }

    public func fetch(url: URL) async throws -> WebDocument {
        guard await fetchScope.allows(url) else { throw WebCapabilityError.fetchRequiresSearchResult }
        try await policy.validateInitialURL(url)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Auralis/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response, finalURL) = try await load(request: request, allowedContentTypes: [
            "text/html", "text/plain", "application/xhtml+xml", "application/json",
        ])
        guard (200...299).contains(response.statusCode) else { throw WebCapabilityError.httpStatus(response.statusCode) }
        try await policy.validateFinalURL(finalURL)
        guard await fetchScope.allows(finalURL) else {
            // A redirect must not turn a previously registered URL into an
            // unregistered source for this run.
            throw WebCapabilityError.fetchRequiresSearchResult
        }
        let raw = String(decoding: data, as: UTF8.self)
        let text = Self.plainText(fromHTML: raw)
        guard !text.isEmpty else { throw WebCapabilityError.invalidResponse }
        let source = WebSource(
            title: Self.htmlTitle(raw) ?? finalURL.host ?? finalURL.absoluteString,
            url: finalURL,
            snippet: String(text.prefix(320)),
            backend: Self.backendIdentifier,
            sourceType: "tavily-document"
        )
        return WebDocument(source: source, text: String(text.prefix(20_000)))
    }

    private func record(_ sources: [WebSource]) async {
        guard let runID = await fetchScope.currentRunID() else { return }
        await fetchScope.record(sources.map(\.url), runID: runID)
    }

    private func load(
        request: URLRequest,
        allowedContentTypes: Set<String>
    ) async throws -> (Data, HTTPURLResponse, URL) {
        guard var currentURL = request.url else { throw WebCapabilityError.invalidURL }
        var redirects = 0
        while true {
            try await policy.validateFinalURL(currentURL)
            var hop = request
            hop.url = currentURL
            let loader = BoundedURLDataLoader(
                configuration: configuration,
                maxBytes: Self.maxResponseBytes,
                allowedContentTypes: allowedContentTypes
            )
            switch try await loader.load(hop) {
            case let .response(response, data):
                return (data, response, response.url ?? currentURL)
            case let .redirect(target):
                guard redirects < policy.maxRedirects else { throw WebCapabilityError.redirectLimitExceeded }
                let absolute = target.absoluteURL
                try await policy.validateRedirect(from: currentURL, to: absolute)
                currentURL = absolute
                redirects += 1
            }
        }
    }

    private static func cacheKey(query: String, options: WebSearchOptions) -> String {
        let domains = options.includeDomains.map { $0.lowercased() }.sorted().joined(separator: ",")
        return "\(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased())|\(options.searchDepth)|\(domains)|\(options.limit)"
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let range = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        let match = String(html[range]).replacingOccurrences(of: #"(?is)^<title[^>]*>|</title>$"#, with: "", options: .regularExpression)
        let value = plainText(fromHTML: match)
        return value.isEmpty ? nil : value
    }

    private static func plainText(fromHTML html: String) -> String {
        var value = html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, replacement) in ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
