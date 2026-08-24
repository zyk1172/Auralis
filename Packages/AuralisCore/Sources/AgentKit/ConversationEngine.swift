import AIKit
import Foundation
import LocalCatalog

/// Chat-first conversation boundary.  Intent is a hint for ranking and task
/// completion; it is never permission to reinterpret an ordinary answer as a
/// local music search.
public struct ConversationEngine: Sendable {
    public init() {}

    public static func isExplicitMusicCommand(_ text: String) -> Bool {
        let semantics = AgentRequestSemantics.analyze(text)
        return semantics.isMusicContext && semantics.domain != .conversation
    }

    public static func allowsOfflineFallback(intent: AgentTaskIntent, userText: String) -> Bool {
        guard isExplicitMusicCommand(userText) else { return false }
        switch intent {
        case .librarySearch, .playbackControl, .musicDiscovery, .queueManagement,
             .playlistManagement, .libraryManagement, .musicAppreciation, .musicDownload:
            return true
        case .conversation, .playbackQuery, .queueQuery, .playlistQuery,
             .serverManagement, .diagnostics, .memoryManagement:
            return false
        }
    }

    public func run(
        userText: String,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: ToolLoop.Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        webService: (any AgentWebService)? = nil,
        intent: AgentTaskIntent? = nil,
        policy: AgentTaskPolicy? = nil,
        initialTaskState: AgentTaskState? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        executionLineage: ExecutionLineage? = nil,
        convergencePolicy: AgentConvergencePolicy? = nil,
        runID: UUID = UUID(),
        executionLease: ToolExecutionLease? = nil,
        toolTimeout: TimeInterval = ToolLoop.toolExecutionTimeout,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (ToolLoop.AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in },
        observeRecommendationIndex: @escaping @Sendable (RecommendationIndexExecutionEvent) async -> Void = { _ in }
    ) async {
        // 一次 turn 只生成一份共享请求计划；lineage 与 ToolLoop 全部复用，
        // 不再各自重新分析用户文本。
        let plan = AgentRequestPlan.build(
            userText: userText,
            history: history,
            explicitIntent: intent,
            explicitPolicy: policy,
            authorizationContext: authorizationContext,
            executionLineage: executionLineage,
            initialTaskState: initialTaskState
        )
        let resolvedLineage = executionLineage ?? Self.executionLineage(
            userText: userText,
            history: history,
            initialTaskState: initialTaskState,
            authorizationContext: authorizationContext,
            plan: plan
        )
        await ToolLoop.run(
            userText: userText,
            provider: provider,
            model: model,
            bridge: bridge,
            catalog: catalog,
            context: context,
            history: history,
            systemService: systemService,
            externalMusicService: externalMusicService,
            webService: webService,
            intent: intent,
            policy: policy,
            initialTaskState: initialTaskState,
            authorizationContext: resolvedLineage.authorization,
            executionLineage: resolvedLineage,
            requestPlan: plan,
            convergencePolicy: convergencePolicy,
            runID: runID,
            executionLease: executionLease,
            toolTimeout: toolTimeout,
            confirm: confirm,
            emit: emit,
            log: log,
            progress: progress,
            state: state,
            observeRecommendationIndex: observeRecommendationIndex
        )
    }

    /// Resolve authorization at the conversation/task boundary.  A short
    /// continuation refers to the last substantive user request, while a
    /// persisted task goal wins for resume.  ToolLoop never derives consent
    /// from the current model-loop text. All authorization derives from the
    /// same shared `AgentRequestPlan` (single semantics per turn).
    private static func executionLineage(
        userText: String,
        history: [AgentChatMessage],
        initialTaskState: AgentTaskState?,
        authorizationContext: SideEffectAuthorizationContext?,
        plan: AgentRequestPlan
    ) -> ExecutionLineage {
        _ = history
        if let authorizationContext {
            return ExecutionLineage(
                sourceRequest: authorizationContext.originalUserRequest,
                authorization: authorizationContext
            )
        }
        if let goal = initialTaskState?.goal.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty,
           goal.caseInsensitiveCompare(userText.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
            return ExecutionLineage(
                originUserMessageID: UUID(),
                taskID: initialTaskState?.id ?? UUID(),
                sourceRequest: goal,
                authorization: plan.authorization
            )
        }
        if !plan.relevantHistoryText.isEmpty {
            // 短续写：授权沿用合并后的共享语义（ToolSelector 与 Authorization 同源），
            // sourceRequest 保留最初的完整任务指令供诊断/恢复。
            return ExecutionLineage(
                sourceRequest: plan.relevantHistoryText,
                authorization: plan.authorization
            )
        }
        return .newRequest(
            text: userText,
            semantics: plan.semantics
        )
    }
}
