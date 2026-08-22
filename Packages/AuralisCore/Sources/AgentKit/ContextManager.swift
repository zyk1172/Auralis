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

    /// 按消息条数裁剪。原生 tool call 及其 tool results 同样按原子组取舍，
    /// 避免旧调用方也构造出孤立 `.tool`。
    public static func trim(
        _ conversation: [AIMessage],
        maxMessages: Int = ContextManager.maxConversationMessages
    ) -> [AIMessage] {
        guard conversation.count > maxMessages else { return conversation }
        guard !conversation.isEmpty else { return [] }
        var keptIndices: Set<Int> = [0]
        var remaining = max(maxMessages - 1, 0)
        for unit in conversationUnits(conversation).reversed() {
            guard unit.indices.count <= remaining else { continue }
            keptIndices.formUnion(unit.indices)
            remaining -= unit.indices.count
        }
        return conversation.indices.compactMap { keptIndices.contains($0) ? conversation[$0] : nil }
    }

    /// 按 token 预算裁剪对话：始终保留首条 system 与当前用户问题，其余从最新历史回填。
    /// 原生 Function Calling 的 `assistant(tool_calls) + tool results` 被当作不可分割的原子组：
    /// 要么完整保留，要么完整丢弃，绝不向 Provider 发送孤立 `.tool` 消息。
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
        let systemIndex = conversation.firstIndex(where: { $0 == system }) ?? 0
        let requiredUserIndex = requiredUser.flatMap { required in
            conversation.lastIndex(where: { $0 == required })
        }
        var keptIndices: Set<Int> = [systemIndex]
        // 当前用户问题必须在任何历史消息之前预留预算。Runner 会先用
        // `canFitCurrentUser` 拒绝放不下的配置，因此这里不会产生超预算请求。
        var tokens = estimatedTokens(system)
        if let requiredUser, let requiredUserIndex {
            keptIndices.insert(requiredUserIndex)
            tokens += estimatedTokens(requiredUser)
        }
        for unit in conversationUnits(conversation).reversed() {
            guard !unit.indices.contains(where: keptIndices.contains) else { continue }
            guard tokens + unit.tokens <= maxTokens else { continue }
            tokens += unit.tokens
            keptIndices.formUnion(unit.indices)
        }
        return conversation.indices.compactMap { keptIndices.contains($0) ? conversation[$0] : nil }
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

    private struct ConversationUnit {
        let indices: [Int]
        let tokens: Int
    }

    /// 将历史拆成可独立裁剪的单元。孤立 tool result 本来就不合法，因此不会进入任何单元。
    private static func conversationUnits(_ conversation: [AIMessage]) -> [ConversationUnit] {
        var units: [ConversationUnit] = []
        var index = conversation.startIndex

        while index < conversation.endIndex {
            let message = conversation[index]
            guard message.role != .system else {
                index = conversation.index(after: index)
                continue
            }

            guard message.role == .assistant,
                  let calls = message.toolCalls,
                  !calls.isEmpty
            else {
                // `.tool` 只能由前面的 assistant tool_calls 组消费；任何没有配对的 tool
                // 都不能回灌给 OpenAI-compatible Provider。
                if message.role != .tool {
                    units.append(.init(indices: [index], tokens: estimatedTokens(message)))
                }
                index = conversation.index(after: index)
                continue
            }

            let expectedIDs = Set(calls.map(\.id))
            var resultIndices: [Int] = []
            var receivedIDs: Set<String> = []
            var cursor = conversation.index(after: index)
            while cursor < conversation.endIndex, conversation[cursor].role == .tool {
                guard let id = conversation[cursor].toolCallID,
                      expectedIDs.contains(id),
                      receivedIDs.insert(id).inserted
                else { break }
                resultIndices.append(cursor)
                cursor = conversation.index(after: cursor)
            }

            // assistant 发出的每一个 call 都必须有对应 tool result；不完整的历史同样不能保留。
            if receivedIDs == expectedIDs {
                let indices = [index] + resultIndices
                units.append(.init(
                    indices: indices,
                    tokens: indices.reduce(0) { $0 + estimatedTokens(conversation[$1]) }
                ))
                index = cursor
            } else {
                index = conversation.index(after: index)
            }
        }
        return units
    }
}
