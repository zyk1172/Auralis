import Foundation

/// 一条跨会话记忆：主人告诉 Agent 的个人信息（如「我叫小猫」「我喜欢周杰伦」）。
/// 由 `memory_save` / `memory_list` / `memory_delete` / `memory_clear` 工具维护，
/// 并在每次会话开始时注入系统提示词，让 Agent 跨会话记得主人。
public struct AgentMemoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String
    public var updatedAt: Date

    public init(key: String, value: String, updatedAt: Date = .now) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// 一个简单 skill：一段可复用的指令，由 Agent 用 `skill_create` 存成本地 skill 文件，
/// 之后用 `skill_list` / `skill_read` 读取并使用。
public struct AgentSkillEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var instructions: String
    public var createdAt: Date

    public init(name: String, instructions: String, createdAt: Date = .now) {
        self.name = name
        self.instructions = instructions
        self.createdAt = createdAt
    }

    /// 列表展示用的简短摘要（取第一行，去空白）。
    public var summary: String {
        let firstLine = instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（无描述）" : trimmed
    }
}
