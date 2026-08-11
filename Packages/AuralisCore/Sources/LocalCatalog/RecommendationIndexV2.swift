import Domain
import Foundation
import MusicLibrary

/// 可由 Agent 稳定生成、也便于之后检索的有限标签空间。
public enum RecommendationIndexV2 {
    public static let rulesVersion = "2.1"
    /// 内容指纹算法版本：只描述“判断歌曲内容是否变化”的指纹算法，与
    /// rulesVersion（分类 taxonomy / prompt / schema 版本）相互独立。
    public static let contentHashVersion = 2
    public static let moods: Set<String> = ["平静", "治愈", "忧郁", "浪漫", "明亮", "激昂", "神秘", "紧张", "怀旧", "温暖", "冷冽", "慵懒", "梦幻", "迷离", "释然", "孤独", "甜蜜", "愤怒", "庄严", "俏皮"]
    public static let scenes: Set<String> = ["深夜", "清晨", "通勤", "学习", "专注", "运动", "聚会", "独处", "旅行", "雨天", "驾车", "工作", "阅读", "冥想", "约会", "派对", "睡前", "散步"]
    public static let vocals: Set<String> = ["女声", "男声", "童声", "合唱", "对唱", "器乐", "说唱", "未知"]
    public static let textures: Set<String> = ["原声", "电子", "钢琴", "吉他", "贝斯", "鼓组", "弦乐", "管乐", "合成器", "人声采样", "现场", "氛围", "Lo-fi", "失真"]
    public static let styles: Set<String> = ["流行", "摇滚", "民谣", "爵士", "古典", "嘻哈", "R&B", "灵魂乐", "电子", "舞曲", "金属", "朋克", "乡村", "蓝调", "雷鬼", "世界音乐", "原声带", "氛围", "轻音乐", "实验"]
}

extension LocalCatalogStore {
    public func recommendationIndexV2Status(serverID: ServerID?) throws -> RecommendationIndexV2Status {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let indexed = snapshot.lines.filter { line in
            snapshot.states[line.id]?.hash == recommendationIndexV2ContentHash(line)
        }.count
        return RecommendationIndexV2Status(
            totalTracks: snapshot.lines.count,
            indexedTracks: indexed,
            pendingTracks: snapshot.lines.count - indexed,
            rulesVersion: RecommendationIndexV2.rulesVersion
        )
    }

    /// 取得下一批待分类元数据。批次稳定排序，失败重试不会跳过歌曲。
    public func nextRecommendationIndexV2Batch(serverID: ServerID?, limit: Int = 80) throws -> RecommendationIndexV2Batch {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let pending = snapshot.lines.filter { snapshot.states[$0.id]?.hash != recommendationIndexV2ContentHash($0) }
        return RecommendationIndexV2Batch(
            tracks: Array(pending.prefix(min(max(limit, 1), 100))),
            pendingTracks: pending.count,
            rulesVersion: RecommendationIndexV2.rulesVersion
        )
    }

    /// 校验模型返回后一次性落库。未知 ID 或不在规范中的标签不会污染索引。
    @discardableResult
    public func writeRecommendationIndexV2(
        _ classifications: [RecommendationIndexV2Classification],
        serverID: ServerID?,
        classifier: String = "configured-agent"
    ) throws -> Int {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.lines.map { ($0.id, $0) })
        let valid = classifications.prefix(100).compactMap { item -> (RecommendationIndexV2Classification, CatalogTrackLine, [(String, [String])])? in
            let customTags = normalizedCustomTags(item.customTags)
            guard let line = byID[item.id],
                  (1...10).contains(item.energy),
                  (1...5).contains(item.tempo),
                  (1...5).contains(item.acousticness),
                  (1...5).contains(item.danceability),
                  !normalizedTags(item.moods, allowed: RecommendationIndexV2.moods).isEmpty ||
                  !normalizedTags(item.scenes, allowed: RecommendationIndexV2.scenes).isEmpty ||
                  !normalizedTags(item.textures, allowed: RecommendationIndexV2.textures).isEmpty ||
                  !normalizedTags(item.styles, allowed: RecommendationIndexV2.styles).isEmpty ||
                  !customTags.isEmpty
            else { return nil }
            return (item, line, customTags)
        }
        guard !valid.isEmpty else { return 0 }

        try db.transaction {
            for (item, line, customTags) in valid {
                let confidence = min(max(item.confidence, 0), 1)
                try db.run("DELETE FROM recommendation_index_v2_tags WHERE global_id = ?", [.text(item.id)])
                try db.run(
                    """
                    INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at, source_hash_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(global_id) DO UPDATE SET source_hash = excluded.source_hash, rules_version = excluded.rules_version,
                    classifier = excluded.classifier, classified_at = excluded.classified_at,
                    source_hash_version = excluded.source_hash_version
                    """,
                    [.text(item.id), .text(GlobalID(item.id)?.serverID.rawValue ?? ""), .text(recommendationIndexV2ContentHash(line)),
                     .text(RecommendationIndexV2.rulesVersion), .text(classifier), .real(Date.now.timeIntervalSince1970),
                     .integer(Int64(RecommendationIndexV2.contentHashVersion))]
                )
                try recommendationIndexV2InsertTags(item.moods, dimension: "mood", allowed: RecommendationIndexV2.moods, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.scenes, dimension: "scene", allowed: RecommendationIndexV2.scenes, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.vocals, dimension: "vocal", allowed: RecommendationIndexV2.vocals, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.textures, dimension: "texture", allowed: RecommendationIndexV2.textures, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.styles, dimension: "style", allowed: RecommendationIndexV2.styles, id: item.id, confidence: confidence)
                for (dimension, values) in customTags {
                    for value in values {
                        try db.run(
                            "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)",
                            [.text(item.id), .text(dimension), .text(value), .real(confidence)]
                        )
                    }
                }
                try recommendationIndexV2InsertNumericTags(item, id: item.id, confidence: confidence)
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

    /// 返回资料库「分类」页所需的全部 V2 标签及各自歌曲数。
    /// 与推荐查询保持同一可见范围：当前规则版本、当前服务器，且不暴露歌词/路径/播放地址。
    public func recommendationIndexV2Categories(serverID: ServerID?) throws -> [RecommendationIndexV2Category] {
        let rows = try db.query(
            """
            SELECT t.dimension, t.value, COUNT(DISTINCT t.global_id) AS track_count
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.rules_version = ?
            \(serverID == nil ? "" : "AND s.server_id = ?")
            GROUP BY t.dimension, t.value
            ORDER BY track_count DESC, t.dimension ASC, t.value ASC
            """,
            serverID.map { [.text(RecommendationIndexV2.rulesVersion), .text($0.rawValue)] }
                ?? [.text(RecommendationIndexV2.rulesVersion)]
        )
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

    /// 读取某个 V2 分类下的真实曲目，供资料库详情页直接播放与加入队列。
    public func recommendationIndexV2Tracks(
        serverID: ServerID?,
        dimension: String,
        value: String
    ) throws -> [Track] {
        let rows = try db.query(
            """
            SELECT t.global_id
            FROM recommendation_index_v2_tags t
            JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
            WHERE s.rules_version = ? AND t.dimension = ? AND t.value = ?
            \(serverID == nil ? "" : "AND s.server_id = ?")
            ORDER BY t.confidence DESC, t.global_id ASC
            """,
            serverID.map { [.text(RecommendationIndexV2.rulesVersion), .text(dimension), .text(value), .text($0.rawValue)] }
                ?? [.text(RecommendationIndexV2.rulesVersion), .text(dimension), .text(value)]
        )
        let order = rows.compactMap { $0["global_id"]?.string }
        guard !order.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: try allTracks(serverID: serverID, limit: 20_000).map {
            (GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue).description, $0)
        })
        return order.compactMap { byID[$0] }
    }

    func recommendationIndexV2Snapshot(serverID: ServerID?) throws -> (lines: [CatalogTrackLine], states: [String: RecommendationIndexV2StoredState]) {
        let tracks = try allTracks(serverID: serverID, limit: 20_000)
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
            rows = try db.query("SELECT global_id, source_hash, rules_version, source_hash_version FROM recommendation_index_v2_state WHERE server_id = ?", [.text(serverID.rawValue)])
        } else {
            rows = try db.query("SELECT global_id, source_hash, rules_version, source_hash_version FROM recommendation_index_v2_state")
        }
        var states: [String: RecommendationIndexV2StoredState] = [:]
        for row in rows where row["rules_version"]?.string == RecommendationIndexV2.rulesVersion {
            if let id = row["global_id"]?.string, let hash = row["source_hash"]?.string {
                states[id] = RecommendationIndexV2StoredState(
                    hash: hash,
                    hashVersion: Int(row["source_hash_version"]?.int ?? 0)
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

    /// 自建分类仍需是可控、可检索的短文本。每首最多 8 个自建维度、每维最多 4 个
    /// 标签；保留维度不能借 customTags 绕过固定词表校验。
    private func normalizedCustomTags(_ groups: [String: [String]]?) -> [(String, [String])] {
        let reserved = Set(["mood", "scene", "vocal", "texture", "style", "energy", "tempo", "acousticness", "danceability"])
        return (groups ?? [:]).compactMap { rawDimension, rawValues -> (String, [String])? in
            let dimension = rawDimension.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dimension.isEmpty,
                  dimension.count <= 24,
                  !reserved.contains(dimension.lowercased()),
                  !dimension.contains("\n"), !dimension.contains("\t")
            else { return nil }
            let values = Array(Set(rawValues.compactMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 32, !value.contains("\n"), !value.contains("\t") else { return nil }
                return value
            })).sorted().prefix(4)
            guard !values.isEmpty else { return nil }
            return (dimension, Array(values))
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        .prefix(8)
        .map { $0 }
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

/// 一条已入库的 V2 索引状态：内容 hash + hash 算法版本。
struct RecommendationIndexV2StoredState {
    var hash: String
    var hashVersion: Int
}
