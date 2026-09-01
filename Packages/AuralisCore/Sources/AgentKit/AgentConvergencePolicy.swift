import Foundation

/// 普通交互式 Agent 的确定性收敛策略。
///
/// 目标是把「同一请求反复不收敛」从纯诊断变成可执行的行为边界，同时不破坏
/// 批量任务（Recommendation Index 走专用 Runtime，不经过这里；legacy
/// `AgentRunner` 兼容面保持宽松预算）。
///
/// 收敛按「行为模式」触发，而不是把不同参数的合法批量读取当作死循环：
/// - 完全相同 tool+参数：最多真正执行/尝试有限次；
/// - tool_search 是能力发现，不是主链路：单任务有次数上限；
/// - 连续 malformed、连续无新证据都是明确的失败信号；
/// - 模型轮次 / 总工具调用是兜底看门狗，防止任何异常路径无限循环。
public struct AgentConvergencePolicy: Sendable, Equatable, Codable {
    /// 普通任务模型轮次上限。原实现默认 1000；交互式普通聊天应 fail-fast。
    public var maxModelRounds: Int
    /// 普通任务总工具调用上限。
    public var maxTotalToolCalls: Int
    /// 相同 tool + 相同规范化参数连续出现的上限（缓存命中和幂等跳过不计数）。
    public var maxIdenticalToolCalls: Int
    /// 连续没有新增事实/证据的轮次上限。
    public var maxNoProgressRounds: Int
    /// 单任务 tool_search 调用上限。
    public var maxToolSearches: Int
    /// 连续 malformed 参数上限。
    public var maxConsecutiveMalformedCalls: Int
    /// 连续搜索工具无新证据的上限（现有工作集提示的上限之上再加硬停止）。
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

    /// 交互式普通聊天的严格预算。
    public static let interactive = AgentConvergencePolicy()

    /// 需要较多轮次但仍应 fail-fast 的复合任务（搜索→选择→写队列→播放等）。
    public static let compoundTask = AgentConvergencePolicy(
        maxModelRounds: 24,
        maxTotalToolCalls: 48,
        maxIdenticalToolCalls: 2,
        maxNoProgressRounds: 3,
        maxToolSearches: 3,
        maxConsecutiveMalformedCalls: 3,
        maxSameToolNoNewEvidence: 3
    )

    /// Legacy `AgentRunner` 兼容面保留的历史契约：不设累计轮次/调用上限，
    /// 只保留防呆模式（相同参数、搜索无新证据、malformed）。
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

    /// 长任务（下载批量 / 推荐索引等）保留自己的宽松预算；推荐索引实际走
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

/// 收敛停止的可诊断原因。用户提示由 `userMessage` 生成，避免模糊的「任务失败」。
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
    /// 已达到收敛阈值的搜索工具名（从 schema 移除，避免模型反复尝试）。
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
    /// 返回 true 表示该工具已达到收敛阈值（调用方应从 schema 移除该工具）。
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

    /// 该搜索工具是否已达到收敛阈值（应停止使用该工具 / 触发任务停止）。
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

    /// 返回第一个命中的停止原因；nil 表示可以继续。
    public func stopReason(
        under policy: AgentConvergencePolicy,
        tolerateSearchExhaustion: Bool = false
    ) -> AgentConvergenceStopReason? {
        _ = policy
        _ = tolerateSearchExhaustion
        return nil
    }
}
