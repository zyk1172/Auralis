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

    @Test("P0-1 旧固定索引（无开放标签、语义版本为 0）进入 semanticTagsOnly 批次")
    func oldFixedIndexEntersSemanticOnlyBatch() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        // 只写固定分类（旧索引场景：没有开放标签）。
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], energy: 3, confidence: 0.9)
        ], serverID: serverID)
        // 模拟旧版本数据：语义标签规则版本回退为 0。
        try await store.db.run(
            "UPDATE recommendation_index_v2_state SET semantic_tag_rules_version = 0 WHERE global_id = ?",
            [.text(id)]
        )
        // 固定已完成但缺开放标签 → next_batch 必须是 semanticTagsOnly，且能取到这首歌。
        let next = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        #expect(next.mode == "semanticTagsOnly")
        #expect(next.tracks.contains { $0.id == id })
        #expect(next.pendingTracks == 1)
        let status = try await store.recommendationIndexV2Status(serverID: serverID)
        #expect(status.pendingTracks == 0)
        #expect(status.pendingSemanticTagTracks == 1)
    }

    @Test("P0-1 semanticTags=[] 也代表已处理，不会无限补标签")
    func emptySemanticTagsStillCompletes() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Track 01")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], energy: 3, confidence: 0.9)
        ], serverID: serverID)
        // 模拟旧数据。
        try await store.db.run(
            "UPDATE recommendation_index_v2_state SET semantic_tag_rules_version = 0 WHERE global_id = ?",
            [.text(id)]
        )
        // 语义批次：模型认为信息不足，返回 semanticTags=[]。
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, energy: 3, semanticTags: [], mode: "semanticTagsOnly")
        ], serverID: serverID)
        // 即使 0 个标签，处理已完成 → 不再进入下一批。
        let next = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        #expect(next.mode == "done")
        #expect(next.tracks.isEmpty)
        let status = try await store.recommendationIndexV2Status(serverID: serverID)
        #expect(status.semanticProcessedTracks == 1)
        #expect(status.pendingSemanticTagTracks == 0)
        #expect(status.semanticTaggedTracks == 0)
    }

    @Test("P1-5 legacy 变体迁移：Lo-fi / LO-FI 重写为 canonical，点击数量与歌曲一致")
    func legacyVariantsMigrated() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [
            semTrack(serverID: serverID, remoteID: "t1", title: "Song A"),
            semTrack(serverID: serverID, remoteID: "t2", title: "Song B"),
        ])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let ids = batch.tracks.map(\.id)
        // 先建立 state + 固定分类（让 tag_catalog 能 join 到 state）。
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: ids[0], moods: ["平静"], energy: 3, confidence: 0.8),
            RecommendationIndexV2Classification(id: ids[1], moods: ["平静"], energy: 3, confidence: 0.8),
        ], serverID: serverID)
        // 直接写入历史变体（模拟旧数据），不经过 canonical 写回路径。
        try await store.db.run(
            "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, 'tag', ?, ?)",
            [.text(ids[0]), .text("Lo-fi"), .real(0.8)]
        )
        try await store.db.run(
            "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, 'tag', ?, ?)",
            [.text(ids[1]), .text("LO-FI"), .real(0.7)]
        )
        // 幂等迁移。
        try await store.recommendationIndexV2MigrateSemanticCanonical()
        // 数据库内部已 canonical：tag_catalog 显示 2 首，且点进去能取到 2 首。
        let catalog = try await store.recommendationIndexV2TagCatalog(serverID: serverID)
        let lofi = catalog.filter { RecommendationIndexV2.semanticTagKey($0.value) == "lo-fi" }
        #expect(lofi.count == 1)
        #expect(lofi.first?.trackCount == 2)
        let tracks = try await store.recommendationIndexV2Tracks(serverID: serverID, dimension: "tag", value: lofi.first!.value)
        #expect(tracks.count == 2)
    }

    @Test("P0-1 先 full 后 semanticTagsOnly，最后 truly done")
    func fullThenSemanticThenDone() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        // 未分类：full 批次。
        let first = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        #expect(first.mode == "full")
        let id = try #require(first.tracks.first?.id)
        // full 写回（含开放标签）。
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(
                id: id, moods: ["平静"], energy: 3,
                semanticTags: [.init(value: "夜行感", confidence: 0.8)]
            )
        ], serverID: serverID)
        // 全部完成：下一批 mode=done 且无曲目。
        let done = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        #expect(done.mode == "done")
        #expect(done.tracks.isEmpty)
        #expect(done.pendingTracks == 0)
    }

    @Test("P1 跨歌曲 canonical：Lo-fi / LO-FI 归一到同一词条")
    func crossSongCanonicalization() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [
            semTrack(serverID: serverID, remoteID: "t1", title: "Song A"),
            semTrack(serverID: serverID, remoteID: "t2", title: "Song B"),
        ])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let ids = batch.tracks.map(\.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: ids[0], moods: ["平静"], energy: 3,
                semanticTags: [.init(value: "Lo-fi", confidence: 0.8)]),
            RecommendationIndexV2Classification(id: ids[1], moods: ["平静"], energy: 3,
                semanticTags: [.init(value: "LO-FI", confidence: 0.7)]),
        ], serverID: serverID)
        let catalog = try await store.recommendationIndexV2TagCatalog(serverID: serverID)
        let lofi = catalog.filter { $0.dimension == "tag" && RecommendationIndexV2.semanticTagKey($0.value) == "lo-fi" }
        #expect(lofi.count == 1)
        #expect(lofi.first?.trackCount == 2)
    }

    @Test("P1 semantic_tag_rules_version 按曲目持久化")
    func semanticVersionPersistedPerTrack() async throws {
        let store = try semStore()
        let serverID: ServerID = "s1"
        try await semSeed(store, [semTrack(serverID: serverID, remoteID: "t1", title: "Song")])
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 10)
        let id = try #require(batch.tracks.first?.id)
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: id, moods: ["平静"], energy: 3,
                semanticTags: [.init(value: "夜行感", confidence: 0.8)])
        ], serverID: serverID)
        let rows = try await store.db.query(
            "SELECT semantic_tag_rules_version FROM recommendation_index_v2_state WHERE global_id = ?",
            [.text(id)]
        )
        let version = rows.first?["semantic_tag_rules_version"]?.int ?? 0
        #expect(version == RecommendationIndexV2.semanticTagRulesVersion)
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
