import AIKit
import Foundation

/// 上下文管理：控制真正发送给模型的对话规模与工具结果大小。
///
/// ConversationStore / SessionStore 保存完整历史；这里只负责「发送前裁剪」：
/// - 限制对话消息条数（保留 system + 最近若干条，避免截断配对中的 tool 消息）；
/// - 限制单条工具结果回灌文本长度（避免长清单撑爆上下文）；
/// - 提供中英混排的 token 估算，供裁剪与预算展示使用。
public enum ContextManager {
    /// 单条工具结果回灌给模型的文本上限。
    public static let maxToolResultCharacters = 2_400
    /// 按消息条数裁剪的上限（保留给旧式 `trim` 与测试使用）。
    public static let maxConversationMessages = 40
    /// 曲库索引 / 分类歌曲清单允许回灌模型的更大上限（供模型了解曲库后推荐）。
    public static let maxIndexCharacters = 60_000
    /// 按 token 预算裁剪的默认预算。
    /// 面向 100 万 token 上下文模型（如 DeepSeek V4 Flash）设得比较宽，
    /// 长任务（建歌单 → 逐批加歌 → 验证）不会因上下文被过早截断而丢失关键 ID。
    public static let maxContextTokens = 24_000

    /// 为输入计算真实可用预算：上下文窗口必须为输出、工具 schema 与协议开销留空间。
    public static func inputBudget(
        capabilities: ModelCapabilities,
        requestedInputBudget: Int,
        reservedOutputTokens: Int
    ) -> Int {
        let protocolReserve = 1_024
        let available = capabilities.maxContextTokens - reservedOutputTokens - protocolReserve
        return max(2_048, min(requestedInputBudget, available))
    }

    /// 裁剪对话：始终保留首条 system；截取末尾若干条。
    /// 若截取后以 `.tool` 消息开头（失去配对的 assistant tool_calls，会被 API 拒绝），
    /// 继续前移丢弃，直到第一条不再是 `.tool`。
    public static func trim(
        _ conversation: [AIMessage],
        maxMessages: Int = ContextManager.maxConversationMessages
    ) -> [AIMessage] {
        guard conversation.count > maxMessages else { return conversation }
        guard let system = conversation.first else { return Array(conversation.suffix(maxMessages)) }
        var tail = Array(conversation.dropFirst().suffix(maxMessages - 1))
        while tail.first?.role == .tool { tail.removeFirst() }
        return [system] + tail
    }

    /// 按 token 预算裁剪对话：从最新消息向前累加，直到达到预算；
    /// 始终保留首条 system；若裁剪后以连续 `.tool` 消息开头（其 assistant tool_calls 已被裁掉），
    /// 整组丢弃，保证 API 上下文的 tool 配对始终合法。
    public static func trimByTokens(
        _ conversation: [AIMessage],
        maxTokens: Int = ContextManager.maxContextTokens
    ) -> [AIMessage] {
        guard conversation.count > 2 else { return conversation }
        let system = conversation.first { $0.role == .system } ?? conversation[0]
        var kept: [AIMessage] = []
        var tokens = 0
        for message in conversation.reversed() {
            // 系统提示单独保留并最后加回，不占用普通预算。
            if message.role == .system { continue }
            tokens += estimatedTokens(message.content)
            if tokens > maxTokens, !kept.isEmpty { break }
            kept.insert(message, at: 0)
        }
        // 若首条被裁掉，把开头的连续 .tool 消息整组丢弃（其 assistant tool_calls 已丢失）。
        var index = 0
        while index < kept.count, kept[index].role == .tool { index += 1 }
        if index > 0 { kept.removeFirst(index) }
        kept.insert(system, at: 0)
        return kept
    }

    /// 截断工具结果文本，保留开头并注明被截断。
    public static func truncateToolResult(
        _ text: String,
        limit: Int = ContextManager.maxToolResultCharacters
    ) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        return "\(head)…（结果过长已截断，共 \(text.count) 字）"
    }

    /// 估算字符串 token 数（中英混排近似：非 ASCII 约 1 token/字，ASCII 约 1 token/4 字符）。
    public static func estimatedTokens(_ text: String) -> Int {
        var ascii = 0
        var nonAscii = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonAscii += 1 }
        }
        return nonAscii + ascii / 4 + 1
    }
}
