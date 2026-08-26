import Domain
import Foundation

/// Authoritative runtime state for the Recommendation Index. Catalog counts
/// describe persisted data; this value describes whether a live Skill run
/// exists. Keeping the two separate prevents the model from inferring
/// "running in the background" from `pendingTracks > 0`.
public enum RecommendationIndexExecutionState: Sendable, Equatable, Codable {
    public struct Running: Sendable, Equatable, Codable {
        public let runID: UUID
        public let sessionID: UUID
        public let phase: RecommendationIndexWorkflow.State
        public let batchID: UUID?
        public let batchRevision: UInt64?
        public let batchTrackIDs: [String]
        public let attempt: Int
        public let totalTracks: Int
        public let indexedTracks: Int
        public let pendingTracks: Int
        public let currentBatchSize: Int
        public let processedThisRun: Int
        public let message: String?
        public let startedAt: Date
        public let updatedAt: Date

        public init(
            runID: UUID,
            sessionID: UUID,
            phase: RecommendationIndexWorkflow.State,
            batchID: UUID? = nil,
            batchRevision: UInt64? = nil,
            batchTrackIDs: [String] = [],
            attempt: Int = 0,
            totalTracks: Int = 0,
            indexedTracks: Int = 0,
            pendingTracks: Int = 0,
            currentBatchSize: Int = 0,
            processedThisRun: Int = 0,
            message: String? = nil,
            startedAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.runID = runID
            self.sessionID = sessionID
            self.phase = phase
            self.batchID = batchID
            self.batchRevision = batchRevision
            self.batchTrackIDs = batchTrackIDs
            self.attempt = attempt
            self.totalTracks = totalTracks
            self.indexedTracks = indexedTracks
            self.pendingTracks = pendingTracks
            self.currentBatchSize = currentBatchSize
            self.processedThisRun = processedThisRun
            self.message = message
            self.startedAt = startedAt
            self.updatedAt = updatedAt
        }
    }

    case idle
    case running(Running)
    case failed(runID: UUID, message: String, at: Date)
    case completed(runID: UUID, indexedTracks: Int, totalTracks: Int, at: Date)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var userFacingSummary: String {
        switch self {
        case .idle:
            return "当前没有推荐索引任务运行"
        case let .running(snapshot):
            let phase = Self.phaseText(snapshot.phase)
            let attempt = snapshot.attempt > 0 ? "（第 \(snapshot.attempt) 次尝试）" : ""
            if snapshot.totalTracks > 0 {
                return "索引任务正在运行：已完成 \(snapshot.indexedTracks) / \(snapshot.totalTracks)，\(phase)\(attempt)"
            }
            return "索引任务正在运行：\(phase)\(attempt)"
        case let .failed(_, message, _):
            return "最近一次推荐索引任务失败：\(message)"
        case let .completed(_, indexedTracks, totalTracks, _):
            return "最近一次推荐索引任务已完成：\(indexedTracks) / \(totalTracks)"
        }
    }

    private static func phaseText(_ phase: RecommendationIndexWorkflow.State) -> String {
        switch phase {
        case .readingStatus: return "正在读取状态"
        case .fetchingBatch: return "正在准备批次"
        case .loadingCanonicalTags: return "正在检查已有标签"
        case .gatheringEvidence: return "正在补充歌曲证据"
        case .classifyingBatch: return "正在分类当前批次"
        case .retrying: return "正在重试当前批次"
        case .writingBatch: return "正在保存分类"
        case .verifying: return "正在核验写入结果"
        case .completed: return "已完成"
        }
    }
}

/// Coordinator-scoped execution state. A run must claim a server before it
/// starts; another session may still chat or play music, but a second index
/// run for the same server cannot commit concurrently.
public actor RecommendationIndexExecutionRegistry {
    private var states: [String: RecommendationIndexExecutionState] = [:]

    public init() {}

    @discardableResult
    public func begin(
        serverID: ServerID?,
        runID: UUID,
        sessionID: UUID,
        startedAt: Date = .now
    ) -> Bool {
        let key = Self.key(for: serverID)
        if case let .running(snapshot) = states[key], snapshot.runID != runID {
            return false
        }
        states[key] = .running(.init(
            runID: runID,
            sessionID: sessionID,
            phase: .readingStatus,
            startedAt: startedAt
        ))
        return true
    }

    public func update(
        serverID: ServerID?,
        runID: UUID,
        sessionID: UUID,
        phase: RecommendationIndexWorkflow.State,
        batchID: UUID? = nil,
        batchRevision: UInt64? = nil,
        batchTrackIDs: [String] = [],
        attempt: Int = 0,
        totalTracks: Int,
        indexedTracks: Int,
        pendingTracks: Int,
        currentBatchSize: Int,
        processedThisRun: Int,
        message: String? = nil
    ) {
        let key = Self.key(for: serverID)
        guard case let .running(previous) = states[key],
              previous.runID == runID,
              previous.sessionID == sessionID else { return }
        states[key] = .running(.init(
            runID: runID,
            sessionID: sessionID,
            phase: phase,
            batchID: batchID,
            batchRevision: batchRevision,
            batchTrackIDs: batchTrackIDs,
            attempt: attempt,
            totalTracks: totalTracks,
            indexedTracks: indexedTracks,
            pendingTracks: pendingTracks,
            currentBatchSize: currentBatchSize,
            processedThisRun: processedThisRun,
            message: message,
            startedAt: previous.startedAt,
            updatedAt: .now
        ))
    }

    public func complete(
        serverID: ServerID?,
        runID: UUID,
        totalTracks: Int,
        indexedTracks: Int
    ) {
        let key = Self.key(for: serverID)
        guard isOwned(by: runID, at: key) else { return }
        states[key] = .completed(
            runID: runID,
            indexedTracks: indexedTracks,
            totalTracks: totalTracks,
            at: .now
        )
    }

    public func fail(serverID: ServerID?, runID: UUID, message: String) {
        let key = Self.key(for: serverID)
        guard isOwned(by: runID, at: key) else { return }
        states[key] = .failed(runID: runID, message: message, at: .now)
    }

    public func stop(serverID: ServerID?, runID: UUID) {
        let key = Self.key(for: serverID)
        guard isOwned(by: runID, at: key) else { return }
        states[key] = .idle
    }

    public func snapshot(serverID: ServerID?) -> RecommendationIndexExecutionState {
        states[Self.key(for: serverID)] ?? .idle
    }

    private func isOwned(by runID: UUID, at key: String) -> Bool {
        guard case let .running(snapshot) = states[key] else { return false }
        return snapshot.runID == runID
    }

    private static func key(for serverID: ServerID?) -> String {
        serverID?.rawValue ?? "__no-server__"
    }
}
