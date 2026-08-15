@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Helpers

/// 还原持久化资料库的桩：restoreLastConnection 返回预置结果。
private struct RestoringConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }
}

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

private func makeResult(tracks: [Track]) -> ServerConnectionResult {
    ServerConnectionResult(
        account: makeAccount(),
        capabilities: .init(supportsStructuredLyrics: true),
        artists: [],
        albums: [],
        tracks: tracks,
        serverType: "test-server",
        serverVersion: "1.0"
    )
}

/// 每个测试独占一个本地目录库文件与 UserDefaults，避免并行测试互相污染。
@MainActor
private func makeIsolatedModel(tracks: [Track]) -> AuralisAppModel {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-sync-refresh-tests")
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let storeURL = dir.appendingPathComponent("catalog.sqlite")
    let defaults = UserDefaults(suiteName: "sync-refresh-\(UUID().uuidString)")!
    return AuralisAppModel(
        connector: RestoringConnector(result: makeResult(tracks: tracks)),
        defaults: defaults,
        storeURL: storeURL
    )
}

/// 把曲目写入本地 SQLite（模拟一次增量同步会话）。
/// 注意：OpenSubsonic 的「增量」实际是全量遍历，completeSync 对 full 与 incremental
/// 都会先删除该服务器的旧记录再写入 staged 集——因此每次 seed 必须包含该服务器的完整目录，
/// 否则未 stage 的旧记录会被正确删除（这是删除正确性契约，不是 bug）。
@MainActor
private func seedStore(
    _ model: AuralisAppModel,
    serverID: ServerID,
    tracks: [Track] = [],
    albums: [Album] = [],
    artists: [Artist] = []
) async throws {
    let store = model.catalogCoordinator.store
    let session = try await store.beginSync(serverID: serverID, mode: .incremental)
    if !artists.isEmpty { try await store.stageArtists(artists, session: session) }
    if !albums.isEmpty { try await store.stageAlbums(albums, session: session) }
    if !tracks.isEmpty { try await store.stageTracks(tracks, session: session) }
    try await store.completeSync(session, completedAt: .now)
}

/// 等待某个条件成立（用于 onSyncCompleted 触发的异步刷新）。
@MainActor
private func waitUntil(_ timeout: Int = 500, _ condition: () -> Bool) async {
    for _ in 0..<timeout {
        await Task.yield()
        if condition() { return }
    }
}

// MARK: - Tests

@Test("后台同步完成后：内存目录与首页「最近添加」立即包含新曲目")
@MainActor
func syncCompletionRefreshesCatalogAndRecentlyAdded() async throws {
    let serverID: ServerID = "test-server"
    let existing = [makeTrack(remoteID: "remote-1", title: "First"), makeTrack(remoteID: "remote-2", title: "Second")]
    let model = makeIsolatedModel(tracks: existing)
    await model.restorePersistedLibrary()
    // 等 apply() 触发的后台 registerAndSync（桩同步器 → 不产生同步完成事件）settle。
    await waitUntil { model.catalog.tracks.count == 2 }
    #expect(model.homeRecentlyAdded30DaysTracks.count == 2)

    // 模拟此前已完成的全量同步：现有曲目在本地 SQLite 中。
    try await seedStore(model, serverID: serverID, tracks: existing)

    // 模拟后台增量同步把新歌 / 专辑 / 艺术家写进本地 SQLite（页面不重启）。
    // 增量同步 staging 的是完整目录：第二次 seed 必须包含既有曲目 + 新曲目，
    // 否则 completeSync 的删除语义会正确移除未 stage 的旧记录。
    let newTrack = makeTrack(remoteID: "remote-new", title: "Fresh Download")
    let newAlbum = Album(id: "new-album", serverID: serverID, artistID: "new-artist", title: "New Album", artistName: "New Artist")
    let newArtist = Artist(id: "new-artist", serverID: serverID, name: "New Artist", albumCount: 1)
    try await seedStore(
        model, serverID: serverID,
        tracks: existing + [newTrack], albums: [newAlbum], artists: [newArtist]
    )

    // 同步完成回调（CatalogCoordinator.startSync 成功后的 onSyncCompleted 路径）：
    // 刷新 Agent 索引文件 + 重建内存目录。
    model.catalogCoordinator.onSyncCompleted?(serverID, 1)
    await waitUntil { model.catalog.tracks.contains { $0.id == newTrack.id } }

    // 内存目录含新曲目 / 新专辑 / 新艺术家，且原有曲目仍在（不是覆盖为空）。
    #expect(model.catalog.tracks.contains { $0.id == newTrack.id })
    #expect(model.catalog.tracks.count == 3)
    #expect(model.catalog.albums.contains { $0.id == newAlbum.id })
    #expect(model.catalog.artists.contains { $0.id == newArtist.id })
    // 首页「最近添加」包含新同步曲目，原有曲目仍在。
    #expect(model.homeRecentlyAdded30DaysTracks.contains { $0.id == newTrack.id })
    #expect(model.homeRecentlyAdded30DaysTracks.contains { $0.id == existing[0].id })
}

@Test("同步完成刷新保留正在播放上下文（currentTrack / queue / 进度）")
@MainActor
func syncCompletionRefreshPreservesPlaybackContext() async throws {
    let serverID: ServerID = "test-server"
    let existing = [makeTrack(remoteID: "remote-1", title: "First"), makeTrack(remoteID: "remote-2", title: "Second")]
    let model = makeIsolatedModel(tracks: existing)
    await model.restorePersistedLibrary()
    await waitUntil { model.catalog.tracks.count == 2 }

    // 建立明确的播放上下文：正在播放第一首，队列为现有曲目。
    model.currentTrack = existing[0]
    model.queue = existing
    model.playbackPosition = 30

    // 新曲目进入本地库（连同现有曲目一起，模拟增量同步后的完整库）。
    let newTrack = makeTrack(remoteID: "remote-new", title: "Fresh Download")
    try await seedStore(model, serverID: serverID, tracks: existing + [newTrack])

    await model.refreshCatalogFromStore(serverID: serverID)

    // 正在播放上下文原样保留：当前曲目 / 队列 / 进度没有被清空。
    #expect(model.currentTrack.id == existing[0].id)
    #expect(model.queue.map(\.id) == existing.map(\.id))
    #expect(model.playbackPosition == 30)
    // 新曲目进入内存目录与「最近添加」。
    #expect(model.catalog.tracks.contains { $0.id == newTrack.id })
    #expect(model.homeRecentlyAdded30DaysTracks.contains { $0.id == newTrack.id })
}
