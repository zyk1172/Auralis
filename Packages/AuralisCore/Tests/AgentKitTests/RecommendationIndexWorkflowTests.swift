import AgentKit
import Testing

@Suite("Recommendation Index workflow")
struct RecommendationIndexWorkflowTests {
    @Test("状态机按 status、batch、write、verify 完成")
    func completesFromFacts() {
        var workflow = WorkflowEngine.recommendationIndexWorkflow(preferredBatchSize: 8)
        #expect(workflow.state == .readingStatus)
        #expect(workflow.applyStatus(pending: 20) == .fetchingBatch)
        #expect(workflow.applyBatch(ids: ["a", "b"], pending: 20) == .classifyingBatch)
        workflow.beginWritingBatch()
        #expect(workflow.state == .writingBatch)
        #expect(workflow.applyWrite(pending: 12) == .verifying)
        #expect(workflow.verify(pending: 12) == .fetchingBatch)
        #expect(workflow.applyBatch(ids: ["c"], pending: 4) == .classifyingBatch)
        #expect(workflow.applyWrite(pending: 0) == .verifying)
        #expect(workflow.verify(pending: 0) == .completed)
        #expect(workflow.isCompleted)
    }

    @Test("截断恢复只缩小下一批，不改变完成事实")
    func shrinksOnlyForRecovery() {
        var workflow = WorkflowEngine.recommendationIndexWorkflow(preferredBatchSize: 16)
        #expect(workflow.shrinkBatch() == 8)
        #expect(workflow.retryCount == 1)
        #expect(workflow.state == .fetchingBatch)
        #expect(workflow.pending == 0)
    }
}
