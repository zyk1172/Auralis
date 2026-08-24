import Domain
import Foundation
import MusicLibrary
import Testing
@testable import LocalCatalog

/// V2 跨设备导入/导出与内容指纹迁移测试。
/// 覆盖 export→import round trip、双设备不同 ServerID、个人行为数据不影响导入、
/// 元数据变化拒绝、版本/格式/安全校验、事务回滚与旧索引不调用 LLM 迁移。
@Suite("Recommendation Index V2 transfer")
struct RecommendationIndexV2TransferTests {
    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    private func track(
        serverID: ServerID,
        remoteID: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        duration: TimeInterval = 200,
        year: Int? = 2020,
        genres: [String] = ["Rock"],
        language: String? = "zh"
    ) -> Track {
        Track(
            id: TrackID(rawValue: remoteID),
            serverID: serverID,
            albumID: AlbumID(rawValue: "\(remoteID)-album"),
            artistID: ArtistID(rawValue: "\(remoteID)-artist"),
            title: title,
            artistName: artist,
            albumTitle: album,
            duration: duration,
            year: year,
            genres: genres,
            language: language
        )
    }

    private func seed(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
        guard let serverID = tracks.first?.serverID else { return }
        let session = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks(tracks, session: session)
        try await store.completeSync(session, completedAt: .now)
    }

    private func classifyAll(_ store: LocalCatalogStore, serverID: ServerID) async throws -> Int {
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 100)
        let classifications = batch.tracks.enumerated().map { index, line in
            RecommendationIndexV2Classification(
                id: line.id,
                moods: index.isMultiple(of: 2) ? ["平静"] : ["明亮"],
                scenes: ["深夜"],
                energy: 3,
                vocals: ["器乐"],
                textures: ["钢琴"],
                styles: ["流行"],
                confidence: 0.9
            )
        }
        return try await store.writeRecommendationIndexV2(classifications, serverID: serverID)
    }

    private func encodePackage(_ package: RecommendationIndexV2Package) throws -> Data {
        try JSONEncoder().encode(package)
    }

    @Test("export → import round trip keeps tags across devices with different local ServerID")
    func exportImportRoundTripAcrossServerID() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [
            track(serverID: serverA, remoteID: "t1", title: "Night Piano"),
            track(serverID: serverA, remoteID: "t2", title: "Morning Run"),
        ])
        let written = try await classifyAll(storeA, serverID: serverA)
        #expect(written == 2)

        let package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)
        #expect(package.formatVersion == 1)
        #expect(package.rulesVersion == RecommendationIndexV2.rulesVersion)
        #expect(package.contentHashVersion == RecommendationIndexV2.contentHashVersion)
        #expect(package.trackCount == 2)
        #expect(package.entries.count == 2)

        // 设备 B：同一个 NAS，但本地生成的 ServerID 不同（server-b）。
        let storeB = try makeStore()
        let serverB: ServerID = "server-b"
        try await seed(storeB, [
            track(serverID: serverB, remoteID: "t1", title: "Night Piano"),
            track(serverID: serverB, remoteID: "t2", title: "Morning Run"),
        ])
        let stats = try await storeB.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: serverB
        )
        #expect(stats.imported == 2)
        #expect(stats.notFound == 0)
        #expect(stats.metadataChanged == 0)

        let status = try await storeB.recommendationIndexV2Status(serverID: serverB)
        #expect(status.indexedTracks == 2)
        #expect(status.pendingTracks == 0)
        let read = try await storeB.readRecommendationIndexV2(serverID: serverB, dimension: "mood", value: "平静")
        #expect(read.map(\.track.id).contains("\(serverB.rawValue):t1"))
    }

    @Test("favorite / playCount / rating differences do not block import (personal data excluded from hash)")
    func personalDataDoesNotBlockImport() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [track(serverID: serverA, remoteID: "t1", title: "Same Song")])
        try await classifyAll(storeA, serverID: serverA)
        let package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)
        #expect(package.trackCount == 1)

        let storeB = try makeStore()
        let serverB: ServerID = "server-b"
        try await seed(storeB, [track(serverID: serverB, remoteID: "t1", title: "Same Song")])
        // 设备 B 的个人数据与设备 A 不同：收藏、评分、播放次数都不同。
        let gid = GlobalID(serverID: serverB, remoteID: "t1")
        try await storeB.setFavorite(gid, value: true)
        try await storeB.setRating(gid, rating: 5)
        try await storeB.recordPlay(gid, completed: true)
        try await storeB.recordPlay(gid, completed: true)

        let stats = try await storeB.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: serverB
        )
        #expect(stats.imported == 1)
        #expect(stats.metadataChanged == 0)
        let status = try await storeB.recommendationIndexV2Status(serverID: serverB)
        #expect(status.indexedTracks == 1)
        #expect(status.pendingTracks == 0)
    }

    @Test("title change rejects entry and keeps it pending")
    func titleChangeRejected() async throws {
        try await assertMetadataChangeRejected { _ in
            track(serverID: "server-b", remoteID: "t1", title: "Changed Title")
        }
    }

    @Test("artist change rejects entry and keeps it pending")
    func artistChangeRejected() async throws {
        try await assertMetadataChangeRejected { _ in
            track(serverID: "server-b", remoteID: "t1", title: "Same Song", artist: "Different Artist")
        }
    }

    @Test("album change rejects entry and keeps it pending")
    func albumChangeRejected() async throws {
        try await assertMetadataChangeRejected { _ in
            track(serverID: "server-b", remoteID: "t1", title: "Same Song", album: "Different Album")
        }
    }

    @Test("duration significant change rejects entry")
    func durationChangeRejected() async throws {
        try await assertMetadataChangeRejected { _ in
            track(serverID: "server-b", remoteID: "t1", title: "Same Song", duration: 600)
        }
    }

    @Test("genre order difference but same set imports successfully")
    func genreOrderSameSetImports() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [
            track(serverID: serverA, remoteID: "t1", title: "Genres", genres: ["Rock", "Indie"]),
        ])
        try await classifyAll(storeA, serverID: serverA)
        let package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)

        let storeB = try makeStore()
        let serverB: ServerID = "server-b"
        // 相同集合、不同顺序。
        try await seed(storeB, [
            track(serverID: serverB, remoteID: "t1", title: "Genres", genres: ["Indie", "Rock"]),
        ])
        let stats = try await storeB.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: serverB
        )
        #expect(stats.imported == 1)
        #expect(stats.metadataChanged == 0)
    }

    @Test("rulesVersion mismatch is rejected")
    func rulesVersionMismatch() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [track(serverID: serverA, remoteID: "t1", title: "Song")])
        try await classifyAll(storeA, serverID: serverA)
        var package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)
        package.rulesVersion = "9.9"

        let storeB = try makeStore()
        try await seed(storeB, [track(serverID: "server-b", remoteID: "t1", title: "Song")])
        do {
            _ = try await storeB.importRecommendationIndexV2Package(
                data: try encodePackage(package),
                serverID: "server-b"
            )
            Issue.record("expected versionIncompatible")
        } catch let error as RecommendationIndexV2ImportError {
            guard case .versionIncompatible = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test("contentHashVersion mismatch is rejected")
    func contentHashVersionMismatch() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [track(serverID: serverA, remoteID: "t1", title: "Song")])
        try await classifyAll(storeA, serverID: serverA)
        var package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)
        package.contentHashVersion = 99

        let storeB = try makeStore()
        try await seed(storeB, [track(serverID: "server-b", remoteID: "t1", title: "Song")])
        do {
            _ = try await storeB.importRecommendationIndexV2Package(
                data: try encodePackage(package),
                serverID: "server-b"
            )
            Issue.record("expected versionIncompatible")
        } catch let error as RecommendationIndexV2ImportError {
            guard case .versionIncompatible = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test("damaged JSON is rejected")
    func damagedJSONRejected() async throws {
        let store = try makeStore()
        try await seed(store, [track(serverID: "server-b", remoteID: "t1", title: "Song")])
        do {
            _ = try await store.importRecommendationIndexV2Package(
                data: Data("{ not json ".utf8),
                serverID: "server-b"
            )
            Issue.record("expected invalidData")
        } catch let error as RecommendationIndexV2ImportError {
            guard case .invalidData = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test("invalid dimension value is counted as malformed and skipped")
    func invalidDimensionSkipped() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [track(serverID: serverA, remoteID: "t1", title: "Song")])
        try await classifyAll(storeA, serverID: serverA)
        var package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)
        // 篡改维度值，使其不在 mood allowlist；hash 仍与本地一致，命中标签校验。
        package.entries[0].tags = [
            RecommendationIndexV2PackageTag(dimension: "mood", value: "不存在的情绪", confidence: 0.9)
        ]
        let storeB = try makeStore()
        try await seed(storeB, [track(serverID: "server-b", remoteID: "t1", title: "Song")])
        let stats = try await storeB.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: "server-b"
        )
        #expect(stats.malformed == 1)
        #expect(stats.imported == 0)
    }

    @Test("invalid confidence is counted as malformed")
    func invalidConfidenceSkipped() async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [track(serverID: serverA, remoteID: "t1", title: "Song")])
        try await classifyAll(storeA, serverID: serverA)
        var package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)
        // 篡改 confidence 超出 0...1；hash 仍与本地一致，命中标签校验。
        package.entries[0].tags = [
            RecommendationIndexV2PackageTag(dimension: "mood", value: "平静", confidence: 1.5)
        ]
        let storeB = try makeStore()
        try await seed(storeB, [track(serverID: "server-b", remoteID: "t1", title: "Song")])
        let stats = try await storeB.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: "server-b"
        )
        #expect(stats.malformed == 1)
        #expect(stats.imported == 0)
    }

    @Test("oversized package is rejected before parsing")
    func oversizedPackageRejected() async throws {
        let store = try makeStore()
        try await seed(store, [track(serverID: "server-b", remoteID: "t1", title: "Song")])
        let huge = Data(count: 51 * 1024 * 1024)
        do {
            _ = try await store.importRecommendationIndexV2Package(data: huge, serverID: "server-b")
            Issue.record("expected tooLarge")
        } catch let error as RecommendationIndexV2ImportError {
            guard case .tooLarge = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test("SQLite transaction rolls back on failure (import is atomic)")
    func transactionRollback() async throws {
        let store = try makeStore()
        let serverID: ServerID = "server-b"
        try await seed(store, [track(serverID: serverID, remoteID: "t1", title: "Song")])
        let db = await store.db
        let gid = GlobalID(serverID: serverID, remoteID: "t1").description
        do {
            try await db.transaction {
                try db.run(
                    "INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at, source_hash_version) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(gid), .text(serverID.rawValue), .text("abc"), .text(RecommendationIndexV2.rulesVersion), .text("test"), .real(Date.now.timeIntervalSince1970), .integer(2)]
                )
                // 重复主键：强制失败，验证整个事务回滚。
                try db.run(
                    "INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at, source_hash_version) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(gid), .text(serverID.rawValue), .text("abc"), .text(RecommendationIndexV2.rulesVersion), .text("test"), .real(Date.now.timeIntervalSince1970), .integer(2)]
                )
            }
            Issue.record("expected transaction failure")
        } catch {
            // 事务失败后第一条插入必须被回滚。
        }
        let rows = try await db.query(
            "SELECT 1 FROM recommendation_index_v2_state WHERE global_id = ?",
            [.text(gid)]
        )
        #expect(rows.isEmpty)
    }

    @Test("old V2 index migrates content hash locally without calling the model")
    func oldIndexMigrationDoesNotCallModel() async throws {
        let store = try makeStore()
        let serverID: ServerID = "server-b"
        try await seed(store, [
            track(serverID: serverID, remoteID: "t1", title: "Night Piano"),
            track(serverID: serverID, remoteID: "t2", title: "Morning Run"),
        ])
        let written = try await classifyAll(store, serverID: serverID)
        #expect(written == 2)

        // 模拟旧索引：source_hash_version = 0（旧算法混入个人行为数据的 hash）。
        let db = await store.db
        try await db.run(
            "UPDATE recommendation_index_v2_state SET source_hash = 'old-hash', source_hash_version = 0",
            []
        )

        // 调用 status 触发迁移；迁移只重算 content hash，不调用模型、保留原 tags。
        let status = try await store.recommendationIndexV2Status(serverID: serverID)
        #expect(status.indexedTracks == 2)
        #expect(status.pendingTracks == 0)

        // 迁移后版本必须已更新。
        let rows = try await db.query(
            "SELECT source_hash_version FROM recommendation_index_v2_state WHERE server_id = ?",
            [.text(serverID.rawValue)]
        )
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0["source_hash_version"]?.int == 2 })

        // tags 完整保留。
        let read = try await store.readRecommendationIndexV2(serverID: serverID, dimension: "mood", value: "平静")
        #expect(read.count == 1)
    }

    @Test("export excludes pending and damaged records")
    func exportExcludesPending() async throws {
        let store = try makeStore()
        let serverID: ServerID = "server-b"
        try await seed(store, [
            track(serverID: serverID, remoteID: "t1", title: "Classified"),
            track(serverID: serverID, remoteID: "t2", title: "Pending"),
        ])
        // 只分类 t1。
        let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 100)
        guard let t1 = batch.tracks.first(where: { $0.id.contains("t1") }) else {
            Issue.record("missing t1 in batch")
            return
        }
        _ = try await store.writeRecommendationIndexV2([
            RecommendationIndexV2Classification(id: t1.id, moods: ["平静"], scenes: ["深夜"], energy: 3, confidence: 0.9)
        ], serverID: serverID)

        let package = try await store.exportRecommendationIndexV2Package(serverID: serverID)
        #expect(package.trackCount == 1)
        #expect(package.entries.count == 1)
        #expect(package.entries.first?.remoteTrackID == "t1")
    }

    @Test("import reports not found for missing tracks without failing the whole file")
    func importNotFoundCounted() async throws {
        let store = try makeStore()
        let serverB: ServerID = "server-b"
        try await seed(store, [track(serverID: serverB, remoteID: "t1", title: "Song")])
        let package = RecommendationIndexV2Package(
            formatVersion: 1,
            rulesVersion: RecommendationIndexV2.rulesVersion,
            contentHashVersion: RecommendationIndexV2.contentHashVersion,
            trackCount: 2,
            entries: [
                RecommendationIndexV2PackageEntry(
                    remoteTrackID: "t1",
                    contentHash: "whatever",
                    tags: [RecommendationIndexV2PackageTag(dimension: "mood", value: "平静", confidence: 0.9)],
                    classifier: "test"
                ),
                RecommendationIndexV2PackageEntry(
                    remoteTrackID: "missing-track",
                    contentHash: "whatever",
                    tags: [RecommendationIndexV2PackageTag(dimension: "mood", value: "平静", confidence: 0.9)],
                    classifier: "test"
                ),
            ]
        )
        let stats = try await store.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: serverB
        )
        #expect(stats.totalEntries == 2)
        #expect(stats.notFound == 1)
        // t1 的 contentHash 不匹配 → metadataChanged（内容不匹配时按“已变化”处理）。
        #expect(stats.metadataChanged == 1)
        #expect(stats.imported == 0)
    }

    private func assertMetadataChangeRejected(
        _ makeChangedTrack: (String) -> Track
    ) async throws {
        let storeA = try makeStore()
        let serverA: ServerID = "server-a"
        try await seed(storeA, [track(serverID: serverA, remoteID: "t1", title: "Same Song")])
        try await classifyAll(storeA, serverID: serverA)
        let package = try await storeA.exportRecommendationIndexV2Package(serverID: serverA)

        let storeB = try makeStore()
        let serverB: ServerID = "server-b"
        try await seed(storeB, [makeChangedTrack("Same Song")])
        let stats = try await storeB.importRecommendationIndexV2Package(
            data: try encodePackage(package),
            serverID: serverB
        )
        #expect(stats.imported == 0)
        #expect(stats.metadataChanged == 1)
        let status = try await storeB.recommendationIndexV2Status(serverID: serverB)
        #expect(status.indexedTracks == 0)
        #expect(status.pendingTracks == 1)
    }
}
