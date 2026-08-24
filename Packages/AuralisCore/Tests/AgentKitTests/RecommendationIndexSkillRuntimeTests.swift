import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

private final class ClosedIndexProvider: AIProvider, @unchecked Sendable {
    enum FirstResponse { case valid, malformed }

    private let lock = NSLock()
    private var firstResponse: FirstResponse
    private var didRespond = false
    private var recorded: [AICompletionRequest] = []

    let capabilities = ModelCapabilities(
        maxContextTokens: 32_000,
        maxOutputTokens: 4_096,
        supportsToolCalling: true,
        supportsParallelTools: true,
        supportsToolChoice: true,
        supportsStrictSchema: true,
        supportsStreaming: true,
        supportsJSONMode: true,
        supportsJSONSchema: true,
        toolMode: .openAIChat
    )

    var supportsToolCalling: Bool { true }

    init(firstResponse: FirstResponse = .valid) {
        self.firstResponse = firstResponse
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "closed-index", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async -> AICompletionResponse {
        let shouldReturnMalformed = lock.withLock {
            recorded.append(request)
            let value = !didRespond && firstResponse == .malformed
            didRespond = true
            return value
        }
        if shouldReturnMalformed {
            return AICompletionResponse(model: request.model, content: #"{"batchID":"truncated""#)
        }
        return AICompletionResponse(model: request.model, content: Self.envelope(for: request))
    }

    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func requests() -> [AICompletionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private static func envelope(for request: AICompletionRequest) -> String {
        guard let payload = request.messages.last?.content.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let batchID = input["batchID"] as? String,
              let revision = input["revision"] as? NSNumber,
              let mode = input["mode"] as? String,
              let tracks = input["tracks"] as? [[String: Any]] else {
            return "{}"
        }
        let items: [[String: Any]] = tracks.compactMap { track in
            guard let id = track["id"] as? String else { return nil }
            return [
                "id": id,
                "mode": mode,
                "moods": ["平静"],
                "scenes": ["深夜"],
                "energy": 3,
                "tempo": 2,
                "acousticness": 4,
                "danceability": 2,
                "vocals": ["器乐"],
                "textures": ["钢琴"],
                "styles": ["轻音乐"],
                "semanticTags": [["value": "夜行感", "confidence": 0.8]],
                "confidence": 0.9,
            ]
        }
        let object: [String: Any] = [
            "batchID": batchID,
            "revision": revision,
            "mode": mode,
            "items": items,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ClosedIndexMessages {
    private var values: [String] = []

    func append(_ message: AgentChatMessage) {
        values += message.messages.compactMap {
            switch $0 {
            case let .text(value), let .error(value), let .toolProgress(step: value), let .streaming(value): value
            default: nil
            }
        }
    }

    func contains(_ needle: String) -> Bool {
        values.contains { $0.contains(needle) }
    }
}

private func closedIndexStore(trackCount: Int) async throws -> (LocalCatalogStore, ServerID) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
    let serverID: ServerID = "closed-index-server"
    let tracks = (0..<trackCount).map { index in
        Track(
            id: TrackID(rawValue: "track-\(index)"),
            serverID: serverID,
            albumID: AlbumID(rawValue: "album-\(index)"),
            artistID: ArtistID(rawValue: "artist-\(index)"),
            title: "Track \(index)",
            artistName: "Artist",
            albumTitle: "Album",
            duration: 180
        )
    }
    let sync = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: sync)
    try await store.completeSync(sync, completedAt: .now)
    return (store, serverID)
}

@Test("Recommendation Index classification is a closed no-tool transform and Runtime commits")
func recommendationIndexClosedTransformCommits() async throws {
    let (store, serverID) = try await closedIndexStore(trackCount: 3)
    let provider = ClosedIndexProvider()
    let messages = ClosedIndexMessages()
    let runID = UUID()
    let lineage = ExecutionLineage.newRequest(text: "构建完整推荐索引")
    let lease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)

    await ConversationEngine().run(
        userText: "构建完整推荐索引",
        provider: provider,
        model: "closed-index",
        bridge: MockAgentBridge(activeServerID: serverID),
        catalog: store,
        context: .init(serverID: serverID),
        intent: .libraryManagement,
        policy: .policy(for: .libraryManagement),
        executionLineage: lineage,
        runID: runID,
        executionLease: lease,
        confirm: { _ in true },
        emit: { await messages.append($0) }
    )

    let status = try await store.recommendationIndexStatus(serverID: serverID)
    #expect(status.pendingUniqueTracks == 0)
    #expect(await messages.contains("推荐索引已完成"))
    #expect(!(await messages.contains("只返回完整 JSON")))
    let requests = provider.requests()
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.tools?.isEmpty == true })
    #expect(requests.allSatisfy { $0.hostedTools?.isEmpty == true })
    #expect(requests.allSatisfy { $0.toolChoice == nil })
    #expect(requests.allSatisfy {
        if case .jsonSchema = $0.outputFormat { return true }
        return false
    })
}

@Test("Malformed classification performs no stale commit and receives a new batch revision")
func recommendationIndexMalformedOutputChangesBatchIdentity() async throws {
    let (store, serverID) = try await closedIndexStore(trackCount: 9)
    let provider = ClosedIndexProvider(firstResponse: .malformed)
    let runID = UUID()
    let lease = ToolExecutionLease(runID: runID, sessionID: UUID(), generation: 1)

    await ConversationEngine().run(
        userText: "构建完整推荐索引",
        provider: provider,
        model: "closed-index",
        bridge: MockAgentBridge(activeServerID: serverID),
        catalog: store,
        context: .init(serverID: serverID),
        intent: .libraryManagement,
        policy: .policy(for: .libraryManagement),
        executionLineage: .newRequest(text: "构建完整推荐索引"),
        runID: runID,
        executionLease: lease,
        confirm: { _ in true },
        emit: { _ in }
    )

    let requests = provider.requests()
    #expect(requests.count >= 3)
    let first = try #require(requests[0].messages.last?.content.data(using: .utf8))
    let second = try #require(requests[1].messages.last?.content.data(using: .utf8))
    let firstJSON = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
    let secondJSON = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
    #expect(firstJSON["batchID"] as? String != secondJSON["batchID"] as? String)
    #expect((firstJSON["revision"] as? NSNumber)?.uint64Value != (secondJSON["revision"] as? NSNumber)?.uint64Value)
    #expect(try await store.recommendationIndexStatus(serverID: serverID).pendingUniqueTracks == 0)
}

@Test("Stale Recommendation Index envelope is rejected by batch identity")
func recommendationIndexRejectsStaleEnvelope() throws {
    let track = CatalogTrackLine(
        id: "server:track",
        title: "Track",
        artist: "Artist",
        album: "Album",
        year: nil,
        genres: [],
        language: nil,
        duration: 180,
        isFavorite: false,
        rating: nil,
        playCount: 0,
        isDownloaded: false
    )
    let current = RecommendationIndexPreparedBatch(
        batchID: UUID(),
        revision: 2,
        checkpointGeneration: 4,
        mode: "full",
        tracks: [track],
        pendingFixed: 1,
        pendingSemantic: 1
    )
    let stale = RecommendationIndexClassificationEnvelope(
        batchID: UUID(),
        revision: 1,
        mode: "full",
        items: [.init(id: track.id, mode: "full")]
    )
    #expect(throws: RecommendationIndexValidationError.staleBatch) {
        try RecommendationIndexSkillRuntime.validate(stale, for: current)
    }
}

@Test("Old Recommendation Index checkpoint decodes with fail-closed generation defaults")
func oldRecommendationIndexCheckpointMigrates() throws {
    let old = #"{"total":20,"indexed":8,"pending":12,"pendingSemantic":12,"totalWrittenThisRun":8,"lastSuccessfulBatchCount":8,"currentBatchIDs":["s:1"],"currentBatchMode":"full","preferredBatchSize":8,"status":"classifyingBatch","updatedAt":0}"#
    let checkpoint = try JSONDecoder().decode(RecommendationIndexCheckpoint.self, from: Data(old.utf8))
    #expect(checkpoint.checkpointGeneration == 0)
    #expect(checkpoint.currentBatchID == nil)
    #expect(checkpoint.currentBatchRevision == nil)
    #expect(checkpoint.currentBatchIDs == ["s:1"])
}
