import Domain
import Foundation
import LocalCatalog

public struct AgentExternalMusicResult: Sendable, Equatable {
    public let identity: ExternalMusicIdentity?
    public let candidates: [ExternalMusicIdentityCandidate]
    public let metrics: CommunityMusicMetrics
    /// 详情级公开音乐资料（MusicBrainz 详情 / CritiqueBrainz 评论 / ListenBrainz 统计）。
    /// 歌曲信息详情页与 Agent `music_get_public_evidence` 共用。
    public let evidence: CommunityMusicEvidence?

    public init(
        identity: ExternalMusicIdentity?,
        candidates: [ExternalMusicIdentityCandidate] = [],
        metrics: CommunityMusicMetrics,
        evidence: CommunityMusicEvidence? = nil
    ) {
        self.identity = identity
        self.candidates = candidates
        self.metrics = metrics
        self.evidence = evidence
    }
}

public protocol AgentExternalMusicService: Sendable {
    /// 只由歌曲鉴赏/歌曲信息显式触发；不得在启动或整库同步时批量调用。
    func enrich(track: Track, globalID: GlobalID) async -> AgentExternalMusicResult
    /// 带强制刷新：忽略本地指标缓存重新请求（身份匹配仍复用 Stable Identity）。
    func enrich(track: Track, globalID: GlobalID, forceRefresh: Bool) async -> AgentExternalMusicResult
}

public extension AgentExternalMusicService {
    func enrich(track: Track, globalID: GlobalID, forceRefresh: Bool) async -> AgentExternalMusicResult {
        await enrich(track: track, globalID: globalID)
    }
}

public enum ExternalMusicServiceError: Error, Sendable, Equatable {
    case invalidRequest
    case network
    case timeout
    case rateLimited
    case httpStatus(Int)
    case invalidResponse
    case cancelled
}

/// MusicBrainz 身份匹配 + 三个 MetaBrainz 数据源的按需读取器。
/// 结果写入 LocalCatalog，成功/无数据缓存 14 天；暂时性失败只短缓存。
public actor MusicBrainzExternalMusicService: AgentExternalMusicService {
    public struct Endpoints: Sendable {
        public var musicBrainz: URL
        public var critiqueBrainz: URL
        public var listenBrainz: URL

        public init(
            musicBrainz: URL = URL(string: "https://musicbrainz.org/ws/2")!,
            critiqueBrainz: URL = URL(string: "https://critiquebrainz.org/ws/1")!,
            listenBrainz: URL = URL(string: "https://api.listenbrainz.org/1")!
        ) {
            self.musicBrainz = musicBrainz
            self.critiqueBrainz = critiqueBrainz
            self.listenBrainz = listenBrainz
        }
    }

    private let catalog: LocalCatalogStore
    private let session: URLSession
    private let endpoints: Endpoints
    private let now: @Sendable () -> Date
    private let musicBrainzMinimumInterval: TimeInterval
    private var lastMusicBrainzRequestAt: Date?
    private let userAgent: String
    private let preferencesProvider: @Sendable () -> ExternalMusicPreferences

    public init(
        catalog: LocalCatalogStore,
        session: URLSession = .shared,
        endpoints: Endpoints = .init(),
        userAgent: String = "Auralis/1.0.2 (https://github.com/zyk1172/Auralis)",
        musicBrainzMinimumInterval: TimeInterval = 1.05,
        preferencesProvider: @escaping @Sendable () -> ExternalMusicPreferences = { .current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.catalog = catalog
        self.session = session
        self.endpoints = endpoints
        self.userAgent = userAgent
        self.musicBrainzMinimumInterval = max(musicBrainzMinimumInterval, 0)
        self.preferencesProvider = preferencesProvider
        self.now = now
    }

    /// 普通清缓存：清除元数据新鲜度、大众指标、评论与低置信候选，
    /// 保留高置信度 Stable Identity（避免重新识别 MBID）。
    public func clearCache() async throws {
        try await catalog.clearExternalMusicCache()
    }

    /// 高级“重置音乐身份匹配”：连 Stable Identity 一起清空，下次按需重新识别。
    public func resetIdentity() async throws {
        try await catalog.resetExternalMusicIdentity()
    }

    public func enrich(track: Track, globalID: GlobalID) async -> AgentExternalMusicResult {
        await enrich(track: track, globalID: globalID, forceRefresh: false)
    }

    public func enrich(track: Track, globalID: GlobalID, forceRefresh: Bool) async -> AgentExternalMusicResult {
        if Task.isCancelled {
            return AgentExternalMusicResult(
                identity: nil,
                metrics: CommunityMusicMetrics(globalTrackID: globalID, values: [])
            )
        }

        let preferences = preferencesProvider()
        let cachedIdentity = try? await catalog.externalMusicIdentity(for: globalID)
        let cachedCandidates = (try? await catalog.externalMusicCandidates(for: globalID)) ?? []
        guard preferences.enabled else {
            return AgentExternalMusicResult(
                identity: cachedIdentity,
                candidates: cachedCandidates,
                metrics: disabledMetrics(globalID: globalID)
            )
        }

        let identity: ExternalMusicIdentity?
        var candidates: [ExternalMusicIdentityCandidate] = []
        // MBID 是稳定外部身份，不因为本地校验时间过期而丢弃；指标有自己的刷新周期。
        if let cachedIdentity, cachedIdentity.recordingMBID != nil {
            identity = cachedIdentity
        } else if preferences.musicBrainzEnabled,
                  let cachedIdentity, let isrc = cachedIdentity.isrc, !isrc.isEmpty {
            let match = await matchByISRC(isrc, track: track, globalID: globalID)
            identity = match.identity
            candidates = match.candidates
        } else if preferences.musicBrainzEnabled {
            let match = await match(track: track, globalID: globalID)
            identity = match.identity
            candidates = match.candidates
        } else {
            // MusicBrainz 被单独关闭时只能使用本地已有身份，绝不为了其他来源偷偷匹配。
            identity = cachedIdentity
            candidates = cachedCandidates
        }

        let cached = try? await catalog.communityMusicMetrics(for: globalID)
        // forceRefresh 时忽略缓存（仍复用 Stable Identity）。
        func cachedValue(_ source: CommunityMusicSource) -> CommunityMusicMetric? {
            forceRefresh ? nil : cached?.value(for: source)
        }

        // MusicBrainz：一次 lookup 同时得到 summary metric 与详情（不重复打 API）。
        let musicBrainzResult = await fetchMusicBrainzMetricAndDetail(
            identity: identity,
            cached: cachedValue(.musicBrainz),
            preferences: preferences
        )
        let critiqueBrainz = await metric(
            for: .critiqueBrainz, identity: identity,
            cached: cachedValue(.critiqueBrainz), preferences: preferences
        )
        let listenBrainz = await metric(
            for: .listenBrainz, identity: identity,
            cached: cachedValue(.listenBrainz), preferences: preferences
        )
        let metrics = [musicBrainzResult.metric, critiqueBrainz, listenBrainz]
        for metric in metrics where metric.status != .disabled && metric.status != .loading {
            try? await catalog.upsertCommunityMusicMetric(metric, for: globalID)
        }

        // 详情级 Evidence：全部来自缓存（零网络）时保持已缓存证据不变，避免 fetchedAt 抖动；
        // 有新鲜获取时重建。
        var evidence: CommunityMusicEvidence?
        let allFromCache = musicBrainzResult.fromCache
            && (critiqueBrainz.fetchedAt == cached?.value(for: .critiqueBrainz)?.fetchedAt)
            && (listenBrainz.fetchedAt == cached?.value(for: .listenBrainz)?.fetchedAt)
        if allFromCache, let cachedEvidence = try? await catalog.communityMusicEvidence(for: globalID) {
            evidence = cachedEvidence
        } else {
            evidence = await buildEvidence(
                track: track,
                globalID: globalID,
                identity: identity,
                metrics: metrics,
                musicBrainzDetail: musicBrainzResult.detail,
                preferences: preferences
            )
        }
        if let evidence {
            try? await catalog.upsertCommunityMusicEvidence(evidence, for: globalID)
        }

        return AgentExternalMusicResult(
            identity: identity,
            candidates: candidates,
            metrics: CommunityMusicMetrics(globalTrackID: globalID, values: metrics),
            evidence: evidence
        )
    }

    /// MusicBrainz：metric + 详情一次 lookup 获取；返回是否命中缓存。
    private func fetchMusicBrainzMetricAndDetail(
        identity: ExternalMusicIdentity?,
        cached: CommunityMusicMetric?,
        preferences: ExternalMusicPreferences
    ) async -> (metric: CommunityMusicMetric, detail: MusicBrainzDetail?, fromCache: Bool) {
        guard preferences.isEnabled(.musicBrainz) else {
            return (metric(.musicBrainz, nil, status: .disabled), nil, true)
        }
        if let cached, isFresh(cached) {
            return (cached, nil, true)
        }
        guard let identity else {
            return (metric(.musicBrainz, nil, status: .noData), nil, false)
        }
        guard let mbid = identity.recordingMBID else {
            return (metric(.musicBrainz, identity.recordingMBID, status: .noData), nil, false)
        }
        do {
            let lookup = try await musicBrainzLookup(mbid: mbid)
            let detail = Self.detail(from: lookup, mbid: mbid)
            guard let rating = lookup.rating, (rating.votesCount ?? 0) > 0 else {
                return (metric(.musicBrainz, mbid, status: .noData), detail, false)
            }
            let metric = CommunityMusicMetric(
                source: .musicBrainz,
                entityID: mbid,
                rating: rating.value,
                ratingCount: rating.votesCount,
                fetchedAt: now(),
                status: .available
            )
            return (metric, detail, false)
        } catch {
            return (metric(.musicBrainz, mbid, status: status(for: error)), nil, false)
        }
    }

    /// 组装详情级 Evidence。各来源只在该来源开启且（新取或缓存可用）时纳入。
    private func buildEvidence(
        track: Track,
        globalID: GlobalID,
        identity: ExternalMusicIdentity?,
        metrics: [CommunityMusicMetric],
        musicBrainzDetail: MusicBrainzDetail?,
        preferences: ExternalMusicPreferences
    ) async -> CommunityMusicEvidence? {
        var reviews: [CommunityMusicReview] = []
        if preferences.isEnabled(.critiqueBrainz),
           identity?.releaseGroupMBID != nil,
           let fresh = try? await catalog.communityMusicReviews(for: globalID), !fresh.isEmpty {
            reviews = fresh
        }

        let critique = metrics.first(where: { $0.source == .critiqueBrainz })
        let listen = metrics.first(where: { $0.source == .listenBrainz })
        let hasAny = musicBrainzDetail != nil || critique != nil || listen != nil || !reviews.isEmpty
        guard hasAny else { return nil }
        return CommunityMusicEvidence(
            globalTrackID: globalID,
            identity: identity,
            musicBrainz: musicBrainzDetail,
            critiqueBrainzAggregate: critique,
            listenBrainz: listen,
            reviews: reviews,
            fetchedAt: now()
        )
    }

    private static func detail(from lookup: MBRecordingLookup, mbid: String) -> MusicBrainzDetail? {
        let release = lookup.releases?.max { lhs, rhs in
            (lhs.date ?? "") < (rhs.date ?? "")
        }
        return MusicBrainzDetail(
            recordingMBID: mbid,
            releaseMBID: release?.id,
            releaseGroupMBID: release?.releaseGroup?.id,
            artistMBID: lookup.artistCredit?.first?.artist?.id,
            isrc: lookup.isrcs?.first,
            title: lookup.title,
            artistCredit: artistCreditString(lookup.artistCredit),
            rating: lookup.rating?.value,
            votesCount: lookup.rating?.votesCount,
            genres: (lookup.genres ?? []).map(\.name),
            tags: (lookup.tags ?? []).map(\.name),
            releaseDate: release?.date,
            releaseType: release?.releaseGroup?.primaryType
        )
    }

    private func metric(
        for source: CommunityMusicSource,
        identity: ExternalMusicIdentity?,
        cached: CommunityMusicMetric?,
        preferences: ExternalMusicPreferences
    ) async -> CommunityMusicMetric {
        guard preferences.isEnabled(source) else {
            return metric(source, nil, status: .disabled)
        }
        if let cached, isFresh(cached) { return cached }
        guard let identity else { return metric(source, nil, status: .noData) }
        switch source {
        case .musicBrainz: return await fetchMusicBrainzMetricAndDetail(identity: identity, cached: nil, preferences: ExternalMusicPreferences.current()).metric
        case .critiqueBrainz: return await fetchCritiqueBrainzMetric(identity: identity)
        case .listenBrainz: return await fetchListenBrainzMetric(identity: identity)
        }
    }

    private func disabledMetrics(globalID: GlobalID) -> CommunityMusicMetrics {
        CommunityMusicMetrics(
            globalTrackID: globalID,
            values: CommunityMusicSource.allCases.map { metric($0, nil, status: .disabled) }
        )
    }

    /// 按来源 + 状态使用集中缓存策略：成功/无数据走各自 TTL，失败走短负缓存。
    private func isFresh(_ metric: CommunityMusicMetric) -> Bool {
        let current = now()
        let allowedAge = LocalCatalogStore.cacheTTL(for: metric.source, status: metric.status)
        return allowedAge > 0 && current.timeIntervalSince(metric.fetchedAt) <= allowedAge
    }

    private func match(
        track: Track,
        globalID: GlobalID
    ) async -> (identity: ExternalMusicIdentity?, candidates: [ExternalMusicIdentityCandidate]) {
        do {
            var components = URLComponents(
                url: endpoints.musicBrainz.appendingPathComponent("recording"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "query", value: "recording:\"\(lucene(track.title))\" AND artist:\"\(lucene(track.artistName))\""),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "8"),
            ]
            guard let url = components?.url else { throw ExternalMusicServiceError.invalidRequest }
            let data = try await request(url: url, musicBrainz: true)
            let response = try JSONDecoder().decode(MBSearchResponse.self, from: data)
            let scored = response.recordings.map { recording in
                makeCandidate(recording, track: track, globalID: globalID)
            }.sorted { $0.confidence > $1.confidence }

            guard let best = scored.first else {
                try? await catalog.replaceExternalMusicCandidates([], for: globalID)
                return (nil, [])
            }
            if best.confidence >= 0.90 {
                let identity = ExternalMusicIdentity(
                    globalTrackID: globalID,
                    recordingMBID: best.recordingMBID,
                    releaseMBID: best.releaseMBID,
                    releaseGroupMBID: best.releaseGroupMBID,
                    artistMBID: best.artistMBID,
                    isrc: best.isrc,
                    matchConfidence: best.confidence,
                    matchMethod: best.matchMethod,
                    verifiedAt: now()
                )
                try? await catalog.upsertExternalMusicIdentity(identity)
                try? await catalog.replaceExternalMusicCandidates([], for: globalID)
                return (identity, [])
            }

            let medium = Array(scored.filter { $0.confidence >= 0.65 }.prefix(5))
            try? await catalog.replaceExternalMusicCandidates(medium, for: globalID)
            return (nil, medium)
        } catch {
            return (nil, (try? await catalog.externalMusicCandidates(for: globalID)) ?? [])
        }
    }

    /// ISRC 是录音级标识，优先于标题/艺人模糊匹配；命中后仍把完整身份写回本地。
    private func matchByISRC(
        _ isrc: String,
        track: Track,
        globalID: GlobalID
    ) async -> (identity: ExternalMusicIdentity?, candidates: [ExternalMusicIdentityCandidate]) {
        do {
            var components = URLComponents(
                url: endpoints.musicBrainz.appendingPathComponent("recording"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "query", value: "isrc:\(lucene(isrc))"),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "2"),
            ]
            guard let url = components?.url else { throw ExternalMusicServiceError.invalidRequest }
            let data = try await request(url: url, musicBrainz: true)
            let response = try JSONDecoder().decode(MBSearchResponse.self, from: data)
            guard let recording = response.recordings.first else { return (nil, []) }
            // ISRC 对 Recording 匹配权重很高，但 Release 仍要结合专辑/艺人/时长选择，
            // 不直接拿 releases.first。
            let release = recording.releases?.max { lhs, rhs in
                albumSimilarity(lhs.title, track.albumTitle) < albumSimilarity(rhs.title, track.albumTitle)
            }
            let identity = ExternalMusicIdentity(
                globalTrackID: globalID,
                recordingMBID: recording.id,
                releaseMBID: release?.id,
                releaseGroupMBID: release?.releaseGroup?.id,
                artistMBID: recording.artistCredit?.first?.artist?.id,
                isrc: recording.isrcs?.first ?? isrc,
                matchConfidence: 1,
                matchMethod: .isrc,
                verifiedAt: now()
            )
            try? await catalog.upsertExternalMusicIdentity(identity)
            try? await catalog.replaceExternalMusicCandidates([], for: globalID)
            return (identity, [])
        } catch {
            return (nil, (try? await catalog.externalMusicCandidates(for: globalID)) ?? [])
        }
    }

    private func makeCandidate(
        _ recording: MBRecording,
        track: Track,
        globalID: GlobalID
    ) -> ExternalMusicIdentityCandidate {
        let candidateArtist = Self.artistCreditString(recording.artistCredit)
        let candidateDuration = recording.length.map { Double($0) / 1_000 }
        let titleExact = normalized(recording.title) == normalized(track.title)
        let artistExact = normalized(candidateArtist) == normalized(track.artistName)
        let durationDifference = candidateDuration.map { abs($0 - track.duration) }
        let durationScore: Double = switch durationDifference {
        case .some(let value) where value <= 2: 0.10
        case .some(let value) where value <= 5: 0.06
        case .none: 0.03
        default: 0
        }
        let release = recording.releases?.max { lhs, rhs in
            albumSimilarity(lhs.title, track.albumTitle) < albumSimilarity(rhs.title, track.albumTitle)
        }
        var confidence = Double(recording.score ?? 0) / 100 * 0.40
        confidence += titleExact ? 0.25 : 0.10 * similarity(recording.title, track.title)
        confidence += artistExact ? 0.20 : 0.08 * similarity(candidateArtist, track.artistName)
        confidence += durationScore
        confidence += 0.05 * albumSimilarity(release?.title ?? "", track.albumTitle)
        confidence -= versionMismatchPenalty(local: track.title + " " + track.albumTitle, remote: recording.title + " " + (release?.title ?? ""))
        confidence = min(max(confidence, 0), 1)
        return ExternalMusicIdentityCandidate(
            globalTrackID: globalID,
            recordingMBID: recording.id,
            releaseMBID: release?.id,
            releaseGroupMBID: release?.releaseGroup?.id,
            artistMBID: recording.artistCredit?.first?.artist?.id,
            isrc: recording.isrcs?.first,
            title: recording.title,
            artistName: candidateArtist,
            duration: candidateDuration,
            confidence: confidence,
            matchMethod: titleExact && artistExact && (durationDifference ?? 0) <= 5 ? .metadataExact : .metadataFuzzy,
            createdAt: now()
        )
    }

    /// 统一 MB 录音查询（metric + detail 共用，避免重复打 API）。
    private func musicBrainzLookup(mbid: String) async throws -> MBRecordingLookup {
        var components = URLComponents(
            url: endpoints.musicBrainz.appendingPathComponent("recording/\(mbid)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "inc", value: "ratings+isrcs+artist-credits+releases+release-groups+genres+tags"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components?.url else { throw ExternalMusicServiceError.invalidRequest }
        let data = try await request(url: url, musicBrainz: true)
        return try JSONDecoder().decode(MBRecordingLookup.self, from: data)
    }

    /// CritiqueBrainz：拉取聚合 + 有限真实评论（默认最多 10 条），容错解析。
    private func fetchCritiqueBrainzMetric(identity: ExternalMusicIdentity) async -> CommunityMusicMetric {
        guard let releaseGroupMBID = identity.releaseGroupMBID else {
            return metric(.critiqueBrainz, nil, status: .noData)
        }
        do {
            var components = URLComponents(
                url: endpoints.critiqueBrainz.appendingPathComponent("review/"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "entity_id", value: releaseGroupMBID),
                URLQueryItem(name: "entity_type", value: "release_group"),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components?.url else { throw ExternalMusicServiceError.invalidRequest }
            let data = try await request(url: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExternalMusicServiceError.invalidResponse
            }
            let average = object["average_rating"] as? [String: Any]
            let rating = number(average?["rating"] ?? average?["average_rating"])
            let ratingCount = integer(average?["count"] ?? average?["rating_count"])
            let reviewCount = integer(object["count"] ?? object["review_count"])
            let hasData = (ratingCount ?? 0) > 0 || (reviewCount ?? 0) > 0

            let rawReviews = object["reviews"] as? [[String: Any]] ?? []
            let reviews = rawReviews.prefix(10).compactMap { raw in
                Self.parseReview(raw, releaseGroupMBID: releaseGroupMBID, now: now())
            }
            if !reviews.isEmpty {
                try? await catalog.upsertCommunityMusicReviews(reviews, for: identity.globalTrackID)
            }
            return CommunityMusicMetric(
                source: .critiqueBrainz,
                entityID: releaseGroupMBID,
                rating: rating,
                ratingCount: ratingCount,
                reviewCount: reviewCount,
                fetchedAt: now(),
                status: hasData ? .available : .noData
            )
        } catch {
            return metric(.critiqueBrainz, releaseGroupMBID, status: status(for: error))
        }
    }

    /// 容错解析单条 CritiqueBrainz 评论；任一可选字段缺失不导致整条失败。
    private static func parseReview(
        _ raw: [String: Any],
        releaseGroupMBID: String,
        now: Date
    ) -> CommunityMusicReview? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let author = raw["user"] as? [String: Any]
        let text = raw["text"] as? String ?? ""
        guard !text.isEmpty else { return nil }
        let sourceName = raw["source"] as? String
        let license = raw["license"] as? String
        // excerpt：取前 280 字符，超出加省略号，避免详情/Agent 塞入全文。
        let excerpt = text.count > 280 ? String(text.prefix(277)) + "…" : text
        let dateString = raw["created"] as? String
        let publishedAt = dateString.flatMap(Self.isoDate)
        return CommunityMusicReview(
            reviewID: id,
            entityID: releaseGroupMBID,
            authorName: author?["display_name"] as? String ?? (author?["name"] as? String),
            rating: (raw["rating"] as? NSNumber)?.doubleValue,
            publishedAt: publishedAt,
            language: raw["language"] as? String,
            excerpt: excerpt,
            fullText: nil,
            positiveVotes: (raw["vote"] as? [String: Any])?["positive"] as? Int,
            negativeVotes: (raw["vote"] as? [String: Any])?["negative"] as? Int,
            popularity: nil,
            licenseID: license,
            sourceName: sourceName,
            sourceURL: raw["source_url"] as? String,
            fetchedAt: now
        )
    }

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func fetchListenBrainzMetric(identity: ExternalMusicIdentity) async -> CommunityMusicMetric {
        let entityID: String
        let endpoint: String
        let bodyKey: String
        if let releaseGroupMBID = identity.releaseGroupMBID {
            entityID = releaseGroupMBID
            endpoint = "popularity/release-group"
            bodyKey = "release_group_mbids"
        } else if let recordingMBID = identity.recordingMBID {
            entityID = recordingMBID
            endpoint = "popularity/recording"
            bodyKey = "recording_mbids"
        } else {
            return metric(.listenBrainz, nil, status: .noData)
        }
        do {
            let url = endpoints.listenBrainz.appendingPathComponent(endpoint)
            let body = try JSONSerialization.data(withJSONObject: [bodyKey: [entityID]])
            let data = try await request(url: url, method: "POST", body: body)
            guard let result = try decodeListenBrainzPopularity(data).first else {
                return metric(.listenBrainz, entityID, status: .noData)
            }
            let hasData = (result.totalListenCount ?? 0) > 0 || (result.totalUserCount ?? 0) > 0
            return CommunityMusicMetric(
                source: .listenBrainz,
                entityID: entityID,
                listenCount: result.totalListenCount,
                listenerCount: result.totalUserCount,
                fetchedAt: now(),
                status: hasData ? .available : .noData
            )
        } catch {
            return metric(.listenBrainz, entityID, status: status(for: error))
        }
    }

    private func request(
        url: URL,
        musicBrainz: Bool = false,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        if musicBrainz { try await waitForMusicBrainzSlot() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw ExternalMusicServiceError.invalidResponse
            }
            switch http.statusCode {
            case 200..<300: return data
            case 429, 503: throw ExternalMusicServiceError.rateLimited
            default: throw ExternalMusicServiceError.httpStatus(http.statusCode)
            }
        } catch is CancellationError {
            throw ExternalMusicServiceError.cancelled
        } catch let error as ExternalMusicServiceError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ExternalMusicServiceError.timeout
        } catch {
            throw ExternalMusicServiceError.network
        }
    }

    private func waitForMusicBrainzSlot() async throws {
        if let lastMusicBrainzRequestAt {
            let elapsed = now().timeIntervalSince(lastMusicBrainzRequestAt)
            let remaining = musicBrainzMinimumInterval - elapsed
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
        }
        lastMusicBrainzRequestAt = now()
    }

    private func metric(
        _ source: CommunityMusicSource,
        _ entityID: String?,
        status: CommunityMetricStatus
    ) -> CommunityMusicMetric {
        CommunityMusicMetric(source: source, entityID: entityID, fetchedAt: now(), status: status)
    }

    private func status(for error: Error) -> CommunityMetricStatus {
        switch error {
        case ExternalMusicServiceError.rateLimited: .rateLimited
        case ExternalMusicServiceError.httpStatus(404): .noData
        case ExternalMusicServiceError.invalidRequest: .notSupported
        case ExternalMusicServiceError.network, ExternalMusicServiceError.timeout: .unavailable
        default: .failed
        }
    }

    private func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalized(lhs).split(separator: " "))
        let right = Set(normalized(rhs).split(separator: " "))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private func albumSimilarity(_ lhs: String, _ rhs: String) -> Double {
        normalized(lhs) == normalized(rhs) ? 1 : similarity(lhs, rhs)
    }

    private func versionMismatchPenalty(local: String, remote: String) -> Double {
        let markers = ["live", "remaster", "deluxe", "instrumental", "cover", "现场", "重制", "豪华", "纯音乐"]
        let local = normalized(local)
        let remote = normalized(remote)
        return markers.contains { local.contains($0) != remote.contains($0) } ? 0.18 : 0
    }

    /// 多艺术家 credit 用 " & " 连接展示，不再把 ArtistAArtistB 直接拼在一起；
    /// 匹配仍优先按数组逐段比较（见 makeCandidate 的 artistExact）。
    private static func artistCreditString(_ credits: [MBArtistCredit]?) -> String {
        guard let credits, !credits.isEmpty else { return "" }
        return credits.map(\.name).joined(separator: " & ")
    }

    private func lucene(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    private func decodeListenBrainzPopularity(_ data: Data) throws -> [ListenBrainzPopularityEntry] {
        if let entries = try? JSONDecoder().decode([ListenBrainzPopularityEntry].self, from: data) {
            return entries
        }
        if let wrapped = try? JSONDecoder().decode(ListenBrainzPopularityResponse.self, from: data) {
            return wrapped.payload
        }
        throw ExternalMusicServiceError.invalidResponse
    }
}

private struct MBSearchResponse: Decodable {
    let recordings: [MBRecording]
}

private struct MBRecording: Decodable {
    let id: String
    let score: Int?
    let title: String
    let length: Int?
    let isrcs: [String]?
    let artistCredit: [MBArtistCredit]?
    let releases: [MBRelease]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, length, isrcs, releases
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit: Decodable {
    let name: String
    let artist: MBArtist?
}

private struct MBArtist: Decodable { let id: String? }

private struct MBRelease: Decodable {
    let id: String
    let title: String
    let date: String?
    let releaseGroup: MBReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title, date
        case releaseGroup = "release-group"
    }
}

private struct MBReleaseGroup: Decodable {
    let id: String
    let primaryType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case primaryType = "primary-type"
    }
}

private struct MBRecordingLookup: Decodable {
    let title: String?
    let isrcs: [String]?
    let artistCredit: [MBArtistCredit]?
    let releases: [MBRelease]?
    let genres: [MBGenreTag]?
    let tags: [MBGenreTag]?
    let rating: MBRating?

    enum CodingKeys: String, CodingKey {
        case title, isrcs, releases, genres, tags, rating
        case artistCredit = "artist-credit"
    }
}

private struct MBGenreTag: Decodable {
    let name: String
}

private struct MBRating: Decodable {
    let value: Double?
    let votesCount: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case votesCount = "votes-count"
    }
}

private struct ListenBrainzPopularityEntry: Decodable {
    let totalListenCount: Int?
    let totalUserCount: Int?

    enum CodingKeys: String, CodingKey {
        case totalListenCount = "total_listen_count"
        case totalUserCount = "total_user_count"
    }
}

private struct ListenBrainzPopularityResponse: Decodable {
    let payload: [ListenBrainzPopularityEntry]
}
