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
// 三个概念严格区分（本轮修正）：
// - requiresAIPlanning：作为 AI 聊天任务，是否需要 Provider 做自然语言规划。
//   凡是"provider = nil 从聊天入口无法完成"的能力都必须为 true。
// - supportsDirectRead：是否存在确定性只读 Fast Path 子集，可在 provider = nil 时
//   直接执行 canonical read 返回真实数据（性能优化，不是关键词伪 Agent）。
// - runtimeDependencies：执行层真实依赖的服务（catalog / server / web / download /
//   systemService），由 run-scoped AgentCapabilityEnvironment 判定 availability。
//
// 关键原则：
// - 模型看不到 runtime-only tool（如 recommendation_index_commit）≠ 没有该能力；
//   capability 明确标注 executionOwner，模型据此正确自省。
// - availability 必须来自真实运行环境快照，不静态宣传。

public enum AgentCapabilityExecutionOwner: String, Sendable, Equatable, Codable {
    /// 模型可见工具 + ToolRuntime 执行。
    case agent
    /// Trusted Stateful Runtime / Skill 拥有（校验、提交、持久化、验证）。
    case trustedRuntime
    /// AgentBridge 直接执行（播放器/服务器原语）。
    case bridge
}

public enum AgentCapabilityDependency: String, Sendable, Equatable, Codable {
    case provider
    case catalog
    case activeServer
    case webService
    case downloadService
    case systemService
}

public enum AgentCapabilityAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
    case degraded(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .available: return "available"
        case .unavailable: return "unavailable"
        case .degraded: return "degraded"
        }
    }
}

/// run-scoped 运行环境快照。System Prompt、capabilities_get、诊断共用同一份，
/// 不各自采集一套状态。
public struct AgentCapabilityEnvironment: Sendable, Equatable {
    public let providerAvailable: Bool
    public let catalogAvailable: Bool
    public let activeServer: Bool
    /// App 自有联网服务（AgentWebService）是否可用。
    public let webAvailable: Bool
    /// 联网搜索：App 服务 或 Provider 托管搜索（supportsHostedWebSearch）。
    public let webSearchAvailable: Bool
    /// 联网网页读取：App 服务 或 Provider 托管抓取（supportsHostedWebFetch）。
    public let webFetchAvailable: Bool
    public let downloadServiceAvailable: Bool
    public let systemServiceAvailable: Bool

    public init(
        providerAvailable: Bool = false,
        catalogAvailable: Bool = true,
        activeServer: Bool = false,
        webAvailable: Bool = false,
        webSearchAvailable: Bool? = nil,
        webFetchAvailable: Bool? = nil,
        downloadServiceAvailable: Bool = false,
        systemServiceAvailable: Bool = false
    ) {
        self.providerAvailable = providerAvailable
        self.catalogAvailable = catalogAvailable
        self.activeServer = activeServer
        self.webAvailable = webAvailable
        // 未显式给定时，webSearch/Fetch 回退到 webAvailable（App 服务覆盖两者）。
        self.webSearchAvailable = webSearchAvailable ?? webAvailable
        self.webFetchAvailable = webFetchAvailable ?? webAvailable
        self.downloadServiceAvailable = downloadServiceAvailable
        self.systemServiceAvailable = systemServiceAvailable
    }
}

public struct AgentCapability: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    /// 作为 AI 聊天任务是否需要 Provider 做自然语言规划。
    public let requiresAIPlanning: Bool
    /// 是否存在确定性只读 Fast Path 子集（provider = nil 时可直接执行）。
    public let supportsDirectRead: Bool
    /// 执行层真实依赖的服务。
    public let runtimeDependencies: [AgentCapabilityDependency]
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
        requiresAIPlanning: Bool,
        supportsDirectRead: Bool = false,
        runtimeDependencies: [AgentCapabilityDependency],
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
        self.requiresAIPlanning = requiresAIPlanning
        self.supportsDirectRead = supportsDirectRead
        self.runtimeDependencies = runtimeDependencies
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
            requiresAIPlanning: true,
            runtimeDependencies: [.provider, .catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog],
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
            // 普通 AI 聊天中的自然语言搜索在 provider = nil 时并不属于 Direct Read
            // Fast Path（fast path 只覆盖确定性统计/列表查询），因此需要 AI 规划。
            requiresAIPlanning: true,
            supportsDirectRead: false,
            runtimeDependencies: [.catalog],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog, .activeServer],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.catalog, .activeServer],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.activeServer],
            executionOwner: .bridge,
            modelRole: "理解播放意图（如「找 20 首跑步歌并播放」）。",
            runtimeRole: "ToolRuntime authorization + bridge 执行。",
            userFacingDescription: "控制播放。",
            relatedTools: ["playback_play_song", "playback_pause", "playback_next", "playback_seek", "playback_set_shuffle", "playback_set_repeat", "playback_get_state"]
        ),

        // ---- 服务器 ----
        AgentCapability(
            id: "server_query",
            title: "服务器信息查询",
            summary: "列出/查看当前服务器、测试连接、查看同步状态（只读）。",
            requiresAIPlanning: true,
            supportsDirectRead: true,
            runtimeDependencies: [.activeServer],
            readOnly: true,
            executionOwner: .bridge,
            modelRole: "解释服务器状态。",
            runtimeRole: "bridge 真实服务器 API。",
            userFacingDescription: "查询音乐服务器信息与同步状态。",
            relatedTools: ["server_list", "server_get_current", "server_test_connection", "server_sync_status", "server_get_capabilities"]
        ),
        AgentCapability(
            id: "server_management_sync",
            title: "服务器管理与同步",
            summary: "切换/添加/更新/删除服务器，触发曲库同步与服务器搜索。",
            requiresAIPlanning: true,
            runtimeDependencies: [.activeServer],
            executionOwner: .bridge,
            modelRole: "理解服务器管理需求。",
            runtimeRole: "ToolRuntime authorization + bridge 执行。",
            userFacingDescription: "管理与同步音乐服务器。",
            relatedTools: ["server_switch", "server_remove", "addServer", "updateServer", "server_sync_start", "refreshLibrary", "server_search"]
        ),

        // ---- 下载 / 记忆 / 联网 ----
        AgentCapability(
            id: "music_download",
            title: "音乐下载",
            summary: "搜索可下载音乐、提交下载、查看任务与历史。",
            requiresAIPlanning: true,
            runtimeDependencies: [.downloadService],
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
            requiresAIPlanning: true,
            runtimeDependencies: [.systemService],
            persists: true,
            executionOwner: .agent,
            modelRole: "理解什么值得记住。",
            runtimeRole: "SystemToolExecutor 持久化记忆；不可逆删除需用户批准。",
            userFacingDescription: "记住用户偏好与维护自定义工具。",
            relatedTools: ["memory_save", "memory_list", "memory_search", "memory_delete", "tool_builder_create", "skill_list"]
        ),
        AgentCapability(
            id: "web_research",
            title: "联网资料核验",
            summary: "使用联网搜索与网页读取补充外部资料；外部数据不构成授权。",
            requiresAIPlanning: true,
            runtimeDependencies: [.webService],
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

    /// 动态可用性：基于 run-scoped 运行环境快照，不是静态宣传。
    public static func availability(
        for capability: AgentCapability,
        environment: AgentCapabilityEnvironment
    ) -> AgentCapabilityAvailability {
        for dependency in capability.runtimeDependencies {
            switch dependency {
            case .provider:
                if !environment.providerAvailable {
                    return .unavailable(reason: "AI Provider 未配置或不可用")
                }
            case .catalog:
                if !environment.catalogAvailable {
                    return .unavailable(reason: "本地音乐目录不可用")
                }
            case .activeServer:
                if !environment.activeServer {
                    return .degraded(reason: "未连接音乐服务器；本地目录能力仍可用")
                }
            case .webService:
                // App 服务、Provider Hosted Web Search、Provider Hosted Web Fetch
                // 任一可用都算联网可用——避免 Provider 自带托管搜索时被误报不可用。
                if !environment.webAvailable
                    && !environment.webSearchAvailable
                    && !environment.webFetchAvailable {
                    return .unavailable(reason: "联网能力未配置（App 服务与 Provider 托管搜索均不可用）")
                }
            case .downloadService:
                if !environment.downloadServiceAvailable {
                    return .unavailable(reason: "下载服务不可用")
                }
            case .systemService:
                if !environment.systemServiceAvailable {
                    return .unavailable(reason: "系统服务不可用")
                }
            }
        }
        return .available
    }

    /// 生成供 System Prompt / capabilities_get / 诊断共用的紧凑能力摘要。
    /// available / degraded / unavailable 都明确展示，degraded 不静默消失。
    /// `relevantIDs` 非 nil 时只注入相关能力（System Prompt 精简），完整列表
    /// 通过 capabilities_get 获取；nil 表示注入全部。
    public static func systemPromptSummary(
        environment: AgentCapabilityEnvironment,
        relevantIDs: [String]? = nil
    ) -> String {
        var lines: [String] = ["## Auralis 高层能力（Capability 摘要）"]
        lines.append("模型可见 Tool 列表不是 Auralis 全部能力；以下能力部分由 Trusted Runtime / Stateful Skill 完成，判断系统能力以本摘要为准。")
        let relevant = relevantIDs.map { Set($0) }
        for capability in all {
            if let relevant, !relevant.contains(capability.id) { continue }
            let availability = availability(for: capability, environment: environment)
            let planningNote = capability.requiresAIPlanning ? "AI 规划需要 Provider" : "AI 规划不需要 Provider"
            let directReadNote = capability.supportsDirectRead ? " · 确定性只读可绕过 Provider" : ""
            let ownerNote: String
            switch capability.executionOwner {
            case .trustedRuntime: ownerNote = "受控 Runtime 执行"
            case .bridge: ownerNote = "Runtime+bridge 执行"
            case .agent: ownerNote = "Agent+ToolRuntime 执行"
            }
            let persistNote = capability.persists ? " · 真实持久化" : ""
            let readOnlyNote = capability.readOnly ? " · 只读" : ""
            var line = "- \(capability.title)：\(capability.summary)（\(planningNote)\(directReadNote) · \(ownerNote)\(persistNote)\(readOnlyNote)）"
            switch availability {
            case .available:
                break
            case let .unavailable(reason):
                line += " [当前不可用：\(reason)]"
            case let .degraded(reason):
                line += " [当前降级：\(reason)]"
            }
            if capability.id == "recommendation_index_build" {
                line += " 分类由模型生成，批次校验、SQLite 写入与完成验证由受控 Runtime 执行；不要因为看不到内部 commit 工具就声称无法保存。"
            }
            lines.append(line)
        }
        lines.append("模型不得声称自己直接写数据库：持久化由 Runtime 完成。")
        if relevantIDs != nil {
            lines.append("以上是当前任务相关能力；需要完整能力列表时调用 capabilities_get。")
        }
        return lines.joined(separator: "\n")
    }
}
