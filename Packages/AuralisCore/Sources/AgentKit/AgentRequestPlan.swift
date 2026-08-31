import Foundation

/// 一次用户 turn 的共享请求分析结果。
///
/// 核心原则：一次 turn 只生成一份 semantics，Intent / ToolSelector /
/// 操作元数据 / Task Policy / Direct Read 判定全部消费同一份结果，禁止各层
/// 用自己的关键词规则重新解释用户文本（避免 split-brain）。
///
/// 构建时机在 conversation/task 边界（ConversationEngine / AgentRuntime /
/// ToolLoop.run），随后整次 execution lineage 内固定。
public struct AgentRequestPlan: Sendable {
    public let currentUserText: String
    public let relevantHistoryText: String
    public let semantics: AgentRequestSemantics
    public let intent: AgentTaskIntent
    public let policy: AgentTaskPolicy
    /// Deterministic completion contract for compound local mutations. This
    /// is intentionally separate from authorization metadata: the operation
    /// set describes which successful effects the task must observe before it
    /// can finish, while Runtime still decides execution from descriptor risk
    /// and confirmation policy.
    public let requiredCompletionOperations: Set<ToolAuthorizationOperation>
    /// 当前 lineage 的副作用语义元数据。短续写继承上一 lineage；新完整请求从
    /// 当前语义重新编译。它用于路由和诊断，不是普通本地工具的执行白名单。
    public let authorization: SideEffectAuthorizationContext
    public let executionLineage: ExecutionLineage?

    public var allowedOperations: Set<ToolAuthorizationOperation> {
        authorization.allowedOperations
    }

    public init(
        currentUserText: String,
        relevantHistoryText: String,
        semantics: AgentRequestSemantics,
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        authorization: SideEffectAuthorizationContext,
        executionLineage: ExecutionLineage? = nil,
        completionSemantics: AgentRequestSemantics? = nil
    ) {
        self.currentUserText = currentUserText
        self.relevantHistoryText = relevantHistoryText
        self.semantics = semantics
        self.intent = intent
        self.policy = policy
        self.requiredCompletionOperations = Self.compileRequiredCompletionOperations(
            semantics: completionSemantics ?? semantics,
            policy: policy
        )
        self.authorization = authorization
        self.executionLineage = executionLineage
    }

    /// Compile completion requirements once at the task boundary. A missing
    /// operation is deliberately represented by an empty set: that preserves
    /// the existing broad predicate for legacy/ambiguous requests without
    /// turning semantic operation inference into an execution permission gate.
    private static func compileRequiredCompletionOperations(
        semantics: AgentRequestSemantics,
        policy: AgentTaskPolicy
    ) -> Set<ToolAuthorizationOperation> {
        switch policy.completion {
        case .queueMutation, .playlistMutation, .playbackMutation:
            return semantics.requestedOperations
        default:
            return []
        }
    }

    /// 在 conversation/task 边界构建一次计划。
    ///
    /// 参数说明：
    /// - `authorizationContext`：调用方已解析的语义元数据（例如持久化任务恢复），
    ///   优先于从语义重新编译；
    /// - `executionLineage`：已有 lineage 时取其元数据；
    /// - `initialTaskState`：持久化任务 goal 优先于当前文字（resume 语义）。
    public static func build(
        userText: String,
        history: [AgentChatMessage],
        explicitIntent: AgentTaskIntent? = nil,
        explicitPolicy: AgentTaskPolicy? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        executionLineage: ExecutionLineage? = nil,
        initialTaskState: AgentTaskState? = nil
    ) -> AgentRequestPlan {
        let relevantHistoryText = AgentHistoryPolicy.relevantHistoryText(for: userText, in: history)
        // 唯一一次语义分析：ToolSelector / Intent / 操作元数据 / Direct Read
        // 全部消费这个结果。
        let semantics = AgentRequestSemantics.analyze(userText, historyText: relevantHistoryText)
        let intent = explicitIntent ?? AgentIntentClassifier.classify(
            text: userText,
            historyText: relevantHistoryText,
            precomputedSemantics: semantics
        )
        let policy = explicitPolicy ?? AgentTaskPolicyResolver.resolve(
            text: userText,
            historyText: relevantHistoryText,
            explicitIntent: intent,
            precomputedSemantics: semantics
        )
        let authorization: SideEffectAuthorizationContext
        if let authorizationContext {
            authorization = authorizationContext
        } else if let lineage = executionLineage {
            authorization = lineage.authorization
        } else if let goal = initialTaskState?.goal.trimmingCharacters(in: .whitespacesAndNewlines),
                  !goal.isEmpty,
                  goal.caseInsensitiveCompare(userText.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
            authorization = SideEffectAuthorizationContext(
                originalUserRequest: goal,
                semantics: AgentRequestSemantics.analyze(goal)
            )
        } else if !relevantHistoryText.isEmpty {
            // 短续写：语义已经合并了历史；授权编译仍基于同一份合并语义，
            // 避免 ToolSelector 看到播放能力而授权层却停留在 conversation。
            authorization = SideEffectAuthorizationContext(
                originalUserRequest: userText,
                semantics: semantics
            )
        } else {
            authorization = SideEffectAuthorizationContext(
                originalUserRequest: userText,
                semantics: semantics
            )
        }
        // A resumed task/explicit continuation may use a short current
        // message such as “继续”. Its route and policy still belong to the
        // original goal, so preserve that goal's completion contract without
        // turning the authorization metadata into an execution gate.
        let completionSemantics: AgentRequestSemantics? = {
            guard let source = executionLineage?.sourceRequest
                    ?? initialTaskState?.goal,
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(userText.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
            else { return nil }
            return AgentRequestSemantics.analyze(source)
        }()
        return AgentRequestPlan(
            currentUserText: userText,
            relevantHistoryText: relevantHistoryText,
            semantics: semantics,
            intent: intent,
            policy: policy,
            authorization: authorization,
            executionLineage: executionLineage,
            completionSemantics: completionSemantics
        )
    }
}
