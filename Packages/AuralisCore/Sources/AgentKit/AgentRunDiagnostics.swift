import Foundation

/// 单次 Agent run 的安全结构化诊断记录。
///
/// 只记录可诊断的行为事实，绝不记录 API Key、token、密码或完整敏感用户数据；
/// 工具参数继续使用已有的 `AgentSensitiveDataRedactor`。
public struct AgentRunDiagnostics: Codable, Sendable, Equatable {
    public let runID: UUID
    public var intent: String
    public var semanticDomain: String
    public var semanticOperation: String
    public var requestedOperations: [String]
    public var allowedOperations: [String]
    public var selectedToolNames: [String]
    public var toolSearchQueries: [String]
    public var toolSearchReturnedNames: [String]
    public var toolCallNames: [String]
    public var authorizationDecisions: [String]
    public var confirmationDecisions: [String]
    public var toolSuccessCount: Int
    public var toolFailureCount: Int
    public var failureCodes: [String]
    public var noProgressCount: Int
    public var convergenceStopReason: String?
    public var completionPredicate: String?
    public var completionResult: String?
    /// Built-in Skill 诊断：为什么激活、处于哪个阶段、发生了多少次状态迁移、
    /// 最终结果如何。
    public var activeSkillID: String?
    public var skillPhase: String?
    public var skillTransitionCount: Int
    public var skillCompletionResult: String?

    public init(runID: UUID = UUID()) {
        self.runID = runID
        self.intent = ""
        self.semanticDomain = ""
        self.semanticOperation = ""
        self.requestedOperations = []
        self.allowedOperations = []
        self.selectedToolNames = []
        self.toolSearchQueries = []
        self.toolSearchReturnedNames = []
        self.toolCallNames = []
        self.authorizationDecisions = []
        self.confirmationDecisions = []
        self.toolSuccessCount = 0
        self.toolFailureCount = 0
        self.failureCodes = []
        self.noProgressCount = 0
        self.convergenceStopReason = nil
        self.completionPredicate = nil
        self.completionResult = nil
        self.activeSkillID = nil
        self.skillPhase = nil
        self.skillTransitionCount = 0
        self.skillCompletionResult = nil
    }

    public mutating func recordSelectedTool(_ name: String) {
        if !selectedToolNames.contains(name) { selectedToolNames.append(name) }
    }

    public mutating func recordToolSearch(query: String, returned: [String]) {
        if toolSearchQueries.count < 8 { toolSearchQueries.append(query) }
        for name in returned where !toolSearchReturnedNames.contains(name) {
            if toolSearchReturnedNames.count < 32 { toolSearchReturnedNames.append(name) }
        }
    }

    public mutating func recordToolCall(_ name: String) {
        if toolCallNames.count < 64 { toolCallNames.append(name) }
    }

    public mutating func recordAuthorization(_ decision: String) {
        if authorizationDecisions.count < 32 { authorizationDecisions.append(decision) }
    }

    public mutating func recordConfirmation(_ decision: String) {
        if confirmationDecisions.count < 16 { confirmationDecisions.append(decision) }
    }

    public mutating func recordFailure(code: String) {
        toolFailureCount += 1
        if !failureCodes.contains(code) { failureCodes.append(code) }
    }

    public mutating func recordToolSuccess() {
        toolSuccessCount += 1
    }
}
