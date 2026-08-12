import AIKit
import Foundation

/// 动态工具加载：Schema 优化器，只决定“这次把哪些工具的 JSON Schema 给模型”，
/// 绝不决定 Agent 能否完成任务（permissive runtime 里已注册工具默认全部可执行）。
///
/// 规则：CommonSafeTools ∪ IntentSuggestedTools ∪ KeywordSuggestedTools ∪
/// TaskRequiredTools（纯加法）。任务进行中由 AgentRunner 每轮用「用户原文 + 模型
/// 已输出文本 + 已执行工具」重新展开，第一轮没选中的工具不会永久缺失。
///
/// 选择结果同时驱动：
/// 1) 原生 function calling 的 `tools` 请求体；
/// 2) 系统提示词中的工具清单。
///
/// 旧式驼峰别名（searchTracks、playTrack 等）仍注册、可执行，但在此处统一映射回
/// 新式 canonical 名称，避免同一语义的重复 schema 同时暴露给模型。
public enum ToolSelector {
    // MARK: - 工具组（新式名称为主，含无新式替代的旧式名称）

    /// 长期可获得（CommonSafeTools）：核心 + 需求文档 §6.1 的常用工具全部常驻 schema。
    /// 原生 function calling 只能调用 schema 内工具；为了让模型在任意任务中都能直接
    /// 使用这些能力（而不依赖脆弱的关键词命中），它们必须常驻。仍保持远小于全量注册表
    /// 的有界子集（旧别名在此统一映射回 canonical，不重复占位）。
    static let coreNames: [String] = [
        // 本地库查询
        "library_get_summary", "library_search", "library_select_tracks",
        "library_get_catalog_index", "library_get_catalog_tracks", "library_get_song",
        "library_get_album", "library_get_artist", "library_get_playlist",
        "library_get_starred", "library_get_recently_played", "library_get_random_songs",
        "library_get_similar_songs", "library_get_genres", "library_get_tracks_by_genre",
        "library_get_least_played", "library_get_downloaded",
        "music_appreciate",
        // 推荐索引 V2（长任务：后续轮次可能只写「继续」，必须常驻 schema）
        "library_index_v2_status", "library_index_v2_read", "library_index_v2_next_batch", "library_index_v2_write_batch", "library_index_v2_tag_catalog",
        // 推荐 / 发现
        "recommend_by_mood", "recommend_by_constraints", "smart_queue_generate",
        // 播放
        "playback_get_state",
        "playback_play_song", "playback_play_album", "playback_play_artist",
        "playback_play_playlist", "playback_play_random",
        "playback_pause", "playback_resume",
        "playback_next", "playback_previous", "playback_seek",
        "playback_set_shuffle", "playback_set_repeat",
        // 队列
        "queue_get", "queue_append", "queue_play_next", "queue_replace", "queue_clear",
        "queue_remove", "queue_move", "queue_shuffle_remaining",
        // 歌单
        "listPlaylists", "playlist_create", "playlist_add_songs",
        "playlist_rename", "playlist_remove_songs", "playlist_move",
        "playlist_duplicate", "playlist_merge", "playlist_delete",
        // 收藏 / 不喜欢 / 评分
        "favorite_set", "preference_set_disliked", "library_get_disliked", "rating_set",
        // 服务器
        "server_get_current", "server_list", "server_search", "server_sync_status",
        "server_switch", "server_remove",
        // 歌词 / 公开音乐资料
        "lyrics_get", "music_get_public_evidence",
        // 最终展示协议
        "result_present_tracks",
        // 音乐下载（MoviePilot）
        "music_download",
        // 记忆与技能
        "memory_save", "memory_list", "memory_delete", "memory_clear",
        "skill_create", "skill_list", "skill_read", "skill_delete",
    ]

    /// 歌单相关。
    static let playlistNames: [String] = [
        "listPlaylists", "library_get_playlist",
        "playlist_create", "playlist_add_songs", "addTracksToPlaylist", "removeTracksFromPlaylist",
        "queue_save_as_playlist", "favorite_set",
    ]

    /// 收藏 / 评分 / 不喜欢相关。
    static let annotationNames: [String] = [
        "getFavorites", "library_get_starred",
        "likeTrack", "unlikeTrack",
        "favoriteAlbum", "favoriteArtist",
        "setRating", "clearRating",
        "preference_set_disliked", "library_get_disliked",
    ]

    /// 服务器 / 同步相关。
    static let serverNames: [String] = [
        "server_get_current", "server_list",
        "server_test_connection", "server_get_capabilities",
        "server_sync_status", "server_sync_start",
        "server_search", "removeServer",
    ]

    /// 推荐 / 随机相关。
    static let recommendationNames: [String] = [
        "recommend_by_mood", "recommend_by_constraints",
        "smart_queue_generate",
        "library_get_random_songs", "library_get_most_played",
        "library_get_recently_played", "library_get_similar_songs",
        "library_get_genres", "library_get_tracks_by_genre",
        "music_get_public_evidence",
        "queue_replace", "queue_append",
    ]

    /// 诊断 / 维护 / 统计相关。
    static let diagnosticsNames: [String] = [
        "diagnostics_playback", "diagnostics_now_playing",
        "diagnostics_get_recent_errors", "diagnostics_export_report",
        "library_find_duplicates", "library_find_metadata_issues",
        "library_find_unplayable", "stats_get_listening_summary",
        "device_get_audio_route", "app_get_context",
        "cache_get_status",
    ]

    /// 旧式别名 → 新式 canonical 名称（执行兼容由注册表保留，schema 只暴露 canonical）。
    /// 只在两个工具语义完全等价时映射；无新式替代的旧工具（deletePlaylist、
    /// removeTracksFromPlaylist、setRating、removeServer 等）不在映射中。
    static let canonicalAliases: [String: String] = [
        "searchTracks": "library_search",
        "searchAlbums": "library_search",
        "searchArtists": "library_search",
        "getTrack": "library_get_song",
        "getAlbum": "library_get_album",
        "getArtist": "library_get_artist",
        "getFavorites": "library_get_starred",
        "getRecentHistory": "library_get_recently_played",
        "getSimilarTracks": "library_get_similar_songs",
        "getPlaylist": "library_get_playlist",
        "playTrack": "playback_play_song",
        "playAlbum": "playback_play_album",
        "playPlaylist": "playback_play_playlist",
        "pause": "playback_pause",
        "resume": "playback_resume",
        "next": "playback_next",
        "previous": "playback_previous",
        "seek": "playback_seek",
        "addToQueue": "queue_append",
        "playNext": "queue_play_next",
        "replaceQueue": "queue_replace",
        "clearQueue": "queue_clear",
        "addTracksToPlaylist": "playlist_add_songs",
        "listServers": "server_list",
        "getActiveServer": "server_get_current",
        "testServerConnection": "server_test_connection",
        "likeTrack": "favorite_set",
        "unlikeTrack": "favorite_set",
        "favoriteAlbum": "favorite_set",
        "unfavoriteAlbum": "favorite_set",
        "favoriteArtist": "favorite_set",
        "unfavoriteArtist": "favorite_set",
        "getLeastPlayed": "library_get_least_played",
        "getDownloadedTracks": "library_get_downloaded",
        "removeFromQueue": "queue_remove",
        "renamePlaylist": "playlist_rename",
        "removeTracksFromPlaylist": "playlist_remove_songs",
        "reorderPlaylist": "playlist_move",
        "duplicatePlaylist": "playlist_duplicate",
        "mergePlaylists": "playlist_merge",
        "deletePlaylist": "playlist_delete",
        "setRating": "rating_set",
        "clearRating": "rating_set",
        "switchServer": "server_switch",
        "removeServer": "server_remove",
    ]

    /// 把旧别名映射为 canonical 并按首次出现顺序去重。
    static func resolvedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { canonicalAliases[$0] ?? $0 }
            .filter { seen.insert($0).inserted }
    }

    /// 按用户请求选择工具集（去重保序；旧别名映射回 canonical）。
    public static func select(for userText: String, all: [ToolDescriptor]) -> [ToolDescriptor] {
        let lower = userText.lowercased()
        var names = coreNames

        if containsAny(lower, ["歌单", "playlist", "播放列表"]) { names += playlistNames }
        if containsAny(lower, ["收藏", "喜欢", "评分", "不喜欢", "不感兴趣", "favorite", "star", "heart", "dislike"]) { names += annotationNames }
        if containsAny(lower, ["服务器", "同步", "连接", "在线", "server", "sync", "connect"]) { names += serverNames }
        if containsAny(lower, ["推荐", "随机", "recommand", "shuffle", "深夜", "伤感", "女声", "标签", "挑选", "筛选", "清单", "热门", "火", "选", "列", "索引", "分类", "归类", "标注", "v2", "大众评价", "乐评", "评分", "资料", "开车", "驾驶", "通勤", "提神", "运动", "健身", "跑步", "学习", "工作", "睡觉", "睡前", "放松", "安静", "有精神", "高能量", "来点", "来几首", "放几首", "想听", "适合", "给我选", "给我挑", "推荐一些", "挑几首", "选几首"]) { names += recommendationNames }
        if containsAny(lower, ["为什么", "停止", "失败", "卡顿", "诊断", "原因", "diagnos", "error"]) { names += diagnosticsNames }
        if containsAny(lower, ["歌词", "lyric"]) { names += ["lyrics_get"] }
        if containsAny(lower, ["下载", "离线", "download", "offline"]) { names += ["media_download_offline", "getDownloadedTracks"] }
        if containsAny(lower, ["记住", "记忆", "我是谁", "我叫", "名字", "喜欢", "skill", "技能", "memory"]) { names += ["memory_save", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"] }

        let unique = Self.resolvedNames(names)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        return unique.compactMap { byName[$0] }
    }

    /// 意图感知选择：KeywordSuggested ∪ IntentSuggested ∪ TaskRequired，纯加法。
    /// 意图只是路由提示，不再裁剪能力；不会把任何已注册工具按 policy 过滤掉。
    public static func select(
        for userText: String,
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        all: [ToolDescriptor]
    ) -> [ToolDescriptor] {
        var selected = select(for: userText, all: all)
        let intentNames: Set<String>
        switch intent {
        case .conversation:
            intentNames = ["library_get_summary", "app_get_context", "memory_list"]
        case .librarySearch:
            intentNames = ["library_search", "library_get_song", "library_get_album", "library_get_artist", "server_search"]
        case .playbackControl:
            intentNames = ["playback_get_state", "playback_play_song", "playback_pause", "playback_resume", "playback_next", "playback_previous", "playback_seek", "playback_set_shuffle", "playback_set_repeat"]
        case .musicDiscovery:
            intentNames = ["library_get_catalog_index", "library_get_catalog_tracks", "library_select_tracks", "recommend_by_mood", "recommend_by_constraints", "library_get_similar_songs", "queue_replace", "queue_append"]
        case .queueManagement:
            intentNames = ["queue_get", "queue_append", "queue_play_next", "queue_replace", "queue_clear", "queue_move", "queue_shuffle_remaining", "queue_save_as_playlist"]
        case .playlistManagement:
            intentNames = ["listPlaylists", "library_get_playlist", "playlist_create", "playlist_add_songs", "removeTracksFromPlaylist", "deletePlaylist"]
        case .libraryManagement:
            intentNames = ["library_get_summary", "library_index_v2_status", "library_index_v2_read", "library_index_v2_next_batch", "library_index_v2_write_batch", "library_index_v2_tag_catalog", "favorite_set", "setRating", "clearRating", "preference_set_disliked", "library_get_disliked"]
        case .serverManagement:
            intentNames = Set(serverNames)
        case .diagnostics:
            intentNames = Set(diagnosticsNames + serverNames)
        case .musicAppreciation:
            intentNames = ["library_search", "library_get_song", "music_appreciate", "music_get_public_evidence"]
        case .musicDownload:
            intentNames = ["library_search", "server_search", "music_download", "media_download_offline", "getDownloadedTracks"]
        case .memoryManagement:
            intentNames = ["memory_save", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"]
        }
        let names = selected.map(\.name) + intentNames.sorted()
        let unique = Self.resolvedNames(names)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        return unique.compactMap { byName[$0] }
    }

    /// 把选中的工具描述转为原生 function calling 定义。
    public static func toolDefinitions(from descriptors: [ToolDescriptor]) -> [AIToolDefinition] {
        descriptors.map { descriptor in
            AIToolDefinition(
                name: descriptor.name,
                description: descriptor.summary,
                parametersJSON: Self.parametersJSON(for: descriptor)
            )
        }
    }

    /// 由 ToolParameter 生成最小 JSON Schema。
    static func parametersJSON(for descriptor: ToolDescriptor) -> String? {
        guard !descriptor.parameters.isEmpty else { return nil }
        var properties: [String: Any] = [:]
        for parameter in descriptor.parameters {
            if let schemaJSON = parameter.schemaJSON,
               let data = schemaJSON.data(using: .utf8),
               var schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                schema["description"] = parameter.description
                properties[parameter.name] = schema
            } else {
                properties[parameter.name] = ["type": "string", "description": parameter.description]
            }
        }
        let required = descriptor.parameters.filter(\.required).map(\.name)
        let schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0.lowercased()) }
    }
}
