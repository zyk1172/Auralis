import AIKit
import Foundation

public enum AgentContextFactKind: String, Codable, Sendable {
    case publicAppState
    case trackMetadata
    case lyrics
    case playbackHistory
    case favoritesAndRatings
    case externalDiscovery
    case credential
}

public struct AgentContextFact: Codable, Sendable, Equatable {
    public let kind: AgentContextFactKind
    public let label: String
    public let value: String

    public init(kind: AgentContextFactKind, label: String, value: String) {
        self.kind = kind
        self.label = label
        self.value = value
    }
}

/// 唯一的模型上下文装配边界。调用方交给它结构化事实，而不是拼接任意对象描述。
public enum AgentContextBuilder {
    public static func build(
        systemPrompt: String,
        task: AgentTaskState,
        facts: [AgentContextFact],
        history: [AIMessage],
        recentToolTranscript: [AIMessage] = [],
        permissions: AIPrivacyPermissions,
        capabilities: ModelCapabilities,
        inputBudget: Int
    ) -> [AIMessage] {
        var system = systemPrompt
        system += "\n\n当前任务：\(task.intent.rawValue)；目标：\(task.goal)"
        if !task.completedActions.isEmpty {
            system += "\n已完成动作：" + task.completedActions.suffix(12).joined(separator: "；")
        }
        if !task.evidence.isEmpty {
            let claims = task.evidence.suffix(12).map {
                "[\($0.source.rawValue)/\(String(format: "%.2f", $0.confidence))] \($0.claim)"
            }
            system += "\n已有证据：" + claims.joined(separator: "；")
        }

        let allowedFacts = facts.filter { isAllowed($0.kind, permissions: permissions) }
        if !allowedFacts.isEmpty {
            system += "\n本地事实：" + allowedFacts.map { "\($0.label)=\($0.value)" }.joined(separator: "；")
        }

        var messages = [AIMessage(role: .system, content: system)]
        messages.append(contentsOf: history.filter { $0.role != .system })
        messages.append(contentsOf: legalToolTranscript(recentToolTranscript))

        let reservedOutput = min(capabilities.maxOutputTokens, auralisDefaultMaxOutputTokens)
        let budget = ContextManager.inputBudget(
            capabilities: capabilities,
            requestedInputBudget: inputBudget,
            reservedOutputTokens: reservedOutput
        )
        return ContextManager.trimByTokens(messages, maxTokens: budget)
    }

    public static func taskSummary(_ task: AgentTaskState) -> String {
        let status = task.completed ? "completed" : "active"
        return "intent=\(task.intent.rawValue); status=\(status); actions=\(task.completedActions.count); evidence=\(task.evidence.count); errors=\(task.errors.count)"
    }

    /// 只保留完整的 assistant(tool_calls) → tool(result) 组合，杜绝孤立 tool 消息。
    public static func legalToolTranscript(_ messages: [AIMessage]) -> [AIMessage] {
        var result: [AIMessage] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            guard message.role == .assistant,
                  let calls = message.toolCalls,
                  !calls.isEmpty
            else {
                if message.role != .tool { result.append(message) }
                index += 1
                continue
            }

            let expected = Set(calls.map(\.id))
            var results: [AIMessage] = []
            var cursor = index + 1
            while cursor < messages.count, messages[cursor].role == .tool {
                if let id = messages[cursor].toolCallID, expected.contains(id) {
                    results.append(messages[cursor])
                }
                cursor += 1
            }
            let received = Set(results.compactMap(\.toolCallID))
            if received == expected {
                result.append(message)
                result.append(contentsOf: results)
            }
            index = cursor
        }
        return result
    }

    private static func isAllowed(_ kind: AgentContextFactKind, permissions: AIPrivacyPermissions) -> Bool {
        switch kind {
        case .publicAppState: true
        case .trackMetadata: permissions.allowsMetadata
        case .lyrics: permissions.allowsLyrics
        case .playbackHistory: permissions.allowsPlaybackHistory
        case .favoritesAndRatings: permissions.allowsFavoritesAndRatings
        case .externalDiscovery: permissions.allowsExternalDiscovery
        case .credential: false
        }
    }
}
