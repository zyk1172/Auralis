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

/// Optional run-scoped extension for services that enforce that `web_fetch`
/// can only read URLs returned during the current assistant run. Existing test
/// or app-provided `AgentWebService` implementations remain source-compatible.
public protocol AgentWebRunScopedService: AgentWebService {
    func beginRun(_ runID: UUID) async
    func register(sources: [WebSource]) async
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

    public func record(_ urls: [URL]) {
        self.urls.formUnion(urls.map { WebSource.canonicalURL($0).absoluteString })
    }

    public func register(sources: [WebSource]) {
        record(sources.map(\.url))
    }

    public func allows(_ url: URL) -> Bool {
        _ = activeRunID
        return urls.contains(WebSource.canonicalURL(url).absoluteString)
    }
}

/// Selects a web backend by capability, keeping the limited DDG Instant Answer
/// implementation visibly separate from a real full-search backend.
public struct WebCapabilityRouter: AgentWebRunScopedService, AgentWebSearchBackend, Sendable {
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

    public func register(sources: [WebSource]) async {
        await fetchScope.register(sources: sources)
        if let scoped = configuredFullSearch as? any AgentWebRunScopedService {
            await scoped.register(sources: sources)
        }
        if let scoped = instantAnswerFallback as? any AgentWebRunScopedService {
            await scoped.register(sources: sources)
        }
    }

    public func search(query: String, limit: Int) async throws -> WebSearchResult {
        if let configuredFullSearch {
            let result = try await configuredFullSearch.search(query: query, limit: limit)
            await fetchScope.record(result.sources.map(\.url))
            return result
        }
        guard let instantAnswerFallback else {
            throw WebCapabilityError.invalidResponse
        }
        let result = try await instantAnswerFallback.search(query: query, limit: limit)
        await fetchScope.record(result.sources.map(\.url))
        return result
    }

    public func fetch(url: URL) async throws -> WebDocument {
        guard await fetchScope.allows(url) else {
            throw WebCapabilityError.fetchRequiresSearchResult
        }
        if let configuredFullSearch {
            return try await configuredFullSearch.fetch(url: url)
        }
        guard let instantAnswerFallback else {
            throw WebCapabilityError.invalidResponse
        }
        return try await instantAnswerFallback.fetch(url: url)
    }
}
