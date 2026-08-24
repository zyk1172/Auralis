import Foundation

/// 一次用户 turn 的共享请求分析结果。
///
/// 核心原则：一次 turn 只生成一份 semantics，Intent / ToolSelector /
/// Authorization / Task Policy / Direct Read 判定全部消费同一份结果，禁止各层
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
    /// 当前 lineage 的副作用授权。短续写继承上一 lineage；新完整请求从
    /// 当前语义重新编译，绝不继承旧 mutation authorization。
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
        executionLineage: ExecutionLineage? = nil
    ) {
        self.currentUserText = currentUserText
        self.relevantHistoryText = relevantHistoryText
        self.semantics = semantics
        self.intent = intent
        self.policy = policy
        self.authorization = authorization
        self.executionLineage = executionLineage
    }

    /// 在 conversation/task 边界构建一次计划。
    ///
    /// 参数说明：
    /// - `authorizationContext`：调用方已解析的授权（例如持久化任务恢复），
    ///   优先于从语义重新编译；
    /// - `executionLineage`：已有 lineage 时取其 authorization；
    /// - `initialTaskState`：持久化任务 goal 优先于当前文字（resume 语义）；
    /// - `failClosedAuthorization`：ToolLoop 直接调用方未提供 lineage/context 时
    ///   保持 fail-closed（拒绝对一切副作用授权），绝不把当前文本变成 consent。
    public static func build(
        userText: String,
        history: [AgentChatMessage],
        explicitIntent: AgentTaskIntent? = nil,
        explicitPolicy: AgentTaskPolicy? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        executionLineage: ExecutionLineage? = nil,
        initialTaskState: AgentTaskState? = nil,
        failClosedAuthorization: Bool = false
    ) -> AgentRequestPlan {
        let relevantHistoryText = AgentHistoryPolicy.relevantHistoryText(for: userText, in: history)
        // 唯一一次语义分析：ToolSelector / Intent / Authorization / Direct Read
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
        } else if failClosedAuthorization {
            // ToolLoop 直接调用方（未携带 lineage/context）只能使用只读能力；
            // 任何副作用都 fail-closed，防止文本本身成为授权来源。
            authorization = SideEffectAuthorizationContext(originalUserRequest: "")
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
        return AgentRequestPlan(
            currentUserText: userText,
            relevantHistoryText: relevantHistoryText,
            semantics: semantics,
            intent: intent,
            policy: policy,
            authorization: authorization,
            executionLineage: executionLineage
        )
    }
}
