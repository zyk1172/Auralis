import Foundation

/// The one transient presentation state for an active assistant run.  This is
/// deliberately separate from persisted chat messages and AgentTaskRecord:
/// activity can change frequently, while the transcript must only retain
/// durable user-visible output.
public struct AssistantRunPresentationState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case thinking
        case streaming
        case usingTool(name: String)
        case workflow(skillID: String, phase: String, detail: String)
        case waitingForConfirmation
        case retrying(message: String)
        case completed
        case failed(message: String)

        public var displayText: String {
            switch self {
            case .thinking:
                "正在处理…"
            case .streaming:
                "正在回复…"
            case let .usingTool(name):
                name
            case let .workflow(_, _, detail):
                detail
            case .waitingForConfirmation:
                "等待确认…"
            case let .retrying(message):
                message
            case .completed:
                "已完成"
            case let .failed(message):
                message
            }
        }
    }

    public let runID: UUID
    public let sessionID: UUID
    public var phase: Phase
    /// Provider-returned reasoning is useful while a run is active, but is
    /// intentionally not part of the persisted conversation transcript.
    public var reasoningText: String

    public init(
        runID: UUID,
        sessionID: UUID,
        phase: Phase,
        reasoningText: String = ""
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.phase = phase
        self.reasoningText = reasoningText
    }
}
