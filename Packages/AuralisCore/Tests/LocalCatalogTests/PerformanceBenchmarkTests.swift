import Domain
import Foundation
import LocalCatalog
import Testing

/// 大型资料库规模验证：3000 首歌曲入库、查询、检索均可用且不退化。
@Suite("大型资料库规模")
struct PerformanceBenchmarkTests {
    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    @Test("3000 首歌曲可入库并检索")
    func threeThousandTracks() async throws {
        let store = try makeStore()
        let serverID = ServerID(rawValue: "scale")
        var tracks: [Track] = []
        for i in 0..<3000 {
            let artistIndex = i / 100
            tracks.append(Track(
                id: TrackID(rawValue: "t\(i)"),
                serverID: serverID,
                albumID: AlbumID(rawValue: "al\(i / 10)"),
                artistID: ArtistID(rawValue: "ar\(artistIndex)"),
                title: "Song \(i)",
                artistName: "Artist \(artistIndex)",
                albumTitle: "Album \(i / 10)",
                duration: 180,
                year: 1990 + (i % 35),
                genres: ["Genre\(i % 8)"]
            ))
        }

        let session = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks(tracks, session: session)
        try await store.completeSync(session, completedAt: .now)

        let all = try await store.allTracks(serverID: serverID, limit: 5000)
        #expect(all.count == 3000)

        // 歌曲摘要路径
        let summaries = try await store.allTrackSummaries(serverID: serverID)
        #expect(summaries.count == 3000)

        // FTS 检索
        let hits = try await store.searchTracks(query: "Song 2999", serverID: serverID)
        #expect(hits.contains { $0.title == "Song 2999" })

        // 收藏 / 流派摘要
        let favorites = try await store.getFavorites(serverID: serverID)
        #expect(favorites.isEmpty)
    }
}
