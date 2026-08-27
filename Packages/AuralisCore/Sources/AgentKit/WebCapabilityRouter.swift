import AIKit
import Foundation

/// Web search backend capability. A hosted capability is selected by the
/// Provider request codec; local backends remain the fallback for providers
/// without a real server-side web tool.
public enum WebSearchCapability: String, Codable, Hashable, Sendable {
    case hostedFullSearch
    case configuredFullSearch
    case instantAnswerFallback
    case unavailable
}

/// A local or configured full-search backend. Hosted Provider tools do not
/// conform to this protocol because they execute inside the Provider request.
public protocol AgentWebSearchBackend: AgentWebService {
    var capability: WebSearchCapability { get }
}

/// Optional extension for full-search providers with bounded domain filters.
/// Existing backends remain source-compatible through the default adapter.
public protocol AgentWebSearchOptionsBackend: AgentWebSearchBackend {
    func search(query: String, options: WebSearchOptions) async throws -> WebSearchResult
}

public extension AgentWebSearchBackend {
    func search(query: String, options: WebSearchOptions) async throws -> WebSearchResult {
        try await search(query: query, limit: options.limit)
    }
}

/// Optional run-scoped extension for services that enforce that `web_fetch`
/// can only read URLs returned during the current assistant run. Existing test
/// or app-provided `AgentWebService` implementations remain source-compatible.
public protocol AgentWebRunScopedService: AgentWebService {
    func beginRun(_ runID: UUID) async
    func register(sources: [WebSource], runID: UUID) async
}

/// Per-conversation capability scope for local web fetches. Search results are
/// data, not authorization for side effects, but they are the only URL sources
/// allowed into the default fetch path when IP pinning is unavailable.
public actor WebFetchURLScope {
    private var urls: Set<String> = []
    private var activeRunID: UUID?

    public init() {}

    public func beginRun(_ runID: UUID) {
        activeRunID = runID
        urls.removeAll(keepingCapacity: true)
    }

    public func currentRunID() -> UUID? { activeRunID }

    public func record(_ urls: [URL]) {
        guard activeRunID != nil else { return }
        self.urls.formUnion(urls.map { WebSource.canonicalURL($0).absoluteString })
    }

    public func record(_ urls: [URL], runID: UUID) {
        guard activeRunID == runID else { return }
        record(urls)
    }

    public func register(sources: [WebSource], runID: UUID) {
        guard activeRunID == runID else { return }
        record(sources.map(\.url))
    }

    public func allows(_ url: URL) -> Bool {
        guard activeRunID != nil else { return false }
        return urls.contains(WebSource.canonicalURL(url).absoluteString)
    }
}

/// Selects a web backend by capability, keeping the limited DDG Instant Answer
/// implementation visibly separate from a real full-search backend.
public struct WebCapabilityRouter: AgentWebRunScopedService, AgentWebSearchOptionsBackend, Sendable {
    private let hostedSearchAvailable: Bool
    private let configuredFullSearch: (any AgentWebSearchBackend)?
    private let instantAnswerFallback: (any AgentWebSearchBackend)?
    private let fetchScope: WebFetchURLScope

    public init(
        hostedSearchAvailable: Bool = false,
        configuredFullSearch: (any AgentWebSearchBackend)? = nil,
        instantAnswerFallback: (any AgentWebSearchBackend)? = nil,
        fetchScope: WebFetchURLScope = WebFetchURLScope()
    ) {
        self.hostedSearchAvailable = hostedSearchAvailable
        self.configuredFullSearch = configuredFullSearch
        self.instantAnswerFallback = instantAnswerFallback
        self.fetchScope = fetchScope
    }

    /// The capability that should be advertised to a model-facing caller.
    /// Hosted search has priority even though the local `search` method is only
    /// used when the caller has chosen the local fallback path.
    public var capability: WebSearchCapability {
        if hostedSearchAvailable { return .hostedFullSearch }
        if configuredFullSearch != nil { return .configuredFullSearch }
        if instantAnswerFallback != nil { return .instantAnswerFallback }
        return .unavailable
    }

    /// Capability available through this local service, excluding a Provider's
    /// server-side tool. Useful for diagnostics and tests.
    public var localCapability: WebSearchCapability {
        if configuredFullSearch != nil { return .configuredFullSearch }
        if instantAnswerFallback != nil { return .instantAnswerFallback }
        return .unavailable
    }

    public func beginRun(_ runID: UUID) async {
        await fetchScope.beginRun(runID)
        if let scoped = configuredFullSearch as? any AgentWebRunScopedService {
            await scoped.beginRun(runID)
        }
        if let scoped = instantAnswerFallback as? any AgentWebRunScopedService {
            await scoped.beginRun(runID)
        }
    }

    public func register(sources: [WebSource], runID: UUID) async {
        await fetchScope.register(sources: sources, runID: runID)
        if let scoped = configuredFullSearch as? any AgentWebRunScopedService {
            await scoped.register(sources: sources, runID: runID)
        }
        if let scoped = instantAnswerFallback as? any AgentWebRunScopedService {
            await scoped.register(sources: sources, runID: runID)
        }
    }

    public func search(query: String, limit: Int) async throws -> WebSearchResult {
        try await search(query: query, options: WebSearchOptions(limit: limit))
    }

    public func search(query: String, options: WebSearchOptions) async throws -> WebSearchResult {
        let runID = await fetchScope.currentRunID()
        if let configuredFullSearch {
            do {
                let result: WebSearchResult
                if let optionsBackend = configuredFullSearch as? any AgentWebSearchOptionsBackend {
                    result = try await optionsBackend.search(query: query, options: options)
                } else {
                    result = try await configuredFullSearch.search(query: query, limit: options.limit)
                }
                if let runID { await fetchScope.record(result.sources.map(\.url), runID: runID) }
                return result
            } catch {
                // A configured backend is preferred, but its missing key,
                // outage, or rate limit must not remove the existing DDG
                // fallback from ordinary App operation.
                guard let instantAnswerFallback else { throw error }
                let result = try await instantAnswerFallback.search(query: query, limit: options.limit)
                if let runID { await fetchScope.record(result.sources.map(\.url), runID: runID) }
                return result
            }
        }
        guard let instantAnswerFallback else {
            throw WebCapabilityError.invalidResponse
        }
        let result = try await instantAnswerFallback.search(query: query, limit: options.limit)
        if let runID { await fetchScope.record(result.sources.map(\.url), runID: runID) }
        return result
    }

    public func fetch(url: URL) async throws -> WebDocument {
        guard await fetchScope.allows(url) else {
            throw WebCapabilityError.fetchRequiresSearchResult
        }
        if let configuredFullSearch {
            do {
                return try await configuredFullSearch.fetch(url: url)
            } catch WebCapabilityError.fetchRequiresSearchResult {
                // A search outage may have returned a URL from the DDG
                // fallback. Let the backend that produced that URL enforce
                // its own run scope instead of asking Tavily to read it.
                if let instantAnswerFallback {
                    return try await instantAnswerFallback.fetch(url: url)
                }
                throw WebCapabilityError.fetchRequiresSearchResult
            }
        }
        guard let instantAnswerFallback else {
            throw WebCapabilityError.invalidResponse
        }
        return try await instantAnswerFallback.fetch(url: url)
    }
}
