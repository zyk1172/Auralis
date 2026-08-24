import AgentKit
import Domain
import Foundation
import Testing

@Suite("Recommendation Index execution state")
struct RecommendationIndexExecutionStateTests {
    @Test("persisted pending data does not imply a live index run")
    func pendingDataIsNotRunning() async {
        let registry = RecommendationIndexExecutionRegistry()

        let state = await registry.snapshot(serverID: "state-server")

        #expect(state == .idle)
        #expect(!state.isRunning)
        #expect(state.userFacingSummary.contains("没有推荐索引任务运行"))
    }

    @Test("index execution state reports phase and terminal result")
    func stateMovesFromRunningToCompleted() async {
        let registry = RecommendationIndexExecutionRegistry()
        let runID = UUID()
        let sessionID = UUID()

        #expect(await registry.begin(serverID: "state-server", runID: runID, sessionID: sessionID))
        await registry.update(
            serverID: "state-server",
            runID: runID,
            sessionID: sessionID,
            phase: .classifyingBatch,
            totalTracks: 100,
            indexedTracks: 24,
            pendingTracks: 76,
            pendingSemanticTagTracks: 10,
            currentBatchSize: 8,
            processedThisRun: 24
        )

        let running = await registry.snapshot(serverID: "state-server")
        guard case let .running(snapshot) = running else {
            Issue.record("expected a running Recommendation Index state")
            return
        }
        #expect(snapshot.runID == runID)
        #expect(snapshot.sessionID == sessionID)
        #expect(snapshot.phase == .classifyingBatch)
        #expect(snapshot.indexedTracks == 24)
        #expect(snapshot.currentBatchSize == 8)
        #expect(snapshot.processedThisRun == 24)
        #expect(running.userFacingSummary.contains("24 / 100"))

        await registry.complete(
            serverID: "state-server",
            runID: runID,
            totalTracks: 100,
            indexedTracks: 100
        )
        let completed = await registry.snapshot(serverID: "state-server")
        guard case let .completed(completedRunID, indexedTracks, totalTracks, _) = completed else {
            Issue.record("expected a completed Recommendation Index state")
            return
        }
        #expect(completedRunID == runID)
        #expect(indexedTracks == 100)
        #expect(totalTracks == 100)
        #expect(!completed.isRunning)
        #expect(completed.userFacingSummary.contains("已完成"))
    }

    @Test("same server index runs conflict while unrelated servers remain available")
    func resourceIsScopedToServer() async {
        let registry = RecommendationIndexExecutionRegistry()
        let firstRun = UUID()
        let secondRun = UUID()

        #expect(await registry.begin(serverID: "server-a", runID: firstRun, sessionID: UUID()))
        #expect(await registry.begin(serverID: "server-a", runID: secondRun, sessionID: UUID()) == false)
        #expect(await registry.begin(serverID: "server-b", runID: secondRun, sessionID: UUID()))

        await registry.stop(serverID: "server-a", runID: firstRun)
        await registry.stop(serverID: "server-b", runID: secondRun)
        #expect((await registry.snapshot(serverID: "server-a")) == .idle)
        #expect((await registry.snapshot(serverID: "server-b")) == .idle)
    }
}
