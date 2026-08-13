import AppShell
import Domain
import Foundation
import Testing

/// 播放模式（顺序 / 随机 / 列表循环 / 单曲循环）在模型层的完整行为验证。
/// 覆盖 handleTrackEnded 的自然播完分支、next()/previous() 的物理与循环语义，
/// 以及 canGoNext/canGoPrevious 的统一 capability。
@Suite("Playback mode behavior (repeat/shuffle/sequential)")
struct PlaybackModeBehaviorTests {
    // MARK: - 单曲循环（repeat-one）

    @Test("repeatOne：自然播完重播当前曲目")
    @MainActor
    func repeatOneReplaysCurrentTrack() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setRepeatMode(.one)
        model.currentTrack = track("t2") // 即使位于队尾也重播自身
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    @Test("repeatOne：位于队中自然播完仍重播自身，不跳下一首")
    @MainActor
    func repeatOneDoesNotAdvance() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setRepeatMode(.one)
        model.currentTrack = track("t2")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    // MARK: - 列表循环（repeat-all）

    @Test("repeatAll：队尾自然播完绕回第一首")
    @MainActor
    func repeatAllWrapsToFirstAtEnd() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setRepeatMode(.all)
        model.currentTrack = track("t3")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t1")
    }

    @Test("repeatAll：队中自然播完进入下一首")
    @MainActor
    func repeatAllAdvancesInMiddle() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setRepeatMode(.all)
        model.currentTrack = track("t1")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    @Test("repeatAll：单曲队列自然播完重播自身")
    @MainActor
    func repeatAllSingleTrackLoops() {
        let model = makeModel(tracks: [track("t1")])
        model.playQueue([track("t1")])
        model.setRepeatMode(.all)
        model.currentTrack = track("t1")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t1")
    }

    @Test("repeatAll：手动 next 到队尾绕回第一首")
    @MainActor
    func repeatAllManualNextWraps() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setRepeatMode(.all)
        model.currentTrack = track("t3")
        model.next()
        #expect(model.currentTrack.id.rawValue == "t1")
    }

    @Test("repeatAll：手动 previous 从队首绕回队尾最后一首")
    @MainActor
    func repeatAllManualPreviousWraps() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setRepeatMode(.all)
        model.currentTrack = track("t1")
        model.playbackPosition = 0
        model.previous()
        #expect(model.currentTrack.id.rawValue == "t3")
    }

    // MARK: - 顺序（repeat-off）

    @Test("repeatOff：队尾自然播完暂停，不切歌")
    @MainActor
    func repeatOffStopsAtEnd() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setRepeatMode(.off)
        model.currentTrack = track("t2")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t2") // 停留在最后一首
    }

    @Test("repeatOff：队中自然播完进入下一首")
    @MainActor
    func repeatOffAdvancesInMiddle() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setRepeatMode(.off)
        model.currentTrack = track("t1")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    @Test("repeatOff：队尾手动 next 不动作")
    @MainActor
    func repeatOffManualNextAtEndIsNoop() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setRepeatMode(.off)
        model.currentTrack = track("t2")
        model.next()
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    // MARK: - 随机（shuffle）

    @Test("shuffle：自然播完从队列随机选非当前曲目")
    @MainActor
    func shuffleNaturalEndPicksAnotherInQueue() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3"), track("t4")])
        model.playQueue([track("t1"), track("t2"), track("t3"), track("t4")])
        model.setShuffle(true)
        model.setRepeatMode(.off)
        model.currentTrack = track("t3")
        model.handleTrackEnded()
        let current = model.currentTrack.id.rawValue
        #expect(current != "t3")
        #expect(Set(model.queue.map(\.id.rawValue)).contains(current))
    }

    @Test("shuffle：手动 next 从队列随机选非当前曲目")
    @MainActor
    func shuffleManualNextPicksAnotherInQueue() {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3"), track("t4")])
        model.playQueue([track("t1"), track("t2"), track("t3"), track("t4")])
        model.setShuffle(true)
        model.currentTrack = track("t4") // 物理队尾
        model.next()
        let current = model.currentTrack.id.rawValue
        #expect(current != "t4")
        #expect(Set(model.queue.map(\.id.rawValue)).contains(current))
    }

    @Test("shuffle：单曲队列自然播完不随机（保持当前并暂停语义安全）")
    @MainActor
    func shuffleSingleTrackIsSafe() {
        let model = makeModel(tracks: [track("t1")])
        model.playQueue([track("t1")])
        model.setShuffle(true)
        model.setRepeatMode(.off)
        model.currentTrack = track("t1")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t1")
    }

    // MARK: - 随机 + 循环开关（本轮修复：随机不再无视“不循环”）

    @Test("shuffle+repeatOff：一轮随机播完自然结束时暂停，不继续隐式循环")
    @MainActor
    func shuffleOffStopsAfterOnePass() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setShuffle(true)
        model.setRepeatMode(.off)
        // 两首队列：t1 播（计入本轮）→ 结束随机到 t2；t2 结束 → 池空 → 停在本曲。
        model.currentTrack = track("t1")
        model.handleTrackEnded()
        #expect(model.currentTrack.id.rawValue == "t2")
        model.handleTrackEnded()
        // 一轮已播完（t1、t2 都已计入），不再随机，停留在 t2。
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    @Test("shuffle+repeatAll：一轮播完重置并继续随机，不停")
    @MainActor
    func shuffleAllKeepsGoingAfterPass() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setShuffle(true)
        model.setRepeatMode(.all)
        model.currentTrack = track("t1")
        model.handleTrackEnded() // → t2（本轮还剩 t2）
        #expect(model.currentTrack.id.rawValue == "t2")
        model.handleTrackEnded() // 池空 → 重置 → 随机选 t1
        #expect(model.currentTrack.id.rawValue == "t1")
    }

    @Test("shuffle+repeatOff：池播完后 canGoNext 为 false，不再可点下一首")
    @MainActor
    func shuffleOffCanGoNextFalseWhenPoolExhausted() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setShuffle(true)
        model.setRepeatMode(.off)
        model.currentTrack = track("t1")
        #expect(model.canGoNext == true) // t2 尚未播放
        model.handleTrackEnded() // → t2，本轮两首都已播放
        #expect(model.currentTrack.id.rawValue == "t2")
        #expect(model.canGoNext == false) // 池空：不可再下一首
        model.handleTrackEnded() // 池空：停在本曲
        #expect(model.currentTrack.id.rawValue == "t2")
        #expect(model.canGoNext == false)
    }

    // MARK: - 列表循环无缝路径（handlePreparedTrackStarted）

    @Test("repeatAll：无缝预载到队尾绕回第一首时，模型跟随到第一首")
    @MainActor
    func repeatAllSeamlessWrapFollowsPrepared() async {
        let engine = RepeatProbeEngine()
        let tracks = [track("t1"), track("t2")]
        let model = makeModel(tracks: tracks, engine: engine)
        model.playQueue(tracks)
        model.setRepeatMode(.all)
        await waitUntil { await engine.hasPreparedStartedHandler }
        model.currentTrack = track("t2") // 队尾：预载项应为其下一首 = 第一首
        await engine.simulatePreparedStart(tracks[0])
        #expect(model.currentTrack.id.rawValue == "t1")
    }

    @Test("repeatOff：无缝预载到队尾后无下一首时暂停，不绕回")
    @MainActor
    func repeatOffSeamlessEndPauses() async {
        let engine = RepeatProbeEngine()
        let tracks = [track("t1"), track("t2")]
        let model = makeModel(tracks: tracks, engine: engine)
        model.playQueue(tracks)
        model.setRepeatMode(.off)
        await waitUntil { await engine.hasPreparedStartedHandler }
        model.currentTrack = track("t2")
        await engine.simulatePreparedStart(tracks[0])
        // 顺序 + 不循环：队尾没有下一首，暂停并停留在原曲。
        #expect(model.currentTrack.id.rawValue == "t2")
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 单曲循环防竞态（旧预载项不得带跑）

    @Test("repeatOne：即使引擎带入了旧预载项，也重播当前曲目而非被带跑")
    @MainActor
    func repeatOneRejectsStalePreparedAdvance() async {
        let engine = RepeatProbeEngine()
        let tracks = [track("t1"), track("t2")]
        let model = makeModel(tracks: tracks, engine: engine)
        model.playQueue(tracks)
        model.setRepeatMode(.one)
        model.currentTrack = track("t1")
        // 模拟引擎因旧预载项自动推进到 t2（模式切换竞态）。
        await engine.simulatePreparedStart(tracks[1])
        #expect(model.currentTrack.id.rawValue == "t1") // 仍回到当前曲目
    }

    // MARK: - capability 统一

    @Test("capability：shuffle 物理队尾、池中仍有未播放曲目时 canGoNext 为 true")
    @MainActor
    func shuffleCanGoNextAtEnd() {
        // playQueue 已把 t1 计入本轮；当前人为设为物理队尾 t3，池中仍有 t2 未播放。
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setShuffle(true)
        model.currentTrack = track("t3")
        #expect(model.hasNext == false)
        #expect(model.canGoNext == true) // shuffle 仍可随机选未播放曲目
    }

    @Test("capability：repeatAll 物理队尾 canGoNext 为 true")
    @MainActor
    func repeatAllCanGoNextAtEnd() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setRepeatMode(.all)
        model.currentTrack = track("t2")
        #expect(model.canGoNext == true)
    }

    @Test("capability：repeatOff 非 shuffle 物理队尾 canGoNext 为 false")
    @MainActor
    func repeatOffCanGoNextFalseAtEnd() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setRepeatMode(.off)
        model.setShuffle(false)
        model.currentTrack = track("t2")
        #expect(model.canGoNext == false)
    }

    @Test("capability：repeatOne 有物理下一首时 canGoNext 为 true")
    @MainActor
    func repeatOneCanGoNextWhenNextExists() {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.setRepeatMode(.one)
        model.currentTrack = track("t1")
        #expect(model.hasNext == true)
        #expect(model.canGoNext == true)
    }

    // MARK: - helpers

    @MainActor
    private func makeModel(
        tracks: [Track],
        engine: (any PlaybackControlling)? = nil
    ) -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: "server",
                    displayName: "Server",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "listener",
                    credentialReference: "test"
                ),
                artists: [], albums: [], tracks: tracks,
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            engine: engine ?? PlaybackModeProbeEngine(),
            defaults: UserDefaults(suiteName: "playback-mode-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("playback-mode-\(UUID().uuidString).sqlite")
        )
    }

    private func track(_ id: String) -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: "server",
            albumID: "album", artistID: "artist",
            title: id, artistName: "Artist", albumTitle: "Album", duration: 180,
            streamURL: URL(string: "https://music.example.test/\(id).flac")
        )
    }
}

/// 最小无副作用引擎：selectAndPlay 的 Task 调用 engine.play 时只记录，不真正起播。
private actor PlaybackModeProbeEngine: PlaybackControlling {
    private var playbackState = PlaybackState.idle
    func state() -> PlaybackState { playbackState }
    func play(track: Track) { playbackState = .playing }
    func pause() { playbackState = .paused }
    func resume() { playbackState = .playing }
    func stop() { playbackState = .idle }
}

/// 可模拟“预载下一首已自动推进”的最小引擎。
private actor RepeatProbeEngine: PlaybackControlling {
    private var playbackState = PlaybackState.idle
    private var preparedStarted: (@Sendable (Track) -> Void)?
    private(set) var hasPreparedStartedHandler = false
    func state() -> PlaybackState { playbackState }
    func play(track: Track) { playbackState = .playing }
    func pause() { playbackState = .paused }
    func resume() { playbackState = .playing }
    func stop() { playbackState = .idle }
    func setPreparedTrackStartedHandler(_ handler: (@Sendable (Track) -> Void)?) {
        preparedStarted = handler
        hasPreparedStartedHandler = handler != nil
    }
    func simulatePreparedStart(_ track: Track) {
        preparedStarted?(track)
    }
}
