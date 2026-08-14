@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

/// iPhone 一级导航回归（RC issue 4）：在歌单/收藏详情里点“音乐库”“AI 助手”必须
/// 清掉 browseDestination 再切换分区，否则 NavigationStack 的 navigationDestination(item:)
/// 详情仍盖在新分区之上，表现为“点了但跳不过去”。
/// 纯状态测试：不依赖模拟器、不联网、不启动播放引擎。
@Suite("iPhone top-level navigation")
struct TopLevelNavigationTests {

    @MainActor
    private func makeModel() -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(id: "server", displayName: "Server"),
                artists: [], albums: [], tracks: [],
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            connector: NeverConnector(),
            defaults: UserDefaults(suiteName: "nav-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nav-\(UUID().uuidString).sqlite")
        )
    }

    private struct NeverConnector: ServerConnecting, @unchecked Sendable {
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }

    @Test("Home → 收藏详情 → 点音乐库：清空 browseDestination，selectedSection == .library")
    @MainActor
    func homeFavoritesDetailToLibraryClearsBrowseDestination() {
        let model = makeModel()
        model.selectTopLevelSection(.home)
        model.browseDestination = .favorites
        #expect(model.browseDestination == .favorites)

        model.selectTopLevelSection(.library)
        #expect(model.browseDestination == nil)
        #expect(model.selectedSection == .library)
    }

    @Test("Home → 歌单详情 → 点 AI 助手：清空 browseDestination，selectedSection == .assistant")
    @MainActor
    func homePlaylistDetailToAssistantClearsBrowseDestination() {
        let model = makeModel()
        model.selectTopLevelSection(.home)
        let playlist = Playlist(
            id: PlaylistID(rawValue: "pl-1"),
            serverID: "server",
            name: "My List",
            trackIDs: []
        )
        model.browseDestination = .playlist(playlist)
        #expect(model.browseDestination != nil)

        model.selectTopLevelSection(.assistant)
        #expect(model.browseDestination == nil)
        #expect(model.selectedSection == .assistant)
    }

    @Test("详情打开时切回首页：同样清空浏览详情")
    @MainActor
    func detailToHomeClearsBrowseDestination() {
        let model = makeModel()
        model.browseDestination = .playlists
        model.selectTopLevelSection(.home)
        #expect(model.browseDestination == nil)
        #expect(model.selectedSection == .home)
    }
}
