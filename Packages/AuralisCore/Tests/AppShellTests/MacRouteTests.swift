@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// Clean-Slate Mac UI：新路由身份（MacRoute id 稳定、跨服务器不碰撞）与
/// 资料库查询助手（专辑曲目 disc/track 排序）的纯逻辑测试。
@Suite("Mac clean-slate routing & query helpers")
struct MacRouteTests {
    // MARK: - MacRoute identity

    @Test("album route id 包含 serverID，跨服务器同 remote id 不碰撞")
    func albumRouteIDsAreServerScoped() {
        let a = Album(id: "album-1", serverID: "serverA", artistID: "artist", title: "Same", artistName: "X")
        let b = Album(id: "album-1", serverID: "serverB", artistID: "artist", title: "Same", artistName: "X")
        #expect(MacRoute.album(a).id != MacRoute.album(b).id)
        #expect(MacRoute.album(a).id.contains("serverA"))
        #expect(MacRoute.album(b).id.contains("serverB"))
    }

    @Test("playlist route id 包含 serverID + playlistID")
    func playlistRouteIDsAreStable() {
        let p1 = Playlist(id: "pl-1", serverID: "serverA", name: "Mix", trackIDs: [])
        let p2 = Playlist(id: "pl-1", serverID: "serverB", name: "Mix", trackIDs: [])
        #expect(MacRoute.playlist(p1).id != MacRoute.playlist(p2).id)
        #expect(MacRoute.playlist(p1).id == MacRoute.playlist(p1).id)
    }

    @Test("genre route id 使用归一化 name，稳定")
    func genreRouteIDIsStable() {
        let g1 = Genre(name: "Rock", songCount: 5)
        let g2 = Genre(name: "Rock", songCount: 99)
        #expect(MacRoute.genre(g1).id == MacRoute.genre(g2).id)
        #expect(MacRoute.genre(g1).title == "Rock")
    }

    @Test("顶层目的地 id 唯一且稳定")
    func topLevelDestinationsAreUnique() {
        let ids = [MacRoute.home, .songs, .albums, .artists, .genres, .favorites, .disliked, .downloads, .playlists, .categories, .assistant, .server, .nowPlaying].map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(MacRoute.home.id == "home")
        #expect(MacRoute.nowPlaying.id == "nowPlaying")
    }

    // MARK: - MacLibraryQuery

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
