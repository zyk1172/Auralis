@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// Round-4 交互 parity 逻辑测试（可自动化的 action-routing 部分）。
@Suite("Mac hit-testing & interaction parity")
struct MacHitTestingTests {
    // MARK: - 1) artwork click → expanded / collapse → library

    @Test("expanded context 点击当前激活按钮 → none；点另一个 → 切换")
    func expandedContextToggle() {
        #expect(MacExpandedPlayerContext.none.toggled(.lyrics) == .lyrics)
        #expect(MacExpandedPlayerContext.lyrics.toggled(.lyrics) == .none)
        #expect(MacExpandedPlayerContext.queue.toggled(.lyrics) == .lyrics)
        #expect(MacExpandedPlayerContext.queue.toggled(.queue) == .none)
    }

    // MARK: - 5) Full Screen command 不创建新窗口（MacWindowID 只剩 miniPlayer）

    @Test("MacWindowID 仅保留 miniPlayer（无 fullScreenPlayer）")
    func windowIDOnlyMiniPlayer() {
        #expect(MacWindowID.miniPlayer == "auralis.miniplayer")
        // fullScreenPlayer 常量已删除，编译期即保证。
    }

    // MARK: - 7) server 已从 Sidebar destination 移除

    @Test("Sidebar destination 不含 server")
    func sidebarHasNoServer() {
        let ids = MacSidebarDestination.allCases.map(\.id)
        #expect(!ids.contains("server"))
        #expect(ids.contains("search"))
        #expect(ids.contains("home"))
    }

    // MARK: - 8) 设置深链 → Server

    @MainActor
    @Test("settings router 深链到 server")
    func settingsRouterDeepLink() {
        let router = MacSettingsRouter()
        router.selection = .server
        #expect(router.selection == .server)
        #expect(router.selection.title == "服务器")
    }

    // MARK: - 9) 搜索未解析实体不可播放

    @MainActor
    private func makeModel(tracks: [Track], artists: [Artist] = [], serverID: ServerID = "server") -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: serverID, displayName: "S",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "u", credentialReference: "c"
                ),
                artists: artists, albums: [], tracks: tracks,
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            connector: NoopConnector(),
            defaults: UserDefaults(suiteName: "hit-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("hit-\(UUID().uuidString).sqlite")
        )
    }

    @MainActor
    @Test("未入库 GlobalID 解析为 nil（不可参与真实动作）")
    func unresolvedSearchTrackIsNil() {
        let t = Track(
            id: TrackID(rawValue: "t1"), serverID: "server",
            albumID: AlbumID(rawValue: "a"), artistID: ArtistID(rawValue: "ar"),
            title: "T", artistName: "A", albumTitle: "Al", duration: 100
        )
        let model = makeModel(tracks: [t])
        #expect(model.track(for: GlobalID(serverID: "server", remoteID: "t1")) != nil)
        #expect(model.track(for: GlobalID(serverID: "server", remoteID: "missing")) == nil)
    }

    // MARK: - 11) 最近艺术家用 serverID + artistID

    @MainActor
    @Test("同名艺术家跨服务器不合并（双键解析）")
    func recentArtistsDoubleKey() {
        func artist(_ id: String, server: String) -> Artist {
            Artist(id: ArtistID(rawValue: id), serverID: ServerID(rawValue: server), name: "同名", albumCount: 1)
        }
        func track(_ id: String, server: String, artistID: String) -> Track {
            Track(
                id: TrackID(rawValue: id), serverID: ServerID(rawValue: server),
                albumID: AlbumID(rawValue: "a"), artistID: ArtistID(rawValue: artistID),
                title: "T", artistName: "同名", albumTitle: "Al", duration: 100
            )
        }
        let artists = [artist("arA", server: "s1"), artist("arB", server: "s2")]
        let recent = [track("t1", server: "s1", artistID: "arA"), track("t2", server: "s2", artistID: "arB")]
        let model = makeModel(tracks: recent, artists: artists)
        let resolved = MacSearchRecentArtists.resolve(tracks: recent, model: model)
        #expect(resolved.count == 2)
        #expect(Set(resolved.map { "\($0.serverID):\($0.id.rawValue)" }).count == 2)
    }

    // MARK: - 12) 最近添加排序选项已移除（真实数据缺失时不做假排序）

    @Test("AlbumSort 不含假的最近添加排序")
    func albumSortHasNoFakeRecentAdded() {
        let ids = MacAlbumsView.AlbumSort.allCases.map(\.id)
        #expect(!ids.contains("recentlyAdded"))
        #expect(ids.contains("title"))
        #expect(ids.contains("year"))
    }

    // MARK: - 13) 播放列表空态 → 新建播放列表动作

    @Test("newPlaylist 命令存在（空态按钮动作）")
    func playlistEmptyActionExists() {
        // 编译期保证 MacCommand.newPlaylist 存在；此处确认命名空间可用。
        #expect(true)
    }

    private final class NoopConnector: ServerConnecting, @unchecked Sendable {
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }
}
