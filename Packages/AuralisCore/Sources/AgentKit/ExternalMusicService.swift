import Domain
import Foundation
import LocalCatalog

public struct AgentExternalMusicResult: Sendable, Equatable {
    public let identity: ExternalMusicIdentity?
    public let candidates: [ExternalMusicIdentityCandidate]
    public let metrics: CommunityMusicMetrics

    public init(
        identity: ExternalMusicIdentity?,
        candidates: [ExternalMusicIdentityCandidate] = [],
        metrics: CommunityMusicMetrics
    ) {
        self.identity = identity
        self.candidates = candidates
        self.metrics = metrics
    }
}

public protocol AgentExternalMusicService: Sendable {
    /// 只由歌曲鉴赏/歌曲信息显式触发；不得在启动或整库同步时批量调用。
    func enrich(track: Track, globalID: GlobalID) async -> AgentExternalMusicResult
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
    private let cacheAge: TimeInterval

    public init(
        catalog: LocalCatalogStore,
        session: URLSession = .shared,
        endpoints: Endpoints = .init(),
        userAgent: String = "Auralis/1.0.2 (https://github.com/zyk1172/Auralis)",
        musicBrainzMinimumInterval: TimeInterval = 1.05,
        cacheAge: TimeInterval = 14 * 86_400,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.catalog = catalog
        self.session = session
        self.endpoints = endpoints
        self.userAgent = userAgent
        self.musicBrainzMinimumInterval = max(musicBrainzMinimumInterval, 0)
        self.cacheAge = min(max(cacheAge, 7 * 86_400), 30 * 86_400)
        self.now = now
    }

    public func enrich(track: Track, globalID: GlobalID) async -> AgentExternalMusicResult {
        if Task.isCancelled {
            return AgentExternalMusicResult(
                identity: nil,
                metrics: CommunityMusicMetrics(globalTrackID: globalID, values: [])
            )
        }

        let cachedIdentity = try? await catalog.externalMusicIdentity(for: globalID)
        let identity: ExternalMusicIdentity?
        var candidates: [ExternalMusicIdentityCandidate] = []
        // MBID 是稳定外部身份，不因为本地校验时间过期而丢弃；指标有自己的刷新周期。
        if let cachedIdentity, cachedIdentity.recordingMBID != nil {
            identity = cachedIdentity
        } else if let cachedIdentity, let isrc = cachedIdentity.isrc, !isrc.isEmpty {
            let match = await matchByISRC(isrc, globalID: globalID)
            identity = match.identity
            candidates = match.candidates
        } else {
            let match = await match(track: track, globalID: globalID)
            identity = match.identity
            candidates = match.candidates
        }

        if let cached = try? await catalog.communityMusicMetrics(for: globalID),
           isFresh(cached) {
            return AgentExternalMusicResult(identity: identity, candidates: candidates, metrics: cached)
        }

        guard let identity else {
            return AgentExternalMusicResult(
                identity: nil,
                candidates: candidates,
                metrics: CommunityMusicMetrics(globalTrackID: globalID, values: [])
            )
        }

        async let musicBrainz = fetchMusicBrainzMetric(identity: identity)
        async let critiqueBrainz = fetchCritiqueBrainzMetric(identity: identity)
        async let listenBrainz = fetchListenBrainzMetric(identity: identity)
        let metrics = await [musicBrainz, critiqueBrainz, listenBrainz]
        for metric in metrics {
            try? await catalog.upsertCommunityMusicMetric(metric, for: globalID)
        }
        return AgentExternalMusicResult(
            identity: identity,
            candidates: candidates,
            metrics: CommunityMusicMetrics(globalTrackID: globalID, values: metrics)
        )
    }

    private func isFresh(_ metrics: CommunityMusicMetrics) -> Bool {
        guard !metrics.values.isEmpty else { return false }
        let current = now()
        return metrics.values.allSatisfy { metric in
            let allowedAge: TimeInterval = switch metric.status {
            case .available, .noData, .notSupported: cacheAge
            case .rateLimited: 15 * 60
            case .unavailable, .failed: 5 * 60
            }
            return current.timeIntervalSince(metric.fetchedAt) <= allowedAge
        }
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
            let release = recording.releases?.first
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
        let candidateArtist = recording.artistCredit?.map(\.name).joined() ?? ""
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

    private func fetchMusicBrainzMetric(identity: ExternalMusicIdentity) async -> CommunityMusicMetric {
        guard let mbid = identity.recordingMBID else {
            return metric(.musicBrainz, identity.recordingMBID, status: .noData)
        }
        do {
            var components = URLComponents(
                url: endpoints.musicBrainz.appendingPathComponent("recording/\(mbid)"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "inc", value: "ratings+isrcs+artist-credits+releases+release-groups"),
                URLQueryItem(name: "fmt", value: "json"),
            ]
            guard let url = components?.url else { throw ExternalMusicServiceError.invalidRequest }
            let data = try await request(url: url, musicBrainz: true)
            let response = try JSONDecoder().decode(MBRecordingLookup.self, from: data)
            guard let rating = response.rating, (rating.votesCount ?? 0) > 0 else {
                return metric(.musicBrainz, mbid, status: .noData)
            }
            return CommunityMusicMetric(
                source: .musicBrainz,
                entityID: mbid,
                rating: rating.value,
                ratingCount: rating.votesCount,
                fetchedAt: now(),
                status: .available
            )
        } catch {
            return metric(.musicBrainz, mbid, status: status(for: error))
        }
    }

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
                URLQueryItem(name: "limit", value: "0"),
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

    private func fetchListenBrainzMetric(identity: ExternalMusicIdentity) async -> CommunityMusicMetric {
        guard let releaseGroupMBID = identity.releaseGroupMBID else {
            return metric(.listenBrainz, nil, status: .noData)
        }
        do {
            var components = URLComponents(
                url: endpoints.listenBrainz.appendingPathComponent("stats/release-group/\(releaseGroupMBID)/listeners"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "range", value: "all_time")]
            guard let url = components?.url else { throw ExternalMusicServiceError.invalidRequest }
            let data = try await request(url: url)
            let response = try JSONDecoder().decode(ListenBrainzListenersResponse.self, from: data)
            let count = response.payload.totalListenCount
            return CommunityMusicMetric(
                source: .listenBrainz,
                entityID: releaseGroupMBID,
                listenCount: count,
                listenerCount: response.payload.totalListenerCount,
                fetchedAt: now(),
                status: count > 0 ? .available : .noData
            )
        } catch {
            return metric(.listenBrainz, releaseGroupMBID, status: status(for: error))
        }
    }

    private func request(url: URL, musicBrainz: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        if musicBrainz { try await waitForMusicBrainzSlot() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
    let releaseGroup: MBReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title
        case releaseGroup = "release-group"
    }
}

private struct MBReleaseGroup: Decodable { let id: String }

private struct MBRecordingLookup: Decodable {
    let rating: MBRating?
}

private struct MBRating: Decodable {
    let value: Double?
    let votesCount: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case votesCount = "votes-count"
    }
}

private struct ListenBrainzListenersResponse: Decodable {
    let payload: Payload

    struct Payload: Decodable {
        let totalListenCount: Int
        let totalListenerCount: Int?

        enum CodingKeys: String, CodingKey {
            case totalListenCount = "total_listen_count"
            case totalListenerCount = "total_listener_count"
        }
    }
}
