import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

private actor IndexExecutionGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class ClosedIndexProvider: AIProvider, @unchecked Sendable {
    enum FirstResponse: Equatable { case valid, malformed, transientFailures(Int) }

    private let lock = NSLock()
    private var firstResponse: FirstResponse
    private var didRespond = false
    private var remainingTransientFailures: Int
    private var recorded: [AICompletionRequest] = []
    private let gate: IndexExecutionGate?

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

    init(firstResponse: FirstResponse = .valid, gate: IndexExecutionGate? = nil) {
        self.firstResponse = firstResponse
        if case let .transientFailures(count) = firstResponse {
            self.remainingTransientFailures = count
        } else {
            self.remainingTransientFailures = 0
        }
        self.gate = gate
    }

    func testConnection() async -> AIConnectionResult {
        AIConnectionResult(latency: 0, model: "closed-index", message: "ready")
    }

    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        if let gate {
            await gate.markEntered()
            await gate.waitUntilReleased()
        }
        let shouldReturnMalformed = lock.withLock {
            recorded.append(request)
            let value = !didRespond && firstResponse == .malformed
            didRespond = true
            return value
        }
        let shouldFailTransiently = lock.withLock {
            guard remainingTransientFailures > 0 else { return false }
            remainingTransientFailures -= 1
            return true
        }
        if shouldFailTransiently {
            throw AIProviderError.transport("temporary index test failure")
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

private actor ClosedIndexEvents {
    private var values: [RecommendationIndexExecutionEvent] = []

    func append(_ event: RecommendationIndexExecutionEvent) {
        values.append(event)
    }

    func kinds() -> [RecommendationIndexExecutionEvent.Kind] {
        values.map(\.kind)
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
    let events = ClosedIndexEvents()
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
        emit: { await messages.append($0) },
        observeRecommendationIndex: { await events.append($0) }
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
    let eventKinds = await events.kinds()
    for kind in [
        .routeSelected,
        .started,
        .statusLoaded,
        .batchPrepared,
        .classificationStarted,
        .classificationCompleted,
        .commitStarted,
        .commitCompleted,
        .completed,
    ] as [RecommendationIndexExecutionEvent.Kind] {
        #expect(eventKinds.contains(kind))
    }
}

@Test("Recommendation Index exposes live progress before the batch commit and completes after commit")
func recommendationIndexPublishesLiveExecutionState() async throws {
    let (store, serverID) = try await closedIndexStore(trackCount: 2)
    let gate = IndexExecutionGate()
    let provider = ClosedIndexProvider(gate: gate)
    let registry = RecommendationIndexExecutionRegistry()
    let runID = UUID()
    let sessionID = UUID()
    let lease = ToolExecutionLease(runID: runID, sessionID: sessionID, generation: 1)

    let task = Task {
        await ConversationEngine().run(
            userText: "构建完整推荐索引",
            provider: provider,
            model: "closed-index",
            bridge: MockAgentBridge(activeServerID: serverID),
            catalog: store,
            context: .init(
                serverID: serverID,
                recommendationIndexExecutionRegistry: registry
            ),
            intent: .libraryManagement,
            policy: .policy(for: .libraryManagement),
            executionLineage: .newRequest(text: "构建完整推荐索引"),
            runID: runID,
            executionLease: lease,
            confirm: { _ in true },
            emit: { _ in }
        )
    }

    await gate.waitUntilEntered()
    let liveState = await registry.snapshot(serverID: serverID)
    guard case let .running(snapshot) = liveState else {
        Issue.record("expected a live Recommendation Index state while the provider is paused")
        await gate.release()
        await task.value
        return
    }
    #expect(snapshot.runID == runID)
    #expect(snapshot.sessionID == sessionID)
    #expect(snapshot.phase == .classifyingBatch)
    #expect(snapshot.currentBatchSize > 0)
    #expect(liveState.userFacingSummary.contains("正在运行"))

    await gate.release()
    await task.value

    let finalState = await registry.snapshot(serverID: serverID)
    guard case let .completed(completedRunID, indexedTracks, totalTracks, _) = finalState else {
        Issue.record("expected the live Recommendation Index state to complete")
        return
    }
    #expect(completedRunID == runID)
    #expect(indexedTracks == totalTracks)
    #expect(totalTracks == 2)
    #expect(try await store.recommendationIndexStatus(serverID: serverID).pendingUniqueTracks == 0)
}

@Test("Malformed classification performs no stale commit and receives a new batch revision")
func recommendationIndexMalformedOutputChangesBatchIdentity() async throws {
    let (store, serverID) = try await closedIndexStore(trackCount: 9)
    let provider = ClosedIndexProvider(firstResponse: .malformed)
    let events = ClosedIndexEvents()
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
        emit: { _ in },
        observeRecommendationIndex: { await events.append($0) }
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
    let eventKinds = await events.kinds()
    #expect(eventKinds.contains(.classificationFailed))
    #expect(eventKinds.contains(.retrying))
}

@Test("Recommendation Index retries transient classification failures without changing the closed protocol")
func recommendationIndexRetriesTransientClassificationFailures() async throws {
    let (store, serverID) = try await closedIndexStore(trackCount: 3)
    let provider = ClosedIndexProvider(firstResponse: .transientFailures(2))
    let events = ClosedIndexEvents()
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
        emit: { _ in },
        observeRecommendationIndex: { await events.append($0) }
    )

    #expect(try await store.recommendationIndexStatus(serverID: serverID).pendingUniqueTracks == 0)
    #expect(provider.requests().count >= 3)
    let eventKinds = await events.kinds()
    #expect(eventKinds.filter { $0 == .retrying }.count == 2)
    #expect(!eventKinds.contains(.failed))
    #expect(provider.requests().allSatisfy { $0.tools?.isEmpty == true })
    #expect(provider.requests().allSatisfy { $0.hostedTools?.isEmpty == true })
    #expect(provider.requests().allSatisfy { $0.toolChoice == nil })
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

@Test("Recommendation Index parser extracts fenced JSON and reports coverage diagnostics")
func recommendationIndexParserDiagnosticsAreStructured() throws {
    let first = CatalogTrackLine(
        id: "server:one", title: "One", artist: "Artist", album: "Album", year: nil,
        genres: [], language: nil, duration: 180, isFavorite: false, rating: nil,
        playCount: 0, isDownloaded: false
    )
    let second = CatalogTrackLine(
        id: "server:two", title: "Two", artist: "Artist", album: "Album", year: nil,
        genres: [], language: nil, duration: 180, isFavorite: false, rating: nil,
        playCount: 0, isDownloaded: false
    )
    let batch = RecommendationIndexPreparedBatch(
        batchID: UUID(), revision: 3, checkpointGeneration: 2, mode: "full",
        tracks: [first, second], pendingFixed: 2, pendingSemantic: 0
    )
    let valid = RecommendationIndexClassificationEnvelope(
        batchID: batch.batchID,
        revision: batch.revision,
        mode: "full",
        items: [.init(id: first.id, mode: "full"), .init(id: second.id, mode: "full")]
    )
    let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
    let parsed = RecommendationIndexClassificationParser.parse(
        "模型说明：\n```json\n\(validJSON)\n```\n",
        for: batch
    )
    #expect(parsed == .success(valid))

    let incomplete = RecommendationIndexClassificationEnvelope(
        batchID: batch.batchID,
        revision: batch.revision,
        mode: "full",
        items: [.init(id: first.id, mode: "full")]
    )
    let incompleteResult = RecommendationIndexClassificationParser.parse(
        String(decoding: try JSONEncoder().encode(incomplete), as: UTF8.self),
        for: batch
    )
    switch incompleteResult {
    case .success:
        #expect(Bool(false))
    case let .failure(failure):
        #expect(failure.stage == .trackCoverage)
        #expect(failure.missingIDs == [second.id])
        #expect(failure.batchSize == 2)
        #expect(failure.rawLength > 0)
        #expect(failure.compactSummary.contains("missing_ids=\(second.id)"))
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
