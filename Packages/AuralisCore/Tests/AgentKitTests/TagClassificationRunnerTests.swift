// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

private struct BackgroundClassifierProvider: AIProvider {
    let handler: @Sendable (AICompletionRequest) async throws -> AICompletionResponse
    func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse { try await handler(request) }
    func testConnection() async throws -> AIConnectionResult { throw TagClassificationFailure("No probes expected") }
    func stream(_ request: AICompletionRequest) -> AsyncThrowingStream<AIStreamEvent, Error> { .init { $0.finish() } }
}

private actor ClassificationRequests {
    var requests: [AICompletionRequest] = []
    func record(_ request: AICompletionRequest) -> Int { requests.append(request); return requests.count }
}

private actor ClassificationPauseGate {
    var entered = false
    var finished = false
    var waiting: CheckedContinuation<Void, Never>?
    var releaseWaiter: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        entered = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered || finished { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func finish() { finished = true; waiting?.resume(); waiting = nil }
}

private func classifiedResponse(_ request: AICompletionRequest) throws -> AICompletionResponse {
    let tracks = try JSONSerialization.jsonObject(with: Data(request.messages.last!.content.utf8)) as! [[String: Any]]
    let items = tracks.map { ["id": $0["id"]!, "tags": ["scene.study", "scene.focus", "instrument.piano"], "confidence": 0.9] }
    let data = try JSONSerialization.data(withJSONObject: ["items": items])
    return .init(model: request.model, content: String(decoding: data, as: UTF8.self))
}

@Suite("Independent background classification")
struct TagClassificationRunnerTests {
    private func fixture(count: Int = 3) async throws -> (LocalCatalogStore, [Track]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let tracks = (0..<count).map { index in
            Track(id: TrackID(rawValue: "\(index)"), serverID: "server", albumID: "album", artistID: "artist",
                  title: "Song \(index)", artistName: "Artist \(index)", albumTitle: "Album", duration: 180)
        }
        let sync = try await store.beginSync(serverID: "server", mode: .full)
        try await store.stageTracks(tracks, session: sync)
        try await store.completeSync(sync, completedAt: .now)
        return (store, tracks)
    }

    @Test("Text-only providers classify and persist real tags without chat, probes or tools")
    func completePipeline() async throws {
        let (store, _) = try await fixture(count: 10)
        let recorder = ClassificationRequests()
        let provider = BackgroundClassifierProvider { request in
            _ = await recorder.record(request)
            return try classifiedResponse(request)
        }
        try await TagClassificationRunner(catalog: store, provider: provider, model: " text-only ").run(serverID: "server")
        #expect(try await store.recommendationIndexStatus(serverID: "server").pendingTracks == 0)
        #expect(try await store.recommendByTags(serverIDs: ["server"], query: .init(includeTags: ["scene.study", "instrument.piano"], maxPerArtist: 10, maxPerAlbum: 10)).count == 10)
        let requests = await recorder.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.model == "text-only")
            #expect(request.tools == nil)
            #expect(request.hostedTools == nil)
            #expect(request.messages.count == 2)
            #expect(!request.messages.last!.content.contains("playCount"))
            #expect(!request.messages.last!.content.contains("isFavorite"))
        }
    }

    @Test("Empty classifications can be retried without replacing existing usable labels")
    func retriesUnlabeledOnly() async throws {
        let (store, _) = try await fixture(count: 2)
        _ = try await store.writeRecommendationIndex([
            .init(id: "server:0", scenes: ["scene.late_night"]), .init(id: "server:1"),
        ], serverID: "server")
        #expect(try await store.emptyRecommendationClassificationCount(serverID: "server") == 1)
        #expect(try await store.requeueEmptyRecommendationClassifications(serverID: "server") == 1)
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 1)
        let recorder = ClassificationRequests()
        let provider = BackgroundClassifierProvider { request in
            _ = await recorder.record(request)
            return try classifiedResponse(request)
        }
        try await TagClassificationRunner(catalog: store, provider: provider, model: "text-only").run(serverID: "server")
        #expect(try await store.emptyRecommendationClassificationCount(serverID: "server") == 0)
        let existing = try await store.recommendByTags(serverIDs: ["server"], query: .init(includeTags: ["scene.late_night"]))
        #expect(existing.map(\.track.id.rawValue) == ["0"])
        #expect(await recorder.requests.count == 1)
    }

    @Test("Malformed responses shrink a bounded batch and resume until every track is committed")
    func malformedRetry() async throws {
        let (store, _) = try await fixture()
        let recorder = ClassificationRequests()
        let provider = BackgroundClassifierProvider { request in
            let count = await recorder.record(request)
            if count == 1 { return .init(model: request.model, content: "{\"items\":[]}") }
            return try classifiedResponse(request)
        }
        try await TagClassificationRunner(catalog: store, provider: provider, model: "text-only").run(serverID: "server")
        #expect(try await store.recommendationIndexStatus(serverID: "server").pendingTracks == 0)
        #expect(await recorder.requests.count == 2)
    }

    @Test("Metadata changed during classification cannot be marked as freshly classified")
    func rejectsStaleResponse() async throws {
        let (store, original) = try await fixture(count: 1)
        let provider = BackgroundClassifierProvider { request in
            var changed = original
            changed[0].title = "Changed while model was running"
            let sync = try await store.beginSync(serverID: "server", mode: .full)
            try await store.stageTracks(changed, session: sync)
            try await store.completeSync(sync, completedAt: .now)
            return try classifiedResponse(request)
        }
        await #expect(throws: RecommendationIndexWriteError.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "text-only").run(serverID: "server")
        }
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 0)
    }

    @Test("Revoking authorization before commit leaves the pending batch unchanged")
    func authorizationBeforeCommit() async throws {
        let (store, _) = try await fixture(count: 1)
        let calls = ClassificationRequests()
        let provider = BackgroundClassifierProvider { try classifiedResponse($0) }
        await #expect(throws: TagClassificationFailure.self) {
            try await TagClassificationRunner(catalog: store, provider: provider, model: "text-only").run(serverID: "server", authorize: {
                let count = await calls.record(.init(model: "permission", messages: []))
                if count > 1 { throw TagClassificationFailure("permission revoked") }
            })
        }
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 0)
    }

    @Test("Pause ignores a late response, keeps completed batches, and resumes only pending tracks")
    func pauseAndResume() async throws {
        let (store, _) = try await fixture()
        let calls = ClassificationRequests()
        let gate = ClassificationPauseGate()
        let provider = BackgroundClassifierProvider { request in
            if await calls.record(request) == 2 { await gate.enterAndWait() }
            return try classifiedResponse(request)
        }
        let task = Task {
            do {
                try await TagClassificationRunner(catalog: store, provider: provider, model: "text-only", maxOutputTokens: 512).run(serverID: "server")
                await gate.finish()
            } catch { await gate.finish(); throw error }
        }
        await gate.waitUntilEntered()
        let entered = await gate.entered
        #expect(entered)
        task.cancel()
        await gate.release()
        _ = try? await task.value
        #expect(try await store.recommendationIndexStatus(serverID: "server").indexedTracks == 1)
        try await TagClassificationRunner(catalog: store, provider: BackgroundClassifierProvider { try classifiedResponse($0) }, model: "text-only").run(serverID: "server")
        #expect(try await store.recommendationIndexStatus(serverID: "server").pendingTracks == 0)
    }
}
