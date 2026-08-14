import Domain
import Foundation
import MusicLibrary

/// V2 索引跨设备传输格式（`.auralis-index-v2`，初版为 JSON）。
///
/// 只包含音乐内容分类派生数据。**绝不包含**：服务器密码 / token / API Key / NAS URL /
/// IP / Stream URL / Download URL / Keychain 引用 / 歌词 / 播放历史 / 个人评分 /
/// 收藏 / skip count / completion rate / 本地文件路径 / Cookie / AI 会话。
public struct RecommendationIndexV2Package: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var rulesVersion: String
    public var contentHashVersion: Int
    public var createdAt: Date
    public var trackCount: Int
    public var libraryFingerprint: String?
    public var entries: [RecommendationIndexV2PackageEntry]

    public init(
        formatVersion: Int,
        rulesVersion: String,
        contentHashVersion: Int,
        createdAt: Date = .now,
        trackCount: Int,
        libraryFingerprint: String? = nil,
        entries: [RecommendationIndexV2PackageEntry]
    ) {
        self.formatVersion = formatVersion
        self.rulesVersion = rulesVersion
        self.contentHashVersion = contentHashVersion
        self.createdAt = createdAt
        self.trackCount = trackCount
        self.libraryFingerprint = libraryFingerprint
        self.entries = entries
    }
}

public struct RecommendationIndexV2PackageEntry: Codable, Sendable, Equatable {
    public var remoteTrackID: String
    public var contentHash: String
    public var tags: [RecommendationIndexV2PackageTag]
    public var classifier: String
    public var classifiedAt: Date

    public init(
        remoteTrackID: String,
        contentHash: String,
        tags: [RecommendationIndexV2PackageTag],
        classifier: String,
        classifiedAt: Date = .now
    ) {
        self.remoteTrackID = remoteTrackID
        self.contentHash = contentHash
        self.tags = tags
        self.classifier = classifier
        self.classifiedAt = classifiedAt
    }
}

public struct RecommendationIndexV2PackageTag: Codable, Sendable, Equatable {
    public var dimension: String
    public var value: String
    public var confidence: Double

    public init(dimension: String, value: String, confidence: Double) {
        self.dimension = dimension
        self.value = value
        self.confidence = confidence
    }
}

/// 导入统计：按歌曲逐条计数，一首失败不会让整个导入失败。
public struct RecommendationIndexV2ImportStatistics: Sendable, Equatable {
    public var totalEntries: Int
    public var imported: Int
    public var alreadyExists: Int
    public var metadataChanged: Int
    public var notFound: Int
    public var malformed: Int
    public var versionIncompatible: Int

    public init(
        totalEntries: Int = 0,
        imported: Int = 0,
        alreadyExists: Int = 0,
        metadataChanged: Int = 0,
        notFound: Int = 0,
        malformed: Int = 0,
        versionIncompatible: Int = 0
    ) {
        self.totalEntries = totalEntries
        self.imported = imported
        self.alreadyExists = alreadyExists
        self.metadataChanged = metadataChanged
        self.notFound = notFound
        self.malformed = malformed
        self.versionIncompatible = versionIncompatible
    }
}

public enum RecommendationIndexV2ImportError: Error, Equatable, Sendable {
    case invalidData
    case tooLarge(Int)
    case tooManyEntries(Int)
    case versionIncompatible(format: Int, rules: String, contentHash: Int)
}

extension RecommendationIndexV2ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidData:
            "索引文件无法解析。"
        case let .tooLarge(size):
            "索引文件过大（\(size) 字节），已拒绝导入。"
        case let .tooManyEntries(count):
            "索引条目数量异常（\(count)），已拒绝导入。"
        case let .versionIncompatible(format, rules, contentHash):
            "索引版本不兼容（格式 \(format)、规则 \(rules)、指纹 \(contentHash)）。"
        }
    }
}

extension LocalCatalogStore {
    /// V2 传输格式的当前版本。与 rulesVersion / contentHashVersion 分开，只表示
    /// 传输容器结构版本。
    public static let recommendationIndexV2PackageFormatVersion = 1

    /// 只导出当前服务器、当前规则版本 + 当前内容指纹版本 + 已有完整 tags 的歌曲。
    /// pending / invalid / 损坏记录一律不导出。
    public func exportRecommendationIndexV2Package(serverID: ServerID) throws -> RecommendationIndexV2Package {
        let snapshot = try recommendationIndexV2Snapshot(serverID: serverID)
        let valid = snapshot.lines.filter {
            snapshot.states[$0.id]?.hash == recommendationIndexV2ContentHash($0)
        }
        guard !valid.isEmpty else {
            return RecommendationIndexV2Package(
                formatVersion: Self.recommendationIndexV2PackageFormatVersion,
                rulesVersion: RecommendationIndexV2.rulesVersion,
                contentHashVersion: RecommendationIndexV2.contentHashVersion,
                trackCount: 0,
                entries: []
            )
        }

        // 读取状态（classifier / classified_at）与完整标签（含 confidence）。
        let idSet = Set(valid.map(\.id))
        let stateRows = try db.query(
            "SELECT global_id, source_hash, rules_version, source_hash_version, classifier, classified_at FROM recommendation_index_v2_state WHERE server_id = ?",
            [.text(serverID.rawValue)]
        )
        var stateByID: [String: (classifier: String, classifiedAt: Date)] = [:]
        for row in stateRows {
            guard let id = row["global_id"]?.string, idSet.contains(id) else { continue }
            stateByID[id] = (
                classifier: row["classifier"]?.string ?? "configured-agent",
                classifiedAt: Date(timeIntervalSince1970: row["classified_at"]?.double ?? 0)
            )
        }

        let tagRows = try db.query(
            "SELECT global_id, dimension, value, confidence FROM recommendation_index_v2_tags WHERE global_id IN (\(idSet.map { _ in "?" }.joined(separator: ","))) ORDER BY global_id, dimension, value",
            idSet.sorted().map { SQLiteValue.text($0) }
        )
        var tagsByID: [String: [RecommendationIndexV2PackageTag]] = [:]
        for row in tagRows {
            guard let id = row["global_id"]?.string,
                  let dimension = row["dimension"]?.string,
                  let value = row["value"]?.string
            else { continue }
            tagsByID[id, default: []].append(
                RecommendationIndexV2PackageTag(
                    dimension: dimension,
                    value: value,
                    confidence: row["confidence"]?.double ?? 0
                )
            )
        }

        let entries = valid.compactMap { line -> RecommendationIndexV2PackageEntry? in
            guard let remoteID = GlobalID(line.id)?.remoteID else { return nil }
            let tags = tagsByID[line.id] ?? []
            guard !tags.isEmpty else { return nil }
            let state = stateByID[line.id]
            return RecommendationIndexV2PackageEntry(
                remoteTrackID: remoteID,
                contentHash: recommendationIndexV2ContentHash(line),
                tags: tags,
                classifier: state?.classifier ?? "configured-agent",
                classifiedAt: state?.classifiedAt ?? .now
            )
        }
        let sortedIDs = entries.compactMap { $0.remoteTrackID.isEmpty ? nil : $0.remoteTrackID }.sorted()
        return RecommendationIndexV2Package(
            formatVersion: Self.recommendationIndexV2PackageFormatVersion,
            rulesVersion: RecommendationIndexV2.rulesVersion,
            contentHashVersion: RecommendationIndexV2.contentHashVersion,
            trackCount: entries.count,
            libraryFingerprint: Self.stableFingerprint(sortedIDs),
            entries: entries
        )
    }

    /// 导入外部 V2 索引包。外部 JSON 一律视为不可信输入：
    /// 限制文件大小、条目数量、标签数量、字符串长度与 confidence 范围；
    /// dimension 必须进入现有 allowlist（或通过自建维度格式校验）；
    /// 所有 SQLite 写入使用 parameter binding。
    public func importRecommendationIndexV2Package(
        data: Data,
        serverID: ServerID
    ) throws -> RecommendationIndexV2ImportStatistics {
        let maxBytes = 50 * 1024 * 1024
        guard data.count <= maxBytes else { throw RecommendationIndexV2ImportError.tooLarge(data.count) }

        let package: RecommendationIndexV2Package
        do {
            package = try JSONDecoder().decode(RecommendationIndexV2Package.self, from: data)
        } catch {
            throw RecommendationIndexV2ImportError.invalidData
        }
        guard package.formatVersion == Self.recommendationIndexV2PackageFormatVersion,
              package.rulesVersion == RecommendationIndexV2.rulesVersion,
              package.contentHashVersion == RecommendationIndexV2.contentHashVersion
        else {
            throw RecommendationIndexV2ImportError.versionIncompatible(
                format: package.formatVersion,
                rules: package.rulesVersion,
                contentHash: package.contentHashVersion
            )
        }

        let maxEntries = 200_000
        guard package.entries.count <= maxEntries else {
            throw RecommendationIndexV2ImportError.tooManyEntries(package.entries.count)
        }

        // 当前服务器曲目映射：remoteTrackID → CatalogTrackLine。
        let tracks = try allTracks(serverID: serverID)
        let lineByRemoteID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track -> (String, CatalogTrackLine)? in
            let line = CatalogTrackLine(
                id: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue).description,
                title: track.title, artist: track.artistName, album: track.albumTitle,
                year: track.year, genres: track.genres, language: track.language,
                duration: Int(track.duration),
                isFavorite: false, rating: nil, playCount: 0, isDownloaded: false
            )
            return (track.id.rawValue, line)
        })

        var statistics = RecommendationIndexV2ImportStatistics(totalEntries: package.entries.count)

        // 先逐条校验并分类，收集需要写入的记录；整批在一个事务内落库。
        var toImport: [(line: CatalogTrackLine, entry: RecommendationIndexV2PackageEntry)] = []
        for entry in package.entries {
            guard isValidRemoteTrackID(entry.remoteTrackID),
                  isValidClassifier(entry.classifier),
                  let line = lineByRemoteID[entry.remoteTrackID]
            else {
                statistics.notFound += 1
                continue
            }
            let localHash = recommendationIndexV2ContentHash(line)
            guard localHash == entry.contentHash else {
                statistics.metadataChanged += 1
                continue
            }
            let tags = validatedTags(entry.tags)
            guard !tags.isEmpty else {
                statistics.malformed += 1
                continue
            }
            // 已存在相同内容指纹且已有 tags 的歌曲视为已导入，跳过避免无谓写入。
            let existing = try? db.query(
                "SELECT source_hash, source_hash_version FROM recommendation_index_v2_state WHERE global_id = ? LIMIT 1",
                [.text(line.id)]
            ).first
            let existingHash = existing?["source_hash"]?.string
            let existingVersion = existing?["source_hash_version"]?.int ?? 0
            let hasExistingTags = (try? db.query(
                "SELECT 1 FROM recommendation_index_v2_tags WHERE global_id = ? LIMIT 1",
                [.text(line.id)]
            ).isEmpty == false) ?? false
            if existingVersion >= RecommendationIndexV2.contentHashVersion,
               existingHash == localHash,
               hasExistingTags {
                statistics.alreadyExists += 1
                continue
            }
            toImport.append((line, entry))
            statistics.imported += 1
        }

        guard !toImport.isEmpty else { return statistics }
        try db.transaction {
            for (line, entry) in toImport {
                try db.run("DELETE FROM recommendation_index_v2_tags WHERE global_id = ?", [.text(line.id)])
                let confidenceByTag = Dictionary(
                    uniqueKeysWithValues: entry.tags.map { ($0.dimension + "\u{1F}" + $0.value, $0.confidence) }
                )
                for tag in validatedTags(entry.tags) {
                    let confidence = confidenceByTag[tag.dimension + "\u{1F}" + tag.value] ?? 0
                    try db.run(
                        "INSERT INTO recommendation_index_v2_tags (global_id, dimension, value, confidence) VALUES (?, ?, ?, ?)",
                        [.text(line.id), .text(tag.dimension), .text(tag.value), .real(min(max(confidence, 0), 1))]
                    )
                }
                try db.run(
                    """
                    INSERT INTO recommendation_index_v2_state (global_id, server_id, source_hash, rules_version, classifier, classified_at, source_hash_version, semantic_tag_rules_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(global_id) DO UPDATE SET
                        source_hash = excluded.source_hash,
                        rules_version = excluded.rules_version,
                        classifier = excluded.classifier,
                        classified_at = excluded.classified_at,
                        source_hash_version = excluded.source_hash_version,
                        semantic_tag_rules_version = excluded.semantic_tag_rules_version
                    """,
                    [
                        .text(line.id), .text(serverID.rawValue), .text(entry.contentHash),
                        .text(RecommendationIndexV2.rulesVersion),
                        .text(entry.classifier.isEmpty ? "imported" : entry.classifier),
                        .real(entry.classifiedAt.timeIntervalSince1970),
                        .integer(Int64(RecommendationIndexV2.contentHashVersion)),
                        .integer(Int64(RecommendationIndexV2.semanticTagRulesVersion)),
                    ]
                )
            }
        }
        return statistics
    }

    // MARK: - 传输校验

    private func isValidRemoteTrackID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 512
    }

    private func isValidClassifier(_ value: String) -> Bool {
        value.count <= 128
    }

    /// 外部标签必须经过与写回路径一致的校验：固定维度进入现有 allowlist，
    /// 数值维度验证范围，自建维度走长度/保留名/换行校验。
    private func validatedTags(_ tags: [RecommendationIndexV2PackageTag]) -> [(dimension: String, value: String)] {
        var seen = Set<String>()
        var result: [(dimension: String, value: String)] = []
        for tag in tags {
            guard tag.confidence.isFinite, (0...1).contains(tag.confidence) else { continue }
            let rawDimension = tag.dimension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var rawValue = tag.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawDimension.isEmpty, !rawValue.isEmpty,
                  rawDimension.count <= 64, rawValue.count <= 128,
                  !rawValue.contains("\n"), !rawValue.contains("\t")
            else { continue }
            switch rawDimension {
            case "mood":
                guard RecommendationIndexV2.moods.contains(rawValue) else { continue }
            case "scene":
                guard RecommendationIndexV2.scenes.contains(rawValue) else { continue }
            case "vocal":
                guard RecommendationIndexV2.vocals.contains(rawValue) else { continue }
            case "texture":
                guard RecommendationIndexV2.textures.contains(rawValue) else { continue }
            case "style":
                guard RecommendationIndexV2.styles.contains(rawValue) else { continue }
            case "energy":
                guard let number = Int(rawValue), (1...10).contains(number) else { continue }
            case "tempo", "acousticness", "danceability":
                guard let number = Int(rawValue), (1...5).contains(number) else { continue }
            case "tag":
                // 开放语义标签：规范化后入库，保持与写回路径一致。
                guard let canonical = RecommendationIndexV2.normalizeSemanticTag(rawValue) else { continue }
                if rawValue != canonical { rawValue = canonical }
            default:
                // 自建维度：非保留名、长度限制、无换行制表符。
                let reserved = Set(["mood", "scene", "vocal", "texture", "style", "energy", "tempo", "acousticness", "danceability"])
                let dimension = tag.dimension.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !dimension.isEmpty,
                      dimension.count <= 24,
                      !reserved.contains(dimension.lowercased()),
                      !dimension.contains("\n"), !dimension.contains("\t")
                else { continue }
                guard rawValue.count <= 32 else { continue }
            }
            let key = rawDimension + "\u{1F}" + rawValue
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append((rawDimension, rawValue))
        }
        return result
    }

    private static func stableFingerprint(_ remoteTrackIDs: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for id in remoteTrackIDs {
            for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        }
        return String(hash, radix: 16)
    }
}
