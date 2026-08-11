import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

private final class ExternalMusicURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // All access is serialized by `lock`; Swift cannot infer that guarantee for
    // mutable static test fixtures, so opt out of the redundant global check.
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var statusCode = 200

    static func reset(statusCode: Int = 200) {
        lock.lock()
        requests = []
        self.statusCode = statusCode
        lock.unlock()
    }

    static var captured: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.statusCode
        Self.lock.unlock()

        let body: String
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        if path.hasSuffix("/recording") {
            if query.contains("Multi") {
                // 多艺术家：credit 是两个独立 artist。
                body = """
                {"recordings":[{"id":"rec-multi","score":100,"title":"Multi Artist Song","length":200000,
                "artist-credit":[{"name":"ArtistA","artist":{"id":"a1"}},{"name":"ArtistB","artist":{"id":"a2"}}],
                "releases":[{"id":"release-multi","title":"Exact Album","release-group":{"id":"rg-multi"}}]}]}
                """
            } else if query.contains("isrc:TEST") {
                // ISRC 命中多 release：release-wrong 专辑名不匹配，release-right 匹配。
                body = """
                {"recordings":[{"id":"rec-isrc","score":100,"title":"ISRC Song","length":200000,
                "isrcs":["TEST1234"],"artist-credit":[{"name":"Exact Artist","artist":{"id":"artist-1"}}],
                "releases":[
                  {"id":"release-wrong","title":"Other Album","release-group":{"id":"rg-wrong"}},
                  {"id":"release-right","title":"Exact Album","release-group":{"id":"rg-right"}}
                ]}]}
                """
            } else {
                body = """
                {"recordings":[{"id":"rec-1","score":100,"title":"Exact Song","length":200000,
                "isrcs":["USAAA0000001"],"artist-credit":[{"name":"Exact Artist","artist":{"id":"artist-1"}}],
                "releases":[{"id":"release-1","title":"Exact Album","release-group":{"id":"rg-1"}}]}]}
                """
            }
        } else if path.contains("/recording/rec-multi") {
            body = """
            {"rating":{"value":4.5,"votes-count":7},"title":"Multi Artist Song",
            "artist-credit":[{"name":"ArtistA","artist":{"id":"a1"}},{"name":"ArtistB","artist":{"id":"a2"}}],
            "genres":[{"name":"Jazz"}],"tags":[{"name":"piano"}]}
            """
        } else if path.contains("/recording/rec-1") {
            body = "{\"rating\":{\"value\":4.5,\"votes-count\":20}}"
        } else if path.contains("/review") {
            body = """
            {"count":2,"average_rating":{"rating":4.0,"count":3},"reviews":[
              {"id":"rev-1","user":{"display_name":"Critic One"},"rating":4.5,
               "created":"2024-01-01T00:00:00Z","language":"en","text":"A thoughtful review about the album.",
               "license":"CC BY-SA 3.0","source":"CritiqueBrainz","source_url":"https://critiquebrainz.org/review/rev-1"},
              {"id":"rev-2","user":{"name":"Anonymous"},"rating":3.0,"language":"zh",
               "text":"A shorter review.","source":"Manual"}
            ]}
            """
        } else if path.contains("/popularity/") {
            body = "[{\"total_listen_count\":12345,\"total_user_count\":456}]"
        } else {
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func externalMusicTestStore() throws -> LocalCatalogStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExternalMusicServiceTests.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
}

private func externalMusicSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExternalMusicURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func externalMusicTrack(title: String = "Exact Song") -> Track {
    Track(
        id: "track-1", serverID: "nas", albumID: "album-1", artistID: "artist-local",
        title: title, artistName: "Exact Artist", albumTitle: "Exact Album", duration: 200
    )
}

/// Foundation may bridge a URLRequest body into `httpBodyStream` before a
/// custom URLProtocol sees it. Read either representation so the test verifies
/// the actual JSON sent over the wire instead of depending on that bridge.
private func externalMusicRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw ExternalMusicServiceError.invalidRequest
    }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count == 0 { break }
        guard count > 0 else { throw ExternalMusicServiceError.invalidRequest }
        body.append(buffer, count: count)
    }
    return body
}

@Suite("按需外部音乐数据", .serialized)
struct ExternalMusicServiceTests {
    @Test("高置信度匹配绑定身份并分别缓存三个来源")
    func highConfidenceMatchAndMetricCache() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let endpoints = MusicBrainzExternalMusicService.Endpoints(
            musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
            critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
            listenBrainz: URL(string: "https://listenbrainz.test/1")!
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: endpoints,
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences() },
            now: { fixedNow }
        )
        let globalID = GlobalID(serverID: "nas", remoteID: "track-1")

        let first = await service.enrich(track: externalMusicTrack(), globalID: globalID)
        let requestCountAfterFirst = ExternalMusicURLProtocol.captured.count
        let second = await service.enrich(track: externalMusicTrack(), globalID: globalID)

        #expect(first.identity?.recordingMBID == "rec-1")
        #expect(first.identity?.releaseGroupMBID == "rg-1")
        #expect(first.identity?.matchConfidence == 1)
        #expect(first.metrics.value(for: .musicBrainz)?.ratingCount == 20)
        #expect(first.metrics.value(for: .critiqueBrainz)?.reviewCount == 2)
        #expect(first.metrics.value(for: .listenBrainz)?.listenCount == 12_345)
        #expect(first.metrics.value(for: .listenBrainz)?.listenerCount == 456)
        #expect(first.metrics.hasCommunityEvidence)
        #expect(requestCountAfterFirst == 4)
        #expect(ExternalMusicURLProtocol.captured.count == requestCountAfterFirst,
                "第二次应命中 SQLite 14 天缓存，不再发外部请求")
        #expect(second == first)
        #expect(ExternalMusicURLProtocol.captured.allSatisfy {
            $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Auralis/") == true
        })
        let popularity = ExternalMusicURLProtocol.captured.first { $0.url?.path.contains("/popularity/") == true }
        #expect(popularity?.httpMethod == "POST")
        let popularityBody = try externalMusicRequestBody(try #require(popularity))
        let popularityJSON = try #require(
            try JSONSerialization.jsonObject(with: popularityBody) as? [String: [String]]
        )
        #expect(popularityJSON["release_group_mbids"] == ["rg-1"])
    }

    @Test("中等置信度只保存候选不自动绑定")
    func mediumConfidenceStaysCandidate() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: .init(
                musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
                critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
                listenBrainz: URL(string: "https://listenbrainz.test/1")!
            ),
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences() }
        )
        let globalID = GlobalID(serverID: "nas", remoteID: "ambiguous")

        let result = await service.enrich(
            track: externalMusicTrack(title: "Exact Song Remix"),
            globalID: globalID
        )

        #expect(result.identity == nil)
        #expect(!result.candidates.isEmpty)
        #expect(result.candidates[0].confidence >= 0.65)
        #expect(result.candidates[0].confidence < 0.90)
        #expect(try await store.externalMusicIdentity(for: globalID) == nil)
    }

    @Test("已有 ISRC 优先于文本匹配并补齐稳定身份")
    func existingISRCPrecedesMetadataSearch() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "isrc-track")
        try await store.upsertExternalMusicIdentity(
            ExternalMusicIdentity(
                globalTrackID: globalID,
                isrc: "USAAA0000001",
                matchConfidence: 1,
                matchMethod: .isrc
            )
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: .init(
                musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
                critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
                listenBrainz: URL(string: "https://listenbrainz.test/1")!
            ),
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences() }
        )

        let result = await service.enrich(
            track: externalMusicTrack(title: "本地标题可以不同"),
            globalID: globalID
        )

        #expect(result.identity?.recordingMBID == "rec-1")
        #expect(result.identity?.matchMethod == .isrc)
        let firstURL = ExternalMusicURLProtocol.captured.first?.url?.absoluteString ?? ""
        #expect(firstURL.contains("isrc"))
        #expect(!firstURL.contains("recording%3A"))
    }

    @Test("总开关关闭时返回 disabled 且零网络请求")
    func masterSwitchOffMakesZeroRequests() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: .init(
                musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
                critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
                listenBrainz: URL(string: "https://listenbrainz.test/1")!
            ),
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences(enabled: false) }
        )

        let result = await service.enrich(
            track: externalMusicTrack(),
            globalID: GlobalID(serverID: "nas", remoteID: "disabled")
        )

        #expect(ExternalMusicURLProtocol.captured.isEmpty)
        #expect(result.metrics.values.count == CommunityMusicSource.allCases.count)
        #expect(result.metrics.values.allSatisfy { $0.status == .disabled })
    }

    @Test("单独启用 ListenBrainz 只访问 popularity release-group")
    func perSourceGateAndReleaseGroupPOST() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "listen-only")
        try await store.upsertExternalMusicIdentity(ExternalMusicIdentity(
            globalTrackID: globalID,
            recordingMBID: "rec-1",
            releaseGroupMBID: "rg-1",
            matchConfidence: 1,
            matchMethod: .embeddedRecordingMBID
        ))
        let preferences = ExternalMusicPreferences(
            musicBrainzEnabled: false,
            critiqueBrainzEnabled: false,
            listenBrainzEnabled: true
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: .init(
                musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
                critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
                listenBrainz: URL(string: "https://listenbrainz.test/1")!
            ),
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { preferences }
        )

        let result = await service.enrich(track: externalMusicTrack(), globalID: globalID)
        let request = try #require(ExternalMusicURLProtocol.captured.only)
        let body = try externalMusicRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: [String]])

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/1/popularity/release-group")
        #expect(json["release_group_mbids"] == ["rg-1"])
        #expect(result.metrics.value(for: .musicBrainz)?.status == .disabled)
        #expect(result.metrics.value(for: .critiqueBrainz)?.status == .disabled)
        #expect(result.metrics.value(for: .listenBrainz)?.listenerCount == 456)
    }

    @Test("缺少 release-group 时回退 recording popularity")
    func recordingPopularityFallback() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "recording-fallback")
        try await store.upsertExternalMusicIdentity(ExternalMusicIdentity(
            globalTrackID: globalID,
            recordingMBID: "rec-1",
            matchConfidence: 1,
            matchMethod: .embeddedRecordingMBID
        ))
        let preferences = ExternalMusicPreferences(
            musicBrainzEnabled: false,
            critiqueBrainzEnabled: false,
            listenBrainzEnabled: true
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: .init(
                musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
                critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
                listenBrainz: URL(string: "https://listenbrainz.test/1")!
            ),
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { preferences }
        )

        _ = await service.enrich(track: externalMusicTrack(), globalID: globalID)
        let request = try #require(ExternalMusicURLProtocol.captured.only)
        let body = try externalMusicRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: [String]])
        #expect(request.url?.path == "/1/popularity/recording")
        #expect(json["recording_mbids"] == ["rec-1"])
    }

    @Test("clearCache 清除身份候选和指标")
    func clearCacheRemovesAllDerivedExternalData() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "cached")
        try await store.upsertExternalMusicIdentity(ExternalMusicIdentity(
            globalTrackID: globalID, recordingMBID: "rec-1", matchConfidence: 1,
            matchMethod: .embeddedRecordingMBID
        ))
        try await store.upsertCommunityMusicMetric(
            CommunityMusicMetric(source: .listenBrainz, listenCount: 1, status: .available),
            for: globalID
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            preferencesProvider: { ExternalMusicPreferences(enabled: false) }
        )

        try await service.clearCache()

        // 普通清缓存保留高置信度 Stable Identity；只清指标与候选。
        #expect(try await store.externalMusicIdentity(for: globalID)?.recordingMBID == "rec-1")
        #expect(try await store.communityMusicMetrics(for: globalID).values.isEmpty)
        #expect(ExternalMusicURLProtocol.captured.isEmpty)
    }

    @Test("多艺术家 credit 用 & 连接，不拼成 ArtistAArtistB")
    func multiArtistCreditJoined() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let endpoints = MusicBrainzExternalMusicService.Endpoints(
            musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
            critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
            listenBrainz: URL(string: "https://listenbrainz.test/1")!
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: endpoints,
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences() }
        )
        let globalID = GlobalID(serverID: "nas", remoteID: "multi-1")
        let track = Track(
            id: "multi-1", serverID: "nas", albumID: "album-multi", artistID: "artist-local",
            title: "Multi Artist Song", artistName: "ArtistA & ArtistB", albumTitle: "Exact Album", duration: 200
        )
        let result = await service.enrich(track: track, globalID: globalID)
        #expect(result.identity?.recordingMBID == "rec-multi")
        // 详情里的 artistCredit 是 " & " 连接，不是 ArtistAArtistB。
        #expect(result.evidence?.musicBrainz?.artistCredit == "ArtistA & ArtistB")
        // 真实字段：流派 / 标签。
        #expect(result.evidence?.musicBrainz?.genres == ["Jazz"])
        #expect(result.evidence?.musicBrainz?.tags == ["piano"])
    }

    @Test("ISRC 命中多 release 时按专辑匹配选择，不取 releases.first")
    func isrcChoosesBestRelease() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "isrc-1")
        // 预置只有 ISRC、无 recordingMBID 的身份：触发 matchByISRC。
        try await store.upsertExternalMusicIdentity(ExternalMusicIdentity(
            globalTrackID: globalID, isrc: "TEST1234",
            matchConfidence: 1, matchMethod: .isrc
        ))
        let endpoints = MusicBrainzExternalMusicService.Endpoints(
            musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
            critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
            listenBrainz: URL(string: "https://listenbrainz.test/1")!
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: endpoints,
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences() }
        )
        let track = Track(
            id: "isrc-1", serverID: "nas", albumID: "album-isrc", artistID: "artist-local",
            title: "ISRC Song", artistName: "Exact Artist", albumTitle: "Exact Album", duration: 200
        )
        let result = await service.enrich(track: track, globalID: globalID)
        // 选择与本地专辑匹配的 release-right，而不是 releases.first（release-wrong）。
        #expect(result.identity?.releaseMBID == "release-right")
        #expect(result.identity?.releaseGroupMBID == "rg-right")
    }

    @Test("CritiqueBrainz 评论保存 license/source/sourceURL，无评论=noData")
    func critiqueBrainzReviewsSavedWithLicense() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let endpoints = MusicBrainzExternalMusicService.Endpoints(
            musicBrainz: URL(string: "https://musicbrainz.test/ws/2")!,
            critiqueBrainz: URL(string: "https://critiquebrainz.test/ws/1")!,
            listenBrainz: URL(string: "https://listenbrainz.test/1")!
        )
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            endpoints: endpoints,
            musicBrainzMinimumInterval: 0,
            preferencesProvider: { ExternalMusicPreferences() }
        )
        let globalID = GlobalID(serverID: "nas", remoteID: "track-1")
        let result = await service.enrich(track: externalMusicTrack(), globalID: globalID)

        let reviews = result.evidence?.reviews ?? []
        #expect(reviews.count == 2)
        let first = try #require(reviews.first { $0.reviewID == "rev-1" })
        #expect(first.authorName == "Critic One")
        #expect(first.rating == 4.5)
        #expect(first.licenseID == "CC BY-SA 3.0")
        #expect(first.sourceName == "CritiqueBrainz")
        #expect(first.sourceURL == "https://critiquebrainz.org/review/rev-1")
        #expect(first.excerpt.contains("thoughtful"))
        // excerpt 超长会截断（长度限制）。
        #expect(first.excerpt.count <= 281)

        // 持久化到 SQLite。
        let stored = try await store.communityMusicReviews(for: globalID)
        #expect(stored.count == 2)
        #expect(stored.contains { $0.licenseID == "CC BY-SA 3.0" })
    }

    @Test("resetIdentity 连 Stable Identity 一起清空")
    func resetIdentityClearsStableIdentity() async throws {
        ExternalMusicURLProtocol.reset()
        let store = try externalMusicTestStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "identity")
        try await store.upsertExternalMusicIdentity(ExternalMusicIdentity(
            globalTrackID: globalID, recordingMBID: "rec-1", matchConfidence: 1,
            matchMethod: .embeddedRecordingMBID
        ))
        let service = MusicBrainzExternalMusicService(
            catalog: store,
            session: externalMusicSession(),
            preferencesProvider: { ExternalMusicPreferences(enabled: false) }
        )
        try await service.resetIdentity()
        #expect(try await store.externalMusicIdentity(for: globalID) == nil)
        #expect(ExternalMusicURLProtocol.captured.isEmpty)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
