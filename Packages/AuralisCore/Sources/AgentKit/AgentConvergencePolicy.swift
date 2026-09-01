import Foundation

/// 普通交互式 Agent 的收敛诊断配置。
///
/// 这些字段保留为兼容性、遥测和诊断数据。普通 Agent 是否继续调用工具，
/// 由模型根据真实工具结果决定；此 tracker 不再因为这些计数主动终止普通 Agent。
/// Recommendation Index 仍然走专用 Runtime，不经过普通 Agent 循环。
public struct AgentConvergencePolicy: Sendable, Equatable, Codable {
    /// 诊断用的模型轮次阈值；不作为普通 Agent 的终止条件。
    public var maxModelRounds: Int
    /// 诊断用的总工具调用阈值；不作为普通 Agent 的终止条件。
    public var maxTotalToolCalls: Int
    /// 诊断用的相同 tool + 相同规范化参数阈值（缓存命中和幂等跳过不计数）。
    public var maxIdenticalToolCalls: Int
    /// 诊断用的连续无新增事实/证据轮次阈值。
    public var maxNoProgressRounds: Int
    /// 诊断用的单任务 tool_search 调用阈值。
    public var maxToolSearches: Int
    /// 诊断用的连续 malformed 参数阈值。
    public var maxConsecutiveMalformedCalls: Int
    /// 诊断用的连续搜索工具无新证据阈值。
    public var maxSameToolNoNewEvidence: Int

    public init(
        maxModelRounds: Int = 16,
        maxTotalToolCalls: Int = 32,
        maxIdenticalToolCalls: Int = 2,
        maxNoProgressRounds: Int = 3,
        maxToolSearches: Int = 3,
        maxConsecutiveMalformedCalls: Int = 3,
        maxSameToolNoNewEvidence: Int = 3
    ) {
        self.maxModelRounds = maxModelRounds
        self.maxTotalToolCalls = maxTotalToolCalls
        self.maxIdenticalToolCalls = maxIdenticalToolCalls
        self.maxNoProgressRounds = maxNoProgressRounds
        self.maxToolSearches = maxToolSearches
        self.maxConsecutiveMalformedCalls = maxConsecutiveMalformedCalls
        self.maxSameToolNoNewEvidence = maxSameToolNoNewEvidence
    }

    /// 交互式普通聊天的默认诊断阈值集合；不构成执行预算。
    public static let interactive = AgentConvergencePolicy()

    /// 复合任务（搜索→选择→写队列→播放等）的诊断阈值集合。
    public static let compoundTask = AgentConvergencePolicy(
        maxModelRounds: 24,
        maxTotalToolCalls: 48,
        maxIdenticalToolCalls: 2,
        maxNoProgressRounds: 3,
        maxToolSearches: 3,
        maxConsecutiveMalformedCalls: 3,
        maxSameToolNoNewEvidence: 3
    )

    /// Legacy `AgentRunner` 兼容面保留的历史阈值集合。
    /// 生产路径（ConversationEngine）不使用此预算。
    public static let legacyPermissive = AgentConvergencePolicy(
        maxModelRounds: 1_000,
        maxTotalToolCalls: Int.max,
        maxIdenticalToolCalls: Int.max,
        maxNoProgressRounds: .max,
        maxToolSearches: 8,
        maxConsecutiveMalformedCalls: 8,
        maxSameToolNoNewEvidence: .max
    )

    /// 长任务（下载批量 / 推荐索引等）保留自己的诊断阈值集合；推荐索引实际走
    /// RecommendationIndexSkillRuntime，不经过普通 Agent 循环。
    public static let longRunning = AgentConvergencePolicy(
        maxModelRounds: 10_000,
        maxTotalToolCalls: Int.max,
        maxIdenticalToolCalls: 8,
        maxNoProgressRounds: 8,
        maxToolSearches: 8,
        maxConsecutiveMalformedCalls: 8,
        maxSameToolNoNewEvidence: 8
    )
}

/// 历史收敛停止原因枚举。保留 `userMessage` 与 Codable API 供兼容和诊断使用。
public enum AgentConvergenceStopReason: String, Sendable, Equatable, Codable {
    case modelRoundLimit
    case totalToolCallLimit
    case identicalToolCall
    case noProgress
    case toolSearchExhausted
    case repeatedMalformedCall
    case noNewEvidence
    case unsupportedCapability

    /// 面向用户的自然说明；不暴露内部计数器细节。
    public var userMessage: String {
        switch self {
        case .modelRoundLimit, .totalToolCallLimit:
            return "本轮交互尝试次数过多，为避免卡住已停止。可以换一种更明确的说法重新发起。"
        case .identicalToolCall:
            return "同一操作已经重复尝试过且没有新结果，本次停止继续执行相同操作。"
        case .noProgress:
            return "已经反复尝试但没有取得新的进展，本次停止继续。"
        case .toolSearchExhausted:
            return "当前工具能力不足以完成这个操作，已停止继续搜索。"
        case .repeatedMalformedCall:
            return "模型连续返回了无法解析的工具调用，已停止本次交互。"
        case .noNewEvidence:
            return "已经反复尝试相同查询，没有获得新的结果，本次停止继续搜索。"
        case .unsupportedCapability:
            return "当前 Auralis 没有支持此操作的受支持工具。"
        }
    }
}

/// 一次交互运行内的收敛计数器。两个 Loop（generic chat / deterministic task）
/// 共用同一份跟踪实现，避免行为分叉。
public struct AgentConvergenceTracker: Sendable {
    public private(set) var modelRounds = 0
    public private(set) var totalToolCalls = 0
    public private(set) var identicalToolCallStreak = 0
    public private(set) var noProgressStreak = 0
    public private(set) var toolSearchCount = 0
    public private(set) var consecutiveMalformedCalls = 0
    public private(set) var lastSignature: String?
    /// 每个搜索工具独立的“连续无新证据”streak（不同工具互不污染）。
    public private(set) var searchNoNewEvidenceStreakByTool: [String: Int] = [:]
    /// 兼容性的搜索工具集合；普通 Agent 不会由 tracker 自动标记或移除工具。
    public private(set) var exhaustedSearchTools: Set<String> = []

    public init() {}

    public mutating func recordModelRound() {
        modelRounds += 1
    }

    /// 每收到一个模型 ToolCall 调用一次：只累计总调用数。
    /// 幂等/缓存拦截的重复调用也算总账，但不计入 identical streak。
    public mutating func recordTotalCall() {
        totalToolCalls += 1
    }

    /// 真正执行工具后调用：只负责 identical signature streak，不再修改 totalToolCalls
    /// （避免一次真实执行被统计两次）。
    public mutating func recordToolExecution(signature: String) {
        if lastSignature == signature {
            identicalToolCallStreak += 1
        } else {
            identicalToolCallStreak = 1
        }
        lastSignature = signature
    }

    /// 搜索工具结果返回后调用：按工具名独立累计 no-new-evidence。
    /// 产生新 evidence → 重置该工具 streak；无新 → 累计。
    /// 只累计诊断 streak；返回值保留兼容性，普通 Agent 始终可以继续使用该工具。
    @discardableResult
    public mutating func recordSearchOutcome(
        toolName: String,
        foundNewEvidence: Bool,
        policy: AgentConvergencePolicy
    ) -> Bool {
        if foundNewEvidence {
            searchNoNewEvidenceStreakByTool[toolName] = 0
        } else {
            let streak = (searchNoNewEvidenceStreakByTool[toolName] ?? 0) + 1
            searchNoNewEvidenceStreakByTool[toolName] = streak
        }
        _ = policy
        return false
    }

    /// 保留搜索耗尽查询 API；普通 Agent 不会因诊断 streak 耗尽工具。
    public func isSearchExhausted(_ toolName: String, under policy: AgentConvergencePolicy) -> Bool {
        _ = toolName
        _ = policy
        return false
    }

    public mutating func recordToolSearch() {
        toolSearchCount += 1
    }

    public mutating func recordMalformedCall() {
        consecutiveMalformedCalls += 1
    }

    /// 合法 ToolCall 后必须调用：malformed streak 只对“真正连续”的畸形调用生效。
    public mutating func recordValidCall() {
        consecutiveMalformedCalls = 0
    }

    public mutating func recordProgress() {
        noProgressStreak = 0
    }

    public mutating func recordNoProgress() {
        noProgressStreak += 1
    }

    /// 保留停止原因 API；普通 Agent 的 convergence 计数只做诊断，因此始终返回 nil。
    public func stopReason(
        under policy: AgentConvergencePolicy,
        tolerateSearchExhaustion: Bool = false
    ) -> AgentConvergenceStopReason? {
        _ = policy
        _ = tolerateSearchExhaustion
        return nil
    }
}
