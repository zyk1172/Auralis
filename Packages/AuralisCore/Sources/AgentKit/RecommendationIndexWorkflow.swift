import Foundation

/// Runtime-owned state presentation for Recommendation Index. The closed Skill
/// owns preparation, classification validation and commit; this value no longer
/// exposes model-controlled write instructions.
public struct RecommendationIndexWorkflow: Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case readingStatus
        case fetchingBatch
        case loadingCanonicalTags
        case gatheringEvidence
        case classifyingBatch
        case retrying
        case writingBatch
        case verifying
        case completed
    }

    public enum ProviderFailureRecovery: Sendable, Equatable {
        /// The model had received a batch but had not committed it. The batch
        /// must be fetched again after shrinking; otherwise the next request
        /// can refer to a payload that is no longer present in the transcript.
        case retryCurrentBatch(limit: Int)
        /// A previous write already completed, so only the catalog facts need
        /// to be read again. Never shrink a batch that is no longer pending.
        case resumeFromStatus
    }

    public private(set) var state: State
    public private(set) var pending = 0
    public private(set) var currentBatchIDs: [String] = []
    public private(set) var preferredBatchSize: Int
    public private(set) var retryCount = 0

    public init(preferredBatchSize: Int = 16) {
        self.state = .readingStatus
        self.preferredBatchSize = max(1, preferredBatchSize)
    }

    public var isCompleted: Bool { state == .completed }

    public var hasCurrentBatch: Bool { !currentBatchIDs.isEmpty }

    public mutating func configure(maxOutputTokens: Int) {
        preferredBatchSize = RecommendationIndexBatchPolicy.recommendedLimit(
            maxOutputTokens: maxOutputTokens
        )
    }

    public mutating func beginStatusRead() {
        guard !isCompleted else { return }
        state = .readingStatus
    }

    @discardableResult
    public mutating func applyStatus(pending: Int) -> State {
        self.pending = max(0, pending)
        currentBatchIDs = []
        state = self.pending == 0 ? .completed : .fetchingBatch
        return state
    }

    public mutating func beginBatchFetch() {
        guard !isCompleted else { return }
        state = .fetchingBatch
    }

    @discardableResult
    public mutating func applyBatch(
        ids: [String],
        pending: Int
    ) -> State {
        self.pending = max(0, pending)
        currentBatchIDs = ids
        state = ids.isEmpty ? .verifying : .classifyingBatch
        return state
    }

    public mutating func beginWritingBatch() {
        guard !isCompleted else { return }
        state = .writingBatch
    }

    /// Keep the fetched batch intact when the write payload is structurally
    /// valid enough to retry but the runtime rejects its contents. The next
    /// Provider turn must remain a classification turn; it must not regain
    /// control of status/next routing.
    public mutating func retryCurrentBatch() {
        guard !isCompleted else { return }
        state = currentBatchIDs.isEmpty ? .fetchingBatch : .classifyingBatch
    }

    @discardableResult
    public mutating func applyWrite(pending: Int) -> State {
        self.pending = max(0, pending)
        currentBatchIDs = []
        state = .verifying
        return state
    }

    public mutating func beginVerification() {
        guard !isCompleted else { return }
        state = .verifying
    }

    /// Recover from a transient Provider failure without changing the wire
    /// protocol. A current, uncommitted batch is discarded and retried at a
    /// smaller boundary; after a successful write, verification resumes from
    /// the catalog instead of repeating the write.
    @discardableResult
    public mutating func recoverFromProviderFailure() -> ProviderFailureRecovery {
        if hasCurrentBatch {
            return .retryCurrentBatch(limit: shrinkBatch())
        }
        beginStatusRead()
        return .resumeFromStatus
    }

    @discardableResult
    public mutating func verify(pending: Int) -> State {
        self.pending = max(0, pending)
        state = self.pending == 0 ? .completed : .fetchingBatch
        return state
    }

    /// Shrink only the next requested batch after a malformed/truncated model
    /// response. This is recovery, not a normal model capability limit.
    @discardableResult
    public mutating func shrinkBatch() -> Int {
        preferredBatchSize = max(1, preferredBatchSize / 2)
        currentBatchIDs = []
        retryCount += 1
        state = .fetchingBatch
        return preferredBatchSize
    }
}
