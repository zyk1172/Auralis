// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AppShell
import Application
import Domain
import Foundation
import ImagePipeline
import Testing

private actor CancellableArtworkConnector: ServerConnecting {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellations = 0
    private(set) var calls = 0
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.serverUnavailable
    }
    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? {
        calls += 1
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancellations += 1 }
        return nil
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

@Suite("Artwork subscriber cancellation", .timeLimit(.minutes(1)))
struct ArtworkCancellationTests {
    private func pipeline(_ connector: CancellableArtworkConnector) -> ArtworkPipeline {
        ArtworkPipeline(connector: connector, diskCache: ArtworkDiskCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            budget: 1024
        ))
    }
    private func load(_ pipeline: ArtworkPipeline) async -> ArtworkPipelinePayload? {
        await pipeline.load(serverID: "server", remoteKey: "cover", cacheKey: "server|cover",
                            fallbackCacheKey: nil, targetPixelSize: 100)
    }

    @Test("The final consumer cancellation cancels the underlying request")
    func finalConsumerCancels() async {
        let connector = CancellableArtworkConnector()
        let pipeline = pipeline(connector)
        let request = Task { await load(pipeline) }
        await connector.waitForStart()
        request.cancel()
        #expect(await request.value == nil)
        #expect(await connector.cancellations == 1)
        #expect(await pipeline.activeConsumerCount(for: "server|cover") == 0)
    }

    @Test("One consumer cancellation preserves another consumer's shared request")
    func sharedConsumerRemains() async throws {
        let connector = CancellableArtworkConnector()
        let pipeline = pipeline(connector)
        let first = Task { await load(pipeline) }
        await connector.waitForStart()
        let second = Task { await load(pipeline) }
        for _ in 0..<1000 {
            if await pipeline.activeConsumerCount(for: "server|cover") == 2 { break }
            await Task.yield()
        }
        #expect(await pipeline.activeConsumerCount(for: "server|cover") == 2)
        first.cancel()
        for _ in 0..<1000 {
            if await pipeline.activeConsumerCount(for: "server|cover") == 1 { break }
            await Task.yield()
        }
        #expect(await connector.cancellations == 0)
        #expect(await connector.calls == 1)
        second.cancel()
        _ = await (first.value, second.value)
        #expect(await connector.cancellations == 1)
    }
}
