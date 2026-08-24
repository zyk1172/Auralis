import Domain
import Foundation

/// A redacted, run-scoped observation emitted by the Recommendation Index
/// Runtime. It is deliberately data-only: raw Provider output, prompts and
/// credentials never enter this event.
public struct RecommendationIndexExecutionEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case routeSelected
        case started
        case phaseChanged
        case statusLoaded
        case batchPrepared
        case classificationStarted
        case classificationCompleted
        case classificationFailed
        case commitStarted
        case commitCompleted
        case retrying
        case completed
        case cancelled
        case failed
    }

    public let kind: Kind
    public let runID: UUID
    public let sessionID: UUID
    public let serverID: String?
    public let phase: RecommendationIndexWorkflow.State
    public let batchID: UUID?
    public let batchRevision: UInt64?
    public let batchSize: Int
    public let attempt: Int
    public let totalTracks: Int?
    public let indexedTracks: Int?
    public let pendingTracks: Int?
    public let pendingSemanticTracks: Int?
    public let durationMilliseconds: Int?
    public let message: String?

    public init(
        kind: Kind,
        runID: UUID,
        sessionID: UUID,
        serverID: ServerID?,
        phase: RecommendationIndexWorkflow.State,
        batchID: UUID? = nil,
        batchRevision: UInt64? = nil,
        batchSize: Int = 0,
        attempt: Int = 0,
        totalTracks: Int? = nil,
        indexedTracks: Int? = nil,
        pendingTracks: Int? = nil,
        pendingSemanticTracks: Int? = nil,
        durationMilliseconds: Int? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.runID = runID
        self.sessionID = sessionID
        self.serverID = serverID?.rawValue
        self.phase = phase
        self.batchID = batchID
        self.batchRevision = batchRevision
        self.batchSize = max(0, batchSize)
        self.attempt = max(0, attempt)
        self.totalTracks = totalTracks
        self.indexedTracks = indexedTracks
        self.pendingTracks = pendingTracks
        self.pendingSemanticTracks = pendingSemanticTracks
        self.durationMilliseconds = durationMilliseconds
        self.message = message
    }

    /// Compact key/value form for unified logging. Values are intentionally
    /// bounded and contain no model response body.
    public var compactSummary: String {
        var fields = [
            "event=\(kind.rawValue)",
            "run_id=\(runID.uuidString)",
            "session_id=\(sessionID.uuidString)",
            "phase=\(phase.rawValue)",
            "batch_size=\(batchSize)",
            "attempt=\(attempt)",
        ]
        if let serverID { fields.append("server_id=\(serverID)") }
        if let batchID { fields.append("batch_id=\(batchID.uuidString)") }
        if let batchRevision { fields.append("revision=\(batchRevision)") }
        if let totalTracks { fields.append("total=\(totalTracks)") }
        if let indexedTracks { fields.append("indexed=\(indexedTracks)") }
        if let pendingTracks { fields.append("pending=\(pendingTracks)") }
        if let pendingSemanticTracks { fields.append("pending_semantic=\(pendingSemanticTracks)") }
        if let durationMilliseconds { fields.append("duration_ms=\(durationMilliseconds)") }
        if let message {
            let clipped = String(message.prefix(240)).replacingOccurrences(of: "\n", with: " ")
            fields.append("message=\(clipped)")
        }
        return fields.joined(separator: " ")
    }
}
