@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// Mac 路由身份 / 查询助手 / 格式化的纯逻辑测试（Round-2 导航模型）。
@Suite("Mac clean-slate routing & query helpers")
struct MacRouteTests {
    @Test("album entity route id 含 serverID，跨服务器同 remote id 不碰撞")
    func albumEntityIDsAreServerScoped() {
        let a = MacEntityRouteID(serverID: "serverA", remoteID: "album-1")
        let b = MacEntityRouteID(serverID: "serverB", remoteID: "album-1")
        #expect(a != b)
        #expect(MacDetailRoute.album(a) != MacDetailRoute.album(b))
    }

    @Test("playlist entity route id 含 serverID + playlistID")
    func playlistEntityIDsAreStable() {
        let p1 = MacEntityRouteID(serverID: "serverA", remoteID: "pl-1")
        let p2 = MacEntityRouteID(serverID: "serverB", remoteID: "pl-1")
        #expect(MacDetailRoute.playlist(p1) != MacDetailRoute.playlist(p2))
        #expect(MacDetailRoute.playlist(p1) == MacDetailRoute.playlist(p1))
    }

    @Test("genre route 使用归一化 name")
    func genreRouteUsesName() {
        let r1 = MacDetailRoute.genre("Rock")
        let r2 = MacDetailRoute.genre("Rock")
        #expect(r1 == r2)
        #expect(MacDetailRoute.genre("Rock") != MacDetailRoute.genre("Pop"))
    }

    @Test("Sidebar destination 顶层唯一且稳定")
    func sidebarDestinationsUnique() {
        let all = MacSidebarDestination.allCases
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(MacSidebarDestination.home.id == "home")
        #expect(["歌曲", "Songs"].contains(MacSidebarDestination.songs.title))
    }

    @MainActor
    private func makeModel(tracks: [Track]) -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: "server", displayName: "S",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "u", credentialReference: "c"
                ),
                artists: [], albums: [], tracks: tracks,
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            connector: NoopConnector(),
            defaults: UserDefaults(suiteName: "mac-route-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mac-route-\(UUID().uuidString).sqlite")
        )
    }

    @MainActor
    @Test("albumTracks 按 disc 再按 track 排序")
    func albumTracksSortByDiscThenTrack() {
        func t(_ id: String, disc: Int?, track: Int?) -> Track {
            Track(
                id: TrackID(rawValue: id), serverID: "server",
                albumID: "album", artistID: "artist",
                title: id, artistName: "A", albumTitle: "Album",
                duration: 100, trackNumber: track, discNumber: disc
            )
        }
        let tracks = [
            t("d1t2", disc: 1, track: 2),
            t("d2t1", disc: 2, track: 1),
            t("d1t1", disc: 1, track: 1),
            t("noNum", disc: nil, track: nil)
        ]
        let model = makeModel(tracks: tracks)
        let album = Album(id: "album", serverID: "server", artistID: "artist", title: "Album", artistName: "A")
        let sorted = MacLibraryQuery.albumTracks(album, model: model)
        #expect(sorted.map(\.id.rawValue) == ["d1t1", "d1t2", "noNum", "d2t1"])
    }

    @Test("MacFormat.time 输出 m:ss")
    func timeFormatting() {
        #expect(MacFormat.time(0) == "0:00")
        #expect(MacFormat.time(65) == "1:05")
        #expect(MacFormat.time(3723) == "62:03")
    }

    private final class NoopConnector: ServerConnecting, @unchecked Sendable {
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }
}
