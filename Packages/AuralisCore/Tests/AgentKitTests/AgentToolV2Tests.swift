import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Test doubles

/// 固定返回值的 AgentSystemService，用于验证系统工具执行与路由。
private final class StubSystemService: AgentSystemService, @unchecked Sendable {
    func appContext() async -> AgentAppContext {
        AgentAppContext(page: "home", serverName: "Test Server", currentTrackTitle: "Song A",
                        playbackState: "playing", queueCount: 3, isShuffled: false, repeatMode: "off",
                        networkType: "wifi", isOffline: false, hasPendingTask: false)
    }
    func openPage(_ page: String) async -> Bool { true }
    func featureStatus() async -> AgentFeatureStatus { AgentFeatureStatus(backgroundAudioEnabled: true, siriEnabled: true) }
    func listServers() async -> [AgentServerInfo] { [AgentServerInfo(id: "srv", displayName: "Test", host: "music.example")] }
    func currentServer() async -> AgentServerInfo? { AgentServerInfo(id: "srv", displayName: "Test", host: "music.example", serverType: "navidrome", serverVersion: "0.54") }
    func testServerConnection() async -> AgentConnectionTestResult { AgentConnectionTestResult(success: true, latencyMs: 12, serverType: "navidrome", serverVersion: "0.54") }
    func serverCapabilities() async -> AgentCapabilitiesSummary { AgentCapabilitiesSummary(supportsStructuredLyrics: true, supportsSonicSimilarity: true) }
    func syncStatus() async -> AgentSyncStatus { AgentSyncStatus(isRunning: false, mode: "incremental", lastCompletedAt: .now, lastProcessedCount: 120, isStale: false) }
    func networkStatus() async -> AgentNetworkStatus { AgentNetworkStatus(networkType: "wifi", isOffline: false, isServerReachable: true, isConstrained: false) }
    func audioRoute() async -> AgentAudioRoute { AgentAudioRoute(outputName: "耳机", outputType: "headphones") }
    func storageStatus() async -> AgentStorageStatus { AgentStorageStatus(offlineAudioBytes: 0, offlineAudioCount: 3, freeBytes: 1024 * 1024 * 1024) }
    func lyrics(for trackID: TrackID) async -> AgentLyricsResult { AgentLyricsResult(hasLyrics: true, isSynced: true, lineCount: 40) }
    func downloadOffline(trackID: TrackID) async -> Bool { true }
    func cacheStatus() async -> AgentCacheStatus { AgentCacheStatus(offlineAudioBytes: 1024 * 1024, offlineAudioCount: 3) }
    func nowPlayingStatus() async -> AgentNowPlayingStatus { AgentNowPlayingStatus(title: "A", artist: "B", consistentWithApp: true) }
    func recentlyAdded(days: Int, limit: Int) async -> [TrackCard] { [] }
    func mostPlayed(limit: Int) async -> [TrackCard] { [] }
    func brokenArtwork(limit: Int) async -> [String] { [] }
    func staleCache(limit: Int) async -> [String] { [] }
    func topItems(kind: String, limit: Int) async -> [AgentTopItem] { [AgentTopItem(name: "周杰伦", value: 8)] }
    func formatDistribution() async -> [AgentFormatCount] { [AgentFormatCount(format: "flac", count: 3)] }
    func recommendByMood(_ mood: String, limit: Int) async -> AgentRecommendationResult {
        AgentRecommendationResult(mood: mood, tracks: [])
    }
    func recommendByConstraints(_ constraints: AgentRecommendationConstraints) async -> AgentRecommendationResult {
        AgentRecommendationResult(mood: "组合约束", tracks: [])
    }
    func diagnosticsReport() async -> String { "Auralis 诊断报告（脱敏）\n- 状态：idle" }
    func listeningSummary() async -> AgentListeningSummary { AgentListeningSummary(totalPlays: 10, uniqueTracks: 4, totalFavorites: 2) }
    func playbackDiagnostics() async -> AgentPlaybackDiagnostics { AgentPlaybackDiagnostics(state: "playing", mediaSource: "server", audioSessionActive: true, queueValid: true, isPlaying: true) }
    func recentErrors(limit: Int) async -> [AgentErrorRecord] { [] }
}

// MARK: - Helpers

private func makeV2Store() throws -> LocalCatalogStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
}

private func makeV2Track(serverID: ServerID, remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID), serverID: serverID,
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title, artistName: "Artist \(serverID.rawValue)",
        albumTitle: "Album \(serverID.rawValue)", duration: 200
    )
}

private func seedV2(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

// MARK: - v2 工具执行

@Test("v2 playback_play_song executes through bridge")
func v2PlaySong() async throws {
    let store = try makeV2Store()
    try await seedV2(store, [makeV2Track(serverID: "test-server", remoteID: "v2-1", title: "V2Song")])
    let bridge = MockAgentBridge(activeServerID: "test-server")
    let gid = GlobalID(serverID: "test-server", remoteID: "v2-1")
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "playback_play_song", arguments: ["trackID": gid.description]),
        bridge: bridge, catalog: store, serverID: "test-server", systemService: nil
    )
    #expect(result.success)
    #expect(await bridge.playedTracks.contains(gid))
}

@Test("v2 queue_play_next inserts after current")
func v2QueuePlayNext() async throws {
    let store = try makeV2Store()
    try await seedV2(store, [makeV2Track(serverID: "test-server", remoteID: "v2-1", title: "V2Song")])
    let bridge = MockAgentBridge(activeServerID: "test-server")
    let gid = GlobalID(serverID: "test-server", remoteID: "v2-1")
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "queue_play_next", arguments: ["trackID": gid.description]),
        bridge: bridge, catalog: store, serverID: "test-server", systemService: nil
    )
    #expect(result.success)
}

@Test("v2 favorite_set toggles song favorite")
func v2FavoriteSet() async throws {
    let store = try makeV2Store()
    try await seedV2(store, [makeV2Track(serverID: "test-server", remoteID: "v2-1", title: "V2Song")])
    let bridge = MockAgentBridge(activeServerID: "test-server")
    let gid = GlobalID(serverID: "test-server", remoteID: "v2-1")
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "favorite_set", arguments: ["targetType": "song", "targetID": gid.description, "value": "true"]),
        bridge: bridge, catalog: store, serverID: "test-server", systemService: nil
    )
    #expect(result.success)
    #expect(await bridge.likedTracks.contains(gid))
}

@Test("v2 playback_set_repeat parses mode")
func v2SetRepeat() async throws {
    let store = try makeV2Store()
    let bridge = MockAgentBridge()
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "playback_set_repeat", arguments: ["mode": "one"]),
        bridge: bridge, catalog: store, serverID: nil, systemService: nil
    )
    #expect(result.success)
}

@Test("v2 library_search returns track cards")
func v2LibrarySearch() async throws {
    let store = try makeV2Store()
    try await seedV2(store, [makeV2Track(serverID: "test-server", remoteID: "v2-1", title: "七里香")])
    let bridge = MockAgentBridge(activeServerID: "test-server")
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "library_search", arguments: ["query": "七里香", "kind": "song"]),
        bridge: bridge, catalog: store, serverID: "test-server", systemService: nil
    )
    #expect(result.success)
    if case let .trackCards(cards) = result.payload {
        #expect(cards.first?.title == "七里香")
    } else {
        Issue.record("expected track cards payload")
    }
}

// MARK: - 系统服务工具

@Test("v2 app_get_context uses system service")
func v2AppContext() async throws {
    let store = try makeV2Store()
    let bridge = MockAgentBridge()
    let system = StubSystemService()
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "app_get_context", arguments: [:]),
        bridge: bridge, catalog: store, serverID: nil, systemService: system
    )
    #expect(result.success)
    #expect(result.summary.contains("Test Server"))
}

@Test("v2 server_test_connection reports real result")
func v2ServerTestConnection() async throws {
    let store = try makeV2Store()
    let bridge = MockAgentBridge()
    let system = StubSystemService()
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "server_test_connection", arguments: [:]),
        bridge: bridge, catalog: store, serverID: nil, systemService: system
    )
    #expect(result.success)
    #expect(result.summary.contains("连接成功"))
    #expect(!result.summary.contains("token"))
    #expect(!result.summary.contains("http"))
}

@Test("v2 system tool without service returns unavailable")
func v2SystemToolWithoutService() async throws {
    let store = try makeV2Store()
    let bridge = MockAgentBridge()
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "cache_get_status", arguments: [:]),
        bridge: bridge, catalog: store, serverID: nil, systemService: nil
    )
    #expect(result.success == false)
    #expect(result.summary.contains("系统服务不可用"))
}

@Test("v2 diagnostics_playback returns diagnostics")
func v2Diagnostics() async throws {
    let store = try makeV2Store()
    let bridge = MockAgentBridge()
    let system = StubSystemService()
    let result = await AgentToolkit.executeV2(
        ToolCall(name: "diagnostics_playback", arguments: [:]),
        bridge: bridge, catalog: store, serverID: nil, systemService: system
    )
    #expect(result.success)
    #expect(result.summary.contains("状态"))
}

// MARK: - 队列 v2 工具

@Suite("队列 v2 工具")
struct QueueV2Tests {
    @Test("queue_replace / queue_clear 需要确认且真实执行")
    func confirmationAndExecution() async throws {
        let store = try makeV2Store()
        let tracks = [
            makeV2Track(serverID: "s", remoteID: "1", title: "A"),
            makeV2Track(serverID: "s", remoteID: "2", title: "B"),
        ]
        try await seedV2(store, tracks)
        let bridge = MockAgentBridge(activeServerID: "s")

        #expect(AgentToolRegistry.descriptor(for: "queue_replace")?.requiresConfirmation == true)
        #expect(AgentToolRegistry.descriptor(for: "queue_clear")?.requiresConfirmation == true)

        let clear = await AgentToolkit.executeV2(
            ToolCall(name: "queue_clear", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(clear.success)

        let replace = await AgentToolkit.executeV2(
            ToolCall(name: "queue_replace", arguments: ["trackIDs": "s:1,s:2"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(replace.success)
    }

    @Test("queue_save_as_playlist 调用 bridge 创建歌单")
    func saveAsPlaylist() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "A")])
        let bridge = MockAgentBridge(activeServerID: "s")

        let result = await AgentToolkit.executeV2(
            ToolCall(name: "queue_save_as_playlist", arguments: ["name": "我的队列"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(bridge.createdPlaylistNames.contains("我的队列"))
    }

    @Test("queue_move 调用 bridge 调整顺序")
    func moveQueue() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "A")])
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "queue_move", arguments: ["from": "0", "to": "1"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("调整"))
    }

    @Test("queue_shuffle_remaining 调用 bridge")
    func shuffleRemaining() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "A")])
        let bridge = MockAgentBridge(activeServerID: "s")

        let result = await AgentToolkit.executeV2(
            ToolCall(name: "queue_shuffle_remaining", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
    }
}

@Suite("推荐工具")
struct RecommendToolTests {
    @Test("recommend_by_mood 走系统服务并返回结果")
    func recommendByMood() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()

        let result = await AgentToolkit.executeV2(
            ToolCall(name: "recommend_by_mood", arguments: ["mood": "深夜", "limit": "5"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("深夜"))
    }

    @Test("recommend_by_mood 缺少 mood 参数返回参数错误")
    func recommendByMoodRequiresMood() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()

        let result = await AgentToolkit.executeV2(
            ToolCall(name: "recommend_by_mood", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(!result.success)
    }
}

@Suite("睡眠定时 / 约束推荐 / 智能队列 / 诊断导出")
struct AgentP1GTests {
    @Test("playback_set_sleep_timer 调用 bridge 并返回成功")
    func setSleepTimer() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "playback_set_sleep_timer", arguments: ["mode": "afterMinutes", "minutes": "30"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
    }

    @Test("playback_get_sleep_timer 返回状态")
    func getSleepTimer() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "playback_get_sleep_timer", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("睡眠定时"))
    }

    @Test("recommend_by_constraints 走系统服务")
    func recommendByConstraints() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "A")])
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "recommend_by_constraints", arguments: ["favoritesOnly": "true", "limit": "5"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
    }

    @Test("smart_queue_generate 只返回预览，不替换队列")
    func smartQueuePreview() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "A")])
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "smart_queue_generate", arguments: ["limit": "5"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("预览"))
    }

    @Test("diagnostics_export_report 返回脱敏报告")
    func exportReport() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "diagnostics_export_report", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("诊断报告"))
    }
}

@Suite("统计工具")
struct StatsToolTests {
    @Test("stats_get_top_items 走系统服务")
    func topItems() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "stats_get_top_items", arguments: ["kind": "artist", "limit": "5"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("最常听"))
    }

    @Test("stats_get_format_distribution 走系统服务")
    func formatDistribution() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "stats_get_format_distribution", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
    }

    @Test("stats_get_storage_distribution 走系统服务")
    func storageDistribution() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "stats_get_storage_distribution", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
    }

    @Test("playback_set_speed 调用 bridge")
    func setSpeed() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "playback_set_speed", arguments: ["rate": "1.25"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("1.25"))
    }
}

@Suite("资料库维护工具")
struct MaintenanceToolTests {
    @Test("library_find_duplicates 报告同名同艺人疑似重复")
    func findDuplicates() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [
            makeV2Track(serverID: "s", remoteID: "1", title: "七里香"),
            makeV2Track(serverID: "s", remoteID: "2", title: "七里香"),
        ])
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_find_duplicates", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("疑似重复"))
    }

    @Test("library_find_metadata_issues 报告缺年份/流派/封面")
    func findMetadataIssues() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "无元数据")])
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_find_metadata_issues", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("缺少年份"))
    }

    @Test("library_find_unplayable 报告无流地址且未离线")
    func findUnplayable() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "无地址")])
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_find_unplayable", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("无播放地址"))
    }
}

@Suite("封面/缓存维护工具")
struct ArtworkCacheMaintenanceTests {
    @Test("library_find_broken_artwork 走系统服务")
    func brokenArtwork() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_find_broken_artwork", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("封面"))
    }

    @Test("library_find_stale_cache 走系统服务")
    func staleCache() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_find_stale_cache", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("缓存"))
    }
}

@Suite("控制中心对比工具")
struct NowPlayingDiagnosticsTests {
    @Test("diagnostics_now_playing 走系统服务并报告一致性")
    func nowPlaying() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "diagnostics_now_playing", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("控制中心"))
    }
}

@Suite("播放随机 / 系统集成状态工具")
struct PlaybackRandomAndSystemToolsTests {
    @Test("playback_play_random 调用 bridge")
    func playRandom() async throws {
        let store = try makeV2Store()
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "A")])
        let bridge = MockAgentBridge(activeServerID: "s")
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "playback_play_random", arguments: ["limit": "10"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(result.success)
        #expect(result.summary.contains("随机"))
    }

    @Test("ios_siri_get_status 走系统服务")
    func siriStatus() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "ios_siri_get_status", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("Siri"))
    }

    @Test("ios_shortcuts_list 列出快捷指令")
    func shortcutsList() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "ios_shortcuts_list", arguments: [:]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("快捷指令"))
    }
}

@Suite("最近添加 / 最常播放工具")
struct RecentlyAddedAndMostPlayedTests {
    @Test("library_get_recently_added 走系统服务")
    func recentlyAdded() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_get_recently_added", arguments: ["days": "30", "limit": "5"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("添加"))
    }

    @Test("library_get_most_played 走系统服务")
    func mostPlayed() async throws {
        let store = try makeV2Store()
        let bridge = MockAgentBridge(activeServerID: "s")
        let system = StubSystemService()
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "library_get_most_played", arguments: ["limit": "5"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: system
        )
        #expect(result.success)
        #expect(result.summary.contains("最常播放"))
    }
}

@Suite("GlobalID 服务器归属校验")
struct GlobalIDServerScopeTests {
    @Test("跨服务器 GlobalID 被拒绝（旧会话 ID 失效）")
    func rejectsCrossServerID() async throws {
        let store = try makeV2Store()
        // 当前服务器 s 有 1 首；另一台服务器 other 也有 1 首（同 remoteID）。
        try await seedV2(store, [makeV2Track(serverID: "s", remoteID: "1", title: "CurrentServer")])
        try await seedV2(store, [makeV2Track(serverID: "other", remoteID: "1", title: "OtherServer")])
        let bridge = MockAgentBridge(activeServerID: "s")

        // 用 other:1 播放，当前活跃服务器是 s → 必须拒绝。
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "playback_play_song", arguments: ["trackID": "other:1"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(!result.success)

        // 当前服务器 s:1 → 正常成功。
        let ok = await AgentToolkit.executeV2(
            ToolCall(name: "playback_play_song", arguments: ["trackID": "s:1"]),
            bridge: bridge, catalog: store, serverID: ServerID(rawValue: "s"), systemService: nil
        )
        #expect(ok.success)
    }
}
