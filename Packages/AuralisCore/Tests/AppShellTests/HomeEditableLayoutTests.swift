@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

// 自包含桩：还原持久化资料库（connect 返回预置结果），与其它 AppShell 测试一致。
private struct HomeLayoutConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }
}

private func homeTestDefaults(_ name: String) -> UserDefaults {
    UserDefaults(suiteName: "home-layout-\(name)-\(UUID().uuidString)")!
}

/// 首页模块注册表 / 默认配置必须与产品规则一致（需求 9）。
@Test("首页模块默认配置：快捷入口 歌单/收藏/最常听，内容模块 随机/最近播放/很久没听/最近添加/收藏里随便听")
func homeModuleDefaultConfigurationMatchesSpec() {
    let quickVisible = HomeModuleRegistry.modules(in: .quickEntry).filter(\.defaultVisible).map(\.id)
    #expect(quickVisible == [.playlists, .favorites, .mostPlayed])
    // 快捷入口不再提供 播放历史 / 下载（用户要求），因此也没有默认隐藏项。
    let quickHidden = HomeModuleRegistry.modules(in: .quickEntry).filter { !$0.defaultVisible }.map(\.id)
    #expect(quickHidden.isEmpty)

    let contentVisible = HomeModuleRegistry.modules(in: .content).filter(\.defaultVisible).map(\.id)
    #expect(contentVisible == [.random, .recentlyPlayed, .longUnplayed, .recentlyAdded, .favoriteRandom])
    let contentHidden = HomeModuleRegistry.modules(in: .content).filter { !$0.defaultVisible }.map(\.id)
    #expect(contentHidden == [.neverPlayed, .topArtists, .topAlbums])

    let defaults = HomeModuleRegistry.defaultPreference()
    #expect(defaults.quickEntries.map(\.moduleID) == ["playlists", "favorites", "mostPlayed"])
    #expect(defaults.contentModules.map(\.moduleID) == [
        "random", "recentlyPlayed", "longUnplayed", "recentlyAdded",
        "favoriteRandom", "neverPlayed", "topArtists", "topAlbums",
    ])
    #expect(defaults.preference(moduleID: "random")?.isVisible == true)
    #expect(defaults.preference(moduleID: "neverPlayed")?.isVisible == false)
}

/// 用户关闭模块：只改布局偏好，且跨实例持久化（App 完全退出重开仍保留，需求 8/5）。
@Test("关闭模块跨实例持久化，App 重开后仍为关闭")
@MainActor
func togglingModuleVisibilityPersistsAcrossModelInstances() {
    let defaults = homeTestDefaults("toggle")
    let first = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    #expect(first.homeLayout.preference(moduleID: "random")?.isVisible == true)
    first.setHomeModuleVisible("random", isVisible: false)
    #expect(first.homeLayout.preference(moduleID: "random")?.isVisible == false)

    let second = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    #expect(second.homeLayout.preference(moduleID: "random")?.isVisible == false,
            "关闭状态应写入 UserDefaults，重新创建模型后仍为关闭")
    #expect(second.homeLayout.preference(moduleID: "recentlyPlayed")?.isVisible == true)
}

/// 拖动排序：退出编辑后按新顺序渲染，且跨实例持久化（需求 6/8）。
@Test("拖动排序跨实例持久化，重开 App 顺序仍保留")
@MainActor
func movingModuleReordersAndPersistsAcrossModelInstances() {
    let defaults = homeTestDefaults("move")
    let first = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    // 把「最近播放」(index 1) 拖到「随机音乐」前面 (offset 0)。
    first.moveHomeModule(in: .content, fromOffsets: IndexSet(integer: 1), toOffset: 0)
    let firstOrder = first.homeLayout.contentModules.map(\.moduleID)
    #expect(firstOrder.first == "recentlyPlayed")
    #expect(firstOrder[1] == "random")

    let second = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    #expect(second.homeLayout.contentModules.map(\.moduleID) == firstOrder)
}

/// 快捷入口与内容模块分开排序、分开显示/隐藏（互不混排，需求 7）。
@Test("快捷入口与内容模块分开排序互不混排")
@MainActor
func quickAndContentGroupsStaySeparated() {
    let defaults = homeTestDefaults("separate")
    let model = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    // 快捷入口只注册 歌单/收藏/最常听；播放历史/下载不在注册表（用户要求移除）。
    #expect(HomeModuleRegistry.module(forID: "playHistory") == nil)
    #expect(HomeModuleRegistry.module(forID: "downloads") == nil)
    model.moveHomeModule(in: .quickEntry, fromOffsets: IndexSet(integer: 2), toOffset: 0)
    model.setHomeModuleVisible("favorites", isVisible: false)
    #expect(model.homeLayout.quickEntries.map(\.moduleID) == ["mostPlayed", "playlists", "favorites"])
    #expect(model.homeLayout.quickEntries.first { $0.moduleID == "favorites" }?.isVisible == false)
    // 内容模块不受快捷入口改动影响。
    #expect(model.homeLayout.contentModules.map(\.moduleID).first == "random")
    #expect(model.homeLayout.contentModules.first { $0.moduleID == "random" }?.isVisible == true)
}

/// 恢复默认布局：只重置首页布局偏好，不碰其它偏好 / 数据（需求 13）。
@Test("恢复默认布局只重置布局偏好，其它键不受影响")
@MainActor
func resetHomeLayoutOnlyResetsLayout() {
    let defaults = homeTestDefaults("reset")
    defaults.set(2.0, forKey: "auralis.playbackRate")
    defaults.set("sentinel", forKey: "auralis.lastTrackID")
    let model = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    model.setHomeModuleVisible("random", isVisible: false)
    model.moveHomeModule(in: .content, fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(model.homeLayout.preference(moduleID: "random")?.isVisible == false)

    model.resetHomeLayout()
    #expect(model.homeLayout == HomeModuleRegistry.defaultPreference())
    // 其它偏好键保持原样。
    #expect(defaults.double(forKey: "auralis.playbackRate") == 2.0)
    #expect(defaults.string(forKey: "auralis.lastTrackID") == "sentinel")
}

/// 归一化：旧版本遗留的未知模块 ID 被丢弃，新版本新增模块按默认设置补齐（需求 1 的「注册即出现」）。
@Test("布局偏好归一化：丢弃未知 ID、补齐新增模块")
@MainActor
func layoutNormalizationDropsUnknownAndAppendsNewModules() {
    let defaults = homeTestDefaults("normalize")
    let legacy = HomeLayoutPreference(
        quickEntries: [
            HomeModulePreference(moduleID: "ghost", isVisible: true, order: 0),
            HomeModulePreference(moduleID: "playlists", isVisible: true, order: 7),
        ],
        contentModules: [
            HomeModulePreference(moduleID: "random", isVisible: true, order: 3),
        ]
    )
    HomeLayoutStore.save(legacy, to: defaults)

    let model = AuralisAppModel(
        catalog: .empty,
        connector: HomeLayoutConnector(result: emptyResult()),
        defaults: defaults,
        storeURL: nil
    )
    #expect(!model.homeLayout.quickEntries.contains { $0.moduleID == "ghost" })
    #expect(model.homeLayout.quickEntries.map(\.moduleID) == HomeModuleRegistry.modules(in: .quickEntry).map(\.id.rawValue))
    #expect(model.homeLayout.quickEntries.first?.order == 0)
    #expect(model.homeLayout.contentModules.count == HomeModuleRegistry.modules(in: .content).count)
    #expect(model.homeLayout.contentModules.first?.moduleID == "random")
}

// MARK: - 数据规则快照

/// 很久没听 / 从未播放 / 常听艺术家 / 常听专辑 / 近 30 天新增 / 收藏随机 的快照规则。
@Test("首页模块数据规则：很久没听 / 从未播放 / 常听艺术家 / 常听专辑 / 近30天新增 / 收藏随机")
@MainActor
func homeSnapshotDataRules() async throws {
    let serverID = ServerID(rawValue: "test-server")
    let a1 = Artist(id: "artist-1", serverID: serverID, name: "A1", albumCount: 1)
    let a2 = Artist(id: "artist-2", serverID: serverID, name: "A2", albumCount: 1)
    let a3 = Artist(id: "artist-3", serverID: serverID, name: "A3", albumCount: 1)
    let b1 = Album(id: "album-1", serverID: serverID, artistID: a1.id, title: "B1", artistName: "A1")
    let b2 = Album(id: "album-2", serverID: serverID, artistID: a1.id, title: "B2", artistName: "A1")
    let b3 = Album(id: "album-3", serverID: serverID, artistID: a2.id, title: "B3", artistName: "A2")
    let b4 = Album(id: "album-4", serverID: serverID, artistID: a3.id, title: "B4", artistName: "A3")

    let t1 = track("t1", serverID: serverID, album: b1, artist: a1, favorite: true)
    let t2 = track("t2", serverID: serverID, album: b2, artist: a1, favorite: false)
    let t3 = track("t3", serverID: serverID, album: b1, artist: a2, favorite: false)
    let t4 = track("t4", serverID: serverID, album: b3, artist: a2, favorite: false)
    let t5 = track("t5", serverID: serverID, album: b4, artist: a3, favorite: false)
    let t6 = track("t6", serverID: serverID, album: b4, artist: a3, favorite: true)

    let defaults = homeTestDefaults("rules")
    // 播放次数：t1=5, t2=3, t3=1，其余 0。
    defaults.set([
        "test-server:t1": 5, "test-server:t2": 3, "test-server:t3": 1,
        "test-server:t4": 0, "test-server:t5": 0, "test-server:t6": 0,
    ], forKey: "auralis.playCounts")
    // 最近播放（最近在前）：t2, t1。
    defaults.set(["test-server:t2", "test-server:t1"], forKey: "auralis.recentlyPlayed")
    // 入库时间：t6=3 天前、t4=5 天前、t5=60 天前、t1/t2/t3 更早（>30 天）。
    let now = Date()
    defaults.set([
        "t1": now.addingTimeInterval(-100 * 86_400).timeIntervalSince1970,
        "t2": now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970,
        "t3": now.addingTimeInterval(-80 * 86_400).timeIntervalSince1970,
        "t4": now.addingTimeInterval(-5 * 86_400).timeIntervalSince1970,
        "t5": now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970,
        "t6": now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970,
    ], forKey: "auralis.libraryAdded")

    let result = ServerConnectionResult(
        account: ServerAccount(
            id: "test-server",
            displayName: "Test Library",
            baseURL: URL(string: "https://music.example.test")!,
            username: "listener",
            credentialReference: "cred"
        ),
        capabilities: .init(),
        artists: [a1, a2, a3],
        albums: [b1, b2, b3, b4],
        tracks: [t1, t2, t3, t4, t5, t6],
        serverType: "test-server",
        serverVersion: "1.0"
    )
    let model = AuralisAppModel(
        connector: HomeLayoutConnector(result: result),
        defaults: defaults,
        storeURL: nil
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    // apply() 的首页货架派生是后台任务（首屏只等 catalog）；测试确定性等待其完成。
    await model.awaitPendingApplyDerivations()

    // 最近播放：最近在前、去重（t2, t1）。
    #expect(model.homeRecentlyPlayedTracks.map(\.id) == [t2.id, t1.id])

    // 很久没听：播放过但不在最近播放历史 → 只有 t3（t1/t2 在最近历史里）。
    #expect(model.homeLongUnplayedTracks.map(\.id) == [t3.id])

    // 从未播放：播放次数 0 且不在播放历史 → t6, t4, t5（按入库时间倒序）。
    #expect(model.homeNeverPlayedTracks.map(\.id) == [t6.id, t4.id, t5.id])

    // 常听艺术家：A1=8 次 > A2=1 次，A3 无播放不出现。
    #expect(model.homeTopArtists.map(\.id) == [a1.id, a2.id])
    #expect(model.homeTopArtistPlayCounts[a1.id] == 8)
    #expect(model.homeTopArtistPlayCounts[a2.id] == 1)

    // 常听专辑：B1=6 次 > B2=3 次。
    #expect(model.homeTopAlbums.map(\.id) == [b1.id, b2.id])
    #expect(model.homeTopAlbumPlayCounts[b1.id] == 6)
    #expect(model.homeTopAlbumPlayCounts[b2.id] == 3)

    // 近 30 天新增：t6（3 天前）、t4（5 天前）；t5 是 60 天前不算，t1/t2/t3 更早不算。
    #expect(model.homeRecentlyAdded30DaysTracks.map(\.id) == [t6.id, t4.id])

    // 收藏里随便听：真实收藏（t1、t6）随机采样。
    #expect(!model.homeFavoriteRandomTracks.isEmpty)
    #expect(model.homeFavoriteRandomTracks.allSatisfy { $0.isFavorite })
    #expect(Set(model.homeFavoriteRandomTracks.map(\.id)).isSubset(of: [t1.id, t6.id]))

    // 随机音乐是稳定快照，且“随机播放”只消费该货架，不会回退到整个资料库。
    let randomSnapshot = model.randomTracks
    #expect(!randomSnapshot.isEmpty)
    #expect(model.randomTracks == randomSnapshot)
    model.playShuffledQueue(randomSnapshot)
    #expect(Set(model.queue.map { GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue) })
        .isSubset(of: Set(randomSnapshot.map { GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue) })))
}

/// 收藏里随便听「换一批」：本地重采样，不发网络请求（不依赖服务器，直接验证样本变化或仍为收藏）。
@Test("收藏里随便听换一批为本地重采样")
@MainActor
func regenerateFavoriteRandomResamplesLocally() async throws {
    let serverID = ServerID(rawValue: "test-server")
    let artist = Artist(id: "artist-1", serverID: serverID, name: "A1", albumCount: 1)
    let album = Album(id: "album-1", serverID: serverID, artistID: artist.id, title: "B1", artistName: "A1")
    let tracks = (0..<10).map { index in
        track("fav-\(index)", serverID: serverID, album: album, artist: artist, favorite: true)
    }
    let result = ServerConnectionResult(
        account: ServerAccount(
            id: "test-server", displayName: "Test Library",
            baseURL: URL(string: "https://music.example.test")!,
            username: "listener", credentialReference: "cred"
        ),
        capabilities: .init(),
        artists: [artist], albums: [album], tracks: tracks,
        serverType: "test-server", serverVersion: "1.0"
    )
    let model = AuralisAppModel(
        connector: HomeLayoutConnector(result: result),
        defaults: homeTestDefaults("favrandom"),
        storeURL: nil
    )
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        password: "test-only-value"
    ))
    // apply() 的首页货架派生是后台任务（首屏只等 catalog）；测试确定性等待其完成。
    await model.awaitPendingApplyDerivations()
    let firstSample = model.homeFavoriteRandomTracks
    model.regenerateFavoriteRandomMusic()
    let secondSample = model.homeFavoriteRandomTracks
    #expect(secondSample.allSatisfy { $0.isFavorite })
    #expect(secondSample.count == firstSample.count)
    #expect(Set(secondSample.map(\.id)).isSubset(of: Set(tracks.map(\.id))))
}

// MARK: - 工具

private func emptyResult() -> ServerConnectionResult {
    ServerConnectionResult(
        account: ServerAccount(
            id: "test-server",
            displayName: "Test Library",
            baseURL: URL(string: "https://music.example.test")!,
            username: "listener",
            credentialReference: "cred"
        ),
        capabilities: .init(),
        artists: [], albums: [], tracks: [],
        serverType: "test-server",
        serverVersion: "1.0"
    )
}

private func track(_ id: String, serverID: ServerID, album: Album, artist: Artist, favorite: Bool) -> Track {
    Track(
        id: TrackID(rawValue: id),
        serverID: serverID,
        albumID: album.id,
        artistID: artist.id,
        title: id,
        artistName: artist.name,
        albumTitle: album.title,
        duration: 180,
        isFavorite: favorite,
        artworkKey: "art-\(id)"
    )
}
