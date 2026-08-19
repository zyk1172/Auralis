import Domain
import Foundation
import LocalCatalog

/// 单个工具参数的声明，用于参数校验与系统提示生成。
public struct ToolParameter: Sendable, Hashable {
    public let name: String
    public let required: Bool
    public let description: String
    /// 可选的完整 JSON Schema 片段。未提供时参数仍按字符串声明；用于索引批次这类
    /// 原生结构化参数，避免模型先把数组转义成字符串再传回工具。
    public let schemaJSON: String?

    public init(name: String, required: Bool, description: String, schemaJSON: String? = nil) {
        self.name = name
        self.required = required
        self.description = description
        self.schemaJSON = schemaJSON
    }
}

public enum ToolCachePolicy: String, Sendable, Hashable {
    case none
    case task
}

public enum ToolSideEffectPolicy: String, Sendable, Hashable {
    case none
    case playback
    case queue
    case playlist
    case annotation
    case server
    case download
    case memory
}

public enum ToolEvidencePolicy: String, Sendable, Hashable {
    case none
    case localCatalog
    case playbackState
    case server
    case externalAPI
}

/// 工具元数据：分组、权限、展示角色、参数。
public struct ToolDescriptor: Sendable, Hashable {
    public let name: String
    public let group: ToolGroup
    public let permission: ToolPermission
    /// deprecated / diagnostics-only：permissive runtime 不再因它触发确认。
    public let requiresConfirmation: Bool
    public let summary: String
    public let parameters: [ToolParameter]
    public let cachePolicy: ToolCachePolicy
    public let sideEffectPolicy: ToolSideEffectPolicy
    public let evidencePolicy: ToolEvidencePolicy
    /// 执行该工具必须具备的任务能力域（deprecated / diagnostics-only）：
    /// permissive runtime 不再因缺少 scope 拒绝已注册工具，保留仅为迁移/日志兼容。
    public let requiredScopes: Set<GrantedScope>
    /// 默认展示角色：决定工具结果进入候选池 / 最终 / 歧义（Tool 执行可覆盖）。
    public let defaultPresentationRole: ToolPresentationRole
    public let maxResultCharacters: Int

    public init(
        name: String,
        group: ToolGroup,
        permission: ToolPermission,
        requiresConfirmation: Bool = false,
        summary: String,
        parameters: [ToolParameter] = [],
        cachePolicy: ToolCachePolicy? = nil,
        sideEffectPolicy: ToolSideEffectPolicy? = nil,
        evidencePolicy: ToolEvidencePolicy? = nil,
        requiredScopes: Set<GrantedScope>? = nil,
        defaultPresentationRole: ToolPresentationRole = .candidate,
        maxResultCharacters: Int = ContextManager.maxToolResultCharacters
    ) {
        self.name = name
        self.group = group
        self.permission = permission
        self.requiresConfirmation = requiresConfirmation
        self.summary = summary
        self.parameters = parameters
        self.cachePolicy = cachePolicy ?? (permission == .readOnly ? .task : .none)
        let resolvedSideEffectPolicy = sideEffectPolicy ?? Self.defaultSideEffectPolicy(name: name, group: group, permission: permission)
        self.sideEffectPolicy = resolvedSideEffectPolicy
        self.evidencePolicy = evidencePolicy ?? Self.defaultEvidencePolicy(group: group, permission: permission)
        self.requiredScopes = requiredScopes ?? Self.defaultRequiredScopes(
            name: name,
            group: group,
            permission: permission,
            sideEffectPolicy: resolvedSideEffectPolicy
        )
        self.defaultPresentationRole = defaultPresentationRole
        self.maxResultCharacters = maxResultCharacters
    }

    private static func defaultRequiredScopes(
        name: String,
        group: ToolGroup,
        permission: ToolPermission,
        sideEffectPolicy: ToolSideEffectPolicy
    ) -> Set<GrantedScope> {
        // 少数工具的注册分组是为了兼容旧 schema；它们的真实能力域必须按实际行为声明。
        switch name {
        case "music_appreciate":
            return [.catalogRead, .externalRead]
        case "library_index_v2_write_batch":
            return [.catalogRead, .annotationWrite]
        case "media_download_offline":
            return [.catalogRead, .downloadWrite]
        default:
            break
        }

        switch group {
        case .catalog:
            return permission == .readOnly ? [.catalogRead] : [.annotationWrite]
        case .playback:
            if permission == .readOnly { return [.catalogRead] }
            return sideEffectPolicy == .queue ? [.queueWrite] : [.playbackWrite]
        case .playlist:
            return permission == .readOnly ? [.catalogRead] : [.playlistWrite]
        case .annotation:
            return permission == .readOnly ? [.catalogRead] : [.annotationWrite]
        case .server:
            return permission == .readOnly ? [.serverRead] : [.serverWrite]
        case .download:
            return permission == .readOnly ? [.serverRead] : [.downloadWrite]
        case .memory:
            return permission == .readOnly ? [.memoryRead] : [.memoryWrite]
        }
    }

    private static func defaultEvidencePolicy(group: ToolGroup, permission: ToolPermission) -> ToolEvidencePolicy {
        guard permission == .readOnly else { return .none }
        return switch group {
        case .catalog: .localCatalog
        case .playback: .playbackState
        case .server, .download: .server
        case .playlist, .annotation, .memory: .none
        }
    }

    private static func defaultSideEffectPolicy(name: String, group: ToolGroup, permission: ToolPermission) -> ToolSideEffectPolicy {
        guard permission != .readOnly else { return .none }
        return switch group {
        case .playback: name.hasPrefix("queue_") || name == "replaceQueue" || name == "addToQueue" || name == "playNext" || name == "clearQueue" ? .queue : .playback
        case .playlist: .playlist
        case .annotation: .annotation
        case .server: .server
        case .download: .download
        case .memory: .memory
        case .catalog: name == "library_index_v2_write_batch" ? .annotation : .none
        }
    }
}

/// 全部 Agent 工具注册表。集中声明权限与确认要求，供 Runner 校验与 UI 展示。
public enum AgentToolRegistry {
    /// 原生 Function Calling 直接接收数组。固定音乐分析维度
    /// （mood/scene/vocal/texture/style/energy/tempo/acousticness/danceability）保持规范；
    /// 另外支持开放语义标签 semanticTags（dimension='tag'，数量无硬上限）。
    static let recommendationClassificationArraySchema = #"""
    {
      "type": "array",
      "minItems": 1,
      "maxItems": 100,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "id": {"type": "string"},
          "moods": {"type": "array", "items": {"type": "string"}},
          "scenes": {"type": "array", "items": {"type": "string"}},
          "energy": {"type": "integer", "minimum": 1, "maximum": 10},
          "tempo": {"type": "integer", "minimum": 1, "maximum": 5},
          "acousticness": {"type": "integer", "minimum": 1, "maximum": 5},
          "danceability": {"type": "integer", "minimum": 1, "maximum": 5},
          "vocals": {"type": "array", "items": {"type": "string"}},
          "textures": {"type": "array", "items": {"type": "string"}},
          "styles": {"type": "array", "items": {"type": "string"}},
          "semanticTags": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "value": {"type": "string"},
                "confidence": {"type": "number", "minimum": 0, "maximum": 1}
              },
              "required": ["value", "confidence"]
            }
          },
          "mode": {"type": "string", "enum": ["full", "semanticTagsOnly"]},
          "confidence": {"type": "number", "minimum": 0, "maximum": 1}
        },
        "required": ["id"]
      }
    }
    """#

    public static let all: [ToolDescriptor] = [
        // MARK: Catalog
        .init(name: "searchTracks", group: .catalog, permission: .readOnly, summary: "按关键词搜索单曲",
              parameters: [.init(name: "q", required: true, description: "搜索关键词")]),
        .init(name: "searchAlbums", group: .catalog, permission: .readOnly, summary: "按关键词搜索专辑",
              parameters: [.init(name: "q", required: true, description: "搜索关键词")]),
        .init(name: "searchArtists", group: .catalog, permission: .readOnly, summary: "按关键词搜索艺术家",
              parameters: [.init(name: "q", required: true, description: "搜索关键词")]),
        .init(name: "getTrack", group: .catalog, permission: .readOnly, summary: "获取单曲详情",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "getAlbum", group: .catalog, permission: .readOnly, summary: "获取专辑详情",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "getArtist", group: .catalog, permission: .readOnly, summary: "获取艺术家详情",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "getFavorites", group: .catalog, permission: .readOnly, summary: "获取收藏的单曲"),
        .init(name: "getRecentHistory", group: .catalog, permission: .readOnly, summary: "获取最近播放历史",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 50")]),
        .init(name: "getLeastPlayed", group: .catalog, permission: .readOnly, summary: "获取最少播放的单曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 50")]),
        .init(name: "getDownloadedTracks", group: .catalog, permission: .readOnly, summary: "获取已下载的单曲"),
        .init(name: "getSimilarTracks", group: .catalog, permission: .readOnly, summary: "获取相似单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "getCurrentTrack", group: .catalog, permission: .readOnly, summary: "获取当前播放的单曲"),
        .init(name: "getCurrentQueue", group: .catalog, permission: .readOnly, summary: "获取当前播放队列"),

        // MARK: 最终展示协议（确定性 Presentation，模型不能决定 UI）
        .init(name: "result_present_tracks", group: .catalog, permission: .readOnly,
              summary: "明确把一组歌曲作为本次任务的最终展示结果（只传入真正打算展示给用户的最终歌曲，不要传整个候选池）",
              parameters: [
                .init(name: "trackIDs", required: true, description: "最终歌曲的 GlobalTrackID 数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "kind", required: false, description: "final=最终推荐结果（默认）；disambiguation=存在多个匹配需要用户选择",
                      schemaJSON: #"{"type":"string","enum":["final","disambiguation"]}"#),
              ],
              defaultPresentationRole: .finalResult),

        // MARK: Canonical 新式工具（旧别名仍注册，仅供执行兼容；schema 只暴露 canonical）
        .init(name: "library_get_least_played", group: .catalog, permission: .readOnly, summary: "获取最少播放的单曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 50")]),
        .init(name: "library_get_downloaded", group: .catalog, permission: .readOnly, summary: "获取已下载的单曲"),
        .init(name: "queue_remove", group: .playback, permission: .reversible, summary: "从队列移除指定位置",
              parameters: [.init(name: "index", required: true, description: "队列索引（从 0）")]),
        .init(name: "playlist_rename", group: .playlist, permission: .reversible, summary: "重命名歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "name", required: true, description: "新名称")]),
        .init(name: "playlist_remove_songs", group: .playlist, permission: .reversible, summary: "从歌单移除曲目",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "indices", required: false, description: "要移除的曲目索引数组（歌单内 0 基索引）",
                                 schemaJSON: #"{"type":"array","items":{"type":"integer","minimum":0}}"#)]),
        .init(name: "playlist_move", group: .playlist, permission: .reversible, summary: "调整歌单内曲目顺序",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "from", required: true, description: "原索引"),
                           .init(name: "to", required: true, description: "目标索引")]),
        .init(name: "playlist_duplicate", group: .playlist, permission: .reversible, summary: "复制歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "playlist_merge", group: .playlist, permission: .reversible, summary: "把多个歌单合并成新歌单",
              parameters: [.init(name: "name", required: true, description: "新歌单名称"),
                           .init(name: "sourceIDs", required: true, description: "源歌单 GlobalPlaylistID 数组",
                                 schemaJSON: #"{"type":"array","items":{"type":"string"}}"#)]),
        .init(name: "playlist_delete", group: .playlist, permission: .destructive, summary: "删除歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "rating_set", group: .annotation, permission: .reversible, summary: "设置单曲评分（value 0 表示清除）",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID"),
                           .init(name: "value", required: true, description: "评分 1-5；0 表示清除评分",
                                 schemaJSON: #"{"type":"integer","minimum":0,"maximum":5}"#)]),
        .init(name: "server_switch", group: .server, permission: .reversible, summary: "切换服务器",
              parameters: [.init(name: "serverID", required: true, description: "服务器 ID")]),
        .init(name: "server_remove", group: .server, permission: .destructive, summary: "删除服务器（仅本地清理）",
              parameters: [.init(name: "serverID", required: true, description: "服务器 ID")]),

        // MARK: Playback
        .init(name: "playTrack", group: .playback, permission: .reversible, summary: "播放指定单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "playAlbum", group: .playback, permission: .reversible, summary: "播放指定专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "playPlaylist", group: .playback, permission: .reversible, summary: "播放指定歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "pause", group: .playback, permission: .reversible, summary: "暂停播放"),
        .init(name: "resume", group: .playback, permission: .reversible, summary: "继续播放"),
        .init(name: "seek", group: .playback, permission: .reversible, summary: "拖动播放进度",
              parameters: [.init(name: "seconds", required: true, description: "目标秒数")]),
        .init(name: "next", group: .playback, permission: .reversible, summary: "下一首"),
        .init(name: "previous", group: .playback, permission: .reversible, summary: "上一首"),
        .init(name: "addToQueue", group: .playback, permission: .reversible, summary: "加入队列末尾",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "playNext", group: .playback, permission: .reversible, summary: "下一首播放",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "replaceQueue", group: .playback, permission: .reversible, summary: "替换整个队列",
              parameters: [.init(name: "trackIDs", required: true, description: "逗号分隔的 GlobalTrackID")]),
        .init(name: "removeFromQueue", group: .playback, permission: .reversible, summary: "从队列移除",
              parameters: [.init(name: "index", required: true, description: "队列索引（从 0）")]),
        .init(name: "reorderQueue", group: .playback, permission: .reversible, summary: "调整队列顺序",
              parameters: [.init(name: "from", required: true, description: "原索引"),
                           .init(name: "to", required: true, description: "目标索引")]),
        .init(name: "clearQueue", group: .playback, permission: .reversible, summary: "清空队列"),

        // MARK: 音乐下载（MoviePilot / MoviePilot）
        .init(name: "music_download", group: .download, permission: .reversible, summary: "从 MoviePilot（MoviePilot）搜索并下载音乐资源",
              parameters: [
                .init(name: "action", required: true, description: "search=搜索候选 | download=提交下载 | tasks=查询下载任务 | history=查看下载历史 | status=查询插件状态 | history_remove=移除单条历史 | history_clean=按条件清理历史"),
                .init(name: "artist", required: false, description: "艺人名（search）"),
                .init(name: "album", required: false, description: "专辑名（search）"),
                .init(name: "album_aliases", required: false, description: "专辑英文/别名，逗号分隔；中文专辑务必提供（search）"),
                .init(name: "keyword", required: false, description: "搜索关键词（search）"),
                .init(name: "year", required: false, description: "年份（search）"),
                .init(name: "limit", required: false, description: "返回条数，默认 10（search）"),
                .init(name: "prefer_lossless", required: false, description: "优先无损 true/false（search）"),
                .init(name: "min_seeders", required: false, description: "最低做种数（search）"),
                .init(name: "kind", required: false, description: "single=单曲 | album=专辑合集 | auto=自动（search，v0.5.x）"),
                .init(name: "ref", required: false, description: "搜索结果条目引用（hash:id，download 推荐）"),
                .init(name: "site_id", required: false, description: "站点 ID（download，配合 index）"),
                .init(name: "index", required: false, description: "候选序号（download，配合 site_id）"),
                .init(name: "magnet", required: false, description: "磁力链接（download）"),
                .init(name: "title", required: false, description: "资源标题（download/magnet）"),
                .init(name: "max_size_gb", required: false, description: "体积上限 GB：把 search 返回的 size_limit_gb 原样传回（download，v0.5.x）"),
                .init(name: "verify_song", required: false, description: "目标歌曲名：单曲自动下载必传，插件会校验种子确实包含该曲（download）"),
                .init(name: "verify_artist", required: false, description: "目标艺人名：单曲自动下载配合 verify_song 使用（download）"),
                .init(name: "status", required: false, description: "任务状态过滤（tasks）；清理目标状态 downloading/completed/failed/paused（history_clean）"),
                .init(name: "hash", required: false, description: "目标下载 hash（history_remove，必传）"),
                .init(name: "keep", required: false, description: "只保留最近 N 条记录（history_clean）"),
                .init(name: "orphans", required: false, description: "是否清理下载器已不存在的孤儿记录 true/false（history_clean）"),
              ]),

        // MARK: Playlist
        .init(name: "listPlaylists", group: .playlist, permission: .readOnly, summary: "列出歌单"),
        .init(name: "getPlaylist", group: .playlist, permission: .readOnly, summary: "获取歌单详情",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "createPlaylist", group: .playlist, permission: .reversible, summary: "新建歌单",
              parameters: [.init(name: "name", required: true, description: "歌单名称")]),
        .init(name: "renamePlaylist", group: .playlist, permission: .reversible, summary: "重命名歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "name", required: true, description: "新名称")]),
        .init(name: "addTracksToPlaylist", group: .playlist, permission: .reversible, summary: "向歌单添加曲目",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "trackIDs", required: true, description: "逗号分隔的 GlobalTrackID")]),
        .init(name: "removeTracksFromPlaylist", group: .playlist, permission: .reversible, summary: "从歌单移除曲目",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "indices", required: true, description: "逗号分隔的位置索引")]),
        .init(name: "reorderPlaylist", group: .playlist, permission: .reversible, summary: "调整歌单内顺序",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "from", required: true, description: "原索引"),
                           .init(name: "to", required: true, description: "目标索引")]),
        .init(name: "duplicatePlaylist", group: .playlist, permission: .reversible, summary: "复制歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "mergePlaylists", group: .playlist, permission: .reversible, summary: "合并歌单",
              parameters: [.init(name: "sourceIDs", required: true, description: "逗号分隔的 GlobalPlaylistID"),
                           .init(name: "name", required: true, description: "新歌单名称")]),
        .init(name: "deletePlaylist", group: .playlist, permission: .destructive, summary: "删除歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),

        // MARK: Annotation
        .init(name: "likeTrack", group: .annotation, permission: .reversible, summary: "收藏单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "unlikeTrack", group: .annotation, permission: .reversible, summary: "取消收藏单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "favoriteAlbum", group: .annotation, permission: .reversible, summary: "收藏专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "unfavoriteAlbum", group: .annotation, permission: .reversible, summary: "取消收藏专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "favoriteArtist", group: .annotation, permission: .reversible, summary: "收藏艺术家",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "unfavoriteArtist", group: .annotation, permission: .reversible, summary: "取消收藏艺术家",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "setRating", group: .annotation, permission: .reversible, summary: "设置评分",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID"),
                           .init(name: "rating", required: true, description: "1-5 整数")]),
        .init(name: "clearRating", group: .annotation, permission: .reversible, summary: "清除评分",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),

        // MARK: Server
        .init(name: "listServers", group: .server, permission: .readOnly, summary: "列出已连接服务器"),
        .init(name: "getActiveServer", group: .server, permission: .readOnly, summary: "获取当前服务器"),
        .init(name: "testServerConnection", group: .server, permission: .readOnly, summary: "测试服务器连接",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),
        .init(name: "addServer", group: .server, permission: .reversible, summary: "添加服务器（打开原生表单录入凭据）",
              parameters: [.init(name: "displayName", required: true, description: "显示名称"),
                           .init(name: "baseURL", required: true, description: "服务器地址")]),
        .init(name: "updateServer", group: .server, permission: .reversible, summary: "更新服务器",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),
        .init(name: "switchServer", group: .server, permission: .reversible, summary: "切换服务器",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),
        .init(name: "refreshLibrary", group: .server, permission: .reversible, summary: "刷新本地目录"),
        .init(name: "getSyncStatus", group: .server, permission: .readOnly, summary: "获取同步状态"),
        .init(name: "removeServer", group: .server, permission: .destructive, summary: "删除服务器（仅本地清理）",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),

        // MARK: 第一阶段统一命名工具（v2 工具集）

        // App / 设备状态
        .init(name: "app_get_context", group: .catalog, permission: .readOnly, summary: "获取 App 上下文（页面/服务器/当前歌曲/播放状态/网络）"),
        .init(name: "app_open_page", group: .catalog, permission: .readOnly, summary: "打开指定页面",
              parameters: [.init(name: "page", required: true, description: "首页/音乐库/搜索/AI助手/设置/当前播放/歌词/播放队列/下载管理/服务器管理")]),
        .init(name: "app_get_feature_status", group: .catalog, permission: .readOnly, summary: "查询后台播放/Siri/快捷指令/本地网络等能力状态"),
        .init(name: "device_get_network_status", group: .catalog, permission: .readOnly, summary: "获取网络类型与服务器可达性"),
        .init(name: "device_get_audio_route", group: .catalog, permission: .readOnly, summary: "获取当前音频输出设备"),
        .init(name: "device_get_storage_status", group: .catalog, permission: .readOnly, summary: "获取存储占用与剩余空间"),

        // 服务器
        .init(name: "server_list", group: .server, permission: .readOnly, summary: "列出已配置的服务器"),
        .init(name: "server_get_current", group: .server, permission: .readOnly, summary: "获取当前服务器信息（不含凭据）"),
        .init(name: "server_test_connection", group: .server, permission: .readOnly, summary: "对当前服务器执行真实连通性测试"),
        .init(name: "server_get_capabilities", group: .server, permission: .readOnly, summary: "获取当前服务器支持的 OpenSubsonic 能力"),
        .init(name: "server_sync_status", group: .server, permission: .readOnly, summary: "查看资料库同步状态与上次同步时间"),
        .init(name: "server_sync_start", group: .server, permission: .reversible, summary: "触发一次音乐库增量同步（后台执行，本地未找到歌曲时可先同步）"),
        .init(name: "server_search", group: .server, permission: .readOnly, summary: "在服务器上在线搜索歌曲（HTTP，本地无结果时使用）",
              parameters: [
                .init(name: "query", required: true, description: "搜索关键词"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),

        // 本地库
        .init(name: "library_get_summary", group: .catalog, permission: .readOnly, summary: "获取本地资料库统计摘要"),
        .init(name: "library_search", group: .catalog, permission: .readOnly, summary: "统一搜索歌曲/专辑/艺术家/歌单/流派/歌词",
              parameters: [
                .init(name: "query", required: true, description: "搜索关键词"),
                .init(name: "kind", required: false, description: "song/album/artist/playlist/genre/lyrics，默认全部"),
                .init(name: "limit", required: false, description: "返回数量，默认 30，最多 100"),
                .init(name: "onlyFavorites", required: false, description: "只搜收藏（true/false）"),
                .init(name: "onlyOffline", required: false, description: "只搜离线（true/false）"),
              ]),
        .init(name: "library_get_catalog_index", group: .catalog, permission: .readOnly, summary: "查看曲库分类索引（歌手/专辑/流派/语言/年代/总览），了解曲库里有什么，推荐前先用它",
              parameters: [.init(name: "category", required: false, description: "artists/albums/genres/languages/years/overview，默认 overview")],
              maxResultCharacters: ContextManager.maxIndexCharacters),
        .init(name: "library_get_catalog_tracks", group: .catalog, permission: .readOnly, summary: "按分类取歌曲清单（artist/album/genre/language/year/favorites/recent/popular/all），只含元数据，供推荐筛选",
              parameters: [
                .init(name: "category", required: true, description: "artist/album/genre/language/year/favorites/recent/popular/all"),
                .init(name: "value", required: false, description: "分类值（如 周杰伦 / 中文 / 摇滚 / 2020）"),
                .init(name: "limit", required: false, description: "返回数量，默认 100，最多 500"),
              ], maxResultCharacters: ContextManager.maxIndexCharacters),
        .init(name: "library_index_v2_status", group: .catalog, permission: .readOnly, summary: "查看 AI 推荐索引 V2 的总数、已完成和待分类数；完整构建任务必须先调用本工具，并持续到 pending=0", maxResultCharacters: 24_000),
        .init(name: "library_index_v2_read", group: .catalog, permission: .readOnly, summary: "读取已完成的 AI 推荐索引 V2 条目及全部分类标签，可按维度和标签筛选",
              parameters: [
                .init(name: "dimension", required: false, description: "mood/scene/vocal/texture/style/energy/tempo/acousticness/danceability/tag"),
                .init(name: "value", required: false, description: "要匹配的标签值，如 通勤、深夜、平静"),
                .init(name: "limit", required: false, description: "返回 1-100 条，默认 50"),
              ], maxResultCharacters: 24_000),
        .init(name: "library_index_v2_next_batch", group: .catalog, permission: .readOnly, summary: "取下一批待分类曲目元数据；仅在用户明确要求构建或继续索引时使用；每个真实 ID 必须恰好分类一次，不能加入歌词、路径或播放地址",
              parameters: [.init(name: "limit", required: false, description: "每批 1-100；Runtime 会按模型输出预算选择安全分片")],
              maxResultCharacters: ContextManager.maxIndexCharacters),
        .init(name: "library_index_v2_write_batch", group: .catalog, permission: .reversible, summary: "写入刚刚由 library_index_v2_next_batch 返回的推荐索引分类；items 必须严格覆盖该批全部真实 ID 各一次。mode=full 写固定维度与可选开放 semanticTags；mode=semanticTagsOnly 只写 id、mode 和 semanticTags，不能伪造固定维度。开放 semanticTags 没有全局数量硬上限；写入成功后必须重新调用 next_batch 获取下一批，直到 pending=0",
              parameters: [.init(
                name: "items",
                required: true,
                description: "分类数组。full：id、固定维度、semanticTags 与 confidence；semanticTagsOnly：id、mode=semanticTagsOnly、semanticTags。semanticTags 仅限有音乐意义且有区分度的开放标签，优先复用 canonical 标签，词库不设全局硬上限。",
                schemaJSON: Self.recommendationClassificationArraySchema
              )],
              maxResultCharacters: 24_000),
        .init(name: "library_select_tracks", group: .catalog, permission: .readOnly, summary: "集合查询：一次筛选语言/流派/艺术家/年代，按本地热度代理排序，返回候选歌曲清单（多首任务优先用这个，不要逐个歌手搜索）",
              parameters: [
                .init(name: "languages", required: false, description: "语言数组，如 [\"中文\",\"粤语\"]",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "genres", required: false, description: "流派数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "artists", required: false, description: "艺术家数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "yearFrom", required: false, description: "起始年份"),
                .init(name: "yearTo", required: false, description: "结束年份"),
                .init(name: "favoritesOnly", required: false, description: "true=只要收藏"),
                .init(name: "excludeRecentlyPlayed", required: false, description: "true=排除最近播放"),
                .init(name: "recentDays", required: false, description: "排除最近 N 天，默认 7"),
                .init(name: "excludeTrackIDs", required: false, description: "要排除的 GlobalID 数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "playableOnly", required: false, description: "deprecated：不再按瞬时 streamURL 过滤；Auralis 播放时会向服务器刷新/在线流播（默认 false）"),
                .init(name: "sort", required: false, description: "popularityProxy/favorites/recentlyPlayed/title/random，默认 popularityProxy（recentlyAdded 由 library_get_recently_added 提供）"),
                .init(name: "limit", required: false, description: "返回数量，默认 50，最多 100"),
              ]),
        .init(name: "library_index_v2_tag_catalog", group: .catalog, permission: .readOnly, summary: "分页查看当前已有的开放语义标签词库及使用次数，便于构建 V2 时优先复用 canonical 标签（分页只是读取方式，不是标签数量限制）",
              parameters: [
                .init(name: "query", required: false, description: "可选：按标签名筛选"),
                .init(name: "limit", required: false, description: "每页 1-100 条，默认 50"),
                .init(name: "offset", required: false, description: "分页起始位置，默认 0，可无限向后翻页",
                      schemaJSON: #"{"type":"integer","minimum":0}"#),
              ], maxResultCharacters: 16_000),
        .init(name: "library_get_song", group: .catalog, permission: .readOnly, summary: "获取单曲详情（含格式/码率/收藏/评分/离线状态）",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "music_appreciate", group: .catalog, permission: .readOnly, summary: "为正在播放或指定歌曲准备分层鉴赏证据：已核验元数据、私人播放数据与可用的外部大众评价；没有 Community Evidence 时明确标记不可用",
              parameters: [.init(name: "trackID", required: false, description: "可选 GlobalTrackID；省略时鉴赏当前正在播放的歌曲")]),
        .init(name: "library_get_album", group: .catalog, permission: .readOnly, summary: "获取专辑详情",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "library_get_artist", group: .catalog, permission: .readOnly, summary: "获取艺术家详情",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "library_get_playlist", group: .catalog, permission: .readOnly, summary: "获取歌单详情",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "library_get_recently_added", group: .catalog, permission: .readOnly, summary: "获取最近添加的歌曲",
              parameters: [
                .init(name: "days", required: false, description: "最近 N 天，默认 30"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),
        .init(name: "library_get_most_played", group: .catalog, permission: .readOnly, summary: "获取最常播放的歌曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 20")]),
        .init(name: "library_get_recently_played", group: .catalog, permission: .readOnly, summary: "获取最近播放",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 20")]),
        .init(name: "library_get_starred", group: .catalog, permission: .readOnly, summary: "获取收藏的歌曲"),
        .init(name: "library_get_random_songs", group: .catalog, permission: .readOnly, summary: "获取随机歌曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 10")]),
        .init(name: "library_get_similar_songs", group: .catalog, permission: .readOnly, summary: "获取相似歌曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "library_get_genres", group: .catalog, permission: .readOnly, summary: "获取全部流派及其歌曲数量（按歌曲数降序）",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 30")]),
        .init(name: "library_get_tracks_by_genre", group: .catalog, permission: .readOnly, summary: "获取某流派下的歌曲（按流派浏览）",
              parameters: [
                .init(name: "genre", required: true, description: "流派名（大小写不敏感，如 爵士/Jazz）"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),

        // 播放
        .init(name: "playback_get_state", group: .playback, permission: .readOnly, summary: "获取播放器状态"),
        .init(name: "playback_play_song", group: .playback, permission: .reversible, summary: "播放指定歌曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "playback_play_album", group: .playback, permission: .reversible, summary: "播放指定专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "playback_play_artist", group: .playback, permission: .reversible, summary: "播放指定艺术家的歌曲",
              parameters: [
                .init(name: "artistID", required: true, description: "GlobalArtistID"),
                .init(name: "scope", required: false, description: "top/全部/random/专辑名"),
              ]),
        .init(name: "playback_play_playlist", group: .playback, permission: .reversible, summary: "播放指定歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "playback_play_random", group: .playback, permission: .reversible, summary: "随机播放资料库歌曲",
              parameters: [.init(name: "limit", required: false, description: "队列数量，默认 30")]),
        .init(name: "playback_pause", group: .playback, permission: .reversible, summary: "暂停播放"),
        .init(name: "playback_resume", group: .playback, permission: .reversible, summary: "继续播放"),
        .init(name: "playback_next", group: .playback, permission: .reversible, summary: "下一首"),
        .init(name: "playback_previous", group: .playback, permission: .reversible, summary: "上一首"),
        .init(name: "playback_seek", group: .playback, permission: .reversible, summary: "跳到指定秒数",
              parameters: [.init(name: "seconds", required: true, description: "目标秒数")]),
        .init(name: "playback_set_shuffle", group: .playback, permission: .reversible, summary: "设置随机播放",
              parameters: [.init(name: "enabled", required: true, description: "true/false")]),
        .init(name: "playback_set_repeat", group: .playback, permission: .reversible, summary: "设置循环模式（off/all/one）",
              parameters: [.init(name: "mode", required: true, description: "off/all/one")]),
        .init(name: "playback_set_speed", group: .playback, permission: .reversible, summary: "设置播放速度（0.5x–2.0x）",
              parameters: [.init(name: "rate", required: true, description: "播放速度，如 1.0 / 1.25 / 1.5")]),
        .init(name: "playback_set_sleep_timer", group: .playback, permission: .reversible, summary: "设置睡眠定时（off/afterMinutes/afterCurrentTrack/afterCurrentAlbum/afterCurrentQueue）",
              parameters: [
                .init(name: "mode", required: true, description: "off/afterMinutes/afterCurrentTrack/afterCurrentAlbum/afterCurrentQueue"),
                .init(name: "minutes", required: false, description: "afterMinutes 时分钟数，默认 30"),
              ]),
        .init(name: "playback_cancel_sleep_timer", group: .playback, permission: .reversible, summary: "取消睡眠定时"),
        .init(name: "playback_get_sleep_timer", group: .playback, permission: .readOnly, summary: "查询睡眠定时状态"),

        // 队列
        .init(name: "queue_get", group: .playback, permission: .readOnly, summary: "获取当前播放队列"),
        .init(name: "queue_append", group: .playback, permission: .reversible, summary: "把歌曲追加到队列末尾",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "queue_play_next", group: .playback, permission: .reversible, summary: "把歌曲插入到当前歌曲之后播放",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "queue_replace", group: .playback, permission: .reversible, summary: "替换整个播放队列",
              parameters: [.init(name: "trackIDs", required: true, description: "GlobalTrackID 数组",
                                 schemaJSON: #"{"type":"array","items":{"type":"string"}}"#)]),
        .init(name: "queue_clear", group: .playback, permission: .reversible, summary: "清空播放队列"),
        .init(name: "queue_shuffle_remaining", group: .playback, permission: .reversible, summary: "只随机尚未播放的剩余队列"),
        .init(name: "queue_move", group: .playback, permission: .reversible, summary: "调整队列中歌曲顺序",
              parameters: [
                .init(name: "from", required: true, description: "原索引"),
                .init(name: "to", required: true, description: "目标索引"),
              ]),
        .init(name: "queue_save_as_playlist", group: .playlist, permission: .reversible, summary: "把当前队列保存为歌单",
              parameters: [.init(name: "name", required: true, description: "歌单名称")]),

        // 收藏 / 歌单 / 歌词 / 下载 / 缓存 / 统计 / 诊断
        .init(name: "favorite_set", group: .annotation, permission: .reversible, summary: "设置收藏（歌曲/专辑/艺术家）",
              parameters: [
                .init(name: "targetType", required: true, description: "song/album/artist"),
                .init(name: "targetID", required: true, description: "GlobalID"),
                .init(name: "value", required: true, description: "true=收藏 / false=取消收藏"),
              ]),
        .init(name: "playlist_create", group: .playlist, permission: .reversible, summary: "新建歌单",
              parameters: [.init(name: "name", required: true, description: "歌单名称")]),
        .init(name: "playlist_add_songs", group: .playlist, permission: .reversible, summary: "把歌曲加入歌单",
              parameters: [
                .init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                .init(name: "trackIDs", required: true, description: "GlobalTrackID 数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
              ]),
        .init(name: "preference_set_disliked", group: .annotation, permission: .reversible, summary: "设置/取消“不喜欢”：不喜欢的歌曲不会再出现在任何自动推荐、随机播放、相似歌曲、智能队列或发现模块中；显式搜索、打开专辑/歌单或直接点播仍然允许播放",
              parameters: [
                .init(name: "trackID", required: true, description: "GlobalTrackID"),
                .init(name: "value", required: true, description: "true=标记不喜欢 / false=取消不喜欢"),
              ]),
        .init(name: "library_get_disliked", group: .catalog, permission: .readOnly, summary: "读取已标记“不喜欢”的歌曲（含标题/艺术家/专辑）",
              parameters: [
                .init(name: "limit", required: false, description: "返回数量，默认 50，最大 200"),
              ]),
        .init(name: "music_get_public_evidence", group: .catalog, permission: .readOnly, summary: "获取当前/指定歌曲的真实公开音乐资料证据（MusicBrainz 身份与评分、CritiqueBrainz 聚合与少量评论摘要、ListenBrainz 收听统计）；没有真实数据时不得编造大众评价",
              parameters: [
                .init(name: "trackID", required: false, description: "GlobalTrackID；省略时使用当前播放歌曲"),
                .init(name: "refresh", required: false, description: "true=忽略缓存强制刷新，默认 false"),
              ]),
        .init(name: "lyrics_get", group: .catalog, permission: .readOnly, summary: "获取歌词状态",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "media_download_offline", group: .catalog, permission: .reversible, summary: "下载歌曲到本地离线缓存",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "cache_get_status", group: .catalog, permission: .readOnly, summary: "获取缓存容量（封面/歌词/离线音频）"),
        .init(name: "recommend_by_mood", group: .catalog, permission: .readOnly, summary: "按情绪推荐歌曲（深夜/放松/通勤/学习/运动/伤感/治愈/怀旧/安静/高能量）",
              parameters: [
                .init(name: "mood", required: true, description: "情绪：深夜/放松/通勤/学习/运动/伤感/治愈/怀旧/安静/高能量"),
                .init(name: "limit", required: false, description: "返回数量，默认 10"),
              ]),
        .init(name: "recommend_by_constraints", group: .catalog, permission: .readOnly, summary: "组合约束推荐（中文/收藏/排除最近/年代/流派/时长/无损/离线/排除艺术家）",
              parameters: [
                .init(name: "languages", required: false, description: "逗号分隔语言，如 中文"),
                .init(name: "genres", required: false, description: "逗号分隔流派"),
                .init(name: "yearFrom", required: false, description: "起始年份"),
                .init(name: "yearTo", required: false, description: "结束年份"),
                .init(name: "favoritesOnly", required: false, description: "true=只从收藏选择"),
                .init(name: "excludeRecentlyPlayed", required: false, description: "true=排除最近播放"),
                .init(name: "onlyOffline", required: false, description: "true=只要离线歌曲"),
                .init(name: "excludeArtist", required: false, description: "排除的艺术家名"),
                .init(name: "maxTotalMinutes", required: false, description: "限定总时长（分钟）"),
                .init(name: "losslessOnly", required: false, description: "true=只要无损（FLAC/ALAC/WAV/AIFF）"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),
        .init(name: "smart_queue_generate", group: .catalog, permission: .readOnly, summary: "生成智能队列预览（不替换队列；确认后请用 queue_replace）",
              parameters: [.init(name: "limit", required: false, description: "数量，默认 20")]),
        .init(name: "diagnostics_export_report", group: .catalog, permission: .readOnly, summary: "导出脱敏诊断报告"),
        .init(name: "diagnostics_now_playing", group: .catalog, permission: .readOnly, summary: "对比控制中心/锁屏与 App 内播放状态"),
        .init(name: "ios_siri_get_status", group: .catalog, permission: .readOnly, summary: "查询 Siri 集成状态"),
        .init(name: "ios_shortcuts_list", group: .catalog, permission: .readOnly, summary: "列出快捷指令 App 中可用的操作"),
        .init(name: "library_find_duplicates", group: .catalog, permission: .readOnly, summary: "查找疑似重复歌曲（只报告，不删除）",
              parameters: [.init(name: "limit", required: false, description: "最多报告组数，默认 10")]),
        .init(name: "library_find_metadata_issues", group: .catalog, permission: .readOnly, summary: "查找元数据问题（缺艺术家/专辑/年份/流派/封面/异常时长）",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "library_find_broken_artwork", group: .catalog, permission: .readOnly, summary: "查找封面标识存在但本地磁盘缓存缺失的歌曲",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "library_find_stale_cache", group: .catalog, permission: .readOnly, summary: "查找本地音频缓存中已不存在的曲目（陈旧缓存）",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "library_find_unplayable", group: .catalog, permission: .readOnly, summary: "查找无播放地址且未离线的歌曲",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "stats_get_top_items", group: .catalog, permission: .readOnly, summary: "获取最常听的艺术家/专辑/歌曲",
              parameters: [
                .init(name: "kind", required: true, description: "artist/album/track"),
                .init(name: "limit", required: false, description: "返回数量，默认 10"),
              ]),
        .init(name: "stats_get_format_distribution", group: .catalog, permission: .readOnly, summary: "获取音频格式分布"),
        .init(name: "stats_get_storage_distribution", group: .catalog, permission: .readOnly, summary: "获取存储/缓存分布"),
        .init(name: "stats_get_listening_summary", group: .catalog, permission: .readOnly, summary: "获取收听统计摘要"),
        .init(name: "diagnostics_playback", group: .catalog, permission: .readOnly, summary: "诊断播放器状态（缓冲/来源/错误/音频会话/队列）"),
        .init(name: "diagnostics_get_recent_errors", group: .catalog, permission: .readOnly, summary: "获取最近脱敏错误记录",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 20")]),

        // MARK: 记忆与技能
        .init(name: "memory_save", group: .memory, permission: .reversible, summary: "记住关于主人的一条信息（跨会话有效）",
              parameters: [
                .init(name: "key", required: true, description: "字段名，如 名字 / 喜欢的歌手 / 生日"),
                .init(name: "value", required: true, description: "要记住的内容"),
              ]),
        .init(name: "memory_list", group: .memory, permission: .readOnly, summary: "查看已记住的关于主人的信息"),
        .init(name: "memory_delete", group: .memory, permission: .reversible, summary: "删除一条记忆",
              parameters: [.init(name: "key", required: true, description: "要删除的记忆字段名")]),
        .init(name: "memory_clear", group: .memory, permission: .reversible, summary: "清空全部记忆"),
        .init(name: "skill_create", group: .memory, permission: .reversible, summary: "创建一段可复用指令（skill 文件），之后可读取使用",
              parameters: [
                .init(name: "name", required: true, description: "技能名，简短英文或中文"),
                .init(name: "instructions", required: true, description: "完整技能指令"),
              ]),
        .init(name: "skill_list", group: .memory, permission: .readOnly, summary: "查看已创建的技能列表"),
        .init(name: "skill_read", group: .memory, permission: .readOnly, summary: "读取某个技能的完整指令",
              parameters: [.init(name: "name", required: true, description: "技能名")]),
        .init(name: "skill_delete", group: .memory, permission: .reversible, summary: "删除一个技能",
              parameters: [.init(name: "name", required: true, description: "技能名")]),

    ]

    public static func descriptor(for name: String) -> ToolDescriptor? {
        all.first { $0.name == name }
    }

    /// 元数据查找与执行的唯一公开入口。调用方无需再判断系统工具或旧工具分支。
    public static func execute(
        _ call: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        allowsLyrics: Bool = false
    ) async -> ToolResult {
        guard let descriptor = descriptor(for: call.name) else {
            return ToolResult(
                call: call,
                permission: .readOnly,
                success: false,
                summary: "未知工具：\(call.name)"
            )
        }
        if SystemToolNames.contains(call.name) {
            guard let systemService else {
                return ToolResult(call: call, permission: descriptor.permission, success: false, summary: "系统服务不可用：当前设备未提供该系统能力。")
            }
            return await SystemToolExecutor.execute(call, descriptor: descriptor, systemService: systemService)
        }
        return await AgentToolkit.executeRegistered(
            call,
            descriptor: descriptor,
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            externalMusicService: externalMusicService,
            allowsLyrics: allowsLyrics
        )
    }
}
