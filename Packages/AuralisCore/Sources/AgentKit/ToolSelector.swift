import AIKit
import Foundation

/// 动态工具加载：根据用户意图只向模型暴露相关工具，降低 tool schema 对上下文的占用。
///
/// 规则集中维护：核心工具常驻，其余工具按关键词分组按需加入。
/// 选择结果同时驱动：
/// 1) 原生 function calling 的 `tools` 请求体；
/// 2) 系统提示词中的工具清单。
/// 未选中的工具仍然注册、可执行（模型若误用也不会报错），只是不再展示。
public enum ToolSelector {
    // MARK: - 工具组（新式名称为主，含无新式替代的旧式名称）

    /// 任何请求都可能需要的基础查询 / 播放能力。
    static let coreNames: [String] = [
        "library_get_summary",
        "library_search", "library_select_tracks", "library_get_catalog_index", "library_get_catalog_tracks", "library_get_song", "music_appreciate",
        // 推荐索引 V2 是一个长任务：后续轮次的输入往往只写「继续」或「开始」，
        // 不能仅靠本条文字匹配，否则 OpenAI Responses 的 tools 请求会漏掉它们。
        // 三个工具的实际执行仍受 AgentRunner 的明确意图规则约束。
        "library_index_v2_status", "library_index_v2_read", "library_index_v2_next_batch", "library_index_v2_write_batch",
        "playback_get_state",
        "playback_play_song", "playback_play_album", "playback_play_artist",
        "playback_play_playlist", "playback_play_random",
        // 常驻新式歌单加歌工具；旧式别名与按下标删除只在明确歌单意图时提供，
        // 避免每个请求都携带重复 schema，保持原生接口工具集有界。
        "playlist_add_songs",
        "playback_pause", "playback_resume",
        "playback_next", "playback_previous", "playback_seek",
        "playback_set_shuffle", "playback_set_repeat",
        "queue_get", "queue_append", "queue_play_next", "queue_replace", "queue_clear",
        // 音乐下载（MoviePilot）：用户点播不在库中的歌曲 / 直接要求下载时使用
        "music_download",
        // 记忆与技能：主人报出个人信息 / 创建、读取 skill 时使用（常驻，保证原生模式可用）
        "memory_save", "memory_list", "memory_delete", "memory_clear",
        "skill_create", "skill_list", "skill_read", "skill_delete",
    ]

    /// 歌单相关。
    static let playlistNames: [String] = [
        "listPlaylists", "library_get_playlist",
        "playlist_create", "playlist_add_songs", "addTracksToPlaylist", "removeTracksFromPlaylist",
        "queue_save_as_playlist", "favorite_set",
    ]

    /// 收藏 / 评分相关。
    static let annotationNames: [String] = [
        "getFavorites", "library_get_starred",
        "likeTrack", "unlikeTrack",
        "favoriteAlbum", "favoriteArtist",
        "setRating", "clearRating",
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

    /// 按用户请求选择工具集（去重保序）。
    public static func select(for userText: String, all: [ToolDescriptor]) -> [ToolDescriptor] {
        let lower = userText.lowercased()
        var names = coreNames

        if containsAny(lower, ["歌单", "playlist", "播放列表"]) { names += playlistNames }
        if containsAny(lower, ["收藏", "喜欢", "评分", "favorite", "star", "heart"]) { names += annotationNames }
        if containsAny(lower, ["服务器", "同步", "连接", "在线", "server", "sync", "connect"]) { names += serverNames }
        if containsAny(lower, ["推荐", "随机", "recommand", "shuffle", "深夜", "伤感", "女声", "标签", "挑选", "筛选", "清单", "热门", "火", "选", "列", "索引", "分类", "归类", "标注", "v2"]) { names += recommendationNames }
        if containsAny(lower, ["为什么", "停止", "失败", "卡顿", "诊断", "原因", "diagnos", "error"]) { names += diagnosticsNames }
        if containsAny(lower, ["歌词", "lyric"]) { names += ["lyrics_get"] }
        if containsAny(lower, ["下载", "离线", "download", "offline"]) { names += ["media_download_offline", "getDownloadedTracks"] }
        if containsAny(lower, ["记住", "记忆", "我是谁", "我叫", "名字", "喜欢", "skill", "技能", "memory"]) { names += ["memory_save", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"] }

        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        return unique.compactMap { byName[$0] }
    }

    /// 意图感知选择：先生成小型候选集，再用运行时策略收紧。
    /// 若关键词选择遗漏了该意图的必要工具，会从获准分组补入；不会把未授权工具暴露给模型。
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
            intentNames = ["library_get_summary", "library_index_v2_status", "library_index_v2_read", "library_index_v2_next_batch", "library_index_v2_write_batch", "favorite_set", "setRating", "clearRating"]
        case .serverManagement:
            intentNames = Set(serverNames)
        case .diagnostics:
            intentNames = Set(diagnosticsNames + serverNames)
        case .musicAppreciation:
            intentNames = ["library_search", "library_get_song", "music_appreciate"]
        case .musicDownload:
            intentNames = ["library_search", "server_search", "music_download", "media_download_offline", "getDownloadedTracks"]
        case .memoryManagement:
            intentNames = ["memory_save", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"]
        }
        let existing = Set(selected.map(\.name))
        selected.append(contentsOf: all.filter { intentNames.contains($0.name) && !existing.contains($0.name) })
        return selected.filter(policy.authorizes)
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
