// SPDX-License-Identifier: GPL-3.0-only
import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - 工具编排协作层专项回归测试
//
// 覆盖实机场景：
// A 总体统计 / B 限定统计 / C 队列复合任务 / D 同义表达 / E 删除歌单单次确认 /
// F 拒绝后不重复弹窗 / G generic Agent 交给模型判断能力 / H 续写 /
// I tool_search 自然语言检索 / J tool_search 诊断计数 / L mutation speculative text /
// M 模型自创确认不阻塞 / K Anthropic 顺序（放 AIKitTests）。

// MARK: - Test doubles（自包含，避免与其它测试文件私有符号冲突）

private actor OrchestrationCollector {
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

    func joinedText() -> String {
        messages.flatMap { message in
            message.messages.compactMap { item -> String? in
                if case let .text(value) = item { return value }
                return nil
            }
        }.joined(separator: "\n")
    }
}

private actor OrchestrationConfirmProbe {
    private(set) var calls = 0
    private(set) var decisions: [PendingConfirmation] = []
    private let approve: Bool

    init(approve: Bool) { self.approve = approve }

    func decide(_ pending: PendingConfirmation) -> Bool {
        calls += 1
        decisions.append(pending)
        return approve
    }

    func count() -> Int { calls }
}

private final class OrchestrationBridge: AgentBridge, @unchecked Sendable {
    let activeServerIDValue: ServerID?
    let deleteSideEffect: (@Sendable (GlobalID) async throws -> Void)?
    init(
        activeServerID: ServerID? = nil,
        deleteSideEffect: (@Sendable (GlobalID) async throws -> Void)? = nil
    ) {
        self.activeServerIDValue = activeServerID
        self.deleteSideEffect = deleteSideEffect
    }
    var activeServerID: ServerID? { activeServerIDValue }
    var lyricsStateValue: AgentLyricsState = .unknown
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }
    func currentTrack() -> Track? { lastPlayed }
    // currentQueue 反映最近一次 replaceQueue 的结果（供 Skill 的队列验证读取）。
    func currentQueue() -> [Track] {
        guard let gids = replacedQueues.last else { return [] }
        return gids.enumerated().map { index, gid in
            Track(
                id: TrackID(rawValue: gid.remoteID ?? "t\(index)"),
                serverID: gid.serverID,
                albumID: AlbumID(rawValue: "\(gid.remoteID ?? "t\(index)")-album"),
                artistID: ArtistID(rawValue: "\(gid.remoteID ?? "t\(index)")-artist"),
                title: "歌\(index)",
                artistName: "周杰伦",
                albumTitle: "专辑",
                duration: 200
            )
        }
    }

    private(set) var playedTracks: [GlobalID] = []
    private(set) var replacedQueues: [[GlobalID]] = []
    private(set) var clearedQueueCount = 0
    private(set) var deletedPlaylists: [GlobalID] = []
    private(set) var appendedQueues: [GlobalID] = []
    /// 最近一次成功播放的曲目（供 playback_get_state 状态验证）。
    private var lastPlayed: Track?

    var playResult: Bool = true
    var mutationResult: AgentMutationResult = .confirmed("ok")

    func playTrack(globalID: GlobalID) async -> Bool {
        playedTracks.append(globalID)
        if playResult {
            lastPlayed = Track(
                id: TrackID(rawValue: globalID.remoteID),
                serverID: globalID.serverID,
                albumID: AlbumID(rawValue: "\(globalID.remoteID)-album"),
                artistID: ArtistID(rawValue: "\(globalID.remoteID)-artist"),
                title: "播放中",
                artistName: "周杰伦",
                albumTitle: "专辑",
                duration: 200
            )
        }
        return playResult
    }
    func playServerTrack(globalID: GlobalID) async -> Bool { true }
    func playAlbum(globalID: GlobalID) async -> Bool { true }
    func playPlaylist(globalID: GlobalID) async -> Bool { true }
    func playRandom(limit: Int) async -> AgentMutationResult { mutationResult }
    func pause() async -> AgentMutationResult { mutationResult }
    func resume() async -> AgentMutationResult { mutationResult }
    func seek(seconds: TimeInterval) async -> AgentMutationResult { mutationResult }
    func next() async -> AgentMutationResult { mutationResult }
    func previous() async -> AgentMutationResult { mutationResult }
    func setShuffle(_ enabled: Bool) async -> AgentMutationResult { mutationResult }
    func setRepeatMode(_ mode: RepeatMode) async -> AgentMutationResult { mutationResult }
    func setPlaybackRate(_ rate: Float) async -> AgentMutationResult { mutationResult }
    func setSleepTimer(mode: String, minutes: TimeInterval) async -> AgentMutationResult { mutationResult }
    func cancelSleepTimer() async -> AgentMutationResult { mutationResult }
    func getSleepTimer() async -> (mode: String, remaining: TimeInterval) { ("off", 0) }
    func addToQueue(globalID: GlobalID) async -> AgentMutationResult {
        appendedQueues.append(globalID)
        return mutationResult
    }
    func playNext(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func playNext(globalIDs: [GlobalID]) async -> AgentMutationResult { mutationResult }
    func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult {
        replacedQueues.append(globalIDs)
        return mutationResult
    }
    func removeFromQueue(at index: Int) async -> AgentMutationResult { mutationResult }
    func reorderQueue(from: Int, to: Int) async -> AgentMutationResult { mutationResult }
    func clearQueue() async -> AgentMutationResult { clearedQueueCount += 1; return mutationResult }
    func shuffleRemaining() async -> AgentMutationResult { mutationResult }
    func saveQueueAsPlaylist(name: String) async -> AgentMutationResult { mutationResult }

    func createPlaylist(name: String) async -> GlobalID? { nil }
    func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { mutationResult }
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult { mutationResult }
    func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult { mutationResult }
    func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult { mutationResult }
    func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult { mutationResult }
    func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult { mutationResult }
    func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult {
        try? await deleteSideEffect?(globalID)
        deletedPlaylists.append(globalID)
        return mutationResult
    }

    func likeTrack(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func unlikeTrack(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func favoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func unfavoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func favoriteArtist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func unfavoriteArtist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
    func setRating(globalID: GlobalID, rating: Int) async -> AgentMutationResult { mutationResult }
    func clearRating(globalID: GlobalID) async -> AgentMutationResult { mutationResult }

    func listServers() async -> [ServerAccount] { [] }
    func getActiveServer() async -> ServerAccount? { nil }
    func testServerConnection(serverID: ServerID) async -> Bool { true }
    func addServer(displayName: String, baseURL: String, username: String, token: String) async -> AgentMutationResult { mutationResult }
    func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> AgentMutationResult { mutationResult }
    func switchServer(serverID: ServerID) async -> AgentMutationResult { mutationResult }
    func refreshLibrary() async -> AgentMutationResult { mutationResult }
    func getSyncStatus() async -> [CatalogSyncStatus] { [] }
    func removeServer(serverID: ServerID) async -> AgentMutationResult { mutationResult }
    func serverSearch(query: String, limit: Int) async -> [Track] { [] }
}

/// Native（openAIChat）脚本 Provider：每个请求消费一个响应；保留请求记录。
private final class OrchestrationProvider: AIProvider, @unchecked Sendable {
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
        AIConnectionResult(latency: 0, model: "orchestration", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        nextResponse(for: request)
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let response = nextResponse(for: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(model: response.model))
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

// MARK: - Helpers

private func orchestrationStore() throws -> LocalCatalogStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-orchestration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
}

private func orchestrationTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: serverID,
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "周杰伦",
        albumTitle: "Album \(remoteID)",
        duration: 200
    )
}

private func seedOrchestration(_ store: LocalCatalogStore, tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

private func orchestrationCall(id: String, name: String, arguments: [String: AIJSONValue] = [:]) -> AIToolCall {
    AIToolCall(id: id, name: name, arguments: .object(arguments))
}

private func orchestrationResponse(content: String = "", calls: [AIToolCall] = []) -> AICompletionResponse {
    AICompletionResponse(model: "orchestration", content: content, toolCalls: calls.isEmpty ? nil : calls)
}

private let orchestrationServerID: ServerID = "orch-server"

// MARK: - 场景 A/B：总体统计 vs 限定统计

@Suite("Agent tool orchestration")
struct AgentToolOrchestrationRegressionTests {

    @Test("A 总体统计走 library_get_summary fast path，不进入模型规划")
    func libraryStatsDirectReadExactlyOneTool() async throws {
        let store = try orchestrationStore()
        try await seedOrchestration(store, tracks: (0..<3).map { orchestrationTrack(serverID: orchestrationServerID, remoteID: "t\($0)", title: "歌\($0)") })
        let runID = UUID()
        let provider = OrchestrationProvider([orchestrationResponse(content: "不应进入模型规划")])
        let collector = OrchestrationCollector()
        await ConversationEngine().run(
            userText: "音乐库统计",
            provider: provider,
            model: "orch",
            bridge: OrchestrationBridge(),
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(provider.requests().isEmpty, "总体统计不应发起模型规划")
        let metrics = await ToolMetricsCollector.shared.snapshot().filter { $0.runID == runID }
        #expect(metrics.map(\.toolName) == ["library_get_summary"])
    }

    @Test("B 限定统计（有多少中文歌手）绝不直接 library_get_summary")
    func qualifiedAggregateNeverRoutesToGlobalSummary() {
        // 允许 fast path：无修饰、无过滤条件的全局 aggregate。
        for text in ["音乐库统计", "曲库统计", "一共有多少歌手", "曲库有多少首歌", "音乐库有多少张专辑"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(semantics.directReadCapability?.toolName == "library_get_summary", "「\(text)」应命中 library_get_summary")
        }
        // 禁止 fast path：带限定/过滤条件。
        for text in ["有多少中文歌手", "有多少女歌手", "有多少日本歌手", "多少古典歌曲", "多少无损歌曲", "有多少 2020 年后的专辑", "多少周杰伦的歌曲"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(semantics.directReadCapability == nil, "「\(text)」不得直接映射 library_get_summary")
        }
    }

    @Test("B2 限定统计进入普通模型规划而非总体统计")
    func qualifiedStatsConsultModel() async throws {
        let store = try orchestrationStore()
        try await seedOrchestration(store, tracks: (0..<2).map { orchestrationTrack(serverID: orchestrationServerID, remoteID: "t\($0)", title: "歌\($0)") })
        let runID = UUID()
        let provider = OrchestrationProvider([
            orchestrationResponse(content: "当前资料字段没有可靠的中文歌手统计，无法精确给出数量。"),
        ])
        let collector = OrchestrationCollector()
        await ConversationEngine().run(
            userText: "有多少中文歌手",
            provider: provider,
            model: "orch",
            bridge: OrchestrationBridge(),
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(!provider.requests().isEmpty, "限定统计应进入模型规划")
        let answeredChinese = await collector.containsText("中文歌手")
        #expect(answeredChinese, "应展示模型的真实回答")
        let metrics = await ToolMetricsCollector.shared.snapshot().filter { $0.runID == runID }
        #expect(!metrics.contains { $0.toolName == "library_get_summary" }, "限定统计不得执行 library_get_summary")
    }

    // MARK: - 场景 C/D：队列复合任务与同义表达

    @Test("C 列出十首周杰伦的歌曲，替换到队列播放 → queueReplace+playbackPlay 编译")
    func compoundQueuePlayIntentCompiles() {
        let semantics = AgentRequestSemantics.analyze("列出十首周杰伦的歌曲，替换到队列播放")
        #expect(semantics.requestedOperations == [.queueReplace, .playbackPlay])
    }

    @Test("D 同义表达归一为 queueReplace")
    func queueReplaceSynonymsNormalize() {
        for text in ["替换队列", "替换到队列", "换成当前队列", "用这些歌覆盖当前队列", "把队列换成这些歌曲"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(semantics.requestedOperations.contains(.queueReplace), "「\(text)」应归一为 queueReplace")
        }
    }

    @Test("C2 歌单创建复合意图：空歌单只有 create；带歌曲才有 add；保存队列为歌单")
    func playlistCompoundCompiles() {
        let bare = AgentRequestSemantics.analyze("创建一个空歌单 Test")
        #expect(bare.requestedOperations == [.playlistCreate], "空歌单不得自动授权加歌")

        let withSongs = AgentRequestSemantics.analyze("创建一个 20 首适合通勤的歌单")
        #expect(withSongs.requestedOperations.contains(.playlistCreate))
        #expect(withSongs.requestedOperations.contains(.playlistAdd))

        let saveQueue = AgentRequestSemantics.analyze("保存当前队列为歌单")
        #expect(saveQueue.requestedOperations == [.playlistSaveQueue])
    }

    @Test("C3 ToolSelector 只暴露获准 mutation，不暴露 queue_clear / queue_append_many")
    func mutationExposureMatchesAuthorizationPlan() {
        let plan = AgentRequestPlan.build(
            userText: "列出十首周杰伦的歌曲，替换到队列播放",
            history: []
        )
        #expect(plan.allowedOperations == [.queueReplace, .playbackPlay])
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("queue_replace"))
        #expect(names.contains("playback_play_song"))
        #expect(!names.contains("queue_clear"))
        #expect(!names.contains("queue_append_many"))
        #expect(!names.contains("playlist_delete"))
        #expect(!names.contains("server_remove"))
    }

    @Test("C4 暂停播放只保留相关 playback schema，执行层不靠 exact operation gate")
    func pauseExposesRelevantPlaybackMutation() {
        let plan = AgentRequestPlan.build(userText: "暂停播放", history: [])
        #expect(plan.allowedOperations == [.playbackPause])
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let mutations = selected.filter { $0.permission != .readOnly }.map(\.name)
        #expect(!mutations.contains("playback_next"), "不应暴露下一首，实际：\(mutations)")
        #expect(!mutations.contains("playback_previous"), "不应暴露上一首，实际：\(mutations)")
        #expect(!mutations.contains("playback_seek"), "不应暴露定位，实际：\(mutations)")
        #expect(!mutations.contains("playback_set_shuffle"), "不应暴露随机，实际：\(mutations)")
        #expect(!mutations.contains("playback_set_repeat"), "不应暴露循环，实际：\(mutations)")
        #expect(mutations.contains("playback_pause"), "应暴露 playback_pause")
        #expect(!mutations.contains("playlist_delete"))
        #expect(!mutations.contains("server_remove"))
    }

    @Test("C5 端到端：搜索→提交候选→Skill 替换队列→播放，无确认、无 queue_clear")
    func jayChouQueueReplacePlaysEndToEnd() async throws {
        let store = try orchestrationStore()
        try await seedOrchestration(store, tracks: (0..<10).map { orchestrationTrack(serverID: orchestrationServerID, remoteID: "t\($0)", title: "歌\($0)") })
        let bridge = OrchestrationBridge()
        let collector = OrchestrationCollector()
        let probe = OrchestrationConfirmProbe(approve: true)
        let ids = (0..<10).map { "\(orchestrationServerID.rawValue):t\($0)" }
        // v2 架构：mutation 由 QueueReplacePlaybackSkill 接管；模型只负责
        // 搜索 + result_present_tracks 提交最终候选，queue_replace/playback
        // 由 Skill 内部固定调用 ToolRuntime（forcedSkillCall，不再消耗模型轮次）。
        let provider = OrchestrationProvider([
            orchestrationResponse(calls: [orchestrationCall(id: "c1", name: "library_search", arguments: ["query": .string("周杰伦")])]),
            orchestrationResponse(calls: [orchestrationCall(id: "c2", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
            orchestrationResponse(content: "已经用这 10 首替换队列并开始播放。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "列出十首周杰伦的歌曲，替换到队列播放",
            provider: provider,
            model: "orch",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { await probe.decide($0) },
            emit: { await collector.append($0) }
        )
        #expect(bridge.replacedQueues.count == 1)
        #expect(bridge.replacedQueues.first?.count == 10)
        #expect(bridge.playedTracks.contains(GlobalID(serverID: orchestrationServerID, remoteID: "t0")))
        #expect(bridge.clearedQueueCount == 0, "队列复合任务不得触碰 queue_clear")
        #expect(bridge.appendedQueues.isEmpty, "不得 fallback 到 queue_append")
        let probeCount = await probe.count()
        #expect(probeCount == 0, "可逆 mutation 不需要模型自创确认")
        let textA = await collector.containsText("队列已替换并开始播放")
        let textB = await collector.containsText("验证完成")
        #expect(textA || textB)
    }

    // MARK: - 场景 E/F：删除歌单确认单次化

    @Test("E 删除歌单：一次正式确认、一次真实删除，不再 tool_search / 重复确认")
    func deletePlaylistSingleConfirmation() async throws {
        let store = try orchestrationStore()
        try await store.upsertPlaylist(
            Playlist(id: "pl-a", serverID: orchestrationServerID, name: "跑步", trackIDs: []),
            serverID: orchestrationServerID
        )
        let bridge = OrchestrationBridge()
        let collector = OrchestrationCollector()
        let probe = OrchestrationConfirmProbe(approve: true)
        let provider = OrchestrationProvider([
            orchestrationResponse(calls: [orchestrationCall(id: "d1", name: "playlist_delete", arguments: ["playlistID": .string("\(orchestrationServerID.rawValue):pl-a")])]),
            orchestrationResponse(content: "已删除跑步歌单。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "删除歌单 跑步",
            provider: provider,
            model: "orch",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { await probe.decide($0) },
            emit: { await collector.append($0) }
        )
        #expect(bridge.deletedPlaylists.count == 1)
        let probeCount = await probe.count()
        #expect(probeCount == 1, "不可逆删除只出现一次正式确认")
        let confirmation = await probe.decisions.first
        #expect(confirmation?.title == "删除歌单「跑步」？")
        #expect(confirmation?.detail.contains("跑步") == true)
        #expect(confirmation?.detail.contains("0 首") == true)
        #expect(confirmation?.detail.contains("不可逆") == true)
        #expect(confirmation?.detail.contains("playlistID=") != true)
        #expect(confirmation?.title.contains(orchestrationServerID.rawValue) != true)
        var toolSearchCount = 0
        for request in provider.requests() {
            let hasSearch = request.transcript.messages.contains { message in
                message.toolCalls?.contains { $0.name == "tool_search" } == true
            }
            if hasSearch { toolSearchCount += 1 }
        }
        #expect(toolSearchCount == 0)
    }

    @Test("F 用户拒绝删除：同一 run 不再弹第二次确认，且不执行")
    func deniedDeleteDoesNotReprompt() async throws {
        let store = try orchestrationStore()
        try await store.upsertPlaylist(
            Playlist(id: "pl-denied", serverID: orchestrationServerID, name: "私密", trackIDs: []),
            serverID: orchestrationServerID
        )
        let bridge = OrchestrationBridge()
        let collector = OrchestrationCollector()
        let probe = OrchestrationConfirmProbe(approve: false)
        let provider = OrchestrationProvider([
            orchestrationResponse(calls: [orchestrationCall(id: "r1", name: "playlist_delete", arguments: ["playlistID": .string("\(orchestrationServerID.rawValue):pl-denied")])]),
            orchestrationResponse(calls: [orchestrationCall(id: "r2", name: "playlist_delete", arguments: ["playlistID": .string("\(orchestrationServerID.rawValue):pl-denied")])]),
            orchestrationResponse(content: "已停止。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "删除歌单 私密",
            provider: provider,
            model: "orch",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { await probe.decide($0) },
            emit: { await collector.append($0) }
        )
        #expect(bridge.deletedPlaylists.isEmpty)
        let probeCount = await probe.count()
        #expect(probeCount == 1, "拒绝后同一参数不得再次弹确认")
        let stoppedText = await collector.containsText("已停止")
        let stoppedError = await collector.containsError("未批准")
        #expect(stoppedText || stoppedError)
    }

    // MARK: - 场景 G：generic Agent 不在模型规划前 fail-fast

    @Test("G 删除曲婉婷的所有歌曲：Runtime 允许模型先规划并查询能力")
    func unsupportedTrackDeletionAllowsModelPlanning() async throws {
        let store = try orchestrationStore()
        let provider = OrchestrationProvider([
            orchestrationResponse(calls: [orchestrationCall(id: "s1", name: "tool_search", arguments: ["query": .string("删除歌曲")])]),
            orchestrationResponse(content: "当前工具结果无法确认删除能力，我会如实说明。"),
        ])
        let collector = OrchestrationCollector()
        let runID = UUID()
        await ConversationEngine().run(
            userText: "删除曲婉婷的所有歌曲",
            provider: provider,
            model: "orch",
            bridge: OrchestrationBridge(),
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(provider.requests().count >= 2, "generic Agent 应先让模型规划并处理 tool_search 结果")
        #expect(await collector.containsText("当前工具结果无法确认删除能力"))
        #expect(await collector.containsError("没有删除音乐服务器曲库文件") == false, "能力诊断不得在模型规划前直接终止")
    }

    // MARK: - 场景 H：续写

    @Test("H 第一个 → 继承上一 lineage 的播放授权并保持 playback 工具暴露")
    func continuationInheritsPlaybackLineage() {
        let history = [
            AgentChatMessage(id: UUID(), role: .user, messages: [.text("播放 Sunset")]),
            AgentChatMessage(id: UUID(), role: .assistant, messages: [.text("找到两个版本，请问选哪个？")]),
        ]
        let plan = AgentRequestPlan.build(userText: "第一个", history: history)
        #expect(plan.relevantHistoryText == "播放 Sunset")
        #expect(plan.semantics.isContinuation)
        #expect(plan.intent == .playbackControl)
        #expect(plan.allowedOperations.contains(.playbackPlay))
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        #expect(Set(selected.map(\.name)).contains("playback_play_song"))
    }

    // MARK: - 场景 I：tool_search 自然语言检索

    @Test("I 把歌曲安排成下一首播放 → 能发现 queue_play_next")
    func naturalLanguageSearchFindsPlayNext() {
        let catalog = ToolCatalog(descriptors: AgentToolRegistry.all)
        for query in ["把歌曲安排成下一首播放", "下一首播放", "接下来播放", "play next"] {
            let names = catalog.search(query: query).map(\.name)
            let found = names.contains("queue_play_next")
            let top = Array(names.prefix(8))
            #expect(found, "「\(query)」应命中 queue_play_next，实际：\(top)")
        }
    }

    @Test("I2 tool_search 保留风险元数据但不标记普通 mutation 未授权")
    func toolSearchDoesNotMarkReversibleMutationsUnauthorized() {
        let catalog = ToolCatalog(descriptors: AgentToolRegistry.all)
        let entries = catalog.search(
            query: "替换队列",
            authorizedOperations: [.playbackPlay]
        )
        #expect(entries.contains { $0.name == "queue_replace" && $0.authorized == nil })
        let readEntry = entries.first { $0.name == "queue_get" }
        #expect(readEntry?.authorized == nil)
        #expect(entries.allSatisfy { !$0.summary.contains("未授权") })
    }

    // MARK: - 场景 J：tool_search 诊断计数

    @Test("J 找不到能力时重复 tool_search 不由 convergence 提前停止")
    func toolSearchThrashRemainsModelControlled() async throws {
        let store = try orchestrationStore()
        let collector = OrchestrationCollector()
        let provider = OrchestrationProvider(Array(repeating: orchestrationResponse(
            calls: [orchestrationCall(id: "t1", name: "tool_search", arguments: ["query": .string("不存在的超能力查询xyz")])]
        ), count: 8))
        let runID = UUID()
        await ConversationEngine().run(
            userText: "帮我做一个完全不存在的操作",
            provider: provider,
            model: "orch",
            bridge: OrchestrationBridge(),
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        // 8 次调用已经超过旧的 tool_search 阈值；普通 Agent 仍由模型决定何时结束。
        #expect(provider.requests().count >= 8)
        #expect(await collector.containsError("当前工具能力不足以完成这个操作") == false)
    }

    // MARK: - 场景 L/M：mutation provisional 文本

    @Test("L mutation 成功声明在真实成功前不显示（缓冲）")
    func speculativeMutationTextBuffered() async throws {
        let store = try orchestrationStore()
        try await seedOrchestration(store, tracks: [orchestrationTrack(serverID: orchestrationServerID, remoteID: "t0", title: "歌")])
        let bridge = OrchestrationBridge()
        bridge.mutationResult = .failed("替换失败（服务器不可用）")
        let collector = OrchestrationCollector()
        let probe = OrchestrationConfirmProbe(approve: true)
        let provider = OrchestrationProvider([
            orchestrationResponse(content: "已经替换好了", calls: [orchestrationCall(id: "m1", name: "queue_replace", arguments: ["trackIDs": .array([.string("\(orchestrationServerID.rawValue):t0")])])]),
            orchestrationResponse(content: "替换失败了，我再试一次别的方案。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "把队列替换为这首歌",
            provider: provider,
            model: "orch",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { await probe.decide($0) },
            emit: { await collector.append($0) }
        )
        // “已经替换好了”是 provisional 文本：queue_replace 失败后绝不能作为成功事实留在用户可见消息里。
        #expect(!(await collector.joinedText().contains("已经替换好了")))
    }

    @Test("M 模型自创确认不阻塞已授权的可逆 mutation")
    func modelInventedConfirmationDoesNotBlock() async throws {
        let store = try orchestrationStore()
        try await seedOrchestration(store, tracks: [orchestrationTrack(serverID: orchestrationServerID, remoteID: "t0", title: "歌")])
        let bridge = OrchestrationBridge()
        let collector = OrchestrationCollector()
        let probe = OrchestrationConfirmProbe(approve: true)
        // v2 架构：模型文字不制造确认状态由 Skill 接管保证——模型说“需要你确认”
        // 的同时提交候选（result_present_tracks），Skill 直接执行 queue_replace，
        // 不出现任何 confirmation。
        let provider = OrchestrationProvider([
            orchestrationResponse(content: "替换队列需要你确认哦。", calls: [orchestrationCall(id: "n1", name: "result_present_tracks", arguments: ["trackIDs": .array([.string("\(orchestrationServerID.rawValue):t0")])])]),
            orchestrationResponse(content: "已替换完成。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "替换队列为这首歌",
            provider: provider,
            model: "orch",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { await probe.decide($0) },
            emit: { await collector.append($0) }
        )
        #expect(bridge.replacedQueues.count == 1, "已授权的可逆操作不应被模型文字制造确认状态")
        #expect(await probe.count() == 0, "descriptor confirmationPolicy == none 时不得弹确认")
    }

    // MARK: - 场景：重复不可逆操作成功后不再次弹确认

    @Test("E2 删除成功后同一调用重复出现：只执行一次、不重复弹窗")
    func deleteSuccessDoesNotRepeatConfirmation() async throws {
        let store = try orchestrationStore()
        try await store.upsertPlaylist(
            Playlist(id: "pl-b", serverID: orchestrationServerID, name: "通勤", trackIDs: []),
            serverID: orchestrationServerID
        )
        let bridge = OrchestrationBridge(deleteSideEffect: { gid in
            try await store.deletePlaylist(gid)
        })
        let collector = OrchestrationCollector()
        let probe = OrchestrationConfirmProbe(approve: true)
        let provider = OrchestrationProvider([
            orchestrationResponse(calls: [orchestrationCall(id: "x1", name: "playlist_delete", arguments: ["playlistID": .string("\(orchestrationServerID.rawValue):pl-b")])]),
            orchestrationResponse(calls: [orchestrationCall(id: "x2", name: "playlist_delete", arguments: ["playlistID": .string("\(orchestrationServerID.rawValue):pl-b")])]),
            orchestrationResponse(content: "完成。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "删除歌单 通勤",
            provider: provider,
            model: "orch",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: orchestrationServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { await probe.decide($0) },
            emit: { await collector.append($0) }
        )
        let requests = provider.requests()
        let toolResults = requests.last?.messages.filter { $0.role == .tool }.map(\.content) ?? []
        let remainingPlaylist = try await store.getPlaylist(GlobalID(serverID: orchestrationServerID, remoteID: "pl-b"))
        #expect(remainingPlaylist == nil, "playlist remained locally")
        #expect(toolResults.contains { $0.contains("已删除歌单") }, "tool results: \(toolResults)")
        #expect(bridge.deletedPlaylists.count == 1, "成功后的重复删除不得再次执行")
        #expect(await probe.count() == 1, "成功后的重复删除不得再次弹确认")
    }
}
