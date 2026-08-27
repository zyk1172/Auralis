import AIKit
import Foundation
import LocalCatalog

/// Small structured first-pass adapter for public iTunes metadata. It is an
/// optional enhancement: a failure returns no result and never stops indexing.
public actor AppleITunesMusicSearchService {
    public static let shared = AppleITunesMusicSearchService()
    public static let defaultEndpoint = URL(string: "https://itunes.apple.com/search")!

    private let endpoint: URL
    private let configuration: URLSessionConfiguration
    private let policy: SafeWebURLPolicy
    private var cache: [String: (expiresAt: Date, lines: [String])] = [:]

    public init(
        endpoint: URL = AppleITunesMusicSearchService.defaultEndpoint,
        session: URLSession = .shared,
        policy: SafeWebURLPolicy = SafeWebURLPolicy()
    ) {
        self.endpoint = endpoint
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.configuration = configuration
        self.policy = policy
    }

    public func search(title: String, artist: String, album: String?) async -> [String] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !artist.isEmpty else { return [] }
        let key = [artist, title, album ?? ""].joined(separator: "|").lowercased()
        if let cached = cache[key], cached.expiresAt > .now { return cached.lines }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: [artist, title].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url,
              (try? await policy.validateInitialURL(url)) != nil else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response, finalURL) = try await load(request: request)
            guard (200...299).contains(response.statusCode),
                  (try? await policy.validateFinalURL(finalURL)) != nil,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else { return [] }
            let lines = results.compactMap(Self.normalizedLine).prefix(3).map { $0 }
            cache[key] = (Date().addingTimeInterval(7 * 24 * 60 * 60), Array(lines))
            return Array(lines)
        } catch {
            return []
        }
    }

    private static func normalizedLine(_ raw: [String: Any]) -> String? {
        let track = (raw["trackName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (raw["artistName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = (raw["collectionName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let track, !track.isEmpty, let artist, !artist.isEmpty else { return nil }
        let genre = (raw["primaryGenreName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let releaseDate = (raw["releaseDate"] as? String).flatMap { $0.prefix(10).isEmpty ? nil : String($0.prefix(10)) }
        let explicit = (raw["trackExplicitness"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let url = (raw["trackViewUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return [
            "track=\(track)",
            "artist=\(artist)",
            collection.map { "album=\($0)" },
            genre.map { "genre=\($0)" },
            releaseDate.map { "release=\($0)" },
            explicit.map { "explicit=\($0)" },
            url.map { "url=\($0)" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func load(request: URLRequest) async throws -> (Data, HTTPURLResponse, URL) {
        guard var currentURL = request.url else { throw WebCapabilityError.invalidURL }
        var redirects = 0
        while true {
            try await policy.validateFinalURL(currentURL)
            var hop = request
            hop.url = currentURL
            let loader = BoundedURLDataLoader(
                configuration: configuration,
                maxBytes: 500_000,
                allowedContentTypes: ["application/json"]
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
}

/// Skill-only, track-attributable evidence execution. The tool never accepts
/// a free URL for fetch and never forwards library state to an external source.
enum RecommendationIndexEvidenceTool {
    static let recommendedMusicEvidenceDomains = [
        "music.apple.com", "music.163.com", "allmusic.com", "discogs.com", "bandcamp.com", "last.fm",
    ]

    static func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        catalog: LocalCatalogStore,
        webService: (any AgentWebService)?,
        externalMusicService: (any AgentExternalMusicService)?
    ) async -> ToolResult {
        guard let rawTrackID = call.optionalString("trackID"),
              let globalID = GlobalID(rawTrackID),
              let track = try? await catalog.getTrack(globalID) else {
            return .fail(call, descriptor, "证据工具需要当前批次中的真实 trackID。")
        }
        let query = call.optionalString("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "\(track.artistName) \(track.title) \(track.albumTitle)"
        let appleLines = await AppleITunesMusicSearchService.shared.search(
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle
        )
        var lines = appleLines.map { "[Apple iTunes structured] \($0)" }
        var sources: [WebSource] = []
        if lines.isEmpty, let webService {
            let domains = stringArray(call.arguments["domains"])
            let limit = min(max((try? call.int("limit")) ?? 5, 1), 5)
            let options = WebSearchOptions(
                limit: limit,
                includeDomains: domains.isEmpty ? recommendedMusicEvidenceDomains : domains,
                searchDepth: "basic"
            )
            do {
                let result: WebSearchResult
                if let optionsBackend = webService as? any AgentWebSearchOptionsBackend {
                    result = try await optionsBackend.search(query: query, options: options)
                } else {
                    result = try await webService.search(query: query, limit: limit)
                }
                sources = result.sources
                lines = result.sources.map {
                    "[\($0.domain)] \($0.title) · \($0.snippet) · URL=\($0.url.absoluteString)"
                }
            } catch {
                // External evidence is an enhancement; local metadata remains
                // sufficient for the classifier when a backend is unavailable.
            }
        }
        let text = lines.isEmpty
            ? "没有获得结构化或网页公开证据；请只依据本地歌曲元数据。"
            : lines.joined(separator: "\n")
        let evidence = AgentEvidence(
            source: .externalAPI,
            provenance: sources.first?.backend ?? (appleLines.isEmpty ? "external-discovery" : "apple-itunes"),
            confidence: sources.isEmpty ? 0.75 : 0.55,
            entityID: rawTrackID,
            claim: text,
            requiredDisclosureCategories: [.metadata, .externalDiscovery]
        )
        return .ok(
            call,
            descriptor,
            "已为当前歌曲获取公开证据（Apple=\(appleLines.count)，网页=\(sources.count)）",
            .text(text),
            evidence: [evidence],
            trustLevel: .externalUntrusted
        )
    }

    static func fetch(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        catalog: LocalCatalogStore,
        webService: (any AgentWebService)?
    ) async -> ToolResult {
        guard let rawTrackID = call.optionalString("trackID"),
              let globalID = GlobalID(rawTrackID),
              let _ = try? await catalog.getTrack(globalID) else {
            return .fail(call, descriptor, "证据工具需要当前批次中的真实 trackID。")
        }
        guard let webService,
              let rawURL = call.optionalString("url"),
              let url = URL(string: rawURL) else {
            return .fail(call, descriptor, "网页证据读取能力未配置或地址无效。")
        }
        do {
            let document = try await webService.fetch(url: url)
            let text = String(document.text.prefix(20_000))
            let evidence = AgentEvidence(
                source: .externalAPI,
                provenance: document.source.backend ?? document.source.domain,
                confidence: 0.5,
                entityID: rawTrackID,
                claim: text,
                requiredDisclosureCategories: [.metadata, .externalDiscovery]
            )
            return .ok(
                call,
                descriptor,
                "已读取当前歌曲的公开网页证据",
                .text("来源：\(document.source.title)\nURL：\(document.source.url.absoluteString)\n\n\(text)"),
                evidence: [evidence],
                trustLevel: .externalUntrusted
            )
        } catch {
            return .fail(call, descriptor, "公开网页证据读取失败：\(error.localizedDescription)")
        }
    }

    private static func stringArray(_ value: AIJSONValue?) -> [String] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.prefix(8).map { $0 }
    }
}
