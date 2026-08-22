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
    /// 按 token 预算裁剪的模型总上下文上限。当前模型最大 256K；实际输入还会由
    /// `inputBudget` 为 16K 输出和协议字段预留空间。
    public static let maxContextTokens = 256_000
    /// 消息角色、JSON 包装、原生工具字段等不在正文估算中的固定协议预留。
    public static let protocolReserveTokens = 1_024

    /// 为输入计算真实可用预算：上下文窗口必须为输出、工具 schema 与协议开销留空间。
    public static func inputBudget(
        capabilities: ModelCapabilities,
        requestedInputBudget: Int,
        reservedOutputTokens: Int
    ) -> Int {
        let available = max(0, capabilities.maxContextTokens - reservedOutputTokens - protocolReserveTokens)
        // 极小上下文模型可能连旧的 2K 下限也容纳不下；此时宁可返回真实剩余值，
        // 也不能为了满足人为下限而制造一个超过 Provider 窗口的请求。
        return min(max(0, requestedInputBudget), available)
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
        maxTokens: Int = ContextManager.maxContextTokens,
        preservingUserText: String? = nil
    ) -> [AIMessage] {
        guard !conversation.isEmpty else { return [] }
        let system = conversation.first { $0.role == .system } ?? conversation[0]
        let requiredUser = preservingUserText.flatMap { text in
            conversation.last { $0.role == .user && $0.content == text }
        }
        var kept: [AIMessage] = []
        // System prompt 是实际输入的一部分，必须先占用预算；旧实现把它无条件加回，
        // 在工具清单较长时会使裁剪后的请求仍超过 Provider 上下文窗口。
        var tokens = estimatedTokens(system)
        for message in conversation.reversed() {
            // 系统提示单独保留并最后加回；其成本已经计入 `tokens`。
            if message.role == .system { continue }
            if let requiredUser, message == requiredUser {
                guard tokens + estimatedTokens(message) <= maxTokens else { continue }
                tokens += estimatedTokens(message)
                kept.insert(message, at: 0)
                continue
            }
            let messageTokens = estimatedTokens(message)
            guard tokens + messageTokens <= maxTokens else { break }
            tokens += messageTokens
            kept.insert(message, at: 0)
        }
        // 若首条被裁掉，把开头的连续 .tool 消息整组丢弃（其 assistant tool_calls 已丢失）。
        var index = 0
        while index < kept.count, kept[index].role == .tool { index += 1 }
        if index > 0 { kept.removeFirst(index) }
        kept.insert(system, at: 0)
        return kept
    }

    /// 当前用户问题和首条系统提示是否能同时进入模型上下文。
    /// 不能时继续裁剪历史没有意义，且绝不能发送一条没有用户问题的请求。
    public static func canFitCurrentUser(
        _ conversation: [AIMessage],
        userText: String,
        maxTokens: Int
    ) -> Bool {
        guard let system = conversation.first(where: { $0.role == .system }),
              let user = conversation.last(where: { $0.role == .user && $0.content == userText })
        else { return false }
        return estimatedTokens(system) + estimatedTokens(user) <= maxTokens
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

    /// 计算消息正文及原生工具调用参数的近似输入成本。角色/JSON 固定开销由
    /// `protocolReserveTokens` 统一预留，避免在每条消息重复猜测。
    public static func estimatedTokens(_ message: AIMessage) -> Int {
        var total = estimatedTokens(message.content)
        if let toolCallID = message.toolCallID { total += estimatedTokens(toolCallID) }
        if let name = message.name { total += estimatedTokens(name) }
        for call in message.toolCalls ?? [] {
            total += estimatedTokens(call.id)
            total += estimatedTokens(call.name)
            total += estimatedTokens(call.arguments)
        }
        return total
    }

    /// 估算原生工具 Schema 的输入成本。Schema 不是消息正文，但同样会占用模型
    /// 上下文；对 16K/32K 的中转或本地模型尤其重要。
    public static func estimatedTokens(_ tools: [AIToolDefinition]) -> Int {
        tools.reduce(0) { total, tool in
            total
                + estimatedTokens(tool.name)
                + estimatedTokens(tool.description)
                + estimatedTokens(tool.parametersJSON ?? "")
        }
    }
}
