import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Built-in Fixed Skills 与 loop 级收敛测试
//
// P6/P8/P9：loop 级搜索诊断 / tool_search 授权可见性
// N1-N9：QueueReplacePlaybackSkill
// O1-O6：PlaylistBuildSkill

private actor SkillCollector {
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

    func joinedErrors() -> String {
        messages.flatMap { message in
            message.messages.compactMap { item -> String? in
                if case let .error(value) = item { return value }
                return nil
            }
        }.joined(separator: "\n")
    }
}

/// 增强桥接：currentQueue 反映最近一次 replaceQueue 的结果；createPlaylist 可回调写 store。
private final class SkillBridge: AgentBridge, @unchecked Sendable {
    let activeServerIDValue: ServerID?
    init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }
    var activeServerID: ServerID? { activeServerIDValue }
    var lyricsStateValue: AgentLyricsState = .unknown
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }

    /// 最近一次成功播放的曲目（供 playback_get_state 状态验证）。
    private var lastPlayed: Track?
    func currentTrack() -> Track? { lastPlayed }

    private var queueTracks: [Track] = []
    func currentQueue() -> [Track] { queueTracks }

    private(set) var playedTracks: [GlobalID] = []
    private(set) var replacedQueues: [[GlobalID]] = []
    private(set) var clearedQueueCount = 0
    private(set) var appendedQueues: [GlobalID] = []
    private(set) var createdPlaylistNames: [String] = []
    private(set) var addedToPlaylist: [(GlobalID, [GlobalID])] = []
    private(set) var deletedPlaylists: [GlobalID] = []

    var playResult: Bool = true
    var mutationResult: AgentMutationResult = .confirmed("ok")
    var playlistAddResult: AgentMutationResult = .confirmed("ok")
    var onPlaylistCreated: (@Sendable (String, GlobalID) async throws -> Void)?
    /// 加歌成功后回调（测试用它把真实歌单内容写回 store，驱动强验证路径）。
    var onTracksAdded: (@Sendable (GlobalID, [GlobalID]) async throws -> Void)?

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
    func playServerTrack(globalID: GlobalID) async -> Bool { playResult }
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
        queueTracks = globalIDs.enumerated().map { index, gid in
            Track(
                id: TrackID(rawValue: gid.remoteID),
                serverID: gid.serverID,
                albumID: AlbumID(rawValue: "\(gid.remoteID)-album"),
                artistID: ArtistID(rawValue: "\(gid.remoteID)-artist"),
                title: "歌\(index)",
                artistName: "周杰伦",
                albumTitle: "专辑",
                duration: 200
            )
        }
        return mutationResult
    }
    func removeFromQueue(at index: Int) async -> AgentMutationResult { mutationResult }
    func reorderQueue(from: Int, to: Int) async -> AgentMutationResult { mutationResult }
    func clearQueue() async -> AgentMutationResult { clearedQueueCount += 1; return mutationResult }
    func shuffleRemaining() async -> AgentMutationResult { mutationResult }
    func saveQueueAsPlaylist(name: String) async -> AgentMutationResult { mutationResult }

    func createPlaylist(name: String) async -> GlobalID? {
        createdPlaylistNames.append(name)
        let gid = GlobalID(serverID: "v2", remoteID: UUID().uuidString)
        try? await onPlaylistCreated?(name, gid)
        return gid
    }
    func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { mutationResult }
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult {
        addedToPlaylist.append((playlistGID, trackGIDs))
        try? await onTracksAdded?(playlistGID, trackGIDs)
        return playlistAddResult
    }
    func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult { mutationResult }
    func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult { mutationResult }
    func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult { mutationResult }
    func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult { mutationResult }
    func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult {
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

private final class SkillProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [AICompletionResponse]
    private var recordedRequests: [AICompletionRequest] = []

    let capabilities: ModelCapabilities
    var supportsToolCalling: Bool { capabilities.supportsToolCalling }

    init(_ responses: [AICompletionResponse]) {
        self.responses = responses
        self.capabilities = ModelCapabilities(
            maxContextTokens: 32_000,
            maxOutputTokens: 4_096,
            supportsToolCalling: true,
            supportsParallelTools: true,
            supportsToolChoice: true,
            supportsStrictSchema: true,
            supportsStreaming: true,
            toolMode: .openAIChat
        )
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "skill", message: "ready")
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

private func skillStore() throws -> LocalCatalogStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-skill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
}

private func seedSkillTracks(_ store: LocalCatalogStore, count: Int) async throws {
    let session = try await store.beginSync(serverID: "v2", mode: .full)
    try await store.stageTracks((0..<count).map { index in
        Track(
            id: TrackID(rawValue: "t\(index)"),
            serverID: "v2",
            albumID: AlbumID(rawValue: "t\(index)-album"),
            artistID: ArtistID(rawValue: "t\(index)-artist"),
            title: "歌 \(index)",
            artistName: "周杰伦",
            albumTitle: "专辑 \(index)",
            duration: 200
        )
    }, session: session)
    try await store.completeSync(session, completedAt: .now)
}

private func skillCall(id: String, name: String, arguments: [String: AIJSONValue] = [:]) -> AIToolCall {
    AIToolCall(id: id, name: name, arguments: .object(arguments))
}

private func skillResponse(content: String = "", calls: [AIToolCall] = []) -> AICompletionResponse {
    AICompletionResponse(model: "skill", content: content, toolCalls: calls.isEmpty ? nil : calls)
}

private let skillServerID: ServerID = "v2"

// MARK: - P6/P8/P9 loop 级

@Suite("Agent orchestration v2 loop")
struct AgentSkillLoopTests {

    @Test("P6 同一搜索反复无新结果 → 仅累计诊断，不提前停止")
    func sameSearchNoEvidenceRemainsModelControlled() async throws {
        let store = try skillStore()
        let collector = SkillCollector()
        let provider = SkillProvider(Array(repeating: skillResponse(
            calls: [skillCall(id: "s1", name: "library_search", arguments: ["query": .string("完全不存在xyz")])]
        ), count: 4))
        let runID = UUID()
        await ConversationEngine().run(
            userText: "帮我找一首完全不存在的歌",
            provider: provider,
            model: "skill",
            bridge: SkillBridge(),
            catalog: store,
            context: ToolLoop.Context(serverID: skillServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(provider.requests().count >= 4, "连续无新结果不应触发 convergence 提前停止")
        #expect(await collector.containsError("没有获得新的结果") == false)
    }

    @Test("P8/P9 tool_search 结果不伪造 unauthorized 标记，普通 mutation 可进入后续 schema")
    func toolSearchKeepsReversibleMutationAvailable() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 1)
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "t1", name: "tool_search", arguments: ["query": .string("替换队列")])]),
            skillResponse(calls: [skillCall(id: "t2", name: "playback_play_song", arguments: ["trackID": .string("\(skillServerID.rawValue):t0")])]),
            skillResponse(content: "已播放。"),
        ])
        let collector = SkillCollector()
        let runID = UUID()
        await ConversationEngine().run(
            userText: "播放一首歌",
            provider: provider,
            model: "skill",
            bridge: SkillBridge(),
            catalog: store,
            context: ToolLoop.Context(serverID: skillServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        let requests = provider.requests()
        var foundUnauthorizedText = false
        for request in requests.dropFirst() {
            for message in request.transcript.messages where message.role == .tool {
                if message.content.contains("queue_replace"), message.content.contains("未授权") {
                    foundUnauthorizedText = true
                }
            }
        }
        #expect(!foundUnauthorizedText, "模型看到的 tool_search 结果不应把普通 mutation 标为未授权")
        var foundQueueReplace = false
        for request in requests.dropFirst() {
            let names = (request.tools ?? []).map(\.name)
            if names.contains("queue_replace") { foundQueueReplace = true }
        }
        #expect(foundQueueReplace, "普通 reversible queue_replace 应可进入后续 schema")
    }
}

// MARK: - N 系列：QueueReplacePlaybackSkill

@Suite("QueueReplacePlaybackSkill")
struct QueueReplacePlaybackSkillTests {

    private static func runQueueSkill(
        userText: String,
        store: LocalCatalogStore,
        bridge: SkillBridge,
        provider: SkillProvider
    ) async -> SkillCollector {
        let collector = SkillCollector()
        let runID = UUID()
        await ConversationEngine().run(
            userText: userText,
            provider: provider,
            model: "skill",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: skillServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        return collector
    }

    @Test("N1/N2/N5/N6 替换队列播放 → Skill 激活、queue_replace 恰一次、无 clear/append fallback")
    func queueReplacePlaybackSkillRunsExactlyOnce() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 10)
        let bridge = SkillBridge()
        let ids = (0..<10).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "library_search", arguments: ["query": .string("周杰伦")])]),
            skillResponse(calls: [skillCall(id: "c2", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        _ = await Self.runQueueSkill(
            userText: "列出十首周杰伦的歌曲，替换到队列播放",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.replacedQueues.count == 1, "queue_replace 必须恰执行一次")
        #expect(bridge.replacedQueues.first?.count == 10)
        #expect(bridge.clearedQueueCount == 0, "绝不 fallback 到 queue_clear")
        #expect(bridge.appendedQueues.isEmpty, "绝不 fallback 到 queue_append")
        #expect(bridge.playedTracks.count == 1, "授权 playbackPlay 时应开始播放")
        #expect(bridge.playedTracks.contains(GlobalID(serverID: skillServerID, remoteID: "t0")))
    }

    @Test("N3 queue_replace 失败 → 不执行播放")
    func queueReplaceFailureSkipsPlayback() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        bridge.mutationResult = .failed("服务器不可用")
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        let collector = await Self.runQueueSkill(
            userText: "用这些歌替换当前队列并播放",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.playedTracks.isEmpty, "queue_replace 失败不得执行播放")
        #expect(bridge.replacedQueues.count <= 1)
        let failed = await collector.containsError("队列替换失败")
        #expect(failed)
    }

    @Test("N4 queue_replace 成功 + playback 失败 → 不重复 replace")
    func playbackFailureDoesNotRepeatReplace() async throws {
        let semantics = AgentRequestSemantics.analyze("用这些歌替换当前队列并播放")
        #expect(semantics.requestedOperations.contains(.playbackPlay), "语义应授权播放")
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        bridge.playResult = false
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        let collector = await Self.runQueueSkill(
            userText: "用这些歌替换当前队列并播放",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.replacedQueues.count == 1, "playback 失败不得再次 replace")
        #expect(bridge.clearedQueueCount == 0)
        let partial = await collector.containsError("队列已替换成功，但开始播放失败")
        #expect(partial)
    }

    @Test("N7 只授权 queueReplace → 不执行播放")
    func queueReplaceOnlyDoesNotPlay() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        _ = await Self.runQueueSkill(
            userText: "用这些歌替换当前队列",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.replacedQueues.count == 1)
        #expect(bridge.playedTracks.isEmpty, "未授权 playbackPlay 时 Skill 不得自行播放")
    }

    @Test("N9 模型正文说播放不构成授权")
    func modelTextDoesNotExpandAuthorization() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(content: "替换后最好自动播放", calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        _ = await Self.runQueueSkill(
            userText: "用这些歌替换当前队列",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.playedTracks.isEmpty, "模型正文不能扩展 mutation 授权")
    }

    @Test("N8 只读请求不激活 mutation Skill")
    func readOnlyRequestDoesNotActivateSkill() {
        let semantics = AgentRequestSemantics.analyze("列出我的歌单")
        let runtime = BuiltInStatefulSkillRegistry.activate(semantics: semantics, userText: "列出我的歌单", initialTaskState: nil)
        #expect(runtime == nil)
    }

    @Test("N10 用户要 10 首、模型交 58 首 → 最终只操作 10 首（targetCount 硬约束）")
    func targetCountTruncatesOverSubmittedCandidates() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 58)
        let bridge = SkillBridge()
        let ids = (0..<58).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        _ = await Self.runQueueSkill(
            userText: "我要十首周杰伦的歌曲，替换到队列播放",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.replacedQueues.count == 1)
        #expect(bridge.replacedQueues.first?.count == 10, "模型提交 58 首时必须硬约束到 10 首，实际：\(bridge.replacedQueues.first?.count ?? -1)")
        #expect(bridge.clearedQueueCount == 0)
        #expect(bridge.appendedQueues.isEmpty)
    }

    @Test("N11 固定 Skill 激活后模型首轮 schema 中 mutation 数量 == 0")
    func skillActivationHidesAllMutationsFromModelSchema() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "library_search", arguments: ["query": .string("周杰伦")])]),
            skillResponse(calls: [skillCall(id: "c2", name: "result_present_tracks", arguments: ["trackIDs": .array([.string("\(skillServerID.rawValue):t0")])])]),
        ])
        _ = await Self.runQueueSkill(
            userText: "替换队列并播放周杰伦",
            store: store,
            bridge: SkillBridge(),
            provider: provider
        )
        let requests = provider.requests()
        #expect(!requests.isEmpty)
        let firstTools = requests.first?.tools ?? []
        #expect(!firstTools.isEmpty, "首轮应暴露只读工具")
        let mutations = firstTools.map(\.name).filter { name in
            guard let descriptor = AgentToolRegistry.descriptor(for: name) else { return false }
            return descriptor.permission != .readOnly
        }
        #expect(mutations.isEmpty, "Skill 激活后模型 schema 不得出现任何 mutation（playback_play_artist/queue_clear 等），实际：\(mutations)")
        // 只读工具仍然可用（search/select 必须可见）。
        let names = firstTools.map(\.name)
        #expect(names.contains("library_search"))
        #expect(names.contains("result_present_tracks"))
    }

    @Test("N12 模型绕过 schema 硬调同族 mutation（playback_play_artist）→ 被拒绝，不提前播放")
    func modelHardCallingMutationIsRejected() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        let provider = SkillProvider([
            // 模型第一轮直接硬调 playback_play_artist（不在 schema 里）。
            skillResponse(calls: [skillCall(id: "m1", name: "playback_play_artist", arguments: ["artistID": .string("\(skillServerID.rawValue):t0-artist")])]),
            // 被拒后模型回到候选收集，正确提交候选。
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array([.string("\(skillServerID.rawValue):t0")])])]),
        ])
        let collector = await Self.runQueueSkill(
            userText: "替换队列并播放周杰伦",
            store: store,
            bridge: bridge,
            provider: provider
        )
        // 模型的 playback_play_artist 必须被拦截：Skill 只允许自己的 forced call 执行 mutation。
        // Skill 主路径正常完成（播放 t0），但模型硬调的 artist 播放绝不可达。
        #expect(bridge.playedTracks == [GlobalID(serverID: skillServerID, remoteID: "t0")],
                "只允许 Skill 主路径播放，模型硬调的写操作不得执行，实际：\(bridge.playedTracks)")
        #expect(bridge.replacedQueues.count == 1, "Skill 主路径正常完成替换")
        #expect(bridge.clearedQueueCount == 0)
        let completed = await collector.containsText("队列已替换并开始播放")
        #expect(completed)
    }

    @Test("N13 伪造 skill- 前缀 id 的模型 mutation 调用 → 仍被拒绝（来源判定不信任 tool_call.id）")
    func forgedSkillPrefixIdStillRejected() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        let provider = SkillProvider([
            // 模型伪造 id = "skill-forged"，冒充 Skill forced call。
            skillResponse(calls: [skillCall(id: "skill-forged", name: "playback_play_artist", arguments: ["artistID": .string("\(skillServerID.rawValue):t0-artist")])]),
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array([.string("\(skillServerID.rawValue):t0")])])]),
        ])
        let collector = await Self.runQueueSkill(
            userText: "替换队列并播放周杰伦",
            store: store,
            bridge: bridge,
            provider: provider
        )
        // 来源判定基于结构化 origin（.providerNative），不是 id 前缀：
        // 即使 id 是 skill-forged，模型调用仍然被拒绝，Skill 主路径正常完成。
        #expect(bridge.playedTracks == [GlobalID(serverID: skillServerID, remoteID: "t0")],
                "伪造 id 不得绕过 mutation 隔离，实际：\(bridge.playedTracks)")
        #expect(bridge.replacedQueues.count == 1)
        #expect(bridge.clearedQueueCount == 0)
        let completed = await collector.containsText("队列已替换并开始播放")
        #expect(completed)
    }

    @Test("N14 候选不足（要 10 首只交 3 首）→ 不发生任何队列 mutation")
    func insufficientCandidatesBlockQueueMutation() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array([
                .string("\(skillServerID.rawValue):t0"), .string("\(skillServerID.rawValue):t1"), .string("\(skillServerID.rawValue):t2"),
            ])])]),
        ])
        let collector = await Self.runQueueSkill(
            userText: "我要十首周杰伦的歌曲，替换到队列播放",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.replacedQueues.isEmpty, "候选不足时不得先修改真实队列")
        #expect(bridge.playedTracks.isEmpty)
        let insufficient = await collector.containsError("候选不足")
        #expect(insufficient)
    }
}

// MARK: - O 系列：PlaylistBuildSkill

@Suite("PlaylistBuildSkill")
struct PlaylistBuildSkillTests {

    private static func runPlaylistSkill(
        userText: String,
        store: LocalCatalogStore,
        bridge: SkillBridge,
        provider: SkillProvider
    ) async -> SkillCollector {
        let collector = SkillCollector()
        let runID = UUID()
        await ConversationEngine().run(
            userText: userText,
            provider: provider,
            model: "skill",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: skillServerID),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        return collector
    }

    @Test("O1 创建歌单加歌 → Skill 路由；仅 create 不激活")
    func playlistBuildRouting() {
        let semantics = AgentRequestSemantics.analyze("给我找 30 首适合通勤的歌，创建一个通勤歌单")
        #expect(semantics.requestedOperations.contains(.playlistCreate))
        #expect(semantics.requestedOperations.contains(.playlistAdd))
        let runtime = BuiltInStatefulSkillRegistry.activate(semantics: semantics, userText: "给我找 30 首适合通勤的歌，创建一个通勤歌单", initialTaskState: nil)
        #expect(runtime?.skillID == PlaylistBuildSkill.id)
        let bare = AgentRequestSemantics.analyze("创建一个空歌单 Test")
        #expect(!bare.requestedOperations.contains(.playlistAdd))
        let bareRuntime = BuiltInStatefulSkillRegistry.activate(semantics: bare, userText: "创建一个空歌单 Test", initialTaskState: nil)
        #expect(bareRuntime == nil)
    }

    @Test("O2/O3 create 一次、add 一次、verify → completed；歌单名来自用户请求")
    func playlistBuildCreateAddVerifyOnce() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        // 记录创建的歌单名（P1-1 验证：生产路径 playlistName 必须是“通勤”而不是默认值）。
        let playlistNameBox = NameBox()
        bridge.onPlaylistCreated = { name, gid in
            playlistNameBox.set(name)
            try await store.upsertPlaylist(
                Playlist(
                    id: PlaylistID(rawValue: gid.remoteID),
                    serverID: "v2",
                    name: name,
                    trackIDs: []
                ),
                serverID: "v2"
            )
        }
        // 加歌成功后把真实内容写回 store，驱动 library_get_playlist 强验证路径。
        bridge.onTracksAdded = { playlistGID, trackGIDs in
            try await store.upsertPlaylist(
                Playlist(
                    id: PlaylistID(rawValue: playlistGID.remoteID),
                    serverID: "v2",
                    name: playlistNameBox.get(),
                    trackIDs: trackGIDs.map { TrackID(rawValue: $0.remoteID) }
                ),
                serverID: "v2"
            )
        }
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        let collector = await Self.runPlaylistSkill(
            userText: "创建一个通勤歌单，加入这 3 首歌",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.createdPlaylistNames.count == 1, "playlist_create 必须恰一次")
        #expect(bridge.createdPlaylistNames.first == "通勤", "生产路径歌单名必须来自用户请求，实际：\(String(describing: bridge.createdPlaylistNames.first))")
        let errors = await collector.joinedErrors()
        if !errors.isEmpty { Issue.record("\(errors)") }
        #expect(errors.isEmpty)
        #expect(bridge.addedToPlaylist.count == 1, "playlist_add_songs 必须恰一次")
        #expect(bridge.addedToPlaylist.first?.1.count == 3)
        #expect(bridge.deletedPlaylists.isEmpty, "Skill 不触碰 playlist_delete")
        let completed = await collector.containsText("歌单已创建并加入歌曲")
        #expect(completed, "强验证通过后应 completed")
    }

    @Test("O4/O5 create 成功 + add 失败 → 不重新 create、不删歌单、partial 报告")
    func createSuccessAddFailurePreservesPartial() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        bridge.playlistAddResult = .failed("加歌失败")
        bridge.onPlaylistCreated = { name, gid in
            try await store.upsertPlaylist(
                Playlist(
                    id: PlaylistID(rawValue: gid.remoteID),
                    serverID: "v2",
                    name: name,
                    trackIDs: []
                ),
                serverID: "v2"
            )
        }
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        let collector = await Self.runPlaylistSkill(
            userText: "创建一个通勤歌单，加入这 3 首歌",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.createdPlaylistNames.count == 1, "add 失败不得重新 create")
        #expect(bridge.addedToPlaylist.count == 1)
        #expect(bridge.deletedPlaylists.isEmpty, "没有 playlistDelete 授权，绝不自动删除歌单")
        let partial = await collector.containsError("歌单已创建，但歌曲加入失败")
        #expect(partial)
    }

    @Test("O6 resume 已有 createdPlaylistID + 已选候选 → 从 addingTracks 继续且 trackIDs 非空")
    func resumeSkipsCreate() throws {
        let checkpoint = PlaylistBuildSkillCheckpointForTest(
            playlistID: "v2:existing-playlist",
            playlistName: "通勤",
            targetCount: nil,
            createdPlaylist: true,
            selectedTrackIDs: ["v2:t0", "v2:t1", "v2:t2"]
        )
        let data = try JSONEncoder().encode(checkpoint)
        let json = String(data: data, encoding: .utf8)
        let runtime = BuiltInPlaylistBuildSkill().makeRuntime(checkpointJSON: json)
        let step = runtime.nextStep()
        guard case let .executeTool(name, arguments) = step else {
            Issue.record("resume 后 nextStep 应为 executeTool，实际 \(step)")
            return
        }
        #expect(name == "playlist_add_songs")
        // P1-2：resume 的 trackIDs 必须非空且等于 checkpoint 保存的原候选，
        // 不能发出空数组的 playlist_add_songs。
        if case let .array(ids) = arguments["trackIDs"] {
            let strings = ids.compactMap { value -> String? in
                if case let .string(s) = value { return s }
                return nil
            }
            #expect(strings == ["v2:t0", "v2:t1", "v2:t2"], "resume 必须携带原候选，实际：\(strings)")
        } else {
            Issue.record("playlist_add_songs 缺少 trackIDs 参数")
        }
    }

    @Test("O7 旧 checkpoint（无候选）恢复 → 回候选收集，不发出空 add、不重新 create")
    func resumeWithoutCandidatesCollectsFirst() throws {
        let checkpoint = PlaylistBuildSkillCheckpointForTest(
            playlistID: "v2:existing-playlist",
            playlistName: "通勤",
            targetCount: nil,
            createdPlaylist: true,
            selectedTrackIDs: nil
        )
        let data = try JSONEncoder().encode(checkpoint)
        let json = String(data: data, encoding: .utf8)
        let runtime = BuiltInPlaylistBuildSkill().makeRuntime(checkpointJSON: json)
        let step = runtime.nextStep()
        // 有歌单但无候选 → 回到候选收集（freeModelTurn），绝不 create / 空 add。
        #expect(step == .freeModelTurn)
    }

    @Test("O8 候选不足（要 10 首只交 3 首）→ 不创建歌单、不发生任何 mutation")
    func insufficientCandidatesBlockPlaylistMutation() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array([
                .string("\(skillServerID.rawValue):t0"), .string("\(skillServerID.rawValue):t1"), .string("\(skillServerID.rawValue):t2"),
            ])])]),
        ])
        let collector = await Self.runPlaylistSkill(
            userText: "创建一个叫通勤的歌单并加入 10 首歌",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.createdPlaylistNames.isEmpty, "候选不足时不得先创建歌单")
        #expect(bridge.addedToPlaylist.isEmpty)
        let insufficient = await collector.containsError("候选不足")
        #expect(insufficient)
    }

    @Test("O9 空歌单（add 后读回 tracks 为空）→ 验证失败，不 completed")
    func emptyPlaylistVerificationFails() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        // 创建歌单但 add 后不写回 store（模拟歌单实际为空）：library_get_playlist
        // 返回空 tracks，空歌单本身就是验证结果，必须失败而不能跳过验证。
        bridge.onPlaylistCreated = { name, gid in
            try await store.upsertPlaylist(
                Playlist(
                    id: PlaylistID(rawValue: gid.remoteID),
                    serverID: "v2",
                    name: name,
                    trackIDs: []
                ),
                serverID: "v2"
            )
        }
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        let collector = await Self.runPlaylistSkill(
            userText: "创建一个通勤歌单，加入这 3 首歌",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.createdPlaylistNames.count == 1)
        #expect(bridge.addedToPlaylist.count == 1)
        let failed = await collector.containsError("歌单验证失败")
        #expect(failed, "空歌单不得绕过验证直接 completed")
    }

    @Test("O10 playlistName 编译进 ActivationContext（多种自然说法）")
    func playlistNameCompiledFromUserText() {
        for (text, expected) in [
            ("创建一个通勤歌单", "通勤"),
            ("新建一个通勤歌单", "通勤"),
            ("建个通勤歌单", "通勤"),
            ("创建一个歌单叫通勤", "通勤"),
            ("创建一个叫通勤的歌单", "通勤"),
            ("创建歌单「通勤」", "通勤"),
            ("歌单叫通勤", "通勤"),
        ] {
            #expect(AgentSkillPlaylistNameParser.infer(from: text) == expected, "「\(text)」应解析出「\(expected)」")
        }
        // 生产路径：ActivationContext 携带编译值，Runtime 直接消费。
        let semantics = AgentRequestSemantics.analyze("新建一个通勤歌单，加入这 3 首歌")
        let plan = AgentRequestPlan.build(userText: "新建一个通勤歌单，加入这 3 首歌", history: [])
        let runtime = BuiltInPlaylistBuildSkill().makeRuntime(checkpointJSON: nil, activation: BuiltInSkillActivationContext(
            currentUserText: "新建一个通勤歌单，加入这 3 首歌",
            semantics: semantics,
            allowedOperations: plan.authorization.allowedOperations,
            inferredTargetCount: 3,
            compiledPlaylistName: AgentSkillPlaylistNameParser.infer(from: "新建一个通勤歌单，加入这 3 首歌")
        ))
        #expect(runtime.facts["playlist.skill.playlistName"] == "通勤", "生产路径歌单名来自编译值，实际：\(runtime.facts["playlist.skill.playlistName"] ?? "nil")")
    }
}

private final class NameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String = ""
    func set(_ newValue: String) { lock.lock(); storedValue = newValue; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return storedValue }
}

private struct PlaylistBuildSkillCheckpointForTest: Codable {
    var playlistID: String?
    var playlistName: String
    var targetCount: Int?
    var createdPlaylist: Bool
    var selectedTrackIDs: [String]?
}

// MARK: - Custom Tool schema exposure（P1-4 回归）

@Suite("Custom Tool schema exposure")
struct CustomToolExposureTests {

    @Test("P11 mutation Custom Tool（derivedOperations ⊆ allowed）能进 production schema")
    func customToolMutationExposedWhenAuthorized() {
        let custom = ToolDescriptor(
            name: "custom_queue_replace", group: .playback, permission: .reversible,
            summary: "自建：替换播放队列",
            tags: ["queue", "replace", "自建"],
            customToolID: UUID(),
            customToolVersion: 1,
            derivedAuthorizationOperations: [.queueReplace]
        )
        let plan = AgentRequestPlan.build(userText: "替换当前队列", history: [])
        #expect(plan.allowedOperations.contains(.queueReplace))
        let selected = ToolSelector.select(plan: plan, all: [custom])
        #expect(selected.contains { $0.name == "custom_queue_replace" },
                "derivedAuthorizationOperations ⊆ allowed 的 mutation Custom Tool 必须可进 schema")
    }

    @Test("P12 未授权的 mutation Custom Tool 不进 schema；只读 Custom Tool 不受授权限制（domain 语义内）")
    func customToolExposureFailClosed() {
        let unauthorized = ToolDescriptor(
            name: "custom_delete_playlist", group: .playlist, permission: .destructive,
            summary: "自建：删除歌单",
            tags: ["playlist", "delete"],
            customToolID: UUID(),
            customToolVersion: 1,
            derivedAuthorizationOperations: [.playlistDelete]
        )
        // 只读 Custom Tool 仍走 domain 语义过滤（queue 域内可见），但不受授权限制。
        let readOnly = ToolDescriptor(
            name: "custom_queue_search", group: .catalog, permission: .readOnly,
            summary: "自建：队列搜索",
            tags: ["queue", "search"]
        )
        let plan = AgentRequestPlan.build(userText: "替换当前队列", history: [])
        let selected = ToolSelector.select(plan: plan, all: [unauthorized, readOnly])
        #expect(!selected.contains { $0.name == "custom_delete_playlist" }, "未授权 mutation Custom Tool 不得进 schema")
        #expect(selected.contains { $0.name == "custom_queue_search" }, "只读 Custom Tool 在 domain 语义内始终可见")
    }

    @Test("P13 空授权（[]）下 mutation Custom Tool 也不进 schema（fail-closed 一致）")
    func customToolExposureEmptyAuthorization() {
        let custom = ToolDescriptor(
            name: "custom_queue_replace", group: .playback, permission: .reversible,
            summary: "自建：替换播放队列",
            tags: ["queue", "replace"],
            customToolID: UUID(),
            customToolVersion: 1,
            derivedAuthorizationOperations: [.queueReplace]
        )
        let plan = AgentRequestPlan.build(userText: "列出我的歌单", history: [])
        #expect(plan.allowedOperations.isEmpty)
        let selected = ToolSelector.select(plan: plan, all: [custom])
        #expect(!selected.contains { $0.name == "custom_queue_replace" }, "空授权下 mutation Custom Tool 不得进 schema")
    }
}
