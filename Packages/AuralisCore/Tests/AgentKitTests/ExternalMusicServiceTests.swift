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
        if path.hasSuffix("/recording") {
            body = """
            {"recordings":[{"id":"rec-1","score":100,"title":"Exact Song","length":200000,
            "isrcs":["USAAA0000001"],"artist-credit":[{"name":"Exact Artist","artist":{"id":"artist-1"}}],
            "releases":[{"id":"release-1","title":"Exact Album","release-group":{"id":"rg-1"}}]}]}
            """
        } else if path.contains("/recording/rec-1") {
            body = "{\"rating\":{\"value\":4.5,\"votes-count\":20}}"
        } else if path.contains("/review") {
            body = "{\"count\":2,\"average_rating\":{\"rating\":4.0,\"count\":3}}"
        } else if path.contains("/listeners") {
            body = "{\"payload\":{\"total_listen_count\":12345,\"total_listener_count\":456}}"
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

@Suite("按需外部音乐数据")
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
            musicBrainzMinimumInterval: 0
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
            musicBrainzMinimumInterval: 0
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
}
