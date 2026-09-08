// SPDX-License-Identifier: GPL-3.0-only
import AIKit
import AgentKit
import Application
import AppShell
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

// MARK: - Connectors

/// 还原持久化资料库的桩：restoreLastConnection 返回预置结果。
private struct RestoringConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }
}

/// 没有任何持久化连接的桩：restoreLastConnection 返回 nil。
private struct NoRestoreConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }
}

/// 记录 deletePlaylist 调用的桩，供删除确认集成测试断言是否真正执行。
private final class RecordingConnector: ServerConnecting, @unchecked Sendable {
    let result: ServerConnectionResult
    private(set) var deletedPlaylistIDs: [PlaylistID] = []

    init(result: ServerConnectionResult) { self.result = result }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }

    func deletePlaylist(serverID: ServerID, playlistID: PlaylistID) async -> Bool {
        deletedPlaylistIDs.append(playlistID)
        return true
    }
}

/// 返回排队 ACTION 响应一次，随后返回收尾文本，使 LLM 循环自然终止。
private final class ScriptedAIProvider: AIProvider, @unchecked Sendable {
    private var remaining: [String]
    private let closing: String

    init(actionBatches: [String], closing: String = "已处理完成。") {
        self.remaining = actionBatches
        self.closing = closing
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "scripted", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        let content = remaining.isEmpty ? closing : remaining.removeFirst()
        return AICompletionResponse(model: request.model, content: content)
    }

    /// 流式路径与 `complete` 语义一致：取下一个内容块分段 delta 推送，
    /// 让 AgentRunner 走真实的流式收尾逻辑（文本 ACTION 协议）。
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let content = remaining.isEmpty ? closing : remaining.removeFirst()
                continuation.yield(.started(model: request.model))
                let chunks = Self.splitForStreaming(content)
                for chunk in chunks {
                    continuation.yield(.answerDelta(chunk))
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

/// Holds a headless conversation at the Provider boundary so another session
/// can exercise an interactive destructive confirmation concurrently.
private final class BlockingAIProvider: AIProvider, @unchecked Sendable {
    let capabilities = ModelCapabilities(
        supportsToolCalling: false,
        supportsStreaming: false,
        toolMode: .textualToolProtocol
    )
    private let gate: CoordinatorIndexGate
    private let content: String

    init(gate: CoordinatorIndexGate, content: String) {
        self.gate = gate
        self.content = content
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "blocking", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        await gate.markEntered()
        await gate.waitUntilReleased()
        return AICompletionResponse(model: request.model, content: content)
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor CoordinatorIndexGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// First fails at the Provider boundary, then returns the exact closed
/// Recommendation Index envelope requested by the Runtime.  This intentionally
/// exercises AgentCoordinator/task-store resume instead of calling the skill
/// directly.
private final class ResumeIndexProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var completions = 0
    private var observedBatchSizes: [Int] = []
    private var observedRequests: [AICompletionRequest] = []
    private let pauseGate: CoordinatorIndexGate?
    private let failFirstAttempt: Bool

    init(pauseGate: CoordinatorIndexGate? = nil, failFirstAttempt: Bool = true) {
        self.pauseGate = pauseGate
        self.failFirstAttempt = failFirstAttempt
    }

    let capabilities = ModelCapabilities(
        maxContextTokens: 32_000,
        maxOutputTokens: 4_096,
        supportsToolCalling: true,
        supportsParallelTools: true,
        supportsToolChoice: true,
        supportsStrictSchema: true,
        supportsStreaming: true,
        supportsJSONMode: true,
        supportsJSONSchema: true,
        toolMode: .openAIChat
    )

    var supportsToolCalling: Bool { true }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "resume-index", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        lock.withLock {
            observedRequests.append(request)
        }

        // The runtime first gathers read-only evidence, then makes the closed
        // classification request. Evidence does not affect this fixture's
        // classification attempt count or its deliberate provider failure.
        guard request.outputFormat != nil else {
            return AICompletionResponse(model: request.model, content: "Evidence is sufficient for classification.")
        }

        let count = lock.withLock {
            completions += 1
            return completions
        }
        guard !failFirstAttempt || count > 1 else {
            // Keep this production-path resume fixture deterministic: the
            // first attempt is a non-retryable provider boundary failure;
            // transient transport recovery is covered by the Skill runtime
            // tests separately.
            throw AIProviderError.httpStatusDetail(status: 401, detail: "AuthError: invalid api key (test fixture)")
        }

        if let pauseGate {
            await pauseGate.markEntered()
            await pauseGate.waitUntilReleased()
        }

        guard let payload = request.messages.last?.content.data(using: .utf8),
              let input = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let batchID = input["batchID"] as? String,
              let revision = input["revision"] as? NSNumber,
              let tracks = input["tracks"] as? [[String: Any]]
        else {
            throw AIProviderError.malformedResponse(detail: "测试分类输入无法解析", retryable: false)
        }
        lock.withLock {
            observedBatchSizes.append(tracks.count)
        }

        let items = tracks.compactMap { entry -> [String: Any]? in
            // Classification input now carries evidence alongside each track.
            // The fixture intentionally reads only the canonical track record.
            let track = (entry["track"] as? [String: Any]) ?? entry
            guard let id = track["id"] as? String else { return nil }
            return [
                "id": id,
                "moods": ["平静"],
                "scenes": ["深夜"],
                "energy": 3,
                "tempo": 2,
                "acousticness": 4,
                "danceability": 2,
                "themes": [],
                "genres": [],
                "vocals": ["器乐"],
                "textures": ["钢琴"],
                "styles": ["轻音乐"],
                "instruments": [],
                "rhythms": [],
                "confidence": 0.9,
            ]
        }
        let response: [String: Any] = [
            "batchID": batchID,
            "revision": revision,
            "items": items,
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        return AICompletionResponse(model: request.model, content: String(decoding: data, as: UTF8.self))
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    var completionCount: Int {
        lock.withLock { completions }
    }

    var batchSizes: [Int] {
        lock.withLock { observedBatchSizes }
    }

    var requests: [AICompletionRequest] {
        lock.withLock { observedRequests }
    }
}

// MARK: - Helpers

private func makeAccount() -> ServerAccount {
    ServerAccount(
        id: "test-server",
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        credentialReference: "cred"
    )
}

private func makeTrack(remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: "test-server",
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "Artist",
        albumTitle: "Album",
        duration: 200
    )
}

private func makeResult(tracks: [Track], playlists: [Playlist] = []) -> ServerConnectionResult {
    ServerConnectionResult(
        account: makeAccount(),
        capabilities: .init(supportsStructuredLyrics: true),
        artists: [],
        albums: [],
        tracks: tracks,
        playlists: playlists,
        serverType: "test-server",
        serverVersion: "1.0"
    )
}

private func temporaryAgentDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-agent-tests")
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 每个测试独占一个本地目录库文件，避免并行测试共享固定 applicationSupport 路径导致写入竞争。
private func temporaryCatalogURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-catalog-tests")
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("catalog.sqlite")
}

// MARK: - Card direct-play (no LLM)

@Test("点击歌曲卡片直接本地播放，不经过大模型")
@MainActor
func cardDirectPlayBypassesLLM() async throws {
    let tracks = [makeTrack(remoteID: "remote-1", title: "First"), makeTrack(remoteID: "remote-2", title: "Second")]
    // 使用隔离的 UserDefaults，避免「上次收听」持久化（本次新增功能）写入共享的 .standard 污染其它测试，
    // 也避免本测试被此前运行残留的 lastTrackID 影响，使 connect 后 currentTrack 恰为 target 导致断言失真。
    let defaults = UserDefaults(suiteName: "card-direct-play-\(UUID().uuidString)")!
    let model = AuralisAppModel(connector: RestoringConnector(result: makeResult(tracks: tracks)), defaults: defaults, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(model: model, coordinator: model.catalogCoordinator, directory: temporaryAgentDirectory())
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))

    let target = model.catalog.tracks[1]
    let card = TrackCard(
        globalID: GlobalID(serverID: model.catalog.activeServerID!, remoteID: target.id.rawValue),
        title: target.title,
        artistName: target.artistName,
        albumTitle: target.albumTitle,
        duration: target.duration,
        isFavorite: target.isFavorite
    )
    #expect(model.currentTrack.id != target.id)

    coordinator.play(card: card)

    // play() 是 fire-and-forget：等待主线程上的内部任务把曲目解析并切歌。
    for _ in 0..<100 {
        await Task.yield()
        if model.currentTrack.id == target.id { break }
    }
    #expect(model.currentTrack.id == target.id)
}

// MARK: - Background restore

@Test("后台恢复：有持久化连接时替换资料库并隐藏服务器配置")
@MainActor
func backgroundRestoreReplacesCatalog() async throws {
    let tracks = [makeTrack(remoteID: "remote-1", title: "First"), makeTrack(remoteID: "remote-2", title: "Second")]
    let model = AuralisAppModel(connector: RestoringConnector(result: makeResult(tracks: tracks)), storeURL: temporaryCatalogURL())
    #expect(model.catalog.tracks.isEmpty)

    await model.restorePersistedLibrary()

    #expect(model.catalog.account.id == "test-server")
    #expect(model.catalog.tracks.count == 2)
    #expect(model.shouldPresentServerSetup == false)
}

@Test("后台恢复：无持久化连接时弹出服务器配置")
@MainActor
func backgroundRestorePromptsSetupWhenEmpty() async throws {
    let tracks = [makeTrack(remoteID: "remote-1", title: "First")]
    let model = AuralisAppModel(connector: NoRestoreConnector(result: makeResult(tracks: tracks)), storeURL: temporaryCatalogURL())
    #expect(model.shouldPresentServerSetup == false)

    await model.restorePersistedLibrary()

    #expect(model.catalog.tracks.isEmpty)
    #expect(model.shouldPresentServerSetup == true)
}

// MARK: - Automatic tool execution (integration through AgentCoordinator)

@Test("Session activation sanitizes legacy persisted identifiers")
@MainActor
func sessionActivationSanitizesLegacyPersistedIdentifiers() async throws {
    let directory = temporaryAgentDirectory()
    let seedStore = SessionStore(fileURL: directory.appendingPathComponent("agent-sessions.json"))
    let legacySession = await seedStore.create()
    let legacyID = GlobalID(serverID: "server-persist", remoteID: "playlist-123")
    await seedStore.append(
        AgentChatMessage(
            role: .assistant,
            messages: [.text("歌单（playlistID=\(legacyID.description)，8 首）")]
        ),
        to: legacySession.id
    )

    let model = AuralisAppModel(
        connector: NoRestoreConnector(result: makeResult(tracks: [])),
        storeURL: temporaryCatalogURL()
    )
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: directory
    )
    await coordinator.bootstrap()
    await coordinator.activate(legacySession.id)

    let text = coordinator.messages.flatMap { message in
        message.messages.compactMap { item -> String? in
            if case let .text(value) = item { return value }
            return nil
        }
    }.joined(separator: "\n")
    #expect(text.contains("歌单"))
    #expect(!text.contains(legacyID.description))
    #expect(!text.contains("playlistID="))
}

@Test("Session switch away and back still sanitizes persisted identifiers")
@MainActor
func sessionSwitchRoundTripSanitizesPersistedIdentifiers() async throws {
    let directory = temporaryAgentDirectory()
    let seedStore = SessionStore(fileURL: directory.appendingPathComponent("agent-sessions.json"))
    let sessionA = await seedStore.create()
    let sessionB = await seedStore.create()
    let dirtyID = GlobalID(serverID: "server-persist", remoteID: "playlist-456")
    await seedStore.append(
        AgentChatMessage(
            role: .assistant,
            messages: [.text("歌单（playlistID=\(dirtyID.description)，5 首）")]
        ),
        to: sessionA.id
    )

    let model = AuralisAppModel(
        connector: NoRestoreConnector(result: makeResult(tracks: [])),
        storeURL: temporaryCatalogURL()
    )
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: directory
    )
    await coordinator.bootstrap()

    func visibleText() -> String {
        coordinator.messages.flatMap { message in
            message.messages.compactMap { item -> String? in
                if case let .text(value) = item { return value }
                return nil
            }
        }.joined(separator: "\n")
    }

    // First view must be clean.
    await coordinator.activate(sessionA.id)
    #expect(visibleText().contains("歌单"))
    #expect(!visibleText().contains(dirtyID.description))

    // Switch to another session and back; the ID must not reappear.
    await coordinator.activate(sessionB.id)
    await coordinator.activate(sessionA.id)
    #expect(visibleText().contains("歌单"))
    #expect(!visibleText().contains(dirtyID.description))
    #expect(!visibleText().contains("playlistID="))
}

@Test("不可逆删除在 UI 批准后执行并记入操作日志")
@MainActor
func destructiveToolExecutesWithoutConfirmation() async throws {
    let playlistRemoteID = UUID().uuidString
    let playlist = Playlist(id: PlaylistID(rawValue: playlistRemoteID), serverID: "test-server", name: "待删除", trackIDs: [])
    let connector = RecordingConnector(result: makeResult(tracks: [makeTrack(remoteID: "remote-1", title: "Only")], playlists: [playlist]))
    let model = AuralisAppModel(connector: connector, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(model: model, coordinator: model.catalogCoordinator, directory: temporaryAgentDirectory())
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let gid = GlobalID(serverID: "test-server", remoteID: playlistRemoteID)
    try await model.catalogCoordinator.store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)

    let provider = ScriptedAIProvider(actionBatches: ["ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(gid.description)\"}}"])
    coordinator.send("删除歌单", provider: provider)

    for _ in 0..<500 {
        await Task.yield()
        if coordinator.pendingOperationConfirmation != nil {
            coordinator.approveOperationConfirmation()
        }
        if !coordinator.isRunning { break }
        // The production run owns a detached async task; a yield-only loop
        // can exhaust before it gets scheduled when the whole package runs.
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect((await connector.deletedPlaylistIDs).contains(PlaylistID(rawValue: playlistRemoteID)))
    #expect(!model.catalog.playlists.contains { $0.id.rawValue == playlistRemoteID })
    #expect(coordinator.actionRecords.contains { $0.toolName == "deletePlaylist" && $0.permission == .destructive })
}

@Test("UI confirmation dismiss defers denial and resumes the run exactly once")
@MainActor
func operationConfirmationDismissDefersDenialAndResumesOnce() async throws {
    let playlistRemoteID = UUID().uuidString
    let playlist = Playlist(
        id: PlaylistID(rawValue: playlistRemoteID),
        serverID: "test-server",
        name: "待删除",
        trackIDs: []
    )
    let connector = RecordingConnector(
        result: makeResult(tracks: [makeTrack(remoteID: "remote-1", title: "Only")], playlists: [playlist])
    )
    let model = AuralisAppModel(connector: connector, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let gid = GlobalID(serverID: "test-server", remoteID: playlistRemoteID)
    try await model.catalogCoordinator.store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)
    coordinator.send(
        "删除歌单",
        provider: ScriptedAIProvider(
            actionBatches: [
                "ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(gid.description)\"}}"
            ]
        )
    )

    for _ in 0..<500 {
        if coordinator.pendingOperationConfirmation != nil { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    let confirmationID = try #require(coordinator.pendingOperationConfirmation?.id)

    // This is the same next-runloop boundary used by AssistantView's alert
    // Binding setter. It must resume the waiting confirmation with false.
    DispatchQueue.main.async {
        guard coordinator.pendingOperationConfirmation?.id == confirmationID else { return }
        coordinator.denyOperationConfirmation()
    }
    for _ in 0..<500 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(!coordinator.isRunning)
    #expect(coordinator.pendingOperationConfirmation == nil)
    #expect(!connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: playlistRemoteID)))

    // A delayed/duplicate dismiss callback must be idempotent and must not
    // resume another continuation or execute the denied write.
    coordinator.denyOperationConfirmation()
    #expect(coordinator.pendingOperationConfirmation == nil)
    #expect(!connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: playlistRemoteID)))
}

@Test("运行时确认按会话隔离，不阻塞后台会话")
@MainActor
func operationConfirmationIsScopedToRunAndSession() async throws {
    let playlistRemoteID = UUID().uuidString
    let playlist = Playlist(
        id: PlaylistID(rawValue: playlistRemoteID),
        serverID: "test-server",
        name: "待删除",
        trackIDs: []
    )
    let connector = RecordingConnector(
        result: makeResult(tracks: [makeTrack(remoteID: "remote-1", title: "Only")], playlists: [playlist])
    )
    let model = AuralisAppModel(connector: connector, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let sessionA = await coordinator.newSession()
    let sessionB = await coordinator.newSession()
    await coordinator.activate(sessionA)
    let gid = GlobalID(serverID: "test-server", remoteID: playlistRemoteID)
    try await model.catalogCoordinator.store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)

    let providerA = ScriptedAIProvider(
        actionBatches: ["ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(gid.description)\"}}"],
        closing: "删除完成。"
    )
    coordinator.send("删除歌单", provider: providerA)
    for _ in 0..<500 {
        if coordinator.pendingOperationConfirmation != nil { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(coordinator.pendingOperationConfirmation != nil)

    // The pending confirmation belongs to A. Switching to B must hide it but
    // must not cancel A's run or consume its continuation.
    await coordinator.activate(sessionB)
    #expect(coordinator.pendingOperationConfirmation == nil)
    let providerB = MockAIProvider()
    coordinator.send("你好", provider: providerB)
    for _ in 0..<500 where coordinator.isRunning {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!coordinator.isRunning)

    await coordinator.activate(sessionA)
    #expect(coordinator.pendingOperationConfirmation != nil)
    coordinator.approveOperationConfirmation()
    for _ in 0..<500 where coordinator.isRunning {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: playlistRemoteID)))
}

@Test("两个交互会话可同时等待确认，并且只能批准各自的 run")
@MainActor
func simultaneousInteractiveConfirmationsRemainKeyedByRunAndSession() async throws {
    let firstID = UUID().uuidString
    let secondID = UUID().uuidString
    let first = Playlist(
        id: PlaylistID(rawValue: firstID),
        serverID: "test-server",
        name: "第一个待删除",
        trackIDs: []
    )
    let second = Playlist(
        id: PlaylistID(rawValue: secondID),
        serverID: "test-server",
        name: "第二个待删除",
        trackIDs: []
    )
    let connector = RecordingConnector(
        result: makeResult(
            tracks: [makeTrack(remoteID: "remote-1", title: "Only")],
            playlists: [first, second]
        )
    )
    let model = AuralisAppModel(connector: connector, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let sessionA = await coordinator.newSession()
    let sessionB = await coordinator.newSession()
    let firstGID = GlobalID(serverID: "test-server", remoteID: firstID)
    let secondGID = GlobalID(serverID: "test-server", remoteID: secondID)
    try await model.catalogCoordinator.store.upsertPlaylist(first, serverID: "test-server", isReadOnly: false)
    try await model.catalogCoordinator.store.upsertPlaylist(second, serverID: "test-server", isReadOnly: false)

    await coordinator.activate(sessionA)
    coordinator.send(
        "删除第一个歌单",
        provider: ScriptedAIProvider(actionBatches: [
            "ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(firstGID.description)\"}}"
        ])
    )
    for _ in 0..<500 {
        if coordinator.pendingOperationConfirmation != nil { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    let pendingA = try #require(coordinator.pendingOperationConfirmation)
    #expect(pendingA.sessionID == sessionA)
    #expect(pendingA.toolCallID == "text-0")
    #expect(pendingA.operation == .playlistDelete)

    // A remains suspended, but B must be able to start its own destructive
    // run rather than being rejected by a global continuation/pending flag.
    await coordinator.activate(sessionB)
    coordinator.send(
        "删除第二个歌单",
        provider: ScriptedAIProvider(actionBatches: [
            "ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(secondGID.description)\"}}"
        ])
    )
    for _ in 0..<500 {
        if coordinator.pendingOperationConfirmation?.sessionID == sessionB { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    let pendingB = try #require(coordinator.pendingOperationConfirmation)
    #expect(pendingB.sessionID == sessionB)
    #expect(pendingB.runID != pendingA.runID)
    #expect(pendingB.call.optionalString("playlistID") == secondGID.description)

    coordinator.approveOperationConfirmation()
    for _ in 0..<500 where coordinator.isRunning {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    // Switching back exposes A's original pending operation; approving B did
    // not resume or approve A's continuation.
    await coordinator.activate(sessionA)
    let stillPendingA = try #require(coordinator.pendingOperationConfirmation)
    #expect(stillPendingA.id == pendingA.id)
    #expect(stillPendingA.sessionID == sessionA)
    coordinator.approveOperationConfirmation()
    for _ in 0..<500 where coordinator.isRunning {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: firstID)))
    #expect(connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: secondID)))
}

@Test("Headless mode is scoped per run and sendAndWait returns its captured session")
@MainActor
func headlessRunDoesNotSuppressInteractiveConfirmationOrLeakSessionText() async throws {
    let playlistRemoteID = UUID().uuidString
    let playlist = Playlist(
        id: PlaylistID(rawValue: playlistRemoteID),
        serverID: "test-server",
        name: "待删除",
        trackIDs: []
    )
    let connector = RecordingConnector(
        result: makeResult(tracks: [makeTrack(remoteID: "remote-1", title: "Only")], playlists: [playlist])
    )
    let model = AuralisAppModel(connector: connector, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let sessionA = await coordinator.newSession()
    let sessionB = await coordinator.newSession()
    let gid = GlobalID(serverID: "test-server", remoteID: playlistRemoteID)
    try await model.catalogCoordinator.store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)

    await coordinator.activate(sessionA)
    let gate = CoordinatorIndexGate()
    let headlessTask = Task { @MainActor in
        await coordinator.sendAndWait(
            "讲一个需要等待的长故事",
            provider: BlockingAIProvider(gate: gate, content: "A 会话的无界面结果")
        )
    }
    await gate.waitUntilEntered()

    // A is headless and still blocked at the Provider. B must nevertheless
    // reach its own interactive destructive confirmation.
    await coordinator.activate(sessionB)
    let providerB = ScriptedAIProvider(
        actionBatches: ["ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(gid.description)\"}}"],
        closing: "B 会话删除完成。"
    )
    coordinator.send("删除歌单", provider: providerB)
    for _ in 0..<500 {
        if coordinator.pendingOperationConfirmation != nil { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(coordinator.pendingOperationConfirmation != nil)

    coordinator.approveOperationConfirmation()
    for _ in 0..<500 where coordinator.isRunning {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: playlistRemoteID)))

    // Keep the UI on B while A completes. sendAndWait must read A's
    // SessionStore messages rather than the currently published B messages.
    await coordinator.activate(sessionB)
    await gate.release()
    let reply = await headlessTask.value
    #expect(reply == "A 会话的无界面结果")
}

@Test("删除等待确认的会话会自动拒绝并清理确认")
@MainActor
func deletingSessionRejectsItsPendingConfirmation() async throws {
    let playlistRemoteID = UUID().uuidString
    let playlist = Playlist(
        id: PlaylistID(rawValue: playlistRemoteID),
        serverID: "test-server",
        name: "待删除",
        trackIDs: []
    )
    let connector = RecordingConnector(
        result: makeResult(tracks: [makeTrack(remoteID: "remote-1", title: "Only")], playlists: [playlist])
    )
    let model = AuralisAppModel(connector: connector, storeURL: temporaryCatalogURL())
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()
    let sessionA = await coordinator.newSession()
    let sessionB = await coordinator.newSession()
    await coordinator.activate(sessionA)
    let gid = GlobalID(serverID: "test-server", remoteID: playlistRemoteID)
    try await model.catalogCoordinator.store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)

    let provider = ScriptedAIProvider(
        actionBatches: ["ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(gid.description)\"}}"]
    )
    coordinator.send("删除歌单", provider: provider)
    for _ in 0..<500 {
        if coordinator.pendingOperationConfirmation != nil { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(coordinator.pendingOperationConfirmation != nil)

    await coordinator.activate(sessionB)
    await coordinator.delete(sessionA)
    #expect(coordinator.activeSessionID == sessionB)
    #expect(coordinator.pendingOperationConfirmation == nil)
    #expect(!connector.deletedPlaylistIDs.contains(PlaylistID(rawValue: playlistRemoteID)))
}

@Test("Coordinator 真实入口在 Provider 失败后可由继续恢复索引")
@MainActor
func recommendationIndexResumesThroughCoordinatorAfterProviderFailure() async throws {
    let track = makeTrack(remoteID: "resume-track", title: "Resume Track")
    let model = AuralisAppModel(
        connector: RestoringConnector(result: makeResult(tracks: [track])),
        storeURL: temporaryCatalogURL()
    )
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let provider = ResumeIndexProvider()
    let sync = try await model.catalogCoordinator.store.beginSync(serverID: "test-server", mode: .full)
    try await model.catalogCoordinator.store.stageTracks([track], session: sync)
    try await model.catalogCoordinator.store.completeSync(sync, completedAt: .now)
    let initialStatus = try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server")
    let isIndexBuild = AgentRequestSemantics.analyze("开始并一次性完成推荐索引").isRecommendationIndexBuild
    #expect(isIndexBuild)
    #expect(initialStatus.pendingUniqueTracks == 1)
    coordinator.send("开始并一次性完成推荐索引", provider: provider)
    for _ in 0..<300 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(!coordinator.isRunning)
    #expect(coordinator.activeTask?.status == .failed)
    #expect(try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server").pendingUniqueTracks == 1)

    coordinator.send("继续", provider: provider)
    for _ in 0..<600 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(!coordinator.isRunning)
    #expect(provider.completionCount == 2)
    #expect(coordinator.activeTask?.status == .completed)
    #expect(try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server").pendingUniqueTracks == 0)
}

@Test("Coordinator projects the live Recommendation Index phase into the run presentation")
@MainActor
func recommendationIndexLivePhaseReachesCoordinatorPresentation() async throws {
    let track = makeTrack(remoteID: "live-index-track", title: "Live Index Track")
    let model = AuralisAppModel(
        connector: RestoringConnector(result: makeResult(tracks: [track])),
        storeURL: temporaryCatalogURL()
    )
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()

    let sync = try await model.catalogCoordinator.store.beginSync(serverID: "test-server", mode: .full)
    try await model.catalogCoordinator.store.stageTracks([track], session: sync)
    try await model.catalogCoordinator.store.completeSync(sync, completedAt: .now)

    let gate = CoordinatorIndexGate()
    let provider = ResumeIndexProvider(pauseGate: gate)
    coordinator.send("开始并一次性完成推荐索引", provider: provider)
    for _ in 0..<300 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!coordinator.isRunning)

    coordinator.send("继续", provider: provider)
    await gate.waitUntilEntered()
    for _ in 0..<100 {
        if coordinator.recommendationIndexExecutionState.isRunning { break }
        await Task.yield()
    }

    guard case let .running(snapshot) = coordinator.recommendationIndexExecutionState else {
        Issue.record("expected Coordinator to expose a live Recommendation Index run")
        await gate.release()
        return
    }
    #expect(snapshot.phase == .classifyingBatch)
    #expect(snapshot.currentBatchSize == 1)
    #expect(snapshot.pendingTracks == 1)
    guard case let .workflow(skillID, phase, _) = coordinator.runPresentationState?.phase else {
        Issue.record("expected the active run presentation to show the workflow phase")
        await gate.release()
        return
    }
    #expect(skillID == RecommendationIndexSkillRuntime.skillID)
    #expect(phase == RecommendationIndexWorkflow.State.classifyingBatch.rawValue)

    await gate.release()
    for _ in 0..<600 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!coordinator.isRunning)
    #expect(try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server").pendingUniqueTracks == 0)
}

@Test("Coordinator exact Chinese build request reaches the real Recommendation Index Runtime")
@MainActor
func recommendationIndexExactChineseBuildRequestUsesRealRuntime() async throws {
    let tracks = [
        makeTrack(remoteID: "exact-index-1", title: "Exact Index One"),
        makeTrack(remoteID: "exact-index-2", title: "Exact Index Two"),
    ]
    let catalogStore = try LocalCatalogStore(url: temporaryCatalogURL())
    let model = AuralisAppModel(
        connector: RestoringConnector(result: makeResult(tracks: tracks)),
        catalogStore: catalogStore
    )
    var privacyPermissions = AIPrivacyPermissions()
    privacyPermissions.allowsExternalDiscovery = true
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory(),
        privacyPermissionsOverride: privacyPermissions
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()
    try? await Task.sleep(for: .milliseconds(50))

    let sync = try await model.catalogCoordinator.store.beginSync(serverID: "test-server", mode: .full)
    try await model.catalogCoordinator.store.stageTracks(tracks, session: sync)
    try await model.catalogCoordinator.store.completeSync(sync, completedAt: .now)
    let initialStatus = try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server")
    #expect(initialStatus.pendingUniqueTracks == 2)

    let text = "建立推荐索引"
    let semantics = AgentRequestSemantics.analyze(text)
    let policy = AgentTaskPolicyResolver.resolve(text: text)
    let route = WorkflowEngine.route(
        intent: policy.intent,
        text: text,
        semantics: semantics
    )
    #expect(semantics.isRecommendationIndexBuild)
    #expect(semantics.requestedOperations.contains(.recommendationIndexWrite))
    #expect(policy.intent == .libraryManagement)
    #expect(policy.completion == .indexPendingCountIsZero)
    #expect(route.kind == .recommendationIndex)

    let gate = CoordinatorIndexGate()
    let provider = ResumeIndexProvider(pauseGate: gate, failFirstAttempt: false)
    coordinator.send(text, provider: provider)
    await gate.waitUntilEntered()

    for _ in 0..<100 {
        if coordinator.recommendationIndexExecutionState.isRunning { break }
        await Task.yield()
    }
    guard case let .running(snapshot) = coordinator.recommendationIndexExecutionState else {
        Issue.record("expected the exact Chinese request to enter RecommendationIndexSkillRuntime")
        await gate.release()
        return
    }
    #expect(snapshot.phase == .classifyingBatch)
    #expect(snapshot.currentBatchSize == 2)
    #expect(snapshot.pendingTracks == 2)
    guard case let .workflow(skillID, phase, _) = coordinator.runPresentationState?.phase else {
        Issue.record("expected the live workflow presentation to be Recommendation Index")
        await gate.release()
        return
    }
    #expect(skillID == RecommendationIndexSkillRuntime.skillID)
    #expect(phase == RecommendationIndexWorkflow.State.classifyingBatch.rawValue)

    await gate.release()
    for _ in 0..<600 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    let finalStatus = try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server")
    #expect(!coordinator.isRunning)
    #expect(coordinator.activeTask?.status == .completed)
    #expect(finalStatus.pendingUniqueTracks == 0)
    #expect(finalStatus.pendingUniqueTracks == 0)

    let requests = provider.requests
    let evidenceRequests = requests.filter { $0.outputFormat == nil }
    let classificationRequests = requests.filter { $0.outputFormat != nil }
    #expect(evidenceRequests.count == 1)
    #expect(classificationRequests.count == 1)
    #expect(classificationRequests.allSatisfy { $0.tools?.isEmpty == true })
    #expect(classificationRequests.allSatisfy { $0.hostedTools?.isEmpty == true })
    #expect(classificationRequests.allSatisfy { $0.toolChoice == nil })
    #expect(classificationRequests.allSatisfy { request in
        request.messages.allSatisfy { !$0.content.contains("recommendation_index_commit") }
    })
    #expect(coordinator.actionRecords.contains { $0.toolName == "recommendation_index_commit" })
    #expect(!coordinator.messages.contains { message in
        message.messages.contains { item in
            if case let .text(value) = item {
                return value.contains("无法保存") || value.contains("没有写工具")
            }
            return false
        }
    })
}

@Test("Coordinator 真实入口连续处理三批，并在 Provider 失败后继续完成索引")
@MainActor
func recommendationIndexProcessesThreeBatchesThroughCoordinator() async throws {
    let tracks = (0..<20).map { index in
        makeTrack(remoteID: "continuous-\(index)", title: "Continuous \(index)")
    }
    let catalogStore = try LocalCatalogStore(url: temporaryCatalogURL())
    let model = AuralisAppModel(
        connector: RestoringConnector(result: makeResult(tracks: tracks)),
        catalogStore: catalogStore
    )
    let coordinator = AgentCoordinator(
        model: model,
        coordinator: model.catalogCoordinator,
        directory: temporaryAgentDirectory()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    await coordinator.bootstrap()
    // `connect` starts the production catalog refresh in the background. Let
    // its registration finish before this test creates a deterministic snapshot.
    try? await Task.sleep(for: .milliseconds(50))

    let provider = ResumeIndexProvider()
    let sync = try await model.catalogCoordinator.store.beginSync(serverID: "test-server", mode: .full)
    try await model.catalogCoordinator.store.stageTracks(tracks, session: sync)
    try await model.catalogCoordinator.store.saveCheckpoint(
        LibrarySyncCheckpoint(
            sessionID: sync.id,
            serverID: sync.serverID,
            section: .tracks,
            processedCount: tracks.count,
            completedAt: .now
        ),
        session: sync
    )
    try await model.catalogCoordinator.store.completeSync(sync, completedAt: .now)
    #expect(try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server").pendingUniqueTracks == 20)

    // 首次真实入口请求在 Provider 边界失败，不能被离线音乐搜索或其它协议接管。
    coordinator.send("开始并一次性完成推荐索引", provider: provider)
    for _ in 0..<500 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!coordinator.isRunning)
    #expect(coordinator.activeTask?.status == .failed)
    #expect(try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server").pendingUniqueTracks == 20)

    // 短 continuation 恢复同一条 execution lineage；成功路径必须真实提交 8+8+4 三批。
    coordinator.send("继续", provider: provider)
    for _ in 0..<1_000 {
        if !coordinator.isRunning { break }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    let finalStatus = try await model.catalogCoordinator.store.recommendationIndexStatus(serverID: "test-server")
    #expect(!coordinator.isRunning)
    #expect(coordinator.activeTask?.status == .completed)
    #expect(finalStatus.pendingUniqueTracks == 0)
    #expect(finalStatus.pendingUniqueTracks == 0)
    #expect(provider.completionCount == 4)
    #expect(provider.batchSizes == [8, 8, 4])
}
