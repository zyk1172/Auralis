import Foundation

/// A conservative, shared interpretation of a user request.
///
/// This is intentionally a signal layer rather than a capability gate.  The
/// model can still discover and call any registered model-visible tool through
/// `tool_search`; the result is used only to rank tools, choose completion
/// semantics, and derive least-privilege authorization for the user's own
/// request.  In particular, generic words such as "推荐", "下载", "搜索",
/// "为什么", `memory`, and `skill` do not imply an Auralis operation.
public struct AgentRequestSemantics: Sendable, Equatable, Hashable {
    public enum Domain: String, Codable, Sendable, Hashable {
        case conversation
        case web
        case system
        case musicLibrary
        case playback
        case queue
        case playlist
        case recommendation
        case diagnostics
        case download
        case memory
        case server
    }

    public enum Operation: String, Codable, Sendable, Hashable {
        case conversation
        case read
        case mutate
        case discover
    }

    public let domain: Domain
    public let operation: Operation
    public let requiresSideEffect: Bool
    public let isMusicContext: Bool
    public let isContinuation: Bool
    public let suggestedToolNamespaces: Set<String>

    public var isReadOnly: Bool { operation == .read }
    public var isExplicitMutation: Bool { operation == .mutate }

    public init(
        domain: Domain,
        operation: Operation,
        isMusicContext: Bool,
        isContinuation: Bool,
        suggestedToolNamespaces: Set<String> = []
    ) {
        self.domain = domain
        self.operation = operation
        self.requiresSideEffect = operation == .mutate
        self.isMusicContext = isMusicContext
        self.isContinuation = isContinuation
        self.suggestedToolNamespaces = suggestedToolNamespaces
    }

    public static func analyze(_ text: String) -> AgentRequestSemantics {
        let value = normalized(text)
        let continuation = isContinuation(value)
        guard !value.isEmpty else {
            return Self(domain: .conversation, operation: .conversation, isMusicContext: false, isContinuation: continuation)
        }

        let has = { (terms: [String]) in terms.contains { value.contains($0) } }

        let query = has([
            "有哪些", "有什么", "哪些", "列表", "查看", "查询", "列出", "显示", "当前", "现在",
            "状态", "是什么", "什么", "which", "what", "list", "current", "status",
        ])
        let collectionQuery = has(["我的收藏", "收藏里面", "收藏的歌曲", "收藏曲目", "favorite tracks"])

        let explicitMusicNouns = has([
            "歌曲", "音乐", "曲库", "音乐库", "找歌", "歌手", "艺人", "专辑", "歌单", "播放列表", "播放队列", "队列", "收听", "听歌", "听了",
            "这首歌", "首歌", "这些歌", "的歌", "什么歌", "哪些歌", "我的收藏", "收藏里面", "歌词", "playlist", "music", "song", "track", "album", "artist", "queue",
            "lyrics", "playback",
        ])
        let explicitPlaybackAction = has([
            "播放", "先放", "放一首", "放一组", "放几首", "直接放", "给我放", "暂停", "下一首", "上一首", "继续播放", "快进", "快退", "跳转", "循环播放",
            "随机播放", "play ", "playback", "pause", "resume", "next track", "previous track",
        ])
        let explicitQueueAction = has([
            "加入队列", "放进队列", "放到队列", "接下来播放", "替换队列", "替换当前队列", "建立队列", "创建队列", "建立播放队列", "建立一个播放队列", "清空队列", "清空当前队列", "移出队列", "从队列移除",
            "调整队列", "移动队列", "随机剩余队列", "换成", "换为", "queue_append", "queue_replace", "queue_clear",
        ])
        let explicitPlaylistAction = has([
            "创建歌单", "新建歌单", "加入歌单", "加到歌单", "添加到歌单", "删除歌单",
            "重命名歌单", "改名歌单", "移除歌单歌曲", "调整歌单顺序", "复制歌单", "合并歌单",
            "playlist_create", "playlist_add", "playlist_delete", "playlist_rename",
        ]) || (has(["歌单", "playlist", "播放列表"]) && has(["创建", "新建", "建一个", "建", "加入", "添加", "删除", "重命名", "改名", "移除", "调整", "复制", "合并"]))
        let externalAnnotationContext = has(["网页", "文章", "页面", "帖子", "排版", "代码", "代码库"])
        // “收藏 ZZLikeUnique” is an Auralis-specific mutation even when the
        // track title itself contains no music noun.  Keep the signal narrow:
        // a web/article/code context must never authorize an annotation tool.
        let standaloneFavoriteAction = has(["收藏", "favorite"]) && !externalAnnotationContext && !collectionQuery
        let explicitAnnotationAction = !collectionQuery && (explicitMusicNouns || standaloneFavoriteAction) && has([
            "收藏", "取消收藏", "给这首歌评分", "给歌曲评分", "设置评分", "清除评分",
            "不喜欢这首", "不喜欢这首歌", "不感兴趣这首", "favorite", "rating", "dislike",
        ])
        let indexMarker = has([
            "推荐索引", "索引 v2", "索引v2", "index v2", "library_index_v2",
        ])
        let indexMutation = indexMarker && has([
            "开始", "启动", "建立", "创建", "构建", "重建", "继续", "处理", "分类", "一次性", "全部", "完成索引",
        ])
        let memoryMutation = has([
            "请记住", "记住", "忘记", "删除记忆", "清除记忆", "保存到记忆", "保存记忆",
            "memory_save", "memory_delete", "memory_clear", "创建技能", "删除技能", "skill_create", "skill_delete",
        ])
        let memoryRead = has([
            "我的记忆", "记忆列表", "搜索记忆", "查看记忆", "读取技能", "技能列表", "memory_list", "memory_search", "skill_list", "skill_read",
        ])
        let explicitMemory = memoryMutation || memoryRead || has(["我的名字是", "我叫"])

        let webContext = has([
            "网页", "文档", "新闻", "互联网", "联网", "网上", "官方文档", "web", "internet", "news", "online",
        ])
        let systemContext = has([
            "siri", "快捷指令", "音频输出", "耳机", "设备", "存储空间", "网络状态", "app", "应用能力", "功能状态",
        ])
        let statisticsContext = has([
            "统计", "收听", "听了", "最常听", "最近添加", "最近加入", "新添加", "新加入", "格式", "缓存占用", "存储分布",
        ])
        let diagnosticContext = has([
            "诊断", "播放失败", "播放状态", "当前播放状态", "正在播放状态", "停止播放", "播放器故障", "音频流",
            "错误", "失败", "日志", "卡住", "为什么播放", "diagnos", "error", "重复歌曲", "元数据", "封面问题",
            "损坏", "陈旧缓存", "不可播放",
        ])
        let serverMutation = has([
            "曲库同步", "同步音乐库", "切换服务器", "添加服务器", "删除服务器", "连接服务器", "server_sync_start", "server_switch", "server_remove",
        ]) || (has(["navidrome", "opensubsonic", "音乐服务器", "服务器"]) && has(["同步", "sync", "连接"]))
        let serverContext = has([
            "navidrome", "opensubsonic", "音乐服务器", "服务器", "server", "同步", "连接",
        ])
        let downloadContext = has([
            "下载", "离线", "download", "offline", "torrent", "moviepilot", "音乐下载",
        ])
        let recommendationRequest = has([
            "推荐", "相似", "发现", "随便听", "心情", "场景", "开车", "驾驶", "通勤", "提神", "运动", "健身",
            "跑步", "睡觉", "睡前", "放松", "安静", "有精神", "高能量", "来点", "来几首", "放几首", "想听",
            "适合", "给我选", "给我挑", "推荐一些", "挑几首", "选几首", "recommend", "shuffle",
        ])
        let genericSearch = has(["搜索", "查找", "查询", "找歌", "哪首", "哪个专辑", "谁唱的", "search"])
        // A short, compact CJK entity lookup (for example “搜索周杰伦”)
        // is a useful local-catalog ranking signal.  It is deliberately not
        // applied to external/web queries such as “搜索 Python 官方文档”.
        let compactCatalogEntityLookup = genericSearch && !webContext && isCompactCJKEntityLookup(value)

        // Only explicit Auralis/music nouns or unambiguous music actions make
        // a request a music request.  This is the boundary that prevents
        // "推荐几本书" and "怎么下载 Python wheel" from leaking music tools.
        let isMusicContext = explicitMusicNouns
            || explicitPlaybackAction
            || explicitQueueAction
            || explicitPlaylistAction
            || explicitAnnotationAction
            || indexMarker
            || compactCatalogEntityLookup
            || (recommendationRequest && explicitMusicNouns)
            || (downloadContext && explicitMusicNouns)

        if explicitMemory {
            return Self(
                domain: .memory,
                operation: memoryMutation ? .mutate : .read,
                isMusicContext: isMusicContext,
                isContinuation: continuation,
                suggestedToolNamespaces: ["memory"]
            )
        }
        if webContext && !isMusicContext {
            return Self(domain: .web, operation: .read, isMusicContext: false, isContinuation: continuation, suggestedToolNamespaces: ["server"])
        }
        if systemContext && !isMusicContext {
            return Self(domain: .system, operation: .read, isMusicContext: false, isContinuation: continuation, suggestedToolNamespaces: ["catalog"])
        }
        if indexMarker && isMusicContext {
            return Self(
                domain: .musicLibrary,
                operation: indexMutation ? .mutate : .read,
                isMusicContext: true,
                isContinuation: continuation,
                suggestedToolNamespaces: ["catalog"]
            )
        }
        // A server-looking token can be part of a GlobalID
        // (“test-server:pl-x”).  It must not shadow an explicit playlist,
        // queue, playback, or catalog request.
        if serverContext && (serverMutation || !isMusicContext) {
            return Self(
                domain: .server,
                operation: serverMutation ? .mutate : .read,
                isMusicContext: isMusicContext,
                isContinuation: continuation,
                suggestedToolNamespaces: ["server"]
            )
        }
        if isMusicContext && (diagnosticContext || statisticsContext) {
            return Self(
                domain: .diagnostics,
                operation: .read,
                isMusicContext: isMusicContext,
                isContinuation: continuation,
                suggestedToolNamespaces: ["catalog", "playback", "server"]
            )
        }
        if downloadContext && isMusicContext {
            return Self(
                domain: .download,
                operation: query ? .read : .mutate,
                isMusicContext: true,
                isContinuation: continuation,
                suggestedToolNamespaces: ["download", "server", "catalog"]
            )
        }

        let playlistContext = explicitMusicNouns && has(["歌单", "playlist", "播放列表"])
        if playlistContext {
            if recommendationRequest && !explicitPlaylistAction {
                return Self(domain: .recommendation, operation: .discover, isMusicContext: true, isContinuation: continuation, suggestedToolNamespaces: ["catalog", "playback", "playlist"])
            }
            return Self(
                domain: .playlist,
                operation: explicitPlaylistAction ? .mutate : .read,
                isMusicContext: true,
                isContinuation: continuation,
                suggestedToolNamespaces: ["playlist", "catalog"]
            )
        }

        let queueContext = explicitMusicNouns && has(["队列", "queue", "接下来播放"])
        if queueContext {
            return Self(
                domain: .queue,
                operation: explicitQueueAction ? .mutate : .read,
                isMusicContext: true,
                isContinuation: continuation,
                suggestedToolNamespaces: ["playback"]
            )
        }

        let playbackQuery = query && has(["正在播放", "当前播放", "播放状态", "播放什么", "播放哪首", "now playing", "playback state"])
        if explicitPlaybackAction || (explicitMusicNouns && has(["播放"])) {
            return Self(
                domain: .playback,
                operation: playbackQuery ? .read : .mutate,
                isMusicContext: true,
                isContinuation: continuation,
                suggestedToolNamespaces: ["playback", "catalog"]
            )
        }
        if explicitAnnotationAction {
            return Self(domain: .musicLibrary, operation: .mutate, isMusicContext: true, isContinuation: continuation, suggestedToolNamespaces: ["annotation", "catalog"])
        }
        if recommendationRequest && isMusicContext {
            return Self(domain: .recommendation, operation: .discover, isMusicContext: true, isContinuation: continuation, suggestedToolNamespaces: ["catalog", "playback"])
        }
        if isMusicContext && (genericSearch || query || collectionQuery) {
            return Self(domain: .musicLibrary, operation: .read, isMusicContext: true, isContinuation: continuation, suggestedToolNamespaces: ["catalog", "server"])
        }

        return Self(domain: .conversation, operation: .conversation, isMusicContext: isMusicContext, isContinuation: continuation)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isContinuation(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、；;：: \t\n"))
        return [
            "继续", "继续吧", "第一个", "第一个吧", "就这个", "就它", "这个", "播放它", "播放这个",
            "加入队列", "加入播放队列", "把它播放", "选这个",
        ].contains(normalized)
    }

    private static func isCompactCJKEntityLookup(_ value: String) -> Bool {
        let prefixes = ["搜索", "查找", "查询"]
        guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { return false }
        let tail = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...8).contains(tail.count), !tail.contains(where: { $0.isWhitespace }) else { return false }
        return tail.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
