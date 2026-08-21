import AIKit
import Domain
import Foundation
import LocalCatalog

/// 用户请求的粗粒度意图。意图只用于任务理解、工具排序、提示、完成语义与 UI/诊断，
/// 不再是普通音乐工具的执行权限边界（permissive direct-execution runtime）。
public enum AgentTaskIntent: String, Codable, CaseIterable, Sendable {
    case conversation
    case librarySearch
    case playbackControl
    case musicDiscovery
    case queueManagement
    case playlistManagement
    case libraryManagement
    case serverManagement
    case diagnostics
    case musicAppreciation
    case musicDownload
    case memoryManagement
}

/// 工具副作用风险（deprecated / diagnostics-only）。Runtime 不再据此拒绝任何普通工具；
/// 保留枚举仅为旧任务记录、日志与 UI 分类兼容。
public enum AgentRisk: Int, Codable, Comparable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 能力域描述（deprecated / diagnostics-only）。
/// 曾用于按意图隔离工具；现在保留类型仅为 migration / Codable / 日志兼容，
/// Runtime 不再因缺少 scope 而拒绝已注册的普通工具。
public enum GrantedScope: String, Codable, CaseIterable, Sendable, Hashable {
    case catalogRead
    case playbackWrite
    case queueWrite
    case playlistWrite
    case annotationWrite
    case serverRead
    case serverWrite
    case downloadWrite
    case memoryRead
    case memoryWrite
    case diagnosticsRead
    case externalRead
}

public struct AgentTaskBudget: Codable, Equatable, Sendable {
    /// 0 表示不额外限制，直接跟随当前 Provider / ModelCapabilities。
    public static let followProvider = 0

    /// 极端看门狗：任务总墙钟时间。
    public var wallClockSeconds: TimeInterval

    /// 单次模型请求的输入限制。
    /// 0 = 跟随 Provider。
    public var maxInputTokens: Int

    /// 单次模型请求的输出限制。
    /// 0 = 跟随 Provider。
    public var maxOutputTokens: Int

    /// 极端防失控模型轮次看门狗。
    public var maxModelRounds: Int

    /// 仅诊断，不作为正常任务终止条件。
    public var maxNoProgressRounds: Int

    /// 仅诊断，不作为正常任务终止条件。
    public var maxRepeatedToolPattern: Int

    public init(
        wallClockSeconds: TimeInterval = 60 * 60,
        maxInputTokens: Int = AgentTaskBudget.followProvider,
        maxOutputTokens: Int = AgentTaskBudget.followProvider,
        maxModelRounds: Int = 1_000,
        maxNoProgressRounds: Int = 3,
        maxRepeatedToolPattern: Int = 4
    ) {
        self.wallClockSeconds = wallClockSeconds
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxModelRounds = maxModelRounds
        self.maxNoProgressRounds = maxNoProgressRounds
        self.maxRepeatedToolPattern = maxRepeatedToolPattern
    }

    public func resolvedInputTokens(
        capabilities: ModelCapabilities
    ) -> Int {
        guard maxInputTokens > 0 else {
            return capabilities.maxContextTokens
        }

        return min(
            maxInputTokens,
            capabilities.maxContextTokens
        )
    }

    public func resolvedOutputTokens(
        capabilities: ModelCapabilities
    ) -> Int {
        guard maxOutputTokens > 0 else {
            return capabilities.maxOutputTokens
        }

        return min(
            maxOutputTokens,
            capabilities.maxOutputTokens
        )
    }
}

public enum AgentCompletionPredicate: Codable, Equatable, Sendable {
    case modelAnswer
    /// 真实成功执行了至少一个工具（Tool Success ≠ Evidence）。
    case successfulToolResult
    case queueMutation
    case playlistMutation
    case playbackMutation
    case indexPendingCountIsZero
    case appreciationWithEvidence
}

/// 每个任务的路由/诊断策略（intent、completion、budget 等）。
/// 已注册的普通音乐工具默认全部允许执行；`authorizes` 不再构成能力门禁，
/// 保留方法仅为兼容旧调用方，恒返回 true。
public struct AgentTaskPolicy: Codable, Equatable, Sendable {
    public let intent: AgentTaskIntent
    public let scopes: Set<GrantedScope>
    public let allowedToolGroups: Set<ToolGroup>
    public let allowedPermissions: Set<ToolPermission>
    public let requiresConfirmationForDestructive: Bool
    public let maxRisk: AgentRisk
    public let completion: AgentCompletionPredicate
    public let budget: AgentTaskBudget

    public init(
        intent: AgentTaskIntent,
        scopes: Set<GrantedScope>,
        allowedToolGroups: Set<ToolGroup>,
        allowedPermissions: Set<ToolPermission> = [.readOnly],
        requiresConfirmationForDestructive: Bool = false,
        maxRisk: AgentRisk = .none,
        completion: AgentCompletionPredicate = .modelAnswer,
        budget: AgentTaskBudget = AgentTaskBudget()
    ) {
        self.intent = intent
        self.scopes = scopes
        self.allowedToolGroups = allowedToolGroups
        self.allowedPermissions = allowedPermissions
        self.requiresConfirmationForDestructive = requiresConfirmationForDestructive
        self.maxRisk = maxRisk
        self.completion = completion
        self.budget = budget
    }

    /// deprecated / diagnostics-only：permissive direct-execution runtime 不再用
    /// 意图/权限/风险/scope 拒绝已注册的普通音乐工具。恒返回 true。
    public func authorizes(_ descriptor: ToolDescriptor) -> Bool {
        true
    }

    public static func risk(for permission: ToolPermission) -> AgentRisk {
        switch permission {
        case .readOnly: .none
        case .reversible: .medium
        case .destructive: .high
        }
    }

    public static func policy(for intent: AgentTaskIntent) -> AgentTaskPolicy {
        let read: Set<ToolPermission> = [.readOnly]
        let write: Set<ToolPermission> = [.readOnly, .reversible]
        let destructive: Set<ToolPermission> = [.readOnly, .reversible, .destructive]
        switch intent {
        case .conversation:
            return .init(intent: intent, scopes: [.catalogRead, .memoryRead], allowedToolGroups: [.catalog, .memory], allowedPermissions: read)
        case .librarySearch:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead], allowedToolGroups: [.catalog, .server], allowedPermissions: read, completion: .successfulToolResult)
        case .playbackControl:
            return .init(intent: intent, scopes: [.catalogRead, .playbackWrite], allowedToolGroups: [.catalog, .playback], allowedPermissions: write, maxRisk: .medium, completion: .playbackMutation)
        case .musicDiscovery:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .queueWrite, .externalRead], allowedToolGroups: [.catalog, .server, .playback], allowedPermissions: write, maxRisk: .medium, completion: .successfulToolResult)
        case .queueManagement:
            return .init(intent: intent, scopes: [.catalogRead, .playbackWrite, .queueWrite], allowedToolGroups: [.catalog, .playback], allowedPermissions: destructive, maxRisk: .high, completion: .queueMutation)
        case .playlistManagement:
            return .init(intent: intent, scopes: [.catalogRead, .playlistWrite], allowedToolGroups: [.catalog, .playlist], allowedPermissions: destructive, maxRisk: .high, completion: .playlistMutation)
        case .libraryManagement:
            return .init(intent: intent, scopes: [.catalogRead, .annotationWrite], allowedToolGroups: [.catalog, .annotation], allowedPermissions: write, maxRisk: .medium, completion: .successfulToolResult)
        case .serverManagement:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .serverWrite], allowedToolGroups: [.catalog, .server], allowedPermissions: destructive, maxRisk: .high, completion: .successfulToolResult)
        case .diagnostics:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .diagnosticsRead], allowedToolGroups: [.catalog, .playback, .server], allowedPermissions: read, completion: .successfulToolResult)
        case .musicAppreciation:
            return .init(intent: intent, scopes: [.catalogRead, .externalRead], allowedToolGroups: [.catalog], allowedPermissions: read, completion: .appreciationWithEvidence)
        case .musicDownload:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .downloadWrite], allowedToolGroups: [.catalog, .server, .download], allowedPermissions: write, maxRisk: .medium, completion: .successfulToolResult)
        case .memoryManagement:
            return .init(intent: intent, scopes: [.memoryRead, .memoryWrite], allowedToolGroups: [.memory], allowedPermissions: destructive, maxRisk: .high, completion: .successfulToolResult)
        }
    }
}

public enum AgentEvidenceSource: String, Codable, Sendable {
    case localCatalog
    case derivedLocalStatistic
    case playbackState
    case server
    case externalAPI
    case musicBrainz
    case listenBrainz
    case critiqueBrainz
    case userStatement
    case modelInference
}

public struct AgentEvidence: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: AgentEvidenceSource
    public let provenance: String
    public let confidence: Double
    public let fetchedAt: Date
    public let entityID: String?
    public let claim: String

    public init(id: UUID = UUID(), source: AgentEvidenceSource, provenance: String, confidence: Double, fetchedAt: Date = .now, entityID: String? = nil, claim: String) {
        self.id = id
        self.source = source
        self.provenance = provenance
        self.confidence = min(max(confidence, 0), 1)
        self.fetchedAt = fetchedAt
        self.entityID = entityID
        self.claim = claim
    }
}

public struct AgentTaskProgress: Codable, Sendable, Equatable {
    public var modelRounds = 0
    public var toolCalls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var noProgressRounds = 0
    public var lastProgressAt = Date()
}

public enum AgentTaskLifecycleStatus: String, Codable, Sendable {
    case queued
    case running
    case waitingForModel
    case waitingForTool
    case completed
    case insufficient
    case failed
    case cancelled
    case interrupted
}

public enum AgentTaskCompletionState: String, Codable, Sendable {
    case pending
    case satisfied
    case insufficientEvidence
    case failed
}

/// 与音乐领域工作集分离的通用任务状态。领域状态可增量附加，不再成为主循环本身。
public struct AgentTaskState: Codable, Identifiable, Sendable {
    public let id: UUID
    public let intent: AgentTaskIntent
    public let goal: String
    public var status: AgentTaskLifecycleStatus
    public var facts: [String: String]
    public var evidence: [AgentEvidence]
    public var candidateIDs: Set<String>
    public var selectedIDs: Set<String>
    public var completedActions: [String]
    public var pendingActions: [String]
    public var errors: [String]
    public var progress: AgentTaskProgress
    public var completed: Bool
    public var completionState: AgentTaskCompletionState
    public var errorState: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var recentToolSignatures: [String]
    public var repeatedToolPatternCount: Int
    /// 真实成功执行过的工具名（每次成功追加）。
    public var successfulToolNames: [String]
    /// 真实成功执行的工具总数（Tool Success 是独立于 Evidence 的事实）。
    public var successfulToolCount: Int

    public init(id: UUID = UUID(), intent: AgentTaskIntent, goal: String, startedAt: Date = .now) {
        self.id = id
        self.intent = intent
        self.goal = goal
        self.status = .running
        self.facts = [:]
        self.evidence = []
        self.candidateIDs = []
        self.selectedIDs = []
        self.completedActions = []
        self.pendingActions = []
        self.errors = []
        self.progress = AgentTaskProgress(lastProgressAt: startedAt)
        self.completed = false
        self.completionState = .pending
        self.errorState = nil
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.recentToolSignatures = []
        self.repeatedToolPatternCount = 0
        self.successfulToolNames = []
        self.successfulToolCount = 0
    }

    public mutating func recordProgress(action: String? = nil, at date: Date = .now) {
        if let action, !action.isEmpty { completedActions.append(action) }
        progress.noProgressRounds = 0
        progress.lastProgressAt = date
        updatedAt = date
    }

    public mutating func recordNoProgress() {
        progress.noProgressRounds += 1
        updatedAt = .now
    }

    public mutating func recordToolCall(name: String, arguments: [String: String]) {
        let values = arguments.map { "\($0.key)=\($0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }.sorted()
        let signature = name + "|" + values.joined(separator: "&")
        if recentToolSignatures.last == signature {
            repeatedToolPatternCount += 1
        } else {
            repeatedToolPatternCount = 1
        }
        recentToolSignatures.append(signature)
        if recentToolSignatures.count > 12 { recentToolSignatures.removeFirst(recentToolSignatures.count - 12) }
        updatedAt = .now
    }

    /// 仅剩两个极端看门狗：总墙钟时间、模型轮次（默认 1000）。
    /// noProgress / repeatedToolPattern 只作诊断统计，不再终止任何正常任务。
    public func budgetViolation(policy: AgentTaskPolicy, now: Date = .now) -> AgentRuntimeError? {
        if now.timeIntervalSince(startedAt) > policy.budget.wallClockSeconds { return .wallClockBudgetExceeded }
        if progress.modelRounds >= policy.budget.maxModelRounds { return .modelRoundBudgetExceeded }
        return nil
    }
}

public enum AgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    /// 未知工具（注册表里不存在），而不是“权限不足”。
    case toolOutsidePolicy(String)
    case wallClockBudgetExceeded
    case modelRoundBudgetExceeded
    /// deprecated：不再作为任务终止条件；保留仅为兼容旧代码。
    case noProgress
    /// deprecated：不再作为任务终止条件；保留仅为兼容旧代码。
    case repeatedToolPattern

    public var errorDescription: String? {
        switch self {
        case let .toolOutsidePolicy(name): "无法执行：工具 \(name) 不存在。"
        case .wallClockBudgetExceeded: "任务运行时间过长，已停止以保护设备。"
        case .modelRoundBudgetExceeded: "任务运行轮次异常过多，已停止以保护设备。"
        case .noProgress: "任务连续多轮没有取得新进展。"
        case .repeatedToolPattern: "任务重复调用同一工具且没有形成新进展。"
        }
    }
}

public enum AgentFailureKind: String, Codable, Sendable {
    case cancelled
    case timeout
    case authentication
    case rateLimited
    case transientNetwork
    case serverUnavailable
    case invalidConfiguration
    case incompatibleResponse
    case permanent

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transientNetwork, .serverUnavailable: true
        default: false
        }
    }
}

public enum AgentFailureClassifier {
    public static func classify(_ error: Error) -> AgentFailureKind {
        if error is CancellationError { return .cancelled }
        if error is AgentRunnerError { return .timeout }
        if let provider = error as? AIProviderError {
            switch provider {
            case .missingCredential, .invalidEndpoint, .unsupportedEndpointProtocol, .insecureEndpoint:
                return .invalidConfiguration
            case .outputTruncated:
                // 由 V2 Runtime 缩批恢复；不能触发同一超大请求的通用网络重试。
                return .permanent
            case let .httpStatus(status):
                if status == 401 || status == 403 { return .authentication }
                if status == 429 { return .rateLimited }
                if (500...599).contains(status) { return .serverUnavailable }
                return .permanent
            case .transport:
                return .transientNetwork
            case let .malformedResponse(_, retryable):
                return retryable ? .transientNetwork : .incompatibleResponse
            }
        }
        if let url = error as? URLError {
            if url.code == .cancelled { return .cancelled }
            if url.code == .timedOut { return .timeout }
            return .transientNetwork
        }
        return .permanent
    }
}

public enum AgentIntentClassifier {
    public static func classify(_ text: String) -> AgentTaskIntent {
        let value = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { value.contains($0) } }
        // “推荐索引”是资料库维护任务，不是普通音乐推荐；优先于 discovery 关键词。
        if has(["推荐索引", "索引 v2", "索引v2", "library_index_v2"]) { return .libraryManagement }
        if has(["鉴赏", "赏析", "乐评", "大众评价", "appreciate"]) { return .musicAppreciation }
        if has(["下载", "离线", "torrent", "moviepilot"]) { return .musicDownload }
        if has(["诊断", "为什么", "错误", "失败", "日志", "卡住"]) { return .diagnostics }
        if has(["播放状态", "当前播放状态", "正在播放状态"]) { return .diagnostics }
        if has(["服务器", "同步", "连接", "navidrome", "nas"]) { return .serverManagement }
        if has(["歌单", "playlist"]) { return .playlistManagement }
        if has(["队列", "接下来播放", "替换队列", "清空队列"]) { return .queueManagement }
        if has(["推荐", "相似", "发现", "随便听", "心情", "场景", "开车", "驾驶", "通勤", "提神", "运动", "健身", "跑步", "睡觉", "睡前", "放松", "安静", "有精神", "高能量", "来点", "来几首", "放几首", "想听", "适合", "给我选", "给我挑", "推荐一些", "挑几首", "选几首"]) { return .musicDiscovery }
        if has(["播放", "暂停", "下一首", "上一首", "快进", "循环", "随机播放"]) { return .playbackControl }
        if has(["收藏", "评分", "资料库", "索引 v2", "索引v2"]) { return .libraryManagement }
        if has(["记住", "记忆", "忘记", "技能", "memory", "skill"]) { return .memoryManagement }
        if has(["找歌", "搜索", "查找", "哪首", "哪个专辑", "谁唱的"]) { return .librarySearch }
        return .conversation
    }
}

/// 将文字入口或 UI 显式入口解析为单次任务策略。业务识别只发生在任务创建时，
/// 低层模型循环只消费结构化 policy，不再包含推荐索引等业务分支。
public enum AgentTaskPolicyResolver {
    public static func resolve(
        text: String,
        historyText: String = "",
        explicitIntent: AgentTaskIntent? = nil
    ) -> AgentTaskPolicy {
        let intent = explicitIntent ?? AgentIntentClassifier.classify(text)
        let base = AgentTaskPolicy.policy(for: intent)
        guard intent == .libraryManagement,
              RecommendationIndexTaskRules.requiresCompleteBuild(text: text, historyText: historyText)
        else { return base }

        var budget = base.budget

        // 全库索引属于可持续推进的长任务。
        // 单次 token 完全跟随用户配置的 Provider，不再二次写死 256K / 16K。
        budget.wallClockSeconds = 24 * 60 * 60
        budget.maxInputTokens = AgentTaskBudget.followProvider
        budget.maxOutputTokens = AgentTaskBudget.followProvider

        // 这里只是极端防死循环看门狗。
        // 10,000+ 首库即使缩到最小 8 首 / batch 也不能正常撞到这里。
        budget.maxModelRounds = 10_000

        // 仅诊断，不作为正常终止条件。
        budget.maxNoProgressRounds = 3
        return AgentTaskPolicy(
            intent: intent,
            scopes: base.scopes,
            allowedToolGroups: base.allowedToolGroups,
            allowedPermissions: base.allowedPermissions,
            requiresConfirmationForDestructive: base.requiresConfirmationForDestructive,
            maxRisk: base.maxRisk,
            completion: .indexPendingCountIsZero,
            budget: budget
        )
    }
}

/// Recommendation Index 是普通本地工具服务；这里只负责在任务创建边界选择完成条件，
/// 不参与模型循环、重试、超时或工具分派。
public enum RecommendationIndexTaskRules {
    public static func requiresCompleteBuild(text: String, historyText: String = "") -> Bool {
        let combined = (text + " " + historyText).lowercased()
        let indexMarkers = ["推荐索引", "索引 v2", "索引v2", "index v2", "library_index_v2"]
        let actionMarkers = ["构建", "重建", "继续", "处理", "分类", "一次性", "全部", "完成索引"]
        return indexMarkers.contains(where: combined.contains) && actionMarkers.contains(where: combined.contains)
    }
}

public enum AgentModelAnswerDecision: Sendable, Equatable {
    case accept
    case continueTask(String)
    case fail(String)
}

/// 把工具输出归并为 TaskState。Runner 不再解析工具摘要中的中文数字或业务关键词。
public enum AgentTaskReducer {
    @discardableResult
    public static func apply(
        result: ToolResult,
        descriptor: ToolDescriptor,
        to state: inout AgentTaskState
    ) -> Bool {
        guard result.success else {
            // 失败本身也是新信息（新错误事实）：换策略的判断依据。记录为进展，不当作停滞。
            state.errors.append(result.summary)
            state.errorState = result.summary
            state.recordProgress(action: "\(descriptor.name) 失败：\(result.summary)")
            return false
        }

        // 真实成功工具结果：独立于 Evidence 的事实（memory_list 等不产生 Evidence 但确实执行成功）。
        state.successfulToolNames.append(descriptor.name)
        state.successfulToolCount += 1

        var changed = false
        for (key, value) in result.facts where state.facts[key] != value {
            state.facts[key] = value
            changed = true
        }

        var evidence = result.evidence
        if evidence.isEmpty, let source = evidenceSource(for: descriptor.evidencePolicy) {
            evidence = [AgentEvidence(
                source: source,
                provenance: "tool:\(descriptor.name)",
                confidence: 1,
                claim: result.summary
            )]
        }
        for item in evidence {
            let duplicate = state.evidence.contains {
                $0.source == item.source && $0.provenance == item.provenance && $0.claim == item.claim
            }
            if !duplicate {
                state.evidence.append(item)
                changed = true
            }
        }

        if descriptor.sideEffectPolicy != .none {
            let key = "sideEffect.\(descriptor.sideEffectPolicy.rawValue)"
            if state.facts[key] != "success" {
                state.facts[key] = "success"
            }
            // 每一次真正成功、且未被工作集幂等保护拦截的副作用都是实际进展。
            // 即使完成事实已经是 success，不同参数的合法批量操作也不能被误判为停滞。
            changed = true
        }

        if let payload = result.payload, case let .trackCards(cards) = payload {
            let before = state.candidateIDs.count
            state.candidateIDs.formUnion(cards.map { $0.globalID.description })
            changed = changed || state.candidateIDs.count != before
        }

        if changed {
            state.recordProgress(action: "\(descriptor.name): \(result.summary)")
        } else {
            state.recordNoProgress()
        }
        state.errorState = nil
        return changed
    }

    private static func evidenceSource(for policy: ToolEvidencePolicy) -> AgentEvidenceSource? {
        switch policy {
        case .none: nil
        case .localCatalog: .localCatalog
        case .playbackState: .playbackState
        case .server: .server
        case .externalAPI: .externalAPI
        }
    }
}

/// Runtime 层的确定性完成判定。LLM 的自然语言只是一份候选答案；任务事实未满足时，
/// Runtime 要求继续或明确失败，不能把“看起来完成”当成真实完成。
public enum AgentCompletionEvaluator {
    public static func evaluateModelAnswer(
        _ answer: String,
        state: inout AgentTaskState,
        policy: AgentTaskPolicy,
        repairAttempts: Int
    ) -> AgentModelAnswerDecision {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return repairAttempts == 0
                ? .continueTask("模型返回了空内容。请根据当前任务状态调用获准工具，或给出明确且完整的最终回答。")
                : .fail("模型连续返回空内容，任务未完成。")
        }

        let satisfied: Bool
        let continuation: String
        switch policy.completion {
        case .modelAnswer:
            satisfied = true
            continuation = ""
        case .successfulToolResult:
            // Tool Success ≠ Evidence：只要真实成功执行过工具就算完成条件达成。
            // Evidence 只用于外部事实/大众评价/诊断 provenance，不承担“工具是否执行过”的语义。
            satisfied = state.successfulToolCount > 0
            continuation = "当前任务需要至少一次真实成功的工具结果。请调用相关工具后再依据真实结果回答。"
        case .queueMutation:
            satisfied = state.facts["sideEffect.queue"] == "success"
            continuation = "队列修改尚未得到成功工具结果。请执行获准的队列工具；不要仅用文字声称已经完成。"
        case .playlistMutation:
            satisfied = state.facts["sideEffect.playlist"] == "success"
            continuation = "歌单修改尚未得到成功工具结果。请执行获准的歌单工具；不要仅用文字声称已经完成。"
        case .playbackMutation:
            satisfied = state.facts["sideEffect.playback"] == "success" || state.facts["sideEffect.queue"] == "success"
            continuation = "播放操作尚未得到成功工具结果。请执行获准的播放工具；不要仅用文字声称已经完成。"
        case .indexPendingCountIsZero:
            // 完整完成 = 固定分类待处理 == 0 且 开放语义标签待处理 == 0。
            let pendingFixed = state.facts["recommendation.index.pending"]
            let pendingSemantic = state.facts["recommendation.index.pendingSemantic"] ?? "0"
            satisfied = pendingFixed == "0" && pendingSemantic == "0"
            if pendingFixed == nil {
                continuation = "推荐索引完成事实尚未取得。请先调用 library_index_v2_status；只有真实工具结果显示固定分类与开放语义标签都无待处理项才能结束。"
            } else if pendingFixed != "0" {
                continuation = "推荐索引仍有待分类歌曲（固定分类待处理 \(pendingFixed ?? "?") 首）。请调用 library_index_v2_next_batch 获取当前安全批次，写回后再次调用 next_batch；直到固定分类与开放标签都完成。"
            } else if pendingSemantic != "0" {
                continuation = "推荐索引固定分类已完成，但仍需为 \(pendingSemantic) 首歌曲补充开放语义标签。请继续调用 library_index_v2_next_batch（本批模式 semanticTagsOnly）并写回。"
            } else if state.facts["recommendation.index.nextBatchAvailable"] == "true" {
                continuation = "推荐索引仍有待分类歌曲。请调用 library_index_v2_next_batch 获取完整当前批次，分类后再调用 library_index_v2_write_batch。"
            } else {
                continuation = "推荐索引仍有待分类歌曲。请调用 library_index_v2_next_batch 获取当前安全批次并持续分类写回。"
            }
        case .appreciationWithEvidence:
            let metadataReady = state.facts["appreciation.metadata"] == "available"
            let lyricsResolved = state.facts["appreciation.lyrics"] != nil
            let communityResolved = state.facts["appreciation.community"] != nil
            let requiredSections = ["【已核验事实】", "【模型分析】", "【我的私人数据】", "【大众评价】"]
            let hasRequiredSections = requiredSections.allSatisfy(answer.contains)
            let hasCommunityEvidence = state.facts["appreciation.community"] == "available"
            let communityBoundarySatisfied = hasCommunityEvidence
                || answer.contains("暂无可核验的大众评价数据。")
            let unsupportedCommunityClaim = !hasCommunityEvidence && [
                "大众普遍认为", "广受好评", "听众一致认为",
            ].contains(where: answer.contains)
            satisfied = metadataReady
                && lyricsResolved
                && communityResolved
                && hasRequiredSections
                && communityBoundarySatisfied
                && !unsupportedCommunityClaim
            continuation = "歌曲鉴赏必须先调用 music_appreciate，并以【已核验事实】【模型分析】【我的私人数据】【大众评价】分层回答。没有 Community Evidence 时，大众评价段必须写“暂无可核验的大众评价数据。”"
        }

        if satisfied {
            state.completed = true
            state.completionState = .satisfied
            state.status = .completed
            state.updatedAt = .now
            return .accept
        }
        if repairAttempts == 0 { return .continueTask(continuation) }
        state.completionState = .insufficientEvidence
        state.status = .insufficient
        state.errorState = continuation
        return .fail("任务没有满足确定性完成条件：\(continuation)")
    }
}

/// Runtime 是任务生命周期与策略的拥有者；旧 Runner 暂作为低层模型循环实现。
public actor AgentRuntime {
    private var runningTaskIDs: Set<UUID> = []

    public init() {}

    public func isRunning(_ id: UUID) -> Bool { runningTaskIDs.contains(id) }

    /// 解析并校验工具存在性。已注册工具一律放行（permissive direct execution）；
    /// 只有注册表里不存在的工具才抛错。
    public func authorize(tool name: String, policy: AgentTaskPolicy) throws -> ToolDescriptor {
        guard let descriptor = AgentToolRegistry.descriptor(for: name) else {
            throw AgentRuntimeError.toolOutsidePolicy(name)
        }
        return descriptor
    }

    public func run(
        taskID: UUID,
        userText: String,
        explicitIntent: AgentTaskIntent? = nil,
        policy explicitPolicy: AgentTaskPolicy? = nil,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: AgentRunner.Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentRunner.AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in }
    ) async {
        let historyText = AgentHistoryPolicy.latestUserText(in: history)
        // AppShell 已经为任务记录解析过策略时必须复用同一份值，避免持久化预算/意图
        // 与真正运行的策略因历史上下文不同而分叉。独立调用者仍可省略并在此解析。
        let policy = explicitPolicy ?? AgentTaskPolicyResolver.resolve(
            text: userText,
            historyText: historyText,
            explicitIntent: explicitIntent
        )
        let intent = policy.intent
        let taskState = AgentTaskState(id: taskID, intent: intent, goal: userText)
        runningTaskIDs.insert(taskID)
        defer { runningTaskIDs.remove(taskID) }
        await state(taskState)
        await AgentRunner.run(
            userText: userText,
            provider: provider,
            model: model,
            bridge: bridge,
            catalog: catalog,
            context: context,
            history: history,
            systemService: systemService,
            externalMusicService: externalMusicService,
            intent: intent,
            policy: policy,
            initialTaskState: taskState,
            confirm: confirm,
            emit: emit,
            log: log,
            progress: progress,
            state: state
        )
    }
}
