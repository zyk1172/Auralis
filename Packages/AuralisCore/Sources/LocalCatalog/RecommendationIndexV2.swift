import Domain
import Foundation
import MusicLibrary

/// 可由 Agent 稳定生成、也便于之后检索的有限标签空间。
public enum RecommendationIndexV2 {
    /// 固定音乐分析维度（结构化索引，不是用户标签系统）。
    public static let fixedDimensions: Set<String> = [
        "mood", "scene", "vocal", "texture", "style",
        "energy", "tempo", "acousticness", "danceability",
    ]
    public static let rulesVersion = "2.1"
    /// 开放语义标签规则版本：只描述“开放标签生成/规范化规则”的版本，与
    /// rulesVersion（固定分类 taxonomy）相互独立。旧数据无开放标签视为 semanticTagRulesVersion = 0。
    public static let semanticTagRulesVersion = 1
    /// 内容指纹算法版本：只描述“判断歌曲内容是否变化”的指纹算法，与
    /// rulesVersion（分类 taxonomy / prompt / schema 版本）相互独立。
    public static let contentHashVersion = 2
    public static let moods: Set<String> = ["平静", "治愈", "忧郁", "浪漫", "明亮", "激昂", "神秘", "紧张", "怀旧", "温暖", "冷冽", "慵懒", "梦幻", "迷离", "释然", "孤独", "甜蜜", "愤怒", "庄严", "俏皮"]
    public static let scenes: Set<String> = ["深夜", "清晨", "通勤", "学习", "专注", "运动", "聚会", "独处", "旅行", "雨天", "驾车", "工作", "阅读", "冥想", "约会", "派对", "睡前", "散步"]
    public static let vocals: Set<String> = ["女声", "男声", "童声", "合唱", "对唱", "器乐", "说唱", "未知"]
    public static let textures: Set<String> = ["原声", "电子", "钢琴", "吉他", "贝斯", "鼓组", "弦乐", "管乐", "合成器", "人声采样", "现场", "氛围", "Lo-fi", "失真"]
    public static let styles: Set<String> = ["流行", "摇滚", "民谣", "爵士", "古典", "嘻哈", "R&B", "灵魂乐", "电子", "舞曲", "金属", "朋克", "乡村", "蓝调", "雷鬼", "世界音乐", "原声带", "氛围", "轻音乐", "实验"]

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

/// V2 pending 统一语义：fixed / semantic 是两类工作集合，unique 是至少有一项工作未完成的
/// 唯一歌曲数（新歌同时缺两类只计一次）。
private struct RecommendationIndexV2PendingState {
    let fixed: Set<String>
    let semantic: Set<String>

    var unique: Set<String> { fixed.union(semantic) }
}

extension LocalCatalogStore {
    /// 清空一个服务器的 Recommendation Index V2 结果。
    /// 只删除该服务器的 state / tag 行，不触碰歌曲、封面、下载、播放历史或其他服务器的索引。
    /// 语义标签词表是跨服务器共享的 canonical 化辅助数据，因此保留，避免影响其他服务器。
    public func clearRecommendationIndexV2(serverID: ServerID) throws {
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

    /// 统一计算 pending 集合：固定分类（content hash 未匹配/过期）与开放语义标签
    /// （semanticTagRulesVersion 低于当前）。status / nextBatch / completion 共用。
    private func recommendationIndexV2PendingState(
        snapshot: (lines: [CatalogTrackLine], states: [String: RecommendationIndexV2StoredState])
    ) throws -> RecommendationIndexV2PendingState {
        var fixed = Set<String>()
        var semantic = Set<String>()
        for line in snapshot.lines {
            if snapshot.states[line.id]?.hash != recommendationIndexV2ContentHash(line) {
                fixed.insert(line.id)
            }
            let version = snapshot.states[line.id]?.semanticTagRulesVersion ?? 0
            if version < RecommendationIndexV2.semanticTagRulesVersion {
                semantic.insert(line.id)
            }
        }
        return RecommendationIndexV2PendingState(fixed: fixed, semantic: semantic)
    }

    public func recommendationIndexV2Status(serverID: ServerID?) throws -> RecommendationIndexV2Status {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let indexed = snapshot.lines.filter { line in
            snapshot.states[line.id]?.hash == recommendationIndexV2ContentHash(line)
        }.count
        let pending = try recommendationIndexV2PendingState(snapshot: snapshot)
        let tagged = try recommendationIndexV2SemanticTaggedIDs(serverID: serverID)
        return RecommendationIndexV2Status(
            totalTracks: snapshot.lines.count,
            indexedTracks: indexed,
            pendingTracks: pending.fixed.count,
            rulesVersion: RecommendationIndexV2.rulesVersion,
            semanticTaggedTracks: tagged.count,
            semanticProcessedTracks: snapshot.lines.count - pending.semantic.count,
            pendingSemanticTagTracks: pending.semantic.count,
            pendingUniqueTracks: pending.unique.count
        )
    }

    /// 已有开放语义标签（dimension='tag'）的曲目 ID 集合（按服务器过滤，tags 表无 server_id 列）。
    func recommendationIndexV2SemanticTaggedIDs(serverID: ServerID?) throws -> Set<String> {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                """
                SELECT DISTINCT t.global_id FROM recommendation_index_v2_tags t
                JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
                WHERE t.dimension = 'tag' AND s.server_id = ?
                """,
                [.text(serverID.rawValue)]
            )
        } else {
            rows = try db.query("SELECT DISTINCT global_id FROM recommendation_index_v2_tags WHERE dimension = 'tag'")
        }
        return Set(rows.compactMap { $0["global_id"]?.string })
    }

    /// 跨歌曲 canonical 映射：normalizedKey → 使用最多的展示值（Lo-fi / lo-fi / LO-FI 归一到同一 display）。
    /// 读取现有 dimension='tag' 全部值，按 normalizeSemanticTag 的 key 归组，取出现次数最多的写法。
    func recommendationIndexV2SemanticCanonicalMap(serverID: ServerID?) throws -> [String: String] {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                """
                SELECT t.value, COUNT(*) AS n FROM recommendation_index_v2_tags t
                JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
                WHERE t.dimension = 'tag' AND s.server_id = ?
                GROUP BY t.value
                """,
                [.text(serverID.rawValue)]
            )
        } else {
            rows = try db.query(
                "SELECT value, COUNT(*) AS n FROM recommendation_index_v2_tags WHERE dimension = 'tag' GROUP BY value"
            )
        }
        var counts: [String: (display: String, count: Int)] = [:]
        for row in rows {
            guard let raw = row["value"]?.string,
                  let canonical = RecommendationIndexV2.normalizeSemanticTag(raw)
            else { continue }
            let key = RecommendationIndexV2.semanticTagKey(canonical)
            let count = Int(row["n"]?.int ?? 0)
            var current = counts[key] ?? (canonical, 0)
            if count > current.count || (count == current.count && canonical < current.display) {
                current = (canonical, count)
            }
            counts[key] = current
        }
        return counts.mapValues { $0.display }
    }

    /// catalog migration key/version：semantic tag canonical 归并。
    static let semanticCanonicalMigrationKey = "recommendation_v2_semantic_canonical"
    static let semanticCanonicalMigrationVersion = 1

    /// 启动时执行 catalog migrations：先查 catalog_migrations 版本（O(1)），
    /// 已应用直接返回；只有旧库首次升级才做全表 canonical 归并。
    nonisolated func runCatalogMigrations() throws {
        try migrateRecommendationSemanticCanonicalIfNeeded()
    }

    /// 一次性 canonical 迁移：
    /// 1. 统计每个 normalizedKey 下各 display 变体的出现次数（count bug 修复：真正取出现最多者）；
    /// 2. canonical display = 出现最多，同票用 localizedStandardCompare 稳定排序；
    /// 3. 每首歌每个 key 只保留 canonical 一行，confidence 取该 key 内最大；
    /// 4. 同步写入 tag_vocabulary（catalog-global，跨服务器统一 canonical）；
    /// 5. 以上与写 migration version 在同一事务内，中途失败不会留下“半迁移已标记完成”。
    nonisolated func migrateRecommendationSemanticCanonicalIfNeeded() throws {
        let applied = try db.query(
            "SELECT version FROM catalog_migrations WHERE key = ?",
            [.text(Self.semanticCanonicalMigrationKey)]
        ).first?["version"]?.int ?? 0
        guard applied < Self.semanticCanonicalMigrationVersion else { return }

        let rows = try db.query(
            "SELECT global_id, value, confidence FROM recommendation_index_v2_tags WHERE dimension = 'tag'"
        )

        try db.transaction {
            var variants: [String: [String: Int]] = [:]
            for row in rows {
                guard let raw = row["value"]?.string,
                      let canonical = RecommendationIndexV2.normalizeSemanticTag(raw)
                else { continue }
                let key = RecommendationIndexV2.semanticTagKey(canonical)
                variants[key, default: [:]][canonical, default: 0] += 1
            }
            // canonical display：出现次数最多；同票按稳定字符串排序取第一个。
            let canonicalByKey: [String: String] = variants.mapValues { variantCounts in
                variantCounts.sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key.localizedStandardCompare($1.key) == .orderedAscending
                }.first!.key
            }
            // 每首歌每个 key 只保留一条：canonical display + 该 key 内最大 confidence。
            var byTrack: [String: [String: (display: String, confidence: Double)]] = [:]
            for row in rows {
                guard let id = row["global_id"]?.string,
                      let raw = row["value"]?.string,
                      let canonical = RecommendationIndexV2.normalizeSemanticTag(raw)
                else { continue }
                let key = RecommendationIndexV2.semanticTagKey(canonical)
                let display = canonicalByKey[key] ?? canonical
                let confidence = max(
                    row["confidence"]?.double ?? 0,
                    byTrack[id]?[key]?.confidence ?? 0
                )
                byTrack[id, default: [:]][key] = (display, confidence)
            }
            for (id, merged) in byTrack {
                try db.run(
                    "DELETE FROM recommendation_index_v2_tags WHERE global_id = ? AND dimension = 'tag'",
                    [.text(id)]
                )
                for (_, item) in merged {
                    try db.run(
                        "INSERT OR REPLACE INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, 'tag', ?, ?)",
                        [.text(id), .text(item.display), .real(item.confidence)]
                    )
                }
            }
            // 写 vocabulary（catalog-global）。
            let now = Date.now.timeIntervalSince1970
            for (key, display) in canonicalByKey {
                try db.run(
                    """
                    INSERT INTO recommendation_index_v2_tag_vocabulary (normalized_key, display_value, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(normalized_key) DO UPDATE SET display_value = excluded.display_value, updated_at = excluded.updated_at
                    """,
                    [.text(key), .text(display), .real(now), .real(now)]
                )
            }
            // 同一事务内标记迁移完成。
            try db.run(
                """
                INSERT INTO catalog_migrations (key, version, applied_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET version = excluded.version, applied_at = excluded.applied_at
                """,
                [.text(Self.semanticCanonicalMigrationKey), .integer(Int64(Self.semanticCanonicalMigrationVersion)), .real(now)]
            )
        }
    }

    /// 语义标签待补的曲目：尚未按当前 semanticTagRulesVersion 处理过（版本低于当前）。
    /// 「处理过」= 该曲目已按本版本语义标签规则跑过一次，即使结果是没有标签（信息不足时不强造标签）。
    /// 取得下一批待分类元数据。使用统一 pending 状态：
    /// - 先处理 pendingFixed（full，固定+开放一起完成）；
    /// - 再处理仅剩的 pendingSemantic（semanticTagsOnly）；
    /// - 都没有 → done。
    /// 同一批模式唯一；pending 计数使用 unique 语义，新歌同时缺两类只算一首。
    public func nextRecommendationIndexV2Batch(serverID: ServerID?, limit: Int = 80) throws -> RecommendationIndexV2Batch {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let pending = try recommendationIndexV2PendingState(snapshot: snapshot)

        let mode: String
        let source: [CatalogTrackLine]
        if !pending.fixed.isEmpty {
            mode = "full"
            source = snapshot.lines.filter { pending.fixed.contains($0.id) }
        } else if !pending.semantic.isEmpty {
            mode = "semanticTagsOnly"
            source = snapshot.lines.filter { pending.semantic.contains($0.id) }
        } else {
            return RecommendationIndexV2Batch(
                tracks: [],
                pendingFixedTracks: 0,
                pendingSemanticTagTracks: 0,
                pendingUniqueTracks: 0,
                rulesVersion: RecommendationIndexV2.rulesVersion,
                mode: "done"
            )
        }
        let batch = Array(source.prefix(min(max(limit, 1), 100)))
        return RecommendationIndexV2Batch(
            tracks: batch,
            pendingFixedTracks: pending.fixed.count,
            pendingSemanticTagTracks: pending.semantic.count,
            pendingUniqueTracks: pending.unique.count,
            rulesVersion: RecommendationIndexV2.rulesVersion,
            mode: mode
        )
    }

    /// 校验模型返回后落库。固定维度（mood/scene/vocal/texture/style + 数值维度）受白名单；
    /// 开放语义标签统一写 dimension = "tag"，不设数量上限，只做规范化 + 语义规则校验。
    ///
    /// mode 语义：
    /// - "full"（默认）：替换该曲目的固定维度 + 开放标签；
    /// - "semanticTagsOnly"：只替换开放标签（dimension='tag'），绝不删除旧的固定维度。
    @discardableResult
    public func writeRecommendationIndexV2(
        _ classifications: [RecommendationIndexV2Classification],
        serverID: ServerID?,
        classifier: String = "configured-agent"
    ) throws -> Int {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.lines.map { ($0.id, $0) })
        let valid = classifications.prefix(100).compactMap { item -> (RecommendationIndexV2Classification, CatalogTrackLine)? in
            guard let line = byID[item.id] else { return nil }
            if item.mode == "semanticTagsOnly" {
                // 只补开放标签：不要求固定维度合法，也绝不触碰旧固定维度。
                return (item, line)
            }
            guard (1...10).contains(item.energy),
                  (1...5).contains(item.tempo),
                  (1...5).contains(item.acousticness),
                  (1...5).contains(item.danceability),
                  !normalizedTags(item.moods, allowed: RecommendationIndexV2.moods).isEmpty ||
                  !normalizedTags(item.scenes, allowed: RecommendationIndexV2.scenes).isEmpty ||
                  !normalizedTags(item.textures, allowed: RecommendationIndexV2.textures).isEmpty ||
                  !normalizedTags(item.styles, allowed: RecommendationIndexV2.styles).isEmpty
            else { return nil }
            return (item, line)
        }
        guard !valid.isEmpty else { return 0 }

        try db.transaction {
            for (item, line) in valid {
                let confidence = min(max(item.confidence, 0), 1)
                let mode = item.mode == "semanticTagsOnly" ? "semanticTagsOnly" : "full"
                if mode == "semanticTagsOnly" {
                    try db.run("DELETE FROM recommendation_index_v2_tags WHERE global_id = ? AND dimension = 'tag'", [.text(item.id)])
                } else {
                    try db.run("DELETE FROM recommendation_index_v2_tags WHERE global_id = ?", [.text(item.id)])
                }
                try db.run(
                    """
                    INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at, source_hash_version, semantic_tag_rules_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(global_id) DO UPDATE SET source_hash = excluded.source_hash, rules_version = excluded.rules_version,
                    classifier = excluded.classifier, classified_at = excluded.classified_at,
                    source_hash_version = excluded.source_hash_version,
                    semantic_tag_rules_version = excluded.semantic_tag_rules_version
                    """,
                    [.text(item.id), .text(GlobalID(item.id)?.serverID.rawValue ?? ""), .text(recommendationIndexV2ContentHash(line)),
                     .text(RecommendationIndexV2.rulesVersion), .text(classifier), .real(Date.now.timeIntervalSince1970),
                     .integer(Int64(RecommendationIndexV2.contentHashVersion)),
                     .integer(Int64(RecommendationIndexV2.semanticTagRulesVersion))]
                )
                if mode == "full" {
                    try recommendationIndexV2InsertTags(item.moods, dimension: "mood", allowed: RecommendationIndexV2.moods, id: item.id, confidence: confidence)
                    try recommendationIndexV2InsertTags(item.scenes, dimension: "scene", allowed: RecommendationIndexV2.scenes, id: item.id, confidence: confidence)
                    try recommendationIndexV2InsertTags(item.vocals, dimension: "vocal", allowed: RecommendationIndexV2.vocals, id: item.id, confidence: confidence)
                    try recommendationIndexV2InsertTags(item.textures, dimension: "texture", allowed: RecommendationIndexV2.textures, id: item.id, confidence: confidence)
                    try recommendationIndexV2InsertTags(item.styles, dimension: "style", allowed: RecommendationIndexV2.styles, id: item.id, confidence: confidence)
                    try recommendationIndexV2InsertNumericTags(item, id: item.id, confidence: confidence)
                }
                try recommendationIndexV2InsertSemanticTags(item.semanticTags, id: item.id, line: line, confidence: confidence)
            }
        }
        return valid.count
    }

    /// 用 V2 场景/情绪标签取候选；未完成索引时调用方可回退到原有流派推荐。
    public func recommendationIndexV2TrackIDs(serverID: ServerID, query: String, limit: Int = 200) throws -> [GlobalID] {
        let rows = try db.query(
            """
            SELECT t.global_id FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.server_id = ? AND s.rules_version = ? AND t.value = ? AND t.dimension IN ('mood', 'scene')
            ORDER BY t.confidence DESC LIMIT ?
            """,
            [.text(serverID.rawValue), .text(RecommendationIndexV2.rulesVersion), .text(query), .integer(Int64(min(max(limit, 1), 500)))]
        )
        return rows.compactMap { $0["global_id"]?.string }.compactMap(GlobalID.init)
    }

    /// 读取已完成且仍与当前曲目元数据匹配的索引记录。
    /// `dimension`/`value` 均为可选筛选条件；返回每首歌的完整标签，便于 Agent 解释或再次筛选。
    public func readRecommendationIndexV2(
        serverID: ServerID?,
        dimension: String? = nil,
        value: String? = nil,
        limit: Int = 50
    ) throws -> [RecommendationIndexV2IndexedTrack] {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let validLines = Dictionary(uniqueKeysWithValues: snapshot.lines.filter {
            snapshot.states[$0.id]?.hash == recommendationIndexV2ContentHash($0)
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
            serverID.map { [.text(RecommendationIndexV2.rulesVersion), .text($0.rawValue)] }
                ?? [.text(RecommendationIndexV2.rulesVersion)]
        )

        var tagsByID: [String: [String: [String]]] = [:]
        var confidenceByID: [String: Double] = [:]
        for row in rows {
            guard let id = row["global_id"]?.string, validLines[id] != nil,
                  let rowDimension = row["dimension"]?.string, let rowValue = row["value"]?.string
            else { continue }
            tagsByID[id, default: [:]][rowDimension, default: []].append(rowValue)
            confidenceByID[id] = max(confidenceByID[id] ?? 0, row["confidence"]?.double ?? 0)
        }

        let normalizedDimension = dimension?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return tagsByID.compactMap { id, tags -> RecommendationIndexV2IndexedTrack? in
            guard let line = validLines[id] else { return nil }
            if let normalizedDimension {
                guard let values = tags[normalizedDimension] else { return nil }
                if let normalizedValue, !values.contains(where: { $0.localizedCaseInsensitiveCompare(normalizedValue) == .orderedSame }) {
                    return nil
                }
            } else if let normalizedValue,
                      !tags.values.joined().contains(where: { $0.localizedCaseInsensitiveCompare(normalizedValue) == .orderedSame }) {
                return nil
            }
            let stableTags = tags.mapValues { Array(Set($0)).sorted() }
            return RecommendationIndexV2IndexedTrack(track: line, tags: stableTags, confidence: confidenceByID[id] ?? 0)
        }
        .sorted { lhs, rhs in
            lhs.confidence == rhs.confidence ? lhs.track.id < rhs.track.id : lhs.confidence > rhs.confidence
        }
        .prefix(min(max(limit, 1), 100))
        .map { $0 }
    }

    /// 返回资料库「分类」页所需的 V2 标签及各自歌曲数。
    /// `dimensions` 非空时只返回指定维度（例如固定维度），用于避免把全部开放语义标签
    /// 一次读进内存；开放标签用 `recommendationIndexV2TagCatalog` 按需分页。
    /// 与推荐查询保持同一可见范围：当前规则版本、当前服务器，且不暴露歌词/路径/播放地址。
    public func recommendationIndexV2Categories(
        serverID: ServerID?,
        dimensions: Set<String>? = nil
    ) throws -> [RecommendationIndexV2Category] {
        var sql = """
            SELECT t.dimension, t.value, COUNT(DISTINCT t.global_id) AS track_count
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.rules_version = ?
        """
        var values: [SQLiteValue] = [.text(RecommendationIndexV2.rulesVersion)]
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
            return RecommendationIndexV2Category(
                dimension: dimension,
                value: value,
                trackCount: Int(row["track_count"]?.int ?? 0)
            )
        }
    }

    /// 开放语义标签词库分页（真正 SQL 分页，总量不受页大小限制）。
    /// migration + vocabulary 写回后，数据库 value 已是 canonical，可直接 GROUP BY t.value。
    /// 每页 limit 上限 100 只是单页大小；offset 可以无限向后，第 501 个标签也可读取。
    public func recommendationIndexV2TagCatalog(
        serverID: ServerID?,
        query: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> RecommendationIndexV2TagPage {
        let pageSize = min(max(limit, 1), 100)
        let safeOffset = max(offset, 0)
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sql = """
            SELECT t.value, COUNT(DISTINCT t.global_id) AS track_count
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE t.dimension = 'tag'
        """
        var values: [SQLiteValue] = []
        if let serverID {
            sql += " AND s.server_id = ?"
            values.append(.text(serverID.rawValue))
        }
        if let trimmed, !trimmed.isEmpty {
            sql += " AND t.value LIKE ?"
            values.append(.text("%\(trimmed)%"))
        }
        // filter → group → sort → page（LIMIT pageSize+1 探测是否有下一页，无需 COUNT 全量）。
        sql += " GROUP BY t.value ORDER BY track_count DESC, t.value ASC LIMIT ? OFFSET ?"
        values.append(.integer(Int64(pageSize + 1)))
        values.append(.integer(Int64(safeOffset)))
        let rows = try db.query(sql, values)
        let hasMore = rows.count > pageSize
        let visibleRows = Array(rows.prefix(pageSize))
        let items = visibleRows.compactMap { row -> RecommendationIndexV2Category? in
            guard let value = row["value"]?.string, !value.isEmpty else { return nil }
            return RecommendationIndexV2Category(
                dimension: "tag",
                value: value,
                trackCount: Int(row["track_count"]?.int ?? 0)
            )
        }
        return RecommendationIndexV2TagPage(
            items: items,
            nextOffset: hasMore ? safeOffset + pageSize : nil,
            hasMore: hasMore
        )
    }

    /// 读取某个 V2 分类下的真实曲目，供资料库详情页直接播放与加入队列。
    public func recommendationIndexV2Tracks(
        serverID: ServerID?,
        dimension: String,
        value: String
    ) throws -> [Track] {
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
            serverID.map { [.text(RecommendationIndexV2.rulesVersion), .text(dimension), .text(value), .text($0.rawValue)] }
                ?? [.text(RecommendationIndexV2.rulesVersion), .text(dimension), .text(value)]
        )
        // 分类详情必须只解码命中的 Track payload。此前先全量 allTracks(limit: 20_000)
        // 再在内存映射，不仅每次点击都会扫描整个曲库，超过 20,000 首还会静默漏歌。
        return rows.compactMap { row in
            guard let payload = row["payload"]?.string else { return nil }
            return try? decode(Track.self, payload)
        }
    }

    func recommendationIndexV2Snapshot(serverID: ServerID?) throws -> (lines: [CatalogTrackLine], states: [String: RecommendationIndexV2StoredState]) {
        // 分类写入也必须看到完整资料库；否则第 20,000 首之后的歌曲永远不会进入 V2 索引。
        let tracks = try allTracks(serverID: serverID)
        let popularity = try popularityScores(serverID: serverID)
        let favorites = Set(try getFavorites(serverID: serverID).map(\.globalID))
        let ratings = serverID.flatMap { try? ratings(serverID: $0) } ?? [:]
        let lines = tracks.map { track -> CatalogTrackLine in
            let id = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            return CatalogTrackLine(
                id: id.description, title: track.title, artist: track.artistName, album: track.albumTitle,
                year: track.year, genres: track.genres, language: track.language, duration: Int(track.duration),
                isFavorite: track.isFavorite || favorites.contains(id), rating: ratings[id] ?? track.rating,
                playCount: popularity[id]?.playCount ?? 0, isDownloaded: false
            )
        }.sorted { lhs, rhs in lhs.id < rhs.id }
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query("SELECT global_id, source_hash, rules_version, source_hash_version, semantic_tag_rules_version FROM recommendation_index_v2_state WHERE server_id = ?", [.text(serverID.rawValue)])
        } else {
            rows = try db.query("SELECT global_id, source_hash, rules_version, source_hash_version, semantic_tag_rules_version FROM recommendation_index_v2_state")
        }
        var states: [String: RecommendationIndexV2StoredState] = [:]
        for row in rows where row["rules_version"]?.string == RecommendationIndexV2.rulesVersion {
            if let id = row["global_id"]?.string, let hash = row["source_hash"]?.string {
                states[id] = RecommendationIndexV2StoredState(
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

    /// 旧 V2 索引迁移：source_hash_version 缺失或低于当前版本时，按当前歌曲内容
    /// 重新计算 content hash 并原地更新。只有歌曲仍存在且 tags 完整时才迁移；
    /// track 不存在 / tags 损坏的条目保持原样，会自然进入 pending。
    private func migrateStaleContentHash(
        lines: [CatalogTrackLine],
        states: inout [String: RecommendationIndexV2StoredState]
    ) throws {
        let stale = states.filter { $0.value.hashVersion < RecommendationIndexV2.contentHashVersion }
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
            updated.append((id, recommendationIndexV2ContentHash(line)))
        }
        guard !updated.isEmpty else { return }
        try db.transaction {
            for (id, hash) in updated {
                try db.run(
                    "UPDATE recommendation_index_v2_state SET source_hash = ?, source_hash_version = ? WHERE global_id = ?",
                    [.text(hash), .integer(Int64(RecommendationIndexV2.contentHashVersion)), .text(id)]
                )
                states[id]?.hash = hash
                states[id]?.hashVersion = RecommendationIndexV2.contentHashVersion
            }
        }
    }

    private func recommendationIndexV2InsertTags(_ values: [String], dimension: String, allowed: Set<String>, id: String, confidence: Double) throws {
        for value in normalizedTags(values, allowed: allowed) {
            try db.run("INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)", [.text(id), .text(dimension), .text(value), .real(confidence)])
        }
    }

    private func recommendationIndexV2InsertNumericTags(_ item: RecommendationIndexV2Classification, id: String, confidence: Double) throws {
        for (dimension, value) in [("energy", item.energy), ("tempo", item.tempo), ("acousticness", item.acousticness), ("danceability", item.danceability)] {
            try db.run("INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)", [.text(id), .text(dimension), .text(String(value)), .real(confidence)])
        }
    }

    private func normalizedTags(_ values: [String], allowed: Set<String>) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(allowed.contains))).sorted()
    }

    /// 写入开放语义标签（dimension = 'tag'）：规范化 + 语义规则校验 + 按 (global_id, dimension, value)
    /// 唯一键去重（PRIMARY KEY 保证不会产生重复行）。不设每首/全局数量上限。
    ///
    /// canonical 复用基于 tag_vocabulary（catalog-global，跨服务器统一）：
    /// 先查本批涉及的 normalized_key 的 vocabulary display；新 key 本批内按出现次数选 canonical
    /// （同票稳定排序），写 vocabulary 后再写 tag。不再每次扫描整个标签库。
    private func recommendationIndexV2InsertSemanticTags(
        _ tags: [RecommendationIndexV2SemanticTag],
        id: String,
        line: CatalogTrackLine,
        confidence: Double
    ) throws {
        var normalized: [(key: String, canonical: String, tagConfidence: Double)] = []
        var seen = Set<String>()
        for tag in tags {
            guard let canonical = RecommendationIndexV2.normalizeSemanticTag(tag.value) else { continue }
            // 语义规则：不能用歌曲名/艺术家/专辑/GlobalID 作为标签，也不能把个人行为当标签。
            let lower = canonical.lowercased()
            let forbidden = [
                line.title.lowercased(), line.artist.lowercased(), line.album.lowercased(),
                line.id.lowercased(),
            ]
            if forbidden.contains(where: { !$0.isEmpty && $0 == lower }) { continue }
            if ["收藏", "不喜欢", "已播放", "播放很多", "评分", "跳过", "下载"].contains(where: { canonical.contains($0) }) { continue }
            let key = RecommendationIndexV2.semanticTagKey(canonical)
            guard seen.insert(key).inserted else { continue }
            normalized.append((key, canonical, min(max(tag.confidence, 0), 1)))
        }
        guard !normalized.isEmpty else { return }

        // 查 vocabulary：已有 key 用 vocabulary display。
        let keys = normalized.map(\.key)
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        let vocabRows = try db.query(
            "SELECT normalized_key, display_value FROM recommendation_index_v2_tag_vocabulary WHERE normalized_key IN (\(placeholders))",
            keys.map { SQLiteValue.text($0) }
        )
        var vocabDisplay: [String: String] = [:]
        for row in vocabRows {
            if let key = row["normalized_key"]?.string, let display = row["display_value"]?.string {
                vocabDisplay[key] = display
            }
        }
        // 本批内新 key：按出现次数选 canonical，同票稳定排序。
        var batchCounts: [String: [String: Int]] = [:]
        for item in normalized {
            batchCounts[item.key, default: [:]][item.canonical, default: 0] += 1
        }
        var resolved: [String: String] = [:]
        for item in normalized where vocabDisplay[item.key] == nil {
            let counts = batchCounts[item.key] ?? [:]
            let chosen = counts.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }.first!.key
            resolved[item.key] = chosen
        }
        // 新 key 写 vocabulary（catalog-global）。
        let now = Date.now.timeIntervalSince1970
        for (key, display) in resolved {
            try db.run(
                """
                INSERT INTO recommendation_index_v2_tag_vocabulary (normalized_key, display_value, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(normalized_key) DO UPDATE SET display_value = excluded.display_value, updated_at = excluded.updated_at
                """,
                [.text(key), .text(display), .real(now), .real(now)]
            )
            vocabDisplay[key] = display
        }
        // 写 tag（per-tag confidence）。
        for item in normalized {
            let display = vocabDisplay[item.key] ?? item.canonical
            try db.run(
                "INSERT OR REPLACE INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, 'tag', ?, ?)",
                [.text(id), .text(display), .real(item.tagConfidence)]
            )
        }
    }

    /// V2 内容指纹：只包含相对稳定的音乐内容身份字段。
    ///
    /// 明确**不**包含 favorite / rating / playCount / skipCount / completionRate /
    /// 下载状态等个人行为数据——用户收藏、评分、播放次数改变不应让 mood / scene /
    /// texture / style / energy / tempo 等内容分类全部失效。个人数据仍然保留在
    /// LocalCatalog（favorites / ratings / play_history），只用于推荐排序与个性化。
    func recommendationIndexV2ContentHash(_ line: CatalogTrackLine) -> String {
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

/// 一条已入库的 V2 索引状态：内容 hash + hash 算法版本 + 语义标签规则版本。
struct RecommendationIndexV2StoredState {
    var hash: String
    var hashVersion: Int
    /// 该曲目的开放语义标签是按哪个 semanticTagRulesVersion 生成的（0 = 尚未生成）。
    var semanticTagRulesVersion: Int
}
