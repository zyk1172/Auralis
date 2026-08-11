@testable import AppShell
import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

/// MusicEnrichmentService：UI / Agent / 歌词补全三路并发时，同一 GlobalID 只发一轮请求。
@Suite("MusicEnrichment in-flight dedupe")
struct MusicEnrichmentDedupeTests {
    private final class CountingURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static var requests: [URLRequest] = []
        private static let lock = NSLock()

        static var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }
        static func reset() {
            lock.lock()
            requests = []
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requests.append(request)
            let path = request.url?.path ?? ""
            Self.lock.unlock()

            let body: String
            if path.hasSuffix("/recording") {
                body = #"{"recordings":[{"id":"rec-1","score":100,"title":"Exact Song","length":200000,"isrcs":["USAAA0000001"],"artist-credit":[{"name":"Exact Artist","artist":{"id":"artist-1"}}],"releases":[{"id":"release-1","title":"Exact Album","release-group":{"id":"rg-1"}}]}]}"#
            } else if path.contains("/recording/rec-1") {
                body = #"{"rating":{"value":4.5,"votes-count":20}}"#
            } else if path.contains("/review") {
                body = #"{"count":2,"average_rating":{"rating":4.0,"count":3}}"#
            } else if path.contains("/popularity/") {
                body = #"[{"total_listen_count":12345,"total_user_count":456}]"#
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func track() -> Track {
        Track(
            id: "track-1", serverID: "nas", albumID: "album-1", artistID: "artist-local",
            title: "Exact Song", artistName: "Exact Artist", albumTitle: "Exact Album", duration: 200
        )
    }

    @Test("concurrent enrich on the same GlobalID shares one request round")
    func concurrentEnrichSharesOneRound() async throws {
        CountingURLProtocol.reset()
        let store = try makeStore()
        let service = MusicEnrichmentService(catalog: store, session: session())
        let globalID = GlobalID(serverID: "nas", remoteID: "track-1")
        let t = track()

        async let first = service.enrich(track: t, globalID: globalID)
        async let second = service.enrich(track: t, globalID: globalID)
        let (r1, r2) = await (first, second)

        // 完整一轮 = MB search + MB lookup + CritiqueBrainz + ListenBrainz = 4 个请求。
        #expect(CountingURLProtocol.count == 4)
        #expect(r1.identity?.recordingMBID == "rec-1")
        #expect(r2.identity?.recordingMBID == "rec-1")
        #expect(r1.metrics.hasCommunityEvidence)
    }
}
