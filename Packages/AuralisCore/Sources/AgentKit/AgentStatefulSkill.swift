import AIKit
import Foundation

/// Generic extension point retained for future trusted workflows. The
/// Recommendation Index no longer uses this model/tool adapter: its dedicated
/// Runtime owns preparation, the closed transform and commit directly.
public enum AgentSkillStep: Sendable, Equatable {
    case executeTool(name: String, arguments: [String: AIJSONValue])
    case modelOutput(AgentSkillOutputContract)
    case completed(message: String)
}

public enum AgentSkillOutputContract: Sendable, Equatable {
    case structuredData

    var instruction: String { "只返回符合当前 Runtime 契约的结构化数据。" }
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

public protocol AgentStatefulSkill: Sendable {
    var id: String { get }
    var name: String { get }
    var instructions: String { get }
    var privateToolNames: Set<String> { get }

    func canActivate(semantics: AgentRequestSemantics, userText: String, initialTaskState: AgentTaskState?) -> Bool
    func makeRuntime(checkpointJSON: String?) -> any AgentStatefulSkillRuntime
}

/// No built-in workflow is projected through the generic model/tool adapter.
/// Deterministic workflows are routed by `WorkflowEngine` to their dedicated
/// Runtime before the ordinary tool loop starts.
public enum BuiltInStatefulSkillRegistry {
    public static let all: [any AgentStatefulSkill] = []

    public static func activate(
        semantics: AgentRequestSemantics,
        userText: String,
        initialTaskState: AgentTaskState?
    ) -> (any AgentStatefulSkillRuntime)? {
        nil
    }
}

/// Stable public identity for the dedicated Recommendation Index workflow.
public struct RecommendationIndexSkill: Sendable, Equatable {
    public static let id = "recommendation-index"
    public static let legacyIDs: Set<String> = [RecommendationIndexCompatibility.legacySkillID]

    public init() {}
}

/// Compact persisted context for an interrupted index run. Catalog status is
/// authoritative. A resume always increments `checkpointGeneration` and
/// discards any previously in-flight batch authority.
public struct RecommendationIndexCheckpoint: Codable, Sendable, Equatable {
    public var checkpointGeneration: UInt64
    public var currentBatchID: UUID?
    public var currentBatchRevision: UInt64?
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
        checkpointGeneration: UInt64 = 0,
        currentBatchID: UUID? = nil,
        currentBatchRevision: UInt64? = nil,
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
        self.checkpointGeneration = checkpointGeneration
        self.currentBatchID = currentBatchID
        self.currentBatchRevision = currentBatchRevision
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

    private enum CodingKeys: String, CodingKey {
        case checkpointGeneration, currentBatchID, currentBatchRevision
        case total, indexed, pending, pendingSemantic, totalWrittenThisRun
        case lastSuccessfulBatchCount, currentBatchIDs, currentBatchMode
        case preferredBatchSize, status, stoppedReason, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkpointGeneration = try container.decodeIfPresent(UInt64.self, forKey: .checkpointGeneration) ?? 0
        currentBatchID = try container.decodeIfPresent(UUID.self, forKey: .currentBatchID)
        currentBatchRevision = try container.decodeIfPresent(UInt64.self, forKey: .currentBatchRevision)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        indexed = try container.decodeIfPresent(Int.self, forKey: .indexed) ?? 0
        pending = try container.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        pendingSemantic = try container.decodeIfPresent(Int.self, forKey: .pendingSemantic) ?? 0
        totalWrittenThisRun = try container.decodeIfPresent(Int.self, forKey: .totalWrittenThisRun) ?? 0
        lastSuccessfulBatchCount = try container.decodeIfPresent(Int.self, forKey: .lastSuccessfulBatchCount) ?? 0
        currentBatchIDs = try container.decodeIfPresent([String].self, forKey: .currentBatchIDs) ?? []
        currentBatchMode = try container.decodeIfPresent(String.self, forKey: .currentBatchMode)
        preferredBatchSize = try container.decodeIfPresent(Int.self, forKey: .preferredBatchSize) ?? 16
        status = try container.decodeIfPresent(RecommendationIndexWorkflow.State.self, forKey: .status) ?? .readingStatus
        stoppedReason = try container.decodeIfPresent(String.self, forKey: .stoppedReason)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}
