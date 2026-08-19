import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Test doubles

/// 可触发播放失败回调的探针引擎。
private actor FailureProbeEngine: PlaybackControlling {
    private var playbackState = PlaybackState.idle
    private var failureHandler: (@Sendable () -> Void)?
    private var preparedStarted: (@Sendable (Track) -> Void)?
    private(set) var playedIDs: [TrackID] = []
    private(set) var preparedIDs: [TrackID?] = []
    private(set) var hasFailureHandler = false

    func state() -> PlaybackState { playbackState }
    func play(track: Track) {
        playedIDs.append(track.id)
        playbackState = .playing
    }
    func pause() { playbackState = .paused }
    func resume() { playbackState = .playing }
    func stop() { playbackState = .idle }
    func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) {}
    func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) {
        failureHandler = handler
        hasFailureHandler = true
    }
    func prepareNext(track: Track?) { preparedIDs.append(track?.id) }
    func setPreparedTrackStartedHandler(_ handler: (@Sendable (Track) -> Void)?) {
        preparedStarted = handler
    }
    func simulateFailure() { failureHandler?() }
    func lastPlayedID() -> TrackID? { playedIDs.last }
    func playCount() -> Int { playedIDs.count }
}

/// 记录 refreshStreamURL 调用并返回 nil 的探针连接器（使重试快速耗尽）。
private actor CountingConnector: ServerConnecting {
    private(set) var refreshCount = 0

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.unsupportedResponse
    }
    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        refreshCount += 1
        return nil
    }
    func numberOfRefreshes() -> Int { refreshCount }
}

@Suite("Stream failure repeat policy + GlobalID async race")
struct PlaybackPolicyRegressionTests {
    @MainActor
    private func makeModel(
        engine: FailureProbeEngine,
        connector: CountingConnector,
        tracks: [Track],
        serverID: ServerID
    ) -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: serverID,
                    displayName: "Server",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "listener",
                    credentialReference: "test"
                ),
                artists: [], albums: [], tracks: tracks,
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            engine: engine,
            connector: connector,
            defaults: UserDefaults(suiteName: "policy-tests-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("policy-\(UUID().uuidString).sqlite")
        )
    }

    /// 与队列曲目同身份但无可用流地址的副本（模拟“正在播放的流已失效”）。
    private func deadURL(_ track: Track) -> Track {
        var copy = track
        copy.streamURL = nil
        return copy
    }

    @MainActor
    private func isFailed(_ model: AuralisAppModel) -> Bool {
        if case .failed = model.playbackState { return true }
        return false
    }

    private func track(_ id: String, serverID: ServerID = "server", streamURL: URL? = nil) -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: serverID,
            albumID: "album", artistID: "artist",
            title: id, artistName: "Artist", albumTitle: "Album", duration: 180,
            streamURL: streamURL ?? URL(string: "https://music.example.test/\(id).flac")
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("repeat off 队尾：流失败重试耗尽后停止，不切歌")
    @MainActor
    func streamFailureRepeatOffTailStops() async {
        let engine = FailureProbeEngine()
        let connector = CountingConnector()
        let tracks = [track("a"), track("b")]
        let model = makeModel(engine: engine, connector: connector, tracks: tracks, serverID: "server")
        model.playQueue(tracks)
        await waitUntil { await engine.playCount() == 1 } // 初始播放落定
        model.setRepeatMode(.off)
        model.currentTrack = deadURL(tracks[1]) // 队尾，流地址已失效
        await waitUntil { await engine.hasFailureHandler }

        await engine.simulateFailure()
        // 等待重试耗尽路径完成。
        await waitUntil { isFailed(model) }
        #expect(model.currentTrack.id.rawValue == "b")
        // 没有切到下一首：引擎仍停留在初始播放的 "a"，播放次数不变（无无限重试）。
        #expect(await engine.lastPlayedID()?.rawValue == "a")
        #expect(await engine.playCount() == 1)
    }

    @Test("repeat all 队尾：流失败重试耗尽后绕回第一首")
    @MainActor
    func streamFailureRepeatAllTailWraps() async {
        let engine = FailureProbeEngine()
        let connector = CountingConnector()
        let tracks = [track("a"), track("b"), track("c")]
        let model = makeModel(engine: engine, connector: connector, tracks: tracks, serverID: "server")
        model.playQueue(tracks)
        await waitUntil { await engine.playCount() == 1 }
        model.setRepeatMode(.all)
        model.currentTrack = deadURL(tracks[2]) // 队尾，流地址已失效
        await waitUntil { await engine.hasFailureHandler }

        await engine.simulateFailure()
        await waitUntil { await engine.playCount() == 2 }
        #expect(await engine.lastPlayedID()?.rawValue == "a")
        #expect(model.currentTrack.id.rawValue == "a")
    }

    @Test("repeat one：流失败重试耗尽后前进一次，不无限自旋")
    @MainActor
    func streamFailureRepeatOneAdvancesOnce() async {
        let engine = FailureProbeEngine()
        let connector = CountingConnector()
        let tracks = [track("a"), track("b")]
        let model = makeModel(engine: engine, connector: connector, tracks: tracks, serverID: "server")
        model.playQueue(tracks)
        await waitUntil { await engine.playCount() == 1 }
        model.setRepeatMode(.one)
        model.currentTrack = deadURL(tracks[0]) // 队中，流地址已失效
        await waitUntil { await engine.hasFailureHandler }

        await engine.simulateFailure()
        await waitUntil { await engine.playCount() == 2 }
        // 前进一次后不再继续触发（selectAndPlay 清零了 b 的重试预算）。
        #expect(await engine.lastPlayedID()?.rawValue == "b")
        #expect(model.currentTrack.id.rawValue == "b")
    }

    @Test("GlobalID：非活动服务器的曲目不会被活动连接器解析流地址")
    @MainActor
    func resolveDoesNotRefreshWrongServerTrack() async {
        let engine = FailureProbeEngine()
        let connector = CountingConnector()
        // 活动服务器是 server-b；currentTrack 来自 server-a（同 remoteID），streamURL 为空，
        // 若没有跨服务器守卫，刷新路径会去活动连接器要地址。
        let activeTracks = [track("x", serverID: "server-b")]
        let model = makeModel(engine: engine, connector: connector, tracks: activeTracks, serverID: "server-b")
        model.playQueue(activeTracks)
        await waitUntil { await engine.playCount() == 1 }
        model.currentTrack = track("x", serverID: "server-a", streamURL: nil)
        await waitUntil { await engine.hasFailureHandler }

        await engine.simulateFailure()
        // 给失败处理留出执行窗口；关键断言是活动连接器从未被请求旧服务器曲目的流地址。
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await connector.numberOfRefreshes() == 0)
    }
}
