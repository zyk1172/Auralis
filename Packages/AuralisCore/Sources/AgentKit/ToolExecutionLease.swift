import Foundation

/// A revocable capability granting one Agent run permission to cross a real
/// mutation boundary. Cancellation is intentionally separate: cancelling a
/// task is best-effort resource cleanup, while revoking this lease is the
/// security decision every mutation sink must honor.
public final class ToolExecutionLease: @unchecked Sendable {
    public let runID: UUID
    public let sessionID: UUID
    public let generation: UInt64

    private let lock = NSLock()
    private var revoked = false

    public init(runID: UUID, sessionID: UUID, generation: UInt64) {
        self.runID = runID
        self.sessionID = sessionID
        self.generation = generation
    }

    /// A fail-closed lease for compatibility callers that did not receive
    /// execution ownership from AgentCoordinator. Read-only tools still work;
    /// ToolRuntime rejects every mutation made with this lease.
    public static func revoked(runID: UUID = UUID()) -> ToolExecutionLease {
        let lease = ToolExecutionLease(runID: runID, sessionID: runID, generation: 0)
        lease.revoke()
        return lease
    }

    public func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }

    /// Synchronous snapshot used at the final side-effect commit point. This
    /// deliberately contains no suspension between the check and the sink.
    public var isValidSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked
    }

    public func isValid() async -> Bool { isValidSnapshot }
}

/// Carries execution ownership through the canonical tool call without
/// widening every stable AgentBridge protocol method. Production mutation
/// sinks use this task-local value for their final pre-commit check.
public enum ToolExecutionContext {
    @TaskLocal public static var lease: ToolExecutionLease?

    /// Calls outside the Agent tool runtime (normal UI actions and legacy
    /// compatibility tests) have no lease and keep their existing behavior.
    /// Canonical model calls always install a lease in ToolRuntime.
    public static var permitsMutationCommit: Bool {
        guard let lease else { return true }
        return lease.isValidSnapshot
    }
}
