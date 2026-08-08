import AIKit
import AgentKit
import Application
import AppShell
import Domain
import Foundation
import LocalCatalog
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

    func deletePlaylist(playlistID: PlaylistID) async -> Bool {
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

// MARK: - Delete confirmation (integration through AgentCoordinator)

@Test("删除确认：拒绝后不执行删除，且资料库保持不变")
@MainActor
func deleteConfirmRejectedSkipsExecution() async throws {
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
    // 桩连接器未实现 makeSynchronizer，后台同步不会落地歌单；工具层依据本地目录库校验，
    // 因此这里直接把歌单写入本地库（唯一的插入，无并发写入冲突）。
    try await model.catalogCoordinator.store.upsertPlaylist(playlist, serverID: "test-server", isReadOnly: false)

    let provider = ScriptedAIProvider(actionBatches: ["ACTION: {\"tool\":\"deletePlaylist\",\"args\":{\"playlistID\":\"\(gid.description)\"}}"])
    coordinator.send("删除歌单", provider: provider)

    // 等待破坏性操作弹出待确认状态。
    for _ in 0..<500 {
        await Task.yield()
        if coordinator.pendingConfirmation != nil { break }
    }
    #expect(coordinator.pendingConfirmation != nil)
    #expect(coordinator.actionRecords.isEmpty)

    coordinator.rejectConfirmation()

    // 等待整轮运行结束。
    for _ in 0..<500 {
        await Task.yield()
        if !coordinator.isRunning { break }
    }
    #expect(!(await connector.deletedPlaylistIDs).contains(PlaylistID(rawValue: playlistRemoteID)))
    #expect(model.catalog.playlists.contains { $0.id.rawValue == playlistRemoteID })
}

@Test("删除确认：批准后执行删除并记入操作日志")
@MainActor
func deleteConfirmApprovedDeletesPlaylist() async throws {
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
        if coordinator.pendingConfirmation != nil { break }
    }
    #expect(coordinator.pendingConfirmation != nil)
    coordinator.approveConfirmation()

    for _ in 0..<500 {
        await Task.yield()
        if !coordinator.isRunning { break }
    }
    #expect((await connector.deletedPlaylistIDs).contains(PlaylistID(rawValue: playlistRemoteID)))
    #expect(!model.catalog.playlists.contains { $0.id.rawValue == playlistRemoteID })
    #expect(coordinator.actionRecords.contains { $0.toolName == "deletePlaylist" && $0.permission == .destructive })
}
