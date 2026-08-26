import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - 工具参数审计回归测试
//
// 覆盖本轮审计发现的整数参数解析失配：
// - rating_set.value（integer schema）通过原生 number 传值时，必须走 setRating
//   而不是因 "4.0" 字符串投影失败误走 clearRating（P1）。

@Suite("Agent tool parameter audit")
struct AgentToolParameterAuditTests {

    private actor RatingCollector {
        private var messages: [AgentChatMessage] = []
        func append(_ message: AgentChatMessage) { messages.append(message) }
        func all() -> [AgentChatMessage] { messages }
    }

    private final class RatingBridge: AgentBridge, @unchecked Sendable {
        let activeServerIDValue: ServerID?
        init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }
        var activeServerID: ServerID? { activeServerIDValue }
        var lyricsStateValue: AgentLyricsState = .unknown
        func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }
        func currentTrack() -> Track? { nil }
        func currentQueue() -> [Track] { [] }

        private(set) var setRatingCalls: [(GlobalID, Int)] = []
        private(set) var clearRatingCalls: [GlobalID] = []
        var mutationResult: AgentMutationResult = .confirmed("ok")

        func setRating(globalID: GlobalID, rating: Int) async -> AgentMutationResult {
            setRatingCalls.append((globalID, rating))
            return mutationResult
        }
        func clearRating(globalID: GlobalID) async -> AgentMutationResult {
            clearRatingCalls.append(globalID)
            return mutationResult
        }

        // 未用到的协议方法补全。
        func playTrack(globalID: GlobalID) async -> Bool { true }
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
        func addToQueue(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func playNext(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func playNext(globalIDs: [GlobalID]) async -> AgentMutationResult { mutationResult }
        func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult { mutationResult }
        func removeFromQueue(at index: Int) async -> AgentMutationResult { mutationResult }
        func reorderQueue(from: Int, to: Int) async -> AgentMutationResult { mutationResult }
        func clearQueue() async -> AgentMutationResult { mutationResult }
        func shuffleRemaining() async -> AgentMutationResult { mutationResult }
        func saveQueueAsPlaylist(name: String) async -> AgentMutationResult { mutationResult }
        func createPlaylist(name: String) async -> GlobalID? { nil }
        func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { mutationResult }
        func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult { mutationResult }
        func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult { mutationResult }
        func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult { mutationResult }
        func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult { mutationResult }
        func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult { mutationResult }
        func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func likeTrack(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func unlikeTrack(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func favoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func unfavoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func favoriteArtist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func unfavoriteArtist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
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

    private final class RatingProvider: AIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [AICompletionResponse]
        private var recorded: [AICompletionRequest] = []
        let capabilities = ModelCapabilities(
            maxContextTokens: 32_000, maxOutputTokens: 4_096,
            supportsToolCalling: true, supportsParallelTools: true,
            supportsToolChoice: true, supportsStrictSchema: true,
            supportsStreaming: true, toolMode: .openAIChat
        )
        init(_ responses: [AICompletionResponse]) { self.responses = responses }
        var supportsToolCalling: Bool { capabilities.supportsToolCalling }
        func testConnection() async -> AIConnectionResult { AIConnectionResult(latency: 0, model: "audit", message: "ok") }
        func complete(_ request: AICompletionRequest) async -> AICompletionResponse { next(request) }
        func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
            let response = next(request)
            return AsyncThrowingStream { continuation in
                continuation.yield(.started(model: response.model))
                if let calls = response.toolCalls, !calls.isEmpty {
                    for call in calls { continuation.yield(.toolCall(call)) }
                } else if !response.content.isEmpty {
                    continuation.yield(.delta(response.content))
                }
                continuation.yield(.completed)
                continuation.finish()
            }
        }
        func requests() -> [AICompletionRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
        private func next(_ request: AICompletionRequest) -> AICompletionResponse {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            guard !responses.isEmpty else { return AICompletionResponse(model: request.model, content: "脚本耗尽。") }
            return responses.removeFirst()
        }
    }

    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    private func seedTracks(_ store: LocalCatalogStore, count: Int) async throws {
        let session = try await store.beginSync(serverID: "v2", mode: .full)
        try await store.stageTracks((0..<count).map { i in
            Track(
                id: TrackID(rawValue: "t\(i)"), serverID: "v2",
                albumID: AlbumID(rawValue: "t\(i)-album"), artistID: ArtistID(rawValue: "t\(i)-artist"),
                title: "歌 \(i)", artistName: "测试", albumTitle: "专辑 \(i)", duration: 200
            )
        }, session: session)
        try await store.completeSync(session, completedAt: .now)
    }

    private func call(_ id: String, _ name: String, _ arguments: [String: AIJSONValue]) -> AIToolCall {
        AIToolCall(id: id, name: name, arguments: .object(arguments))
    }

    /// rating_set 传原生 number 4（integer schema）→ 必须 setRating(4)，绝不能误走 clearRating。
    @Test("rating_set number 传值走 setRating 而非 clearRating")
    func ratingSetNumberValueCallsSetRating() async throws {
        let store = try makeStore()
        try await seedTracks(store, count: 1)
        let bridge = RatingBridge()
        let collector = RatingCollector()
        let provider = RatingProvider([
            AICompletionResponse(model: "audit", content: "", toolCalls: [call("c1", "rating_set", [
                "trackID": .string("v2:t0"),
                "value": .number(4),  // 原生 function calling 的 number
            ])]),
            AICompletionResponse(model: "audit", content: "已评分。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "给这首歌评分 4 分",
            provider: provider,
            model: "audit",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: "v2", allowsFavoritesAndRatings: true),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(bridge.setRatingCalls.count == 1, "number 4 必须走 setRating，实际 set=\(bridge.setRatingCalls) clear=\(bridge.clearRatingCalls)")
        #expect(bridge.setRatingCalls.first?.1 == 4)
        #expect(bridge.clearRatingCalls.isEmpty, "number 4 绝不允许误走 clearRating")
    }

    /// rating_set 传 number 0 → 明确清除评分。
    @Test("rating_set value 0 走 clearRating")
    func ratingSetZeroClears() async throws {
        let store = try makeStore()
        try await seedTracks(store, count: 1)
        let bridge = RatingBridge()
        let collector = RatingCollector()
        let provider = RatingProvider([
            AICompletionResponse(model: "audit", content: "", toolCalls: [call("c1", "rating_set", [
                "trackID": .string("v2:t0"),
                "value": .number(0),
            ])]),
            AICompletionResponse(model: "audit", content: "已清除评分。"),
        ])
        let runID = UUID()
        await ConversationEngine().run(
            userText: "给这首歌评分 0 分",
            provider: provider,
            model: "audit",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: "v2", allowsFavoritesAndRatings: true),
            runID: runID,
            executionLease: ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )

        #expect(bridge.clearRatingCalls == [GlobalID(serverID: "v2", remoteID: "t0")])
        #expect(bridge.setRatingCalls.isEmpty)
    }

    /// ToolCall.int 对 number 4.0 与字符串 "4" 都能正确解析（审计根因的单元级验证）。
    @Test("ToolCall.int 原生 number 与字符串均解析")
    func toolCallIntParsesNumberAndString() throws {
        let native = ToolCall(name: "rating_set", arguments: ["value": .number(4)])
        #expect(try native.int("value") == 4)
        let text = ToolCall(name: "rating_set", arguments: ["value": .string("4")])
        #expect(try text.int("value") == 4)
        // string 投影 number 是 "4.0"（根因），Int("4.0") 为 nil。
        #expect(try native.string("value") == "4.0")
        #expect(Int(try native.string("value")) == nil)
    }
}
