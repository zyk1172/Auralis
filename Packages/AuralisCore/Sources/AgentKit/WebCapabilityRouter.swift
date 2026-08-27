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
    private var sources: [String: WebSource] = [:]
    private var activeRunID: UUID?

    public init() {}

    public func beginRun(_ runID: UUID) {
        activeRunID = runID
        urls.removeAll(keepingCapacity: true)
        sources.removeAll(keepingCapacity: true)
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
        for source in sources {
            self.sources[WebSource.canonicalURL(source.url).absoluteString] = source
        }
    }

    public func allows(_ url: URL) -> Bool {
        guard activeRunID != nil else { return false }
        return urls.contains(WebSource.canonicalURL(url).absoluteString)
    }

    public func source(for url: URL) -> WebSource? {
        guard activeRunID != nil else { return nil }
        return sources[WebSource.canonicalURL(url).absoluteString]
    }
}

/// Reference storage lets a long-lived value-type router refresh its backend
/// without replacing the Coordinator or invalidating its run-scoped fetch
/// state. The lock only protects the short backend snapshot/set operations;
/// backend requests themselves remain fully asynchronous.
private final class WebCapabilityRouterState: @unchecked Sendable {
    private let lock = NSLock()
    private var backend: (any AgentWebSearchBackend)?

    init(backend: (any AgentWebSearchBackend)?) {
        self.backend = backend
    }

    func get() -> (any AgentWebSearchBackend)? {
        lock.lock()
        defer { lock.unlock() }
        return backend
    }

    func set(_ backend: (any AgentWebSearchBackend)?) {
        lock.lock()
        self.backend = backend
        lock.unlock()
    }
}

/// Selects a web backend by capability, keeping the limited DDG Instant Answer
/// implementation visibly separate from a real full-search backend.
public struct WebCapabilityRouter: AgentWebRunScopedService, AgentWebSearchOptionsBackend, Sendable {
    private let hostedSearchAvailable: Bool
    private let configuredState: WebCapabilityRouterState
    private let instantAnswerFallback: (any AgentWebSearchBackend)?
    private let fetchScope: WebFetchURLScope

    public init(
        hostedSearchAvailable: Bool = false,
        configuredFullSearch: (any AgentWebSearchBackend)? = nil,
        instantAnswerFallback: (any AgentWebSearchBackend)? = nil,
        fetchScope: WebFetchURLScope = WebFetchURLScope()
    ) {
        self.hostedSearchAvailable = hostedSearchAvailable
        self.configuredState = WebCapabilityRouterState(backend: configuredFullSearch)
        self.instantAnswerFallback = instantAnswerFallback
        self.fetchScope = fetchScope
    }

    /// Refresh the configured full-search backend in place. Copies of this
    /// router share the same state, so a Coordinator can keep its long-lived
    /// service while settings changes take effect on the next run.
    public func setConfiguredFullSearch(_ backend: (any AgentWebSearchBackend)?) {
        configuredState.set(backend)
    }

    /// The capability that should be advertised to a model-facing caller.
    /// Hosted search has priority even though the local `search` method is only
    /// used when the caller has chosen the local fallback path.
    public var capability: WebSearchCapability {
        let configuredFullSearch = configuredState.get()
        if hostedSearchAvailable { return .hostedFullSearch }
        if configuredFullSearch != nil { return .configuredFullSearch }
        if instantAnswerFallback != nil { return .instantAnswerFallback }
        return .unavailable
    }

    /// Capability available through this local service, excluding a Provider's
    /// server-side tool. Useful for diagnostics and tests.
    public var localCapability: WebSearchCapability {
        let configuredFullSearch = configuredState.get()
        if configuredFullSearch != nil { return .configuredFullSearch }
        if instantAnswerFallback != nil { return .instantAnswerFallback }
        return .unavailable
    }

    public func beginRun(_ runID: UUID) async {
        await fetchScope.beginRun(runID)
        let configuredFullSearch = configuredState.get()
        if let scoped = configuredFullSearch as? any AgentWebRunScopedService {
            await scoped.beginRun(runID)
        }
        if let scoped = instantAnswerFallback as? any AgentWebRunScopedService {
            await scoped.beginRun(runID)
        }
    }

    public func register(sources: [WebSource], runID: UUID) async {
        await fetchScope.register(sources: sources, runID: runID)
        let configuredFullSearch = configuredState.get()
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
        let configuredFullSearch = configuredState.get()
        if let configuredFullSearch {
            do {
                let result: WebSearchResult
                if let optionsBackend = configuredFullSearch as? any AgentWebSearchOptionsBackend {
                    result = try await optionsBackend.search(query: query, options: options)
                } else {
                    result = try await configuredFullSearch.search(query: query, limit: options.limit)
                }
                if let runID { await fetchScope.register(sources: result.sources, runID: runID) }
                return result
            } catch {
                // A configured backend is preferred, but its missing key,
                // outage, or rate limit must not remove the existing DDG
                // fallback from ordinary App operation.
                guard let instantAnswerFallback else { throw error }
                let result = try await instantAnswerFallback.search(query: query, limit: options.limit)
                if let runID { await fetchScope.register(sources: result.sources, runID: runID) }
                return result
            }
        }
        guard let instantAnswerFallback else {
            throw WebCapabilityError.invalidResponse
        }
        let result = try await instantAnswerFallback.search(query: query, limit: options.limit)
        if let runID { await fetchScope.register(sources: result.sources, runID: runID) }
        return result
    }

    public func fetch(url: URL) async throws -> WebDocument {
        guard await fetchScope.allows(url) else {
            throw WebCapabilityError.fetchRequiresSearchResult
        }
        let configuredFullSearch = configuredState.get()
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
            } catch WebCapabilityError.unsupportedContentType {
                // Search snippets are already bounded, attributed, and in the
                // current run's scope. Prefer that evidence over failing the
                // entire tool call when a source serves an unsupported MIME.
                if let source = await fetchScope.source(for: url), !source.snippet.isEmpty {
                    return WebDocument(source: source, text: source.snippet)
                }
                if let instantAnswerFallback {
                    return try await instantAnswerFallback.fetch(url: url)
                }
                throw WebCapabilityError.invalidResponse
            }
        }
        guard let instantAnswerFallback else {
            throw WebCapabilityError.invalidResponse
        }
        return try await instantAnswerFallback.fetch(url: url)
    }
}
