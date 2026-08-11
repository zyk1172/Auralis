import AIKit
import Domain
import Foundation
import LocalCatalog

/// 用户请求的粗粒度意图。意图只决定能力边界，不承载领域实现细节。
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

/// 工具副作用风险。运行时以此为最终门禁，不能只相信模型看见的 schema。
public enum AgentRisk: Int, Codable, Comparable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 任务获准使用的能力域。与 UI 或具体工具名解耦。
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
    public var wallClockSeconds: TimeInterval
    public var maxInputTokens: Int
    public var maxOutputTokens: Int
    public var maxModelRounds: Int
    public var maxNoProgressRounds: Int
    public var maxRepeatedToolPattern: Int

    public init(
        wallClockSeconds: TimeInterval = 6 * 60,
        maxInputTokens: Int = 96_000,
        maxOutputTokens: Int = 8_192,
        maxModelRounds: Int = 24,
        maxNoProgressRounds: Int = 3,
        // The working-set guard asks the model to stop after three duplicate
        // search results. Allow one final attempted call to be blocked and
        // returned as evidence so the model can produce its closing answer;
        // the generic runtime guard remains the final backstop after that.
        maxRepeatedToolPattern: Int = 4
    ) {
        self.wallClockSeconds = wallClockSeconds
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxModelRounds = maxModelRounds
        self.maxNoProgressRounds = maxNoProgressRounds
        self.maxRepeatedToolPattern = maxRepeatedToolPattern
    }
}

public enum AgentCompletionPredicate: Codable, Equatable, Sendable {
    case modelAnswer
    case verifiedToolResult
    case queueMutation
    case playlistMutation
    case playbackMutation
    case indexPendingCountIsZero
    case appreciationWithEvidence
}

/// 每个任务的能力与安全策略。Runner/模型返回任何工具名后都必须再次经过这里。
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

    public func authorizes(_ descriptor: ToolDescriptor) -> Bool {
        guard allowedToolGroups.contains(descriptor.group),
              allowedPermissions.contains(descriptor.permission)
        else { return false }
        return Self.risk(for: descriptor.permission) <= maxRisk
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
            return .init(intent: intent, scopes: [.catalogRead, .serverRead], allowedToolGroups: [.catalog, .server], allowedPermissions: read, completion: .verifiedToolResult)
        case .playbackControl:
            return .init(intent: intent, scopes: [.catalogRead, .playbackWrite], allowedToolGroups: [.catalog, .playback], allowedPermissions: write, maxRisk: .medium, completion: .playbackMutation)
        case .musicDiscovery:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .queueWrite, .externalRead], allowedToolGroups: [.catalog, .server, .playback], allowedPermissions: write, maxRisk: .medium, completion: .verifiedToolResult)
        case .queueManagement:
            return .init(intent: intent, scopes: [.catalogRead, .playbackWrite, .queueWrite], allowedToolGroups: [.catalog, .playback], allowedPermissions: destructive, maxRisk: .high, completion: .queueMutation)
        case .playlistManagement:
            return .init(intent: intent, scopes: [.catalogRead, .playlistWrite], allowedToolGroups: [.catalog, .playlist], allowedPermissions: destructive, maxRisk: .high, completion: .playlistMutation)
        case .libraryManagement:
            return .init(intent: intent, scopes: [.catalogRead, .annotationWrite], allowedToolGroups: [.catalog, .annotation], allowedPermissions: write, maxRisk: .medium, completion: .verifiedToolResult)
        case .serverManagement:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .serverWrite], allowedToolGroups: [.catalog, .server], allowedPermissions: destructive, maxRisk: .high, completion: .verifiedToolResult)
        case .diagnostics:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .diagnosticsRead], allowedToolGroups: [.catalog, .server], allowedPermissions: read, completion: .verifiedToolResult)
        case .musicAppreciation:
            var budget = AgentTaskBudget()
            budget.maxOutputTokens = 12_288
            return .init(intent: intent, scopes: [.catalogRead, .externalRead], allowedToolGroups: [.catalog], allowedPermissions: read, completion: .appreciationWithEvidence, budget: budget)
        case .musicDownload:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .downloadWrite], allowedToolGroups: [.catalog, .server, .download], allowedPermissions: write, maxRisk: .medium, completion: .verifiedToolResult)
        case .memoryManagement:
            return .init(intent: intent, scopes: [.memoryRead, .memoryWrite], allowedToolGroups: [.memory], allowedPermissions: destructive, maxRisk: .high, completion: .verifiedToolResult)
        }
    }
}

public enum AgentEvidenceSource: String, Codable, Sendable {
    case localCatalog
    case playbackState
    case server
    case externalAPI
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

/// 与音乐领域工作集分离的通用任务状态。领域状态可增量附加，不再成为主循环本身。
public struct AgentTaskState: Codable, Identifiable, Sendable {
    public let id: UUID
    public let intent: AgentTaskIntent
    public let goal: String
    public var facts: [String: String]
    public var evidence: [AgentEvidence]
    public var candidateIDs: Set<String>
    public var completedActions: [String]
    public var errors: [String]
    public var progress: AgentTaskProgress
    public var completed: Bool
    public var startedAt: Date
    public var recentToolSignatures: [String]
    public var repeatedToolPatternCount: Int

    public init(id: UUID = UUID(), intent: AgentTaskIntent, goal: String, startedAt: Date = .now) {
        self.id = id
        self.intent = intent
        self.goal = goal
        self.facts = [:]
        self.evidence = []
        self.candidateIDs = []
        self.completedActions = []
        self.errors = []
        self.progress = AgentTaskProgress(lastProgressAt: startedAt)
        self.completed = false
        self.startedAt = startedAt
        self.recentToolSignatures = []
        self.repeatedToolPatternCount = 0
    }

    public mutating func recordProgress(action: String? = nil, at date: Date = .now) {
        if let action, !action.isEmpty { completedActions.append(action) }
        progress.noProgressRounds = 0
        progress.lastProgressAt = date
    }

    public mutating func recordNoProgress() { progress.noProgressRounds += 1 }

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
    }

    public func budgetViolation(policy: AgentTaskPolicy, now: Date = .now) -> AgentRuntimeError? {
        if now.timeIntervalSince(startedAt) > policy.budget.wallClockSeconds { return .wallClockBudgetExceeded }
        if progress.inputTokens > policy.budget.maxInputTokens { return .inputTokenBudgetExceeded }
        if progress.outputTokens > policy.budget.maxOutputTokens { return .outputTokenBudgetExceeded }
        if progress.modelRounds >= policy.budget.maxModelRounds { return .modelRoundBudgetExceeded }
        if progress.noProgressRounds >= policy.budget.maxNoProgressRounds { return .noProgress }
        if repeatedToolPatternCount > policy.budget.maxRepeatedToolPattern { return .repeatedToolPattern }
        return nil
    }
}

public enum AgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case toolOutsidePolicy(String)
    case wallClockBudgetExceeded
    case inputTokenBudgetExceeded
    case outputTokenBudgetExceeded
    case modelRoundBudgetExceeded
    case noProgress
    case repeatedToolPattern

    public var errorDescription: String? {
        switch self {
        case let .toolOutsidePolicy(name): "工具 \(name) 不在当前任务获准范围内。"
        case .wallClockBudgetExceeded: "任务已达到总运行时间预算。"
        case .inputTokenBudgetExceeded: "任务已达到输入 token 预算。"
        case .outputTokenBudgetExceeded: "任务已达到输出 token 预算。"
        case .modelRoundBudgetExceeded: "任务已达到模型轮次预算。"
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
            case .missingCredential, .invalidEndpoint:
                return .invalidConfiguration
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
        if has(["鉴赏", "赏析", "乐评", "大众评价", "appreciate"]) { return .musicAppreciation }
        if has(["下载", "离线", "torrent", "moviepilot"]) { return .musicDownload }
        if has(["诊断", "为什么", "错误", "失败", "日志", "卡住"]) { return .diagnostics }
        if has(["服务器", "同步", "连接", "navidrome", "nas"]) { return .serverManagement }
        if has(["歌单", "playlist"]) { return .playlistManagement }
        if has(["队列", "接下来播放", "替换队列", "清空队列"]) { return .queueManagement }
        if has(["推荐", "相似", "发现", "随便听", "心情", "场景"]) { return .musicDiscovery }
        if has(["播放", "暂停", "下一首", "上一首", "快进", "循环", "随机播放"]) { return .playbackControl }
        if has(["收藏", "评分", "资料库", "索引 v2", "索引v2"]) { return .libraryManagement }
        if has(["记住", "记忆", "忘记", "技能", "memory", "skill"]) { return .memoryManagement }
        if has(["找歌", "搜索", "查找", "哪首", "哪个专辑", "谁唱的"]) { return .librarySearch }
        return .conversation
    }
}

/// Runtime 是任务生命周期与策略的拥有者；旧 Runner 暂作为低层模型循环实现。
public actor AgentRuntime {
    private var runningTaskIDs: Set<UUID> = []

    public init() {}

    public func isRunning(_ id: UUID) -> Bool { runningTaskIDs.contains(id) }

    public func authorize(tool name: String, policy: AgentTaskPolicy) throws -> ToolDescriptor {
        guard let descriptor = AgentToolRegistry.descriptor(for: name), policy.authorizes(descriptor) else {
            throw AgentRuntimeError.toolOutsidePolicy(name)
        }
        return descriptor
    }

    public func run(
        taskID: UUID,
        userText: String,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: AgentRunner.Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentRunner.AgentProgress) async -> Void = { _ in }
    ) async {
        let intent = AgentIntentClassifier.classify(userText)
        let policy = AgentTaskPolicy.policy(for: intent)
        runningTaskIDs.insert(taskID)
        defer { runningTaskIDs.remove(taskID) }
        await AgentRunner.run(
            userText: userText,
            provider: provider,
            model: model,
            bridge: bridge,
            catalog: catalog,
            context: context,
            history: history,
            systemService: systemService,
            intent: intent,
            policy: policy,
            confirm: confirm,
            emit: emit,
            log: log,
            progress: progress
        )
    }
}
