import AIKit
import Foundation

/// 动态工具加载：Schema 优化器，只决定“这次把哪些工具的 JSON Schema 给模型”，
/// 绝不决定 Agent 能否完成任务：它只优化当前轮的 model schema；已注册工具的
/// 执行仍统一经过 ToolRuntime，受精确副作用授权或受信任 Stateful Skill 约束。
///
/// 规则：CommonSafeTools ∪ IntentSuggestedTools ∪ KeywordSuggestedTools ∪
/// TaskRequiredTools（纯加法）。任务进行中由 ToolLoop 每轮用「用户原文 + 模型
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

    /// 仅保留跨意图都安全且体积很小的工具。大部分工具由意图和用户关键词按需加入；
    /// 把完整音乐库、播放、歌单和索引 Schema 常驻会显著降低小模型的工具选择准确率。
    static let coreNames: [String] = [
        "tool_search", "capabilities_get", "app_get_context",
    ]

    static let recommendationIndexStatusNames: [String] = [
        "library_index_v2_status", "library_index_v2_read", "library_index_v2_tag_catalog",
    ]

    static let recommendationIndexBuildNames: [String] = [
        "library_index_v2_status", "library_index_v2_next_batch",
        "library_index_v2_write_batch", "library_index_v2_tag_catalog",
    ]

    static let playbackNames: [String] = [
        "library_search", "server_search", "playback_get_state",
        "playback_play_song", "playback_play_album", "playback_play_artist",
        "playback_play_playlist", "playback_play_random", "playback_pause",
        "playback_resume", "playback_next", "playback_previous", "playback_seek",
    ]

    static let queueNames: [String] = [
        "queue_get", "queue_append", "queue_append_many", "queue_play_next", "queue_play_next_many", "queue_replace", "queue_clear",
        "queue_remove", "queue_move", "queue_shuffle_remaining",
    ]

    /// 歌单相关。
    static let playlistNames: [String] = [
        "library_search",
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

    /// App / 系统 / 设备状态。它们属于真实能力查询，不应只因为没有“搜索/播放”
    /// 关键词而被动态 schema 隐藏。
    static let appDeviceNames: [String] = [
        "app_get_context", "app_open_page", "app_get_feature_status",
        "device_get_network_status", "device_get_audio_route", "device_get_storage_status",
        "ios_siri_get_status", "ios_shortcuts_list",
    ]

    static let statsNames: [String] = [
        "stats_get_top_items", "stats_get_format_distribution", "stats_get_storage_distribution",
        "library_get_recently_added", "library_get_most_played",
        "stats_get_listening_summary",
    ]

    static let catalogMaintenanceNames: [String] = [
        "library_find_duplicates", "library_find_metadata_issues", "library_find_broken_artwork",
        "library_find_stale_cache", "library_find_unplayable", "cache_get_status",
    ]

    /// 推荐 / 随机相关。
    static let recommendationNames: [String] = [
        "library_get_catalog_index", "library_get_catalog_tracks", "library_select_tracks",
        "recommend_by_mood", "recommend_by_constraints",
        "smart_queue_generate",
        "library_get_random_songs", "library_get_most_played",
        "library_get_recently_played", "library_get_similar_songs",
        "library_get_genres", "library_get_tracks_by_genre",
        "music_get_public_evidence",
        "result_present_tracks", "queue_replace", "queue_append",
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
        select(for: userText, all: all, allowAmbiguousContinuation: true, activeSkillID: nil)
    }

    /// Runtime 已经有结构化意图时，不把“继续”这种短词擅自解释成索引任务。
    /// 旧式无上下文调用方仍由上面的公开重载保留兼容行为。
    private static func select(
        for userText: String,
        all: [ToolDescriptor],
        allowAmbiguousContinuation: Bool,
        activeSkillID: String?
    ) -> [ToolDescriptor] {
        let semantics = AgentRequestSemantics.analyze(userText)
        var names = coreNames

        // A catalog summary is useful for an explicit Auralis request, but it
        // is not a generic-chat tool merely because the user said "推荐" or
        // "搜索".
        if semantics.isMusicContext {
            names += ["library_get_summary"]
        }

        if semantics.domain == .playback {
            names += playbackNames
        }
        if semantics.domain == .queue {
            names += queueNames
        }
        if semantics.domain == .musicLibrary {
            names += ["library_search", "library_resolve_entity", "library_get_song", "library_get_album", "library_get_artist", "server_search"]
        }
        if semantics.domain == .conversation,
           semantics.suggestedToolNamespaces.contains("catalog"),
           semantics.suggestedToolNamespaces.contains("web") {
            names += ["library_search", "library_resolve_entity", "web_search"]
        }
        if semantics.suggestedToolNamespaces.contains("annotation") {
            names += annotationNames
        }
        if semantics.suggestedToolNamespaces.contains("playlist") {
            names += playlistNames
        }
        if semantics.suggestedToolNamespaces.contains("recommendation") {
            names += recommendationNames
        }
        if semantics.isRecommendationIndex {
            names += recommendationIndexStatusNames
            if semantics.isRecommendationIndexBuild,
               activeSkillID == "recommendation-index-v2" {
                names += recommendationIndexBuildNames
            }
        }

        if semantics.domain == .playlist { names += playlistNames }
        if semantics.requestedOperations.contains(where: { [.favoriteSet, .ratingSet, .dislikedSet].contains($0) }) { names += annotationNames }
        if semantics.domain == .server { names += serverNames }
        if semantics.domain == .recommendation {
            names += recommendationNames
        }
        if semantics.domain == .system {
            names += appDeviceNames
        }
        if semantics.domain == .diagnostics {
            names += statsNames
        }
        if semantics.domain == .diagnostics {
            names += diagnosticsNames + catalogMaintenanceNames
        }
        if semantics.isMusicContext, semantics.suggestedToolNamespaces.contains("catalog") { names += ["lyrics_get"] }
        if semantics.domain == .download { names += ["media_download_offline", "getDownloadedTracks"] }
        if semantics.domain == .web { names += ["web_search", "web_fetch"] }
        if semantics.domain == .memory {
            names += ["memory_save", "memory_search", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"]
        }
        if let activeSkillID {
            names += all.filter { $0.requiredSkillID == activeSkillID }.map(\.name)
        }

        let unique = Self.resolvedNames(names)
        let byName = Dictionary(uniqueKeysWithValues: all.filter { $0.isVisible(toSkillID: activeSkillID) }.map { ($0.name, $0) })
        return unique.compactMap { byName[$0] }
    }

    /// 意图感知选择：KeywordSuggested ∪ IntentSuggested ∪ TaskRequired，纯加法。
    /// 意图只是路由提示，不再裁剪能力；不会把任何 model 工具按 policy 过滤掉。
    public static func select(
        for userText: String,
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        all: [ToolDescriptor],
        activeSkillID: String? = nil
    ) -> [ToolDescriptor] {
        let selected = select(for: userText, all: all, allowAmbiguousContinuation: false, activeSkillID: activeSkillID)
        let intentNames: Set<String>
        switch intent {
        case .conversation:
            // Generic conversation starts from the compact core set.  A
            // model-visible tool is added by explicit semantics or
            // tool_search, never merely because the caller supplied the
            // compatibility `.conversation` intent.
            intentNames = []
        case .librarySearch:
            intentNames = ["library_search", "library_resolve_entity", "library_get_song", "library_get_album", "library_get_artist", "server_search"]
        case .playbackControl:
            intentNames = ["playback_get_state", "playback_play_song", "playback_pause", "playback_resume", "playback_next", "playback_previous", "playback_seek", "playback_set_shuffle", "playback_set_repeat"]
        case .playbackQuery:
            intentNames = ["playback_get_state", "diagnostics_now_playing", "getCurrentTrack", "getCurrentQueue"]
        case .musicDiscovery:
            intentNames = ["library_get_catalog_index", "library_get_catalog_tracks", "library_select_tracks", "recommend_by_mood", "recommend_by_constraints", "library_get_similar_songs", "queue_replace", "queue_append", "playback_play_song", "playback_play_playlist", "favorite_set", "preference_set_disliked", "lyrics_get", "result_present_tracks"]
        case .queueManagement:
            intentNames = ["queue_get", "queue_append", "queue_append_many", "queue_play_next", "queue_play_next_many", "queue_replace", "queue_clear", "queue_move", "queue_shuffle_remaining", "queue_save_as_playlist"]
        case .queueQuery:
            intentNames = ["queue_get", "getCurrentQueue"]
        case .playlistManagement:
            intentNames = ["library_search", "library_get_song", "listPlaylists", "library_get_playlist", "playlist_create", "playlist_add_songs", "removeTracksFromPlaylist", "deletePlaylist"]
        case .playlistQuery:
            intentNames = ["listPlaylists", "library_get_playlist", "getPlaylist"]
        case .libraryManagement:
            intentNames = Set([
                "library_get_summary", "favorite_set", "setRating", "clearRating", "preference_set_disliked", "library_get_disliked",
                "library_index_v2_status", "library_index_v2_read", "library_index_v2_tag_catalog",
            ])
        case .serverManagement:
            intentNames = Set(serverNames)
        case .diagnostics:
            intentNames = Set(diagnosticsNames + appDeviceNames + statsNames + catalogMaintenanceNames + serverNames)
        case .musicAppreciation:
            intentNames = ["library_search", "library_get_song", "music_appreciate", "music_get_public_evidence"]
        case .musicDownload:
            intentNames = ["library_search", "server_search", "music_download_search", "music_download_submit", "music_download_status", "music_download_tasks", "music_download_history", "music_download_history_remove", "music_download_history_clean", "media_download_offline", "getDownloadedTracks"]
        case .memoryManagement:
            intentNames = ["memory_save", "memory_search", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"]
        }
        let names = selected.map(\.name) + intentNames.sorted()
        let skillNames = activeSkillID.map { skillID in
            all.filter { $0.requiredSkillID == skillID }.map(\.name)
        } ?? []
        let unique = Self.resolvedNames(names)
        let allNames = Self.resolvedNames(unique + skillNames)
        let byName = Dictionary(uniqueKeysWithValues: all.filter { $0.isVisible(toSkillID: activeSkillID) }.map { ($0.name, $0) })
        return allNames.compactMap { byName[$0] }
    }

    /// 把选中的工具描述转为原生 function calling 定义。
    public static func toolDefinitions(from descriptors: [ToolDescriptor]) -> [AIToolDefinition] {
        toolDefinitions(from: descriptors, strict: false)
    }

    /// Provider capabilities decide whether strict schema is emitted; the
    /// descriptor itself remains provider-neutral.
    public static func toolDefinitions(from descriptors: [ToolDescriptor], strict: Bool, activeSkillID: String? = nil) -> [AIToolDefinition] {
        descriptors.filter { $0.isVisible(toSkillID: activeSkillID) }.map { descriptor in
            AIToolDefinition(
                name: descriptor.name,
                description: descriptor.summary,
                parametersJSON: Self.parametersJSON(for: descriptor),
                strict: strict
            )
        }
    }

    /// 由 ToolParameter 生成最小 JSON Schema。
    static func parametersJSON(for descriptor: ToolDescriptor) -> String? {
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
            "additionalProperties": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}
