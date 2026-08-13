import AppShell
import Domain
import Foundation
import Testing

private actor GaplessProbeEngine: PlaybackControlling {
    private var playbackState = PlaybackState.idle
    private var ended: (@Sendable () -> Void)?
    private var preparedStarted: (@Sendable (Track) -> Void)?
    private(set) var playedIDs: [TrackID] = []
    private(set) var preparedIDs: [TrackID?] = []

    func state() -> PlaybackState { playbackState }
    func play(track: Track) {
        playedIDs.append(track.id)
        playbackState = .playing
    }
    func pause() { playbackState = .paused }
    func resume() { playbackState = .playing }
    func stop() { playbackState = .idle }
    func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) { ended = handler }
    func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) {}
    func prepareNext(track: Track?) { preparedIDs.append(track?.id) }
    func setPreparedTrackStartedHandler(_ handler: (@Sendable (Track) -> Void)?) {
        preparedStarted = handler
    }
    func simulatePreparedStart(_ track: Track) { preparedStarted?(track) }
    func lastPreparedID() -> TrackID? { preparedIDs.last ?? nil }
}

@Suite("Seamless next-item preparation")
struct GaplessPreparationTests {
    @Test("Linear queue prepares the next stream")
    @MainActor
    func preparesNext() async {
        let engine = GaplessProbeEngine()
        let tracks = [track("one"), track("two")]
        let model = makeModel(engine: engine, tracks: tracks)
        model.playQueue(tracks)
        await waitUntil { await engine.lastPreparedID() == tracks[1].id }
        #expect(await engine.lastPreparedID() == tracks[1].id)
    }

    @Test("Shuffle and repeat-one invalidate deterministic preparation")
    @MainActor
    func modeInvalidation() async {
        let engine = GaplessProbeEngine()
        let tracks = [track("one"), track("two")]
        let model = makeModel(engine: engine, tracks: tracks)
        model.playQueue(tracks)
        await waitUntil { await engine.lastPreparedID() == tracks[1].id }

        model.setShuffle(true)
        await waitUntil { await engine.lastPreparedID() == nil }
        #expect(await engine.lastPreparedID() == nil)

        model.setShuffle(false)
        model.setRepeatMode(.one)
        await waitUntil { await engine.lastPreparedID() == nil }
        #expect(await engine.lastPreparedID() == nil)
    }

    @Test("Prepared transition updates the model without a second play call")
    @MainActor
    func continuousTransition() async {
        let engine = GaplessProbeEngine()
        let tracks = [track("one"), track("two"), track("three")]
        let model = makeModel(engine: engine, tracks: tracks)
        model.playQueue(tracks)
        await waitUntil { await engine.lastPreparedID() == tracks[1].id }

        await engine.simulatePreparedStart(tracks[1])
        await waitUntilMainActor { model.currentTrack.id == tracks[1].id }
        #expect(model.currentTrack.id == tracks[1].id)
        #expect(await engine.playedIDs == [tracks[0].id])
        await waitUntil { await engine.lastPreparedID() == tracks[2].id }
        #expect(await engine.lastPreparedID() == tracks[2].id)
    }

    @Test("Sleep-after-current-track prevents preloading")
    @MainActor
    func sleepTimerInvalidation() async {
        let engine = GaplessProbeEngine()
        let tracks = [track("one"), track("two")]
        let model = makeModel(engine: engine, tracks: tracks)
        model.playQueue(tracks)
        await waitUntil { await engine.lastPreparedID() == tracks[1].id }
        model.setSleepTimer(mode: .afterCurrentTrack)
        await waitUntil { await engine.lastPreparedID() == nil }
        #expect(await engine.lastPreparedID() == nil)
    }

    @MainActor
    private func makeModel(engine: GaplessProbeEngine, tracks: [Track]) -> AuralisAppModel {
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
            engine: engine,
            defaults: UserDefaults(suiteName: "gapless-tests-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("gapless-\(UUID().uuidString).sqlite")
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

    /// 并行测试负载较高时，@MainActor 上的异步 prep 可能超过 1s；放宽到 20s 避免偶发超时。
    private func waitUntil(
        attempts: Int = 2000,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func waitUntilMainActor(
        attempts: Int = 2000,
        condition: () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
