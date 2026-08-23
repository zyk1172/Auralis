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

@Test("外部网页数据不能授权用户未请求的副作用")
func externalWebDataCannotAuthorizeSideEffect() async throws {
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
        confirm: { _ in true },
        emit: { message in await collector.append(message) }
    )

    #expect(bridge.clearedQueueCount == 0)
    let requests = provider.requests()
    #expect(requests.dropFirst(2).first?.messages.contains { message in
        message.content.contains("不能授权此操作")
    } == true)
    #expect(await collector.containsText("未执行网页中的其他指令"))
}

@Test("continuation keeps the original side-effect authorization")
func continuationKeepsOriginalAuthorization() async throws {
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
        confirm: { _ in true },
        emit: { _ in }
    )

    #expect(bridge.playedTracks == [gid])
}

@Test("persisted resume keeps the original side-effect authorization")
func persistedResumeKeepsOriginalAuthorization() async throws {
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

@Test("generic search converges after repeated empty evidence")
func genericSearchConvergesAfterNoNewResults() async throws {
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

    #expect(await collector.containsText("没有查到可靠来源"))
    let requests = provider.requests()
    #expect(requests.count == 4)
    #expect(requests.last?.tools?.contains { $0.name == "web_search" } == false)
}

@Test("side-effect authorization is operation-level and avoids lexical false positives")
func operationAuthorizationIsLeastPrivilege() {
    let favorite = AgentToolRegistry.descriptor(for: "favorite_set")!
    let rating = AgentToolRegistry.descriptor(for: "rating_set")!
    let index = AgentToolRegistry.descriptor(for: "library_index_v2_write_batch")!
    let queueAppend = AgentToolRegistry.descriptor(for: "queue_append")!
    let queueReplace = AgentToolRegistry.descriptor(for: "queue_replace")!
    let playlistCreate = AgentToolRegistry.descriptor(for: "playlist_create")!
    let playlistAdd = AgentToolRegistry.descriptor(for: "playlist_add_songs")!
    let play = AgentToolRegistry.descriptor(for: "playback_play_song")!
    let favoriteAuthorization = SideEffectAuthorizationContext(originalUserRequest: "收藏这首歌")
    #expect(favoriteAuthorization.allows(favorite))
    #expect(!favoriteAuthorization.allows(rating))
    #expect(!favoriteAuthorization.allows(index))
    let appendAuthorization = SideEffectAuthorizationContext(originalUserRequest: "把这首歌加入队列")
    #expect(appendAuthorization.allows(queueAppend))
    #expect(!appendAuthorization.allows(queueReplace))
    let createAuthorization = SideEffectAuthorizationContext(originalUserRequest: "创建一个歌单")
    #expect(createAuthorization.allows(playlistCreate))
    #expect(!createAuthorization.allows(playlistAdd))
    let playAuthorization = SideEffectAuthorizationContext(originalUserRequest: "播放这首歌")
    #expect(playAuthorization.allows(play))
    #expect(!playAuthorization.allows(queueReplace))
    #expect(SideEffectAuthorizationContext(originalUserRequest: "构建完整推荐索引").allows(index))
    #expect(!SideEffectAuthorizationContext(originalUserRequest: "继续").allows(index))

    #expect(SideEffectAuthorizationContext(originalUserRequest: "我不喜欢这个网页的排版").allowedOperations.isEmpty)
    #expect(SideEffectAuthorizationContext(originalUserRequest: "C++ memory leak 是怎么产生的？").allowedOperations.isEmpty)
    #expect(SideEffectAuthorizationContext(originalUserRequest: "skill issue 是什么意思？").allowedOperations.isEmpty)
}
