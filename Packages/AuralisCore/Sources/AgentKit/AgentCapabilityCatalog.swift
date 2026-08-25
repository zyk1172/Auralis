import Foundation
import LocalCatalog

// MARK: - Agent Capability Catalog
//
// Capability ≠ Tool ≠ Workflow。
//
// - Tool：ToolRuntime 暴露给模型的原子操作（canonical AgentToolRegistry）。
// - Workflow：系统如何完成复杂事情（Stateful Skill / RecommendationIndexSkillRuntime）。
// - Capability：系统能完成的高层任务，是模型自省"我能做什么"的权威来源。
//
// 本目录是唯一的 canonical capability 源：System Prompt 能力摘要、capabilities_get、
// 诊断/UI 都从这里生成，避免多份静态列表漂移。它建立在真实 ToolRegistry / Workflow /
// Skill 之上，不复制 ToolRegistry，也不是第二套 Tool Registry。
//
// 关键原则：
// - 模型看不到 runtime-only tool（如 recommendation_index_commit）≠ 没有该能力；
//   capability 明确标注 executionOwner，模型据此正确自省。
// - requiresProvider 表示"作为 AI 任务是否需要 Provider 做自然语言规划"；
//   执行本身始终由 ToolRuntime / Trusted Runtime 负责，二者不混为一谈。

public enum AgentCapabilityExecutionOwner: String, Sendable, Equatable, Codable {
    /// 模型可见工具 + ToolRuntime 执行。
    case agent
    /// Trusted Stateful Runtime / Skill 拥有（校验、提交、持久化、验证）。
    case trustedRuntime
    /// AgentBridge 直接执行（播放器/服务器原语）。
    case bridge
}

public enum AgentCapabilityAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
    case degraded(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public struct AgentCapability: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    /// 作为 AI 任务是否需要 AI Provider（自然语言规划）。
    public let requiresProvider: Bool
    /// 是否真实持久化（SQLite / 记忆 / 歌单）。
    public let persists: Bool
    /// 是否只读。
    public let readOnly: Bool
    public let executionOwner: AgentCapabilityExecutionOwner
    public let modelRole: String
    public let runtimeRole: String
    public let userFacingDescription: String
    /// 关联的公开工具（仅用于 tool_search/诊断关联，不是注册表副本）。
    public let relatedTools: [String]
    /// 已知限制。
    public let limitations: [String]

    public init(
        id: String,
        title: String,
        summary: String,
        requiresProvider: Bool,
        persists: Bool = false,
        readOnly: Bool = false,
        executionOwner: AgentCapabilityExecutionOwner,
        modelRole: String,
        runtimeRole: String,
        userFacingDescription: String,
        relatedTools: [String],
        limitations: [String] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.requiresProvider = requiresProvider
        self.persists = persists
        self.readOnly = readOnly
        self.executionOwner = executionOwner
        self.modelRole = modelRole
        self.runtimeRole = runtimeRole
        self.userFacingDescription = userFacingDescription
        self.relatedTools = relatedTools
        self.limitations = limitations
    }
}

/// 单一 canonical capability 注册表。所有 capability 都基于真实存在的
/// ToolRegistry 工具 / Workflow / Skill，不允许凭空声明能力。
public enum AgentCapabilityCatalog {
    public static let all: [AgentCapability] = [
        // ---- Recommendation Index（Runtime-owned workflow）----
        AgentCapability(
            id: "recommendation_index_build",
            title: "建立/增量更新音乐分类索引",
            summary: "按情绪、场景、风格、人声、纹理、能量、节奏、声学、可舞性等维度建立并持久化 Auralis Recommendation Index。",
            requiresProvider: true,
            persists: true,
            executionOwner: .trustedRuntime,
            modelRole: "根据 Runtime 提供的当前批次歌曲元数据，生成封闭式结构化分类（批量、修订、曲目全覆盖）。",
            runtimeRole: "读取真实目录状态、准备批次、校验模型分类（batchID/revision/mode/track 覆盖/重复）、提交 SQLite、再读取真实状态验证 pending 下降。",
            userFacingDescription: "建立并持久化 Auralis Recommendation Index（模型生成分类，受控 Runtime 负责保存）。",
            relatedTools: ["library_index_status", "library_index_read"],
            limitations: ["分类写入由 Trusted Runtime 完成；模型看不到内部 commit 工具是安全设计，不代表不能保存。"]
        ),
        AgentCapability(
            id: "recommendation_index_status",
            title: "查看推荐索引状态",
            summary: "读取 Recommendation Index 的总数、已完成与待分类数量。",
            requiresProvider: false,
            readOnly: true,
            executionOwner: .agent,
            modelRole: "读取真实状态并解释。",
            runtimeRole: "读取 LocalCatalog recommendation_index_v2_state。",
            userFacingDescription: "查看推荐索引的建立进度。",
            relatedTools: ["library_index_status"]
        ),
        AgentCapability(
            id: "recommendation_index_browse",
            title: "浏览推荐索引分类结果",
            summary: "按维度与标签读取已完成的推荐索引条目，用于按情绪/场景等筛选音乐。",
            requiresProvider: false,
            readOnly: true,
            executionOwner: .agent,
            modelRole: "按用户条件选择维度与标签。",
            runtimeRole: "读取 recommendation_index_v2_tags。",
            userFacingDescription: "浏览已分类的音乐索引。",
            relatedTools: ["library_index_read"]
        ),

        // ---- 音乐智能 ----
        AgentCapability(
            id: "music_recommendation",
            title: "复杂音乐推荐",
            summary: "基于真实曲库、推荐索引、用户偏好与播放历史做多条件复杂推荐，绝不随机冒充。",
            requiresProvider: true,
            executionOwner: .agent,
            modelRole: "理解用户场景与约束，组合真实筛选条件。",
            runtimeRole: "执行真实曲库查询（约束/心情/智能队列/索引筛选）并返回真实候选。",
            userFacingDescription: "根据场景、情绪、风格等条件做真实音乐推荐。",
            relatedTools: ["recommend_by_constraints", "recommend_by_mood", "smart_queue_generate", "library_select_tracks", "library_get_catalog_tracks"],
            limitations: ["Provider 不可用时不做随机/相似歌曲冒充推荐。"]
        ),
        AgentCapability(
            id: "music_appreciation",
            title: "音乐鉴赏",
            summary: "结合本地元数据、歌词、外部核验资料与模型分析，解读歌曲的风格、编曲、情绪与背景。",
            requiresProvider: true,
            executionOwner: .agent,
            modelRole: "综合本地证据与可核验外部资料给出鉴赏结论。",
            runtimeRole: "提供真实歌曲元数据/歌词/播放统计；外部资料仅作参考不扩权。",
            userFacingDescription: "分析歌曲风格、编曲、情绪与评价。",
            relatedTools: ["music_appreciate", "lyrics_get", "web_search", "web_fetch"]
        ),
        AgentCapability(
            id: "library_analysis",
            title: "音乐库分析",
            summary: "统计与分析音乐库：收听习惯、格式分布、重复/元数据问题、最少播放等。",
            requiresProvider: true,
            executionOwner: .agent,
            modelRole: "理解分析意图，组合统计/诊断查询并解释。",
            runtimeRole: "读取真实目录统计与诊断结果。",
            userFacingDescription: "分析音乐库构成、收听习惯与数据质量问题。",
            relatedTools: ["stats_get_listening_summary", "stats_get_top_items", "stats_get_format_distribution", "stats_get_storage_distribution", "library_find_duplicates", "library_find_metadata_issues"]
        ),
        AgentCapability(
            id: "playlist_construction",
            title: "多步骤歌单构建",
            summary: "按用户条件选歌、创建歌单并加入歌曲，支持恢复。",
            requiresProvider: true,
            persists: true,
            executionOwner: .trustedRuntime,
            modelRole: "理解选歌条件并提交真实候选（result_present_tracks）。",
            runtimeRole: "PlaylistBuildSkill 固定执行 playlist_create → playlist_add_songs → 验证。",
            userFacingDescription: "创建一个按条件选好歌的歌单。",
            relatedTools: ["playlist_create", "playlist_add_songs", "library_search", "library_select_tracks"],
            limitations: ["候选不足时不会先创建再失败；add 失败不自动删除/重建歌单。"]
        ),

        // ---- 曲库 / 检索 ----
        AgentCapability(
            id: "catalog_search",
            title: "结构化音乐检索",
            summary: "统一搜索歌曲/专辑/艺术家/歌单/流派/歌词，解析实体并获取真实 Global ID。",
            requiresProvider: false,
            readOnly: true,
            executionOwner: .agent,
            modelRole: "把自然语言查询映射到结构化搜索。",
            runtimeRole: "执行真实目录搜索与实体解析。",
            userFacingDescription: "搜索与定位音乐库内容。",
            relatedTools: ["library_search", "library_resolve_entity", "library_select_tracks", "library_get_song", "library_get_album", "library_get_artist"]
        ),

        // ---- 变更操作（执行由 Runtime，规划需 Provider）----
        AgentCapability(
            id: "queue_mutation",
            title: "队列操作",
            summary: "替换/追加/清空/调整/下一首等队列变更；作为复杂任务的一步由 Runtime 执行。",
            requiresProvider: true,
            executionOwner: .bridge,
            modelRole: "在复杂任务中决定队列目标（如替换为筛选结果）。",
            runtimeRole: "ToolRuntime exact authorization + bridge 执行 + 幂等保护。",
            userFacingDescription: "修改播放队列。",
            relatedTools: ["queue_replace", "queue_append_many", "queue_clear", "queue_move", "queue_play_next_many", "queue_get"]
        ),
        AgentCapability(
            id: "playlist_mutation",
            title: "歌单操作",
            summary: "创建/重命名/加歌/移除/排序/复制/合并/删除歌单；删除为不可逆需用户批准。",
            requiresProvider: true,
            executionOwner: .bridge,
            modelRole: "在复杂任务中决定歌单目标。",
            runtimeRole: "ToolRuntime authorization + confirmation（删除）+ bridge 执行。",
            userFacingDescription: "创建与维护歌单。",
            relatedTools: ["playlist_create", "playlist_add_songs", "playlist_rename", "playlist_remove_songs", "playlist_delete", "playlist_list"]
        ),
        AgentCapability(
            id: "playback_control",
            title: "播放控制",
            summary: "播放/暂停/下一首/跳转/随机/循环等；作为复杂任务的一步由 Runtime 执行。",
            requiresProvider: true,
            executionOwner: .bridge,
            modelRole: "理解播放意图（如「找 20 首跑步歌并播放」）。",
            runtimeRole: "ToolRuntime authorization + bridge 执行。",
            userFacingDescription: "控制播放。",
            relatedTools: ["playback_play_song", "playback_pause", "playback_next", "playback_seek", "playback_set_shuffle", "playback_set_repeat", "playback_get_state"]
        ),

        // ---- 服务器 / 下载 / 记忆 / 联网 ----
        AgentCapability(
            id: "server_query_sync",
            title: "服务器查询与同步",
            summary: "列出/切换/测试服务器、搜索服务器曲库、触发与查询同步。",
            requiresProvider: false,
            readOnly: true,
            executionOwner: .bridge,
            modelRole: "解释服务器状态。",
            runtimeRole: "bridge 真实服务器 API。",
            userFacingDescription: "管理与查询音乐服务器。",
            relatedTools: ["server_list", "server_get_current", "server_search", "server_sync_status", "server_test_connection"]
        ),
        AgentCapability(
            id: "music_download",
            title: "音乐下载",
            summary: "搜索可下载音乐、提交下载、查看任务与历史。",
            requiresProvider: true,
            persists: true,
            executionOwner: .agent,
            modelRole: "理解下载需求并选择歌曲。",
            runtimeRole: "SystemToolExecutor 下载服务 + 状态记录。",
            userFacingDescription: "下载音乐到服务器/离线。",
            relatedTools: ["music_download_search", "music_download_submit", "music_download_status", "music_download_tasks", "music_download_history"]
        ),
        AgentCapability(
            id: "memory",
            title: "记忆与自定义工具",
            summary: "记住用户信息（跨会话）、管理技能与自定义工具（tool_builder）。",
            requiresProvider: true,
            persists: true,
            executionOwner: .trustedRuntime,
            modelRole: "理解什么值得记住。",
            runtimeRole: "持久化记忆；不可逆删除需用户批准。",
            userFacingDescription: "记住用户偏好与维护自定义工具。",
            relatedTools: ["memory_save", "memory_list", "memory_search", "memory_delete", "tool_builder_create", "skill_list"]
        ),
        AgentCapability(
            id: "web_research",
            title: "联网资料核验",
            summary: "使用联网搜索与网页读取补充外部资料；外部数据不构成授权。",
            requiresProvider: true,
            executionOwner: .agent,
            modelRole: "判断何时需要外部资料并引用来源。",
            runtimeRole: "web_search/web_fetch（外部不可信数据，不扩权）。",
            userFacingDescription: "联网查询外部音乐资料。",
            relatedTools: ["web_search", "web_fetch"]
        ),
    ]

    public static func capability(id: String) -> AgentCapability? {
        all.first { $0.id == id }
    }

    /// 动态可用性：结合当前环境（Provider 是否可用、曲库是否就绪、服务器是否活跃）。
    /// 这是真实 availability，不是静态宣传。
    public static func availability(
        for capability: AgentCapability,
        providerAvailable: Bool,
        catalogAvailable: Bool,
        activeServer: Bool
    ) -> AgentCapabilityAvailability {
        if capability.requiresProvider, !providerAvailable {
            return .unavailable(reason: "AI Provider 未配置或不可用")
        }
        switch capability.id {
        case "recommendation_index_build", "recommendation_index_status", "recommendation_index_browse":
            if !catalogAvailable {
                return .unavailable(reason: "本地音乐目录不可用")
            }
        case "server_query_sync", "music_download", "catalog_search", "library_analysis":
            if !activeServer {
                return .degraded(reason: "未连接音乐服务器；本地目录能力仍可用")
            }
        default:
            break
        }
        return .available
    }

    /// 生成供 System Prompt / capabilities_get / 诊断共用的紧凑能力摘要。
    /// 只描述高层能力、需要 Provider 与否、执行归属与持久化，不罗列 100+ 工具。
    public static func systemPromptSummary(
        providerAvailable: Bool,
        catalogAvailable: Bool,
        activeServer: Bool
    ) -> String {
        var lines: [String] = ["## Auralis 高层能力（Capability 摘要）"]
        lines.append("模型可见 Tool 列表不是 Auralis 全部能力；以下能力部分由 Trusted Runtime / Stateful Skill 完成，判断系统能力以本摘要为准。")
        for capability in all {
            let availability = availability(
                for: capability,
                providerAvailable: providerAvailable,
                catalogAvailable: catalogAvailable,
                activeServer: activeServer
            )
            guard availability.isAvailable || capability.id == "recommendation_index_build" else { continue }
            let providerNote = capability.requiresProvider ? "需要 Provider" : "不需要 Provider"
            let ownerNote: String
            switch capability.executionOwner {
            case .trustedRuntime: ownerNote = "受控 Runtime 执行"
            case .bridge: ownerNote = "Runtime+bridge 执行"
            case .agent: ownerNote = "Agent+ToolRuntime 执行"
            }
            let persistNote = capability.persists ? " · 真实持久化" : ""
            let readOnlyNote = capability.readOnly ? " · 只读" : ""
            var line = "- \(capability.title)：\(capability.summary)（\(providerNote) · \(ownerNote)\(persistNote)\(readOnlyNote)）"
            if case let .unavailable(reason) = availability {
                line += " [当前不可用：\(reason)]"
            }
            if capability.id == "recommendation_index_build" {
                line += " 分类由模型生成，批次校验、SQLite 写入与完成验证由受控 Runtime 执行；不要因为看不到内部 commit 工具就声称无法保存。"
            }
            lines.append(line)
        }
        lines.append("模型不得声称自己直接写数据库：持久化由 Runtime 完成。")
        return lines.joined(separator: "\n")
    }
}
