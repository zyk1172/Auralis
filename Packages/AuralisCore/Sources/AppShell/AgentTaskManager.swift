import AgentKit
import Foundation

/// Agent 任务状态。
public enum AgentTaskStatus: String, Codable, Sendable {
    case queued
    case running
    case waitingForTool
    case waitingForModel
    case completed
    case failed
    case cancelled
    /// App 在任务运行中被系统杀掉 / 关闭，重启后标记为中断。
    case interrupted
    /// 达到安全保护上限后暂停。
    case paused
}

/// 单个 Agent 任务记录（持久化，供重启后标记 interrupted 与审计）。
public struct AgentTaskRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let conversationID: UUID?
    public let createdAt: Date
    public var status: AgentTaskStatus
    public var currentStep: String
    public var toolSteps: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var errorSummary: String?
    public var updatedAt: Date
    public var intent: AgentTaskIntent?
    public var goal: String?
    public var budget: AgentTaskBudget?
    public var completedActions: [String]?
    public var noProgressRounds: Int?

    public init(
        id: UUID = UUID(),
        conversationID: UUID?,
        createdAt: Date = .now,
        status: AgentTaskStatus = .running,
        currentStep: String = "正在理解请求",
        toolSteps: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        errorSummary: String? = nil,
        updatedAt: Date = .now,
        intent: AgentTaskIntent? = nil,
        goal: String? = nil,
        budget: AgentTaskBudget? = nil,
        completedActions: [String]? = [],
        noProgressRounds: Int? = 0
    ) {
        self.id = id
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.status = status
        self.currentStep = currentStep
        self.toolSteps = toolSteps
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.errorSummary = errorSummary
        self.updatedAt = updatedAt
        self.intent = intent
        self.goal = goal
        self.budget = budget
        self.completedActions = completedActions
        self.noProgressRounds = noProgressRounds
    }
}

/// 长期存活的任务仓库：由 AppModel 单例持有，不依赖任何 SwiftUI View 生命周期。
///
/// 任务状态落盘到 JSON（Application Support）；App 重启后把运行中的任务标记为
/// interrupted。已完成的写操作不会被自动重复执行——AgentLoop 只在用户重新发起
/// 请求时才会执行工具，而每个工具调用都先经用户确认 / 上下文重新构建。
/// 运行在 MainActor 上与 AgentCoordinator 一致，写盘为轻量小 JSON，频率很低。
@MainActor
public final class AgentTaskStore {
    private let fileURL: URL
    private var records: [UUID: AgentTaskRecord]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.records = Self.load(from: fileURL) ?? [:]
    }

    public var all: [AgentTaskRecord] {
        records.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(_ id: UUID) -> AgentTaskRecord? { records[id] }

    @discardableResult
    public func start(conversationID: UUID?, intent: AgentTaskIntent? = nil, goal: String? = nil, budget: AgentTaskBudget? = nil) -> AgentTaskRecord {
        let record = AgentTaskRecord(conversationID: conversationID, intent: intent, goal: goal, budget: budget)
        records[record.id] = record
        try? persist()
        return record
    }

    public func update(
        _ id: UUID,
        status: AgentTaskStatus? = nil,
        step: String? = nil,
        toolSteps: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        error: String? = nil,
        completedActions: [String]? = nil,
        noProgressRounds: Int? = nil
    ) {
        guard var record = records[id] else { return }
        if let status { record.status = status }
        if let step, !step.isEmpty { record.currentStep = step }
        if let toolSteps { record.toolSteps = toolSteps }
        if let inputTokens { record.inputTokens = inputTokens }
        if let outputTokens { record.outputTokens = outputTokens }
        if let error { record.errorSummary = error }
        if let completedActions { record.completedActions = completedActions }
        if let noProgressRounds { record.noProgressRounds = noProgressRounds }
        record.updatedAt = .now
        records[id] = record
        try? persist()
    }

    /// App 启动时调用：把上次仍处于运行中的任务标记为 interrupted。
    public func markInterruptedOnLaunch() {
        var changed = false
        for (id, var record) in records {
            if record.status == .running || record.status == .waitingForTool || record.status == .waitingForModel {
                record.status = .interrupted
                record.errorSummary = "App 在任务运行中被关闭，已标记为中断。"
                record.updatedAt = .now
                records[id] = record
                changed = true
            }
        }
        if changed { try? persist() }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Array(records.values))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    private static func load(from url: URL) -> [UUID: AgentTaskRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let list = try? JSONDecoder().decode([AgentTaskRecord].self, from: data)
        return list.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
    }
}