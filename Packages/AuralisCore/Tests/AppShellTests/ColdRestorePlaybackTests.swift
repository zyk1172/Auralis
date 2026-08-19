@testable import AppShell
import Application
import Domain
import Foundation
import Testing

private actor ColdRestoreURLConnector: ServerConnecting {
    let result: ServerConnectionResult
    private(set) var refreshCount = 0

    init(result: ServerConnectionResult) {
        self.result = result
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }
    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        refreshCount += 1
        return URL(string: "https://music.example.test/stream/\(trackID.rawValue).flac")
    }

    func numberOfRefreshes() -> Int { refreshCount }
}

private actor ColdRestoreProbeEngine: PlaybackControlling {
    private var playbackState: PlaybackState = .idle
    private(set) var playedTrack: Track?

    func state() -> PlaybackState { playbackState }
    func play(track: Track) {
        playedTrack = track
        playbackState = .playing
    }
    func pause() { playbackState = .paused }
    func resume() { playbackState = .playing }
    func stop() { playbackState = .idle }

    func lastPlayedTrack() -> Track? { playedTrack }
}

@Test("冷恢复先显示目录且不初始化 Agent，第一次播放按需解析单曲 URL")
@MainActor
func coldRestoreFirstPlaybackResolvesURLOnDemand() async throws {
    let serverID: ServerID = "cold-playback"
    let account = ServerAccount(
        id: serverID,
        displayName: "Cold Playback",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        credentialReference: "credential"
    )
    let track = Track(
        id: "track", serverID: serverID, albumID: "album", artistID: "artist",
        title: "Track", artistName: "Artist", albumTitle: "Album", duration: 180,
        streamURL: nil
    )
    let result = ServerConnectionResult(
        account: account,
        capabilities: .init(),
        artists: [],
        albums: [],
        tracks: [track]
    )
    let connector = ColdRestoreURLConnector(result: result)
    let engine = ColdRestoreProbeEngine()
    let defaults = UserDefaults(suiteName: "cold-restore-playback-\(UUID().uuidString)")!
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cold-restore-playback-\(UUID().uuidString).sqlite")
    let model = AuralisAppModel(
        engine: engine,
        connector: connector,
        defaults: defaults,
        storeURL: storeURL
    )

    await model.restorePersistedLibrary()
    #expect(model.catalog.tracks.count == 1)
    #expect(model.catalog.tracks[0].streamURL == nil)
    #expect(model.agentCoordinatorWasInitialized == false)

    model.selectAndPlay(track)
    for _ in 0..<300 {
        if await engine.lastPlayedTrack() != nil { break }
        try? await Task.sleep(for: .milliseconds(10))
    }

    let played = try #require(await engine.lastPlayedTrack())
    #expect(played.streamURL?.absoluteString == "https://music.example.test/stream/track.flac")
    #expect(await connector.numberOfRefreshes() == 1)
}
