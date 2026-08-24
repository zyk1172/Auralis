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
                    continuation.yield(.delta(chunk))
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
    private let pauseGate: CoordinatorIndexGate?

    init(pauseGate: CoordinatorIndexGate? = nil) {
        self.pauseGate = pauseGate
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
        let count = lock.withLock {
            completions += 1
            return completions
        }
        guard count > 1 else {
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
              let mode = input["mode"] as? String,
              let tracks = input["tracks"] as? [[String: Any]]
        else {
            throw AIProviderError.malformedResponse(detail: "测试分类输入无法解析", retryable: false)
        }
        lock.withLock {
            observedBatchSizes.append(tracks.count)
        }

        let items = tracks.compactMap { track -> [String: Any]? in
            guard let id = track["id"] as? String else { return nil }
            return [
                "id": id,
                "mode": mode,
                "moods": ["平静"],
                "scenes": ["深夜"],
                "energy": 3,
                "tempo": 2,
                "acousticness": 4,
                "danceability": 2,
                "vocals": ["器乐"],
                "textures": ["钢琴"],
                "styles": ["轻音乐"],
                "semanticTags": [["value": "夜行感", "confidence": 0.8]],
                "confidence": 0.9,
            ]
        }
        let response: [String: Any] = [
            "batchID": batchID,
            "revision": revision,
            "mode": mode,
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
    #expect(finalStatus.pendingSemanticTagTracks == 0)
    #expect(provider.completionCount == 4)
    #expect(provider.batchSizes == [8, 8, 4])
}
