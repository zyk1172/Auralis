import AIKit
import Foundation
import LocalCatalog

/// Deterministic state machine for Recommendation Index V2.
///
/// The model still decides how to classify a returned batch, but it cannot
/// decide whether the workflow is complete. Completion is based on status
/// facts reported by the catalog after each write.
public struct RecommendationIndexWorkflow: Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case readingStatus
        case fetchingBatch
        case classifyingBatch
        case writingBatch
        case verifying
        case completed
    }

    public private(set) var state: State
    public private(set) var pending = 0
    public private(set) var pendingSemantic = 0
    public private(set) var currentBatchIDs: [String] = []
    public private(set) var currentBatchMode: String?
    public private(set) var preferredBatchSize: Int
    public private(set) var retryCount = 0

    public init(preferredBatchSize: Int = 16) {
        self.state = .readingStatus
        self.preferredBatchSize = max(1, preferredBatchSize)
    }

    public var isCompleted: Bool { state == .completed }

    public mutating func configure(maxOutputTokens: Int) {
        preferredBatchSize = RecommendationIndexV2BatchPolicy.recommendedLimit(
            maxOutputTokens: maxOutputTokens
        )
    }

    public mutating func beginStatusRead() {
        guard !isCompleted else { return }
        state = .readingStatus
    }

    @discardableResult
    public mutating func applyStatus(pending: Int, pendingSemantic: Int) -> State {
        self.pending = max(0, pending)
        self.pendingSemantic = max(0, pendingSemantic)
        currentBatchIDs = []
        currentBatchMode = nil
        state = self.pending == 0 && self.pendingSemantic == 0 ? .completed : .fetchingBatch
        return state
    }

    public mutating func beginBatchFetch() {
        guard !isCompleted else { return }
        state = .fetchingBatch
    }

    @discardableResult
    public mutating func applyBatch(
        ids: [String],
        mode: String,
        pending: Int,
        pendingSemantic: Int
    ) -> State {
        self.pending = max(0, pending)
        self.pendingSemantic = max(0, pendingSemantic)
        currentBatchIDs = ids
        currentBatchMode = mode
        state = ids.isEmpty ? .verifying : .classifyingBatch
        return state
    }

    public mutating func beginWritingBatch() {
        guard !isCompleted else { return }
        state = .writingBatch
    }

    @discardableResult
    public mutating func applyWrite(pending: Int, pendingSemantic: Int) -> State {
        self.pending = max(0, pending)
        self.pendingSemantic = max(0, pendingSemantic)
        currentBatchIDs = []
        currentBatchMode = nil
        state = .verifying
        return state
    }

    /// Validate the batch identity before the write reaches ToolRuntime or the
    /// catalog. This is workflow state, not a generic working-set concern.
    public func writeIssue(arguments: [String: AIJSONValue]) -> String? {
        guard let value = arguments["items"] ?? arguments["itemsJSON"] else {
            return "缺少必填 items"
        }
        let raw: String
        if case let .string(string) = value {
            raw = string
        } else {
            raw = value.jsonString
        }
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let items = try? JSONDecoder().decode([RecommendationIndexV2Classification].self, from: data)
        else {
            return "items 不是完整的结构化 JSON 数组"
        }
        guard !currentBatchIDs.isEmpty else {
            return "没有刚刚由 library_index_v2_next_batch 返回的当前批次"
        }
        let ids = items.map(\.id)
        guard ids.count == Set(ids).count,
              Set(ids) == Set(currentBatchIDs),
              ids.count == currentBatchIDs.count
        else {
            return "items 必须恰好覆盖当前批次的每个真实 ID 一次"
        }
        if currentBatchMode == "semanticTagsOnly",
           items.contains(where: { $0.mode != "semanticTagsOnly" }) {
            return "当前批次为 semanticTagsOnly，每项必须使用 mode=semanticTagsOnly"
        }
        if currentBatchMode == "full",
           items.contains(where: { $0.mode == "semanticTagsOnly" }) {
            return "当前批次为 full，不能伪装成 semanticTagsOnly"
        }
        return nil
    }

    /// The model may provide prose, but it cannot declare this workflow done.
    /// The decision is based solely on the facts observed by this state machine.
    public func completionDecision(repairAttempts: Int) -> AgentModelAnswerDecision {
        guard !isCompleted else { return .accept }

        let continuation: String
        if pending == 0, pendingSemantic == 0 {
            continuation = "推荐索引的最终核验尚未完成。请调用 library_index_v2_status，确认固定分类与开放语义标签都为 0 后再结束。"
        } else if pending > 0 {
            continuation = "推荐索引仍有待分类歌曲（固定分类待处理 \(pending) 首）。请调用 library_index_v2_next_batch 获取当前安全批次，分类后调用 library_index_v2_write_batch；直到固定分类与开放标签都完成。"
        } else {
            continuation = "推荐索引固定分类已完成，但仍需为 \(pendingSemantic) 首歌曲补充开放语义标签。请继续调用 library_index_v2_next_batch（本批模式 semanticTagsOnly）并写回。"
        }
        if repairAttempts == 0 {
            return .continueTask(continuation)
        }
        return .fail("任务没有满足确定性完成条件：\(continuation)")
    }

    public mutating func beginVerification() {
        guard !isCompleted else { return }
        state = .verifying
    }

    @discardableResult
    public mutating func verify(pending: Int, pendingSemantic: Int) -> State {
        self.pending = max(0, pending)
        self.pendingSemantic = max(0, pendingSemantic)
        state = self.pending == 0 && self.pendingSemantic == 0 ? .completed : .fetchingBatch
        return state
    }

    /// Shrink only the next requested batch after a malformed/truncated model
    /// response. This is recovery, not a normal model capability limit.
    @discardableResult
    public mutating func shrinkBatch() -> Int {
        preferredBatchSize = max(1, preferredBatchSize / 2)
        currentBatchIDs = []
        currentBatchMode = nil
        retryCount += 1
        state = .fetchingBatch
        return preferredBatchSize
    }
}
