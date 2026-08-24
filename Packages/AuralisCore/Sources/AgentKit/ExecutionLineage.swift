import Foundation

/// A conversation may keep all of its semantic history, while executable
/// authority belongs to exactly one user-request lineage.  This value is
/// created at the conversation/task boundary and is never derived from model
/// output, tool output, web content, or a stale completion state.
public struct ExecutionLineage: Sendable, Hashable {
    public let lineageID: UUID
    public let originUserMessageID: UUID
    public let taskID: UUID?
    public let sourceRequest: String
    public let authorization: SideEffectAuthorizationContext
    public let activeSkillID: String?

    public init(
        lineageID: UUID = UUID(),
        originUserMessageID: UUID = UUID(),
        taskID: UUID? = nil,
        sourceRequest: String,
        authorization: SideEffectAuthorizationContext,
        activeSkillID: String? = nil
    ) {
        self.lineageID = lineageID
        self.originUserMessageID = originUserMessageID
        self.taskID = taskID
        self.sourceRequest = sourceRequest
        self.authorization = authorization
        self.activeSkillID = activeSkillID
    }

    public static func newRequest(
        text: String,
        originUserMessageID: UUID = UUID()
    ) -> ExecutionLineage {
        let semantics = AgentRequestSemantics.analyze(text)
        return ExecutionLineage(
            originUserMessageID: originUserMessageID,
            sourceRequest: text,
            authorization: SideEffectAuthorizationContext(
                sourceRequest: text,
                semantics: semantics
            )
        )
    }

    /// Bind a persisted task to a fresh run generation.  A persisted goal is
    /// trusted task state; the user's short resume phrase is not reinterpreted
    /// as a new authorization source.
    public static func resumedTask(
        goal: String,
        taskID: UUID,
        originUserMessageID: UUID = UUID(),
        activeSkillID: String? = nil
    ) -> ExecutionLineage {
        let semantics = AgentRequestSemantics.analyze(goal)
        return ExecutionLineage(
            originUserMessageID: originUserMessageID,
            taskID: taskID,
            sourceRequest: goal,
            authorization: SideEffectAuthorizationContext(
                sourceRequest: goal,
                semantics: semantics
            ),
            activeSkillID: activeSkillID
        )
    }

    public func attaching(
        taskID: UUID?,
        activeSkillID: String? = nil
    ) -> ExecutionLineage {
        ExecutionLineage(
            lineageID: lineageID,
            originUserMessageID: originUserMessageID,
            taskID: taskID,
            sourceRequest: sourceRequest,
            authorization: authorization,
            activeSkillID: activeSkillID ?? self.activeSkillID
        )
    }

    /// A short, explicit continuation keeps the original authority and task
    /// identity, but uses the current user-message ID for transcript identity.
    public func continued(originUserMessageID: UUID = UUID()) -> ExecutionLineage {
        ExecutionLineage(
            lineageID: lineageID,
            originUserMessageID: originUserMessageID,
            taskID: taskID,
            sourceRequest: sourceRequest,
            authorization: authorization,
            activeSkillID: activeSkillID
        )
    }
}

public enum ExecutionLineageResolver {
    /// A substantive request always starts a new lineage.  Only the narrowly
    /// defined continuation vocabulary may inherit executable authority.
    public static func resolve(
        currentUserText: String,
        originUserMessageID: UUID = UUID(),
        previous: ExecutionLineage?
    ) -> ExecutionLineage {
        if AgentHistoryPolicy.isExplicitContinuation(currentUserText),
           let previous {
            return previous.continued(originUserMessageID: originUserMessageID)
        }
        return .newRequest(text: currentUserText, originUserMessageID: originUserMessageID)
    }
}
