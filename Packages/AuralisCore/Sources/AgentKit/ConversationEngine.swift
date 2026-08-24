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
        let resolvedLineage = executionLineage ?? Self.executionLineage(
            userText: userText,
            history: history,
            initialTaskState: initialTaskState,
            authorizationContext: authorizationContext
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
    /// from the current model-loop text.
    private static func executionLineage(
        userText: String,
        history: [AgentChatMessage],
        initialTaskState: AgentTaskState?,
        authorizationContext: SideEffectAuthorizationContext?
    ) -> ExecutionLineage {
        if let authorizationContext {
            return ExecutionLineage(
                sourceRequest: authorizationContext.originalUserRequest,
                authorization: authorizationContext
            )
        }
        if let goal = initialTaskState?.goal.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty,
           goal.caseInsensitiveCompare(userText.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
            return .resumedTask(
                goal: goal,
                taskID: initialTaskState?.id ?? UUID()
            )
        }
        let historyText = AgentHistoryPolicy.relevantHistoryText(for: userText, in: history)
        if !historyText.isEmpty {
            let authorization = SideEffectAuthorizationContext(
                sourceRequest: historyText,
                semantics: AgentRequestSemantics.analyze(historyText)
            )
            return ExecutionLineage(
                sourceRequest: historyText,
                authorization: authorization
            )
        }
        return .newRequest(text: userText)
    }
}
