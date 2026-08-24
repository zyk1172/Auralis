import Foundation

/// The workflow layer makes long-running or batch-shaped tasks explicit without
/// turning intent into a capability gate. ToolRuntime remains the only execution
/// boundary; this route is used for task facts, completion diagnostics and future
/// workflow-specific progress reporting.
public enum AgentWorkflowKind: String, Codable, CaseIterable, Sendable {
    case generic
    case recommendationIndex
    case batchDownload
    case batchQueue

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "recommendationIndexV2"
            ? .recommendationIndex
            : Self(rawValue: raw) ?? .generic
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentWorkflowRoute: Codable, Equatable, Sendable {
    public let kind: AgentWorkflowKind
    public let usesRecommendationIndex: Bool
    public let usesBatchTools: Bool

    public init(
        kind: AgentWorkflowKind,
        usesRecommendationIndex: Bool = false,
        usesBatchTools: Bool = false
    ) {
        self.kind = kind
        self.usesRecommendationIndex = usesRecommendationIndex
        self.usesBatchTools = usesBatchTools
    }
}

public enum WorkflowEngine {
    public static func recommendationIndexWorkflow(
        preferredBatchSize: Int = 16
    ) -> RecommendationIndexWorkflow {
        RecommendationIndexWorkflow(preferredBatchSize: preferredBatchSize)
    }

    public static func route(
        intent: AgentTaskIntent,
        text: String,
        semantics: AgentRequestSemantics? = nil,
        initialTaskState: AgentTaskState? = nil,
        executionLineage: ExecutionLineage? = nil
    ) -> AgentWorkflowRoute {
        let normalized = text.lowercased()
        let analyzed = semantics ?? AgentRequestSemantics.analyze(text)
        if RecommendationIndexSkillRuntime.shouldActivate(
            semantics: analyzed,
            userText: text,
            initialTaskState: initialTaskState,
            executionLineage: executionLineage
        ) {
            return AgentWorkflowRoute(
                kind: .recommendationIndex,
                usesRecommendationIndex: true,
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
