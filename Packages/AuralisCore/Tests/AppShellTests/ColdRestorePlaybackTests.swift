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

// MARK: - R05 收尾：shuffle occurrence 与 Handoff 恢复 index shift

@MainActor
private func makePlaybackModel(
    tracks: [Track],
    suite: String
) -> (model: AuralisAppModel, connector: ColdRestoreURLConnector, engine: ColdRestoreProbeEngine) {
    let serverID = tracks.first?.serverID ?? "test-server"
    let account = ServerAccount(
        id: serverID,
        displayName: "Test",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        credentialReference: "credential"
    )
    let result = ServerConnectionResult(
        account: account,
        capabilities: .init(),
        artists: [],
        albums: [],
        tracks: tracks
    )
    let connector = ColdRestoreURLConnector(result: result)
    let engine = ColdRestoreProbeEngine()
    let defaults = UserDefaults(suiteName: "\(suite)-\(UUID().uuidString)")!
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(suite)-\(UUID().uuidString).sqlite")
    let model = AuralisAppModel(
        engine: engine,
        connector: connector,
        defaults: defaults,
        storeURL: storeURL
    )
    return (model, connector, engine)
}

@Test("R05：shuffle 下重复歌曲是两个独立 occurrence——[A,B,A,C] 一轮内 4 个队列项都播到")
@MainActor
func shufflePlaysEveryDuplicateOccurrence() async throws {
    let serverID: ServerID = "shuffle-occurrence"
    let trackA = Track(id: "A", serverID: serverID, albumID: "al", artistID: "ar", title: "A", artistName: "Artist", albumTitle: "Album", duration: 180, streamURL: nil)
    let trackB = Track(id: "B", serverID: serverID, albumID: "al", artistID: "ar", title: "B", artistName: "Artist", albumTitle: "Album", duration: 180, streamURL: nil)
    let trackC = Track(id: "C", serverID: serverID, albumID: "al", artistID: "ar", title: "C", artistName: "Artist", albumTitle: "Album", duration: 180, streamURL: nil)
    let made = makePlaybackModel(tracks: [trackA, trackB, trackC], suite: "shuffle-occurrence")
    let model = made.model
    await model.restorePersistedLibrary()

    // 队列里 A 出现两次（两个独立 occurrence）。
    model.queue = [trackA, trackB, trackA, trackC]
    model.setShuffle(true)
    model.setRepeatMode(.off)
    model.playQueueEntry(id: model.queueEntries[0].id)

    var playedEntryIDs = Set<UUID>()
    var steps = 0
    while model.canGoNext && steps < 20 {
        if let entryID = model.queueStore.currentEntryID { playedEntryIDs.insert(entryID) }
        model.next()
        steps += 1
    }
    if let entryID = model.queueStore.currentEntryID { playedEntryIDs.insert(entryID) }

    #expect(playedEntryIDs.count == 4,
            "两个 A occurrence 都是独立随机项，本轮应全部播到（按歌曲去重的旧行为最多 3 个）")
    #expect(steps < 20, "随机一轮应在有限步内结束")
}

@Test("R05：Handoff 恢复时队列缺失项目导致的下标错位被修正——[A,X,A,C] index2 → [A,A,C] index1")
@MainActor
func handoffRestoreHandlesMissingQueueItems() async throws {
    let serverID: ServerID = "handoff-shift"
    let trackA = Track(id: "A", serverID: serverID, albumID: "al", artistID: "ar", title: "A", artistName: "Artist", albumTitle: "Album", duration: 180, streamURL: nil)
    let trackB = Track(id: "B", serverID: serverID, albumID: "al", artistID: "ar", title: "B", artistName: "Artist", albumTitle: "Album", duration: 180, streamURL: nil)
    let trackC = Track(id: "C", serverID: serverID, albumID: "al", artistID: "ar", title: "C", artistName: "Artist", albumTitle: "Album", duration: 180, streamURL: nil)
    let made = makePlaybackModel(tracks: [trackA, trackB, trackC], suite: "handoff-shift")
    let model = made.model
    await model.restorePersistedLibrary()
    #expect(model.catalog.tracks.count == 3)

    // 源队列 [A, X, A, C]（X 在接收端曲库不存在），当前 index 2 = 第二个 A。
    let activity = NSUserActivity(activityType: "com.auralis.player.playback")
    activity.userInfo = [
        "serverID": serverID.rawValue,
        "currentTrackID": "A",
        "queueTrackIDs": ["A", "X", "A", "C"],
        "position": 0.0,
        "currentQueueIndex": 2,
    ]
    model.handleHandoffActivity(activity)

    // 恢复队列折叠为 [A, A, C]；当前项必须映射到 index 1（第二个 A），
    // 而不是原始 index 2（那会是 C）。
    #expect(model.queue.map(\.id.rawValue) == ["A", "A", "C"])
    #expect(model.currentQueueIndex == 1, "缺失项跳过后下标要重新映射")
    #expect(model.currentTrack.id.rawValue == "A")
    model.next()
    #expect(model.currentTrack.id.rawValue == "C", "恢复后 next() 应走到 C，而不是还在 A 上")
}
