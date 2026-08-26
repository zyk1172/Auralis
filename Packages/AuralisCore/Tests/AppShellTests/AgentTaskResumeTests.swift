@testable import AppShell
import AgentKit
import Foundation
import Testing

@Test("推荐索引的中断任务可由继续恢复，普通任务不会被抢占")
@MainActor
func recommendationIndexResumeCandidateIsScoped() {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-agent-task-(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = AgentTaskStore(fileURL: fileURL)
    let conversationID = UUID()
    let record = store.start(
        conversationID: conversationID,
        intent: .libraryManagement,
        goal: "开始并一次性完成推荐索引 V2"
    )
    store.update(record.id, status: .interrupted, completedActions: ["library_index_v2_write_batch"])

    #expect(store.recommendationIndexResumeCandidate(conversationID: conversationID, requestText: "继续")?.id == record.id)
    #expect(store.recommendationIndexResumeCandidate(conversationID: UUID(), requestText: "继续") == nil)
    #expect(store.recommendationIndexResumeCandidate(conversationID: conversationID, requestText: "你好") == nil)

    store.update(record.id, status: .failed)
    #expect(store.recommendationIndexResumeCandidate(conversationID: conversationID, requestText: "继续")?.id == record.id)
}

@Test("Stateful Skill checkpoint survives task-store reload")
@MainActor
func recommendationIndexCheckpointPersistsAcrossReload() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-agent-checkpoint-(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = AgentTaskStore(fileURL: fileURL)
    let conversationID = UUID()
    let record = store.start(
        conversationID: conversationID,
        intent: .libraryManagement,
        goal: "开始并一次性完成推荐索引 V2"
    )
    let checkpoint = RecommendationIndexCheckpoint(
        total: 42,
        indexed: 16,
        pending: 26,
        totalWrittenThisRun: 16,
        lastSuccessfulBatchCount: 16,
        currentBatchIDs: ["server:track-17"],
        preferredBatchSize: 16,
        status: .classifyingBatch,
        stoppedReason: "Provider 暂时不可用"
    )
    let checkpointData = try JSONEncoder().encode(checkpoint)
    store.update(record.id, status: .interrupted, checkpointJSON: String(decoding: checkpointData, as: UTF8.self))

    let reloaded = AgentTaskStore(fileURL: fileURL)
    let restored = try #require(reloaded.record(record.id))
    let restoredData = try #require(restored.checkpointJSON?.data(using: .utf8))
    let restoredCheckpoint = try JSONDecoder().decode(RecommendationIndexCheckpoint.self, from: restoredData)
    #expect(restoredCheckpoint == checkpoint)
}
