import Foundation

/// The single semantic result shared by routing, ranking and authorization.
///
/// This is a signal layer, not a capability gate. A model-visible tool that
/// is not shortlisted can still be discovered through `tool_search`. The
/// result is deliberately conservative: generic words such as “推荐”、“下载”、
/// “搜索”、“为什么” or `memory` must not turn an ordinary question into an
/// Auralis mutation.
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
    public let isRecommendationIndex: Bool
    public let isRecommendationIndexBuild: Bool
    public let isMusicAppreciation: Bool
    public let requestedOperations: Set<ToolAuthorizationOperation>
    public let suggestedToolNamespaces: Set<String>

    public var isReadOnly: Bool { operation == .read && requestedOperations.isEmpty }
    public var isExplicitMutation: Bool { operation == .mutate || !requestedOperations.isEmpty }

    public init(
        domain: Domain,
        operation: Operation,
        isMusicContext: Bool,
        isContinuation: Bool,
        isRecommendationIndex: Bool = false,
        isRecommendationIndexBuild: Bool = false,
        isMusicAppreciation: Bool = false,
        requestedOperations: Set<ToolAuthorizationOperation> = [],
        suggestedToolNamespaces: Set<String> = []
    ) {
        self.domain = domain
        self.operation = operation
        self.requiresSideEffect = operation == .mutate || !requestedOperations.isEmpty
        self.isMusicContext = isMusicContext
        self.isContinuation = isContinuation
        self.isRecommendationIndex = isRecommendationIndex
        self.isRecommendationIndexBuild = isRecommendationIndexBuild
        self.isMusicAppreciation = isMusicAppreciation
        self.requestedOperations = requestedOperations
        self.suggestedToolNamespaces = suggestedToolNamespaces
    }

    /// Analyze the current request. A short continuation inherits semantic
    /// context only from the relevant prior user request; a new substantive
    /// query never inherits mutation intent from older history.
    public static func analyze(_ text: String, historyText: String = "") -> AgentRequestSemantics {
        let current = normalized(text)
        let continuation = isContinuation(current)
        let inherited = continuation ? normalized(historyText) : ""
        let value = [inherited, current].filter { !$0.isEmpty }.joined(separator: " ")
        guard !value.isEmpty else {
            return Self(domain: .conversation, operation: .conversation, isMusicContext: false, isContinuation: continuation)
        }

        let has = { (terms: [String]) in containsAny(value, terms) }

        let query = has([
            "有哪些", "有什么", "哪些", "列表", "查看", "查询", "列出", "显示", "当前", "现在",
            "状态", "是什么", "什么", "which", "what", "list", "current", "status",
        ])
        let collectionQuery = has(["我的收藏", "收藏里面", "收藏的歌曲", "收藏曲目", "favorite tracks"])

        let hasSongQuantity = value.range(
            of: #"(?:[0-9]+|[一二两三四五六七八九十百千万零〇]+)\s*首"#,
            options: .regularExpression
        ) != nil || has(["几首"])
        let explicitMusicNouns = has([
            "歌曲", "音乐", "曲库", "音乐库", "找歌", "歌手", "艺人", "专辑", "歌单", "播放列表", "播放队列", "队列", "正在播放", "当前播放", "收听", "听歌", "听了",
            "这首歌", "首歌", "这些歌", "的歌", "什么歌", "哪些歌", "我的收藏", "收藏里面", "歌词",
            "playlist", "music", "song", "track", "album", "artist", "queue", "lyrics", "playback",
        ]) || hasSongQuantity

        // “播放列表/播放队列/播放状态” contain “播放” but are not
        // playback mutations. Keep the verb signal separate from nouns.
        let barePlaybackVerb = has(["播放"])
            && !has(["播放列表", "播放队列", "播放状态", "正在播放什么", "当前播放什么"])
        let explicitPlaybackAction = has([
            "先放", "放一首", "放一组", "放几首", "直接放", "给我放", "暂停", "下一首", "上一首", "继续播放", "快进", "快退", "跳转", "循环播放",
            "随机播放", "play", "playback", "pause", "resume", "next track", "previous track",
        ]) || barePlaybackVerb

        let explicitQueueAction = has([
            "加入队列", "放进队列", "放到队列", "接下来播放", "替换队列", "替换当前队列", "建立队列", "创建队列", "建立播放队列", "建立一个播放队列", "清空队列", "清空当前队列", "移出队列", "从队列移除",
            "调整队列", "移动队列", "随机剩余队列", "换成", "换为", "queue_append", "queue_replace", "queue_clear",
        ])
        let explicitPlaylistAction = has([
            "创建歌单", "新建歌单", "加入歌单", "加到歌单", "添加到歌单", "放到歌单", "放进歌单", "放入歌单", "收进歌单", "删除歌单",
            "重命名歌单", "改名歌单", "移除歌单歌曲", "调整歌单顺序", "复制歌单", "合并歌单",
            "playlist_create", "playlist_add", "playlist_delete", "playlist_rename",
        ]) || (has(["歌单", "playlist", "播放列表"]) && has(["创建", "新建", "建一个", "建", "加入", "添加", "放到", "放进", "放入", "收进", "删除", "重命名", "改名", "移除", "调整", "复制", "合并"]))

        let musicAnnotationTarget = has([
            "这首歌", "歌曲", "音乐", "专辑", "歌手", "艺人", "艺术家", "当前播放", "current track", "track", "song", "album", "artist",
        ])
        let annotationAction = has([
            "收藏", "取消收藏", "给这首歌评分", "给歌曲评分", "设置评分", "清除评分",
            "不喜欢这首", "不喜欢这首歌", "不感兴趣这首", "favorite", "rating", "dislike",
        ])
        let explicitNonMusicAnnotationTarget = has([
            "这本书", "书籍", "网页", "文章", "文档", "链接", "电影", "颜色", "排版", "观点", "想法",
        ])
        // Positive target signal is the authorization boundary. “收藏这本书”
        // and “favorite color” contain no explicit music entity.
        let implicitTrackTitleTarget = annotationAction
            && !explicitNonMusicAnnotationTarget
            && has(["收藏", "favorite"])
            && value.count > 3
        let explicitAnnotationAction = !collectionQuery
            && !explicitNonMusicAnnotationTarget
            && (musicAnnotationTarget || implicitTrackTitleTarget)
            && annotationAction

        let indexMarker = has([
            "推荐索引", "索引处理", "索引进度", "索引还剩", "索引分类", "索引完成", "索引了",
        ]) || RecommendationIndexCompatibility.isLegacyBuildMarker(value)
        let explicitIndexBuild = has([
            "开始构建", "启动构建", "开始索引", "启动索引", "构建推荐索引", "构建完整推荐索引", "建立索引", "重建索引", "重建推荐索引", "继续构建", "继续处理索引",
            "开始并一次性完成推荐索引", "一次性完成全部推荐索引", "开始分类剩余歌曲", "完成整个索引任务", "继续之前的推荐索引任务", "继续处理推荐索引",
        ])
        let indexBuild = indexMarker && explicitIndexBuild
        let memorySave = has([
            "请记住", "记住我的", "记住我", "保存到记忆", "保存记忆", "memory_save",
            "创建技能", "skill_create", "我叫", "我的名字是", "我的生日是",
        ])
        let memoryDelete = has([
            "删除记忆", "清除记忆", "忘掉关于我", "忘记关于我", "删除你记住", "删掉你记住",
            "把我的生日忘掉", "忘掉我的生日", "忘记我的名字", "memory_delete", "memory_clear",
            "删除技能", "skill_delete",
        ])
        let memoryRead = has([
            "我的记忆", "记忆列表", "搜索记忆", "查看记忆", "读取技能", "技能列表", "memory_list", "memory_search", "skill_list", "skill_read",
            "你记得我", "我的名字是什么", "我叫什么",
        ])
        let explicitMemory = memorySave || memoryDelete || memoryRead

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
        let serverEntity = has(["navidrome", "opensubsonic", "音乐服务器", "服务器", "当前服务器", "server"])
        let serverMutation = has([
            "曲库同步", "同步音乐库", "切换服务器", "添加服务器", "删除服务器", "连接服务器", "server_sync_start", "server_switch", "server_remove",
        ]) || (serverEntity && has(["同步", "sync", "连接", "切换", "添加", "删除"]))
        let serverContext = serverEntity
        let downloadContext = has([
            "下载", "离线", "download", "offline", "torrent", "moviepilot", "音乐下载",
        ])
        let recommendationRequest = has([
            "推荐", "相似", "发现", "随便听", "心情", "场景", "开车", "驾驶", "通勤", "提神", "运动", "健身",
            "跑步", "睡觉", "睡前", "放松", "安静", "有精神", "高能量", "来点", "来几首", "放几首", "想听",
            "适合", "给我选", "给我挑", "推荐一些", "挑几首", "选几首", "recommend", "shuffle",
        ]) || (has(["选", "挑"]) && has(["首", "歌", "歌曲"]))
        let genericSearch = has(["搜索", "查找", "查询", "找歌", "哪首", "哪个专辑", "谁唱的", "search"])

        let isMusicContext = explicitMusicNouns
            || explicitPlaybackAction
            || explicitQueueAction
            || explicitPlaylistAction
            || explicitAnnotationAction
            || indexMarker
            || (recommendationRequest && explicitMusicNouns)
            || (downloadContext && explicitMusicNouns)
        let musicAppreciation = isMusicContext && has(["鉴赏", "赏析", "乐评", "大众评价", "appreciate"])

        var requested = Set<ToolAuthorizationOperation>()

        let playbackQuery = query && has(["正在播放", "当前播放", "播放状态", "播放什么", "播放哪首", "now playing", "playback state"])
        if explicitPlaybackAction && !playbackQuery {
            if has(["暂停", "pause"]) { requested.insert(.playbackPause) }
            else if has(["下一首", "上一首", "next track", "previous track"]) { requested.insert(.playbackNavigation) }
            else if has(["快进", "快退", "跳转", "seek"]) { requested.insert(.playbackSeek) }
            else if has(["循环", "随机播放", "shuffle", "repeat", "变速", "速度"]) { requested.insert(.playbackMode) }
            else { requested.insert(.playbackPlay) }
            if has(["替换队列", "替换当前队列", "换成", "换为", "replace queue", "queue_replace"]) {
                requested.insert(.queueReplace)
            }
        }

        if explicitQueueAction {
            if has(["替换队列", "替换当前队列", "建立队列", "创建队列", "建立播放队列", "建立一个播放队列", "换成", "换为", "queue_replace"]) {
                requested.insert(.queueReplace)
            }
            if has(["清空队列", "清空当前队列", "queue_clear", "clear queue"]) { requested.insert(.queueClear) }
            if has(["移出队列", "从队列移除", "queue_remove", "remove from queue"]) { requested.insert(.queueRemove) }
            if has(["调整队列", "移动队列", "queue_move", "reorder", "move queue"]) { requested.insert(.queueMove) }
            if has(["随机剩余队列", "queue_shuffle_remaining", "shuffle remaining"]) { requested.insert(.queueShuffle) }
            if has(["接下来播放", "play next", "queue_play_next"]) { requested.insert(.queuePlayNext) }
            if has(["加入队列", "放进队列", "放到队列", "queue_append"]) { requested.insert(.queueAppend) }
        }

        if explicitPlaylistAction {
            if has(["创建歌单", "新建歌单", "playlist_create"])
                || (has(["歌单", "playlist", "播放列表"]) && has(["创建", "新建", "建一个", "建立"])) {
                requested.insert(.playlistCreate)
            }
            if has(["加入歌单", "加到歌单", "添加到歌单", "放到歌单", "放进歌单", "放入歌单", "收进歌单", "playlist_add"])
                || (has(["歌单", "playlist", "播放列表"]) && has(["加入", "添加", "放到", "放进", "放入", "收进"])) {
                requested.insert(.playlistAdd)
            }
            // “创建一个 N 首歌单” explicitly contains both operations:
            // create the playlist and add the requested songs. A bare
            // “创建歌单” still authorizes only playlistCreate.
            if requested.contains(.playlistCreate), hasSongQuantity || has(["歌曲", "曲目", "这些歌", "这首歌"]) {
                requested.insert(.playlistAdd)
            }
            if has(["删除歌单", "playlist_delete"])
                || (has(["歌单", "playlist", "播放列表"]) && has(["删除"])) { requested.insert(.playlistDelete) }
            if has(["重命名歌单", "改名歌单", "playlist_rename"]) { requested.insert(.playlistRename) }
            if has(["移除歌单歌曲", "playlist_remove"]) { requested.insert(.playlistRemove) }
            if has(["调整歌单顺序", "移动歌单", "playlist_move"]) { requested.insert(.playlistMove) }
            if has(["复制歌单", "playlist_duplicate"]) { requested.insert(.playlistDuplicate) }
            if has(["合并歌单", "playlist_merge"]) { requested.insert(.playlistMerge) }
            if has(["保存队列", "save queue"]) { requested.insert(.playlistSaveQueue) }
        }

        if explicitAnnotationAction {
            if has(["评分", "rating", "清除评分"]) { requested.insert(.ratingSet) }
            else if has(["不喜欢", "不感兴趣", "dislike"]) { requested.insert(.dislikedSet) }
            else { requested.insert(.favoriteSet) }
        }
        if indexBuild { requested.insert(.recommendationIndexWrite) }
        if serverMutation {
            if has(["删除服务器", "server_remove", "remove server"]) { requested.insert(.serverRemove) }
            else if has(["切换服务器", "server_switch", "switch server"]) { requested.insert(.serverSwitch) }
            else if has(["同步", "sync", "曲库同步"]) { requested.insert(.serverSync) }
            else { requested.insert(.serverConfigure) }
        }
        if downloadContext && isMusicContext && !query {
            requested.insert(has(["离线", "offline", "media_download_offline"]) ? .offlineDownload : .downloadSubmit)
        }
        if explicitMemory {
            if memoryDelete {
                if has(["删除技能", "skill_delete"]) { requested.insert(.skillDelete) }
                else if has(["清除记忆", "memory_clear"]) { requested.insert(.memoryClear) }
                else { requested.insert(.memoryDelete) }
            } else if memorySave {
                if has(["创建技能", "skill_create"]) { requested.insert(.skillCreate) }
                else { requested.insert(.memorySave) }
            }
        }

        if explicitMemory {
            return Self(domain: .memory, operation: requested.isEmpty ? .read : .mutate, isMusicContext: isMusicContext, isContinuation: continuation, requestedOperations: requested, suggestedToolNamespaces: ["memory"])
        }
        if webContext && !isMusicContext {
            return Self(domain: .web, operation: .read, isMusicContext: false, isContinuation: continuation, requestedOperations: requested, suggestedToolNamespaces: ["web"])
        }
        if systemContext && !isMusicContext {
            return Self(domain: .system, operation: .read, isMusicContext: false, isContinuation: continuation, requestedOperations: requested, suggestedToolNamespaces: ["catalog"])
        }
        if indexMarker {
            return Self(domain: .musicLibrary, operation: indexBuild ? .mutate : .read, isMusicContext: true, isContinuation: continuation, isRecommendationIndex: true, isRecommendationIndexBuild: indexBuild, requestedOperations: requested, suggestedToolNamespaces: ["catalog"])
        }
        if serverContext {
            return Self(domain: .server, operation: serverMutation ? .mutate : .read, isMusicContext: isMusicContext, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["server"])
        }
        if isMusicContext && (diagnosticContext || statisticsContext) {
            return Self(domain: .diagnostics, operation: .read, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["catalog", "playback", "server"])
        }
        if downloadContext && isMusicContext {
            return Self(domain: .download, operation: query ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["download", "server", "catalog"])
        }

        let playlistContext = explicitMusicNouns && has(["歌单", "playlist", "播放列表"])
        if playlistContext {
            if recommendationRequest && !explicitPlaylistAction {
                return Self(domain: .recommendation, operation: .discover, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["catalog", "playback", "playlist", "recommendation"])
            }
            return Self(domain: .playlist, operation: requested.isEmpty ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["playlist", "catalog"])
        }

        let queueContext = explicitMusicNouns && has(["队列", "queue", "接下来播放"])
        if queueContext {
            let namespaces = recommendationRequest
                ? ["playback", "catalog", "recommendation"]
                : ["playback"]
            return Self(domain: .queue, operation: requested.isEmpty ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: Set(namespaces))
        }

        if explicitPlaybackAction || (explicitMusicNouns && has(["播放"])) {
            let namespaces = recommendationRequest
                ? ["playback", "catalog", "recommendation"]
                : ["playback", "catalog"]
            return Self(domain: .playback, operation: requested.isEmpty ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: Set(namespaces))
        }
        if explicitAnnotationAction {
            return Self(domain: .musicLibrary, operation: .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["annotation", "catalog"])
        }
        if recommendationRequest && isMusicContext {
            return Self(domain: .recommendation, operation: .discover, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["catalog", "playback"])
        }
        if isMusicContext && (genericSearch || query || collectionQuery) {
            let namespaces = collectionQuery ? ["catalog", "server", "annotation"] : ["catalog", "server"]
            return Self(domain: .musicLibrary, operation: .read, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: Set(namespaces))
        }

        // “搜索胡广生” does not prove either a local-music or public-web
        // target.  Expose only the two read-only search entrances so a weaker
        // model can make a useful first choice without reviving the old
        // Chinese-name-is-music heuristic.
        if genericSearch && !webContext && !isMusicContext {
            return Self(
                domain: .conversation,
                operation: .read,
                isMusicContext: false,
                isContinuation: continuation,
                requestedOperations: requested,
                suggestedToolNamespaces: ["catalog", "web"]
            )
        }

        return Self(domain: .conversation, operation: .conversation, isMusicContext: isMusicContext, isContinuation: continuation, requestedOperations: requested)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isContinuation(_ value: String) -> Bool {
        AgentHistoryPolicy.isExplicitContinuation(value)
    }

    private static func containsAny(_ value: String, _ terms: [String]) -> Bool {
        terms.contains { containsTerm(value, $0) }
    }

    /// Chinese phrases are matched as phrases; ASCII words use boundaries so
    /// `app` does not match `application`, `track` does not match `tracking`,
    /// and `memory` does not match an unrelated compound word.
    private static func containsTerm(_ value: String, _ rawTerm: String) -> Bool {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return false }
        let isASCIIWordTerm = term.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && isASCIIWordScalar(scalar.value, allowSpace: true)
        }
        guard isASCIIWordTerm else { return value.contains(term) }

        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(of: term, range: searchStart..<value.endIndex) {
            let before = range.lowerBound > value.startIndex ? value[value.index(before: range.lowerBound)] : nil
            let after = range.upperBound < value.endIndex ? value[range.upperBound] : nil
            let isWord: (Character?) -> Bool = { character in
                guard let character else { return false }
                return character.unicodeScalars.allSatisfy { scalar in
                    scalar.isASCII && isASCIIWordScalar(scalar.value, allowSpace: false)
                }
            }
            if !isWord(before) && !isWord(after) { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isASCIIWordScalar(_ value: UInt32, allowSpace: Bool) -> Bool {
        (65...90).contains(value)
            || (97...122).contains(value)
            || (48...57).contains(value)
            || value == 95
            || (allowSpace && value == 32)
    }
}
