// SPDX-License-Identifier: GPL-3.0-only
import AIKit
import Foundation

/// 记录每次 Agent 运行实际向模型上下文披露过哪些隐私类别。
///
/// 用途：持久化助手正文时打上类别标记（`AgentChatMessage.disclosureCategories`），
/// 之后用户撤销某个类别（如关闭歌词外发）时，历史投影只需丢弃沾过该类别
/// 数据的正文，普通解释与知识回答可以继续重放。
///
/// 数据在生产路径由 `ToolRuntime.executeMeasured` 在工具执行成功后写入；
/// 键是 runID，运行结束由调用方清理，不持久化、不含任何正文内容。
public actor AgentRunDisclosureRegistry {
    public static let shared = AgentRunDisclosureRegistry()

    private var categoriesByRun: [UUID: Set<AIPrivacyCategory>] = [:]

    public init() {}

    /// 工具执行成功后登记一次披露。同一类别重复登记是幂等的。
    /// 工具结果本身已按权限脱敏（如 allowsLyrics=false 时 lyrics_get 不回正文），
    /// 所以只有对应类别当前允许时才计数——结果被掩码即没有发生披露。
    public func record(runID: UUID, toolName: String, permissions: AIPrivacyPermissions) {
        guard let category = AgentRunDisclosureRegistry.category(forToolName: toolName),
              permissions.allows(category) else { return }
        categoriesByRun[runID, default: []].insert(category)
    }

    public func record(runID: UUID, categories: Set<AIPrivacyCategory>) {
        categoriesByRun[runID, default: []].formUnion(categories)
    }

    /// 当前运行到目前为止披露过的类别；没有任何受限披露时返回空集合。
    public func categories(runID: UUID) -> Set<AIPrivacyCategory> {
        categoriesByRun[runID] ?? []
    }

    /// 运行结束清理。必须在每次 run 收尾处调用，避免 runID 无限累积。
    public func clear(runID: UUID) {
        categoriesByRun[runID] = nil
    }

    /// Primary result category. Metadata tools also carry metadata; favorite
    /// flags are tracked conservatively by ToolRuntime when enabled.
    public static func category(forToolName toolName: String) -> AIPrivacyCategory? {
        switch toolName {
        case "lyrics_get": .lyrics
        case "library_get_recently_played", "stats_get_top_items": .playbackHistory
        case "library_get_starred": .favoritesAndRatings
        case "web_search", "web_fetch": .externalDiscovery
        default: toolName.hasPrefix("library_") || toolName.hasPrefix("search_") ? .metadata : nil
        }
    }
}
