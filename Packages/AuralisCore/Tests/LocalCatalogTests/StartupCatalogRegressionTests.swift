import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

@Suite("启动目录完整性", .serialized)
struct StartupCatalogRegressionTests {
    private func makeStore() throws -> LocalCatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-startup-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
    }

    @Test("quick_check 由持久化时间策略控制，不在每次打开时重复执行")
    func integrityCheckIsDueOnlyOncePerInterval() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 10_000)

        #expect(try await store.verifyIntegrityIfDue(now: start, minimumInterval: 60) == true)
        #expect(try await store.verifyIntegrityIfDue(now: start.addingTimeInterval(30), minimumInterval: 60) == false)
        #expect(try await store.verifyIntegrityIfDue(now: start.addingTimeInterval(61), minimumInterval: 60) == true)
    }

    @Test("searchAll 用一次 FTS 返回歌曲、专辑与艺术家")
    func unifiedSearchReturnsAllEntityKinds() async throws {
        let store = try makeStore()
        let serverID: ServerID = "search"
        let artist = Artist(id: "artist", serverID: serverID, name: "UniqueNeedle Artist", albumCount: 1)
        let album = Album(
            id: "album", serverID: serverID, artistID: artist.id,
            title: "UniqueNeedle Album", artistName: artist.name
        )
        let track = Track(
            id: "track", serverID: serverID, albumID: album.id, artistID: artist.id,
            title: "UniqueNeedle Track", artistName: artist.name, albumTitle: album.title, duration: 180
        )
        let session = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageArtists([artist], session: session)
        try await store.stageAlbums([album], session: session)
        try await store.stageTracks([track], session: session)
        try await store.completeSync(session, completedAt: .now)

        let result = try await store.searchAll(query: "UniqueNeedle", serverID: serverID)
        #expect(result.tracks.map(\.globalID.remoteID) == ["track"])
        #expect(result.albums.map(\.globalID.remoteID) == ["album"])
        #expect(result.artists.map(\.globalID.remoteID) == ["artist"])
    }

    @Test("25,100 首完整快照与分类索引不被 20,000 截断")
    func catalogSnapshotHasNoHiddenTwentyThousandCap() async throws {
        let store = try makeStore()
        let serverID: ServerID = "large"
        let count = 25_100
        let tracks = (0..<count).map { index in
            Track(
                id: TrackID(rawValue: "track-\(index)"),
                serverID: serverID,
                albumID: "album",
                artistID: "artist",
                title: "Track \(index)",
                artistName: "Artist",
                albumTitle: "Album",
                duration: 180
            )
        }
        let session = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks(tracks, session: session)
        try await store.completeSync(session, completedAt: .now)

        let snapshot = try await store.catalogSnapshot(serverID: serverID)
        #expect(snapshot.tracks.count == count)
        #expect(try await store.trackCount(serverID: serverID) == count)
        #expect(try await store.makeCatalogIndex(serverID: serverID).songCount == count)
    }
}
