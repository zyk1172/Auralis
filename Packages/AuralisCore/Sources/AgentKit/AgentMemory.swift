// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AIKit
import Foundation

/// 记忆来源：决定撤销权限或删除实体时如何精确撤回。
/// 旧数据没有这个字段，解码时按 `.userAsserted` 处理（memory_save 最初的
/// 设计意图就是记录用户明确分享的信息）；派生记忆必须显式标注来源。
public enum AgentMemorySource: String, Codable, Sendable, Hashable {
    /// 用户明确陈述、由 memory_save 记录的长期信息。
    case userAsserted
    /// 从工具结果/曲库数据派生的推断（如常听风格、收藏偏好）。
    case derivedFromTools
    /// 来自外部内容（网页、歌词等不可信来源）。外部内容不能把临时指令
    /// 升级成用户长期偏好；此类记忆在注入时附带来源说明。
    case external
}

/// 一条跨会话记忆：主人告诉 Agent 的个人信息（如「我叫小猫」「我喜欢周杰伦」）。
/// 由 `memory_save` / `memory_list` / `memory_delete` / `memory_clear` 工具维护，
/// 并在每次会话开始时注入系统提示词，让 Agent 跨会话记得主人。
public struct AgentMemoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let value: String
    public let updatedAt: Date
    /// 首次记录时间；旧数据解码时回落为 updatedAt。
    public let createdAt: Date
    /// 数据来源。注入与撤回都以此为准，而不是凭正文猜测。
    public let source: AgentMemorySource
    /// 该记忆隶属的披露类别（如歌词、播放历史、收藏评分）。
    /// nil 表示普通偏好，不受类别开关过滤；非 nil 时，对应类别被撤销后
    /// 该记忆不再注入模型上下文。
    public let category: AIPrivacyCategory?
    /// 可选有效期；过期记忆不再注入，但仍保留在本地直到用户删除。
    public let expiresAt: Date?
    public let disclosureCategories: Set<AIPrivacyCategory>?

    public init(
        key: String,
        value: String,
        updatedAt: Date = .now,
        createdAt: Date? = nil,
        source: AgentMemorySource = .userAsserted,
        category: AIPrivacyCategory? = nil,
        expiresAt: Date? = nil,
        disclosureCategories: Set<AIPrivacyCategory>? = nil
    ) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.createdAt = createdAt ?? updatedAt
        self.source = source
        self.category = category
        self.expiresAt = expiresAt
        self.disclosureCategories = disclosureCategories
    }

    private enum CodingKeys: String, CodingKey {
        case key, value, updatedAt, createdAt, source, category, expiresAt, disclosureCategories
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decode(String.self, forKey: .value)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
        source = try container.decodeIfPresent(AgentMemorySource.self, forKey: .source) ?? .userAsserted
        category = try container.decodeIfPresent(AIPrivacyCategory.self, forKey: .category)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        disclosureCategories = try container.decodeIfPresent(Set<AIPrivacyCategory>.self, forKey: .disclosureCategories)
    }

    /// 过期判断与注入判断分开：过期仅表示不再主动召回。
    public func isExpired(at now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// 该记忆在当前权限下是否允许进入模型上下文。
    public func isDisclosable(under permissions: AIPrivacyPermissions, at now: Date = .now) -> Bool {
        guard !isExpired(at: now) else { return false }
        if category == nil, disclosureCategories?.isEmpty != false {
            if source == .external { return permissions.allowsExternalDiscovery }
            if source == .derivedFromTools { return permissions.allowPersistedAssistantText }
        }
        guard disclosureCategories?.allSatisfy({ permissions.allows($0) }) != false else { return false }
        guard let category else { return true }
        return permissions.allows(category)
    }
}

/// 技能来源：用户主动沉淀的流程可以复用；外部内容转化来的指令需要
/// 在召回时保留来源说明，不能因为进了 system 提示就升级成权威指令。
public enum AgentSkillSource: String, Codable, Sendable, Hashable {
    case userCreated
    case external
}

/// 一个简单 skill：一段可复用的指令，由 Agent 用 `skill_create` 存成本地 skill 文件，
/// 之后用 `skill_list` / `skill_read` 读取并使用。
public struct AgentSkillEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let instructions: String
    public let createdAt: Date
    /// 旧 skill 文件没有来源元数据，读取时按 `.userCreated` 处理。
    public let source: AgentSkillSource
    public let disclosureCategories: Set<AIPrivacyCategory>?

    public init(name: String, instructions: String, createdAt: Date = .now, source: AgentSkillSource = .userCreated, disclosureCategories: Set<AIPrivacyCategory>? = nil) {
        self.name = name
        self.instructions = instructions
        self.createdAt = createdAt
        self.source = source
        self.disclosureCategories = disclosureCategories
    }

    private enum CodingKeys: String, CodingKey { case name, instructions, createdAt, source, disclosureCategories }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decode(String.self, forKey: .instructions)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decodeIfPresent(AgentSkillSource.self, forKey: .source) ?? .userCreated
        disclosureCategories = try c.decodeIfPresent(Set<AIPrivacyCategory>.self, forKey: .disclosureCategories)
    }

    public func isDisclosable(under permissions: AIPrivacyPermissions) -> Bool {
        if source == .external, disclosureCategories?.isEmpty != false { return permissions.allowsExternalDiscovery }
        return disclosureCategories?.allSatisfy { permissions.allows($0) } ?? true
    }

    /// 列表展示用的简短摘要（取第一行，去空白）。
    public var summary: String {
        let firstLine = instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（无描述）" : trimmed
    }
}
