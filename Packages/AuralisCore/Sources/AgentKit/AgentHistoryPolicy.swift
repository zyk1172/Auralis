import AIKit
import Foundation

/// Agent 会话历史的单一投影策略。
///
/// UI 展示需要保留错误、进度和确认消息，但这些消息不是用户意图，也不是模型事实。
/// 它们不能重新进入下一轮模型上下文，更不能参与下一条任务的 Intent 判定。
public enum AgentHistoryPolicy {
    /// TaskPolicy 只继承最后一条用户消息；不会扫描助手回答、错误或更早任务。
    public static func latestUserText(in history: [AgentChatMessage]) -> String {
        guard let message = history.last(where: { $0.role == .user }) else { return "" }
        return message.messages.compactMap { item in
            if case let .text(value) = item { return value }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把可作为上下文的最终消息转换为 AIMessage。
    /// `.error`、`.toolProgress`、`.confirmation`、`.streaming` 只属于 UI 运行轨迹，
    /// 绝不回灌模型；卡片和操作预览保留为有限的结构化摘要。
    public static func modelMessages(
        from history: [AgentChatMessage],
        limit: Int = 40
    ) -> [AIMessage] {
        let separator = "、"
        return history.suffix(max(limit, 0)).compactMap { message in
            var content = ""
            for item in message.messages {
                switch item {
                case let .text(text):
                    content += text + "\n"
                case let .trackCards(cards):
                    content += "（推荐 \(cards.count) 首：\(cards.map(\.title).joined(separator: separator))）\n"
                case let .albumCards(cards):
                    content += "（专辑：\(cards.map(\.title).joined(separator: separator))）\n"
                case let .playlistProposal(name, tracks):
                    content += "（歌单提案「\(name)」，\(tracks.count) 首）\n"
                case let .actionPreview(title, detail):
                    content += "（操作预览：\(title)；\(detail)）\n"
                case .toolProgress, .error, .confirmation, .streaming:
                    continue
                }
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AIMessage(
                role: message.role == .user ? .user : .assistant,
                content: trimmed
            )
        }
    }
}
