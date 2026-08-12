import Domain
import Foundation
@testable import LocalCatalog
import MusicLibrary
import Testing

private func semStore() throws -> LocalCatalogStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
}

private func semTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: serverID,
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "Artist \(serverID.rawValue)",
        albumTitle: "Album \(serverID.rawValue)",
        duration: 200
    )
}

private func semSeed(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

private func semTagRows(_ store: LocalCatalogStore, _ id: String) async throws -> [(dimension: String, value: String)] {
    let rows = try await store.db.query(
        "SELECT dimension, value FROM recommendation_index_v2_tags WHERE global_id = ?",
        [.text(id)]
    )
    return rows.compactMap {
        guard let d = $0["dimension"]?.string, let v = $0["value"]?.string else { return nil }
        return (d, v)
    }
}

@Suite("V2 semantic tags")
struct RecommendationIndexV2SemanticTagsTests {
    @Test("TEST1 3 semantic tags written")
    func threeSemanticTags() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        let written = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(
                id: id, moods: ["平静"], energy: 3,
                semanticTags: [
                    .init(value: "夜行感", confidence: 0.8),
                    .init(value: "公路感", confidence: 0.7),
                    .init(value: "城市霓虹", confidence: 0.6),
                ]
            )
        ], serverID: serverID)
        #expect(written == 1)
        let tags = try await semTagRows(store, id).filter { $0.dimension == "tag" }
        #expect(tags.count == 3)
    }

    @Test("TEST2/3 30 与 100 semantic tags 均成功（无每首数量硬上限）")
    func manySemanticTags() async throws {
        for count in [30, 100] {
            let store = try semStore()
            let serverID: ServerID = "s1"
            try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
            let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
            let id = try #require(batch.tracks.first?.id)
            let tags = (0..<count).map { RecommendationIndexV2SemanticTag(value: "标签\($0)", confidence: 0.5) }
            let written = try await store.writeRecommendationIndexV2([
                RecommendationIndexV2Classification(id: id, moods: ["平静"], energy: 3, semanticTags: tags)
            ], serverID: serverID)
            #expect(written == 1)
            let stored = try await semTagRows(store, id).filter { $0.dimension == "tag" }
            #expect(stored.count == count, "存储层不应限制每首标签数量（\(count)）")
        }
    }

    @Test("TEST4/5 重复与变体标签归一成一条")
    func duplicateAndVariantTagsDedupe() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(
                id: id, moods: ["平静"], energy: 3,
                semanticTags: [
                    .init(value: "夜行感", confidence: 0.9),
                    .init(value: "夜行感", confidence: 0.8),
                    .init(value: "夜行感", confidence: 0.7),
                    .init(value: " 夜行感 ", confidence: 0.6),
                    .init(value: "#夜行感", confidence: 0.5),
                    .init(value: "公路感", confidence: 0.6),
                ]
            )
        ], serverID: serverID)
        let tags = try await semTagRows(store, id).filter { $0.dimension == "tag" }.map(\.value).sorted()
        #expect(tags == ["公路感", "夜行感"])
    }

    @Test("TEST9 semanticTagsOnly patch 不删除固定维度")
    func semanticTagsOnlyPreservesFixed() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], scenes: ["深夜"], energy: 3, styles: ["流行"], confidence: 0.9)
        ], serverID: serverID)
        // 增量补开放标签：mode = semanticTagsOnly
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(
                id: id, energy: 3,
                semanticTags: [.init(value: "夜行感", confidence: 0.8)],
                mode: "semanticTagsOnly"
            )
        ], serverID: serverID)
        let rows = try await semTagRows(store, id)
        #expect(rows.contains { $0.dimension == "mood" && $0.value == "平静" })
        #expect(rows.contains { $0.dimension == "scene" && $0.value == "深夜" })
        #expect(rows.contains { $0.dimension == "style" && $0.value == "流行" })
        #expect(rows.contains { $0.dimension == "tag" && $0.value == "夜行感" })
    }

    @Test("TEST7 V2 export/import 保留 semantic tags")
    func transferPreservesSemanticTags() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(
                id: id, moods: ["平静"], energy: 3,
                semanticTags: [.init(value: "夜行感", confidence: 0.8), .init(value: "公路感", confidence: 0.7)]
            )
        ], serverID: serverID)
        let package = try await store.exportRecommendationIndexV2Package(serverID: serverID)
        #expect(package.trackCount == 1)
        let exportedTags = package.entries.first?.tags ?? []
        #expect(exportedTags.contains { $0.dimension == "tag" && $0.value == "夜行感" })
        #expect(exportedTags.contains { $0.dimension == "tag" && $0.value == "公路感" })

        // 导入到另一台设备（不同本地 serverID）。
        let other = try semStore()
        try await semSeed(other, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let data = try JSONEncoder().encode(package)
        let stats = try await other.importRecommendationIndexV2Package(data: data, serverID: serverID)
        #expect(stats.imported == 1)
        let imported = try await semTagRows(other, id)
        #expect(imported.contains { $0.dimension == "tag" && $0.value == "夜行感" })
        #expect(imported.contains { $0.dimension == "tag" && $0.value == "公路感" })
        #expect(imported.contains { $0.dimension == "mood" && $0.value == "平静" })
    }

    @Test("TEST8 旧固定索引升级后不丢失（tag_catalog 可读取）")
    func fixedIndexUpgradeAndTagCatalog() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        // 旧式只写固定维度。
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], energy: 3, confidence: 0.9)
        ], serverID: serverID)
        // 升级：补开放标签。
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(
                id: id, energy: 3,
                semanticTags: [.init(value: "夜行感", confidence: 0.8)],
                mode: "semanticTagsOnly"
            )
        ], serverID: serverID)
        // 旧固定维度保留。
        let rows = try await semTagRows(store, id)
        #expect(rows.contains { $0.dimension == "mood" && $0.value == "平静" })
        // tag_catalog 可见。
        let catalog = try await store.recommendationIndexV2TagCatalog(serverID: serverID)
        #expect(catalog.contains { $0.dimension == "tag" && $0.value == "夜行感" && $0.trackCount == 1 })
    }
}
