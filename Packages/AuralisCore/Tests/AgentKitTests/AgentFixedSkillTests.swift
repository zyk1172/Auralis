import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Built-in Fixed Skills 与 loop 级收敛测试
//
// P6/P8/P9：loop 级搜索收敛 / tool_search 授权可见性
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
}

/// 增强桥接：currentQueue 反映最近一次 replaceQueue 的结果；createPlaylist 可回调写 store。
private final class SkillBridge: AgentBridge, @unchecked Sendable {
    let activeServerIDValue: ServerID?
    init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }
    var activeServerID: ServerID? { activeServerIDValue }
    var lyricsStateValue: AgentLyricsState = .unknown
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }
    func currentTrack() -> Track? { nil }

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
    var onPlaylistCreated: (@Sendable (String, GlobalID) -> Void)?

    func playTrack(globalID: GlobalID) async -> Bool { playedTracks.append(globalID); return playResult }
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
        onPlaylistCreated?(name, gid)
        return gid
    }
    func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { mutationResult }
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult {
        addedToPlaylist.append((playlistGID, trackGIDs))
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

    @Test("P6 同一搜索反复无新结果 → 收敛停止")
    func sameSearchNoEvidenceConverges() async throws {
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
        #expect(provider.requests().count <= 4, "连续无新结果后应停止")
        let stopped = await collector.containsError("没有获得新的结果")
        #expect(stopped)
    }

    @Test("P8/P9 tool_search 结果带 authorized=false，且未授权 mutation 不进后续 schema")
    func toolSearchShowsAuthorizationAndFiltersSchema() async throws {
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
        var foundAuthorizedFlag = false
        for request in requests.dropFirst() {
            for message in request.transcript.messages where message.role == .tool {
                if message.content.contains("queue_replace"), message.content.contains("未授权") {
                    foundAuthorizedFlag = true
                }
            }
        }
        #expect(foundAuthorizedFlag, "模型看到的 tool_search 结果应包含 authorized=false")
        for request in requests.dropFirst() {
            let names = (request.tools ?? []).map(\.name)
            #expect(!names.contains("queue_replace"), "queue_replace 未授权，不得进入后续 schema")
        }
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

    @Test("O2/O3 create 一次、add 一次、verify → completed")
    func playlistBuildCreateAddVerifyOnce() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        bridge.onPlaylistCreated = { name, gid in
            Task {
                try? await store.upsertPlaylist(
                    Playlist(
                        id: PlaylistID(rawValue: gid.remoteID ?? UUID().uuidString),
                        serverID: "v2",
                        name: name,
                        trackIDs: []
                    ),
                    serverID: "v2"
                )
            }
        }
        let ids = (0..<3).map { "\(skillServerID.rawValue):t\($0)" }
        let provider = SkillProvider([
            skillResponse(calls: [skillCall(id: "c1", name: "result_present_tracks", arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))])]),
        ])
        _ = await Self.runPlaylistSkill(
            userText: "创建一个通勤歌单，加入这 3 首歌",
            store: store,
            bridge: bridge,
            provider: provider
        )
        #expect(bridge.createdPlaylistNames.count == 1, "playlist_create 必须恰一次")
        #expect(bridge.addedToPlaylist.count == 1, "playlist_add_songs 必须恰一次")
        #expect(bridge.addedToPlaylist.first?.1.count == 3)
        #expect(bridge.deletedPlaylists.isEmpty, "Skill 不触碰 playlist_delete")
    }

    @Test("O4/O5 create 成功 + add 失败 → 不重新 create、不删歌单、partial 报告")
    func createSuccessAddFailurePreservesPartial() async throws {
        let store = try skillStore()
        try await seedSkillTracks(store, count: 3)
        let bridge = SkillBridge()
        bridge.playlistAddResult = .failed("加歌失败")
        bridge.onPlaylistCreated = { name, gid in
            Task {
                try? await store.upsertPlaylist(
                    Playlist(
                        id: PlaylistID(rawValue: gid.remoteID ?? UUID().uuidString),
                        serverID: "v2",
                        name: name,
                        trackIDs: []
                    ),
                    serverID: "v2"
                )
            }
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

    @Test("O6 resume 已有 createdPlaylistID → 不重新 create")
    func resumeSkipsCreate() throws {
        let checkpoint = PlaylistBuildSkillCheckpointForTest(
            playlistID: "v2:existing-playlist",
            playlistName: "通勤",
            targetCount: nil,
            createdPlaylist: true
        )
        let data = try JSONEncoder().encode(checkpoint)
        let json = String(data: data, encoding: .utf8)
        let runtime = BuiltInPlaylistBuildSkill().makeRuntime(checkpointJSON: json)
        let step = runtime.nextStep()
        guard case let .executeTool(name, _) = step else {
            Issue.record("resume 后 nextStep 应为 executeTool，实际 \(step)")
            return
        }
        #expect(name == "playlist_add_songs")
    }
}

private struct PlaylistBuildSkillCheckpointForTest: Codable {
    var playlistID: String?
    var playlistName: String
    var targetCount: Int?
    var createdPlaylist: Bool
}
