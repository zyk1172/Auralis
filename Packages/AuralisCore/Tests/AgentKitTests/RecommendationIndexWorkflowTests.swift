import AgentKit
import Testing

@Suite("Recommendation Index workflow")
struct RecommendationIndexWorkflowTests {
    @Test("状态机按 status、batch、write、verify 完成")
    func completesFromFacts() {
        var workflow = WorkflowEngine.recommendationIndexWorkflow(preferredBatchSize: 8)
        #expect(workflow.state == .readingStatus)
        #expect(workflow.applyStatus(pending: 20, pendingSemantic: 0) == .fetchingBatch)
        #expect(workflow.applyBatch(ids: ["a", "b"], mode: "full", pending: 20, pendingSemantic: 0) == .classifyingBatch)
        workflow.beginWritingBatch()
        #expect(workflow.state == .writingBatch)
        #expect(workflow.applyWrite(pending: 12, pendingSemantic: 0) == .verifying)
        #expect(workflow.verify(pending: 12, pendingSemantic: 0) == .fetchingBatch)
        #expect(workflow.applyBatch(ids: ["c"], mode: "full", pending: 4, pendingSemantic: 0) == .classifyingBatch)
        #expect(workflow.applyWrite(pending: 0, pendingSemantic: 0) == .verifying)
        #expect(workflow.verify(pending: 0, pendingSemantic: 0) == .completed)
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
