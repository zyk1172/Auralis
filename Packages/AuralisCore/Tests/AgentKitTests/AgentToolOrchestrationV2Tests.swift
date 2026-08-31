import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - 第二轮 Review 修复 + Built-in Fixed Skills 回归测试
//
// P1-P3：queueReplace 授权过宽 / 空授权 fail-closed / unsupported 误判
// P4-P6：收敛计数 / noNewEvidence / malformed 连续
// P7-P10：tool_search 授权可见性 / 未授权不进 schema / 推荐索引不受影响
// N1-N9：QueueReplacePlaybackSkill
// O1-O6：PlaylistBuildSkill

// MARK: - Test doubles

private actor V2Collector {
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

/// 增强桥接：currentQueue 反映最近一次 replaceQueue 的结果；createPlaylist
/// 可通过回调把真实歌单写入 store（供验证工具读取）。
private final class V2Bridge: AgentBridge, @unchecked Sendable {
    let activeServerIDValue: ServerID?
    init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }
    var activeServerID: ServerID? { activeServerIDValue }
    var lyricsStateValue: AgentLyricsState = .unknown
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }
    func currentTrack() -> Track? { nil }

    // 测试桥接：单线程顺序执行，直接存取（@unchecked Sendable 类）。
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

private final class V2Provider: AIProvider, @unchecked Sendable {
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
        AIConnectionResult(latency: 0, model: "v2", message: "ready")
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

private func v2Store() throws -> LocalCatalogStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-v2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
}

private func v2Track(remoteID: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: "v2",
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: "歌 \(remoteID)",
        artistName: "周杰伦",
        albumTitle: "专辑 \(remoteID)",
        duration: 200
    )
}

private func seedV2Tracks(_ store: LocalCatalogStore, count: Int) async throws {
    let session = try await store.beginSync(serverID: "v2", mode: .full)
    try await store.stageTracks((0..<count).map { v2Track(remoteID: "t\($0)") }, session: session)
    try await store.completeSync(session, completedAt: .now)
}

private func v2Call(id: String, name: String, arguments: [String: AIJSONValue] = [:]) -> AIToolCall {
    AIToolCall(id: id, name: name, arguments: .object(arguments))
}

private func v2Response(content: String = "", calls: [AIToolCall] = []) -> AICompletionResponse {
    AICompletionResponse(model: "v2", content: content, toolCalls: calls.isEmpty ? nil : calls)
}

private let v2ServerID: ServerID = "v2"

// MARK: - P 系列

@Suite("Agent orchestration v2")
struct AgentToolOrchestrationV2Tests {

    // MARK: P1-1 queueReplace 自然语言授权过宽

    @Test("P2 换成深色等裸动词不得获得 queueReplace")
    func bareSwapVerbsDoNotAuthorizeQueueReplace() {
        for text in ["把主题换成深色", "把歌单封面换成另一张", "把输出设备换成耳机", "把名字换成 Auralis"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(!semantics.requestedOperations.contains(.queueReplace), "「\(text)」不得授权 queueReplace")
        }
        // positive
        for text in ["把当前队列换成这些歌", "用这些歌曲覆盖当前播放队列", "把这十首歌替换到队列播放", "替换队列", "换成当前队列"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(semantics.requestedOperations.contains(.queueReplace), "「\(text)」应授权 queueReplace")
        }
        let compound = AgentRequestSemantics.analyze("把这十首歌替换到队列播放")
        #expect(compound.requestedOperations.contains(.queueReplace))
        #expect(compound.requestedOperations.contains(.playbackPlay))
    }

    // MARK: P1-2 空 authorization 只保留语义元数据，不隐藏本地能力

    @Test("P1 allowedOperations == [] 不会隐藏相关 reversible schema")
    func emptyAuthorizationDoesNotHideReversibleSchemas() {
        for text in ["列出我的歌单", "当前播放状态", "队列里有什么", "有哪些服务器"] {
            let plan = AgentRequestPlan.build(userText: text, history: [])
            #expect(plan.allowedOperations.isEmpty, "「\(text)」没有可推导的 mutation 元数据")
            let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
            #expect(selected.contains { $0.permission == .readOnly }, "「\(text)」仍应暴露读取能力")
            #expect(!selected.contains { $0.name == "playlist_delete" || $0.name == "server_remove" }, "读取请求不应暴露无关 destructive schema")
        }
        // 授权非空时只暴露对应 mutation。
        let pausePlan = AgentRequestPlan.build(userText: "暂停播放", history: [])
        #expect(pausePlan.allowedOperations == [.playbackPause])
        let pauseSelected = ToolSelector.select(plan: pausePlan, all: AgentToolRegistry.all)
        let mutations = pauseSelected.filter { $0.permission != .readOnly }.map(\.name)
        #expect(mutations.contains("playback_pause"))
        #expect(!mutations.contains("playback_next"))
        #expect(!mutations.contains("playback_seek"))
        #expect(!mutations.contains("playback_set_shuffle"))
        #expect(!mutations.contains("playback_set_repeat"))
        #expect(!mutations.contains("queue_replace"))
        #expect(!mutations.contains("queue_clear"))
        #expect(!mutations.contains("playlist_delete"))
    }

    // MARK: P1-3 unsupported 误判

    @Test("P3 队列/歌单删除不得被 unsupported fail-fast")
    func queuePlaylistDeletionNotUnsupported() {
        let all = AgentToolRegistry.all
        for text in ["清空队列里的所有歌曲", "从播放队列移除所有歌曲", "删除这个歌单里的所有歌曲"] {
            let semantics = AgentRequestSemantics.analyze(text)
            let reason = AgentCapabilityCoverage.unsupportedReason(text: text, semantics: semantics, descriptors: all)
            #expect(reason == nil, "「\(text)」不应 fail-fast：\(reason ?? "nil")")
        }
        for text in ["删除服务器曲库里的所有歌曲文件", "删除服务器上的所有 FLAC 文件", "删除曲婉婷的所有歌曲"] {
            let semantics = AgentRequestSemantics.analyze(text)
            let reason = AgentCapabilityCoverage.unsupportedReason(text: text, semantics: semantics, descriptors: all)
            #expect(reason != nil, "「\(text)」应 fail-fast")
        }
    }

    // MARK: P2-1 totalToolCalls 精确计数

    @Test("P4 一次 ToolCall 只计一次 totalToolCalls")
    func totalToolCallsExactCounting() {
        var tracker = AgentConvergenceTracker()
        tracker.recordTotalCall()
        tracker.recordToolExecution(signature: "library_search|q=1")
        #expect(tracker.totalToolCalls == 1, "recordTotalCall + recordToolExecution 不得重复计数")

        var multi = AgentConvergenceTracker()
        for i in 0..<3 {
            multi.recordTotalCall()
        }
        #expect(multi.totalToolCalls == 3)
    }

    // MARK: P2-3 malformed 必须连续

    @Test("P5 malformed → valid → malformed 不触发连续限制")
    func malformedStreakRequiresConsecutive() {
        var tracker = AgentConvergenceTracker()
        let policy = AgentConvergencePolicy(maxConsecutiveMalformedCalls: 3)
        tracker.recordMalformedCall()
        tracker.recordValidCall()
        tracker.recordMalformedCall()
        #expect(tracker.stopReason(under: policy) == nil, "malformed-valid-malformed 不构成连续")
        tracker.recordMalformedCall()
        #expect(tracker.stopReason(under: policy) == nil, "连续 2 次尚未达阈值")
        tracker.recordMalformedCall()
        #expect(tracker.stopReason(under: policy) == .repeatedMalformedCall, "连续 3 次 malformed 才触发")
    }

    // MARK: P2-2 noNewEvidence

    @Test("P7 新 evidence 重置搜索 streak；不同工具互不污染")
    func searchStreakResetsOnNewEvidenceAndIsPerTool() {
        var tracker = AgentConvergenceTracker()
        let policy = AgentConvergencePolicy(maxSameToolNoNewEvidence: 3)
        tracker.recordSearchOutcome(toolName: "library_search", foundNewEvidence: false, policy: policy)
        tracker.recordSearchOutcome(toolName: "library_search", foundNewEvidence: false, policy: policy)
        tracker.recordSearchOutcome(toolName: "library_search", foundNewEvidence: true, policy: policy)
        #expect(!tracker.isSearchExhausted("library_search", under: policy), "新 evidence 应重置 streak")
        // 不同工具独立：web_search 的调用不污染 library_search 的 streak。
        tracker.recordSearchOutcome(toolName: "library_search", foundNewEvidence: false, policy: policy)
        tracker.recordSearchOutcome(toolName: "web_search", foundNewEvidence: false, policy: policy)
        tracker.recordSearchOutcome(toolName: "library_search", foundNewEvidence: false, policy: policy)
        #expect(!tracker.isSearchExhausted("library_search", under: policy), "library_search 连续 2 次尚未达阈值")
        tracker.recordSearchOutcome(toolName: "library_search", foundNewEvidence: false, policy: policy)
        #expect(tracker.isSearchExhausted("library_search", under: policy), "library_search 连续 3 次无新应收敛")
        #expect(!tracker.isSearchExhausted("web_search", under: policy), "web_search 只累计 1 次，不受 library_search 污染")
        // Search-only tasks stop with a diagnosable reason.
        #expect(tracker.stopReason(under: policy) == .noNewEvidence)
        // Exhausting one search path removes that path, but must not terminate
        // a task while another canonical path (for example music_appreciate)
        // remains available.
        #expect(tracker.stopReason(
            under: policy,
            tolerateSearchExhaustion: true
        ) == nil)
    }

    // MARK: P10 推荐索引长任务不受影响

    @Test("P10 Recommendation Index 保持长任务策略")
    func recommendationIndexKeepsLongRunningPolicy() {
        let policy = AgentTaskPolicyResolver.resolve(
            text: "开始并一次性完成推荐索引 V2，持续分批分类并写回，直到待分类为 0。",
            explicitIntent: .libraryManagement
        )
        #expect(policy.completion == .indexPendingCountIsZero)
        #expect(policy.convergence.maxModelRounds >= 10_000)
        #expect(policy.budget.maxModelRounds == 10_000)
    }
}
