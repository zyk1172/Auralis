// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 单个模型轮（round）的诊断记录。只携带可诊断事实：模型名、终止原因、
/// 分阶段耗时、Provider 请求 ID 与 token 分类；绝不记录 API Key、
/// 请求正文或用户敏感内容。
public struct AgentRoundDiagnostics: Codable, Sendable, Equatable {
    /// 第几轮模型请求（从 1 开始）。
    public var round: Int
    public var model: String
    /// 统一终止语义（AIStreamTermination 的 rawReason 或 kind）。
    public var terminationReason: String?
    /// 请求阶段耗时（流式 + 兼容补发）。
    public var requestDuration: TimeInterval?
    /// 工具阶段耗时（本轮所有工具执行合计）。
    public var toolDuration: TimeInterval?
    /// 恢复阶段耗时（恢复分支注入到下一轮模型成功响应）。
    public var recoveryDuration: TimeInterval?
    /// Provider 响应级请求 ID（x-request-id / request-id）。
    public var providerRequestID: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var reasoningTokens: Int?

    public init(
        round: Int,
        model: String,
        terminationReason: String? = nil,
        requestDuration: TimeInterval? = nil,
        toolDuration: TimeInterval? = nil,
        recoveryDuration: TimeInterval? = nil,
        providerRequestID: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.round = round
        self.model = model
        self.terminationReason = terminationReason
        self.requestDuration = requestDuration
        self.toolDuration = toolDuration
        self.recoveryDuration = recoveryDuration
        self.providerRequestID = providerRequestID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
    }
}

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
    /// Provider 协议/端点模式（AIProviderToolMode 的 rawValue，如
    /// openAIChat / openAIResponses / anthropicMessages）。
    public var providerProtocol: String?
    /// 每轮模型请求的诊断（请求/工具/恢复分阶段），按轮次顺序。
    public var rounds: [AgentRoundDiagnostics]
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
        self.providerProtocol = nil
        self.rounds = []
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

    /// 记录一轮模型请求的诊断。轮数有界，避免长任务诊断无限增长。
    public mutating func recordRound(_ round: AgentRoundDiagnostics) {
        if rounds.count < 64 { rounds.append(round) }
    }

    /// 补记最近一轮的工具阶段耗时（同一轮请求/工具分阶段记录）。
    public mutating func recordLastRoundToolPhase(duration: TimeInterval) {
        guard !rounds.isEmpty else { return }
        rounds[rounds.count - 1].toolDuration = duration
    }
}
