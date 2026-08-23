import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

/// Provider stub that speaks the same native streaming protocol as the
/// production loop. Each request consumes one scripted response and the full
/// request transcript is retained for protocol/capability assertions.
private final class ScenarioProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [AICompletionResponse]
    private var recordedRequests: [AICompletionRequest] = []

    let capabilities = ModelCapabilities(
        maxContextTokens: 32_000,
        maxOutputTokens: 4_096,
        supportsToolCalling: true,
        supportsParallelTools: true,
        supportsToolChoice: true,
        supportsStrictSchema: true,
        supportsStreaming: true,
        toolMode: .openAIChat
    )

    var supportsToolCalling: Bool { true }

    init(_ responses: [AICompletionResponse]) {
        self.responses = responses
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "scenario", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        nextResponse(for: request)
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let response = nextResponse(for: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(model: response.model))
            if let citations = response.webCitations, !citations.isEmpty {
                continuation.yield(.webCitations(citations))
            }
            if let calls = response.toolCalls, !calls.isEmpty {
                for call in calls {
                    continuation.yield(.toolCall(call))
                }
            } else if !response.content.isEmpty {
                continuation.yield(.delta(response.content))
            }
            continuation.yield(.completed)
            continuation.finish()
        }
    }

    func requests() -> [AICompletionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private func nextResponse(for request: AICompletionRequest) -> AICompletionResponse {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        guard !responses.isEmpty else {
            return AICompletionResponse(model: request.model, content: "脚本已耗尽。")
        }
        return responses.removeFirst()
    }
}

/// Native provider that keeps returning a transient server failure. The
/// scenario asserts that retries preserve the native request shape instead of
/// switching the same task to ACTION or a local music rule engine.
private final class FailingNativeScenarioProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [AICompletionRequest] = []
    private let failure = AIProviderError.httpStatus(503)

    let capabilities = ModelCapabilities(
        maxContextTokens: 32_000,
        maxOutputTokens: 4_096,
        supportsToolCalling: true,
        supportsParallelTools: true,
        supportsToolChoice: true,
        supportsStrictSchema: true,
        supportsStreaming: true,
        toolMode: .openAIChat
    )

    var supportsToolCalling: Bool { true }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "failing-native", message: "unavailable")
    }

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        record(request)
        throw failure
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        record(request)
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: failure)
        }
    }

    func requests() -> [AICompletionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private func record(_ request: AICompletionRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }
}

private struct ScenarioWebService: AgentWebService {
    let source: WebSource

    func search(query: String, limit: Int) async throws -> WebSearchResult {
        WebSearchResult(query: query, sources: [source])
    }

    func fetch(url: URL) async throws -> WebDocument {
        WebDocument(source: source, text: "外部网页正文")
    }
}

/// Minimal system double for the system-tool path. The audio route value is
/// intentionally concrete so the scenario proves the second tool really ran.
private final class ScenarioSystemService: AgentSystemService, @unchecked Sendable {
    func appContext() async -> AgentAppContext { AgentAppContext() }
    func openPage(_ page: String) async -> Bool { true }
    func featureStatus() async -> AgentFeatureStatus { AgentFeatureStatus() }
    func networkStatus() async -> AgentNetworkStatus { AgentNetworkStatus(isServerReachable: true) }
    func audioRoute() async -> AgentAudioRoute { AgentAudioRoute(outputName: "测试耳机", outputType: "headphones") }
    func storageStatus() async -> AgentStorageStatus { AgentStorageStatus() }
    func listServers() async -> [AgentServerInfo] { [] }
    func currentServer() async -> AgentServerInfo? { nil }
    func testServerConnection() async -> AgentConnectionTestResult { AgentConnectionTestResult(success: true) }
    func serverCapabilities() async -> AgentCapabilitiesSummary { AgentCapabilitiesSummary() }
    func syncStatus() async -> AgentSyncStatus { AgentSyncStatus() }
    func lyrics(for trackID: TrackID) async -> AgentLyricsResult { AgentLyricsResult() }
    func downloadOffline(trackID: TrackID) async -> Bool { true }
    func cacheStatus() async -> AgentCacheStatus { AgentCacheStatus() }
    func nowPlayingStatus() async -> AgentNowPlayingStatus { AgentNowPlayingStatus() }
    func brokenArtwork(limit: Int) async -> [String] { [] }
    func staleCache(limit: Int) async -> [String] { [] }
    func recentlyAdded(days: Int, limit: Int) async -> [TrackCard] { [] }
    func mostPlayed(limit: Int) async -> [TrackCard] { [] }
    func topItems(kind: String, limit: Int) async -> [AgentTopItem] { [] }
    func formatDistribution() async -> [AgentFormatCount] { [] }
    func recommendByMood(_ mood: String, limit: Int) async -> AgentRecommendationResult {
        AgentRecommendationResult(mood: mood, tracks: [])
    }
    func recommendByConstraints(_ constraints: AgentRecommendationConstraints) async -> AgentRecommendationResult {
        AgentRecommendationResult(mood: "约束", tracks: [])
    }
    func diagnosticsReport() async -> String { "诊断报告" }
    func listeningSummary() async -> AgentListeningSummary { AgentListeningSummary() }
    func playbackDiagnostics() async -> AgentPlaybackDiagnostics { AgentPlaybackDiagnostics() }
    func recentErrors(limit: Int) async -> [AgentErrorRecord] { [] }
}

private actor ScenarioMessageCollector {
    private var messages: [AgentChatMessage] = []

    func append(_ message: AgentChatMessage) { messages.append(message) }
    func all() -> [AgentChatMessage] { messages }

    func containsText(_ text: String) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .text(value) = item { return value.contains(text) }
                return false
            }
        }
    }

    func containsError(_ text: String) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .error(value) = item { return value.contains(text) }
                return false
            }
        }
    }

    func containsWebSource(_ url: URL) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .webSources(sources) = item {
                    return sources.contains { $0.url == url }
                }
                return false
            }
        }
    }
}

private actor ScenarioStateProbe {
    private(set) var calls = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}

private func scenarioStore() throws -> LocalCatalogStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-agent-scenario-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
}

private func scenarioTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: serverID,
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "Billie Eilish",
        albumTitle: "HIT ME HARD AND SOFT",
        duration: 210
    )
}

private func seedScenario(_ store: LocalCatalogStore, tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

private func scenarioCall(
    id: String,
    name: String,
    arguments: [String: AIJSONValue] = [:]
) -> AIToolCall {
    AIToolCall(id: id, name: name, arguments: .object(arguments))
}

private func scenarioResponse(
    content: String = "",
    calls: [AIToolCall] = [],
    citations: [AIWebCitation] = []
) -> AICompletionResponse {
    AICompletionResponse(
        model: "scenario",
        content: content,
        toolCalls: calls.isEmpty ? nil : calls,
        webCitations: citations.isEmpty ? nil : citations
    )
}

@Test("V2 production loop: ordinary conversation completes without music tools or task evaluator")
func ordinaryConversationIsFirstClass() async throws {
    let provider = ScenarioProvider([
        scenarioResponse(content: "黑洞信息悖论讨论的是量子力学与广义相对论之间的张力。")
    ])
    let store = try scenarioStore()
    let bridge = MockAgentBridge()
    let collector = ScenarioMessageCollector()
    let stateProbe = ScenarioStateProbe()

    await ConversationEngine().run(
        userText: "解释一下黑洞信息悖论。",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(),
        intent: .conversation,
        policy: AgentTaskPolicy.policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) },
        state: { _ in await stateProbe.record() }
    )

    #expect(await collector.containsText("黑洞信息悖论"))
    #expect(bridge.playedTracks.isEmpty)
    #expect(bridge.replacedQueues.isEmpty)
    #expect(await stateProbe.count() == 0)
    #expect(provider.requests().count == 1)
}

@Test("V2 provider failure retries the selected native protocol without ACTION or offline fallback")
func providerFailureKeepsNativeProtocol() async throws {
    let provider = FailingNativeScenarioProvider()
    let store = try scenarioStore()
    let bridge = MockAgentBridge()
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "播放一首歌",
        provider: provider,
        model: "failing-native",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(serverID: "scenario-server"),
        intent: .playbackControl,
        policy: AgentTaskPolicy.policy(for: .playbackControl),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    let requests = provider.requests()
    #expect(requests.count >= 2)
    #expect(requests.allSatisfy { !($0.tools ?? []).isEmpty })
    #expect(bridge.playedTracks.isEmpty)
    #expect(await collector.containsError("原生工具协议请求失败"))
    #expect(await collector.containsText("本地能力") == false)
}

@Test("V2 production loop: tool_search expands a conversation capability after an intent miss")
func toolSearchExpandsDeviceCapability() async throws {
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "search-1",
            name: "tool_search",
            arguments: ["query": .string("音频输出设备")]
        )]),
        scenarioResponse(calls: [scenarioCall(id: "route-1", name: "device_get_audio_route")]),
        scenarioResponse(content: "当前音频输出是测试耳机。"),
    ])
    let store = try scenarioStore()
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "告诉我一个系统事实。",
        provider: provider,
        model: "scenario",
        bridge: MockAgentBridge(),
        catalog: store,
        context: ToolLoop.Context(),
        systemService: ScenarioSystemService(),
        // Deliberately pass the generic intent: the initial schema must not
        // be the permanent capability boundary.
        intent: .conversation,
        policy: AgentTaskPolicy.policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    let requests = provider.requests()
    let firstTools = Set(requests.first?.tools?.map(\.name) ?? [])
    let secondTools = Set(requests.dropFirst().first?.tools?.map(\.name) ?? [])
    #expect(!firstTools.contains("device_get_audio_route"))
    #expect(secondTools.contains("device_get_audio_route"))
    #expect(await collector.containsText("当前音频输出是测试耳机"))
}

@Test("V2 production loop: parallel read-only calls retain ids and replay all results")
func parallelReadOnlyCallsKeepAssociations() async throws {
    let provider = ScenarioProvider([
        scenarioResponse(calls: [
            scenarioCall(id: "route-1", name: "device_get_audio_route"),
            scenarioCall(id: "network-1", name: "device_get_network_status"),
        ]),
        scenarioResponse(content: "设备状态已读取。"),
    ])
    let store = try scenarioStore()
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "告诉我网络和音频输出设备状态。",
        provider: provider,
        model: "scenario",
        bridge: MockAgentBridge(),
        catalog: store,
        context: ToolLoop.Context(),
        systemService: ScenarioSystemService(),
        intent: .conversation,
        policy: AgentTaskPolicy.policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    let requests = provider.requests()
    guard requests.count == 2 else {
        Issue.record("并行场景实际请求数为 (requests.count)，预期为 2")
        return
    }
    let resultMessages = requests[1].messages.filter { $0.role == .tool }
    #expect(resultMessages.map(\.toolCallID) == ["route-1", "network-1"])
    #expect(await collector.containsText("设备状态已读取"))
}

@Test("V2 production loop: web result flows into library lookup and real playback")
func webLibraryPlaybackScenario() async throws {
    let sourceURL = URL(string: "https://news.example.test/billie")!
    let source = WebSource(
        title: "Billie Eilish news",
        url: sourceURL,
        snippet: "A recent release update.",
        publishedAt: "2026-08-23",
        backend: "fake-web",
        sourceType: "search"
    )
    let serverID: ServerID = "scenario-server"
    let track = scenarioTrack(serverID: serverID, remoteID: "ocean-eyes", title: "Ocean Eyes")
    let gid = GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    let store = try scenarioStore()
    try await seedScenario(store, tracks: [track])
    let bridge = MockAgentBridge()
    let collector = ScenarioMessageCollector()
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "web-1",
            name: "web_search",
            arguments: ["query": .string("Billie Eilish 最近新闻")]
        )]),
        scenarioResponse(calls: [scenarioCall(
            id: "library-1",
            name: "library_search",
            arguments: ["query": .string("Billie Eilish"), "kind": .string("song")]
        )]),
        scenarioResponse(calls: [scenarioCall(
            id: "play-1",
            name: "playback_play_song",
            arguments: ["trackID": .string(gid.description)]
        )]),
        scenarioResponse(content: "我找到曲库中的 Ocean Eyes，并已开始播放。"),
    ])

    await ConversationEngine().run(
        userText: "搜索 Billie Eilish 最近的新闻，再看看曲库里有没有她的新歌，有的话播放一首。",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(serverID: serverID),
        webService: ScenarioWebService(source: source),
        // Simulate an initial classifier miss: generic chat still owns the
        // provider/tool loop and does not lose web or music capabilities.
        intent: .conversation,
        policy: AgentTaskPolicy.policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    #expect(bridge.playedTracks == [gid])
    #expect(await collector.containsWebSource(sourceURL))
    #expect(await collector.containsText("已开始播放"))

    let requests = provider.requests()
    #expect(requests.count == 4)
    #expect(requests.dropFirst().first?.messages.contains { message in
        message.content.contains("[EXTERNAL_UNTRUSTED_CONTENT]")
    } == true)
}
