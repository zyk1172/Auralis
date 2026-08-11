@testable import AppShell
import AgentKit
import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

/// “不喜欢”与收藏互斥、持久化，以及首页发现货架硬排除 disliked 的纯逻辑测试。
@Suite("Dislike behavior")
struct DislikeBehaviorTests {
    private final class RecordingConnector: ServerConnecting, @unchecked Sendable {
        private(set) var favoriteCalls: [(TrackID, Bool)] = []
        func setFavorite(trackID: TrackID, isFavorite: Bool) async {
            favoriteCalls.append((trackID, isFavorite))
        }
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }

    @MainActor
    private func makeModel(connector: RecordingConnector, tracks: [Track]) -> AuralisAppModel {
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
            connector: connector,
            defaults: UserDefaults(suiteName: "dislike-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("dislike-\(UUID().uuidString).sqlite")
        )
    }

    private func track(_ id: String, favorite: Bool = false) -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: "server",
            albumID: "album", artistID: "artist",
            title: id, artistName: "Artist", albumTitle: "Album", duration: 180,
            isFavorite: favorite
        )
    }

    @Test("favorite=true → dislike → final dislike=true and favorite cleared (server sync called)")
    @MainActor
    func dislikeClearsFavorite() async throws {
        let connector = RecordingConnector()
        let model = makeModel(connector: connector, tracks: [track("t1", favorite: true)])
        let current = model.catalog.tracks[0]
        await model.persistDisliked(current, value: true, source: "user")

        #expect(model.isDisliked(current) == true)
        // 服务器侧取消收藏被调用（复用现有 favorite API，不新造一套）。
        #expect(connector.favoriteCalls.contains { $0.0.rawValue == "t1" && $0.1 == false })
        // 本地目录收藏被清除。
        #expect(model.catalog.tracks.first?.isFavorite == false)
        // SQLite 权威状态持久化。
        let store = model.catalogCoordinator.store
        #expect((try await store.isDisliked(GlobalID(serverID: "server", remoteID: "t1"))) == true)
    }

    @Test("dislike=true → favorite click → dislike cleared and favorite set")
    @MainActor
    func favoriteClickClearsDislike() async throws {
        let connector = RecordingConnector()
        let model = makeModel(connector: connector, tracks: [track("t1")])
        let current = model.catalog.tracks[0]
        await model.persistDisliked(current, value: true, source: "user")
        #expect(model.isDisliked(current) == true)

        await model.toggleFavoritePersisted(current)
        #expect(model.isDisliked(current) == false)
        #expect(model.catalog.tracks.first?.isFavorite == true)
        #expect(connector.favoriteCalls.contains { $0.0.rawValue == "t1" && $0.1 == true })
        // 最终状态：favorite=true / dislike=false（SQLite）。
        let store = model.catalogCoordinator.store
        #expect((try await store.isDisliked(GlobalID(serverID: "server", remoteID: "t1"))) == false)
    }

    @Test("cancel dislike does not restore a previously cleared favorite")
    @MainActor
    func cancelDislikeDoesNotRestoreFavorite() async throws {
        let connector = RecordingConnector()
        let model = makeModel(connector: connector, tracks: [track("t1", favorite: true)])
        let current = model.catalog.tracks[0]
        await model.persistDisliked(current, value: true, source: "user")   // 收藏被取消
        await model.persistDisliked(current, value: false, source: "user")  // 取消不喜欢
        #expect(model.isDisliked(current) == false)
        #expect(model.catalog.tracks.first?.isFavorite == false)
        // 取消不喜欢后没有任何 setFavorite(true) 调用（不自动恢复收藏）。
        #expect(!connector.favoriteCalls.contains { $0.1 == true })
    }

    @Test("recommendByMood excludes disliked at candidate layer")
    @MainActor
    func recommendByMoodExcludesDisliked() async throws {
        let connector = RecordingConnector()
        let model = makeModel(connector: connector, tracks: [
            track("t-mood", favorite: false),
            track("t-disliked", favorite: false),
        ])
        // 给 disliked 写库（recommendByMood 从 SQLite 读 disliked）。
        let disliked = model.catalog.tracks.first { $0.id.rawValue == "t-disliked" }!
        await model.persistDisliked(disliked, value: true, source: "user")

        let service = AuralisSystemToolService(model: model)
        let result = await service.recommendByMood("深夜", limit: 10)
        let ids = result.tracks.map(\.globalID.remoteID)
        #expect(!ids.contains("t-disliked"))
        #expect(ids.contains("t-mood"))
    }

    @Test("recommendByConstraints excludes disliked at candidate layer")
    @MainActor
    func recommendByConstraintsExcludesDisliked() async throws {
        let connector = RecordingConnector()
        let model = makeModel(connector: connector, tracks: [
            track("t-constraint"),
            track("t-disliked"),
        ])
        let disliked = model.catalog.tracks.first { $0.id.rawValue == "t-disliked" }!
        await model.persistDisliked(disliked, value: true, source: "user")

        let service = AuralisSystemToolService(model: model)
        let result = await service.recommendByConstraints(AgentRecommendationConstraints(limit: 10))
        let ids = result.tracks.map(\.globalID.remoteID)
        #expect(!ids.contains("t-disliked"))
        #expect(ids.contains("t-constraint"))
    }

    @Test("home discovery shelves exclude disliked; browsing shelves keep them")
    @MainActor
    func homeSnapshotExcludesDislikedOnlyInDiscovery() async throws {
        let dislikedGID = GlobalID(serverID: "server", remoteID: "t-disliked")
        let liked = track("t-liked", favorite: true)
        let disliked = track("t-disliked", favorite: true)
        let catalog = LibraryCatalog(
            account: ServerAccount(id: "server", displayName: "Server"),
            artists: [], albums: [],
            tracks: [liked, disliked],
            genres: [], playlists: [], history: [], downloads: [],
            lyrics: [:], recommendations: []
        )
        let playCounts: [TrackID: Int] = [liked.id: 3, disliked.id: 5]
        let snapshot = HomeSnapshotBuilder.build(
            catalog: catalog,
            playCounts: playCounts,
            recentIDs: [],
            addedDates: [:],
            dislikedTrackIDs: [dislikedGID]
        )
        // 发现货架排除 disliked。
        #expect(snapshot.longUnplayed.map(\.id.rawValue).contains("t-liked"))
        #expect(!snapshot.longUnplayed.map(\.id.rawValue).contains("t-disliked"))
        #expect(!snapshot.neverPlayed.map(\.id.rawValue).contains("t-disliked"))
        #expect(!snapshot.favoriteRandom.map(\.id.rawValue).contains("t-disliked"))
        // 浏览货架保留 disliked（收藏 / 最近播放 / 最近添加 / 最常听）。
        #expect(snapshot.favorites.map(\.id.rawValue).contains("t-disliked"))
        #expect(snapshot.mostPlayed.map(\.id.rawValue).contains("t-disliked"))
    }
}
