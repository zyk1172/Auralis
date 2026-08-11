import Application
import AppShell
import Domain
import Foundation
import Testing

// 自包含桩：还原持久化资料库（connect 与 restoreLastConnection 均返回预置结果）。
private struct ReproConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }
}

private actor InertPlaybackEngine: PlaybackControlling {
    private var playbackState: PlaybackState = .idle

    func state() -> PlaybackState { playbackState }
    func play(track: Track) throws { playbackState = .playing }
    func pause() { playbackState = .paused }
    func resume() throws { playbackState = .playing }
    func stop() { playbackState = .idle }
}


/// 记录 scrobble 调用的桩，用于验证曲目播完会上报服务器播放计数。
private actor ScrobbleRecordingConnector: ServerConnecting {
    let result: ServerConnectionResult
    private var _scrobbles: [(trackID: TrackID, submission: Bool)] = []

    init(result: ServerConnectionResult) { self.result = result }

    var scrobbles: [(trackID: TrackID, submission: Bool)] { _scrobbles }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }

    func scrobble(trackID: TrackID, submission: Bool) async {
        _scrobbles.append((trackID, submission))
    }
}

private func reproTemporaryCatalogURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-tap-repro")
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("catalog.sqlite")
}

/// 用真实 AVFoundationPlaybackEngine + 带真实 streamURL 的曲目，从 @MainActor 调用 selectAndPlay。
/// 目的：区分崩溃发生在「逻辑层」还是「iOS 音频会话主线程断言层」。
@Test("selectAndPlay with real engine and streamURL does not crash (logic path)")
@MainActor
func selectAndPlayWithRealStreamURLDoesNotCrash() async throws {
    let track = Track(
        id: TrackID(rawValue: "remote-1"),
        serverID: "test-server",
        albumID: AlbumID(rawValue: "remote-1-album"),
        artistID: ArtistID(rawValue: "remote-1-artist"),
        title: "First",
        artistName: "Artist",
        albumTitle: "Album",
        duration: 200,
        streamURL: URL(string: "https://music.example.test/stream/remote-1.mp3")!
    )
    let result = ServerConnectionResult(
        account: ServerAccount(
            id: "test-server",
            displayName: "Test Library",
            baseURL: URL(string: "https://music.example.test")!,
            username: "listener",
            credentialReference: "cred"
        ),
        capabilities: .init(),
        artists: [],
        albums: [],
        tracks: [track],
        serverType: "test-server",
        serverVersion: "1.0"
    )
    let defaults = UserDefaults(suiteName: "tap-crash-repro-\(UUID().uuidString)")!
    let model = AuralisAppModel(
        connector: ReproConnector(result: result),
        defaults: defaults,
        storeURL: reproTemporaryCatalogURL()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    model.selectAndPlay(track)
    for _ in 0..<200 { await Task.yield() }
    #expect(model.currentTrack.id == track.id)
}

/// 回归测试：模拟用户「点击歌曲 + 加入队列」的真实操作流，确保播放队列（ForEach 的数据源）
/// 永远不含重复 id。重复 id 会让 SwiftUI 的 ForEach / List 在渲染时 fatalError（EXC_BREAKPOINT）闪退。
@Test("播放队列永远不会出现重复 id（点击歌曲 / 加入队列场景）")
@MainActor
func queueNeverContainsDuplicateIDs() async throws {
    let t1 = makeTrack(id: "dup-1")
    let t2 = makeTrack(id: "dup-2")
    let result = ServerConnectionResult(
        account: ServerAccount(
            id: "test-server",
            displayName: "Test Library",
            baseURL: URL(string: "https://music.example.test")!,
            username: "listener",
            credentialReference: "cred"
        ),
        capabilities: .init(),
        artists: [],
        albums: [],
        tracks: [t1, t2],
        serverType: "test-server",
        serverVersion: "1.0"
    )
    let defaults = UserDefaults(suiteName: "tap-dup-repro-\(UUID().uuidString)")!
    let model = AuralisAppModel(
        connector: ReproConnector(result: result),
        defaults: defaults,
        storeURL: reproTemporaryCatalogURL()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))

    // 用户先点了一首歌
    model.selectAndPlay(t1)
    // 然后又「加入队列」同一首（UI 里 LibraryView 直接 model.queue.append，不做去重）
    model.queue.append(t1)
    // 再多「加入队列」几次，制造重复
    model.queue.append(t2)
    model.queue.append(t1)

    let ids = model.queue.map { $0.id }
    let uniqueIDs = Set(ids)
    #expect(ids.count == uniqueIDs.count, "队列出现了重复 id，会导致 ForEach 渲染崩溃")

    // 再点一首歌也不应崩溃，且队列依旧唯一
    model.selectAndPlay(t2)
    for _ in 0..<100 { await Task.yield() }
    let ids2 = model.queue.map { $0.id }
    #expect(ids2.count == Set(ids2).count, "selectAndPlay 后队列出现了重复 id")
    #expect(model.currentTrack.id == t2.id)
}

/// 回归测试：Navidrome 只在 scrobble(submission=true) 时记录播放次数。
/// 曲目自然播完（handleTrackEnded）必须向当前服务器上报 scrobble，且仅当曲目属于活动服务器。
@Test("曲目播完会上报 scrobble(submission=true) 到活动服务器")
@MainActor
func trackEndReportsScrobbleToActiveServer() async throws {
    let track = makeTrack(id: "scrobble-1")
    let result = ServerConnectionResult(
        account: ServerAccount(
            id: "test-server",
            displayName: "Test Library",
            baseURL: URL(string: "https://music.example.test")!,
            username: "listener",
            credentialReference: "cred"
        ),
        capabilities: .init(),
        artists: [],
        albums: [],
        tracks: [track],
        serverType: "test-server",
        serverVersion: "1.0"
    )
    let connector = ScrobbleRecordingConnector(result: result)
    let defaults = UserDefaults(suiteName: "scrobble-repro-\(UUID().uuidString)")!
    let model = AuralisAppModel(
        connector: connector,
        defaults: defaults,
        storeURL: reproTemporaryCatalogURL()
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))

    model.currentTrack = track
    model.handleTrackEnded()

    for _ in 0..<100 { await Task.yield() }
    let recorded = await connector.scrobbles
    #expect(recorded.count == 1, "播完应上报一次 scrobble，实际 \(recorded.count) 次")
    #expect(recorded.first?.trackID == track.id)
    #expect(recorded.first?.submission == true)
}

/// 回归测试：播放页单个模式按钮必须能真正进入列表循环和单曲循环，
/// 不能只在图标上切换“顺序/随机”而永远到不了 RepeatMode.one。
@Test("播放模式按钮完整循环四种真实状态")
@MainActor
func playbackModeButtonCyclesThroughRepeatStates() {
    let defaults = UserDefaults(suiteName: "play-mode-repro-\(UUID().uuidString)")!
    let model = AuralisAppModel(
        engine: InertPlaybackEngine(),
        defaults: defaults,
        storeURL: reproTemporaryCatalogURL()
    )

    model.setShuffle(false)
    model.setRepeatMode(.off)
    #expect(model.playMode == .list)

    model.cyclePlayMode()
    #expect(model.playMode == .shuffle)
    #expect(model.isShuffled)
    #expect(model.repeatMode == .off)

    model.cyclePlayMode()
    #expect(model.playMode == .repeatAll)
    #expect(!model.isShuffled)
    #expect(model.repeatMode == .all)

    model.cyclePlayMode()
    #expect(model.playMode == .repeatOne)
    #expect(model.repeatMode == .one)

    model.cyclePlayMode()
    #expect(model.playMode == .list)
    #expect(model.repeatMode == .off)
}


private func makeTrack(id: String) -> Track {
    Track(
        id: TrackID(rawValue: id),
        serverID: "test-server",
        albumID: AlbumID(rawValue: "\(id)-album"),
        artistID: ArtistID(rawValue: "\(id)-artist"),
        title: id,
        artistName: "Artist",
        albumTitle: "Album",
        duration: 200,
        streamURL: URL(string: "https://music.example.test/stream/\(id).mp3")!
    )
}
