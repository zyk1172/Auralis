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

    /// 只让明确的短后续指令继承上一任务的用户意图。
    /// 新的完整请求和寒暄不会把上一轮（尤其是索引/批处理）带入任务策略，
    /// 避免“你好”被旧任务的 historyText 重新解释成“继续构建”。
    public static func relevantHistoryText(
        for currentUserText: String,
        in history: [AgentChatMessage]
    ) -> String {
        guard isShortFollowUp(currentUserText) else { return "" }
        return latestUserText(in: history)
    }

    /// 把可作为上下文的最终消息转换为 AIMessage。
    /// `.error`、`.toolProgress`、`.confirmation`、`.streaming` 只属于 UI 运行轨迹，
    /// 绝不回灌模型；卡片和操作预览保留为有限的结构化摘要。
    public static func modelMessages(
        from history: [AgentChatMessage],
        limit: Int = 40
    ) -> [AIMessage] {
        modelMessages(from: history, for: nil, limit: limit)
    }

    /// 为当前输入构造会话上下文：短后续指令只取相邻的有限历史，纯寒暄不带旧任务。
    /// 其余完整请求沿用原有投影，以保留正常对话的连续性。
    public static func modelMessages(
        from history: [AgentChatMessage],
        for currentUserText: String?,
        limit: Int = 40
    ) -> [AIMessage] {
        if let currentUserText {
            if isGreeting(currentUserText) { return [] }
            let source = isShortFollowUp(currentUserText)
                ? Array(history.suffix(min(max(limit, 0), 12)))
                : Array(history.suffix(max(limit, 0)))
            return project(source)
        }
        return project(Array(history.suffix(max(limit, 0))))
    }

    private static func project(_ history: [AgentChatMessage]) -> [AIMessage] {
        let separator = "、"
        return history.compactMap { message in
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

    private static func isShortFollowUp(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、；;：: \t\n"))
        return [
            "继续", "继续吧", "第一个", "第一个吧", "就这个", "就它", "这个",
            "播放它", "播放这个", "加入队列", "加入播放队列", "把它播放", "选这个",
        ].contains(normalized)
    }

    private static func isGreeting(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、；;：: \t\n"))
        return [
            "你好", "你好呀", "您好", "嗨", "哈喽", "hello", "hi", "hey",
            "早上好", "晚上好", "晚安", "谢谢", "谢谢你",
        ].contains(normalized)
    }
}
