import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import SecurityKit
import Testing

// MARK: - Test doubles

/// Records every AgentBridge call so tests can assert on side effects without a real player/server.
final class MockAgentBridge: AgentBridge, @unchecked Sendable {
    let activeServerIDValue: ServerID?
    private(set) var playedTracks: [GlobalID] = []
    private(set) var serverPlayedTracks: [GlobalID] = []
    private(set) var likedTracks: [GlobalID] = []
    private(set) var removedServers: [ServerID] = []
    private(set) var deletedPlaylists: [GlobalID] = []
    private(set) var addedToPlaylist: [(GlobalID, [GlobalID])] = []
    private(set) var createdPlaylistNames: [String] = []
    private(set) var replacedQueues: [[GlobalID]] = []

    /// 播放类工具的统一返回（默认 true；置 false 可模拟「目标不在目录」）。
    var playResult: Bool = true
    /// 服务器在线流播回退的返回（默认 true）。
    var serverPlayResult: Bool = true

    init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }

    var activeServerID: ServerID? { activeServerIDValue }

    func currentTrack() -> Track? { nil }
    func currentQueue() -> [Track] { [] }

    func playTrack(globalID: GlobalID) async -> Bool { playedTracks.append(globalID); return playResult }
    func playServerTrack(globalID: GlobalID) async -> Bool { serverPlayedTracks.append(globalID); return serverPlayResult }
    func playAlbum(globalID: GlobalID) async -> Bool { playResult }
    func playPlaylist(globalID: GlobalID) async -> Bool { playResult }
    func playRandom() {}
    func pause() {}
    func resume() {}
    func seek(seconds: TimeInterval) {}
    func next() {}
    func previous() {}
    func setShuffle(_ enabled: Bool) {}
    func setRepeatMode(_ mode: RepeatMode) {}
    func setPlaybackRate(_ rate: Float) {}
    func setSleepTimer(mode: String, minutes: TimeInterval) {}
    func cancelSleepTimer() {}
    func getSleepTimer() async -> (mode: String, remaining: TimeInterval) { ("off", 0) }
    func addToQueue(globalID: GlobalID) {}
    func playNext(globalID: GlobalID) {}
    func replaceQueue(globalIDs: [GlobalID]) { replacedQueues.append(globalIDs) }
    func removeFromQueue(at index: Int) {}
    func reorderQueue(from: Int, to: Int) {}
    func clearQueue() {}
    func shuffleRemaining() {}
    func saveQueueAsPlaylist(name: String) async -> Bool {
        createdPlaylistNames.append(name)
        return true
    }

    func createPlaylist(name: String) -> GlobalID? {
        createdPlaylistNames.append(name)
        return GlobalID(serverID: "local", remoteID: UUID().uuidString)
    }
    func renamePlaylist(globalID: GlobalID, name: String) {}
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> Bool {
        addedToPlaylist.append((playlistGID, trackGIDs))
        return true
    }
    func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) {}
    func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) {}
    func duplicatePlaylist(playlistGID: GlobalID) {}
    func mergePlaylists(sourceGIDs: [GlobalID], into name: String) {}
    func deletePlaylist(globalID: GlobalID) { deletedPlaylists.append(globalID) }

    func likeTrack(globalID: GlobalID) { likedTracks.append(globalID) }
    func unlikeTrack(globalID: GlobalID) {}
    func favoriteAlbum(globalID: GlobalID) {}
    func unfavoriteAlbum(globalID: GlobalID) {}
    func favoriteArtist(globalID: GlobalID) {}
    func unfavoriteArtist(globalID: GlobalID) {}
    func setRating(globalID: GlobalID, rating: Int) {}
    func clearRating(globalID: GlobalID) {}

    var serverSearchResultsValue: [Track] = []
    func listServers() -> [ServerAccount] { [] }
    func getActiveServer() -> ServerAccount? { nil }
    func serverSearch(query: String, limit: Int) -> [Track] { serverSearchResultsValue }
    func testServerConnection(serverID: ServerID) async -> Bool { false }
    func addServer(displayName: String, baseURL: String, username: String, token: String) async -> Bool { false }
    func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> Bool { false }
    func switchServer(serverID: ServerID) {}
    func refreshLibrary() {}
    func getSyncStatus() async -> [CatalogSyncStatus] { [] }
    func removeServer(serverID: ServerID) { removedServers.append(serverID) }
}

/// Returns queued ACTION responses once, then a closing message, so the LLM loop terminates.
private final class ScriptedAIProvider: AIProvider, @unchecked Sendable {
    private var remaining: [String]
    private let closing: String
    /// 记录每次收到的完整请求，供测试断言消息角色与内容。
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

    /// 流式路径与 `complete` 语义一致：取下一个内容块，分几段 delta 推送，
    /// 让 AgentRunner 走真实的流式收尾逻辑（文本 ACTION 协议）。
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                requests.append(request)
                let content = remaining.isEmpty ? closing : remaining.removeFirst()
                continuation.yield(.started(model: request.model))
                let chunks = Self.splitForStreaming(content)
                for chunk in chunks {
                    continuation.yield(.delta(chunk))
                }
                continuation.yield(.completed)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 把一段文本拆成几段增量，模拟真实 SSE 的逐块输出。
    fileprivate static func splitForStreaming(_ content: String) -> [String] {
        guard content.count > 2 else { return [content] }
        let mid = content.index(content.startIndex, offsetBy: content.count / 2)
        return [String(content[..<mid]), String(content[mid...])]
    }
}

private struct ThrowingAIProvider: AIProvider {
    enum Failure: Error { case unavailable }
    func testConnection() async throws -> AIConnectionResult { throw Failure.unavailable }
    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse { throw Failure.unavailable }
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish(throwing: Failure.unavailable) }
    }
}

private actor EmittedCollector {
    private(set) var messages: [AgentChatMessage] = []
    func record(_ message: AgentChatMessage) { messages.append(message) }
    func all() -> [AgentChatMessage] { messages }
    func containsText(_ substring: String) -> Bool {
        messages.contains { message in
            message.messages.contains { item in
                if case let .text(text) = item { return text.contains(substring) }
                return false
            }
        }
    }
}

private actor ActionRecorder {
    private(set) var records: [AgentActionRecord] = []
    func add(_ record: AgentActionRecord) { records.append(record) }
    func all() -> [AgentActionRecord] { records }
    func containsTool(_ name: String) -> Bool { records.contains { $0.toolName == name } }
}

private actor ConfirmationProbe {
    let policy: Bool
    private(set) var calls: Int = 0
    private(set) var lastTool: String?
    init(policy: Bool) { self.policy = policy }
    func decide(_ pending: PendingConfirmation) -> Bool {
        calls += 1
        lastTool = pending.toolName
        return policy
    }
}

// MARK: - Helpers

private func makeStore() throws -> LocalCatalogStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
}

private func makeTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
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

private func seed(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

// MARK: - 协议级多轮工具调用网络桩

/// 以真实 URLSession / OpenAICompatibleProvider 跑 Agent 循环，同时记录每一轮
/// 请求体。与逐个 UI 用例相比，它能在一次会话内验证多轮工具回灌的协议形状。
private final class AgentProtocolMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let data: Data
        let headers: [String: String]

        init(data: Data, headers: [String: String] = ["Content-Type": "text/event-stream"]) {
            self.data = data
            self.headers = headers
        }
    }

    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [Stub] = []
        private var capturedRequests: [URLRequest] = []

        func reset(stubs: [Stub]) {
            lock.lock()
            self.stubs = stubs
            capturedRequests = []
            lock.unlock()
        }

        func next(for request: URLRequest) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            capturedRequests.append(materialized(request))
            guard !stubs.isEmpty else { return nil }
            return stubs.removeFirst()
        }

        func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }

        private func materialized(_ request: URLRequest) -> URLRequest {
            guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            var copy = request
            copy.httpBodyStream = nil
            copy.httpBody = body
            return copy
        }
    }

    static func reset(stubs: [Stub]) { state.reset(stubs: stubs) }
    static var requests: [URLRequest] { state.requests() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.state.next(for: request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("OpenAI protocols: one-session multi-round Agent tool loop", .serialized)
struct OpenAIProtocolAgentLoopTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentProtocolMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider(apiPath: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            configuration: AIProviderConfiguration(
                name: "protocol-loop",
                baseURL: URL(string: "https://example.invalid")!,
                apiPath: apiPath,
                model: "protocol-loop-model",
                supportsToolCalling: true
            ),
            credentialVault: InMemoryCredentialVault(),
            session: makeSession()
        )
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func runThreeRoundToolChain(
        apiPath: String,
        stubs: [AgentProtocolMockURLProtocol.Stub]
    ) async throws -> (requests: [[String: Any]], collector: EmittedCollector) {
        AgentProtocolMockURLProtocol.reset(stubs: stubs)
        let store = try makeStore()
        let collector = EmittedCollector()
        await AgentRunner.run(
            userText: "查询资料库后检查当前播放状态",
            provider: makeProvider(apiPath: apiPath),
            model: "protocol-loop-model",
            bridge: MockAgentBridge(),
            catalog: store,
            context: .init(serverID: "test-server"),
            confirm: { _ in true },
            emit: { await collector.record($0) }
        )
        return (try AgentProtocolMockURLProtocol.requests.map(requestObject), collector)
    }

    /// Chat Completions：同一 Agent 会话内连续 two tools → final；最后一轮的
    /// SSE JSON 被拆成两段 data 行，覆盖标准 SSE 多行事件的回归。
    @Test func chatCompletionsReplaysTwoToolResultsInOneSession() async throws {
        let first = """
        data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"chat-call-1\",\"type\":\"function\",\"function\":{\"name\":\"library_get_summary\",\"arguments\":\"{}\"}}]}}]}

        data: [DONE]
        """
        let second = """
        data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"chat-call-2\",\"type\":\"function\",\"function\":{\"name\":\"playback_get_state\",\"arguments\":\"{}\"}}]}}]}

        data: [DONE]
        """
        let final = """
        event: message
        data: {\"choices\":[{\"delta\":{\"content\":\"协议链路已完成\"},\"finish_reason\":\"stop\",\"extra\":
        data: true}]}
        """
        let outcome = try await runThreeRoundToolChain(
            apiPath: "/v1/chat/completions",
            stubs: [.init(data: Data(first.utf8)), .init(data: Data(second.utf8)), .init(data: Data(final.utf8))]
        )

        #expect(outcome.requests.count == 3)
        #expect(await outcome.collector.containsText("协议链路已完成"))
        let secondMessages = try #require(outcome.requests[1]["messages"] as? [[String: Any]])
        #expect(secondMessages.contains { ($0["tool_call_id"] as? String) == "chat-call-1" })
        let thirdMessages = try #require(outcome.requests[2]["messages"] as? [[String: Any]])
        #expect(thirdMessages.contains { ($0["tool_call_id"] as? String) == "chat-call-1" })
        #expect(thirdMessages.contains { ($0["tool_call_id"] as? String) == "chat-call-2" })
    }

    /// 原生 Responses：同一 Agent 会话内连续 two function_call → final，并确认
    /// function_call_output 使用 Responses 所需的 call_id。
    @Test func responsesAPIReplaysTwoFunctionOutputsInOneSession() async throws {
        let first = """
        event: response.output_item.done
        data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"resp-call-1\",\"name\":\"library_get_summary\",\"arguments\":\"{}\"}}

        data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}
        """
        let second = """
        event: response.output_item.done
        data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"resp-call-2\",\"name\":\"playback_get_state\",\"arguments\":\"{}\"}}

        data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r2\"}}
        """
        let final = """
        event: response.output_text.delta
        data: {\"type\":\"response.output_text.delta\",\"delta\":\"Responses 协议链路已完成\",\"extra\":
        data: true}

        data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r3\"}}
        """
        let outcome = try await runThreeRoundToolChain(
            apiPath: "/v1/responses",
            stubs: [.init(data: Data(first.utf8)), .init(data: Data(second.utf8)), .init(data: Data(final.utf8))]
        )

        #expect(outcome.requests.count == 3)
        #expect(await outcome.collector.containsText("Responses 协议链路已完成"))
        let secondInput = try #require(outcome.requests[1]["input"] as? [[String: Any]])
        #expect(secondInput.contains { ($0["type"] as? String) == "function_call" && ($0["call_id"] as? String) == "resp-call-1" })
        #expect(secondInput.contains { ($0["type"] as? String) == "function_call_output" && ($0["call_id"] as? String) == "resp-call-1" })
        let thirdInput = try #require(outcome.requests[2]["input"] as? [[String: Any]])
        #expect(thirdInput.contains { ($0["type"] as? String) == "function_call_output" && ($0["call_id"] as? String) == "resp-call-1" })
        #expect(thirdInput.contains { ($0["type"] as? String) == "function_call_output" && ($0["call_id"] as? String) == "resp-call-2" })
    }
}

// MARK: - Tool validation

@Test("Tool validation: missing required parameter fails")
func toolValidationMissingParameter() async throws {
    let store = try makeStore()
    let bridge = MockAgentBridge()
    let result = await AgentToolkit.execute(
        ToolCall(name: "searchTracks", arguments: [:]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success == false)
    #expect(result.summary.contains("缺少参数"))
}

@Test("Tool validation: invalid numeric parameter fails")
func toolValidationInvalidParameter() async throws {
    let store = try makeStore()
    let bridge = MockAgentBridge()
    let result = await AgentToolkit.execute(
        ToolCall(name: "seek", arguments: ["seconds": "abc"]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success == false)
    #expect(result.summary.contains("非法"))
}

// MARK: - Track ID authenticity

@Test("Track ID authenticity: malformed ID is rejected")
func trackIDAuthenticityRejectsMalformed() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "test-server", remoteID: "real-1", title: "Real One")])
    let bridge = MockAgentBridge()
    let result = await AgentToolkit.execute(
        ToolCall(name: "playTrack", arguments: ["trackID": "not-a-valid-gid"]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success == false)
    #expect(result.summary.contains("不真实或不存在"))
}

@Test("Track ID authenticity: 本地目录没有但服务器有 → 在线流播回退（不再要求先同步）")
func trackIDAuthenticityFallsBackToServerStreaming() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "test-server", remoteID: "real-1", title: "Real One")])
    let bridge = MockAgentBridge()
    let gid = GlobalID(serverID: "test-server", remoteID: "does-not-exist-locally")
    let result = await AgentToolkit.execute(
        ToolCall(name: "playTrack", arguments: ["trackID": gid.description]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    #expect(result.summary.contains("服务器在线流播"))
    #expect(bridge.serverPlayedTracks == [gid])
}

@Test("Track ID authenticity: real ID plays")
func trackIDAuthenticityAcceptsReal() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "test-server", remoteID: "real-1", title: "Real One")])
    let bridge = MockAgentBridge()
    let gid = GlobalID(serverID: "test-server", remoteID: "real-1")
    let result = await AgentToolkit.execute(
        ToolCall(name: "playTrack", arguments: ["trackID": gid.description]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    #expect(await bridge.playedTracks.contains(gid))
}

// MARK: - Read-only playlist

@Test("Read-only playlist: mutation is rejected")
func readOnlyPlaylistRejectsMutation() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "real-1", title: "Real One")
    try await seed(store, [track])
    let playlist = Playlist(id: "pl-ro", serverID: "test-server", name: "只读歌单", trackIDs: [])
    try await store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: true)
    let bridge = MockAgentBridge()
    let plGID = GlobalID(serverID: "test-server", remoteID: "pl-ro")
    let trackGID = GlobalID(serverID: "test-server", remoteID: "real-1")
    let result = await AgentToolkit.execute(
        ToolCall(name: "addTracksToPlaylist", arguments: ["playlistID": plGID.description, "trackIDs": trackGID.description]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success == false)
    #expect(result.summary.contains("只读歌单"))
    #expect(await bridge.addedToPlaylist.isEmpty)
}

@Test("Read-only playlist: normal playlist accepts tracks")
func normalPlaylistAcceptsTracks() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "real-1", title: "Real One")
    try await seed(store, [track])
    let playlist = Playlist(id: "pl-rw", serverID: "test-server", name: "可写歌单", trackIDs: [])
    try await store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)
    let bridge = MockAgentBridge()
    let plGID = GlobalID(serverID: "test-server", remoteID: "pl-rw")
    let trackGID = GlobalID(serverID: "test-server", remoteID: "real-1")
    let result = await AgentToolkit.execute(
        ToolCall(name: "addTracksToPlaylist", arguments: ["playlistID": plGID.description, "trackIDs": trackGID.description]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    #expect(await bridge.addedToPlaylist.contains { $0.0 == plGID })
}

// MARK: - Agent playlist queries

/// 用户问「有多少个歌单」时走 listPlaylists 工具，直接读 SQLite。
/// 只要服务器同步时把歌单写入 SQLite，工具就返回真实数量（此前恒为 0）。
@Test("Agent listPlaylists returns real count after server sync persisted playlists")
func agentListPlaylistsReturnsRealCount() async throws {
    let store = try makeStore()
    let serverID: ServerID = "test-server"
    try await seed(store, [makeTrack(serverID: serverID, remoteID: "t1", title: "Song 1")])
    // 模拟服务器同步把 3 个歌单写入 SQLite（含顺序）。
    try await store.upsertPlaylist(Playlist(id: "pl-a", serverID: serverID, name: "我的收藏", trackIDs: [TrackID(rawValue: "t1")]), serverID: serverID)
    try await store.upsertPlaylist(Playlist(id: "pl-b", serverID: serverID, name: "通勤", trackIDs: []), serverID: serverID)
    try await store.upsertPlaylist(Playlist(id: "pl-c", serverID: serverID, name: "深夜", trackIDs: []), serverID: serverID)

    let bridge = MockAgentBridge()
    let result = await AgentToolkit.execute(
        ToolCall(name: "listPlaylists", arguments: [:]),
        bridge: bridge,
        catalog: store,
        serverID: serverID
    )
    #expect(result.success)
    #expect(result.summary.contains("3"))
}

// MARK: - LLM 消息角色（HTTP 400 回归）

/// 工具执行结果必须用合法角色（user）回传，不能使用 role: .tool——
/// 本 Agent 不是原生 function calling，无 tool_calls 的 tool 消息会被 OpenAI 兼容 API 拒绝（HTTP 400）。
@Test("Tool results are sent back as user role, never tool role")
func toolResultsUseUserRole() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "zz-1", title: "ZZSong")
    try await seed(store, [track])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()

    let provider = ScriptedAIProvider(
        actionBatches: [
            #"ACTION: {"tool":"getFavorites","args":{}}"#,
            "完成。",
        ]
    )

    await AgentRunner.run(
        userText: "我的收藏",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )

    #expect(provider.requests.count >= 2)
    // 第二轮请求必须包含「（工具执行结果）」的 user 消息，且不存在 role == .tool 的消息。
    let second = provider.requests[1]
    #expect(second.messages.contains { $0.role == .user && $0.content.contains("（工具执行结果）") })
    #expect(second.messages.contains { $0.role == .tool } == false)
}

// MARK: - 服务器在线搜索

@Test("server_search returns server tracks as cards (HTTP path)")
func serverSearchReturnsServerTracks() async throws {
    let store = try makeStore()
    let bridge = MockAgentBridge()
    // 服务器返回一首本地目录里没有的歌。
    bridge.serverSearchResultsValue = [
        Track(
            id: TrackID(rawValue: "remote-1"),
            serverID: "test-server",
            albumID: "remote-album",
            artistID: "remote-artist",
            title: "以父之名",
            artistName: "周杰伦",
            albumTitle: "叶惠美",
            duration: 348
        )
    ]
    let result = await AgentToolkit.execute(
        ToolCall(name: "server_search", arguments: ["query": "以父之名"]),
        bridge: bridge,
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    #expect(result.summary.contains("1"))
    // 结果必须带真实卡片（供 UI 展示 + 模型拿到歌曲清单）。
    if case let .trackCards(cards) = result.payload {
        #expect(cards.count == 1)
        #expect(cards.first?.title == "以父之名")
        #expect(cards.first?.globalID == GlobalID(serverID: "test-server", remoteID: "remote-1"))
    } else {
        Issue.record("server_search 应返回歌曲卡片")
    }
}

// MARK: - Offline degrade (no LLM)

@Test("Offline degrade: play still works without the LLM")
func offlinePlay() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "zz-1", title: "ZZPlayUnique")
    try await seed(store, [track])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let log = ActionRecorder()
    let gid = GlobalID(serverID: "test-server", remoteID: "zz-1")
    await AgentRunner.run(
        userText: "播放 ZZPlayUnique",
        provider: nil,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) },
        log: { await log.add($0) }
    )
    #expect(await bridge.playedTracks.contains(gid))
    #expect(await collector.containsText("开始播放"))
    #expect(await log.containsTool("playTrack"))
}

@Test("Offline degrade: no match does not play")
func offlineNoMatch() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "zz-1", title: "ZZPlayUnique")
    try await seed(store, [track])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    await AgentRunner.run(
        userText: "播放 不存在的歌",
        provider: nil,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(await bridge.playedTracks.isEmpty)
    #expect(await collector.containsText("未找到可播放的歌曲"))
}

@Test("Offline degrade: like works without the LLM")
func offlineLike() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "zz-1", title: "ZZLikeUnique")
    try await seed(store, [track])
    let bridge = MockAgentBridge()
    let log = ActionRecorder()
    let gid = GlobalID(serverID: "test-server", remoteID: "zz-1")
    await AgentRunner.run(
        userText: "收藏 ZZLikeUnique",
        provider: nil,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { _ in },
        log: { await log.add($0) }
    )
    #expect(await bridge.likedTracks.contains(gid))
    #expect(await log.containsTool("likeTrack"))
}

@Test("LLM failure degrades to local rules")
func llmFailureDegrades() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "zz-1", title: "ZZPlayUnique")
    try await seed(store, [track])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let gid = GlobalID(serverID: "test-server", remoteID: "zz-1")
    await AgentRunner.run(
        userText: "播放 ZZPlayUnique",
        provider: ThrowingAIProvider(),
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(await bridge.playedTracks.contains(gid))
    // 故障降级后改为本地能力处理，但不再谎称「已切换到本地模式」。
    #expect(await collector.containsText("AI 服务暂时不可用"))
    #expect(await collector.containsText("本地能力"))
}

// MARK: - Agent 主循环（多轮 Tool Calling）

@Test("Large tool batches are not truncated by a fixed cumulative step cap")
func largeToolBatchHasNoFixedStepCap() async throws {
    let store = try makeStore()
    let tracks = (1...320).map { makeTrack(serverID: "test-server", remoteID: "t-\($0)", title: "Song \($0)") }
    try await seed(store, tracks)
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    // 一批返回 305 个 ACTION：Agent 只按单轮/单工具超时停止，不再按累计数量截断。
    let actions = (1...305).map { "ACTION: {\"tool\":\"playTrack\",\"args\":{\"trackID\":\"test-server:t-\($0)\"}}" }
        .joined(separator: "\n")
    let provider = ScriptedAIProvider(actionBatches: [actions])
    await AgentRunner.run(
        userText: "批量播放",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(await bridge.playedTracks.count == 305)
    #expect(await collector.containsText("任务执行步骤异常过多，已暂停") == false)
}

@Test("Loop continues through 12+ tool steps and reaches final answer")
func loopContinuesPastTenToolSteps() async throws {
    let store = try makeStore()
    let tracks = (1...20).map { makeTrack(serverID: "test-server", remoteID: "s-\($0)", title: "Song \($0)") }
    try await seed(store, tracks)
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    // 12 个独立批次，每个批次 1 个工具调用：验证不会在第 3/5/8 步固定停止。
    let batches = (1...12).map { "ACTION: {\"tool\":\"playTrack\",\"args\":{\"trackID\":\"test-server:s-\($0)\"}}" }
    let provider = ScriptedAIProvider(actionBatches: batches, closing: "已按顺序播放完毕。")
    await AgentRunner.run(
        userText: "连续播放",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(await bridge.playedTracks.count == 12)
    #expect(await collector.containsText("已按顺序播放完毕"))
    #expect(await collector.containsText("任务执行步骤异常过多，已暂停") == false)
}

/// 原生 function calling 的脚本化 Provider：前 N 轮返回 tool_calls，之后返回最终文本。
private final class NativeToolAIProvider: AIProvider, @unchecked Sendable {
    private var remaining: [AIToolCall]
    private let closing: String
    private(set) var requests: [AICompletionRequest] = []
    var supportsToolCalling: Bool { true }

    init(toolCalls: [AIToolCall], closing: String = "已处理完成。") {
        self.remaining = toolCalls
        self.closing = closing
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "native", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        requests.append(request)
        guard !remaining.isEmpty else {
            return AICompletionResponse(model: request.model, content: closing, finishReason: "stop")
        }
        let calls = remaining
        remaining = []
        return AICompletionResponse(model: request.model, content: "", finishReason: "tool_calls", toolCalls: calls)
    }

    /// 流式路径与 `complete` 语义一致：有工具调用时逐个产出 `.toolCall`，
    /// 否则把 closing 文本分段 delta 推送，走真实流式收尾。
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                requests.append(request)
                continuation.yield(.started(model: request.model))
                guard !remaining.isEmpty else {
                    for chunk in Self.splitForStreaming(closing) {
                        continuation.yield(.delta(chunk))
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                    return
                }
                let calls = remaining
                remaining = []
                for call in calls {
                    continuation.yield(.toolCall(call))
                }
                continuation.yield(.completed)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func splitForStreaming(_ content: String) -> [String] {
        guard content.count > 2 else { return [content] }
        let mid = content.index(content.startIndex, offsetBy: content.count / 2)
        return [String(content[..<mid]), String(content[mid...])]
    }
}

@Test("Native tool calling: tool results feed back as .tool with matching tool_call_id")
func nativeToolCallingAssociatesResults() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "test-server", remoteID: "n-1", title: "Native Song")])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let gid = GlobalID(serverID: "test-server", remoteID: "n-1")
    let provider = NativeToolAIProvider(toolCalls: [
        AIToolCall(id: "call-1", name: "playTrack", arguments: "{\"trackID\":\"\(gid.description)\"}"),
    ])
    await AgentRunner.run(
        userText: "播放一首歌",
        provider: provider,
        model: "native-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(await bridge.playedTracks.contains(gid))
    #expect(await collector.containsText("已处理完成"))
    // 第二轮请求必须包含 role == .tool 且 tool_call_id 与 call-1 严格配对。
    let second = provider.requests[1]
    let toolMessage = second.messages.first { $0.role == .tool && $0.toolCallID == "call-1" }
    #expect(toolMessage != nil)
    #expect(toolMessage?.content.contains("成功") == true)
}

// MARK: - 流式输出

/// 只输出分段文本的流式 Provider（无工具调用）。
private final class StreamingTextAIProvider: AIProvider, @unchecked Sendable {
    private let chunks: [String]
    init(chunks: [String]) { self.chunks = chunks }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "stream", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        AICompletionResponse(model: request.model, content: chunks.joined())
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(model: request.model))
                for chunk in chunks {
                    continuation.yield(.delta(chunk))
                }
                continuation.yield(.completed)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 先流式输出文本、再产出原生工具调用的 Provider（native 模式）。
private final class StreamingToolCallAIProvider: AIProvider, @unchecked Sendable {
    private let calls: [AIToolCall]
    private let closing: String
    private(set) var requests: [AICompletionRequest] = []
    var supportsToolCalling: Bool { true }

    init(toolCalls: [AIToolCall], closing: String = "已处理完成。") {
        self.calls = toolCalls
        self.closing = closing
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "stream-tool", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        AICompletionResponse(model: request.model, content: closing)
    }

    /// 第一轮：分段 delta 文本 + 逐个 `.toolCall`；后续轮次：只输出 closing 文本。
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                requests.append(request)
                continuation.yield(.started(model: request.model))
                let first = requests.count == 1
                if first {
                    for chunk in ["好的，我", "来搜索这首歌。"] {
                        continuation.yield(.delta(chunk))
                    }
                    for call in calls {
                        continuation.yield(.toolCall(call))
                    }
                } else {
                    for chunk in ScriptedAIProvider.splitForStreaming(closing) {
                        continuation.yield(.delta(chunk))
                    }
                }
                continuation.yield(.completed)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 流式过程中途失败的 Provider：先推一小段文本，再抛错误。
private final class StreamErrorAIProvider: AIProvider, @unchecked Sendable {
    let detail: String
    init(detail: String = "测试错误") { self.detail = detail }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "stream-error", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        throw AIProviderError.malformedResponse(detail: detail, retryable: false)
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(model: request.model))
                continuation.yield(.delta("部分"))
                continuation.finish(throwing: AIProviderError.malformedResponse(detail: detail, retryable: false))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Test("Streaming: deltas are emitted and finalized into the final text")
func streamingEmitsDeltasAndFinalizes() async {
    let store = try! makeStore()
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let provider = StreamingTextAIProvider(chunks: ["你", "好，", "已完成。"])

    await AgentRunner.run(
        userText: "测试流式",
        provider: provider,
        model: "stream-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )

    let all = await collector.all()
    // 每个 delta 都以 .streaming 增量发出。
    let streamed = all.flatMap(\.messages).filter { if case .streaming = $0 { return true } else { return false } }
    #expect(streamed.count == 3)
    // 收尾时产出最终文本。
    #expect(await collector.containsText("你好，已完成。"))
}

@Test("Streaming: tool calls collected from stream are executed and loop continues")
func streamingToolCallsExecuteAndFinalize() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "test-server", remoteID: "s-1", title: "Stream Song")])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let gid = GlobalID(serverID: "test-server", remoteID: "s-1")
    let provider = StreamingToolCallAIProvider(toolCalls: [
        AIToolCall(id: "call-s", name: "playTrack", arguments: "{\"trackID\":\"\(gid.description)\"}"),
    ])

    await AgentRunner.run(
        userText: "播放流式歌曲",
        provider: provider,
        model: "stream-tool-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )

    // 流式过程中收集到的 tool call 被真实执行。
    #expect(await bridge.playedTracks.contains(gid))
    // 第二轮请求把 tool 结果以 role == .tool + tool_call_id 回灌。
    let second = provider.requests[1]
    let toolMessage = second.messages.first { $0.role == .tool && $0.toolCallID == "call-s" }
    #expect(toolMessage != nil)
    // 最终回答仍然出现（流式 delta 已被定型为最终文本）。
    #expect(await collector.containsText("已处理完成。"))
}

@Test("Streaming: mid-stream error degrades to local fallback with error text")
func streamingErrorDegradesToLocalFallback() async {
    let store = try! makeStore()
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let provider = StreamErrorAIProvider(detail: "测试错误")

    await AgentRunner.run(
        userText: "测试失败",
        provider: provider,
        model: "stream-error-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )

    #expect(await collector.containsText("AI 服务暂时不可用"))
    #expect(await collector.containsText("测试错误"))
    // 兜底路径仍然生效（本地搜索找不到 → 提示）。
    #expect(await collector.containsText("本地未找到匹配的歌曲") == true)
}


@Test("Tool failure does not terminate the Agent loop")
func toolFailureDoesNotTerminate() async throws {
    let store = try makeStore()
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    // 第一个工具调用指向不存在的工具（会得到失败结果），随后模型给出最终回答。
    let provider = ScriptedAIProvider(actionBatches: [
        "ACTION: {\"tool\":\"not_a_real_tool\",\"args\":{}}",
        "没有找到相关工具，已改为直接回答。",
    ])
    await AgentRunner.run(
        userText: "测试失败恢复",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    // 工具失败后 Agent 继续下一轮并得到最终回答，而不是整个任务终止。
    #expect(await collector.containsText("没有找到相关工具"))
    #expect(provider.requests.count >= 2)
}

// MARK: - 上下文管理

@Test("ContextManager trims conversation and preserves system + pairing")
func contextManagerTrimsConversation() {
    var messages: [AIMessage] = [AIMessage(role: .system, content: "system")]
    for index in 0..<100 {
        messages.append(AIMessage(role: .user, content: "user-\(index)"))
        messages.append(AIMessage(role: .assistant, content: "assistant-\(index)"))
    }
    // 末尾补一条 .tool 消息：裁剪后不能以 .tool 开头（会失去配对）。
    messages.append(AIMessage(role: .tool, content: "tool-result", toolCallID: "call-x"))
    let trimmed = ContextManager.trim(messages, maxMessages: 12)
    #expect(trimmed.count == 12)
    #expect(trimmed.first?.role == .system)
    #expect(trimmed.first?.content == "system")
    // 不应以 .tool 开头。
    #expect(trimmed[1].role != .tool)
}

@Test("ContextManager truncates oversized tool results")
func contextManagerTruncatesToolResult() {
    let long = String(repeating: "a", count: 5_000)
    let truncated = ContextManager.truncateToolResult(long, limit: 100)
    #expect(truncated.count < long.count)
    #expect(truncated.contains("截断"))
}

// MARK: - 动态工具加载

@Test("ToolSelector loads playlist + recommendation tools for playlist requests")
func toolSelectorLoadsPlaylistTools() {
    let selected = ToolSelector.select(for: "从我的歌单随机推荐一首", all: AgentToolRegistry.all)
    let names = Set(selected.map(\.name))
    #expect(names.contains("listPlaylists"))
    #expect(names.contains("recommend_by_constraints"))
    #expect(names.contains("library_search"))
}

@Test("ToolSelector loads diagnostics tools for 'why did playback stop'")
func toolSelectorLoadsDiagnosticsTools() {
    let selected = ToolSelector.select(for: "为什么刚才停止播放", all: AgentToolRegistry.all)
    let names = Set(selected.map(\.name))
    #expect(names.contains("diagnostics_playback"))
    #expect(names.contains("diagnostics_get_recent_errors"))
}

@Test("ToolSelector never exceeds a bounded tool set")
func toolSelectorIsBounded() {
    let selected = ToolSelector.select(for: "下一首", all: AgentToolRegistry.all)
    // 记忆 / 技能工具（8 个）为跨会话记忆能力常驻开放（主人随时可能报出个人信息），
    // 因此基础工具集从 ~26 增至 34；仍是远小于全量注册表的有界子集。
    #expect(selected.count <= 40)
    #expect(selected.count < AgentToolRegistry.all.count)
}

/// 八项功能验收请求：每个请求都必须选到完成该任务所需的关键工具。
@Test("ToolSelector covers the five explosion-acceptance requests")
func toolSelectorCoversFiveAcceptanceRequests() {
    let cases: [(String, Set<String>)] = [
        ("播放七里香。", ["library_search", "playback_play_song"]),
        ("我有哪些歌单？", ["listPlaylists"]),
        ("从我的歌单随机推荐一首。", ["listPlaylists", "recommend_by_constraints"]),
        ("挑选 20 首比较火的中文歌，列入清单，顺序播放。", ["library_select_tracks", "queue_replace"]),
        ("从深夜、伤感、女声三个标签里选 20 首，排除最近一周听过的，建立播放队列。", ["library_select_tracks", "queue_replace"]),
    ]
    for (text, required) in cases {
        let selected = ToolSelector.select(for: text, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        for tool in required {
            #expect(names.contains(tool), "请求「\(text)」应包含工具 \(tool)")
        }
    }
}

@Test("ToolSelector covers the eight functional acceptance requests")
func toolSelectorCoversEightRequests() {
    let cases: [(String, String)] = [
        ("下一首。", "playback_next"),
        ("播放七里香。", "library_search"),
        ("我有哪些歌单？", "listPlaylists"),
        ("从我的歌单随机推荐一首。", "recommend_by_constraints"),
        ("从收藏里面找五首最近没有听过的歌。", "library_get_starred"),
        ("从深夜、伤感、女声标签里面选十首并建立队列。", "library_get_tracks_by_genre"),
        ("把刚才推荐的前三首加入我的通勤歌单。", "playlist_add_songs"),
        ("为什么刚才停止播放？", "diagnostics_playback"),
    ]
    for (text, expectedTool) in cases {
        let selected = ToolSelector.select(for: text, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains(expectedTool), "请求「\(text)」应包含工具 \(expectedTool)")
    }
}

// MARK: - Delete confirmation

@Test("Delete confirm: rejection does not execute and logs nothing")
func deleteConfirmRejected() async throws {
    let store = try makeStore()
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let log = ActionRecorder()
    let provider = ScriptedAIProvider(actionBatches: ["ACTION: {\"tool\":\"removeServer\",\"args\":{\"serverID\":\"srv-x\"}}"])
    let probe = ConfirmationProbe(policy: false)
    await AgentRunner.run(
        userText: "删除服务器",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { await probe.decide($0) },
        emit: { await collector.record($0) },
        log: { await log.add($0) }
    )
    #expect(await bridge.removedServers.isEmpty)
    #expect(await collector.containsText("已取消"))
    #expect(await log.records.isEmpty)
    #expect(await probe.calls == 1)
}

@Test("Delete confirm: approval executes and logs a destructive action")
func deleteConfirmApproved() async throws {
    let store = try makeStore()
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let log = ActionRecorder()
    let provider = ScriptedAIProvider(actionBatches: ["ACTION: {\"tool\":\"removeServer\",\"args\":{\"serverID\":\"srv-x\"}}"])
    let probe = ConfirmationProbe(policy: true)
    await AgentRunner.run(
        userText: "删除服务器",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { await probe.decide($0) },
        emit: { await collector.record($0) },
        log: { await log.add($0) }
    )
    #expect(await bridge.removedServers.contains("srv-x"))
    #expect(await probe.calls == 1)
    let records = await log.records
    #expect(records.contains { $0.toolName == "removeServer" && $0.permission == .destructive })
}


// MARK: - 全工具逐个验证

/// 逐个执行注册表里的每一个工具：不允许出现「未知工具」路径或崩溃。
/// 参数缺失返回「缺少参数」、系统工具在无 systemService 时返回「系统服务不可用」都算正常。
@Test("Every registered tool dispatches to a real implementation")
func allRegisteredToolsDispatch() async throws {
    let store = try makeStore()
    let track = makeTrack(serverID: "test-server", remoteID: "all-1", title: "All Song")
    try await seed(store, [track])
    let bridge = MockAgentBridge()
    for descriptor in AgentToolRegistry.all {
        let result = await AgentToolkit.executeV2(
            ToolCall(name: descriptor.name, arguments: [:]),
            bridge: bridge,
            catalog: store,
            serverID: "test-server",
            systemService: nil
        )
        #expect(result.call.name == descriptor.name)
        #expect(result.summary.contains("未知工具") == false, "工具 \(descriptor.name) 未接通实现")
    }
}

// MARK: - 音乐清单只在最终回答时展示

@Test("Music cards are buffered and shown only with the final answer")
func cardsBufferedUntilFinalAnswer() async throws {
    let store = try makeStore()
    let tracks = (1...3).map { makeTrack(serverID: "test-server", remoteID: "fav-\($0)", title: "Fav \($0)") }
    try await seed(store, tracks)
    let bridge = MockAgentBridge()
    // 先把歌曲标为收藏，让 getFavorites 返回真实清单。
    for index in 1...3 {
        let gid = GlobalID(serverID: "test-server", remoteID: "fav-\(index)")
        try await store.setFavorite(gid, value: true)
    }
    let collector = EmittedCollector()
    let provider = ScriptedAIProvider(actionBatches: [
        "ACTION: {\"tool\":\"getFavorites\",\"args\":{}}",
        "已为你列出收藏。",
    ])
    await AgentRunner.run(
        userText: "我的收藏",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    // 只应在整轮结束时出现一次歌曲清单，且随后是最终文本回答。
    let all = await collector.all()
    let cardCount = all.reduce(into: 0) { count, message in
        for item in message.messages {
            if case .trackCards = item { count += 1 }
        }
    }
    #expect(cardCount == 1)
    #expect(all.last?.messages.contains { if case .text = $0 { return true } else { return false } } == true)
}

// MARK: - 上下文 token 预算裁剪

@Test("ContextManager trims by token budget and keeps system")
func contextManagerTrimsByTokens() {
    var messages: [AIMessage] = [AIMessage(role: .system, content: "system")]
    for index in 0..<80 {
        messages.append(AIMessage(role: .user, content: "u-\(index)"))
        messages.append(AIMessage(role: .assistant, content: "a-\(index)"))
    }
    // 预算很小：只保留 system + 末尾少量消息。
    let trimmed = ContextManager.trimByTokens(messages, maxTokens: 200)
    #expect(trimmed.first?.role == .system)
    #expect(trimmed.first?.content == "system")
    #expect(trimmed.count < messages.count)
    // 大预算：全部保留（未达到上限）。
    let allKept = ContextManager.trimByTokens(messages, maxTokens: 10_000)
    #expect(allKept.count == messages.count)
}

// MARK: - 任务工作集（防工具调用爆炸）

@Test("WorkingSet: identical query is cached and counted as a duplicate")
func workingSetCachesIdenticalQuery() {
    var ws = AgentTaskWorkingSet()
    let args = ["query": "周杰伦", "limit": "30"]
    let first = ws.tryReuse(tool: "library_search", args: args)
    #expect(first == nil)
    ws.recordExecution(tool: "library_search", args: args, resultText: "结果A")
    let second = ws.tryReuse(tool: "library_search", args: args)
    #expect(second == "结果A")
    #expect(ws.cacheHits == 1)
    #expect(ws.executedCalls == 1)
}

@Test("WorkingSet: no-new-results streak stops searching after limit")
func workingSetStopsSearchingAfterRepeatedNoNewResults() {
    var ws = AgentTaskWorkingSet()
    let gid = GlobalID(serverID: "test-server", remoteID: "x")
    // 第一次有候选：streak 归零。
    ws.observeCandidates([gid])
    #expect(ws.noNewResultsStreak == 0)
    // 连续空结果 / 相同结果：streak 递增，达到上限后停止搜索。
    for _ in 0..<(AgentTaskWorkingSet.noNewResultsLimit - 1) {
        ws.observeCandidates([])
        #expect(ws.stopSearching == false)
    }
    ws.observeCandidates([])
    #expect(ws.stopSearching == true)
}

@Test("WorkingSet: queued songs reaching threshold stops searching")
func workingSetStopsSearchingWhenQueueSatisfied() {
    var ws = AgentTaskWorkingSet()
    let ids = (1...20).map { GlobalID(serverID: "test-server", remoteID: "q-\($0)") }
    ws.noteQueued(ids)
    #expect(ws.stopSearching == true)
}

@Test("WorkingSet: diagnostic summary is non-empty and counts tools")
func workingSetDiagnosticSummary() {
    var ws = AgentTaskWorkingSet()
    ws.recordExecution(tool: "library_search", args: ["query": "周杰伦"], resultText: "ok")
    _ = ws.tryReuse(tool: "library_search", args: ["query": "周杰伦"])
    ws.observeCandidates([GlobalID(serverID: "s", remoteID: "1")])
    let summary = ws.diagnosticSummary
    #expect(summary.contains("library_search"))
    #expect(summary.contains("缓存命中 1 次"))
    #expect(summary.contains("唯一候选歌曲 1 首"))
}

// MARK: - 集合查询 library_select_tracks

@Test("library_select_tracks filters and sorts by popularity proxy")
func librarySelectTracksFiltersAndSorts() async throws {
    let store = try makeStore()
    let tracks = [
        with(makeTrack(serverID: "test-server", remoteID: "s1", title: "中文热歌一")) {
            $0.language = "中文"; $0.isFavorite = true
            $0.streamURL = URL(string: "https://example.com/s1.mp3")
        },
        with(makeTrack(serverID: "test-server", remoteID: "s2", title: "中文冷门二")) {
            $0.language = "中文"
            $0.streamURL = URL(string: "https://example.com/s2.mp3")
        },
        with(makeTrack(serverID: "test-server", remoteID: "s3", title: "English Song")) {
            $0.language = "英语"
            $0.streamURL = URL(string: "https://example.com/s3.mp3")
        },
    ]
    try await seed(store, tracks)
    // 给 s1 记 5 次播放，让热度代理把它排到最前。
    for _ in 0..<5 {
        try await store.recordPlay(GlobalID(serverID: "test-server", remoteID: "s1"), completed: true)
    }
    let result = await AgentToolkit.execute(
        ToolCall(name: "library_select_tracks", arguments: ["languages": "中文", "limit": "10", "sort": "popularityProxy"]),
        bridge: MockAgentBridge(),
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    if case let .trackCards(cards) = result.payload {
        // 语言过滤后只应包含中文歌曲。
        #expect(cards.allSatisfy { ["中文热歌一", "中文冷门二"].contains($0.title) })
        // 播放次数多的排最前。
        #expect(cards.first?.title == "中文热歌一")
    } else {
        Issue.record("library_select_tracks 应返回歌曲卡片")
    }
}

@Test("library_select_tracks falls back to popularity candidates when language tags missing")
func librarySelectTracksLanguageFallback() async throws {
    let store = try makeStore()
    let tracks = (1...6).map { index in
        with(makeTrack(serverID: "test-server", remoteID: "n-\(index)", title: "候选 \(index)")) {
            $0.streamURL = URL(string: "https://example.com/n\(index).mp3")
        }
    }
    try await seed(store, tracks)
    // 语言字段全为空（未写内嵌语言标签）：不应返回空，而应按热度返回候选供模型语义判断。
    let result = await AgentToolkit.execute(
        ToolCall(name: "library_select_tracks", arguments: ["languages": "中文", "limit": "10"]),
        bridge: MockAgentBridge(),
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    if case let .trackCards(cards) = result.payload {
        #expect(cards.count == 6)
    } else {
        Issue.record("语言标签缺失时应按热度返回候选")
    }
}

// MARK: - 循环级：重复搜索不会爆炸

@Test("Loop blocks repeated identical searches and still finishes")
func loopBlocksRepeatedSearches() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "test-server", remoteID: "jay-1", title: "周杰伦 七里香")])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    // 模型连续 4 次调用完全相同的 library_search，然后给出最终回答。
    let provider = ScriptedAIProvider(actionBatches: [
        "ACTION: {\"tool\":\"library_search\",\"args\":{\"query\":\"周杰伦\"}}",
        "ACTION: {\"tool\":\"library_search\",\"args\":{\"query\":\"周杰伦\"}}",
        "ACTION: {\"tool\":\"library_search\",\"args\":{\"query\":\"周杰伦\"}}",
        "ACTION: {\"tool\":\"library_search\",\"args\":{\"query\":\"周杰伦\"}}",
        "完成。",
    ])
    await AgentRunner.run(
        userText: "找周杰伦的歌",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    // 不应触发保护上限暂停，任务正常完成。
    #expect(await collector.containsText("任务执行步骤异常过多") == false)
    #expect(await collector.containsText("完成") == true)
    // 重复搜索被拦截：最后一轮模型请求里应出现停止搜索的提示。
    let lastRequest = provider.requests.last
    #expect(lastRequest?.messages.contains { $0.content.contains("请停止重复搜索") } == true)
}

@Test("Loop allows only one queue replacement per task")
func loopBlocksSecondQueueReplacement() async throws {
    let store = try makeStore()
    let first = makeTrack(serverID: "test-server", remoteID: "queue-1", title: "第一首")
    let second = makeTrack(serverID: "test-server", remoteID: "queue-2", title: "第二首")
    try await seed(store, [first, second])
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    let provider = ScriptedAIProvider(actionBatches: [
        "ACTION: {\"tool\":\"queue_replace\",\"args\":{\"trackIDs\":\"test-server:queue-1\"}}",
        "ACTION: {\"tool\":\"queue_replace\",\"args\":{\"trackIDs\":\"test-server:queue-2\"}}",
        "已完成。",
    ])
    await AgentRunner.run(
        userText: "建立一个播放队列",
        provider: provider,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(bridge.replacedQueues.count == 1)
    #expect(bridge.replacedQueues.first?.first?.remoteID == "queue-1")
    #expect(await collector.containsText("已跳过第二次替换队列"))
}

/// 链式修改 Track 的测试辅助。
private func with(_ track: Track, _ mutate: (inout Track) -> Void) -> Track {
    var copy = track
    mutate(&copy)
    return copy
}


// MARK: - 曲库分类索引（Agent 按需读取）

@Test("CatalogIndex aggregates artists/albums/genres/languages/years without lyrics or artwork")
func catalogIndexAggregatesCategories() async throws {
    let store = try makeStore()
    let tracks = [
        with(makeTrack(serverID: "test-server", remoteID: "i1", title: "中文歌")) { $0.language = "中文"; $0.genres = ["流行"]; $0.year = 2020; $0.streamURL = URL(string: "https://e.com/1") },
        with(makeTrack(serverID: "test-server", remoteID: "i2", title: "英文歌")) { $0.language = "英语"; $0.genres = ["摇滚"]; $0.year = 2021; $0.streamURL = URL(string: "https://e.com/2") },
        with(makeTrack(serverID: "test-server", remoteID: "i3", title: "另一首")) { $0.language = "中文"; $0.genres = ["流行", "民谣"]; $0.year = 2020; $0.streamURL = URL(string: "https://e.com/3") },
    ]
    try await seed(store, tracks)
    let index = try await store.makeCatalogIndex(serverID: "test-server")
    #expect(index.songCount == 3)
    #expect(index.artistCount == 1)
    #expect(index.genres.first(where: { $0.name == "流行" })?.songCount == 2)
    #expect(index.languages.first(where: { $0.language == "中文" })?.songCount == 2)
    #expect(index.years.first(where: { $0.year == 2020 })?.songCount == 2)
}

@Test("library_get_catalog_index returns compact category text")
func catalogIndexToolReturnsText() async throws {
    let store = try makeStore()
    try await seed(store, [
        with(makeTrack(serverID: "test-server", remoteID: "c1", title: "中文歌")) { $0.language = "中文"; $0.genres = ["流行"]; $0.streamURL = URL(string: "https://e.com/1") },
    ])
    let result = await AgentToolkit.execute(
        ToolCall(name: "library_get_catalog_index", arguments: ["category": "genres"]),
        bridge: MockAgentBridge(),
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    if case let .text(text) = result.payload {
        #expect(text.contains("流行"))
    } else {
        Issue.record("应返回文本")
    }
}

@Test("library_get_catalog_tracks filters by category and returns song metadata lines")
func catalogTracksToolFiltersByCategory() async throws {
    let store = try makeStore()
    try await seed(store, [
        with(makeTrack(serverID: "test-server", remoteID: "t1", title: "七里香")) { $0.artistName = "周杰伦"; $0.streamURL = URL(string: "https://e.com/1") },
        with(makeTrack(serverID: "test-server", remoteID: "t2", title: "晴天")) { $0.artistName = "周杰伦"; $0.streamURL = URL(string: "https://e.com/2") },
        with(makeTrack(serverID: "test-server", remoteID: "t3", title: "十年")) { $0.artistName = "陈奕迅"; $0.streamURL = URL(string: "https://e.com/3") },
    ])
    let result = await AgentToolkit.execute(
        ToolCall(name: "library_get_catalog_tracks", arguments: ["category": "artist", "value": "周杰伦", "limit": "10"]),
        bridge: MockAgentBridge(),
        catalog: store,
        serverID: "test-server"
    )
    #expect(result.success)
    if case let .text(text) = result.payload {
        #expect(text.contains("七里香"))
        #expect(text.contains("晴天"))
        #expect(text.contains("十年") == false)
        #expect(text.contains("https://") == false)  // 不泄露流地址
    } else {
        Issue.record("应返回文本")
    }
}

@Test("ToolSelector exposes catalog index tools for recommendation requests")
func toolSelectorExposesCatalogIndexTools() {
    let selected = ToolSelector.select(for: "推荐几首适合深夜的歌", all: AgentToolRegistry.all)
    let names = Set(selected.map(\.name))
    #expect(names.contains("library_get_catalog_index"))
    #expect(names.contains("library_get_catalog_tracks"))
}

@Test("Offline recommendation picks from favorites instead of dead-ending")
func offlineRecommendationUsesFavorites() async throws {
    let store = try makeStore()
    let track = with(makeTrack(serverID: "test-server", remoteID: "r1", title: "推荐歌")) { $0.streamURL = URL(string: "https://e.com/1") }
    try await seed(store, [track])
    try await store.setFavorite(GlobalID(serverID: "test-server", remoteID: "r1"), value: true)
    let bridge = MockAgentBridge()
    let collector = EmittedCollector()
    await AgentRunner.run(
        userText: "推荐几首歌",
        provider: nil,
        model: "scripted-model",
        bridge: bridge,
        catalog: store,
        context: .init(serverID: "test-server", currentTrackTitle: nil, queueCount: 0),
        confirm: { _ in true },
        emit: { await collector.record($0) }
    )
    #expect(await collector.containsText("离线推荐"))
    #expect(await collector.containsText("未找到可播放的歌曲") == false)
}
