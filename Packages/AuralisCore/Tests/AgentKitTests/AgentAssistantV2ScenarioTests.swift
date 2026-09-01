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

    let capabilities: ModelCapabilities

    var supportsToolCalling: Bool { capabilities.supportsToolCalling }

    init(_ responses: [AICompletionResponse], nativeToolCalling: Bool = true) {
        self.responses = responses
        self.capabilities = ModelCapabilities(
            maxContextTokens: 32_000,
            maxOutputTokens: 4_096,
            supportsToolCalling: nativeToolCalling,
            supportsParallelTools: nativeToolCalling,
            supportsToolChoice: nativeToolCalling,
            supportsStrictSchema: nativeToolCalling,
            supportsStreaming: true,
            toolMode: nativeToolCalling ? .openAIChat : AIProviderToolMode.none
        )
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
                continuation.yield(.answerDelta(response.content))
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

private struct EmptyScenarioWebService: AgentWebService {
    func search(query: String, limit: Int) async throws -> WebSearchResult {
        WebSearchResult(query: query, sources: [])
    }

    func fetch(url: URL) async throws -> WebDocument {
        throw WebCapabilityError.fetchRequiresSearchResult
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

    func artistCardCounts() -> [Int] {
        messages.flatMap { message in
            message.messages.compactMap { item -> Int? in
                if case let .artistCards(cards) = item { return cards.count }
                return nil
            }
        }
    }

    func containsText(_ text: String) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .text(value) = item { return value.contains(text) }
                return false
            }
        }
    }

    func joinedText() -> String {
        messages.flatMap { message in
            message.messages.compactMap { item -> String? in
                if case let .text(value) = item { return value }
                return nil
            }
        }.joined(separator: "\n")
    }

    func playlistCardCounts() -> [Int] {
        messages.flatMap { message in
            message.messages.compactMap { item -> Int? in
                if case let .playlistCards(cards) = item { return cards.count }
                return nil
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

private func seedScenarioArtists(_ store: LocalCatalogStore, serverID: ServerID) async throws {
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageArtists([
        Artist(id: "artist", serverID: serverID, name: "Billie Eilish", albumCount: 1)
    ], session: session)
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

@Test("Deterministic collection/status reads bypass planning and execute one canonical tool")
func deterministicReadFastPathUsesExactlyOneTargetTool() async throws {
    let cases: [(String, String, [String: AIJSONValue])] = [
        ("列出我的歌单", "playlist_list", [:]),
        ("当前正在播放什么", "playback_get_state", [:]),
        ("播放队列里现在有哪些歌", "queue_get", [:]),
        ("查看曲库统计", "library_get_summary", [:]),
        ("列出艺术家", "library_get_artists", [:]),
        ("列出专辑", "library_get_albums", [:]),
        ("列出服务器", "server_list", [:]),
    ]

    for (userText, expectedTool, expectedArguments) in cases {
        #expect(AgentRequestSemantics.analyze(userText).directReadCapability?.arguments == expectedArguments)
        let runID = UUID()
        let provider = ScenarioProvider([
            scenarioResponse(content: "不应进入 provider 规划")
        ])
        let collector = ScenarioMessageCollector()
        let catalog = try scenarioStore()
        if expectedTool == "library_get_artists" {
            try await seedScenarioArtists(catalog, serverID: "scenario-server")
        }

        await ConversationEngine().run(
            userText: userText,
            provider: provider,
            model: "scenario",
            bridge: MockAgentBridge(),
            catalog: catalog,
            context: expectedTool == "library_get_artists"
                ? ToolLoop.Context(serverID: "scenario-server")
                : ToolLoop.Context(),
            systemService: expectedTool == "server_list" ? ScenarioSystemService() : nil,
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { message in await collector.append(message) }
        )

        #expect(provider.requests().isEmpty, "\(userText) 不应发起模型规划")
        let metrics = await ToolMetricsCollector.shared.snapshot().filter { $0.runID == runID }
        #expect(metrics.map(\.toolName) == [expectedTool], "\(userText) 应只执行 \(expectedTool)")
        #expect(!(await collector.containsError("失败")), "\(userText) 的 direct tool 不应返回失败")
        if expectedTool == "library_get_artists" {
            #expect(await collector.artistCardCounts() == [1])
        }
    }
}

@Test("Direct read fast path preserves an explicit list limit")
func deterministicPlaylistListFastPathPreservesLimit() async throws {
    let serverID: ServerID = "scenario-server"
    let catalog = try scenarioStore()
    for index in 0..<15 {
        try await catalog.upsertPlaylist(
            Playlist(
                id: PlaylistID(rawValue: "playlist-\(index)"),
                serverID: serverID,
                name: "Playlist-\(index < 10 ? "0\(index)" : "\(index)")",
                trackIDs: []
            ),
            serverID: serverID,
            isReadOnly: false
        )
    }

    let semantics = AgentRequestSemantics.analyze("列出前 10 个歌单")
    #expect(semantics.directReadCapability?.toolName == "playlist_list")
    #expect(semantics.directReadCapability?.arguments == ["limit": .number(10)])

    let runID = UUID()
    let provider = ScenarioProvider([scenarioResponse(content: "不应进入 provider 规划")])
    let collector = ScenarioMessageCollector()
    await ConversationEngine().run(
        userText: "列出前 10 个歌单",
        provider: provider,
        model: "scenario",
        bridge: MockAgentBridge(),
        catalog: catalog,
        context: ToolLoop.Context(serverID: serverID),
        runID: runID,
        executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    #expect(provider.requests().isEmpty)
    let metrics = await ToolMetricsCollector.shared.snapshot().filter { $0.runID == runID }
    #expect(metrics.map(\.toolName) == ["playlist_list"])
    #expect(await collector.playlistCardCounts() == [10])
}

@Test("Library summary counts distinct artist and album IDs")
func librarySummaryUsesEntityIdentityInsteadOfDisplayNames() async throws {
    let serverID: ServerID = "summary-server"
    let tracks = [
        Track(
            id: "track-a",
            serverID: serverID,
            albumID: "album-a",
            artistID: "artist-a",
            title: "同名歌曲 A",
            artistName: "同名艺术家",
            albumTitle: "同名专辑",
            duration: 180
        ),
        Track(
            id: "track-b",
            serverID: serverID,
            albumID: "album-b",
            artistID: "artist-b",
            title: "同名歌曲 B",
            artistName: "同名艺术家",
            albumTitle: "同名专辑",
            duration: 180
        ),
    ]
    let catalog = try scenarioStore()
    try await seedScenario(catalog, tracks: tracks)

    let result = await ToolRuntime.execute(
        ToolCall(name: "library_get_summary"),
        bridge: MockAgentBridge(),
        catalog: catalog,
        serverID: serverID,
        systemService: nil,
        executionLease: ToolExecutionLease(runID: UUID(), sessionID: UUID(), generation: 1)
    )

    #expect(result.success)
    #expect(result.summary.contains("2 首歌曲"))
    #expect(result.summary.contains("2 位艺术家"))
    #expect(result.summary.contains("2 张专辑"))
}

@Test("V2 production loop: native tools unavailable still permits ordinary chat")
func ordinaryChatSurvivesUnavailableNativeTools() async throws {
    let provider = ScenarioProvider([
        scenarioResponse(content: "量子力学描述微观尺度的规律。")
    ], nativeToolCalling: false)
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "解释一下量子力学。",
        provider: provider,
        model: "scenario",
        bridge: MockAgentBridge(),
        catalog: try scenarioStore(),
        context: ToolLoop.Context(),
        intent: .conversation,
        policy: .policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    #expect(await collector.containsText("量子力学"))
    #expect(provider.requests().count == 1)
    #expect(provider.requests().first?.tools?.isEmpty != false)
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

@Test("V2 production loop: tool_search expands a synthetic obscure tool with no preset utterance examples")
func toolSearchExpandsSyntheticObscureTool() async throws {
    let registry = CustomToolRegistry(storageURL: nil)
    _ = try await registry.create(CustomToolManifest(
        name: "test_obscure_music_analysis",
        description: "分析特殊音乐元数据并返回结构化只读证据",
        implementation: .workflow(steps: [CustomToolStep(tool: "library_get_summary")])
    ))
    let syntheticName = try #require(
        await registry.modelDescriptors().first?.name
    )
    let context = ToolLoop.Context(customToolRegistry: registry)
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "discover-obscure",
            name: "tool_search",
            arguments: ["query": .string("特殊音乐分析")]
        )]),
        scenarioResponse(calls: [scenarioCall(
            id: "run-obscure",
            name: syntheticName,
            arguments: [:]
        )]),
        scenarioResponse(content: "特殊音乐分析已完成。"),
    ])
    let store = try scenarioStore()
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "告诉我一个系统事实。",
        provider: provider,
        model: "scenario",
        bridge: MockAgentBridge(),
        catalog: store,
        context: context,
        systemService: ScenarioSystemService(),
        intent: .conversation,
        policy: AgentTaskPolicy.policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    let requests = provider.requests()
    let firstTools = Set(requests.first?.tools?.map(\.name) ?? [])
    let secondTools = Set(requests.dropFirst().first?.tools?.map(\.name) ?? [])
    #expect(!firstTools.contains(syntheticName))
    #expect(secondTools.contains(syntheticName))
    #expect(requests.dropFirst().dropFirst().first?.messages.contains(where: { $0.role == .tool && $0.content.contains("已执行自建工具") }) == true)
    #expect(await collector.containsText("特殊音乐分析已完成"))
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
    let runID = UUID()
    let executionLease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)
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
        runID: runID,
        executionLease: executionLease,
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

@Test("外部网页数据不能绕过 destructive confirmation")
func externalWebDataCannotBypassDestructiveConfirmation() async throws {
    let runID = UUID()
    let executionLease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)
    let source = WebSource(
        title: "科技新闻",
        url: URL(string: "https://news.example.test/technology")!,
        snippet: "新闻正文",
        backend: "fake-web",
        sourceType: "search"
    )
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "web-1",
            name: "web_search",
            arguments: ["query": .string("今天的科技新闻")]
        )]),
        // 模拟模型被网页中的指令诱导；原始用户请求只要求读取新闻。
        scenarioResponse(calls: [scenarioCall(id: "clear-1", name: "queue_clear")]),
        scenarioResponse(content: "新闻已读取，未执行网页中的其他指令。"),
    ])
    let store = try scenarioStore()
    let bridge = MockAgentBridge()
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "查一下今天的科技新闻。",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(),
        systemService: ScenarioSystemService(),
        webService: ScenarioWebService(source: source),
        intent: .conversation,
        policy: AgentTaskPolicy.policy(for: .conversation),
        runID: runID,
        executionLease: executionLease,
        confirm: { _ in false },
        emit: { message in await collector.append(message) }
    )

    #expect(bridge.clearedQueueCount == 0)
    let requests = provider.requests()
    #expect(requests.dropFirst(2).first?.messages.contains { message in
        !message.content.contains("不能授权此操作") &&
        (message.content.contains("确认") || message.content.contains("清空"))
    } == true)
    #expect(await collector.containsText("未执行网页中的其他指令"))
}

@Test("continuation keeps the original side-effect authorization")
func continuationKeepsOriginalAuthorization() async throws {
    let runID = UUID()
    let executionLease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)
    let serverID: ServerID = "continuation-server"
    let track = scenarioTrack(serverID: serverID, remoteID: "sunset", title: "Sunset")
    let gid = GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    let store = try scenarioStore()
    try await seedScenario(store, tracks: [track])
    let bridge = MockAgentBridge()
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "play-first",
            name: "playback_play_song",
            arguments: ["trackID": .string(gid.description)]
        )]),
        scenarioResponse(content: "已播放第一个版本。"),
    ])

    await ConversationEngine().run(
        userText: "第一个",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(serverID: serverID),
        history: [AgentChatMessage(role: .user, messages: [.text("播放专辑里的 Sunset")])],
        intent: .playbackControl,
        policy: .policy(for: .playbackControl),
        runID: runID,
        executionLease: executionLease,
        confirm: { _ in true },
        emit: { _ in }
    )

    #expect(bridge.playedTracks == [gid])
}

@Test("persisted resume keeps the original side-effect authorization")
func persistedResumeKeepsOriginalAuthorization() async throws {
    let runID = UUID()
    let executionLease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)
    let serverID: ServerID = "persisted-resume-server"
    let track = scenarioTrack(serverID: serverID, remoteID: "sunset", title: "Sunset")
    let gid = GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    let store = try scenarioStore()
    try await seedScenario(store, tracks: [track])
    let bridge = MockAgentBridge()
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "resume-play",
            name: "playback_play_song",
            arguments: ["trackID": .string(gid.description)]
        )]),
        scenarioResponse(content: "已继续播放。"),
    ])
    let savedState = AgentTaskState(
        intent: .playbackControl,
        goal: "播放专辑里的 Sunset"
    )

    await ConversationEngine().run(
        userText: "继续",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(serverID: serverID),
        intent: .playbackControl,
        policy: .policy(for: .playbackControl),
        initialTaskState: savedState,
        runID: runID,
        executionLease: executionLease,
        confirm: { _ in true },
        emit: { _ in }
    )

    #expect(bridge.playedTracks == [gid])
}

@Test("read-only music questions use generic completion semantics")
func readOnlyMusicQuestionsDoNotRequireMutation() {
    let cases: [(String, AgentTaskIntent)] = [
        ("我有哪些歌单？", .playlistQuery),
        ("我的播放队列里现在有哪些歌？", .queueQuery),
        ("现在正在播放什么？", .playbackQuery),
    ]
    for (text, intent) in cases {
        #expect(AgentIntentClassifier.classify(text) == intent)
        #expect(AgentTaskPolicy.policy(for: intent).completion == .modelAnswer)
    }
    #expect(AgentIntentClassifier.classify("我的收藏") == .librarySearch)
    #expect(AgentRequestSemantics.analyze("我的收藏").isReadOnly)
}

@Test("explicit reversible playlist create executes once without invented confirmation")
func explicitPlaylistCreateDoesNotAskForConfirmation() async throws {
    let runID = UUID()
    let bridge = MockAgentBridge()
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "create-playlist",
            name: "playlist_create",
            arguments: ["name": .string("Test")]
        )]),
        scenarioResponse(content: "已创建空歌单 Test。"),
    ])
    let confirmation = ScenarioStateProbe()

    await ConversationEngine().run(
        userText: "创建一个空歌单 Test",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: try scenarioStore(),
        context: ToolLoop.Context(),
        intent: .playlistManagement,
        policy: .policy(for: .playlistManagement),
        executionLineage: .newRequest(text: "创建一个空歌单 Test"),
        runID: runID,
        executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
        confirm: { _ in
            await confirmation.record()
            return true
        },
        emit: { _ in }
    )

    #expect(bridge.createdPlaylistNames == ["Test"])
    #expect(await confirmation.count() == 0)
}

@Test("missing operation metadata does not block a reversible mutation")
func missingMutationOperationDoesNotBlockReversibleTool() async throws {
    let serverID: ServerID = "confirmation-server"
    let playlistID = GlobalID(serverID: serverID, remoteID: "playlist")
    let trackID = GlobalID(serverID: serverID, remoteID: "track")
    let store = try scenarioStore()
    try await seedScenario(
        store,
        tracks: [scenarioTrack(serverID: serverID, remoteID: "track", title: "测试歌曲")]
    )
    try await store.upsertPlaylist(
        Playlist(id: "playlist", serverID: serverID, name: "Test", trackIDs: []),
        serverID: serverID,
        isReadOnly: false
    )
    let bridge = MockAgentBridge(activeServerID: serverID)
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "add-after-confirmation",
            name: "playlist_add_songs",
            arguments: [
                "playlistID": .string(playlistID.description),
                "trackIDs": .array([.string(trackID.description)]),
            ]
        )]),
        scenarioResponse(content: "已加入歌单。"),
    ])
    let confirmation = ScenarioStateProbe()
    let semantics = AgentRequestSemantics(
        domain: .playlist,
        operation: .mutate,
        isMusicContext: true,
        isContinuation: false
    )
    let lineage = ExecutionLineage(
        sourceRequest: "处理歌单 Test",
        authorization: SideEffectAuthorizationContext(
            sourceRequest: "处理歌单 Test",
            semantics: semantics
        )
    )

    await ConversationEngine().run(
        userText: "处理歌单 Test",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(serverID: serverID),
        intent: .playlistManagement,
        policy: .policy(for: .playlistManagement),
        executionLineage: lineage,
        runID: lineage.lineageID,
        executionLease: ToolExecutionLease(
            runID: lineage.lineageID,
            sessionID: UUID(),
            generation: 1
        ),
        confirm: { _ in
            await confirmation.record()
            return true
        },
        emit: { _ in }
    )

    #expect(await confirmation.count() == 0)
    #expect(!bridge.addedToPlaylist.isEmpty)
}

@Test("playlist list after failed create is read-only and cannot inherit mutation authority")
func playlistListAfterFailedCreateIsReadOnly() async throws {
    let failedCreate = ExecutionLineage.newRequest(text: "创建一个空歌单 Test")
    let listLineage = ExecutionLineageResolver.resolve(
        currentUserText: "列出歌单",
        previous: failedCreate
    )
    let bridge = MockAgentBridge()
    let provider = ScenarioProvider([
        // Even a confused model cannot reuse the previous create authority.
        scenarioResponse(calls: [scenarioCall(
            id: "stale-create",
            name: "playlist_create",
            arguments: ["name": .string("Test")]
        )]),
        scenarioResponse(content: "没有执行创建；当前歌单列表为空。"),
    ])
    let runID = UUID()

    await ConversationEngine().run(
        userText: "列出歌单",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: try scenarioStore(),
        context: ToolLoop.Context(),
        intent: .playlistQuery,
        policy: .policy(for: .playlistQuery),
        executionLineage: listLineage,
        runID: runID,
        executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
        confirm: { _ in true },
        emit: { _ in }
    )

    #expect(bridge.createdPlaylistNames.isEmpty)
    #expect(listLineage.authorization.allowedOperations.isEmpty)
}

@Test("generic shortlist does not leak music tools from broad words")
func genericShortlistUsesExplicitContext() {
    let bookTools = Set(ToolSelector.select(for: "推荐几本书", all: AgentToolRegistry.all).map(\.name))
    #expect(!bookTools.contains("recommend_by_mood"))
    #expect(!bookTools.contains("queue_replace"))

    let wheelTools = Set(ToolSelector.select(for: "怎么下载 Python wheel", all: AgentToolRegistry.all).map(\.name))
    #expect(!wheelTools.contains("media_download_offline"))

    let docsTools = Set(ToolSelector.select(for: "搜索 Python 官方文档", all: AgentToolRegistry.all).map(\.name))
    #expect(docsTools.contains("web_search"))
    #expect(!docsTools.contains("library_search"))

    let ambiguousTools = Set(ToolSelector.select(for: "搜索胡广生", all: AgentToolRegistry.all).map(\.name))
    #expect(ambiguousTools.contains("library_search"))
    #expect(ambiguousTools.contains("web_search"))
    #expect(!ambiguousTools.contains("queue_append"))
}

@Test("generic search does not stop after repeated empty evidence")
func genericSearchRemainsModelControlledAfterNoNewResults() async throws {
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(id: "web-1", name: "web_search", arguments: ["query": .string("不存在的关键词 1")])]),
        scenarioResponse(calls: [scenarioCall(id: "web-2", name: "web_search", arguments: ["query": .string("不存在的关键词 2")])]),
        scenarioResponse(calls: [scenarioCall(id: "web-3", name: "web_search", arguments: ["query": .string("不存在的关键词 3")])]),
        scenarioResponse(content: "没有查到可靠来源，因此无法确认这项信息。"),
    ])
    let collector = ScenarioMessageCollector()

    await ConversationEngine().run(
        userText: "查一下这个不存在的科技名词。",
        provider: provider,
        model: "scenario",
        bridge: MockAgentBridge(),
        catalog: try scenarioStore(),
        context: ToolLoop.Context(),
        webService: EmptyScenarioWebService(),
        intent: .conversation,
        policy: .policy(for: .conversation),
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    let requests = provider.requests()
    #expect(await collector.containsError("没有获得新的结果") == false)
    #expect(await collector.containsText("没有查到可靠来源"))
    // 三次空结果的最后一次规划请求仍保留 web_search；最终回答请求可以不带工具。
    #expect(requests.count >= 4)
    #expect(requests.dropLast().last?.tools?.contains { $0.name == "web_search" } == true)
}

@Test("side-effect metadata is retained without becoming an execution whitelist")
func operationAuthorizationRemainsMetadata() {
    let favorite = AgentToolRegistry.descriptor(for: "favorite_set")!
    let rating = AgentToolRegistry.descriptor(for: "rating_set")!
    let index = AgentToolRegistry.descriptor(for: "recommendation_index_commit")!
    let queueAppend = AgentToolRegistry.descriptor(for: "queue_append")!
    let queueReplace = AgentToolRegistry.descriptor(for: "queue_replace")!
    let playlistCreate = AgentToolRegistry.descriptor(for: "playlist_create")!
    let playlistAdd = AgentToolRegistry.descriptor(for: "playlist_add_songs")!
    let play = AgentToolRegistry.descriptor(for: "playback_play_song")!
    let favoriteAuthorization = SideEffectAuthorizationContext(originalUserRequest: "收藏这首歌")
    #expect(favoriteAuthorization.allows(favorite))
    #expect(favoriteAuthorization.allows(rating))
    #expect(favoriteAuthorization.allows(index))
    #expect(favoriteAuthorization.allowedOperations == [.favoriteSet])
    let appendAuthorization = SideEffectAuthorizationContext(originalUserRequest: "把这首歌加入队列")
    #expect(appendAuthorization.allows(queueAppend))
    #expect(appendAuthorization.allows(queueReplace))
    #expect(appendAuthorization.allowedOperations == [.queueAppend])
    let createAuthorization = SideEffectAuthorizationContext(originalUserRequest: "创建一个歌单")
    #expect(createAuthorization.allows(playlistCreate))
    #expect(createAuthorization.allows(playlistAdd))
    #expect(createAuthorization.allowedOperations == [.playlistCreate])
    let playAuthorization = SideEffectAuthorizationContext(originalUserRequest: "播放这首歌")
    #expect(playAuthorization.allows(play))
    #expect(playAuthorization.allows(queueReplace))
    #expect(playAuthorization.allowedOperations == [.playbackPlay])
    #expect(SideEffectAuthorizationContext(originalUserRequest: "构建完整推荐索引").allows(index))
    #expect(SideEffectAuthorizationContext(originalUserRequest: "继续").allows(index))

    #expect(SideEffectAuthorizationContext(originalUserRequest: "我不喜欢这个网页的排版").allowedOperations.isEmpty)
    #expect(SideEffectAuthorizationContext(originalUserRequest: "C++ memory leak 是怎么产生的？").allowedOperations.isEmpty)
    #expect(SideEffectAuthorizationContext(originalUserRequest: "skill issue 是什么意思？").allowedOperations.isEmpty)
    #expect(AgentRequestSemantics.analyze("把这些歌放进歌单 Test").requestedOperations.contains(.playlistAdd))
}

private actor MutationBoundaryGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendAtBoundary() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor MutationCommitProbe {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

private final class DelayedLeaseAwareBridge: MockAgentBridge, @unchecked Sendable {
    let boundary = MutationBoundaryGate()
    let commits = MutationCommitProbe()

    override func playTrack(globalID: GlobalID) async -> Bool {
        await boundary.suspendAtBoundary()
        guard ToolExecutionContext.permitsMutationCommit else { return false }
        await commits.record()
        return true
    }

    override func playServerTrack(globalID: GlobalID) async -> Bool {
        guard ToolExecutionContext.permitsMutationCommit else { return false }
        await commits.record()
        return true
    }
}

@Test("revoked lease rejects an authorized mutation before executor entry")
func revokedLeaseCannotExecuteMutation() async throws {
    let serverID: ServerID = "revoked-lease"
    let track = scenarioTrack(serverID: serverID, remoteID: "song", title: "Song")
    let gid = GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    let store = try scenarioStore()
    try await seedScenario(store, tracks: [track])
    let bridge = MockAgentBridge(activeServerID: serverID)
    let runID = UUID()
    let lease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)
    lease.revoke()

    let result = await ToolRuntime.execute(
        ToolCall(name: "playback_play_song", arguments: ["trackID": .string(gid.description)]),
        bridge: bridge,
        catalog: store,
        serverID: serverID,
        systemService: nil,
        authorizationContext: SideEffectAuthorizationContext(originalUserRequest: "播放这首歌"),
        executionLease: lease
    )

    #expect(!result.success)
    #expect(result.summary.contains("运行已失效"))
    #expect(bridge.playedTracks.isEmpty)
    #expect(bridge.serverPlayedTracks.isEmpty)
}

@Test("lease is checked again after async preparation at the final commit boundary")
func revokedLeaseCannotCommitAfterAwait() async throws {
    let serverID: ServerID = "lease-toctou"
    let track = scenarioTrack(serverID: serverID, remoteID: "song", title: "Song")
    let gid = GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    let store = try scenarioStore()
    try await seedScenario(store, tracks: [track])
    let bridge = DelayedLeaseAwareBridge(activeServerID: serverID)
    let runID = UUID()
    let lease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 7)

    let execution = Task {
        await ToolRuntime.execute(
            ToolCall(name: "playback_play_song", arguments: ["trackID": .string(gid.description)]),
            bridge: bridge,
            catalog: store,
            serverID: serverID,
            systemService: nil,
            authorizationContext: SideEffectAuthorizationContext(originalUserRequest: "播放这首歌"),
            executionLease: lease
        )
    }
    await bridge.boundary.waitUntilEntered()
    lease.revoke()
    await bridge.boundary.release()
    let result = await execution.value

    #expect(!result.success)
    #expect(await bridge.commits.value() == 0)
}

@Test("read-only request cannot mutate even when provider asks for playback")
func readOnlyArtistCountCannotTriggerPlayback() async throws {
    let serverID: ServerID = "read-only-invariant"
    let track = scenarioTrack(serverID: serverID, remoteID: "wrong-song", title: "孤勇者 (Live)")
    let gid = GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    let store = try scenarioStore()
    try await seedScenario(store, tracks: [track])
    let bridge = MockAgentBridge(activeServerID: serverID)
    let provider = ScenarioProvider([
        scenarioResponse(calls: [scenarioCall(
            id: "malicious-play",
            name: "playback_play_song",
            arguments: ["trackID": .string(gid.description)]
        )]),
        scenarioResponse(content: "当前音乐库共有 1025 位歌手。"),
    ])
    let collector = ScenarioMessageCollector()
    let runID = UUID()
    let lease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)

    await ConversationEngine().run(
        userText: "有多少歌手？",
        provider: provider,
        model: "scenario",
        bridge: bridge,
        catalog: store,
        context: ToolLoop.Context(serverID: serverID, totalArtists: 1025),
        intent: .librarySearch,
        policy: .policy(for: .librarySearch),
        runID: runID,
        executionLease: lease,
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    #expect(bridge.playedTracks.isEmpty)
    #expect(bridge.serverPlayedTracks.isEmpty)
    #expect(bridge.replacedQueues.isEmpty)
    #expect(bridge.clearedQueueCount == 0)
    #expect(await collector.containsText("1 位艺术家"))
}
