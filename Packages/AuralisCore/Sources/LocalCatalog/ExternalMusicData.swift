import Domain
import Foundation

public enum ExternalMusicMatchMethod: String, Codable, Sendable, Hashable {
    case embeddedRecordingMBID
    case isrc
    case metadataExact
    case metadataFuzzy
    case userConfirmed
}

/// 本地曲目到开放音乐数据库实体的持久身份。主键始终是服务器作用域的 GlobalID。
public struct ExternalMusicIdentity: Codable, Sendable, Hashable {
    public let globalTrackID: GlobalID
    public var recordingMBID: String?
    public var releaseMBID: String?
    public var releaseGroupMBID: String?
    public var artistMBID: String?
    public var isrc: String?
    public var matchConfidence: Double
    public var matchMethod: ExternalMusicMatchMethod
    public var verifiedAt: Date

    public init(
        globalTrackID: GlobalID,
        recordingMBID: String? = nil,
        releaseMBID: String? = nil,
        releaseGroupMBID: String? = nil,
        artistMBID: String? = nil,
        isrc: String? = nil,
        matchConfidence: Double,
        matchMethod: ExternalMusicMatchMethod,
        verifiedAt: Date = .now
    ) {
        self.globalTrackID = globalTrackID
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.releaseGroupMBID = releaseGroupMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.matchConfidence = min(max(matchConfidence, 0), 1)
        self.matchMethod = matchMethod
        self.verifiedAt = verifiedAt
    }
}

/// 中等置信度结果只保存为候选，不能静默绑定到本地歌曲。
public struct ExternalMusicIdentityCandidate: Codable, Sendable, Hashable {
    public let globalTrackID: GlobalID
    public let recordingMBID: String
    public var releaseMBID: String?
    public var releaseGroupMBID: String?
    public var artistMBID: String?
    public var isrc: String?
    public var title: String
    public var artistName: String
    public var duration: TimeInterval?
    public var confidence: Double
    public var matchMethod: ExternalMusicMatchMethod
    public var createdAt: Date

    public init(
        globalTrackID: GlobalID,
        recordingMBID: String,
        releaseMBID: String? = nil,
        releaseGroupMBID: String? = nil,
        artistMBID: String? = nil,
        isrc: String? = nil,
        title: String,
        artistName: String,
        duration: TimeInterval? = nil,
        confidence: Double,
        matchMethod: ExternalMusicMatchMethod,
        createdAt: Date = .now
    ) {
        self.globalTrackID = globalTrackID
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.releaseGroupMBID = releaseGroupMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.title = title
        self.artistName = artistName
        self.duration = duration
        self.confidence = min(max(confidence, 0), 1)
        self.matchMethod = matchMethod
        self.createdAt = createdAt
    }
}

public enum CommunityMusicSource: String, Codable, Sendable, Hashable, CaseIterable {
    case musicBrainz
    case critiqueBrainz
    case listenBrainz
}

/// 公开音乐数据库的独立隐私偏好。它与“向大模型发送歌曲元数据”是两个不同目的地，
/// 因此不能复用 AI Provider 的隐私开关。
public struct ExternalMusicPreferences: Sendable, Equatable {
    public static let defaultCacheTTL: TimeInterval = 14 * 24 * 60 * 60

    public enum Keys {
        public static let enabled = "auralis.externalMusic.enabled"
        public static let musicBrainz = "auralis.externalMusic.musicBrainz"
        public static let critiqueBrainz = "auralis.externalMusic.critiqueBrainz"
        public static let listenBrainz = "auralis.externalMusic.listenBrainz"
    }

    public var enabled: Bool
    public var musicBrainzEnabled: Bool
    public var critiqueBrainzEnabled: Bool
    public var listenBrainzEnabled: Bool
    public var cacheTTL: TimeInterval

    public init(
        enabled: Bool = true,
        musicBrainzEnabled: Bool = true,
        critiqueBrainzEnabled: Bool = true,
        listenBrainzEnabled: Bool = true,
        cacheTTL: TimeInterval = ExternalMusicPreferences.defaultCacheTTL
    ) {
        self.enabled = enabled
        self.musicBrainzEnabled = musicBrainzEnabled
        self.critiqueBrainzEnabled = critiqueBrainzEnabled
        self.listenBrainzEnabled = listenBrainzEnabled
        self.cacheTTL = max(0, cacheTTL)
    }

    public static func current(defaults: UserDefaults = .standard) -> ExternalMusicPreferences {
        func value(_ key: String) -> Bool {
            // 保持升级前“按需公开读取”的行为；用户一旦操作开关就以持久值为准。
            defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        return ExternalMusicPreferences(
            enabled: value(Keys.enabled),
            musicBrainzEnabled: value(Keys.musicBrainz),
            critiqueBrainzEnabled: value(Keys.critiqueBrainz),
            listenBrainzEnabled: value(Keys.listenBrainz)
        )
    }

    public func isEnabled(_ source: CommunityMusicSource) -> Bool {
        guard enabled else { return false }
        return switch source {
        case .musicBrainz: musicBrainzEnabled
        case .critiqueBrainz: critiqueBrainzEnabled
        case .listenBrainz: listenBrainzEnabled
        }
    }
}

public enum CommunityMetricStatus: String, Codable, Sendable, Hashable {
    case disabled
    case loading
    case available
    case noData
    case notSupported
    case rateLimited
    case unavailable
    case failed
}

/// 每个来源独立保存；不同含义的数字永不合成为伪造的“综合评分”。
public struct CommunityMusicMetric: Codable, Sendable, Hashable {
    public let source: CommunityMusicSource
    public let entityID: String?
    public var rating: Double?
    public var ratingCount: Int?
    public var reviewCount: Int?
    public var listenCount: Int?
    public var listenerCount: Int?
    public var fetchedAt: Date
    public var status: CommunityMetricStatus

    public init(
        source: CommunityMusicSource,
        entityID: String? = nil,
        rating: Double? = nil,
        ratingCount: Int? = nil,
        reviewCount: Int? = nil,
        listenCount: Int? = nil,
        listenerCount: Int? = nil,
        fetchedAt: Date = .now,
        status: CommunityMetricStatus
    ) {
        self.source = source
        self.entityID = entityID
        self.rating = rating
        self.ratingCount = ratingCount
        self.reviewCount = reviewCount
        self.listenCount = listenCount
        self.listenerCount = listenerCount
        self.fetchedAt = fetchedAt
        self.status = status
    }
}

public struct CommunityMusicMetrics: Codable, Sendable, Hashable {
    public let globalTrackID: GlobalID
    public var values: [CommunityMusicMetric]

    public init(globalTrackID: GlobalID, values: [CommunityMusicMetric]) {
        self.globalTrackID = globalTrackID
        self.values = values.sorted { $0.source.rawValue < $1.source.rawValue }
    }

    public func value(for source: CommunityMusicSource) -> CommunityMusicMetric? {
        values.first { $0.source == source }
    }

    public func isFresh(now: Date = .now, maxAge: TimeInterval = 14 * 86_400) -> Bool {
        !values.isEmpty && values.allSatisfy { now.timeIntervalSince($0.fetchedAt) <= maxAge }
    }

    public var hasCommunityEvidence: Bool {
        values.contains { $0.status == .available }
    }
}

public extension LocalCatalogStore {
    func externalMusicIdentity(for globalTrackID: GlobalID) throws -> ExternalMusicIdentity? {
        guard let row = try db.query(
            "SELECT * FROM external_music_identities WHERE global_track_id = ? LIMIT 1",
            [.text(globalTrackID.description)]
        ).first,
        let methodRaw = row["match_method"]?.string,
        let method = ExternalMusicMatchMethod(rawValue: methodRaw)
        else { return nil }
        return ExternalMusicIdentity(
            globalTrackID: globalTrackID,
            recordingMBID: row["recording_mbid"]?.string,
            releaseMBID: row["release_mbid"]?.string,
            releaseGroupMBID: row["release_group_mbid"]?.string,
            artistMBID: row["artist_mbid"]?.string,
            isrc: row["isrc"]?.string,
            matchConfidence: row["match_confidence"]?.double ?? 0,
            matchMethod: method,
            verifiedAt: Date(timeIntervalSince1970: row["verified_at"]?.double ?? 0)
        )
    }

    func upsertExternalMusicIdentity(_ identity: ExternalMusicIdentity) throws {
        try db.run(
            """
            INSERT INTO external_music_identities(
                global_track_id, recording_mbid, release_mbid, release_group_mbid,
                artist_mbid, isrc, match_confidence, match_method, verified_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(global_track_id) DO UPDATE SET
                recording_mbid=excluded.recording_mbid,
                release_mbid=excluded.release_mbid,
                release_group_mbid=excluded.release_group_mbid,
                artist_mbid=excluded.artist_mbid,
                isrc=excluded.isrc,
                match_confidence=excluded.match_confidence,
                match_method=excluded.match_method,
                verified_at=excluded.verified_at
            """,
            [
                .text(identity.globalTrackID.description),
                identity.recordingMBID.map(SQLiteValue.text) ?? .null,
                identity.releaseMBID.map(SQLiteValue.text) ?? .null,
                identity.releaseGroupMBID.map(SQLiteValue.text) ?? .null,
                identity.artistMBID.map(SQLiteValue.text) ?? .null,
                identity.isrc.map(SQLiteValue.text) ?? .null,
                .real(identity.matchConfidence),
                .text(identity.matchMethod.rawValue),
                .real(identity.verifiedAt.timeIntervalSince1970),
            ]
        )
    }

    func replaceExternalMusicCandidates(
        _ candidates: [ExternalMusicIdentityCandidate],
        for globalTrackID: GlobalID
    ) throws {
        try db.transaction {
            try db.run(
                "DELETE FROM external_music_candidates WHERE global_track_id = ?",
                [.text(globalTrackID.description)]
            )
            for candidate in candidates {
                let payload = String(decoding: try encoder.encode(candidate), as: UTF8.self)
                try db.run(
                    """
                    INSERT INTO external_music_candidates(
                        global_track_id, recording_mbid, payload, confidence, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(globalTrackID.description), .text(candidate.recordingMBID),
                        .text(payload), .real(candidate.confidence),
                        .real(candidate.createdAt.timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    func externalMusicCandidates(for globalTrackID: GlobalID) throws -> [ExternalMusicIdentityCandidate] {
        try db.query(
            "SELECT payload FROM external_music_candidates WHERE global_track_id = ? ORDER BY confidence DESC",
            [.text(globalTrackID.description)]
        ).compactMap { row in
            row["payload"]?.string.flatMap { try? decoder.decode(ExternalMusicIdentityCandidate.self, from: Data($0.utf8)) }
        }
    }

    func upsertCommunityMusicMetric(_ metric: CommunityMusicMetric, for globalTrackID: GlobalID) throws {
        let payload = String(decoding: try encoder.encode(metric), as: UTF8.self)
        try db.run(
            """
            INSERT INTO community_music_metrics(global_track_id, source, payload, fetched_at, status)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(global_track_id, source) DO UPDATE SET
                payload=excluded.payload, fetched_at=excluded.fetched_at, status=excluded.status
            """,
            [
                .text(globalTrackID.description), .text(metric.source.rawValue), .text(payload),
                .real(metric.fetchedAt.timeIntervalSince1970), .text(metric.status.rawValue),
            ]
        )
    }

    func communityMusicMetrics(for globalTrackID: GlobalID) throws -> CommunityMusicMetrics {
        let values = try db.query(
            "SELECT payload FROM community_music_metrics WHERE global_track_id = ? ORDER BY source",
            [.text(globalTrackID.description)]
        ).compactMap { row in
            row["payload"]?.string.flatMap { try? decoder.decode(CommunityMusicMetric.self, from: Data($0.utf8)) }
        }
        return CommunityMusicMetrics(globalTrackID: globalTrackID, values: values)
    }

    /// 普通“清除公开音乐数据缓存”：清除元数据新鲜度、大众指标、评论与低置信候选，
    /// **保留高置信度 Stable Identity**（避免清缓存后丢失已核验的 MBID/ISRC）。
    /// 不触碰歌曲、播放历史、收藏或其他本地目录数据。
    func clearExternalMusicCache() throws {
        try db.transaction {
            try db.run("DELETE FROM community_music_metrics")
            try db.run("DELETE FROM community_music_evidence")
            try db.run("DELETE FROM community_music_reviews")
            try db.run("DELETE FROM external_music_candidates")
        }
    }

    /// 高级“重置音乐身份匹配”：连 Stable Identity 一起清空，下次按需重新识别 MBID。
    func resetExternalMusicIdentity() throws {
        try db.transaction {
            try db.run("DELETE FROM community_music_metrics")
            try db.run("DELETE FROM community_music_evidence")
            try db.run("DELETE FROM community_music_reviews")
            try db.run("DELETE FROM external_music_candidates")
            try db.run("DELETE FROM external_music_identities")
        }
    }
}

// MARK: - Community Music Evidence（详情级）

/// CritiqueBrainz 单条评论（聚合摘要之外的详情数据）。
/// 必须保留 license / source / sourceURL；Agent 默认只取少量 excerpt，不塞全文。
public struct CommunityMusicReview: Codable, Sendable, Hashable {
    public var reviewID: String
    public var entityID: String
    public var authorName: String?
    public var rating: Double?
    public var publishedAt: Date?
    public var language: String?
    public var excerpt: String
    public var fullText: String?
    public var positiveVotes: Int?
    public var negativeVotes: Int?
    public var popularity: Double?
    public var licenseID: String?
    public var sourceName: String?
    public var sourceURL: String?
    public var fetchedAt: Date

    public init(
        reviewID: String,
        entityID: String,
        authorName: String? = nil,
        rating: Double? = nil,
        publishedAt: Date? = nil,
        language: String? = nil,
        excerpt: String,
        fullText: String? = nil,
        positiveVotes: Int? = nil,
        negativeVotes: Int? = nil,
        popularity: Double? = nil,
        licenseID: String? = nil,
        sourceName: String? = nil,
        sourceURL: String? = nil,
        fetchedAt: Date = .now
    ) {
        self.reviewID = reviewID
        self.entityID = entityID
        self.authorName = authorName
        self.rating = rating
        self.publishedAt = publishedAt
        self.language = language
        self.excerpt = excerpt
        self.fullText = fullText
        self.positiveVotes = positiveVotes
        self.negativeVotes = negativeVotes
        self.popularity = popularity
        self.licenseID = licenseID
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
    }
}

/// MusicBrainz 录音详情（真实 API 字段，无字段不堆“未知”）。
public struct MusicBrainzDetail: Codable, Sendable, Hashable {
    public var recordingMBID: String?
    public var releaseMBID: String?
    public var releaseGroupMBID: String?
    public var artistMBID: String?
    public var isrc: String?
    public var title: String?
    public var artistCredit: String?
    public var rating: Double?
    public var votesCount: Int?
    public var genres: [String]
    public var tags: [String]
    public var releaseDate: String?
    public var releaseType: String?

    public init(
        recordingMBID: String? = nil,
        releaseMBID: String? = nil,
        releaseGroupMBID: String? = nil,
        artistMBID: String? = nil,
        isrc: String? = nil,
        title: String? = nil,
        artistCredit: String? = nil,
        rating: Double? = nil,
        votesCount: Int? = nil,
        genres: [String] = [],
        tags: [String] = [],
        releaseDate: String? = nil,
        releaseType: String? = nil
    ) {
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.releaseGroupMBID = releaseGroupMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.title = title
        self.artistCredit = artistCredit
        self.rating = rating
        self.votesCount = votesCount
        self.genres = genres
        self.tags = tags
        self.releaseDate = releaseDate
        self.releaseType = releaseType
    }
}

/// 歌曲公开音乐资料详情：身份 + 各来源详情 + 评论（供详情页与 Agent 使用）。
public struct CommunityMusicEvidence: Codable, Sendable, Hashable {
    public var globalTrackID: GlobalID
    public var identity: ExternalMusicIdentity?
    public var musicBrainz: MusicBrainzDetail?
    public var critiqueBrainzAggregate: CommunityMusicMetric?
    public var listenBrainz: CommunityMusicMetric?
    public var reviews: [CommunityMusicReview]
    public var fetchedAt: Date

    public init(
        globalTrackID: GlobalID,
        identity: ExternalMusicIdentity? = nil,
        musicBrainz: MusicBrainzDetail? = nil,
        critiqueBrainzAggregate: CommunityMusicMetric? = nil,
        listenBrainz: CommunityMusicMetric? = nil,
        reviews: [CommunityMusicReview] = [],
        fetchedAt: Date = .now
    ) {
        self.globalTrackID = globalTrackID
        self.identity = identity
        self.musicBrainz = musicBrainz
        self.critiqueBrainzAggregate = critiqueBrainzAggregate
        self.listenBrainz = listenBrainz
        self.reviews = reviews
        self.fetchedAt = fetchedAt
    }

    /// 是否存在任何可核验的大众评价证据。
    public var hasCommunityEvidence: Bool {
        musicBrainz != nil || critiqueBrainzAggregate != nil || listenBrainz != nil || !reviews.isEmpty
    }
}

/// 各来源缓存策略（集中定义，不再统一一个 TTL）。
public enum ExternalMusicCachePolicy {
    /// 高置信度 Stable Identity：约 180 天。
    public static let identityTTL: TimeInterval = 180 * 24 * 60 * 60
    /// MusicBrainz 元数据：60 天（30～90 天窗口内）。
    public static let musicBrainzTTL: TimeInterval = 60 * 24 * 60 * 60
    /// CritiqueBrainz 聚合与评论：21 天（14～30 天窗口内）。
    public static let critiqueBrainzTTL: TimeInterval = 21 * 24 * 60 * 60
    /// ListenBrainz 收听统计：10 天（7～14 天窗口内）。
    public static let listenBrainzTTL: TimeInterval = 10 * 24 * 60 * 60
    /// 无数据负缓存：7 天。
    public static let noDataTTL: TimeInterval = 7 * 24 * 60 * 60
    /// 暂时性失败（限流 / 网络）：5 分钟。
    public static let transientFailureTTL: TimeInterval = 5 * 60
}

extension LocalCatalogStore {
    /// 按来源返回可用缓存 TTL；无数据/失败走更短负缓存。
    public static func cacheTTL(for source: CommunityMusicSource, status: CommunityMetricStatus) -> TimeInterval {
        switch status {
        case .available, .notSupported:
            switch source {
            case .musicBrainz: return ExternalMusicCachePolicy.musicBrainzTTL
            case .critiqueBrainz: return ExternalMusicCachePolicy.critiqueBrainzTTL
            case .listenBrainz: return ExternalMusicCachePolicy.listenBrainzTTL
            }
        case .noData:
            return ExternalMusicCachePolicy.noDataTTL
        case .rateLimited, .unavailable, .failed, .disabled, .loading:
            return ExternalMusicCachePolicy.transientFailureTTL
        }
    }

    public func upsertCommunityMusicReviews(
        _ reviews: [CommunityMusicReview],
        for globalTrackID: GlobalID
    ) throws {
        guard !reviews.isEmpty else { return }
        try db.transaction {
            for review in reviews {
                let payload = String(decoding: try encoder.encode(review), as: UTF8.self)
                try db.run(
                    """
                    INSERT INTO community_music_reviews (global_track_id, source, review_id, payload, fetched_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(global_track_id, source, review_id) DO UPDATE SET
                        payload = excluded.payload, fetched_at = excluded.fetched_at
                    """,
                    [
                        .text(globalTrackID.description), .text(CommunityMusicSource.critiqueBrainz.rawValue),
                        .text(review.reviewID), .text(payload),
                        .real(review.fetchedAt.timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    public func upsertCommunityMusicEvidence(
        _ evidence: CommunityMusicEvidence,
        for globalTrackID: GlobalID
    ) throws {
        let payload = String(decoding: try encoder.encode(evidence), as: UTF8.self)
        try db.run(
            """
            INSERT INTO community_music_evidence (global_track_id, payload, fetched_at)
            VALUES (?, ?, ?)
            ON CONFLICT(global_track_id) DO UPDATE SET
                payload = excluded.payload, fetched_at = excluded.fetched_at
            """,
            [.text(globalTrackID.description), .text(payload), .real(evidence.fetchedAt.timeIntervalSince1970)]
        )
    }

    public func communityMusicEvidence(for globalTrackID: GlobalID) throws -> CommunityMusicEvidence? {
        try db.query(
            "SELECT payload FROM community_music_evidence WHERE global_track_id = ? LIMIT 1",
            [.text(globalTrackID.description)]
        ).first.flatMap { row in
            row["payload"]?.string.flatMap { try? decoder.decode(CommunityMusicEvidence.self, from: Data($0.utf8)) }
        }
    }

    public func communityMusicReviews(for globalTrackID: GlobalID) throws -> [CommunityMusicReview] {
        try db.query(
            "SELECT payload FROM community_music_reviews WHERE global_track_id = ? ORDER BY fetched_at DESC",
            [.text(globalTrackID.description)]
        ).compactMap { row in
            row["payload"]?.string.flatMap { try? decoder.decode(CommunityMusicReview.self, from: Data($0.utf8)) }
        }
    }

    /// 清除评论缓存（普通清缓存的一部分）。
    func clearCommunityMusicReviews() throws {
        try db.run("DELETE FROM community_music_reviews")
    }
}
