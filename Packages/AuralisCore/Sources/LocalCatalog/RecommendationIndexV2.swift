import Domain
import Foundation
import MusicLibrary

/// 可由 Agent 稳定生成、也便于之后检索的有限标签空间。
public enum RecommendationIndexV2 {
    public static let rulesVersion = "2.1"
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
            snapshot.states[line.id] == recommendationIndexV2SourceHash(line)
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
        let pending = snapshot.lines.filter { snapshot.states[$0.id] != recommendationIndexV2SourceHash($0) }
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
        let valid = classifications.prefix(100).compactMap { item -> (RecommendationIndexV2Classification, CatalogTrackLine)? in
            guard let line = byID[item.id],
                  (1...10).contains(item.energy),
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
                try db.run("DELETE FROM recommendation_index_v2_tags WHERE global_id = ?", [.text(item.id)])
                try db.run(
                    """
                    INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(global_id) DO UPDATE SET source_hash = excluded.source_hash, rules_version = excluded.rules_version,
                    classifier = excluded.classifier, classified_at = excluded.classified_at
                    """,
                    [.text(item.id), .text(GlobalID(item.id)?.serverID.rawValue ?? ""), .text(recommendationIndexV2SourceHash(line)),
                     .text(RecommendationIndexV2.rulesVersion), .text(classifier), .real(Date.now.timeIntervalSince1970)]
                )
                try recommendationIndexV2InsertTags(item.moods, dimension: "mood", allowed: RecommendationIndexV2.moods, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.scenes, dimension: "scene", allowed: RecommendationIndexV2.scenes, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.vocals, dimension: "vocal", allowed: RecommendationIndexV2.vocals, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.textures, dimension: "texture", allowed: RecommendationIndexV2.textures, id: item.id, confidence: confidence)
                try recommendationIndexV2InsertTags(item.styles, dimension: "style", allowed: RecommendationIndexV2.styles, id: item.id, confidence: confidence)
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
            snapshot.states[$0.id] == recommendationIndexV2SourceHash($0)
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

    private func recommendationIndexV2Snapshot(serverID: ServerID?) throws -> (lines: [CatalogTrackLine], states: [String: String]) {
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
            rows = try db.query("SELECT global_id, source_hash, rules_version FROM recommendation_index_v2_state WHERE server_id = ?", [.text(serverID.rawValue)])
        } else {
            rows = try db.query("SELECT global_id, source_hash, rules_version FROM recommendation_index_v2_state")
        }
        var states: [String: String] = [:]
        for row in rows where row["rules_version"]?.string == RecommendationIndexV2.rulesVersion {
            if let id = row["global_id"]?.string, let hash = row["source_hash"]?.string { states[id] = hash }
        }
        return (lines, states)
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

    private func recommendationIndexV2SourceHash(_ line: CatalogTrackLine) -> String {
        let source = [line.title, line.artist, line.album, line.year.map(String.init) ?? "", line.genres.joined(separator: "|"), line.language ?? "", String(line.duration), line.isFavorite ? "1" : "0", line.rating.map(String.init) ?? "", String(line.playCount)].joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
