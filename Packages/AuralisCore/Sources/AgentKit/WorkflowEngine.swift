import Foundation

/// The workflow layer makes long-running or batch-shaped tasks explicit without
/// turning intent into a capability gate. ToolRuntime remains the only execution
/// boundary; this route is used for task facts, completion diagnostics and future
/// workflow-specific progress reporting.
public enum AgentWorkflowKind: String, Codable, CaseIterable, Sendable {
    case generic
    case recommendationIndexV2
    case batchDownload
    case batchQueue
}

public struct AgentWorkflowRoute: Codable, Equatable, Sendable {
    public let kind: AgentWorkflowKind
    public let usesRecommendationIndexV2: Bool
    public let usesBatchTools: Bool

    public init(
        kind: AgentWorkflowKind,
        usesRecommendationIndexV2: Bool = false,
        usesBatchTools: Bool = false
    ) {
        self.kind = kind
        self.usesRecommendationIndexV2 = usesRecommendationIndexV2
        self.usesBatchTools = usesBatchTools
    }
}

public enum WorkflowEngine {
    public static func recommendationIndexWorkflow(
        preferredBatchSize: Int = 16
    ) -> RecommendationIndexWorkflow {
        RecommendationIndexWorkflow(preferredBatchSize: preferredBatchSize)
    }

    public static func route(intent: AgentTaskIntent, text: String) -> AgentWorkflowRoute {
        let normalized = text.lowercased()
        if intent == .libraryManagement,
           RecommendationIndexTaskRules.requiresCompleteBuild(text: text) {
            return AgentWorkflowRoute(
                kind: .recommendationIndexV2,
                usesRecommendationIndexV2: true,
                usesBatchTools: true
            )
        }

        if intent == .musicDownload {
            return AgentWorkflowRoute(kind: .batchDownload, usesBatchTools: true)
        }

        if intent == .queueManagement,
           ["多首", "批量", "几首", "queue_append_many", "queue_play_next_many", "many", "batch"]
            .contains(where: normalized.contains) {
            return AgentWorkflowRoute(kind: .batchQueue, usesBatchTools: true)
        }

        return AgentWorkflowRoute(kind: .generic)
    }
}
