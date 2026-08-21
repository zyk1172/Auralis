import AIKit
import Foundation

/// Agent 会话历史的单一投影策略。
///
/// UI 展示的完整会话历史同时服务于模型上下文与任务恢复。
/// 任务意图判定仍使用单独的“最近完整指令”投影；模型则尽可能看到完整语义对话，
/// 但不重新注入 UI 运行时轨迹（进度、错误、确认、流式半成品）。最终是否因模型
/// 窗口过小而裁剪由 ContextManager 在发送前统一决定。
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

    /// 返回最近一条完整的用户任务指令。
    ///
    /// 连续点击“继续”时，`latestUserText` 只能得到上一条“继续”，下一轮就会
    /// 丢掉最初的任务意图（例如“构建推荐索引 V2”），导致动态工具列表退回普通
    /// 会话。错误、进度和确认消息本来就不是用户消息，因此这里只需跳过寒暄与短
    /// 后续指令，回溯到最近一条可用于恢复任务的完整指令。
    public static func latestSubstantiveUserText(in history: [AgentChatMessage]) -> String {
        for message in history.reversed() where message.role == .user {
            let text = message.messages.compactMap { item in
                if case let .text(value) = item { return value }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isShortFollowUp(text), !isGreeting(text) else { continue }
            return text
        }
        return ""
    }

    /// 只让明确的短后续指令继承上一任务的用户意图。
    /// 新的完整请求和寒暄不会把上一轮（尤其是索引/批处理）带入任务策略，
    /// 避免“你好”被旧任务的 historyText 重新解释成“继续构建”。
    public static func relevantHistoryText(
        for currentUserText: String,
        in history: [AgentChatMessage]
    ) -> String {
        guard isShortFollowUp(currentUserText) else { return "" }
        return latestSubstantiveUserText(in: history)
    }

    /// 把完整会话转换为 AIMessage。`limit` 仅保留给显式调用方；默认不按消息条数截断。
    public static func modelMessages(
        from history: [AgentChatMessage],
        limit: Int = .max
    ) -> [AIMessage] {
        modelMessages(from: history, for: nil, limit: limit)
    }

    /// 为当前输入构造完整会话上下文。无论当前输入是寒暄、短后续还是新任务，
    /// 都不再按消息类型或最近轮数主动丢弃历史；真正超出模型窗口时由发送层裁剪。
    public static func modelMessages(
        from history: [AgentChatMessage],
        for currentUserText: String?,
        limit: Int = .max
    ) -> [AIMessage] {
        _ = currentUserText
        let source = limit == .max ? history : Array(history.suffix(max(limit, 0)))
        return project(source)
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
                    let tracks = cards.enumerated().map { index, card in
                        "\(index + 1).《\(card.title)》-\(card.artistName)（\(card.albumTitle)；id=\(card.globalID.description)）"
                    }.joined(separator: separator)
                    content += "（推荐 \(cards.count) 首：\(tracks)）\n"
                case let .albumCards(cards):
                    let albums = cards.map { "《\($0.title)》-\($0.artistName)（id=\($0.globalID.description)）" }
                    content += "（专辑：\(albums.joined(separator: separator))）\n"
                case let .playlistProposal(name, tracks):
                    content += "（歌单提案「\(name)」，\(tracks.count) 首）\n"
                case let .actionPreview(title, detail):
                    content += "（操作预览：\(title)；\(detail)）\n"
                case .toolProgress, .error, .confirmation, .streaming:
                    // 这些是 UI/runtime 轨迹，不是对话事实。重新送入模型会把旧错误、
                    // 已结束的确认和半成品当作当前指令，尤其容易污染“继续”任务。
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
