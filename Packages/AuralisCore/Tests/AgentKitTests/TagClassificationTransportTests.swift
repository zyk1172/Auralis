// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import SecurityKit
import Testing

/// Runs the production HTTP codec and cancellation path, rather than returning a fake completion.
private final class ClassificationURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Entry {
        var replies: [Data?]
        var requests: [URLRequest] = []
        var cancellations = 0
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Entry] = [:]
    }
    private static let registry = Registry()

    static func register(host: String, replies: [Data?]) {
        registry.lock.withLock { registry.entries[host] = Entry(replies: replies) }
    }
    static func captured(host: String) -> (requests: [URLRequest], cancellations: Int) {
        registry.lock.withLock {
            let entry = registry.entries[host]!
            return (entry.requests, entry.cancellations)
        }
    }
    static func remove(host: String) { _ = registry.lock.withLock { registry.entries.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Data? = Self.registry.lock.withLock {
            let host = request.url!.host!
            var entry = Self.registry.entries[host]!
            entry.requests.append(request)
            let reply = entry.replies.isEmpty ? nil : entry.replies.removeFirst()
            Self.registry.entries[host] = entry
            return reply
        }
        // A nil reply deliberately leaves the connection open until the runner cancels it.
        guard let reply else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.registry.lock.withLock { Self.registry.entries[request.url!.host!]?.cancellations += 1 }
    }
}

@Suite("Background classification HTTP and stalled gateways")
struct TagClassificationTransportTests {
    private func fixture(count: Int = 1) async throws -> (LocalCatalogStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let tracks = (0..<count).map { index in
            Track(id: TrackID(rawValue: "\(index)"), serverID: "server", albumID: "album", artistID: "artist",
                title: "Song \(index)", artistName: "Artist", albumTitle: "Album", duration: 180)
        }
        let sync = try await store.beginSync(serverID: "server", mode: .full)
        try await store.stageTracks(tracks, session: sync)
        try await store.completeSync(sync, completedAt: .now)
        return (store, directory)
    }

    private func response(responses: Bool = false) throws -> Data {
        let classification = """
        {"items":[{"id":"server:0","tags":["scene.study","instrument.piano"],"confidence":0.9}]}
        """
        if responses {
            return try JSONSerialization.data(withJSONObject: ["id": "resp-classification", "model": "http-model", "status": "completed", "output": [[
                "type": "message", "role": "assistant", "content": [["type": "output_text", "text": classification]],
            ]]])
        }
        return try JSONSerialization.data(withJSONObject: ["model": "http-model", "choices": [[
            "message": ["role": "assistant", "content": classification], "finish_reason": "stop",
        ]]])
    }

    private func makeProvider(host: String, responses: Bool = false) -> (OpenAICompatibleProvider, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClassificationURLProtocol.self]
        let session = URLSession(configuration: config)
        let provider = OpenAICompatibleProvider(configuration: .init(name: "classification-http-test",
            baseURL: URL(string: "https://\(host)")!, apiPath: responses ? "/v1/responses" : "/v1/chat/completions", model: "http-model",
            supportsReasoningControl: responses),
            credentialVault: InMemoryCredentialVault(), session: session)
        return (provider, session)
    }

    @Test("Production Chat/Responses HTTP responses persist labels and support an AND query", arguments: [false, true])
    func realHTTPPipeline(responses: Bool) async throws {
        let (store, directory) = try await fixture()
        let host = "\(UUID().uuidString.lowercased()).example"
        ClassificationURLProtocol.register(host: host, replies: [try response(responses: responses)])
        let (provider, session) = makeProvider(host: host, responses: responses)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model").run(serverID: "server")
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 1)
        #expect(try await store.recommendByTags(serverIDs: ["server"], query: .init(includeTags: ["scene.study", "instrument.piano"])).count == 1)
        let requests = ClassificationURLProtocol.captured(host: host).requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == (responses ? "/v1/responses" : "/v1/chat/completions"))
    }

    @Test("A gateway that never returns is cancelled without silently retrying forever")
    func stalledFirstRequest() async throws {
        let (store, directory) = try await fixture()
        let host = "\(UUID().uuidString.lowercased()).example"
        ClassificationURLProtocol.register(host: host, replies: [nil])
        let (provider, session) = makeProvider(host: host)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: TagClassificationTimeout.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model", requestTimeout: .seconds(1)).run(serverID: "server")
        }
        let captured = ClassificationURLProtocol.captured(host: host)
        #expect(captured.requests.count == 1)
        #expect(captured.cancellations == 1)
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 0)
    }

    @Test("The first song stays committed when the next request stalls")
    func firstSaveSurvivesStall() async throws {
        let (store, directory) = try await fixture(count: 3)
        let host = "\(UUID().uuidString.lowercased()).example"
        ClassificationURLProtocol.register(host: host, replies: [try response(), nil])
        let (provider, session) = makeProvider(host: host)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: TagClassificationTimeout.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model", requestTimeout: .seconds(1)).run(serverID: "server")
        }
        #expect(ClassificationURLProtocol.captured(host: host).requests.count == 2)
        let status = try await store.recommendationIndexStatus(serverID: "server")
        #expect(status.indexedTracks == 1)
        #expect(status.pendingTracks == 2)
    }
}
