import Domain
import Foundation
import MusicLibrary

/// 可由 Agent 稳定生成、也便于之后检索的有限标签空间。
public enum RecommendationIndex {
    /// 固定音乐分析维度（结构化索引，不是用户标签系统）。
    public static let fixedDimensions: Set<String> = [
        "mood", "scene", "theme", "genre", "style",
        "vocal", "instrument", "texture", "rhythm",
        "energy", "tempo", "acousticness", "danceability",
        "instrumentalness", "liveness", "speechiness", "valence", "complexity",
    ]
    public static let rulesVersion = "3.0"
    /// 开放语义标签规则版本：只描述“开放标签生成/规范化规则”的版本，与
    /// rulesVersion（固定分类 taxonomy）相互独立。旧数据无开放标签视为 semanticTagRulesVersion = 0。
    @available(*, deprecated, message: "Open semantic tags are no longer produced by Recommendation Index")
    public static let semanticTagRulesVersion = 0
    /// 内容指纹算法版本：只描述“判断歌曲内容是否变化”的指纹算法，与
    /// rulesVersion（分类 taxonomy / prompt / schema 版本）相互独立。
    public static let contentHashVersion = 2
    /// Legacy display-name sets are derived from the canonical taxonomy. They
    /// remain for old callers, but new classification writes use TagID values.
    public static let moods: Set<String> = Set(
        RecommendationIndexTaxonomy.definitions(for: .mood).map(\.displayName)
    )
    public static let scenes: Set<String> = Set(
        RecommendationIndexTaxonomy.definitions(for: .scene).map(\.displayName)
    )
    public static let vocals: Set<String> = Set(
        RecommendationIndexTaxonomy.definitions(for: .vocal).map(\.displayName)
    )
    public static let textures: Set<String> = Set(
        RecommendationIndexTaxonomy.definitions(for: .texture).map(\.displayName)
    )
    public static let styles: Set<String> = Set(
        RecommendationIndexTaxonomy.definitions(for: .style).map(\.displayName)
    )

    /// 开放语义标签规范化（唯一实现）：trim → Unicode 规范化 → 去掉无意义首尾 # →
    /// 折叠连续空白 → 空值过滤。展示值保留 canonical form；比较时按小写归一避免同义分叉。
    public static func normalizeSemanticTag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let unicodeNormalized = trimmed.precomposedStringWithCanonicalMapping
        var cleaned = unicodeNormalized
        while cleaned.hasPrefix("#") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // 折叠连续空白（含全角空格）。
        cleaned = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// 开放标签比较键（大小写不敏感 + 规范化）。
    public static func semanticTagKey(_ canonical: String) -> String {
        canonical.lowercased()
    }
}

/// Strict Runtime writes use this error to reject an entire batch before the
/// catalog transaction starts. The legacy non-strict API intentionally keeps
/// its historical behavior of ignoring unknown IDs for compatibility callers.
public enum RecommendationIndexWriteError: Error, LocalizedError, Sendable, Equatable {
    case invalidBatch

    public var errorDescription: String? {
        "推荐索引批次包含无法验证的分类，未写入任何数据"
    }
}

/// V2 pending 统一语义：fixed / semantic 是两类工作集合，unique 是至少有一项工作未完成的
/// 唯一歌曲数（新歌同时缺两类只计一次）。
private struct RecommendationIndexPendingState {
    let fixed: Set<String>

    var unique: Set<String> { fixed }
}

extension LocalCatalogStore {
    /// 清空一个服务器的 Recommendation Index 结果。
    /// 只删除该服务器的 state / tag 行，不触碰歌曲、封面、下载、播放历史或其他服务器的索引。
    /// 语义标签词表是跨服务器共享的 canonical 化辅助数据，因此保留，避免影响其他服务器。
    public func clearRecommendationIndex(serverID: ServerID) throws {
        try db.transaction {
            // tags 表没有 server_id，必须先由 state 表限定身份再删除，防止跨服务器误删。
            try db.run(
                """
                DELETE FROM recommendation_index_v2_tags
                WHERE global_id IN (
                    SELECT global_id FROM recommendation_index_v2_state WHERE server_id = ?
                )
                """,
                [.text(serverID.rawValue)]
            )
            try db.run(
                "DELETE FROM recommendation_index_v2_state WHERE server_id = ?",
                [.text(serverID.rawValue)]
            )
        }
    }

    /// 统一计算 pending 集合：只按 content hash 判定固定分类是否需要重建。
    private func recommendationIndexPendingState(
        snapshot: (lines: [CatalogTrackLine], states: [String: RecommendationIndexStoredState])
    ) throws -> RecommendationIndexPendingState {
        var fixed = Set<String>()
        for line in snapshot.lines {
            if snapshot.states[line.id]?.hash != recommendationIndexContentHash(line) {
                fixed.insert(line.id)
            }
        }
        return RecommendationIndexPendingState(fixed: fixed)
    }

    public func recommendationIndexStatus(serverID: ServerID?) throws -> RecommendationIndexStatus {
        let snapshot = try recommendationIndexSnapshot(serverID: serverID)
        let indexed = snapshot.lines.filter { line in
            snapshot.states[line.id]?.hash == recommendationIndexContentHash(line)
        }.count
        let pending = try recommendationIndexPendingState(snapshot: snapshot)
        return RecommendationIndexStatus(
            totalTracks: snapshot.lines.count,
            indexedTracks: indexed,
            pendingTracks: pending.fixed.count,
            rulesVersion: RecommendationIndex.rulesVersion,
            semanticTaggedTracks: 0,
            semanticProcessedTracks: 0,
            pendingSemanticTagTracks: 0,
            pendingUniqueTracks: pending.unique.count
        )
    }

    /// catalog migration key/version：fixed taxonomy v3 cleanup.
    static let fixedTaxonomyMigrationKey = "recommendation_v3_fixed_taxonomy"
    static let fixedTaxonomyMigrationVersion = 1

    nonisolated func runCatalogMigrations() throws {
        try migrateRecommendationFixedTaxonomyIfNeeded()
    }

    @available(*, deprecated, message: "Open semantic tags are no longer used")
    static let semanticCanonicalMigrationKey = "recommendation_v2_semantic_canonical"
    @available(*, deprecated, message: "Open semantic tags are no longer used")
    static let semanticCanonicalMigrationVersion = 0

    @available(*, deprecated, message: "Open semantic tags are no longer used")
    func recommendationIndexSemanticTaggedIDs(serverID: ServerID?) throws -> Set<String> { [] }

    @available(*, deprecated, message: "Open semantic tags are no longer used")
    func recommendationIndexSemanticCanonicalMap(serverID: ServerID?) throws -> [String: String] { [:] }

    @available(*, deprecated, message: "Open semantic tags are no longer used")
    nonisolated func migrateRecommendationSemanticCanonicalIfNeeded() throws {}

    /// Deletes legacy AI-created semantic tag rows and drops the now-unused
    /// vocabulary table. Fixed taxonomy state is deliberately left untouched:
    /// its rulesVersion mismatch makes old classifications naturally pending.
    nonisolated func migrateRecommendationFixedTaxonomyIfNeeded() throws {
        let applied = try db.query(
            "SELECT version FROM catalog_migrations WHERE key = ?",
            [.text(Self.fixedTaxonomyMigrationKey)]
        ).first?["version"]?.int ?? 0
        guard applied < Self.fixedTaxonomyMigrationVersion else { return }

        try db.transaction {
            try db.run("DELETE FROM recommendation_index_v2_tags WHERE dimension = 'tag'")
            try db.run("DROP TABLE IF EXISTS recommendation_index_v2_tag_vocabulary")
            try db.run(
                """
                INSERT INTO catalog_migrations (key, version, applied_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET version = excluded.version, applied_at = excluded.applied_at
                """,
                [.text(Self.fixedTaxonomyMigrationKey), .integer(Int64(Self.fixedTaxonomyMigrationVersion)), .real(Date.now.timeIntervalSince1970)]
            )
        }
    }

    /// 下一批只做固定 taxonomy 分类。旧 rulesVersion 索引会因 hash/rulesVersion
    /// 不匹配自然进入 pending，不迁移到新标签空间。
    public func nextRecommendationIndexBatch(serverID: ServerID?, limit: Int = 80) throws -> RecommendationIndexBatch {
        let snapshot = try recommendationIndexSnapshot(serverID: serverID)
        let pending = try recommendationIndexPendingState(snapshot: snapshot)

        guard !pending.fixed.isEmpty else {
            return RecommendationIndexBatch(
                tracks: [],
                pendingFixedTracks: 0,
                pendingSemanticTagTracks: 0,
                pendingUniqueTracks: 0,
                rulesVersion: RecommendationIndex.rulesVersion,
                mode: "done"
            )
        }
        let source = snapshot.lines.filter { pending.fixed.contains($0.id) }
        let batch = Array(source.prefix(min(max(limit, 1), 100)))
        return RecommendationIndexBatch(
            tracks: batch,
            pendingFixedTracks: pending.fixed.count,
            pendingSemanticTagTracks: 0,
            pendingUniqueTracks: pending.unique.count,
            rulesVersion: RecommendationIndex.rulesVersion,
            mode: "full"
        )
    }

    @discardableResult
    public func writeRecommendationIndex(
        _ classifications: [RecommendationIndexClassification],
        serverID: ServerID?,
        classifier: String = "configured-agent",
        requireExact: Bool = false
    ) throws -> Int {
        let snapshot = try recommendationIndexSnapshot(serverID: serverID)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.lines.map { ($0.id, $0) })
        if requireExact,
           classifications.prefix(100).contains(where: { !Self.hasOnlyResolvableTaxonomy($0) }) {
            throw RecommendationIndexWriteError.invalidBatch
        }
        let normalized = classifications.prefix(100).map(Self.canonicalizedClassification)
        let valid = normalized.compactMap { item -> (RecommendationIndexClassification, CatalogTrackLine)? in
            guard let line = byID[item.id], Self.hasOnlyValidTaxonomy(item) else { return nil }
            return (item, line)
        }
        if requireExact,
           classifications.count > 100 || valid.count != normalized.count {
            // Do this check before opening the transaction. A malformed item
            // must never allow the valid prefix to become a partial commit.
            throw RecommendationIndexWriteError.invalidBatch
        }
        if requireExact {
            if !normalized.allSatisfy(Self.hasOnlyValidTaxonomy) {
                throw RecommendationIndexWriteError.invalidBatch
            }
        }
        guard !valid.isEmpty else { return 0 }

        try db.transaction {
            for (item, line) in valid {
                let confidence = min(max(item.confidence, 0), 1)
                try db.run("DELETE FROM recommendation_index_v2_tags WHERE global_id = ?", [.text(item.id)])
                try db.run(
                    """
                    INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at, source_hash_version, semantic_tag_rules_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(global_id) DO UPDATE SET source_hash = excluded.source_hash, rules_version = excluded.rules_version,
                    classifier = excluded.classifier, classified_at = excluded.classified_at,
                    source_hash_version = excluded.source_hash_version,
                    semantic_tag_rules_version = excluded.semantic_tag_rules_version
                    """,
                    [.text(item.id), .text(GlobalID(item.id)?.serverID.rawValue ?? ""), .text(recommendationIndexContentHash(line)),
                     .text(RecommendationIndex.rulesVersion), .text(classifier), .real(Date.now.timeIntervalSince1970),
                     .integer(Int64(RecommendationIndex.contentHashVersion)),
                     // The legacy state column remains for old databases; v3 never produces open tags.
                     .integer(0)]
                )
                try recommendationIndexInsertTags(item.moods, dimension: .mood, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.scenes, dimension: .scene, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.themes, dimension: .theme, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.genres, dimension: .genre, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.styles, dimension: .style, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.vocals, dimension: .vocal, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.instruments, dimension: .instrument, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.textures, dimension: .texture, id: item.id, confidence: confidence)
                try recommendationIndexInsertTags(item.rhythms, dimension: .rhythm, id: item.id, confidence: confidence)
                try recommendationIndexInsertNumericTags(item, id: item.id, confidence: confidence)
            }
        }
        return valid.count
    }

    /// 用 V2 场景/情绪标签取候选；未完成索引时调用方可回退到原有流派推荐。
    public func recommendationIndexTrackIDs(serverID: ServerID, query: String, limit: Int = 200) throws -> [GlobalID] {
        let tagID = Self.resolvedTagID(query) ?? query
        let rows = try db.query(
            """
            SELECT t.global_id FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.server_id = ? AND s.rules_version = ? AND t.value = ? AND t.dimension IN ('mood', 'scene')
            ORDER BY t.confidence DESC LIMIT ?
            """,
            [.text(serverID.rawValue), .text(RecommendationIndex.rulesVersion), .text(tagID), .integer(Int64(min(max(limit, 1), 500)))]
        )
        return rows.compactMap { $0["global_id"]?.string }.compactMap(GlobalID.init)
    }

    /// Structured fixed-taxonomy recommendation query. Include tags are hard
    /// filters, exclude tags remove tracks, and prefer tags rank the result.
    public func recommendationIndexTrackIDs(
        serverID: ServerID,
        matching query: RecommendationIndexQuery
    ) throws -> [GlobalID] {
        let includeIDs = query.includeTags.compactMap(Self.resolvedTagID)
        let excludeIDs = query.excludeTags.compactMap(Self.resolvedTagID)
        let preferIDs = query.preferTags.compactMap(Self.resolvedTagID)
        var sql = """
            SELECT s.global_id,
                   COALESCE((
                       SELECT COUNT(*) FROM recommendation_index_v2_tags p
                       WHERE p.global_id = s.global_id AND p.value IN (\(preferIDs.map { _ in "?" }.joined(separator: ",")))
                   ), 0) AS preference_score
            FROM recommendation_index_v2_state s
            JOIN recommendation_index_v2_tags t ON t.global_id = s.global_id
            WHERE s.server_id = ? AND s.rules_version = ?
        """
        var values: [SQLiteValue] = preferIDs.map { SQLiteValue.text($0) }
        values.append(contentsOf: [.text(serverID.rawValue), .text(RecommendationIndex.rulesVersion)])
        if !includeIDs.isEmpty {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE value IN (\(includeIDs.map { _ in "?" }.joined(separator: ","))))"
            values.append(contentsOf: includeIDs.map { SQLiteValue.text($0) })
        }
        if !excludeIDs.isEmpty {
            sql += " AND s.global_id NOT IN (SELECT global_id FROM recommendation_index_v2_tags WHERE value IN (\(excludeIDs.map { _ in "?" }.joined(separator: ","))))"
            values.append(contentsOf: excludeIDs.map { SQLiteValue.text($0) })
        }
        if let range = query.energyRange {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE dimension = 'energy' AND CAST(value AS INTEGER) BETWEEN ? AND ?)"
            values.append(contentsOf: [.integer(Int64(range.lowerBound)), .integer(Int64(range.upperBound))])
        }
        if let range = query.tempoRange {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE dimension = 'tempo' AND CAST(value AS INTEGER) BETWEEN ? AND ?)"
            values.append(contentsOf: [.integer(Int64(range.lowerBound)), .integer(Int64(range.upperBound))])
        }
        if let range = query.danceabilityRange {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE dimension = 'danceability' AND CAST(value AS INTEGER) BETWEEN ? AND ?)"
            values.append(contentsOf: [.integer(Int64(range.lowerBound)), .integer(Int64(range.upperBound))])
        }
        if let range = query.acousticnessRange {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE dimension = 'acousticness' AND CAST(value AS INTEGER) BETWEEN ? AND ?)"
            values.append(contentsOf: [.integer(Int64(range.lowerBound)), .integer(Int64(range.upperBound))])
        }
        if let range = query.instrumentalnessRange {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE dimension = 'instrumentalness' AND CAST(value AS INTEGER) BETWEEN ? AND ?)"
            values.append(contentsOf: [.integer(Int64(range.lowerBound)), .integer(Int64(range.upperBound))])
        }
        if let range = query.valenceRange {
            sql += " AND s.global_id IN (SELECT global_id FROM recommendation_index_v2_tags WHERE dimension = 'valence' AND CAST(value AS INTEGER) BETWEEN ? AND ?)"
            values.append(contentsOf: [.integer(Int64(range.lowerBound)), .integer(Int64(range.upperBound))])
        }
        sql += " GROUP BY s.global_id ORDER BY preference_score DESC, MAX(t.confidence) DESC LIMIT ?"
        values.append(.integer(Int64(query.limit)))
        let rows = try db.query(sql, values)
        return rows.compactMap { $0["global_id"]?.string }.compactMap(GlobalID.init)
    }

    /// 读取已完成且仍与当前曲目元数据匹配的索引记录。
    /// `dimension`/`value` 均为可选筛选条件；返回每首歌的完整标签，便于 Agent 解释或再次筛选。
    public func readRecommendationIndex(
        serverID: ServerID?,
        dimension: String? = nil,
        value: String? = nil,
        limit: Int = 50
    ) throws -> [RecommendationIndexIndexedTrack] {
        let snapshot = try recommendationIndexSnapshot(serverID: serverID)
        let validLines = Dictionary(uniqueKeysWithValues: snapshot.lines.filter {
            snapshot.states[$0.id]?.hash == recommendationIndexContentHash($0)
        }.map { ($0.id, $0) })
        guard !validLines.isEmpty else { return [] }

        let rows = try db.query(
            """
            SELECT t.global_id, t.dimension, t.value, t.confidence
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.rules_version = ?
            \(serverID == nil ? "" : "AND s.server_id = ?")
            ORDER BY t.confidence DESC, t.global_id ASC, t.dimension ASC, t.value ASC
            """,
            serverID.map { [.text(RecommendationIndex.rulesVersion), .text($0.rawValue)] }
                ?? [.text(RecommendationIndex.rulesVersion)]
        )

        var tagsByID: [String: [String: [String]]] = [:]
        var confidenceByID: [String: Double] = [:]
        for row in rows {
            guard let id = row["global_id"]?.string, validLines[id] != nil,
                  let rowDimension = row["dimension"]?.string, let rowValue = row["value"]?.string
            else { continue }
            let display = RecommendationIndexTaxonomy.displayName(for: TagID(rawValue: rowValue)) ?? rowValue
            tagsByID[id, default: [:]][rowDimension, default: []].append(display)
            confidenceByID[id] = max(confidenceByID[id] ?? 0, row["confidence"]?.double ?? 0)
        }

        let normalizedDimension = dimension?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedValue = value.flatMap(Self.resolvedTagID) ?? value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return tagsByID.compactMap { id, tags -> RecommendationIndexIndexedTrack? in
            guard let line = validLines[id] else { return nil }
            if let normalizedDimension {
                guard let values = tags[normalizedDimension] else { return nil }
                if let normalizedValue,
                   !values.contains(where: {
                       $0.localizedCaseInsensitiveCompare(normalizedValue) == .orderedSame
                           || RecommendationIndexTaxonomy.resolve($0)?.id.rawValue == normalizedValue
                   }) {
                    return nil
                }
            } else if let normalizedValue,
                      !tags.values.joined().contains(where: {
                          $0.localizedCaseInsensitiveCompare(normalizedValue) == .orderedSame
                              || RecommendationIndexTaxonomy.resolve($0)?.id.rawValue == normalizedValue
                      }) {
                return nil
            }
            let stableTags = tags.mapValues { Array(Set($0)).sorted() }
            return RecommendationIndexIndexedTrack(track: line, tags: stableTags, confidence: confidenceByID[id] ?? 0)
        }
        .sorted { lhs, rhs in
            lhs.confidence == rhs.confidence ? lhs.track.id < rhs.track.id : lhs.confidence > rhs.confidence
        }
        .prefix(min(max(limit, 1), 100))
        .map { $0 }
    }

    /// 返回资料库「分类」页所需的 V2 标签及各自歌曲数。
    /// `dimensions` 非空时只返回指定维度（例如固定维度），用于避免把全部开放语义标签
    /// 一次读进内存；开放标签用 `recommendationIndexTagCatalog` 按需分页。
    /// 与推荐查询保持同一可见范围：当前规则版本、当前服务器，且不暴露歌词/路径/播放地址。
    public func recommendationIndexCategories(
        serverID: ServerID?,
        dimensions: Set<String>? = nil
    ) throws -> [RecommendationIndexCategory] {
        var sql = """
            SELECT t.dimension, t.value, COUNT(DISTINCT t.global_id) AS track_count
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.rules_version = ?
        """
        var values: [SQLiteValue] = [.text(RecommendationIndex.rulesVersion)]
        if let serverID {
            sql += " AND s.server_id = ?"
            values.append(.text(serverID.rawValue))
        }
        if let dimensions, !dimensions.isEmpty {
            let placeholders = dimensions.sorted().map { _ in "?" }.joined(separator: ",")
            sql += " AND t.dimension IN (\(placeholders))"
            values.append(contentsOf: dimensions.sorted().map { SQLiteValue.text($0) })
        }
        sql += " GROUP BY t.dimension, t.value ORDER BY track_count DESC, t.dimension ASC, t.value ASC"
        let rows = try db.query(sql, values)
        return rows.compactMap { row in
            guard let dimension = row["dimension"]?.string,
                  let value = row["value"]?.string,
                  !dimension.isEmpty, !value.isEmpty
            else { return nil }
            return RecommendationIndexCategory(
                dimension: dimension,
                value: RecommendationIndexTaxonomy.displayName(for: TagID(rawValue: value)) ?? value,
                trackCount: Int(row["track_count"]?.int ?? 0)
            )
        }
    }

    /// 开放语义标签词库分页（真正 SQL 分页，总量不受页大小限制）。
    @available(*, deprecated, message: "Open semantic tag catalog is no longer used")
    public func recommendationIndexTagCatalog(
        serverID: ServerID?,
        query: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> RecommendationIndexTagPage {
        _ = (serverID, query, limit, offset)
        return RecommendationIndexTagPage(items: [], nextOffset: nil, hasMore: false)
    }

    /// 读取某个 V2 分类下的真实曲目，供资料库详情页直接播放与加入队列。
    public func recommendationIndexTracks(
        serverID: ServerID?,
        dimension: String,
        value: String
    ) throws -> [Track] {
        let resolved = Self.resolvedTagID(value) ?? value
        let rows = try db.query(
            """
            SELECT tr.payload
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            JOIN tracks tr ON tr.global_id = t.global_id
            WHERE s.rules_version = ? AND t.dimension = ? AND t.value = ?
            \(serverID == nil ? "" : "AND s.server_id = ?")
            ORDER BY t.confidence DESC, t.global_id ASC
            """,
            serverID.map { [.text(RecommendationIndex.rulesVersion), .text(dimension), .text(resolved), .text($0.rawValue)] }
                ?? [.text(RecommendationIndex.rulesVersion), .text(dimension), .text(resolved)]
        )
        // 分类详情必须只解码命中的 Track payload。此前先全量 allTracks(limit: 20_000)
        // 再在内存映射，不仅每次点击都会扫描整个曲库，超过 20,000 首还会静默漏歌。
        return rows.compactMap { row in
            guard let payload = row["payload"]?.string else { return nil }
            return try? decode(Track.self, payload)
        }
    }

    private static func resolvedTagID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if RecommendationIndexTaxonomy.byID[TagID(rawValue: trimmed)] != nil {
            return trimmed
        }
        return RecommendationIndexTaxonomy.resolve(trimmed)?.id.rawValue
    }

    func recommendationIndexSnapshot(serverID: ServerID?) throws -> (lines: [CatalogTrackLine], states: [String: RecommendationIndexStoredState]) {
        // 分类写入也必须看到完整资料库；否则第 20,000 首之后的歌曲永远不会进入推荐索引。
        let tracks = try allTracks(serverID: serverID)
        let popularity = try popularityScores(serverID: serverID)
        let favorites = Set(try getFavorites(serverID: serverID).map(\.globalID))
        let ratingsByID = serverID.flatMap { try? self.ratings(serverID: $0) } ?? [:]
        let lines = tracks.map { track -> CatalogTrackLine in
            let id = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            return CatalogTrackLine(
                id: id.description, title: track.title, artist: track.artistName, album: track.albumTitle,
                year: track.year, genres: track.genres, language: track.language, duration: Int(track.duration),
                isFavorite: track.isFavorite || favorites.contains(id), rating: ratingsByID[id] ?? track.rating,
                playCount: popularity[id]?.playCount ?? 0, isDownloaded: false
            )
        }.sorted { lhs, rhs in lhs.id < rhs.id }
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query("SELECT global_id, source_hash, rules_version, source_hash_version, semantic_tag_rules_version FROM recommendation_index_v2_state WHERE server_id = ?", [.text(serverID.rawValue)])
        } else {
            rows = try db.query("SELECT global_id, source_hash, rules_version, source_hash_version, semantic_tag_rules_version FROM recommendation_index_v2_state")
        }
        var states: [String: RecommendationIndexStoredState] = [:]
        for row in rows where row["rules_version"]?.string == RecommendationIndex.rulesVersion {
            if let id = row["global_id"]?.string, let hash = row["source_hash"]?.string {
                states[id] = RecommendationIndexStoredState(
                    hash: hash,
                    hashVersion: Int(row["source_hash_version"]?.int ?? 0),
                    semanticTagRulesVersion: Int(row["semantic_tag_rules_version"]?.int ?? 0)
                )
            }
        }
        // 旧算法把 favorite/rating/playCount 也混入 hash。升级后这些个人行为数据不再
        // 属于内容指纹，旧索引必须本地重算 content hash（不调用模型、保留原 tags）。
        try migrateStaleContentHash(lines: lines, states: &states)
        return (lines, states)
    }

    /// 历史索引迁移：source_hash_version 缺失或低于当前版本时，按当前歌曲内容
    /// 重新计算 content hash 并原地更新。只有歌曲仍存在且 tags 完整时才迁移；
    /// track 不存在 / tags 损坏的条目保持原样，会自然进入 pending。
    private func migrateStaleContentHash(
        lines: [CatalogTrackLine],
        states: inout [String: RecommendationIndexStoredState]
    ) throws {
        let stale = states.filter { $0.value.hashVersion < RecommendationIndex.contentHashVersion }
        guard !stale.isEmpty else { return }
        let lineByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        var updated: [(String, String)] = []
        for (id, _) in stale {
            guard let line = lineByID[id] else { continue }
            let hasTags = (try? db.query(
                "SELECT 1 FROM recommendation_index_v2_tags WHERE global_id = ? LIMIT 1",
                [.text(id)]
            ).isEmpty == false) ?? false
            guard hasTags else { continue }
            updated.append((id, recommendationIndexContentHash(line)))
        }
        guard !updated.isEmpty else { return }
        try db.transaction {
            for (id, hash) in updated {
                try db.run(
                    "UPDATE recommendation_index_v2_state SET source_hash = ?, source_hash_version = ? WHERE global_id = ?",
                    [.text(hash), .integer(Int64(RecommendationIndex.contentHashVersion)), .text(id)]
                )
                states[id]?.hash = hash
                states[id]?.hashVersion = RecommendationIndex.contentHashVersion
            }
        }
    }

    private func recommendationIndexInsertTags(
        _ values: [String],
        dimension: TagDimension,
        id: String,
        confidence: Double
    ) throws {
        for value in values {
            let tagID = TagID(rawValue: value)
            guard RecommendationIndexTaxonomy.byID[tagID]?.dimension == dimension else { continue }
            try db.run(
                "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)",
                [.text(id), .text(dimension.rawValue), .text(value), .real(confidence)]
            )
        }
    }

    private func recommendationIndexInsertNumericTags(
        _ item: RecommendationIndexClassification,
        id: String,
        confidence: Double
    ) throws {
        let values: [(String, Int?)] = [
            ("energy", item.energy),
            ("tempo", item.tempo),
            ("acousticness", item.acousticness),
            ("danceability", item.danceability),
            ("instrumentalness", item.instrumentalness),
            ("liveness", item.liveness),
            ("speechiness", item.speechiness),
            ("valence", item.valence),
            ("complexity", item.complexity),
        ]
        for (dimension, value) in values {
            guard let value else { continue }
            try db.run(
                "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)",
                [.text(id), .text(dimension), .text(String(value)), .real(confidence)]
            )
        }
    }

    private static func canonicalizedClassification(
        _ item: RecommendationIndexClassification
    ) -> RecommendationIndexClassification {
        var moods: [String] = []
        var scenes: [String] = []
        var themes: [String] = []
        var genres: [String] = []
        var styles: [String] = []
        var vocals: [String] = []
        var instruments: [String] = []
        var textures: [String] = []
        var rhythms: [String] = []
        func route(_ raw: String, to expected: TagDimension) {
            guard let definition = RecommendationIndexTaxonomy.resolve(raw) else { return }
            let destination = definition.dimension == expected ? expected : definition.dimension
            switch destination {
            case .mood: moods.append(definition.id.rawValue)
            case .scene: scenes.append(definition.id.rawValue)
            case .theme: themes.append(definition.id.rawValue)
            case .genre: genres.append(definition.id.rawValue)
            case .style: styles.append(definition.id.rawValue)
            case .vocal: vocals.append(definition.id.rawValue)
            case .instrument: instruments.append(definition.id.rawValue)
            case .texture: textures.append(definition.id.rawValue)
            case .rhythm: rhythms.append(definition.id.rawValue)
            }
        }
        item.moods.forEach { route($0, to: .mood) }
        item.scenes.forEach { route($0, to: .scene) }
        item.themes.forEach { route($0, to: .theme) }
        item.genres.forEach { route($0, to: .genre) }
        item.styles.forEach { route($0, to: .style) }
        item.vocals.forEach { route($0, to: .vocal) }
        item.instruments.forEach { route($0, to: .instrument) }
        item.textures.forEach { route($0, to: .texture) }
        item.rhythms.forEach { route($0, to: .rhythm) }
        return RecommendationIndexClassification(
            id: item.id,
            moods: Array(Set(moods)).sorted(),
            scenes: Array(Set(scenes)).sorted(),
            energy: item.energy,
            tempo: item.tempo,
            acousticness: item.acousticness,
            danceability: item.danceability,
            vocals: Array(Set(vocals)).sorted(),
            textures: Array(Set(textures)).sorted(),
            styles: Array(Set(styles)).sorted(),
            mode: item.mode,
            confidence: item.confidence,
            themes: Array(Set(themes)).sorted(),
            genres: Array(Set(genres)).sorted(),
            instruments: Array(Set(instruments)).sorted(),
            rhythms: Array(Set(rhythms)).sorted(),
            instrumentalness: item.instrumentalness,
            liveness: item.liveness,
            speechiness: item.speechiness,
            valence: item.valence,
            complexity: item.complexity
        )
    }

    private static func hasOnlyResolvableTaxonomy(_ item: RecommendationIndexClassification) -> Bool {
        let arrays: [[String]] = [
            item.moods, item.scenes, item.themes, item.genres, item.styles,
            item.vocals, item.instruments, item.textures, item.rhythms,
        ]
        return arrays.allSatisfy { values in
            values.allSatisfy { RecommendationIndexTaxonomy.resolve($0) != nil }
        }
    }

    private static func hasOnlyValidTaxonomy(_ item: RecommendationIndexClassification) -> Bool {
        let categorical: [(TagDimension, [String])] = [
            (.mood, item.moods),
            (.scene, item.scenes),
            (.theme, item.themes),
            (.genre, item.genres),
            (.style, item.styles),
            (.vocal, item.vocals),
            (.instrument, item.instruments),
            (.texture, item.textures),
            (.rhythm, item.rhythms),
        ]
        for (dimension, values) in categorical {
            for value in values {
                let tagID = TagID(rawValue: value)
                guard RecommendationIndexTaxonomy.byID[tagID]?.dimension == dimension else {
                    return false
                }
            }
        }
        let numericRanges: [(Int?, ClosedRange<Int>)] = [
            (item.energy, 1...10),
            (item.tempo, 1...5),
            (item.acousticness, 1...5),
            (item.danceability, 1...5),
            (item.instrumentalness, 1...5),
            (item.liveness, 1...5),
            (item.speechiness, 1...5),
            (item.valence, 1...5),
            (item.complexity, 1...5),
        ]
        for (value, range) in numericRanges {
            if let value, !range.contains(value) {
                return false
            }
        }
        return true
    }

    /// V2 内容指纹：只包含相对稳定的音乐内容身份字段。
    ///
    /// 明确**不**包含 favorite / rating / playCount / skipCount / completionRate /
    /// 下载状态等个人行为数据——用户收藏、评分、播放次数改变不应让 mood / scene /
    /// texture / style / energy / tempo 等内容分类全部失效。个人数据仍然保留在
    /// LocalCatalog（favorites / ratings / play_history），只用于推荐排序与个性化。
    func recommendationIndexContentHash(_ line: CatalogTrackLine) -> String {
        let remoteID = GlobalID(line.id)?.remoteID ?? ""
        // genre 标准化：trim → 去空 → 去重 → sort，避免数组顺序不同导致 hash 不同。
        let normalizedGenres = Array(Set(
            line.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )).sorted()
        // duration 使用稳定整数秒（CatalogTrackLine.duration 已由 Double 取整），
        // 不直接 hash 任意 Double 字符串。
        let parts = [
            remoteID,
            line.title.trimmingCharacters(in: .whitespacesAndNewlines),
            line.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            line.album.trimmingCharacters(in: .whitespacesAndNewlines),
            line.year.map(String.init) ?? "",
            normalizedGenres.joined(separator: "|"),
            line.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(line.duration),
        ]
        let source = parts.joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

/// 一条已入库的推荐索引状态：内容 hash + hash 算法版本 + 语义标签规则版本。
struct RecommendationIndexStoredState {
    var hash: String
    var hashVersion: Int
    /// 该曲目的开放语义标签是按哪个 semanticTagRulesVersion 生成的（0 = 尚未生成）。
    var semanticTagRulesVersion: Int
}
