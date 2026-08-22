import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - 自包含测试替身（与其它测试文件隔离，避免 private 符号冲突）

private actor InvocationGate {
    private var signaled = false

    func signal() {
        signaled = true
    }

    func isSignaled() -> Bool {
        signaled
    }
}

/// 记录副作用的最小 AgentBridge 实现。
private final class PermissiveBridge: AgentBridge, @unchecked Sendable {
    let activeServerIDValue: ServerID?
    init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }
    var activeServerID: ServerID? { activeServerIDValue }
    var lyricsStateValue: AgentLyricsState = .unknown
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }
    func currentTrack() -> Track? { nil }
    func currentQueue() -> [Track] { [] }

    private(set) var playedTracks: [GlobalID] = []
    private(set) var deletedPlaylists: [GlobalID] = []
    private(set) var replacedQueues: [[GlobalID]] = []
    private(set) var clearedQueueCount = 0
    private(set) var addedToPlaylist: [(GlobalID, [GlobalID])] = []
    private(set) var createdPlaylistNames: [String] = []
    private(set) var likedTracks: [GlobalID] = []
    private(set) var removedServers: [ServerID] = []

    var playResult: Bool = true
    var testConnectionResult: Bool = true
    var playlistAddResult: AgentMutationResult = .confirmed("ok")
    /// 置为 true 时 server_test_connection 会睡眠（用于超时/取消路径）。
    var slowTestConnection = false
    /// 模拟无视任务取消的底层 I/O，用于验证 Runner 主动取消能立即释放调用方。
    var nonCooperativeTestConnection = false
    /// 模拟已经发出写请求、但底层 I/O 无视取消的情况。
    var nonCooperativeClearQueue = false
    let clearQueueStarted = InvocationGate()

    func playTrack(globalID: GlobalID) async -> Bool { playedTracks.append(globalID); return playResult }
    func playServerTrack(globalID: GlobalID) async -> Bool { true }
    func playAlbum(globalID: GlobalID) async -> Bool { true }
    func playPlaylist(globalID: GlobalID) async -> Bool { true }
    func playRandom(limit: Int) async -> AgentMutationResult { .confirmed("ok") }
    func pause() async -> AgentMutationResult { .confirmed("已暂停") }
    func resume() async -> AgentMutationResult { .confirmed("已继续") }
    func seek(seconds: TimeInterval) async -> AgentMutationResult { .confirmed("已定位") }
    func next() async -> AgentMutationResult { .confirmed("下一首") }
    func previous() async -> AgentMutationResult { .confirmed("上一首") }
    func setShuffle(_ enabled: Bool) async -> AgentMutationResult { .confirmed("已设置随机播放") }
    func setRepeatMode(_ mode: RepeatMode) async -> AgentMutationResult { .confirmed("已设置循环模式") }
    func setPlaybackRate(_ rate: Float) async -> AgentMutationResult { .confirmed("已设置播放速度") }
    func setSleepTimer(mode: String, minutes: TimeInterval) async -> AgentMutationResult { .confirmed("已设置睡眠定时") }
    func cancelSleepTimer() async -> AgentMutationResult { .confirmed("已取消睡眠定时") }
    func getSleepTimer() async -> (mode: String, remaining: TimeInterval) { ("off", 0) }
    func addToQueue(globalID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func playNext(globalID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult { replacedQueues.append(globalIDs); return .confirmed("ok") }
    func removeFromQueue(at index: Int) async -> AgentMutationResult { .confirmed("ok") }
    func reorderQueue(from: Int, to: Int) async -> AgentMutationResult { .confirmed("ok") }
    func clearQueue() async -> AgentMutationResult {
        if nonCooperativeClearQueue {
            await clearQueueStarted.signal()
            let sleeper = Task.detached { try? await Task.sleep(for: .seconds(2)) }
            await sleeper.value
        }
        clearedQueueCount += 1
        return .confirmed("ok")
    }
    func shuffleRemaining() async -> AgentMutationResult { .confirmed("ok") }
    func saveQueueAsPlaylist(name: String) async -> AgentMutationResult { createdPlaylistNames.append(name); return .confirmed("已保存队列") }

    func createPlaylist(name: String) async -> GlobalID? {
        createdPlaylistNames.append(name)
        return GlobalID(serverID: "local", remoteID: UUID().uuidString)
    }
    func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { .confirmed("ok") }
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult {
        addedToPlaylist.append((playlistGID, trackGIDs))
        return playlistAddResult
    }
    func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult { .confirmed("ok") }
    func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult { .confirmed("ok") }
    func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult { .confirmed("ok") }
    func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult { deletedPlaylists.append(globalID); return .confirmed("ok") }

    func likeTrack(globalID: GlobalID) async -> AgentMutationResult { likedTracks.append(globalID); return .confirmed("已收藏") }
    func unlikeTrack(globalID: GlobalID) async -> AgentMutationResult { .confirmed("已取消收藏") }
    func favoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { .confirmed("已收藏专辑") }
    func unfavoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { .confirmed("已取消收藏专辑") }
    func favoriteArtist(globalID: GlobalID) async -> AgentMutationResult { .confirmed("已收藏艺术家") }
    func unfavoriteArtist(globalID: GlobalID) async -> AgentMutationResult { .confirmed("已取消收藏艺术家") }
    func setRating(globalID: GlobalID, rating: Int) async -> AgentMutationResult { .confirmed("已评分") }
    func clearRating(globalID: GlobalID) async -> AgentMutationResult { .confirmed("已清除评分") }

    func listServers() async -> [ServerAccount] { [] }
    func getActiveServer() async -> ServerAccount? { nil }
    func testServerConnection(serverID: ServerID) async -> Bool {
        if nonCooperativeTestConnection {
            let sleeper = Task.detached {
                try? await Task.sleep(for: .seconds(2))
            }
            await sleeper.value
        }
        if slowTestConnection {
            try? await Task.sleep(for: .seconds(10))
        }
        return testConnectionResult
    }
    func addServer(displayName: String, baseURL: String, username: String, token: String) async -> AgentMutationResult { .confirmed("ok") }
    func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> AgentMutationResult { .confirmed("ok") }
    func switchServer(serverID: ServerID) async -> AgentMutationResult { .confirmed("ok") }
    func refreshLibrary() async -> AgentMutationResult { .confirmed("已触发刷新") }
    func getSyncStatus() async -> [CatalogSyncStatus] { [] }
    func removeServer(serverID: ServerID) async -> AgentMutationResult { removedServers.append(serverID); return .confirmed("已删除服务器") }
    func serverSearch(query: String, limit: Int) async -> [Track] { [] }
}

/// 可配置推荐结果的 AgentSystemService 桩。
private final class PermissiveSystemService: AgentSystemService, @unchecked Sendable {
    var recommendationTracks: [TrackCard] = []
    /// 置为 true 时 testServerConnection 会睡眠（用于超时/取消路径）。
    var slowTestConnection = false
    func testServerConnection() async -> AgentConnectionTestResult {
        if slowTestConnection {
            try? await Task.sleep(for: .seconds(10))
        }
        return AgentConnectionTestResult(success: true, latencyMs: 1, serverType: "navidrome", serverVersion: "0.54")
    }
    func recommendByMood(_ mood: String, limit: Int) async -> AgentRecommendationResult {
        AgentRecommendationResult(mood: mood, tracks: recommendationTracks)
    }
    func recommendByConstraints(_ constraints: AgentRecommendationConstraints) async -> AgentRecommendationResult {
        AgentRecommendationResult(mood: "组合约束", tracks: recommendationTracks)
    }
    // AgentAppService
    func appContext() async -> AgentAppContext {
        AgentAppContext(page: "home", serverName: "Test", currentTrackTitle: nil, playbackState: "idle", queueCount: 0, isShuffled: false, repeatMode: "off", networkType: "wifi", isOffline: false, hasPendingTask: false)
    }
    func openPage(_ page: String) async -> Bool { true }
    func featureStatus() async -> AgentFeatureStatus { AgentFeatureStatus(backgroundAudioEnabled: true, siriEnabled: true) }
    // AgentServerService
    func listServers() async -> [AgentServerInfo] { [] }
    func currentServer() async -> AgentServerInfo? { nil }
    func serverCapabilities() async -> AgentCapabilitiesSummary { AgentCapabilitiesSummary(supportsStructuredLyrics: false, supportsSonicSimilarity: false) }
    func syncStatus() async -> AgentSyncStatus { AgentSyncStatus(isRunning: false, mode: "incremental", lastCompletedAt: .now, lastProcessedCount: 0, isStale: false) }
    func networkStatus() async -> AgentNetworkStatus { AgentNetworkStatus(networkType: "wifi", isOffline: false, isServerReachable: true, isConstrained: false) }
    // AgentMediaService
    func audioRoute() async -> AgentAudioRoute { AgentAudioRoute(outputName: "耳机", outputType: "headphones") }
    func storageStatus() async -> AgentStorageStatus { AgentStorageStatus(offlineAudioBytes: 0, offlineAudioCount: 0, freeBytes: 1_000_000_000) }
    func lyrics(for trackID: TrackID) async -> AgentLyricsResult { AgentLyricsResult(hasLyrics: true, isSynced: false, lineCount: 1) }
    func downloadOffline(trackID: TrackID) async -> Bool { true }
    func cacheStatus() async -> AgentCacheStatus { AgentCacheStatus(offlineAudioBytes: 0, offlineAudioCount: 0) }
    // AgentLibraryInsightsService
    func recentlyAdded(days: Int, limit: Int) async -> [TrackCard] { [] }
    func mostPlayed(limit: Int) async -> [TrackCard] { [] }
    func brokenArtwork(limit: Int) async -> [String] { [] }
    func staleCache(limit: Int) async -> [String] { [] }
    func topItems(kind: String, limit: Int) async -> [AgentTopItem] { [] }
    func formatDistribution() async -> [AgentFormatCount] { [] }
    func listeningSummary() async -> AgentListeningSummary { AgentListeningSummary(totalPlays: 0, uniqueTracks: 0, totalFavorites: 0) }
    func playbackDiagnostics() async -> AgentPlaybackDiagnostics { AgentPlaybackDiagnostics(state: "idle", mediaSource: "local", audioSessionActive: true, queueValid: true, isPlaying: false) }
    // AgentDiagnosticsService
    func nowPlayingStatus() async -> AgentNowPlayingStatus { AgentNowPlayingStatus(title: nil, artist: nil, consistentWithApp: true) }
    func diagnosticsReport() async -> String { "脱敏诊断" }
    func recentErrors(limit: Int) async -> [AgentErrorRecord] { [] }
}

/// 记录每次请求、按批次返回 ACTION 文本的模型桩（单 chunk，快）。
private final class PermissiveScriptedProvider: AIProvider, @unchecked Sendable {
    private var remaining: [String]
    private let closing: String
    private(set) var requests: [AICompletionRequest] = []

    init(actionBatches: [String], closing: String = "已处理完成。") {
        self.remaining = actionBatches
        self.closing = closing
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "scripted", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        requests.append(request)
        let content = remaining.isEmpty ? closing : remaining.removeFirst()
        return AICompletionResponse(model: request.model, content: content)
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            requests.append(request)
            let content = remaining.isEmpty ? closing : remaining.removeFirst()
            continuation.yield(.started(model: request.model))
            continuation.yield(.delta(content))
            continuation.yield(.completed)
            continuation.finish()
        }
    }
}

private actor PermissiveCollector {
    private(set) var messages: [AgentChatMessage] = []
    func record(_ message: AgentChatMessage) { messages.append(message) }
    func all() -> [AgentChatMessage] { messages }
    /// 每条消息里 trackCards 分组的卡片数量（按出现顺序）。
    func trackCardGroupCounts() -> [Int] {
        messages.flatMap { message in
            message.messages.compactMap { item in
                if case let .trackCards(cards) = item { return cards.count }
                return nil
            }
        }
    }
    func containsAnyTrackCards() -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case .trackCards = item { return true }
                return false
            }
        }
    }
    func containsText(_ substring: String) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .text(text) = item { return text.contains(substring) }
                return false
            }
        }
    }
    func containsError(_ substring: String) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .error(text) = item { return text.contains(substring) }
                return false
            }
        }
    }
}

private actor PermissiveActionLog {
    private(set) var records: [AgentActionRecord] = []
    func record(_ entry: AgentActionRecord) { records.append(entry) }
    func contains(_ text: String) -> Bool { records.contains { $0.summary.contains(text) } }
}

private actor PermissiveProbe {
    private(set) var calls = 0
    func decide(_ pending: PendingConfirmation) -> Bool {
        calls += 1
        return true
    }
}

private actor RejectingProbe {
    private(set) var calls = 0
    func decide(_ pending: PendingConfirmation) -> Bool {
        calls += 1
        return false
    }
}

// MARK: - Helpers

private func makePermStore() throws -> LocalCatalogStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
}

private func makePermTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: serverID,
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "Artist \(serverID.rawValue)",
        albumTitle: "Album \(serverID.rawValue)",
        duration: 200
    )
}

private func seedPerm(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

private func permCard(_ gid: GlobalID, title: String) -> TrackCard {
    TrackCard(globalID: gid, title: title, artistName: "Artist", albumTitle: "Album", duration: 200, isFavorite: false)
}

// MARK: - TEST 01 / 02 / 29：开车提神推荐（含 Intent 分类错误时仍可完成）

@Suite("Agent permissive runtime")
struct AgentPermissiveRuntimeTests {
    @Test("TEST01 开车提神 → musicDiscovery 直接推荐完成")
    func driveTimeDiscoveryWithDiscoveryIntent() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "引擎轰鸣")])
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        system.recommendationTracks = [permCard(GlobalID(serverID: "test-server", remoteID: "t1"), title: "引擎轰鸣")]
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(
            actionBatches: [#"ACTION: {"tool":"recommend_by_mood","args":{"mood":"开车提神"}}"#],
            closing: "为你找到 3 首适合开车提神的歌：引擎轰鸣等。"
        )
        await AgentRunner.run(
            userText: "适合开车的时候听的歌曲，让人提起精神。",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(provider.requests.count >= 2)
        #expect(provider.requests[1].messages.contains { $0.role == .user && $0.content.contains("（工具执行结果）recommend_by_mood: 成功") })
        #expect(await collector.containsText("适合开车提神的歌"))
        #expect(await collector.containsError("没有进展") == false)
    }

    @Test("TEST02 强制 conversation Intent 仍能调用推荐工具")
    func driveTimeDiscoveryWithConversationIntent() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "引擎轰鸣")])
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        system.recommendationTracks = [permCard(GlobalID(serverID: "test-server", remoteID: "t1"), title: "引擎轰鸣")]
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(
            actionBatches: [#"ACTION: {"tool":"recommend_by_mood","args":{"mood":"开车提神"}}"#],
            closing: "已推荐完成。"
        )
        await AgentRunner.run(
            userText: "适合开车的时候听的歌曲，让人提起精神。",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(provider.requests.count >= 2)
        #expect(provider.requests[1].messages.contains { $0.role == .user && $0.content.contains("（工具执行结果）recommend_by_mood: 成功") })
    }

    @Test("TEST03/30 直接播放一组开车提神的歌：推荐→替换队列→播放，无确认")
    func directPlayDriveTimeChain() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [
            makePermTrack(serverID: "test-server", remoteID: "t1", title: "引擎轰鸣"),
            makePermTrack(serverID: "test-server", remoteID: "t2", title: "加速冲刺"),
        ])
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        system.recommendationTracks = [
            permCard(GlobalID(serverID: "test-server", remoteID: "t1"), title: "引擎轰鸣"),
            permCard(GlobalID(serverID: "test-server", remoteID: "t2"), title: "加速冲刺"),
        ]
        let collector = PermissiveCollector()
        let probe = PermissiveProbe()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"recommend_by_mood","args":{"mood":"开车提神"}}"#,
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"test-server:t1,test-server:t2"}}"#,
            #"ACTION: {"tool":"playback_play_song","args":{"trackID":"test-server:t1"}}"#,
        ], closing: "已开始播放。")
        await AgentRunner.run(
            userText: "给我直接放一组适合开车提神的歌。",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            confirm: { await probe.decide($0) },
            emit: { await collector.record($0) }
        )
        #expect(bridge.replacedQueues.count == 1)
        #expect(bridge.replacedQueues.first?.count == 2)
        #expect(bridge.playedTracks.contains(GlobalID(serverID: "test-server", remoteID: "t1")))
        // 用户明确要求直接播放 → 全程 0 次确认。
        #expect(await probe.calls == 0)
    }

    // MARK: - TEST 04 / 05：不存在累计工具调用上限

    @Test("TEST04 连续 100 次不同工具调用不中止")
    func hundredToolCallsDoNotStop() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let actions = (0..<100).map { i in
            #"ACTION: {"tool":"library_get_song","args":{"trackID":"test-server:missing-\#(i)"}}"#
        }
        let provider = PermissiveScriptedProvider(actionBatches: actions, closing: "全部处理完成。")
        await AgentRunner.run(
            userText: "逐个检查 100 首歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 100 次调用 + 1 轮最终回答。
        #expect(provider.requests.count >= 101)
        #expect(await collector.containsText("全部处理完成"))
        #expect(await collector.containsError("达到工具调用上限") == false)
    }

    @Test("TEST05 synthetic 500 次工具调用不存在调用次数上限")
    func fiveHundredToolCallsDoNotStop() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let actions = (0..<500).map { i in
            #"ACTION: {"tool":"library_search","args":{"query":"查询\#(i)"}}"#
        }
        let provider = PermissiveScriptedProvider(actionBatches: actions, closing: "500 次全部完成。")
        await AgentRunner.run(
            userText: "批量检查 500 个查询",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(provider.requests.count >= 501)
        #expect(await collector.containsText("500 次全部完成"))
    }

    // MARK: - TEST 06 / 07：搜索不再有全局 stopSearching

    @Test("TEST06 三个不同搜索全空后仍允许第四次搜索")
    func fourthSearchAllowedAfterThreeEmpty() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"library_search","args":{"query":"AAAA"}}"#,
            #"ACTION: {"tool":"library_search","args":{"query":"BBBB"}}"#,
            #"ACTION: {"tool":"library_search","args":{"query":"CCCC"}}"#,
            #"ACTION: {"tool":"library_search","args":{"query":"DDDD"}}"#,
        ], closing: "四次搜索都完成了。")
        await AgentRunner.run(
            userText: "搜索几首歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 4 次执行 + 最终回答；第四次没有被 stopSearching 拦截。
        #expect(provider.requests.count >= 5)
        let toolResults = provider.requests.dropFirst().compactMap { req -> Bool in
            req.messages.contains { $0.role == .user && $0.content.contains("（工具执行结果）library_search") }
        }
        #expect(toolResults.count == 4)
    }

    @Test("TEST07 完全相同的搜索第二次走缓存，任务继续")
    func identicalSearchUsesCacheAndContinues() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"library_search","args":{"query":"AAA"}}"#,
            #"ACTION: {"tool":"library_search","args":{"query":"AAA"}}"#,
        ], closing: "基于搜索结果回答完成。")
        await AgentRunner.run(
            userText: "搜索 AAA",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(await collector.containsText("基于搜索结果回答完成"))
        #expect(await collector.containsError("已停止搜索") == false)
        #expect(await collector.containsError("重复调用上限") == false)
    }

    // MARK: - TEST 08 / 09：noProgress / repeatedPattern 不再终止

    @Test("TEST08 连续超过旧 maxNoProgressRounds 后任务继续")
    func noProgressBeyondOldLimitContinues() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        // 8 个不同查询，每个都返回 0 结果（成功但无新事实 → 记录 noProgress）。
        let actions = (0..<8).map { i in
            #"ACTION: {"tool":"library_search","args":{"query":"empty\#(i)"}}"#
        }
        let provider = PermissiveScriptedProvider(actionBatches: actions, closing: "没有找到结果，已如实告知。")
        await AgentRunner.run(
            userText: "搜索一些歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(provider.requests.count >= 9)
        #expect(await collector.containsText("没有找到结果"))
        #expect(await collector.containsError("没有取得新进展") == false)
    }

    @Test("TEST09 超过旧 maxRepeatedToolPattern 后任务继续")
    func repeatedPatternBeyondOldLimitContinues() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        // 同一签名重复 6 次（走缓存路径），不终止。
        let same = #"ACTION: {"tool":"library_search","args":{"query":"same"}}"#
        let provider = PermissiveScriptedProvider(actionBatches: Array(repeating: same, count: 6), closing: "重复查询已处理。")
        await AgentRunner.run(
            userText: "查询同一首歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(await collector.containsText("重复查询已处理"))
        #expect(await collector.containsError("重复调用同一工具") == false)
    }

    // MARK: - TEST 10 / 11：queue_replace 可多次、同参数幂等

    @Test("TEST10 queue_replace 不同参数可执行两次")
    func queueReplaceTwiceWithDifferentArgs() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [
            makePermTrack(serverID: "test-server", remoteID: "t1", title: "A"),
            makePermTrack(serverID: "test-server", remoteID: "t2", title: "B"),
        ])
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"test-server:t1"}}"#,
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"test-server:t2"}}"#,
        ], closing: "两次替换都完成。")
        await AgentRunner.run(
            userText: "先放 A 再换成 B",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(bridge.replacedQueues.count == 2)
        #expect(await collector.containsText("两次替换都完成"))
    }

    @Test("TEST11 完全相同 queue_replace 第二次幂等，任务继续")
    func queueReplaceSameArgsIsIdempotent() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [
            makePermTrack(serverID: "test-server", remoteID: "t1", title: "A"),
        ])
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"test-server:t1"}}"#,
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"test-server:t1"}}"#,
        ], closing: "完成。")
        await AgentRunner.run(
            userText: "替换队列",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 只有第一次真正替换；第二次幂等跳过，任务继续。
        #expect(bridge.replacedQueues.count == 1)
        #expect(await collector.containsText("完成"))
    }

    // MARK: - TEST 12：单工具超时不终止任务

    @Test("TEST12 单工具超时后模型调用 fallback 工具并完成")
    func toolTimeoutAllowsFallback() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        bridge.slowTestConnection = true
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"server_test_connection","args":{"serverID":"test-server"}}"#,
            #"ACTION: {"tool":"library_search","args":{"query":"fallback"}}"#,
        ], closing: "改用本地搜索完成。")
        await AgentRunner.run(
            userText: "检查服务器",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            intent: .conversation,
            toolTimeout: 0.05,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 初始请求 + 超时工具 + fallback 工具 + 最终回答。
        #expect(provider.requests.count >= 3)
        #expect(provider.requests.dropFirst().contains { req in
            req.messages.contains { $0.role == .user && $0.content.contains("server_test_connection: 超时") }
        })
        #expect(await collector.containsText("改用本地搜索完成"))
        #expect(await collector.containsError("已停止本次任务") == false)
    }

    // MARK: - TEST 13-16：不可逆删除需批准 / 消歧 / 幂等

    @Test("TEST13 删除跑步歌单（唯一目标）只请求一次批准后执行")
    func deletePlaylistDirectExecution() async throws {
        let store = try makePermStore()
        try await store.upsertPlaylist(Playlist(id: "pl-a", serverID: "test-server", name: "跑步", trackIDs: []), serverID: "test-server")
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let probe = PermissiveProbe()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"deletePlaylist","args":{"playlistID":"test-server:pl-a"}}"#,
        ], closing: "已删除跑步歌单。")
        await AgentRunner.run(
            userText: "删除跑步歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { await probe.decide($0) },
            emit: { await collector.record($0) }
        )
        #expect(bridge.deletedPlaylists.contains(GlobalID(serverID: "test-server", remoteID: "pl-a")))
        #expect(await probe.calls == 1)
        #expect(await collector.containsError("没有权限") == false)
        #expect(await collector.containsError("获准范围") == false)
    }

    @Test("不可逆删除被拒绝时不触发 bridge，且同一调用不会反复弹窗")
    func deniedPlaylistDeletionDoesNotExecute() async throws {
        let store = try makePermStore()
        try await store.upsertPlaylist(Playlist(id: "pl-denied", serverID: "test-server", name: "私密", trackIDs: []), serverID: "test-server")
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let probe = RejectingProbe()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"playlist_delete","args":{"playlistID":"test-server:pl-denied"}}"#,
            #"ACTION: {"tool":"playlist_delete","args":{"playlistID":"test-server:pl-denied"}}"#,
        ], closing: "已停止。")
        await AgentRunner.run(
            userText: "删除私密歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { await probe.decide($0) },
            emit: { await collector.record($0) }
        )
        #expect(bridge.deletedPlaylists.isEmpty)
        #expect(await probe.calls == 1)
        #expect(await collector.containsError("未批准"))
    }

    @Test("TEST14 两个同名歌单可分别列出（消歧靠实体解析，不靠风险确认）")
    func twoSameNamePlaylistsAreListedForDisambiguation() async throws {
        let store = try makePermStore()
        try await store.upsertPlaylist(Playlist(id: "pl-a", serverID: "test-server", name: "跑步", trackIDs: []), serverID: "test-server")
        try await store.upsertPlaylist(Playlist(id: "pl-b", serverID: "test-server", name: "跑步", trackIDs: []), serverID: "test-server")
        let result = await AgentToolkit.execute(
            ToolCall(name: "listPlaylists", arguments: [:]),
            bridge: PermissiveBridge(),
            catalog: store,
            serverID: "test-server"
        )
        #expect(result.success)
        #expect(result.summary.contains("2"))
    }

    @Test("TEST15 明确 playlistID 时直接删除")
    func deletePlaylistWithExplicitID() async throws {
        let store = try makePermStore()
        try await store.upsertPlaylist(Playlist(id: "pl-x", serverID: "test-server", name: "通勤", trackIDs: []), serverID: "test-server")
        let bridge = PermissiveBridge()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"deletePlaylist","args":{"playlistID":"test-server:pl-x"}}"#,
        ], closing: "已删除。")
        await AgentRunner.run(
            userText: "删除歌单 test-server:pl-x",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { _ in true },
            emit: { _ in }
        )
        #expect(bridge.deletedPlaylists.contains(GlobalID(serverID: "test-server", remoteID: "pl-x")))
    }

    @Test("TEST16 删除同一歌单两次：第二次不崩溃，任务继续")
    func deleteSamePlaylistTwiceNoCrash() async throws {
        let store = try makePermStore()
        try await store.upsertPlaylist(Playlist(id: "pl-a", serverID: "test-server", name: "跑步", trackIDs: []), serverID: "test-server")
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"deletePlaylist","args":{"playlistID":"test-server:pl-a"}}"#,
            #"ACTION: {"tool":"deletePlaylist","args":{"playlistID":"test-server:pl-a"}}"#,
        ], closing: "完成。")
        await AgentRunner.run(
            userText: "删除跑步歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(bridge.deletedPlaylists.count == 1)
        #expect(await collector.containsText("完成"))
    }

    // MARK: - TEST 17 / 18：清空队列 / 删除下载直接执行

    @Test("TEST17 清空队列直接执行，无确认")
    func clearQueueDirectExecution() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let probe = PermissiveProbe()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"queue_clear","args":{}}"#,
        ], closing: "队列已清空。")
        await AgentRunner.run(
            userText: "清空当前队列",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { await probe.decide($0) },
            emit: { _ in }
        )
        #expect(bridge.clearedQueueCount == 1)
        #expect(await probe.calls == 0)
    }

    @Test("TEST18 删除离线下载直接执行（无确认）")
    func removeDownloadDirectExecution() async throws {
        // 当前注册表没有专门的“删除下载”工具；若未来加入，必须直接执行。
        let hasRemoveTool = AgentToolRegistry.all.contains { $0.name.contains("remove") && $0.name.contains("download") }
        #expect(hasRemoveTool == false, "当前没有下载删除工具，本测试只记录现状；不要求凭空新增")
    }

    // MARK: - TEST 19-22：conversation Intent 可调用写/播放/队列/推荐工具

    @Test("TEST19 conversation Intent 可创建歌单")
    func conversationIntentCanCreatePlaylist() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"playlist_create","args":{"name":"深夜歌单"}}"#,
        ], closing: "已创建。")
        await AgentRunner.run(
            userText: "创建一个深夜歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { _ in }
        )
        #expect(bridge.createdPlaylistNames.contains("深夜歌单"))
    }

    @Test("TEST20 conversation Intent 可播放歌曲")
    func conversationIntentCanPlaySong() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "A")])
        let bridge = PermissiveBridge()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"playback_play_song","args":{"trackID":"test-server:t1"}}"#,
        ], closing: "开始播放。")
        await AgentRunner.run(
            userText: "播放这首歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { _ in }
        )
        #expect(bridge.playedTracks.contains(GlobalID(serverID: "test-server", remoteID: "t1")))
    }

    @Test("TEST21 conversation Intent 可管理队列")
    func conversationIntentCanManageQueue() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "A")])
        let bridge = PermissiveBridge()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"test-server:t1"}}"#,
        ], closing: "队列已更新。")
        await AgentRunner.run(
            userText: "把这首歌放进队列",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { _ in }
        )
        #expect(bridge.replacedQueues.count == 1)
    }

    @Test("TEST22 conversation Intent 可调用推荐工具")
    func conversationIntentCanRecommend() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"recommend_by_mood","args":{"mood":"夜晚安静"}}"#,
        ], closing: "已推荐。")
        await AgentRunner.run(
            userText: "推荐几首晚上安静听的",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(provider.requests.count >= 2)
        #expect(provider.requests[1].messages.contains { $0.role == .user && $0.content.contains("（工具执行结果）recommend_by_mood") })
    }

    // MARK: - TEST 27 / 28：Schema 只暴露 canonical，重复别名不占 schema

    @Test("TEST27 旧别名映射回 canonical，不再重复暴露")
    func schemaPrefersCanonicalOverAlias() {
        let search = ToolSelector.select(for: "搜索周杰伦", all: AgentToolRegistry.all)
        let searchNames = Set(search.map(\.name))
        #expect(searchNames.contains("library_search"))
        #expect(!searchNames.contains("searchTracks"))

        let play = ToolSelector.select(for: "播放这首歌", all: AgentToolRegistry.all)
        let playNames = Set(play.map(\.name))
        #expect(playNames.contains("playback_play_song"))
        #expect(!playNames.contains("playTrack"))

        let favorites = ToolSelector.select(for: "我的收藏", all: AgentToolRegistry.all)
        let favNames = Set(favorites.map(\.name))
        #expect(favNames.contains("library_get_starred"))
        #expect(!favNames.contains("getFavorites"))
    }

    @Test("TEST28 发现/播放/队列/歌单/收藏/不喜欢等常用工具均可获得")
    func commonToolsAreObtainable() {
        // §6.1：音乐发现任务一次就能拿到推荐、队列、播放、收藏、不喜欢等工具。
        let discovery = ToolSelector.select(
            for: "给我放一组适合开车提神的歌",
            intent: .musicDiscovery,
            policy: AgentTaskPolicy.policy(for: .musicDiscovery),
            all: AgentToolRegistry.all
        )
        let names = Set(discovery.map(\.name))
        #expect(names.contains("recommend_by_mood"))
        #expect(names.contains("recommend_by_constraints"))
        #expect(names.contains("library_select_tracks"))
        #expect(names.contains("library_get_catalog_index"))
        #expect(names.contains("queue_replace"))
        #expect(names.contains("queue_append"))
        #expect(names.contains("playback_play_song"))
        #expect(names.contains("playback_play_playlist"))
        #expect(names.contains("favorite_set"))
        #expect(names.contains("preference_set_disliked"))
        #expect(names.contains("lyrics_get"))
    }

    // MARK: - TEST 29：Typed Array Schema + canonical-only

    @Test("TEST29 多值参数使用 JSON array schema，不再依赖逗号字符串")
    func typedArraySchemas() throws {
        func schemaType(_ tool: String, _ param: String) -> String? {
            guard let descriptor = AgentToolRegistry.descriptor(for: tool),
                  let parameter = descriptor.parameters.first(where: { $0.name == param }),
                  let json = parameter.schemaJSON,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["type"] as? String
        }
        #expect(schemaType("queue_replace", "trackIDs") == "array")
        #expect(schemaType("playlist_add_songs", "trackIDs") == "array")
        #expect(schemaType("playlist_remove_songs", "indices") == "array")
        #expect(schemaType("library_select_tracks", "languages") == "array")
        #expect(schemaType("library_select_tracks", "genres") == "array")
        #expect(schemaType("library_select_tracks", "artists") == "array")
        #expect(schemaType("library_select_tracks", "excludeTrackIDs") == "array")
        #expect(schemaType("result_present_tracks", "trackIDs") == "array")
    }

    @Test("TEST30 模型只看到一套 canonical 工具（旧别名不同时暴露）")
    func canonicalOnlyInSchema() {
        let selected = ToolSelector.select(for: "删除歌单并移动队列", intent: .playlistManagement, policy: AgentTaskPolicy.policy(for: .playlistManagement), all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("playlist_delete"))
        #expect(!names.contains("deletePlaylist"))
        #expect(!names.contains("reorderPlaylist"))
        #expect(!names.contains("removeTracksFromPlaylist"))
        #expect(!names.contains("renamePlaylist"))
        #expect(!names.contains("duplicatePlaylist"))
        #expect(!names.contains("mergePlaylists"))
        #expect(!names.contains("switchServer"))
        #expect(!names.contains("removeServer"))
    }

    // MARK: - TEST 31：musicDiscovery 无显式 final 时要求 result_present_tracks

    @Test("TEST COUNT-02 中文数量 12：模型忘调 final → Runtime 兜底显示 12 首（不是 5）")
    func chineseCountFallbackUsesTwelve() async throws {
        let store = try makePermStore()
        try await seedPerm(store, (0..<20).map { makePermTrack(serverID: "test-server", remoteID: "t\($0)", title: "歌\($0)") })
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        system.recommendationTracks = (0..<20).map { permCard(GlobalID(serverID: "test-server", remoteID: "t\($0)"), title: "歌\($0)") }
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"recommend_by_mood","args":{"mood":"开车提神"}}"#,
            "已经为你选好了。",
        ])
        await AgentRunner.run(
            userText: "推荐十二首开车提神的歌给我看看",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 中文数量 12 被识别；模型仍不调用 final → Runtime 兜底取前 12 首。
        let groups = await collector.trackCardGroupCounts()
        #expect(groups == [12])
    }

    @Test("TEST31 纯推荐忘调 result_present_tracks → Runtime 提示一次后再放行")
    func discoveryForcesFinalSelection() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "歌")])
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        system.recommendationTracks = [permCard(GlobalID(serverID: "test-server", remoteID: "t1"), title: "歌")]
        let collector = PermissiveCollector()
        // 模型只推荐（产生候选），忘记调用 result_present_tracks，直接给最终回答。
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"recommend_by_mood","args":{"mood":"开车提神"}}"#,
            "已经为你选好 1 首适合开车提神的歌。",
        ])
        await AgentRunner.run(
            userText: "推荐一首开车提神的歌给我看看",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 第二轮应出现要求调用 result_present_tracks 的完成校验指令。
        #expect(provider.requests.count >= 3)
        let repairSeen = provider.requests.dropFirst().contains { req in
            req.messages.contains { $0.role == .user && $0.content.contains("result_present_tracks") }
        }
        #expect(repairSeen)
        // 模型仍不调用 result_present_tracks → Runtime 确定性兜底：按用户要求数量（1 首）建立 final。
        let groups = await collector.trackCardGroupCounts()
        #expect(groups == [1])
    }

    // MARK: - TEST 23 / 24：隐私与凭据

    @Test("TEST23 allowsLyrics=false 时歌词正文不进入 Provider 请求")
    func lyricsBodyHiddenWhenDisabled() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "秘密歌词")])
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"lyrics_get","args":{"trackID":"test-server:t1"}}"#,
        ], closing: "歌词已处理。")
        await AgentRunner.run(
            userText: "看歌词",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0, allowsLyrics: false),
            systemService: system,
            intent: .conversation,
            confirm: { _ in true },
            emit: { _ in }
        )
        // 回灌结果被替换成隐私占位，真实歌词内容（来自 lyrics 桩）不会进入后续请求。
        #expect(provider.requests.dropFirst().contains { req in
            req.messages.contains { $0.role == .user && $0.content.contains("歌词已按隐私设置隐藏") }
        })
        #expect(provider.requests.contains { req in
            req.messages.contains { $0.role == .user && $0.content.contains("hidden-lyrics-body") }
        } == false)
    }

    @Test("TEST24 凭据不进入模型上下文（redactor + 日志摘要）")
    func credentialsNeverEnterContextOrLogs() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"addServer","args":{"displayName":"NAS","baseURL":"http://192.168.1.2","username":"admin","token":"sekret-token-xyz"}}"#,
        ], closing: "已完成。")
        await AgentRunner.run(
            userText: "添加服务器",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) },
            log: { _ in }
        )
        // redactor：日志/轨迹参数一律脱敏。
        let redacted = AgentSensitiveDataRedactor.arguments(["token": "sekret-token-xyz", "baseURL": "http://192.168.1.2"])
        #expect(redacted["token"] == "<redacted>")
        #expect(redacted["baseURL"] == "<redacted>")
        // addServer 工具本身不把 token 写进任何 Tool Result / 日志摘要。
        #expect(await collector.containsText("sekret-token-xyz") == false)
    }

    // MARK: - TEST 25：用户取消立即结束

    @Test("TEST25 用户取消立即结束")
    func userCancelStopsImmediately() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        bridge.slowTestConnection = true
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"server_test_connection","args":{"serverID":"test-server"}}"#,
        ])
        let task = Task {
            await AgentRunner.run(
                userText: "检查服务器",
                provider: provider,
                model: "scripted-model",
                bridge: bridge,
                catalog: store,
                context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
                systemService: system,
                intent: .conversation,
                toolTimeout: 30,
                confirm: { _ in true },
                emit: { await collector.record($0) }
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        // 用 10 秒看门狗兜底，防止取消路径意外悬挂。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            do {
                _ = try await group.next()
            } catch {
                Issue.record("取消后任务未能及时结束")
            }
            group.cancelAll()
        }
        #expect(await collector.containsText("已取消"))
    }

    @Test("TEST25b 取消不响应取消的工具时立即结束")
    func userCancelPropagatesToNonCooperativeTool() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        bridge.nonCooperativeTestConnection = true
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"server_test_connection","args":{"serverID":"test-server"}}"#,
        ])
        let task = Task {
            await AgentRunner.run(
                userText: "检查服务器",
                provider: provider,
                model: "scripted-model",
                bridge: bridge,
                catalog: store,
                context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
                intent: .conversation,
                toolTimeout: 30,
                confirm: { _ in true },
                emit: { await collector.record($0) }
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return false
            }
            if await group.next() != true {
                Issue.record("取消没有及时传递给非协作工具")
            }
            group.cancelAll()
        }
        #expect(await collector.containsText("已取消"))
    }

    @Test("取消非协作写操作会记录结果未知，不伪装成普通取消")
    func cancellingWriteRecordsIndeterminateSideEffect() async throws {
        let store = try makePermStore()
        let bridge = PermissiveBridge()
        bridge.nonCooperativeClearQueue = true
        let collector = PermissiveCollector()
        let actionLog = PermissiveActionLog()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"queue_clear","args":{}}"#,
        ])
        let task = Task {
            await AgentRunner.run(
                userText: "清空队列",
                provider: provider,
                model: "scripted-model",
                bridge: bridge,
                catalog: store,
                context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 1),
                intent: .queueManagement,
                toolTimeout: 30,
                confirm: { _ in true },
                emit: { await collector.record($0) },
                log: { await actionLog.record($0) }
            )
        }
        // 等待工具真正进入非协作 I/O，再取消 Runner；固定 sleep 在并行测试负载下
        // 可能在模型仍准备首轮请求时就取消，误测成普通「已取消」而非结果未知。
        var clearQueueDidStart = false
        for _ in 0..<500 {
            if await bridge.clearQueueStarted.isSignaled() {
                clearQueueDidStart = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(clearQueueDidStart)
        guard clearQueueDidStart else {
            task.cancel()
            _ = await task.value
            return
        }
        task.cancel()
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: .milliseconds(500)); return false }
            if await group.next() != true { Issue.record("取消没有及时结束写操作") }
            group.cancelAll()
        }

        #expect(await collector.containsText("结果未知"))
        #expect(await actionLog.contains("结果未知"))
    }

    @Test("TEST25c 部分写入工具结果阻止相同参数再次执行")
    func indeterminateWriteBlocksAutomaticRetry() async throws {
        let store = try makePermStore()
        let track = makePermTrack(serverID: "test-server", remoteID: "t1", title: "歌")
        try await seedPerm(store, [track])
        try await store.upsertPlaylist(Playlist(id: "pl-a", serverID: "test-server", name: "通勤", trackIDs: []), serverID: "test-server")
        let bridge = PermissiveBridge()
        bridge.playlistAddResult = .indeterminate("已添加 1/2 首")
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"playlist_add_songs","args":{"playlistID":"test-server:pl-a","trackIDs":"test-server:t1"}}"#,
            #"ACTION: {"tool":"playlist_add_songs","args":{"playlistID":"test-server:pl-a","trackIDs":"test-server:t1"}}"#,
        ], closing: "已停止重试。")
        await AgentRunner.run(
            userText: "把歌加入通勤歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .conversation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(bridge.addedToPlaylist.count == 1)
        #expect(await collector.containsText("不会自动重试"))
    }

    // MARK: - TEST 26：无公开 Evidence 时不得编造大众评价

    // MARK: - TEST 64-66：候选不可见 / 最终只有一组 / Cancel/Fail 不倾倒

    @Test("TEST64 纯推荐：30+20+50 候选 → result_present_tracks 12 → 只显示一组 12")
    func pureRecommendationShowsOnlyFinalGroup() async throws {
        let store = try makePermStore()
        let tracks = (0..<50).map { makePermTrack(serverID: "test-server", remoteID: "t\($0)", title: "歌\($0)") }
        try await seedPerm(store, tracks)
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        system.recommendationTracks = (0..<30).map { permCard(GlobalID(serverID: "test-server", remoteID: "t\($0)"), title: "歌\($0)") }
        let collector = PermissiveCollector()
        // 12 首最终 ID。
        let finalIDs = (0..<12).map { "test-server:t\($0)" }.joined(separator: ",")
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"recommend_by_constraints","args":{"limit":"30"}}"#,
            #"ACTION: {"tool":"recommend_by_mood","args":{"mood":"开车提神"}}"#,
            #"ACTION: {"tool":"library_select_tracks","args":{"limit":"50"}}"#,
            #"ACTION: {"tool":"result_present_tracks","args":{"trackIDs":"\#(finalIDs)"}}"#,
        ], closing: "已经为你选好 12 首适合开车提神的歌曲。")
        await AgentRunner.run(
            userText: "推荐 12 首开车提神的歌给我看看",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            systemService: system,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 最终只收到一组 12 首，绝不能收到 30/20/50 候选组。
        let groups = await collector.trackCardGroupCounts()
        #expect(groups == [12])
    }

    @Test("TEST65 创建歌单：60 候选 → playlist_add_songs 12 → 只显示 12")
    func playlistCreationShowsOnlyAdded() async throws {
        let store = try makePermStore()
        let tracks = (0..<60).map { makePermTrack(serverID: "test-server", remoteID: "t\($0)", title: "歌\($0)") }
        try await seedPerm(store, tracks)
        try await store.upsertPlaylist(Playlist(id: "pl-a", serverID: "test-server", name: "开车提神", trackIDs: []), serverID: "test-server")
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let ids = (0..<12).map { "test-server:t\($0)" }.joined(separator: ",")
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"library_select_tracks","args":{"limit":"60"}}"#,
            #"ACTION: {"tool":"playlist_add_songs","args":{"playlistID":"test-server:pl-a","trackIDs":"\#(ids)"}}"#,
        ], closing: "已创建歌单《开车提神》· 12 首。")
        await AgentRunner.run(
            userText: "帮我建一个 12 首开车提神歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(await bridge.addedToPlaylist.count == 1)
        let groups = await collector.trackCardGroupCounts()
        #expect(groups == [12])
    }

    @Test("TEST66 queue_replace：40 候选 → 10 入队 → 只显示 10")
    func queueReplaceShowsOnlyQueued() async throws {
        let store = try makePermStore()
        let tracks = (0..<40).map { makePermTrack(serverID: "test-server", remoteID: "t\($0)", title: "歌\($0)") }
        try await seedPerm(store, tracks)
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        let ids = (0..<10).map { "test-server:t\($0)" }.joined(separator: ",")
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"library_select_tracks","args":{"limit":"40"}}"#,
            #"ACTION: {"tool":"queue_replace","args":{"trackIDs":"\#(ids)"}}"#,
        ], closing: "队列已替换为 10 首。")
        await AgentRunner.run(
            userText: "放一组 10 首提神的歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        #expect(bridge.replacedQueues.count == 1)
        let groups = await collector.trackCardGroupCounts()
        #expect(groups == [10])
    }

    @Test("TEST-Cancel Cancel 不倾倒候选池")
    func cancelDoesNotDumpCandidates() async throws {
        let store = try makePermStore()
        let tracks = (0..<80).map { makePermTrack(serverID: "test-server", remoteID: "t\($0)", title: "歌\($0)") }
        try await seedPerm(store, tracks)
        let bridge = PermissiveBridge()
        let system = PermissiveSystemService()
        bridge.slowTestConnection = true
        let collector = PermissiveCollector()
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"library_select_tracks","args":{"limit":"80"}}"#,
            #"ACTION: {"tool":"server_test_connection","args":{"serverID":"test-server"}}"#,
        ])
        let task = Task {
            await AgentRunner.run(
                userText: "搜索 80 首候选",
                provider: provider,
                model: "scripted-model",
                bridge: bridge,
                catalog: store,
                context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
                systemService: system,
                intent: .conversation,
                toolTimeout: 30,
                confirm: { _ in true },
                emit: { await collector.record($0) }
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            do { _ = try await group.next() } catch { Issue.record("取消后任务未能及时结束") }
            group.cancelAll()
        }
        // Cancel 时绝不倾倒 80 首候选。
        #expect(await collector.containsAnyTrackCards() == false)
        #expect(await collector.containsText("已取消"))
    }

    @Test("TEST-Fail 任务失败不倾倒候选池")
    func failureDoesNotDumpCandidates() async throws {
        let store = try makePermStore()
        let tracks = (0..<30).map { makePermTrack(serverID: "test-server", remoteID: "t\($0)", title: "歌\($0)") }
        try await seedPerm(store, tracks)
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        // 收集候选后，歌单操作失败（不存在该歌单）→ 完成条件不满足 → 任务失败。
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"library_select_tracks","args":{"limit":"30"}}"#,
            #"ACTION: {"tool":"playlist_add_songs","args":{"playlistID":"test-server:missing","trackIDs":"test-server:t1"}}"#,
        ])
        await AgentRunner.run(
            userText: "把候选加入一个不存在的歌单",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .playlistManagement,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 失败只显示失败原因，绝不倾倒 30 首候选。
        #expect(await collector.containsAnyTrackCards() == false)
        #expect(await collector.containsError("没有满足确定性完成条件"))
    }

    @Test("TEST26 无公开 Evidence 时任务不允许编造大众共识")
    func appreciationCannotFabricateConsensus() async throws {
        let store = try makePermStore()
        try await seedPerm(store, [makePermTrack(serverID: "test-server", remoteID: "t1", title: "秘密")])
        let bridge = PermissiveBridge()
        let collector = PermissiveCollector()
        // 模型在无 Community Evidence 时声称“大众普遍认为…”，应被完成校验拒绝。
        let provider = PermissiveScriptedProvider(actionBatches: [
            #"ACTION: {"tool":"music_appreciate","args":{"trackID":"test-server:t1"}}"#,
            "【已核验事实】x【模型分析】x【我的私人数据】x【大众评价】大众普遍认为它广受好评。",
        ])
        await AgentRunner.run(
            userText: "鉴赏这首歌",
            provider: provider,
            model: "scripted-model",
            bridge: bridge,
            catalog: store,
            context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
            intent: .musicAppreciation,
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        // 无证据的“大众共识”不能作为成功回答输出。
        #expect(await collector.containsError("没有满足确定性完成条件"))
        #expect(await collector.containsText("广受好评") == false)
    }
}
