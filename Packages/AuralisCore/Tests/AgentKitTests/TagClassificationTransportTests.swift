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
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    bytes.append(buffer, count: count)
                }
                stream.close()
                captured.httpBodyStream = nil; captured.httpBody = bytes
            }
            entry.requests.append(captured)
            let reply = entry.replies.isEmpty ? nil : entry.replies.removeFirst()
            Self.registry.entries[host] = entry
            return reply
        }
        // A nil reply deliberately leaves the connection open until the runner cancels it.
        guard let reply else { return }
        let isStream = reply.starts(with: Data("data:".utf8)) || reply.starts(with: Data("event:".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.registry.lock.withLock { Self.registry.entries[request.url!.host!]?.cancellations += 1 }
    }
}

enum ClassificationHTTPProtocol: String, CaseIterable, Sendable {
    case chat, responses, messages
    var path: String {
        switch self {
        case .chat: "/v1/chat/completions"
        case .responses: "/v1/responses"
        case .messages: "/v1/messages"
        }
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

    private func response(wire: ClassificationHTTPProtocol = .chat, streaming: Bool = false) throws -> Data {
        let classification = """
        {"items":[{"id":"server:0","tags":["scene.study","instrument.piano"],"confidence":0.9}]}
        """
        if streaming {
            func event(_ object: [String: Any]) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: object)
                let prefix = wire == .messages ? "event: \(object["type"] as! String)\n" : ""
                return prefix + "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
            }
            let events: [[String: Any]]
            switch wire {
            case .chat:
                events = [["choices": [["delta": ["content": classification]]]],
                    ["choices": [["delta": [:], "finish_reason": "stop"]]]]
            case .responses:
                events = [["type": "response.output_text.delta", "delta": classification],
                    ["type": "response.completed", "response": ["model": "http-model", "status": "completed"]]]
            case .messages:
                events = [["type": "message_start", "message": ["id": "message-test", "model": "http-model", "usage": ["input_tokens": 1]]],
                    ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                    ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": classification]],
                    ["type": "content_block_stop", "index": 0],
                    ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 32]],
                    ["type": "message_stop"]]
            }
            return Data(try events.map(event).joined().utf8)
        }
        if wire == .responses {
            return try JSONSerialization.data(withJSONObject: ["id": "resp-classification", "model": "http-model", "status": "completed", "output": [[
                "type": "message", "role": "assistant", "content": [["type": "output_text", "text": classification]],
            ]]])
        }
        if wire == .messages {
            return try JSONSerialization.data(withJSONObject: ["id": "message-test", "model": "http-model", "stop_reason": "end_turn",
                "content": [["type": "text", "text": classification]]])
        }
        return try JSONSerialization.data(withJSONObject: ["model": "http-model", "choices": [[
            "message": ["role": "assistant", "content": classification], "finish_reason": "stop",
        ]]])
    }

    private func makeProvider(host: String, wire: ClassificationHTTPProtocol = .chat, streaming: Bool = false) -> (any AIProvider, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClassificationURLProtocol.self]
        let session = URLSession(configuration: config)
        let configuration = AIProviderConfiguration(name: "classification-http-test",
            baseURL: URL(string: "https://\(host)")!, apiPath: wire.path, model: "http-model",
            usesStreaming: streaming, supportsReasoningControl: true)
        let provider: any AIProvider
        if wire == .messages {
            provider = AnthropicMessagesProvider(configuration: configuration, credentialVault: InMemoryCredentialVault(), session: session)
        } else {
            provider = OpenAICompatibleProvider(configuration: configuration, credentialVault: InMemoryCredentialVault(), session: session)
        }
        return (provider, session)
    }

    @Test("All three configured protocols classify via streaming and ordinary HTTP", arguments: ClassificationHTTPProtocol.allCases, [false, true])
    func realHTTPPipeline(wire: ClassificationHTTPProtocol, streaming: Bool) async throws {
        let (store, directory) = try await fixture()
        let host = "\(UUID().uuidString.lowercased()).example"
        ClassificationURLProtocol.register(host: host, replies: [try response(wire: wire, streaming: streaming)])
        let (provider, session) = makeProvider(host: host, wire: wire, streaming: streaming)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model",
            reasoning: .init(mode: .disabled)).run(serverID: "server")
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 1)
        #expect(try await store.recommendByTags(serverIDs: ["server"], query: .init(includeTags: ["scene.study", "instrument.piano"])).count == 1)
        let requests = ClassificationURLProtocol.captured(host: host).requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == wire.path)
        let body = try #require(requests.first?.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        switch wire {
        case .chat: #expect(object["reasoning_effort"] as? String == "none")
        case .responses: #expect((object["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        case .messages: #expect((object["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        }
    }

    @Test("A gateway that never returns is cancelled without silently retrying forever", arguments: [false, true])
    func stalledFirstRequest(streaming: Bool) async throws {
        let (store, directory) = try await fixture()
        let host = "\(UUID().uuidString.lowercased()).example"
        ClassificationURLProtocol.register(host: host, replies: [nil])
        let (provider, session) = makeProvider(host: host, streaming: streaming)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: TagClassificationTimeout.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model", requestTimeout: .seconds(1)).run(serverID: "server")
        }
        let captured = ClassificationURLProtocol.captured(host: host)
        #expect(captured.requests.count == 1)
        #expect(captured.cancellations == 1)
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 0)
    }

    @Test("The first song stays committed when the next request stalls", arguments: [false, true])
    func firstSaveSurvivesStall(streaming: Bool) async throws {
        let (store, directory) = try await fixture(count: 3)
        let host = "\(UUID().uuidString.lowercased()).example"
        ClassificationURLProtocol.register(host: host, replies: [try response(streaming: streaming), nil])
        let (provider, session) = makeProvider(host: host, streaming: streaming)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: TagClassificationTimeout.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model", requestTimeout: .seconds(1)).run(serverID: "server")
        }
        #expect(ClassificationURLProtocol.captured(host: host).requests.count == 2)
        let status = try await store.recommendationIndexStatus(serverID: "server")
        #expect(status.indexedTracks == 1)
        #expect(status.pendingTracks == 2)
    }

    @Test("Valid JSON without a stream completion signal cannot mark a song as classified")
    func interruptedStream() async throws {
        let (store, directory) = try await fixture()
        let host = "\(UUID().uuidString.lowercased()).example"
        let complete = String(decoding: try response(streaming: true), as: UTF8.self)
        let incomplete = Data((complete.components(separatedBy: "\n\n")[0] + "\n\n").utf8)
        ClassificationURLProtocol.register(host: host, replies: [incomplete, incomplete])
        let (provider, session) = makeProvider(host: host, streaming: true)
        defer { session.invalidateAndCancel(); ClassificationURLProtocol.remove(host: host); try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: TagClassificationFailure.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "http-model").run(serverID: "server")
        }
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 0)
        #expect(ClassificationURLProtocol.captured(host: host).requests.count == 2)
    }
}
