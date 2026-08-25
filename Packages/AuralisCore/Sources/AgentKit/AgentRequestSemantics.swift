import AIKit
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
        case customTool
    }

    public enum Operation: String, Codable, Sendable, Hashable {
        case conversation
        case read
        case mutate
        case discover
    }

    /// A high-confidence local read has one canonical entry point. This drives
    /// both deterministic routing for the narrow read scenarios and schema
    /// ranking for less specific follow-ups; ToolRuntime remains the executor.
    public struct DirectReadCapability: Codable, Sendable, Hashable {
        public let toolName: String
        public let arguments: [String: AIJSONValue]

        public init(toolName: String, arguments: [String: AIJSONValue] = [:]) {
            self.toolName = toolName
            self.arguments = arguments
        }
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
    public let directReadCapability: DirectReadCapability?

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
        suggestedToolNamespaces: Set<String> = [],
        directReadCapability: DirectReadCapability? = nil
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
        self.directReadCapability = directReadCapability
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

        let quantityQuery = has(["有多少", "多少", "数量", "几位", "几张", "几首歌"])
        let query = has([
            "有哪些", "有什么", "哪些", "列表", "查看", "查询", "列出", "显示", "当前", "现在",
            "状态", "统计", "概况", "是什么", "什么", "which", "what", "list", "current", "status",
        ]) || quantityQuery
        let collectionQuery = has(["我的收藏", "收藏里面", "收藏的歌曲", "收藏曲目", "favorite tracks"])

        let hasSongQuantity = value.range(
            of: #"(?:[0-9]+|[一二两三四五六七八九十百千万零〇]+)\s*首"#,
            options: .regularExpression
        ) != nil || has(["几首"])
        let explicitMusicNouns = has([
            "歌曲", "音乐", "曲库", "音乐库", "找歌", "歌手", "艺人", "艺术家", "专辑", "歌单", "播放列表", "播放队列", "队列", "正在播放", "当前播放", "收听", "听歌", "听了",
            "这首歌", "首歌", "这些歌", "的歌", "什么歌", "哪些歌", "我的收藏", "收藏里面", "歌词",
            "playlist", "music", "song", "track", "album", "artist", "queue", "lyrics", "playback",
        ]) || hasSongQuantity

        // “播放列表/播放队列/播放状态” contain “播放” but are not
        // playback mutations. Keep the verb signal separate from nouns.
        let barePlaybackVerb = has(["播放"])
            && !has(["播放列表", "播放队列", "播放状态", "正在播放什么", "当前播放什么", "最近播放", "最近听过", "播放历史"])
        let explicitPlaybackAction = has([
            "先放", "放一首", "放一组", "放几首", "直接放", "给我放", "来首", "来点", "整点", "来一首", "放一下", "暂停", "下一首", "上一首", "继续播放", "快进", "快退", "跳转", "循环播放",
            "随机播放", "play", "playback", "pause", "resume", "next track", "previous track",
        ]) || barePlaybackVerb

        // 队列操作采用「domain target + action」结构化判定（P1-1）：
        // 裸动词“换成/换为/替换成”不得独立产生 queue 授权
        // （“把主题换成深色 / 把输出设备换成耳机”绝不能获得 queueReplace）。
        let queueTargetPresent = has(["队列", "当前队列", "播放队列", "queue"])
        let queueStructuralVerbs = [
            "加入", "放进", "放到", "替换", "覆盖", "建立", "创建", "清空", "移出", "移除",
            "调整", "移动", "随机剩余", "接下来播放", "append", "replace", "clear", "remove", "move", "shuffle",
        ]
        // “换成/换为”只有在同时存在明确队列 target 时才构成队列动作。
        let queueSwapWithTarget = has(["换成", "换为"]) && queueTargetPresent
        let explicitQueueAction = (queueTargetPresent && (has(queueStructuralVerbs) || queueSwapWithTarget))
            || has(["queue_append", "queue_replace", "queue_clear", "queue_remove", "queue_move", "queue_shuffle_remaining", "queue_play_next", "play next"])
        // 高置信 queueReplace：队列 target + 替换动作；或结构明确的歌曲集合 → 队列；
        // 或显式 canonical vocabulary。裸“换成/换为/替换成”不在此列。
        let trackCollectionTarget = has(["这些歌", "这些歌曲", "这几首", "这批歌", "候选歌曲", "选好的歌", "选定的歌"])
        let queueReplaceVerb = has(["替换", "覆盖", "replace"])
        let explicitQueueReplace = (queueTargetPresent && (queueReplaceVerb || queueSwapWithTarget))
            || (trackCollectionTarget && queueReplaceVerb && has(["队列", "queue"]))
            || has(["queue_replace", "replace queue", "替换队列", "替换当前队列", "替换到队列", "覆盖当前队列"])
        let explicitPlaylistAction = has([
            "创建歌单", "新建歌单", "加入歌单", "加到歌单", "添加到歌单", "放到歌单", "放进歌单", "放入歌单", "收进歌单", "删除歌单",
            "重命名歌单", "改名歌单", "移除歌单歌曲", "调整歌单顺序", "复制歌单", "合并歌单",
            "保存当前队列为歌单", "保存队列为歌单", "把当前队列保存为歌单", "存为歌单", "保存成歌单", "保存队列", "save queue",
            "playlist_create", "playlist_add", "playlist_delete", "playlist_rename",
        ]) || (has(["歌单", "playlist", "播放列表"]) && has(["创建", "新建", "建一个", "建", "加入", "加到", "添加", "放到", "放进", "放入", "收进", "删除", "重命名", "改名", "移除", "调整", "复制", "合并", "保存", "存为", "存成"]))

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
        // 评分读取（“这首歌的评分是多少？”）：不含 mutation 动词，自然落入只读
        // query 分支，绝不产生 mutation 授权。
        // 评分变更：明确动作动词（设置/给…评/打…分/清除/删除/取消）+ 评分名词，
        // 且指向音乐目标。裸「评分 / 打分」不构成 mutation 授权。
        let ratingMutationPhrase = has([
            "给这首歌评分", "给歌曲评分", "给这首歌打", "给歌曲打", "设置评分", "设置评分为",
            "评分为", "评为", "清除", "删除", "取消", "清掉", "删掉",
        ])
        let ratingMutation = !collectionQuery
            && !explicitNonMusicAnnotationTarget
            && (musicAnnotationTarget || implicitTrackTitleTarget)
            && ratingMutationPhrase
            && has(["评分", "rating", "打分", "分"])
        let explicitAnnotationAction = !collectionQuery
            && !explicitNonMusicAnnotationTarget
            && (musicAnnotationTarget || implicitTrackTitleTarget)
            && (annotationAction || ratingMutation)

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

        // Custom Tool management is deliberately opt-in. A generic mention
        // of “tool” must not authorize a builder mutation; only the explicit
        // builder/doctor vocabulary below enters this domain.
        let customToolCreate = has(["创建自建工具", "创建自定义工具", "新建自建工具", "tool_builder_create", "工具构建"])
        let customToolUpdate = has(["更新自建工具", "修改自建工具", "升级自建工具", "tool_builder_update"])
        let customToolDelete = has(["删除自建工具", "删除自定义工具", "tool_builder_delete"])
        let customToolEnable = has(["启用自建工具", "打开自建工具", "tool_builder_enable"])
        let customToolDisable = has(["停用自建工具", "禁用自建工具", "tool_builder_disable"])
        let customToolRepair = has(["修复自建工具", "修复自定义工具", "tool_repair"])
        let customToolRead = has(["自建工具列表", "列出自建工具", "查看自建工具", "检查自建工具", "诊断工具", "tool_builder_list", "tool_builder_inspect", "tool_builder_validate", "tool_builder_test", "tool_diagnose"])
        let explicitCustomTool = customToolCreate || customToolUpdate || customToolDelete
            || customToolEnable || customToolDisable || customToolRepair || customToolRead

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

        let playbackQuery = query && has(["正在播放", "当前播放", "播放状态", "播放什么", "播放哪首", "now playing", "playback state"])
        let librarySummaryQuery = has(["资料库统计", "曲库统计", "音乐库统计", "资料库概况", "曲库概况", "音乐库概况"])
        let artistListQuery = has(["列出歌手", "歌手列表", "有哪些歌手", "艺人列表", "列出艺人", "有哪些艺人", "艺术家列表", "列出艺术家"])
            || (has(["列出", "显示", "查看", "获取"]) && has(["歌手", "艺人", "艺术家"]))
        let albumListQuery = has(["列出专辑", "专辑列表", "有哪些专辑", "album list", "list albums"])
            || (has(["列出", "显示", "查看", "获取"]) && has(["专辑", "album"]))
        let directReadTopicCount = [
            has(["歌单", "播放列表", "playlist"]),
            has(["播放队列", "队列", "queue"]),
            playbackQuery,
            collectionQuery,
            has(["最近播放", "最近听过", "播放历史", "recent history"]),
            quantityQuery && has(["歌曲", "歌手", "艺人", "专辑", "歌单", "曲库", "音乐库"]),
            artistListQuery,
            albumListQuery,
            has(["服务器列表", "列出服务器", "有哪些服务器", "已连接服务器", "list servers", "server list"]),
            librarySummaryQuery
        ].filter { $0 }.count
        let isCompoundReadRequest = directReadTopicCount > 1 || has([
            "后检查", "后查看", "后查询", "后再", "然后", "并检查", "并查看", "并列出", "以及",
            "同时", "再看看", "再查", "再查看", "再列出", "and then", "after that"
        ])
        let requestedLimit = Self.requestedLimit(in: current)
        let directReadCapability: DirectReadCapability? = {
            guard query, !isCompoundReadRequest else { return nil }
            if has(["歌单", "播放列表", "playlist"]) && !explicitPlaylistAction {
                return Self.directRead("playlist_list", limit: requestedLimit)
            }
            if has(["播放队列", "队列", "queue"]) && !explicitQueueAction {
                return Self.directRead("queue_get")
            }
            if playbackQuery && !explicitPlaybackAction {
                return Self.directRead("playback_get_state")
            }
            if collectionQuery {
                return Self.directRead("library_get_starred")
            }
            if has(["最近播放", "最近听过", "播放历史", "recent history"])
                && !explicitPlaybackAction {
                return Self.directRead("library_get_recently_played", limit: requestedLimit)
            }
            if librarySummaryQuery {
                return Self.directRead("library_get_summary")
            }
            // Direct Read Fast Path 只允许「高置信度、无歧义、无额外过滤条件」的
            // 全局 aggregate。“有多少中文歌手 / 多少古典歌 / 多少无损歌曲”都带
            // 限定/过滤条件，绝不能直接退化为曲库总体统计；这类请求进入普通模型
            // 规划 + 真实查询能力（或如实说明当前字段无法可靠统计）。
            if quantityQuery,
               has(["歌曲", "歌手", "艺人", "专辑", "歌单", "曲库", "音乐库"]),
               !Self.isQualifiedAggregateQuery(value) {
                return Self.directRead("library_get_summary")
            }
            if artistListQuery
                && !explicitPlaylistAction {
                return Self.directRead("library_get_artists", limit: requestedLimit)
            }
            if albumListQuery && !explicitPlaylistAction {
                return Self.directRead("library_get_albums", limit: requestedLimit)
            }
            if has(["服务器列表", "列出服务器", "有哪些服务器", "已连接服务器", "list servers", "server list"])
                && !serverMutation {
                return Self.directRead("server_list")
            }
            return nil
        }()

        var requested = Set<ToolAuthorizationOperation>()
        // 同义表达 → canonical operation 的确定性编译。Task Compiler 不允许
        // LLM 输出权限：queueReplace 只来自结构化判定（explicitQueueReplace），
        // 裸“换成/换为/替换成”不再授权任何 mutation。
        if explicitPlaybackAction && !playbackQuery {
            if has(["暂停", "pause"]) { requested.insert(.playbackPause) }
            else if has(["下一首", "上一首", "next track", "previous track"]) { requested.insert(.playbackNavigation) }
            else if has(["快进", "快退", "跳转", "seek"]) { requested.insert(.playbackSeek) }
            else if has(["循环", "随机播放", "shuffle", "repeat", "变速", "速度"]) { requested.insert(.playbackMode) }
            else { requested.insert(.playbackPlay) }
            if explicitQueueReplace {
                requested.insert(.queueReplace)
            }
        }

        if explicitQueueAction {
            if explicitQueueReplace
                || has(["建立队列", "创建队列", "建立播放队列", "建立一个播放队列"]) {
                requested.insert(.queueReplace)
            }
            if has(["清空队列", "清空当前队列", "queue_clear", "clear queue"]) { requested.insert(.queueClear) }
            if has(["移出队列", "从队列移除", "queue_remove", "remove from queue"]) { requested.insert(.queueRemove) }
            if has(["调整队列", "移动队列", "queue_move", "reorder", "move queue"]) { requested.insert(.queueMove) }
            if has(["随机剩余队列", "queue_shuffle_remaining", "shuffle remaining"]) { requested.insert(.queueShuffle) }
            if has(["接下来播放", "play next", "queue_play_next"]) { requested.insert(.queuePlayNext) }
            if has(["加入队列", "放进队列", "放到队列", "queue_append"]) { requested.insert(.queueAppend) }
        }

        // 复合意图编译：跨域组合操作。
        // “替换到队列播放 / 用这些歌覆盖当前队列然后开始播放” → queueReplace + playbackPlay。
        if requested.contains(.queueReplace),
           has(["播放", "开始播放", "开播", "接着放", "放出来"]),
           !requested.contains(.playbackPause),
           !requested.contains(.playbackNavigation) {
            requested.insert(.playbackPlay)
        }
        // “加入队列并播放下一首” → queueAppend + queuePlayNext。
        if requested.contains(.queueAppend), has(["播放下一首", "接下来播放", "下一首播放"]) {
            requested.insert(.queuePlayNext)
        }

        if explicitPlaylistAction {
            if has(["创建歌单", "新建歌单", "playlist_create"])
                || (has(["歌单", "playlist", "播放列表"]) && has(["创建", "新建", "建一个", "建立"])) {
                requested.insert(.playlistCreate)
            }
            if has(["加入歌单", "加到歌单", "添加到歌单", "放到歌单", "放进歌单", "放入歌单", "收进歌单", "playlist_add"])
                || (has(["歌单", "playlist", "播放列表"]) && has(["加入", "加到", "添加", "放到", "放进", "放入", "收进"])) {
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
            if has(["保存当前队列为歌单", "保存队列为歌单", "把当前队列保存为歌单", "存为歌单", "保存成歌单", "保存队列", "save queue"]) {
                requested.insert(.playlistSaveQueue)
            }
        }

        if explicitAnnotationAction {
            if ratingMutation { requested.insert(.ratingSet) }
            else if has(["不喜欢", "不感兴趣", "dislike"]) { requested.insert(.dislikedSet) }
            else if has(["rating", "rate", "评分", "打分"]) {
                // 英文/中文评分查询（what is this track's rating?）：纯读取，
                // 不产生 favoriteSet / ratingSet mutation 授权。
            }
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

        if customToolCreate { requested.insert(.customToolCreate) }
        if customToolUpdate { requested.insert(.customToolUpdate) }
        if customToolEnable { requested.insert(.customToolEnable) }
        if customToolDisable { requested.insert(.customToolDisable) }
        if customToolDelete { requested.insert(.customToolDelete) }
        if customToolRepair { requested.insert(.customToolRepair) }

        if explicitMemory {
            return Self(domain: .memory, operation: requested.isEmpty ? .read : .mutate, isMusicContext: isMusicContext, isContinuation: continuation, requestedOperations: requested, suggestedToolNamespaces: ["memory"])
        }
        if explicitCustomTool {
            return Self(domain: .customTool, operation: requested.isEmpty ? .read : .mutate, isMusicContext: false, isContinuation: continuation, requestedOperations: requested, suggestedToolNamespaces: ["tool_builder"])
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
            return Self(domain: .server, operation: serverMutation ? .mutate : .read, isMusicContext: isMusicContext, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["server"], directReadCapability: directReadCapability)
        }
        if isMusicContext && (diagnosticContext || statisticsContext) {
            return Self(domain: .diagnostics, operation: .read, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["catalog", "playback", "server"], directReadCapability: directReadCapability)
        }
        if downloadContext && isMusicContext {
            return Self(domain: .download, operation: query ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["download", "server", "catalog"])
        }

        let playlistContext = explicitMusicNouns && has(["歌单", "playlist", "播放列表"])
        if playlistContext {
            if recommendationRequest && !explicitPlaylistAction {
                return Self(domain: .recommendation, operation: .discover, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["catalog", "playback", "playlist", "recommendation"])
            }
            return Self(domain: .playlist, operation: requested.isEmpty ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["playlist", "catalog"], directReadCapability: directReadCapability)
        }

        let queueContext = explicitMusicNouns && has(["队列", "queue", "接下来播放"])
        if queueContext {
            let namespaces = recommendationRequest
                ? ["playback", "catalog", "recommendation"]
                : ["playback"]
            return Self(domain: .queue, operation: requested.isEmpty ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: Set(namespaces), directReadCapability: directReadCapability)
        }

        if explicitPlaybackAction || (explicitMusicNouns && has(["播放"])) {
            let namespaces = recommendationRequest
                ? ["playback", "catalog", "recommendation"]
                : ["playback", "catalog"]
            return Self(domain: .playback, operation: requested.isEmpty ? .read : .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: Set(namespaces), directReadCapability: directReadCapability)
        }
        if explicitAnnotationAction {
            return Self(domain: .musicLibrary, operation: .mutate, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["annotation", "catalog"])
        }
        if recommendationRequest && isMusicContext {
            return Self(domain: .recommendation, operation: .discover, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: ["catalog", "playback"])
        }
        if isMusicContext && (genericSearch || query || collectionQuery) {
            let namespaces = collectionQuery ? ["catalog", "server", "annotation"] : ["catalog", "server"]
            return Self(domain: .musicLibrary, operation: .read, isMusicContext: true, isContinuation: continuation, isMusicAppreciation: musicAppreciation, requestedOperations: requested, suggestedToolNamespaces: Set(namespaces), directReadCapability: directReadCapability)
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

    /// 判定一个「数量 + 曲库名词」请求是否带有限定/过滤条件。
    ///
    /// 原则是结构化的，不是无限关键词黑名单：
    /// 1. 数量词与聚合名词之间的片段必须为空（或只含量词/标点）——“有多少中文歌手”
    ///    的数量词与“歌手”之间夹着“中文” → 限定；而“一共有多少歌手”之间为空 → 全局。
    /// 2. 聚合名词前出现「X的」所有格（周杰伦的、2020年的、我的除外）→ 限定。
    /// 3. 文本中出现 4 位年份、或 bounded 修饰词类别（语言/国别/性别/年代/格式/
    ///    音质/流派/收藏状态）→ 限定。
    ///
    /// 允许仍走 Fast Path 的例子：
    /// - “音乐库统计 / 曲库有多少首歌 / 一共有多少歌手 / 音乐库有多少张专辑”
    /// 不允许直接 library_get_summary 的例子：
    /// - “有多少中文歌手 / 有多少女歌手 / 有多少日本歌手 / 多少古典歌曲 /
    ///   多少无损歌曲 / 有多少 2020 年后的专辑 / 多少周杰伦的歌”
    static func isQualifiedAggregateQuery(_ value: String) -> Bool {
        let aggregateNouns = ["歌曲", "歌手", "艺人", "艺术家", "专辑", "歌单", "曲库", "音乐库"]
        let quantityMarkers = ["有多少", "多少", "数量", "几首", "几位", "几张", "几个", "几支", "几"]
        // 数量词与名词之间允许出现的量词/助词。
        let spanAllowlist = CharacterSet(charactersIn: "的个位张首条项支名左右多共总大概约以上下")

        // 1) 所有格限定：X的歌曲/歌/专辑/歌手/艺人/艺术家/作品（X 不是通用指代）。
        let possessivePattern = #"([^\s，。、！？!?；;：:]{1,8})的(?:歌曲|歌|专辑|歌手|艺人|艺术家|作品)"#
        if let regex = try? NSRegularExpression(pattern: possessivePattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.matches(in: value, range: range)
            for match in matches where match.numberOfRanges > 1 {
                let capture = match.range(at: 1)
                guard capture.location != NSNotFound,
                      let owner = Range(capture, in: value) else { continue }
                let ownerText = String(value[owner])
                let genericOwners = ["我的", "你的", "这个", "这些", "那个", "那些", "当前", "现在", "全部", "所有", "整个", "本地"]
                guard !genericOwners.contains(ownerText) else { continue }
                return true
            }
        }

        // 2) 4 位年份（2020 年后的专辑 / 80 年代除外但年份数字是硬信号）。
        if value.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) != nil {
            return true
        }

        // 3) bounded 修饰词类别：语言/国别/性别/年代/格式/音质/流派/收藏状态。
        //    这是有限的类别词表，不是对具体艺人/歌手名的无限枚举。
        let modifierCategories = [
            "中文", "国语", "粤语", "闽南语", "英语", "英文", "日语", "日文", "韩语", "韩文",
            "法语", "德语", "西班牙语", "意大利语", "俄语", "泰语", "华语", "外国",
            "女", "男", "女性", "男性",
            "古典", "流行", "摇滚", "爵士", "民谣", "电子", "说唱", "嘻哈", "重金属", "朋克",
            "蓝调", "乡村", "轻音乐", "纯音乐", "民乐", "交响", "古风", "二次元", "动漫",
            "无损", "高音质", "高清", "高品质", "低音质", "压缩", "flac", "ape", "wav", "mp3",
            "原声", "现场", "翻唱", "重制", "remaster", "live", "cover", "acoustic",
            "新歌", "老歌", "经典", "热门", "冷门", "小众", "早期", "早期作品",
            "收藏", "喜欢的", "最近", "新添加", "新加入", "最常听",
        ]
        if modifierCategories.contains(where: value.contains) {
            return true
        }

        // 4) 结构性 span 检查：数量词与聚合名词之间不能夹非量词内容。
        //    “有多少中文歌手”：在“多少”与“歌手”之间是“中文” → 限定。
        //    “曲库有多少首歌”：聚合名词“曲库”在数量词之前，span 为空 → 全局。
        for marker in quantityMarkers {
            guard let markerRange = value.range(of: marker) else { continue }
            let afterMarker = value[markerRange.upperBound...]
            for noun in aggregateNouns {
                guard let nounRange = afterMarker.range(of: noun) else { continue }
                let span = afterMarker[..<nounRange.lowerBound]
                let significant = span.filter { character in
                    !spanAllowlist.contains(character.unicodeScalars.first ?? " ") && !character.isWhitespace
                }
                if !significant.isEmpty {
                    return true
                }
            }
        }

        return false
    }

    private static func directRead(_ toolName: String, limit: Int? = nil) -> DirectReadCapability {
        let arguments = limit.map { ["limit": AIJSONValue.number(Double($0))] } ?? [:]
        return DirectReadCapability(toolName: toolName, arguments: arguments)
    }

    /// Extract an explicit list size without making the direct-read route
    /// depend on the model. Tool-specific maximums remain enforced by the
    /// canonical executor.
    private static func requestedLimit(in text: String) -> Int? {
        let pattern = #"(?:前|最多|显示|列出|查看|获取|最近播放(?:的)?|最近听过(?:的)?)\s*(?:的\s*)?(\d{1,4})\s*(?:个|位|张|首|条|项)?|(?:^|[^\d])(\d{1,4})\s*(?:个|位|张|首|条|项)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            let capture = match.range(at: index)
            guard capture.location != NSNotFound,
                  let value = Int((text as NSString).substring(with: capture)),
                  value > 0
            else { continue }
            return value
        }
        return nil
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
