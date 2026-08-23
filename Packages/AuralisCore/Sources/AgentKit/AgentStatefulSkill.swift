import AIKit
import Foundation

/// A small generic interface for trusted, stateful workflows. The model may
/// provide data for a step, but the skill owns transitions, validation,
/// recovery and completion.
public enum AgentSkillStep: Sendable, Equatable {
    case executeTool(name: String, arguments: [String: AIJSONValue])
    /// The Runtime has already selected the next transition.  The model only
    /// returns data satisfying this contract; it does not choose a tool or a
    /// state transition.
    case modelOutput(AgentSkillOutputContract)
    case completed(message: String)
}

public enum AgentSkillOutputContract: Sendable, Equatable {
    case recommendationIndexClassification

    var instruction: String {
        switch self {
        case .recommendationIndexClassification:
            return "只输出一个 JSON 对象：{\"items\":[...] }。items 必须恰好覆盖刚取得的当前批次全部 ID 各一次；不要输出 Markdown、说明文字、ACTION 或工具调用。"
        }
    }
}

public struct AgentSkillRecovery: Sendable, Equatable {
    public let message: String
    public let dropCurrentBatch: Bool
    public let compactTranscript: Bool

    public init(message: String, dropCurrentBatch: Bool = false, compactTranscript: Bool = false) {
        self.message = message
        self.dropCurrentBatch = dropCurrentBatch
        self.compactTranscript = compactTranscript
    }
}

public enum AgentSkillToolConsumption: Sendable, Equatable {
    case none
    case compactTranscript
    case fail(String)
}

public enum AgentSkillModelOutput: Sendable, Equatable {
    case executeTool(name: String, arguments: [String: AIJSONValue])
    case retry(AgentSkillRecovery)
}

public protocol AgentStatefulSkillRuntime: AnyObject, Sendable {
    var skillID: String { get }
    var privateToolNames: Set<String> { get }
    /// All tools owned by this runtime, including public read tools and
    /// private state-transition tools. This is used only for transcript
    /// compaction and control-flow validation; it is not a model visibility
    /// grant.
    var ownedToolNames: Set<String> { get }
    var isCompleted: Bool { get }
    var instructions: String { get }
    var facts: [String: String] { get }

    func configure(maxOutputTokens: Int)
    func nextStep() -> AgentSkillStep
    func consumeModelOutput(_ text: String, contract: AgentSkillOutputContract) -> AgentSkillModelOutput
    func prepareToolCall(name: String, arguments: [String: AIJSONValue]) -> [String: AIJSONValue]
    func validateToolCall(name: String, arguments: [String: AIJSONValue]) -> String?
    func consumeToolResult(name: String, result: ToolResult) -> AgentSkillToolConsumption
    func handleToolFailure(name: String, message: String) -> AgentSkillToolConsumption
    func handleProviderFailure(_ error: Error) -> AgentSkillRecovery?
    func handleMalformedCall(name: String) -> AgentSkillRecovery?
    func completionDecision(repairAttempts: Int) -> AgentModelAnswerDecision
    func markCheckpoint(stoppedReason: String?)
    func checkpointJSON() -> String?
}

/// A trusted built-in skill definition. User-created prompt skills are kept
/// outside this registry and cannot make a private tool visible or executable.
public protocol AgentStatefulSkill: Sendable {
    var id: String { get }
    var name: String { get }
    var instructions: String { get }
    var privateToolNames: Set<String> { get }

    func canActivate(semantics: AgentRequestSemantics, userText: String, initialTaskState: AgentTaskState?) -> Bool
    func makeRuntime(checkpointJSON: String?) -> any AgentStatefulSkillRuntime
}

public enum BuiltInStatefulSkillRegistry {
    public static let all: [any AgentStatefulSkill] = [RecommendationIndexV2Skill()]

    public static func activate(
        semantics: AgentRequestSemantics,
        userText: String,
        initialTaskState: AgentTaskState?
    ) -> (any AgentStatefulSkillRuntime)? {
        all.first {
            $0.canActivate(semantics: semantics, userText: userText, initialTaskState: initialTaskState)
        }?.makeRuntime(checkpointJSON: initialTaskState?.facts["recommendation.index.checkpoint"])
    }
}

/// Persisted, compact checkpoint for an interrupted Recommendation Index V2
/// run. The catalog status remains authoritative; this is resume/UI context.
public struct RecommendationIndexCheckpoint: Codable, Sendable, Equatable {
    public var total: Int
    public var indexed: Int
    public var pending: Int
    public var pendingSemantic: Int
    public var totalWrittenThisRun: Int
    public var lastSuccessfulBatchCount: Int
    public var currentBatchIDs: [String]
    public var currentBatchMode: String?
    public var preferredBatchSize: Int
    public var status: RecommendationIndexWorkflow.State
    public var stoppedReason: String?
    public var updatedAt: Date

    public init(
        total: Int = 0,
        indexed: Int = 0,
        pending: Int = 0,
        pendingSemantic: Int = 0,
        totalWrittenThisRun: Int = 0,
        lastSuccessfulBatchCount: Int = 0,
        currentBatchIDs: [String] = [],
        currentBatchMode: String? = nil,
        preferredBatchSize: Int = 16,
        status: RecommendationIndexWorkflow.State = .readingStatus,
        stoppedReason: String? = nil,
        updatedAt: Date = .now
    ) {
        self.total = total
        self.indexed = indexed
        self.pending = pending
        self.pendingSemantic = pendingSemantic
        self.totalWrittenThisRun = totalWrittenThisRun
        self.lastSuccessfulBatchCount = lastSuccessfulBatchCount
        self.currentBatchIDs = currentBatchIDs
        self.currentBatchMode = currentBatchMode
        self.preferredBatchSize = preferredBatchSize
        self.status = status
        self.stoppedReason = stoppedReason
        self.updatedAt = updatedAt
    }
}

public struct RecommendationIndexV2Skill: AgentStatefulSkill {
    public let id = "recommendation-index-v2"
    public let name = "Recommendation Index V2"
    public let instructions = "固定链路由 Skill Runtime 控制：status → next_batch → 当前批次分类 → Runtime write_batch → status。模型只能为刚返回的当前批次生成结构化 JSON 分类；不能声明完成、选择内部工具、跳过批次或自行构造 ID。"
    public let privateToolNames: Set<String> = [
        "library_index_v2_next_batch", "library_index_v2_write_batch",
    ]

    public init() {}

    public func canActivate(
        semantics: AgentRequestSemantics,
        userText: String,
        initialTaskState: AgentTaskState?
    ) -> Bool {
        if semantics.isRecommendationIndexBuild { return true }
        if RecommendationIndexTaskRules.requiresCompleteBuild(text: userText) { return true }
        guard let initialTaskState else { return false }
        return initialTaskState.intent == .libraryManagement
            && RecommendationIndexTaskRules.requiresCompleteBuild(text: initialTaskState.goal)
    }

    public func makeRuntime(checkpointJSON: String?) -> any AgentStatefulSkillRuntime {
        RecommendationIndexV2SkillRuntime(checkpointJSON: checkpointJSON)
    }
}

public final class RecommendationIndexV2SkillRuntime: AgentStatefulSkillRuntime, @unchecked Sendable {
    public let skillID = "recommendation-index-v2"
    public let privateToolNames: Set<String> = RecommendationIndexV2Skill().privateToolNames
    public let ownedToolNames: Set<String> = [
        "library_index_v2_status",
        "library_index_v2_read",
        "library_index_v2_next_batch",
        "library_index_v2_write_batch",
        "library_index_v2_tag_catalog",
    ]
    public let instructions = RecommendationIndexV2Skill().instructions

    private var workflow: RecommendationIndexWorkflow
    private var total = 0
    private var indexed = 0
    private var totalWrittenThisRun = 0
    private var lastSuccessfulBatchCount = 0
    private var stoppedReason: String?
    private var updatedAt = Date.now

    public init(preferredBatchSize: Int = 16, checkpointJSON: String? = nil) {
        let checkpoint = checkpointJSON.flatMap { raw -> RecommendationIndexCheckpoint? in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RecommendationIndexCheckpoint.self, from: data)
        }
        workflow = RecommendationIndexWorkflow(
            preferredBatchSize: checkpoint?.preferredBatchSize ?? preferredBatchSize
        )
        total = checkpoint?.total ?? 0
        indexed = checkpoint?.indexed ?? 0
        totalWrittenThisRun = checkpoint?.totalWrittenThisRun ?? 0
        lastSuccessfulBatchCount = checkpoint?.lastSuccessfulBatchCount ?? 0
        stoppedReason = checkpoint?.stoppedReason
        updatedAt = checkpoint?.updatedAt ?? .now
    }

    public var isCompleted: Bool { workflow.isCompleted }

    public var facts: [String: String] {
        [
            "recommendation.index.total": "\(total)",
            "recommendation.index.indexed": "\(indexed)",
            "recommendation.index.pending": "\(workflow.pending)",
            "recommendation.index.pendingSemantic": "\(workflow.pendingSemantic)",
            "recommendation.index.currentBatchIDs": workflow.currentBatchIDs.joined(separator: ","),
            "recommendation.index.currentBatchMode": workflow.currentBatchMode ?? "",
            "recommendation.index.skillID": skillID,
            "recommendation.index.checkpoint": checkpointJSON() ?? "",
        ]
    }

    public func configure(maxOutputTokens: Int) {
        workflow.configure(maxOutputTokens: maxOutputTokens)
        touch()
    }

    public func nextStep() -> AgentSkillStep {
        switch workflow.state {
        case .readingStatus, .verifying:
            return .executeTool(name: "library_index_v2_status", arguments: [:])
        case .fetchingBatch:
            return .executeTool(name: "library_index_v2_next_batch", arguments: [
                "limit": .number(Double(workflow.preferredBatchSize)),
            ])
        case .classifyingBatch, .writingBatch:
            return .modelOutput(.recommendationIndexClassification)
        case .completed:
            return .completed(message: "推荐索引 V2 已完成。")
        }
    }

    public func prepareToolCall(name: String, arguments: [String: AIJSONValue]) -> [String: AIJSONValue] {
        var arguments = arguments
        switch name {
        case "library_index_v2_status":
            workflow.beginStatusRead()
        case "library_index_v2_next_batch":
            workflow.beginBatchFetch()
            arguments["limit"] = .number(Double(workflow.preferredBatchSize))
        case "library_index_v2_write_batch":
            workflow.beginWritingBatch()
        default:
            break
        }
        touch()
        return arguments
    }

    public func consumeModelOutput(_ text: String, contract: AgentSkillOutputContract) -> AgentSkillModelOutput {
        switch contract {
        case .recommendationIndexClassification:
            guard let arguments = Self.classificationArguments(from: text),
                  workflow.writeIssue(arguments: arguments) == nil else {
                return .retry(malformedClassificationRecovery())
            }
            return .executeTool(name: "library_index_v2_write_batch", arguments: arguments)
        }
    }

    public func validateToolCall(name: String, arguments: [String: AIJSONValue]) -> String? {
        guard name == "library_index_v2_write_batch" else { return nil }
        return workflow.writeIssue(arguments: arguments)
    }

    public func consumeToolResult(name: String, result: ToolResult) -> AgentSkillToolConsumption {
        guard result.success else {
            return handleToolFailure(name: name, message: result.summary)
        }
        switch name {
        case "library_index_v2_status":
            total = Int(result.facts["recommendation.index.total"] ?? "0") ?? total
            indexed = Int(result.facts["recommendation.index.indexed"] ?? "0") ?? indexed
            _ = workflow.applyStatus(
                pending: Int(result.facts["recommendation.index.pending"] ?? "0") ?? 0,
                pendingSemantic: Int(result.facts["recommendation.index.pendingSemantic"] ?? "0") ?? 0
            )
        case "library_index_v2_next_batch":
            _ = workflow.applyBatch(
                ids: result.facts["recommendation.index.currentBatchIDs"]?.split(separator: ",").map(String.init) ?? [],
                mode: result.facts["recommendation.index.currentBatchMode"] ?? "full",
                pending: Int(result.facts["recommendation.index.pending"] ?? "0") ?? 0,
                pendingSemantic: Int(result.facts["recommendation.index.pendingSemantic"] ?? "0") ?? 0
            )
        case "library_index_v2_write_batch":
            lastSuccessfulBatchCount = workflow.currentBatchIDs.count
            totalWrittenThisRun += lastSuccessfulBatchCount
            _ = workflow.applyWrite(
                pending: Int(result.facts["recommendation.index.pending"] ?? "0") ?? 0,
                pendingSemantic: Int(result.facts["recommendation.index.pendingSemantic"] ?? "0") ?? 0
            )
            touch()
            return .compactTranscript
        default:
            break
        }
        touch()
        return .none
    }

    public func handleToolFailure(name: String, message: String) -> AgentSkillToolConsumption {
        if name == "library_index_v2_write_batch" {
            workflow.retryCurrentBatch()
            touch(stoppedReason: message)
            return .none
        }
        if name == "library_index_v2_status" || name == "library_index_v2_next_batch" {
            touch(stoppedReason: message)
            return .fail("推荐索引 V2 固定链路执行失败：\(message)")
        }
        return .none
    }

    public func handleProviderFailure(_ error: Error) -> AgentSkillRecovery? {
        if isOutputTruncated(error) {
            let limit = workflow.shrinkBatch()
            let message = "本批结构化输出不完整，未执行任何写入；已将 Recommendation Index V2 批次缩小为 \(limit) 首。请重新获取完整当前批次后只提交结构化 write_batch。"
            touch(stoppedReason: message)
            return AgentSkillRecovery(message: message, dropCurrentBatch: true, compactTranscript: true)
        }
        guard AgentFailureClassifier.classify(error).isRetryable else { return nil }
        switch workflow.recoverFromProviderFailure() {
        case let .retryCurrentBatch(limit):
            let message = "原生工具协议暂时不可用；本轮没有执行任何工具调用。未写入的当前批次已丢弃，并缩小为 \(limit) 首；请保持原协议恢复，继续使用原生工具协议重新获取批次并分类写回。"
            touch(stoppedReason: message)
            return AgentSkillRecovery(message: message, dropCurrentBatch: true, compactTranscript: true)
        case .resumeFromStatus:
            let message = "原生工具协议暂时不可用；本轮没有执行任何工具调用。此前成功写入的索引状态已保留，请保持原协议恢复，继续使用原生工具协议从 status 恢复。"
            touch(stoppedReason: message)
            return AgentSkillRecovery(message: message, compactTranscript: true)
        }
    }

    public func handleMalformedCall(name: String) -> AgentSkillRecovery? {
        guard name == "library_index_v2_write_batch" else { return nil }
        return malformedClassificationRecovery()
    }

    private func malformedClassificationRecovery() -> AgentSkillRecovery {
        let limit = workflow.shrinkBatch()
        let message = "本批结构化分类无效，未执行任何写入；已将 Recommendation Index V2 批次缩小为 \(limit) 首。Runtime 会重新获取当前批次，请只返回完整 JSON 分类对象。"
        touch(stoppedReason: message)
        return AgentSkillRecovery(message: message, dropCurrentBatch: true, compactTranscript: true)
    }

    public func completionDecision(repairAttempts: Int) -> AgentModelAnswerDecision {
        workflow.completionDecision(repairAttempts: repairAttempts)
    }

    public func markCheckpoint(stoppedReason: String?) {
        touch(stoppedReason: stoppedReason)
    }

    public func checkpointJSON() -> String? {
        let checkpoint = RecommendationIndexCheckpoint(
            total: total,
            indexed: indexed,
            pending: workflow.pending,
            pendingSemantic: workflow.pendingSemantic,
            totalWrittenThisRun: totalWrittenThisRun,
            lastSuccessfulBatchCount: lastSuccessfulBatchCount,
            currentBatchIDs: workflow.currentBatchIDs,
            currentBatchMode: workflow.currentBatchMode,
            preferredBatchSize: workflow.preferredBatchSize,
            status: workflow.state,
            stoppedReason: stoppedReason,
            updatedAt: updatedAt
        )
        guard let data = try? JSONEncoder().encode(checkpoint) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func touch(stoppedReason: String? = nil) {
        if let stoppedReason { self.stoppedReason = stoppedReason }
        updatedAt = .now
    }

    private func isOutputTruncated(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else { return false }
        if case .outputTruncated = providerError { return true }
        return false
    }

    private static func classificationArguments(from text: String) -> [String: AIJSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? AIJSONValue(jsonString: json) else { return nil }
        switch value {
        case let .object(object): return object
        case let .array(items): return ["items": .array(items)]
        default: return nil
        }
    }
}
