import Domain
import Foundation
import MusicLibrary
import Testing
@testable import LocalCatalog

/// “不喜欢”权威状态（SQLite，GlobalID 键）与自动推荐硬排除测试。
@Suite("Disliked tracks")
struct DislikedTracksTests {
    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    private func track(serverID: ServerID, remoteID: String, title: String = "Song") -> Track {
        Track(
            id: TrackID(rawValue: remoteID),
            serverID: serverID,
            albumID: AlbumID(rawValue: "\(remoteID)-album"),
            artistID: ArtistID(rawValue: "\(remoteID)-artist"),
            title: title,
            artistName: "Artist",
            albumTitle: "Album",
            duration: 200
        )
    }

    private func seed(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
        guard let serverID = tracks.first?.serverID else { return }
        let session = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks(tracks, session: session)
        try await store.completeSync(session, completedAt: .now)
    }

    @Test("set true persists, repeated true idempotent, set false deletes")
    func setPersistIdempotentDelete() async throws {
        let store = try makeStore()
        let gid = GlobalID(serverID: "s1", remoteID: "t1")
        try await store.setDisliked(gid, value: true, source: "user")
        try await store.setDisliked(gid, value: true, source: "user")
        #expect((try await store.isDisliked(gid)) == true)
        #expect(try await store.dislikedTrackIDs(serverID: "s1") == [gid])

        try await store.setDisliked(gid, value: false)
        #expect((try await store.isDisliked(gid)) == false)
        #expect(try await store.dislikedTrackIDs(serverID: "s1").isEmpty)
    }

    @Test("reload from a new store instance persists")
    func reloadPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.sqlite")
        let store = try LocalCatalogStore(url: url)
        let gid = GlobalID(serverID: "s1", remoteID: "t1")
        try await store.setDisliked(gid, value: true)

        let reopened = try LocalCatalogStore(url: url)
        #expect((try await reopened.isDisliked(gid)) == true)
        #expect(try await reopened.dislikedTrackIDs(serverID: "s1") == [gid])
    }

    @Test("two servers with same remote TrackID are isolated")
    func serverIsolation() async throws {
        let store = try makeStore()
        let a = GlobalID(serverID: "server-a", remoteID: "shared")
        let b = GlobalID(serverID: "server-b", remoteID: "shared")
        try await store.setDisliked(a, value: true)
        #expect((try await store.isDisliked(a)) == true)
        #expect((try await store.isDisliked(b)) == false)
        #expect(try await store.dislikedTrackIDs(serverID: "server-a") == [a])
        #expect(try await store.dislikedTrackIDs(serverID: "server-b").isEmpty)
    }

    @Test("Library / Search / Album / Playlist still show disliked; explicit get works")
    func browseAndExplicitStillShowDisliked() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [
            track(serverID: serverID, remoteID: "t1", title: "ZZDisliked"),
            track(serverID: serverID, remoteID: "t2", title: "ZZNormal"),
        ])
        let gid = GlobalID(serverID: serverID, remoteID: "t1")
        try await store.setDisliked(gid, value: true)

        // Library 全量列表仍包含 disliked。
        #expect(try await store.allTracks(serverID: serverID).count == 2)
        // Search 仍能找到。
        #expect(try await store.searchTracks(query: "ZZDisliked", serverID: serverID).count == 1)
        // Album 浏览仍包含（按专辑标题浏览不排除 disliked）。
        let albumTracks = try await store.allTracks(serverID: serverID).filter { $0.albumTitle == "Album" }
        #expect(albumTracks.count == 2)
        // 显式 getTrack 允许。
        #expect(try await store.getTrack(gid)?.id.rawValue == "t1")
        // 播放歌单场景：getPlaylist 不受影响（无歌单则返回 nil，不报错）。
        _ = try? await store.getPlaylist(GlobalID(serverID: serverID, remoteID: "pl"))
        // dislikedTracks 返回真实曲目。
        let disliked = try await store.dislikedTracks(serverID: serverID)
        #expect(disliked.map(\.id.rawValue) == ["t1"])
    }

    @Test("getSimilarTracks excludes disliked")
    func similarExcludesDisliked() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [
            track(serverID: serverID, remoteID: "base", title: "Base Song"),
            track(serverID: serverID, remoteID: "t1", title: "Similar 1"),
            track(serverID: serverID, remoteID: "t2", title: "Similar 2"),
        ])
        try await store.setDisliked(GlobalID(serverID: serverID, remoteID: "t2"), value: true)
        let similar = try await store.getSimilarTracks(GlobalID(serverID: serverID, remoteID: "base"), limit: 10)
        #expect(similar.map(\.globalID.remoteID).contains("t1"))
        #expect(!similar.map(\.globalID.remoteID).contains("t2"))
    }

    @Test("dislike does not change V2 content hash or invalidate index")
    func dislikeDoesNotAffectV2() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [track(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], scenes: ["深夜"], energy: 3, confidence: 0.9)
        ], serverID: serverID)
        #expect((try await store.recommendationIndexV2Status(serverID: serverID)).indexedTracks == 1)

        // 标记不喜欢后索引仍有效（content hash 不含 dislike）。
        try await store.setDisliked(GlobalID(serverID: serverID, remoteID: "t1"), value: true)
        let status = try await store.recommendationIndexV2Status(serverID: serverID)
        #expect(status.indexedTracks == 1)
        #expect(status.pendingTracks == 0)

        // V2 导出不含 dislike（导出包只含分类字段）。
        let package = try await store.exportRecommendationIndexV2Package(serverID: serverID)
        #expect(package.trackCount == 1)
    }

    @Test("legacy dynamic dimensions are cleaned, fixed dimensions and state preserved")
    func legacyCustomTagDimensionsCleaned() async throws {
        let store = try makeStore()
        let serverID: ServerID = "s1"
        try await seed(store, [track(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], energy: 3, textures: ["钢琴"], confidence: 0.9)
        ], serverID: serverID)
        // 手工注入一条历史动态维度（旧 customTags 写入）。
        let db = await store.db
        try await db.run(
            "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)",
            [.text(id), .text("编制"), .text("室内乐"), .real(0.9)]
        )

        // 执行清理：只删除非固定维度，固定维度与 state 保留。
        try await store.cleanupRecommendationIndexV2DynamicDimensions()

        let rows = try await db.query(
            "SELECT dimension FROM recommendation_index_v2_tags WHERE global_id = ?",
            [.text(id)]
        )
        let dimensions = rows.compactMap { $0["dimension"]?.string }
        #expect(!dimensions.contains("编制"))
        #expect(dimensions.contains("mood"))
        #expect(dimensions.contains("texture"))
        // state 保留，索引仍有效（不重新运行 V2）。
        let status = try await store.recommendationIndexV2Status(serverID: serverID)
        #expect(status.indexedTracks == 1)
        #expect(status.pendingTracks == 0)
    }
}
