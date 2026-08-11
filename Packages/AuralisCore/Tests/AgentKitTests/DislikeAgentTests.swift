import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import SecurityKit
import Testing

/// Agent 的 dislike 工具、自动推荐硬排除、旧 notInterested 迁移与 music_appreciate 歌词状态。
@Suite("Agent dislike & lyrics state")
struct DislikeAgentTests {
    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    private func track(serverID: ServerID, remoteID: String, title: String) -> Track {
        Track(
            id: TrackID(rawValue: remoteID),
            serverID: serverID,
            albumID: AlbumID(rawValue: "\(remoteID)-album"),
            artistID: ArtistID(rawValue: "\(remoteID)-artist"),
            title: title,
            artistName: "Artist \(serverID.rawValue)",
            albumTitle: "Album \(serverID.rawValue)",
            duration: 200,
            streamURL: URL(string: "https://music.test/\(remoteID).flac")
        )
    }

    private func seed(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
        guard let serverID = tracks.first?.serverID else { return }
        let session = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks(tracks, session: session)
        try await store.completeSync(session, completedAt: .now)
    }

    private func execute(
        _ name: String,
        _ args: [String: String],
        catalog: LocalCatalogStore,
        bridge: MockAgentBridge,
        serverID: ServerID?,
        allowsLyrics: Bool = false
    ) async -> ToolResult {
        await AgentToolkit.execute(
            ToolCall(name: name, arguments: args),
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            allowsLyrics: allowsLyrics
        )
    }

    @Test("preference_set_disliked sets and library_get_disliked reads back")
    func dislikeSetAndRead() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [track(serverID: serverID, remoteID: "t1", title: "Song A")])
        let bridge = MockAgentBridge(activeServerID: serverID)
        let gid = GlobalID(serverID: serverID, remoteID: "t1").description

        let set = await execute("preference_set_disliked", ["trackID": gid, "value": "true"], catalog: store, bridge: bridge, serverID: serverID)
        #expect(set.success)
        #expect((try await store.isDisliked(GlobalID(serverID: serverID, remoteID: "t1"))) == true)

        let read = await execute("library_get_disliked", ["limit": "10"], catalog: store, bridge: bridge, serverID: serverID)
        #expect(read.success)
        let cards = read.trackCards ?? []
        #expect(cards.map(\.globalID.remoteID).contains("t1"))

        let unset = await execute("preference_set_disliked", ["trackID": gid, "value": "false"], catalog: store, bridge: bridge, serverID: serverID)
        #expect(unset.success)
        #expect((try await store.isDisliked(GlobalID(serverID: serverID, remoteID: "t1"))) == false)
    }

    @Test("library_select_tracks / random / smart queue exclude disliked at candidate layer")
    func agentAutoRecommendationExcludesDisliked() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [
            track(serverID: serverID, remoteID: "t1", title: "Disliked Song"),
            track(serverID: serverID, remoteID: "t2", title: "Normal Song 1"),
            track(serverID: serverID, remoteID: "t3", title: "Normal Song 2"),
        ])
        try await store.setDisliked(GlobalID(serverID: serverID, remoteID: "t1"), value: true)
        let bridge = MockAgentBridge(activeServerID: serverID)

        // library_select_tracks（默认 popularityProxy，随机源也过滤）。
        let select = await execute("library_select_tracks", ["limit": "10", "sort": "random"], catalog: store, bridge: bridge, serverID: serverID)
        let selectCards = select.trackCards ?? []
        #expect(!selectCards.map(\.globalID.remoteID).contains("t1"))
        #expect(selectCards.count == 2)

        // library_get_random_songs
        let random = await execute("library_get_random_songs", ["limit": "10"], catalog: store, bridge: bridge, serverID: serverID)
        let randomCards = random.trackCards ?? []
        #expect(!randomCards.map(\.globalID.remoteID).contains("t1"))

        // smart_queue_generate
        let queue = await execute("smart_queue_generate", ["limit": "10"], catalog: store, bridge: bridge, serverID: serverID)
        let queueCards = queue.trackCards ?? []
        #expect(!queueCards.map(\.globalID.remoteID).contains("t1"))
    }

    @Test("cancelling dislike makes the song recommendable again")
    func cancelDislikeAllowsRecommendationAgain() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [
            track(serverID: serverID, remoteID: "t1", title: "Once Disliked"),
            track(serverID: serverID, remoteID: "t2", title: "Normal Song"),
        ])
        let bridge = MockAgentBridge(activeServerID: serverID)
        let gid = GlobalID(serverID: serverID, remoteID: "t1")

        try await store.setDisliked(gid, value: true)
        let excluded = await execute("library_select_tracks", ["limit": "10", "sort": "random"], catalog: store, bridge: bridge, serverID: serverID)
        #expect(!(excluded.trackCards ?? []).map(\.globalID.remoteID).contains("t1"))

        try await store.setDisliked(gid, value: false)
        let included = await execute("library_select_tracks", ["limit": "10", "sort": "random"], catalog: store, bridge: bridge, serverID: serverID)
        #expect((included.trackCards ?? []).map(\.globalID.remoteID).contains("t1"))
    }

    @Test("playlist still shows disliked tracks (browse is not filtered)")
    func playlistStillShowsDisliked() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [
            track(serverID: serverID, remoteID: "t1", title: "Disliked In Playlist"),
            track(serverID: serverID, remoteID: "t2", title: "Normal In Playlist"),
        ])
        try await store.setDisliked(GlobalID(serverID: serverID, remoteID: "t1"), value: true)
        try await store.upsertPlaylist(
            Playlist(
                id: "pl-1", serverID: serverID, name: "Test Playlist",
                trackIDs: [TrackID(rawValue: "t1"), TrackID(rawValue: "t2")]
            ),
            serverID: serverID
        )
        let detail = try await store.getPlaylist(GlobalID(serverID: serverID, remoteID: "pl-1"))
        let ids = detail?.tracks.map(\.id.rawValue) ?? []
        #expect(ids == ["t1", "t2"])
    }

    @Test("explicit play of disliked song is still allowed")
    func explicitPlayAllowsDisliked() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [track(serverID: serverID, remoteID: "t1", title: "Song A")])
        try await store.setDisliked(GlobalID(serverID: serverID, remoteID: "t1"), value: true)
        let bridge = MockAgentBridge(activeServerID: serverID)

        // 显式点播不被拒绝：playback_play_song 返回成功并交给 bridge。
        let play = await execute("playback_play_song", ["trackID": GlobalID(serverID: serverID, remoteID: "t1").description], catalog: store, bridge: bridge, serverID: serverID)
        #expect(play.success)
        #expect(bridge.playedTracks.map(\.remoteID).contains("t1"))
    }

    @Test("legacy notInterested feedback migrates to disliked_tracks once")
    func legacyNotInterestedMigration() async throws {
        let store = try makeStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preferences = PreferencesStore(fileURL: dir.appendingPathComponent("agent-preferences.json"))
        let gid1 = GlobalID(serverID: "s1", remoteID: "t1")
        let gid2 = GlobalID(serverID: "s1", remoteID: "t2")
        await preferences.recordFeedback(trackID: gid1, kind: .notInterested)
        await preferences.recordFeedback(trackID: gid1, kind: .notInterested)
        await preferences.recordFeedback(trackID: gid2, kind: .liked)

        let defaults = UserDefaults(suiteName: "dislike-migration-\(UUID().uuidString)")!
        defaults.removeObject(forKey: DislikedMigration.migrationCompletedDefaultsKey)
        let migrated = try await DislikedMigration.migrateNotInterestedFeedback(catalog: store, preferences: preferences, defaults: defaults)
        #expect(migrated == 2) // 两条 notInterested（含重复）→ 幂等写入 2 次
        #expect((try await store.isDisliked(gid1)) == true)
        #expect((try await store.isDisliked(gid2)) == false)

        // 二次调用不重复（幂等）。
        let second = try await DislikedMigration.migrateNotInterestedFeedback(catalog: store, preferences: preferences, defaults: defaults)
        #expect(second == 0)
    }

    @Test("music_appreciate reports real lyrics state and never fabricates")
    func musicAppreciateLyricsState() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [track(serverID: serverID, remoteID: "t1", title: "Song A")])
        let bridge = MockAgentBridge(activeServerID: serverID)

        // 有歌词 + 允许发送 → available
        bridge.lyricsStateValue = .available
        let r1 = await execute("music_appreciate", ["trackID": GlobalID(serverID: serverID, remoteID: "t1").description], catalog: store, bridge: bridge, serverID: serverID, allowsLyrics: true)
        #expect(r1.success)
        #expect(r1.facts["appreciation.lyrics"] == "available")

        // 有歌词 + 隐私不允许 → availableButPrivate（不泄露正文，也不谎报不可用）
        bridge.lyricsStateValue = .available
        let r2 = await execute("music_appreciate", ["trackID": GlobalID(serverID: serverID, remoteID: "t1").description], catalog: store, bridge: bridge, serverID: serverID, allowsLyrics: false)
        #expect(r2.facts["appreciation.lyrics"] == "availableButPrivate")

        // 已确认无歌词 → unavailable
        bridge.lyricsStateValue = .unavailable
        let r3 = await execute("music_appreciate", ["trackID": GlobalID(serverID: serverID, remoteID: "t1").description], catalog: store, bridge: bridge, serverID: serverID, allowsLyrics: true)
        #expect(r3.facts["appreciation.lyrics"] == "unavailable")

        // 尚未确认 → unknown（不是硬编码 unavailable）
        bridge.lyricsStateValue = .unknown
        let r4 = await execute("music_appreciate", ["trackID": GlobalID(serverID: serverID, remoteID: "t1").description], catalog: store, bridge: bridge, serverID: serverID, allowsLyrics: true)
        #expect(r4.facts["appreciation.lyrics"] == "unknown")

        // 私人数据包含“已标记不喜欢”
        try await store.setDisliked(GlobalID(serverID: serverID, remoteID: "t1"), value: true)
        let r5 = await execute("music_appreciate", ["trackID": GlobalID(serverID: serverID, remoteID: "t1").description], catalog: store, bridge: bridge, serverID: serverID, allowsLyrics: true)
        #expect(r5.success)
        #expect(r5.evidence.contains { $0.claim.contains("已标记不喜欢") } == true)
    }
}

private extension ToolResult {
    var trackCards: [TrackCard]? {
        if case let .trackCards(cards) = payload { return cards }
        return nil
    }
}
