import AIKit
import Foundation
import LocalCatalog

/// Chat-first conversation boundary.  Intent is a hint for ranking and task
/// completion; it is never permission to reinterpret an ordinary answer as a
/// local music search.
public struct ConversationEngine: Sendable {
    public init() {}

    public static func isExplicitMusicCommand(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        let musicMarkers = [
            "歌曲", "音乐", "曲库", "歌手", "艺人", "专辑", "歌单", "播放列表", "队列", "歌词",
            "song", "music", "artist", "album", "playlist", "queue", "track",
        ]
        let actionMarkers = [
            "播放", "暂停", "下一首", "上一首", "继续播放", "加入队列", "接下来播放", "替换队列",
            "收藏", "喜欢", "评分", "推荐", "找歌", "搜索歌曲", "搜索音乐", "下载", "离线",
            "创建歌单", "新建歌单", "加入歌单", "加到歌单", "删除歌单", "清空队列", "保存队列",
            "play", "pause", "next", "previous", "queue", "favorite", "recommend", "download",
        ]
        if actionMarkers.contains(where: value.contains) { return true }
        return musicMarkers.contains(where: value.contains)
            && ["查", "搜", "找", "看", "列", "获取", "显示", "查询", "什么", "which", "what", "show", "find", "search"]
                .contains(where: value.contains)
    }

    public static func allowsOfflineFallback(intent: AgentTaskIntent, userText: String) -> Bool {
        guard isExplicitMusicCommand(userText) else { return false }
        switch intent {
        case .librarySearch, .playbackControl, .musicDiscovery, .queueManagement,
             .playlistManagement, .libraryManagement, .musicAppreciation, .musicDownload:
            return true
        case .conversation, .serverManagement, .diagnostics, .memoryManagement:
            return false
        }
    }

    public func run(
        userText: String,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: AgentRunner.Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        webService: (any AgentWebService)? = nil,
        intent: AgentTaskIntent? = nil,
        policy: AgentTaskPolicy? = nil,
        initialTaskState: AgentTaskState? = nil,
        toolTimeout: TimeInterval = AgentRunner.toolExecutionTimeout,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentRunner.AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in }
    ) async {
        await AgentRunner.run(
            userText: userText,
            provider: provider,
            model: model,
            bridge: bridge,
            catalog: catalog,
            context: context,
            history: history,
            systemService: systemService,
            externalMusicService: externalMusicService,
            webService: webService,
            intent: intent,
            policy: policy,
            initialTaskState: initialTaskState,
            toolTimeout: toolTimeout,
            confirm: confirm,
            emit: emit,
            log: log,
            progress: progress,
            state: state
        )
    }
}
