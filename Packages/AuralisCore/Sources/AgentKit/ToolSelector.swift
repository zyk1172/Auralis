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
        "library_search", "library_select_tracks", "library_get_catalog_index", "library_get_catalog_tracks", "library_get_song",
        "playback_get_state",
        "playback_play_song", "playback_play_album", "playback_play_artist",
        "playback_play_playlist", "playback_play_random",
        "playback_pause", "playback_resume",
        "playback_next", "playback_previous", "playback_seek",
        "playback_set_shuffle", "playback_set_repeat",
        "queue_get", "queue_append", "queue_play_next", "queue_replace", "queue_clear",
        "playTrack",
    ]

    /// 歌单相关。
    static let playlistNames: [String] = [
        "listPlaylists", "library_get_playlist",
        "playlist_create", "playlist_add_songs",
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
        if containsAny(lower, ["推荐", "随机", "recommand", "shuffle", "深夜", "伤感", "女声", "标签", "挑选", "筛选", "清单", "热门", "火", "选", "列"]) { names += recommendationNames }
        if containsAny(lower, ["为什么", "停止", "失败", "卡顿", "诊断", "原因", "diagnos", "error"]) { names += diagnosticsNames }
        if containsAny(lower, ["歌词", "lyric"]) { names += ["lyrics_get"] }
        if containsAny(lower, ["下载", "离线", "download", "offline"]) { names += ["media_download_offline", "getDownloadedTracks"] }

        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
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
        var properties: [String: [String: String]] = [:]
        for parameter in descriptor.parameters {
            properties[parameter.name] = ["type": "string", "description": parameter.description]
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
