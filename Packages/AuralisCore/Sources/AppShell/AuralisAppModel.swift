import AIKit
import AgentKit
import Application
import Combine
import LocalCatalog
import Domain
import Foundation
import ImagePipeline
import LyricsKit
import Observability
import OfflineManager
import PlaybackEngine
import SystemMediaIntegration
#if os(macOS)
import AppKit
#elseif os(iOS)
import ActivityKit
import UIKit
import Intents
#endif

@MainActor
public final class AuralisAppModel: ObservableObject {
    /// App 全局共享实例：快捷指令 / Siri 等系统入口需要访问与界面同一个播放服务。
    /// 视图持有它而非各自新建，保证「统一播放状态」。
    public static let shared = AuralisAppModel()
    @Published public var selectedSection: AppSection = .home
    public let playbackStore: PlaybackStore
    /// 播放队列展示状态：与高频播放状态分离，上万首队列更新只发布到这里，
    /// 普通播放器控件不再因 queue 变化整体 invalidate。
    public let queueStore = PlaybackQueuePresentationStore()
    /// 领域状态由独立 Store 持有；AppModel 保留兼容门面与跨领域编排。
    let homeStore: HomeStore
    let libraryStore: LibraryStore
    let serverStore: ServerStore
    let downloadStore: DownloadStore
    private let liveActivityManager = LiveActivityManager.shared
    private var childStoreSubscriptions: Set<AnyCancellable> = []

    /// 子 Store 可能在一次逻辑更新中连续发布多次（例如 HomeStore.apply 依次写 12 个 @Published）。
    /// 兼容旧的全局 model 观察方式，但必须：
    ///
    /// 1. 延迟到当前 SwiftUI 更新事务结束以后；
    /// 2. 同一个 RunLoop 中合并为一次全局 invalidation。
    ///
    /// 否则 HomeStore.apply 等批量更新会在 SwiftUI body/update
    /// 尚未结束时同步触发 AuralisAppModel.objectWillChange，
    /// 导致：
    /// "Publishing changes from within view updates is not allowed"
    private var childStoreInvalidationScheduled = false

    private func scheduleChildStoreInvalidation() {
        guard !childStoreInvalidationScheduled else { return }
        childStoreInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.childStoreInvalidationScheduled = false
                self.objectWillChange.send()
            }
        }
    }
    public var currentTrack: Track {
        get { playbackStore.currentTrack }
        set {
            guard playbackStore.currentTrack != newValue else { return }
            playbackStore.currentTrack = newValue
            queueStore.updateCurrentIndex(currentTrackID: queueIdentity(newValue))
        }
    }
    /// 仅在需要「切换当前曲目但不马上在旧队列里定位」时使用（上下文播放的 deferred 路径）。
    /// 旧队列 10000 首扫描由新队列安装统一处理，避免双击时的 O(N) 扫描与 O(N) 队首插入。
    private func setCurrentTrackWithoutQueueUpdate(_ track: Track) {
        guard playbackStore.currentTrack != track else { return }
        playbackStore.currentTrack = track
    }
    /// AI 助手输入框的草稿文本。提升到模型层是为了让底部 Dock（iOS）
    /// 与助手页面（macOS）共用同一份输入，避免嵌套 safeAreaInset 造成的布局重叠。
    @Published public var assistantDraft: String = ""
    /// “不喜欢”状态的内存镜像（SQLite disliked_tracks 是唯一权威）。
    /// 用于同步 UI 读取；启动/同步/变更时从目录刷新。
    @Published public private(set) var dislikedTrackIDs: Set<GlobalID> = []
    /// 内存镜像所属的服务器。异步刷新完成后必须匹配当前服务器，避免切服时旧结果反扑。
    private var dislikedStateServerID: ServerID?
    /// 搜索不再是主导航页；系统入口需要搜索时由 AI 助手展示本地/服务器搜索兜底页。
    @Published public var shouldPresentAssistantSearch = false
    /// 桌面版仅在已有实际播放项目时显示底部迷你播放器；iPhone 的 Dock 则在首页和
    /// 音乐库固定显示，未播放时使用“未在播放”的紧凑内容。
    public var hasCurrentTrack: Bool { currentTrack.id.rawValue != "placeholder" }
    public var playbackState: PlaybackState {
        get { playbackStore.state }
        set {
            guard playbackStore.state != newValue else { return }
            playbackStore.state = newValue
        }
    }
    /// Position ticks are intentionally published only by `PlaybackStore`.
    /// Publishing them through the global model used to redraw every screen
    /// twice per second while music was playing.
    public var playbackPosition: TimeInterval {
        get { playbackStore.position }
        set { playbackStore.position = newValue }
    }
    /// 播放队列（只读视图）。R05：队列项身份是 QueueEntry.id（UUID），歌曲身份
    /// 与队列项身份分离——同一首歌允许出现多次。SwiftUI 渲染必须使用
    /// `queueStore.entries`（entry.id 作身份），不能用这首歌的 TrackID。
    public var queue: [Track] {
        get { queueStore.tracks }
        set {
            // 内容级防重（避免相同赋值反复重建 entry）：不再按歌曲去重。
            guard queueStore.tracks != newValue else { return }
            // 每首歌曲包成独立 QueueEntry（新 UUID），允许重复歌曲进入队列。
            // R05：若当前曲目在新队列中，保留其 entry UUID——否则 setter 重建
            // entry 会让 currentEntryID 失效、回退到 firstIndex 匹配，导致
            // [A, B, A] 播放第二个 A 时下标漂移到第一个 A。
            let currentEntryID = queueStore.currentEntryID
            var rebuilt = newValue.map { QueueEntry(track: $0) }
            if let currentEntryID,
               let currentEntry = queueStore.entries.first(where: { $0.id == currentEntryID }),
               let newIndex = rebuilt.firstIndex(where: { queueIdentity($0.track) == queueIdentity(currentEntry.track) }) {
                rebuilt[newIndex] = QueueEntry(id: currentEntryID, track: newValue[newIndex])
            }
            queueStore.replace(entries: rebuilt, currentTrackID: queueIdentity(currentTrack))
            // 队列变更：开启新一轮随机（避免旧轮次的“已播放”标记污染新队列）。
            shufflePlayedEntryIDs.removeAll()
            // 队列是播放会话的一部分：变更即持久化（按服务器隔离），
            // 进程重启后可恢复上次的队列与当前曲目。
            // 用 debounce 调度（350ms 合并 + utility 后台），禁止在队列 setter
            // 里同步 JSON encode + UserDefaults 写大队列。
            schedulePlaybackSessionPersistence()
            schedulePreparedNext()
        }
    }
    /// 队列项（带独立 UUID 身份）：SwiftUI ForEach / List 渲染用这里的 id。
    public var queueEntries: [QueueEntry] {
        get { queueStore.entries }
        set {
            guard queueStore.entries != newValue else { return }
            queueStore.replace(entries: newValue, currentTrackID: queueIdentity(currentTrack))
            shufflePlayedEntryIDs.removeAll()
            schedulePlaybackSessionPersistence()
            schedulePreparedNext()
        }
    }
    @Published public var isNowPlayingPresented = false
    @Published public var shouldPresentServerSetup = false
    @Published public var browseDestination: BrowseDestination?
    /// 首页布局偏好（模块显示 / 排序）。持久化到 UserDefaults（HomeLayoutStore），
    /// App 完全退出重开仍保留；「恢复默认布局」只重置这一份偏好，不删任何数据。
    public var homeLayout: HomeLayoutPreference { homeStore.layout }
    @Published public var inspector: InspectorSection = .queue
    public private(set) var serverConnectionState: ServerConnectionViewState {
        get { serverStore.connectionState }
        set { serverStore.connectionState = newValue }
    }
    /// 服务器认证是否可能已失效（流播放返回 authorizationFailed 时置位，
    /// 成功连接 / 切换服务器后清除）。用于提示用户重新登录。
    public private(set) var serverAuthenticationFailed: Bool {
        get { serverStore.authenticationFailed }
        set { serverStore.authenticationFailed = newValue }
    }
    public private(set) var serverCapabilities: ServerCapabilities {
        get { serverStore.capabilities }
        set { serverStore.capabilities = newValue }
    }
    public private(set) var catalog: LibraryCatalog {
        get { libraryStore.catalog }
        set {
            libraryStore.catalog = newValue
            catalogRevision &+= 1
        }
    }
    /// O(1) 的目录内容修订号。只在 catalog 替换/实体内容改变时递增；播放进度 tick 不变。
    @Published public private(set) var catalogRevision: UInt64 = 0
    /// 当前 item 的真实时长（秒），由引擎按需回报；目录元数据时长可能不准，
    /// 播放页进度条、控制中心与 Live Activity 以此为准（真机反馈：进度条到头仍在播）。
    /// 真实时长由 PlaybackStore 持有，避免全局 AppModel 的额外 invalidate。
    public var actualDuration: TimeInterval? {
        get { playbackStore.actualDuration }
        set { playbackStore.actualDuration = newValue }
    }
    /// apply() 排队的后台派生任务（首页货架 / 随机音乐 / library-added 对齐）。
    /// 生产首帧不等待它；测试通过 `awaitPendingApplyDerivations()` 确定性等待。
    private var pendingApplyDerivations: Task<Void, Never>?
    /// apply 派生代际计数：快速切换服务器/连续 apply 时，旧代际后台任务完成后
    /// 必须被丢弃，避免旧服务器/旧目录的派生结果覆盖新状态（P1-3）。
    private var applyGeneration: UInt64 = 0
    /// O(1) 的歌曲行元数据修订号。播放次数或首次入库日期改变时递增；播放进度 tick 不变。
    @Published public private(set) var libraryRowMetadataRevision: UInt64 = 0
    /// O(1) 的「不喜欢」集合修订号：dislikedTrackIDs 内容变化时递增。
    @Published public private(set) var dislikedRevision: UInt64 = 0
    /// O(1) 的「最近播放」修订号：播放记录变化时递增（驱动最近播放 Table 重建）。
    @Published public private(set) var recentlyPlayedRevision: UInt64 = 0
    /// O(1) 的「收藏」修订号：歌曲收藏状态变化时递增（驱动收藏 Table 重建）。
    @Published public private(set) var favoritesRevision: UInt64 = 0
    /// O(1) 的「已下载集合」修订号：只在已下载歌曲集合本身变化时递增
    /// （下载进度等高频状态不递增，避免下载中反复重建歌曲 Table）。
    public var downloadsRevision: UInt64 {
        downloadStore.downloadedContentRevision
    }
    /// 最近一次「测试连接 / 连接」的客观诊断快照（DEBUG 网络诊断页使用）。
    @Published public private(set) var connectionDiagnostics: ConnectionDiagnosticsSnapshot?

    /// 连接诊断快照：记录最近一次测试/连接的客观事实，不伪造权限状态。
    public struct ConnectionDiagnosticsSnapshot: Sendable, Equatable {
        public let timestamp: Date
        public let host: String?
        public let isPrivateLAN: Bool
        public let scheme: String?
        public let requestAttempted: Bool
        public let nsErrorDomain: String?
        public let nsErrorCode: Int?
        public let nsErrorDescription: String?
        public let failingURL: String?
        public let underlyingError: String?
        public let mappedMessage: String

        public init(
            timestamp: Date = .now,
            host: String?,
            isPrivateLAN: Bool,
            scheme: String?,
            requestAttempted: Bool,
            nsErrorDomain: String? = nil,
            nsErrorCode: Int? = nil,
            nsErrorDescription: String? = nil,
            failingURL: String? = nil,
            underlyingError: String? = nil,
            mappedMessage: String
        ) {
            self.timestamp = timestamp
            self.host = host
            self.isPrivateLAN = isPrivateLAN
            self.scheme = scheme
            self.requestAttempted = requestAttempted
            self.nsErrorDomain = nsErrorDomain
            self.nsErrorCode = nsErrorCode
            self.nsErrorDescription = nsErrorDescription
            self.failingURL = failingURL
            self.underlyingError = underlyingError
            self.mappedMessage = mappedMessage
        }
    }

    /// 记录连接诊断快照；DEBUG 下同时输出原始 NSError 层级信息（domain/code/failingURL/underlying）。
    private func recordConnectionDiagnostics(
        host: String?, url: URL?, error: Error?, message: String, requestAttempted: Bool
    ) {
        let ns = error as NSError?
        let failing = (error as? URLError)?.failingURL?.absoluteString
        // URLError 没有公开的 .underlying；从 NSError userInfo 提取底层错误。
        let underlyingError = ns?.userInfo["NSUnderlyingError"] as? Error
        let underlying = underlyingError.map {
            ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription
        }
        connectionDiagnostics = ConnectionDiagnosticsSnapshot(
            host: host ?? url?.host,
            isPrivateLAN: (host ?? url?.host).map(ServerURLPolicy.isPrivateOrLocal) ?? false,
            scheme: url?.scheme?.lowercased(),
            requestAttempted: requestAttempted,
            nsErrorDomain: ns?.domain,
            nsErrorCode: ns?.code,
            nsErrorDescription: (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription,
            failingURL: failing,
            underlyingError: underlying,
            mappedMessage: message
        )
        #if DEBUG
        if let error {
            NSLog("[Auralis] 连接诊断 host=%@ url=%@ domain=%@ code=%ld desc=%@ failingURL=%@ underlying=%@ mapped=%@",
                  host ?? "?", url?.absoluteString ?? "?", ns?.domain ?? "?", ns?.code ?? -1,
                  error.localizedDescription, failing ?? "?", underlying ?? "?", message)
        } else {
            NSLog("[Auralis] 连接诊断 host=%@ url=%@ 成功 mapped=%@", host ?? "?", url?.absoluteString ?? "?", message)
        }
        #endif
    }

    /// 独立封面管线与有界内存缓存。ArtworkView 直接依赖它，不再观察整个 AppModel。
    let artworkStore: ArtworkStore
    /// 循环模式，持久化到 UserDefaults。
    @Published public var repeatMode: RepeatMode {
        didSet {
            defaults.set(repeatMode.rawValue, forKey: Self.repeatModeDefaultsKey)
            mediaIntegration.modeChanged(isShuffled: isShuffled, repeatMode: repeatMode)
            schedulePreparedNext()
        }
    }
    /// 播放速度 0.5...2.0（默认 1.0），持久化到 UserDefaults。
    @Published public private(set) var playbackRate: Float = 1.0
    private static let playbackRateDefaultsKey = "auralis.playbackRate"
    /// 播放器音量 0...1，持久化到 UserDefaults。
    @Published public private(set) var volume: Float
    @Published public private(set) var replayGainSettings: ReplayGainSettings
    private var prepareNextTask: Task<Void, Never>?
    /// 本次随机播放轮次中已随机播放过的曲目（TrackID）。
    /// 随机 + 不循环：一轮随机播完即停；随机 + 列表循环：一轮播完重置继续。
    /// 队列变更 / 重新开启随机时清空，避免旧轮次污染新队列。
    /// 随机模式下本轮已随机播放过的队列项（R05：按 entry UUID 记录）。
    /// 重复歌曲是独立队列项——[A₁, B, A₂, C] 随机播过 A₁ 后，A₂ 仍可被选中。
    private var shufflePlayedEntryIDs: Set<UUID> = []
    /// macOS 侧边栏搜索框的查询词（搜索页实时使用）。
    @Published public var macSearchQuery: String = ""
    /// 播放历史与单次播放达标状态由独立组件管理，避免“点选即计数”。
    private var playbackHistoryStore: PlaybackHistoryStore

    public var playCountStorage: [String: Int] { playbackHistoryStore.counts }

    /// 当前活跃服务器下的播放次数（trackID → 次数）。跨服务器查询时为空。
    public var playCounts: [TrackID: Int] {
        guard let serverID = catalog.activeServerID else { return [:] }
        return playbackHistoryStore.counts(for: serverID)
    }

    /// Row cache 的读取必须由 Track 的服务器身份决定，不能把不同服务器的相同 TrackID 混用。
    public func playCount(for track: Track) -> Int {
        playbackHistoryStore.count(for: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
    }
    /// 已下载到本地的歌曲。
    public var downloadedTrackIDs: Set<GlobalID> { downloadStore.downloadedTrackIDs }
    /// 正在下载的歌曲。
    public var downloadingTrackIDs: Set<GlobalID> { downloadStore.downloadingTrackIDs }
    /// 全部服务器作用域的下载进度（0...1）。
    public var downloadingProgressByGlobalID: [GlobalID: Double] { downloadStore.progress }
    /// 排队、传输、失败与完成状态的完整快照。下载页用它保留失败原因并提供重试。
    public var downloadRecords: [GlobalID: DownloadTaskInfo] { downloadStore.records }
    public var lastDownloadOperationError: String? { downloadStore.lastOperationError }
    public var downloadedAudioBytes: Int64 {
        downloadStore.cachedEntries.values.reduce(into: Int64(0)) { $0 += $1.byteCount }
    }
    /// 当前活跃服务器的兼容投影；内部状态始终使用 GlobalID，避免同 TrackID 跨服务器碰撞。
    public var downloadingProgress: [TrackID: Double] {
        guard let serverID = catalog.activeServerID else { return [:] }
        return Dictionary(uniqueKeysWithValues: downloadStore.progress.compactMap { globalID, value in
            guard globalID.serverID == serverID else { return nil }
            return (TrackID(rawValue: globalID.remoteID), value)
        })
    }
    /// 随机播放模式，持久化到 UserDefaults。
    @Published public private(set) var isShuffled: Bool {
        didSet {
            defaults.set(isShuffled, forKey: Self.shuffleDefaultsKey)
            mediaIntegration.modeChanged(isShuffled: isShuffled, repeatMode: repeatMode)
            if isShuffled {
                // 重新开启随机：新一轮；当前队列项计入本轮已播放（R05：按 entry UUID）。
                shufflePlayedEntryIDs.removeAll()
                if currentTrack.id.rawValue != "placeholder", let entryID = queueStore.currentEntryID {
                    shufflePlayedEntryIDs.insert(entryID)
                }
            }
            schedulePreparedNext()
        }
    }
    /// 最近播放的曲目 ID（最近在前），持久化到 UserDefaults，驱动首页「最近播放」。
    /// 最近播放的曲目组合键（"serverID:trackID"，最近在前），按服务器隔离持久化。
    /// 最近播放的曲目 ID（最近在前，按当前服务器过滤，避免两台服务器同 ID 歌曲混在一起）。
    public var recentlyPlayedIDs: [TrackID] {
        guard let serverID = catalog.activeServerID else { return [] }
        return playbackHistoryStore.recentIDs(for: serverID)
    }

    /// 播放会话持久化快照（按服务器隔离，存 UserDefaults）：当前曲目、队列、进度。
    /// 故意不保存「正在播放」标记——进程重启后恢复为暂停，由用户点击播放继续。
    /// R05：额外保存 currentQueueIndex——重复歌曲 [A, B, A, C] 当前播第二个 A 时，
    /// 只存 currentTrackID 无法区分是 index 0 还是 index 2 的 A；恢复时用下标精确定位
    /// 队列项，重启/Handoff 后不丢失 occurrence。
    private struct PlaybackSessionSnapshot: Codable, Sendable, Equatable {
        var currentTrackID: String?
        var queueTrackIDs: [String]
        var position: TimeInterval
        var currentQueueIndex: Int?
        var updatedAt: Date

        init(
            currentTrackID: String?,
            queueTrackIDs: [String],
            position: TimeInterval,
            currentQueueIndex: Int? = nil,
            updatedAt: Date = .now
        ) {
            self.currentTrackID = currentTrackID
            self.queueTrackIDs = queueTrackIDs
            self.position = position
            self.currentQueueIndex = currentQueueIndex
            self.updatedAt = updatedAt
        }
    }
    /// 已缓存歌单的完整曲目（按歌单 ID 索引），从服务器按需拉取。
    public private(set) var playlistTracks: [PlaylistID: [Track]] {
        get { libraryStore.playlistTracks }
        set { libraryStore.playlistTracks = newValue }
    }
    /// 正在加载曲目的歌单 ID。
    public private(set) var loadingPlaylistIDs: Set<PlaylistID> {
        get { libraryStore.loadingPlaylistIDs }
        set { libraryStore.loadingPlaylistIDs = newValue }
    }
    /// 服务器列表显示该歌单已有更新、但 getPlaylists 不含完整 entry 时，
    /// 需要随后通过 getPlaylist 拉取最新曲目顺序的歌单。
    private var playlistIDsNeedingContentRefresh: Set<PlaylistID> = []
    /// 当前进程内已成功删除的歌单。屏蔽并发请求里携带的过期列表，直到下次冷启动。
    private var deletedPlaylistIDs: Set<PlaylistID> = []
    /// 删除请求被服务器明确拒绝或验证仍存在时的可展示提示，避免 UI 静默失败。
    public private(set) var playlistDeletionError: String? {
        get { libraryStore.playlistDeletionError }
        set { libraryStore.playlistDeletionError = newValue }
    }
    /// 随机音乐（首页「随机音乐」货架）：资料库载入时随机采样一次，避免界面频繁重排。
    public var randomTracks: [Track] { homeStore.randomTracks }
    /// 首页「收藏 / 最常听 / 最近播放 / 最近添加」货架快照。
    /// 只在数据真正变化时刷新（资料库同步 / 播放记录 / 收藏切换），
    /// 避免滚动等场景下每次 body 重算都全库过滤 + 排序一遍——大曲库时
    /// 这是首页上下滑动卡顿的重要来源之一。
    public var homeFavoriteTracks: [Track] { homeStore.favorites }
    public var homeMostPlayedTracks: [Track] { homeStore.mostPlayed }
    public var homeRecentlyPlayedTracks: [Track] { homeStore.recentlyPlayed }
    public var homeRecentlyAddedTracks: [Track] { homeStore.recentlyAdded }
    /// 首页「很久没听」：播放过但较久未播放（快照，见 refreshHomeSnapshots 的规则注释）。
    public var homeLongUnplayedTracks: [Track] { homeStore.longUnplayed }
    /// 首页「从未播放」：播放次数为 0 且不在播放历史（快照）。
    public var homeNeverPlayedTracks: [Track] { homeStore.neverPlayed }
    /// 首页「收藏里随便听」：从真实收藏随机采样（刷新时采样一次，换一批时重新采样）。
    public var homeFavoriteRandomTracks: [Track] { homeStore.favoriteRandom }
    /// 首页「最近添加」：近 30 天真正新增的歌曲（数量显示「近30天新增 N 首」，而非全库总数）。
    public var homeRecentlyAdded30DaysTracks: [Track] { homeStore.recentlyAdded30Days }
    /// 首页「常听艺术家 / 常听专辑」：按真实播放次数聚合（仅含播放过的）。
    public var homeTopArtists: [Artist] { homeStore.topArtists }
    public var homeTopAlbums: [Album] { homeStore.topAlbums }
    /// 常听艺术家 / 常听专辑的累计播放次数（供详情页显示「N 次播放」）。
    public var homeTopArtistPlayCounts: [ArtistID: Int] { homeStore.artistPlayCounts }
    public var homeTopAlbumPlayCounts: [AlbumID: Int] { homeStore.albumPlayCounts }
    /// 流派详情从服务器按需拉取的歌曲（本地按曲目标签筛选为空时回退到服务器）。
    public private(set) var genreTracks: [Track]? {
        get { libraryStore.genreTracks }
        set { libraryStore.genreTracks = newValue }
    }
    /// 当前正在按流派从服务器加载的流派；为 nil 表示没有进行中的加载。
    public private(set) var loadingGenre: Genre? {
        get { libraryStore.loadingGenre }
        set { libraryStore.loadingGenre = newValue }
    }
    /// 播放错误（streamURL 为 nil 等），供 UI 展示提示。
    @Published public private(set) var playbackError: PlaybackError? = nil
    /// 首次入库时间按 GlobalID 隔离，并由独立组件执行线性 reconcile / 迁移。
    private var libraryAddedTracker: LibraryAddedTracker

    /// 系统媒体集成（Now Playing / 远程命令 / 中断与路由）。
    public let mediaIntegration = SystemMediaIntegrationController()

    /// 本地音乐目录（SQLite + FTS5）与同步生命周期。首次访问时惰性创建。
    /// 曲库分类索引文件（Agent 按需读取；同步完成后刷新）。
    public private(set) lazy var libraryCatalogIndex = LibraryCatalogIndexStore(
        directoryURL: LibraryCatalogIndexStore.defaultDirectory()
    )
    public private(set) lazy var catalogCoordinator: CatalogCoordinator = {
        let coordinator: CatalogCoordinator
        if let runtimeCatalogStore {
            coordinator = CatalogCoordinator(
                connector: connector,
                store: runtimeCatalogStore,
                trackCache: cacheStore,
                lyricsCache: lyricsCache
            )
        } else {
            // 自定义 connector 的测试/预览便利路径；生产一定走上面的共享 store。
            coordinator = CatalogCoordinator(
                connector: connector,
                storeURL: storeURL,
                trackCache: cacheStore,
                lyricsCache: lyricsCache
            )
        }
        // 同步完成后刷新曲库分类索引文件，让 Agent 始终能读到最新元数据；
        // 并把内存目录从本地 SQLite 重建出来，让首页「最近添加」与音乐库立刻反映
        // 新下载到服务器的曲目（此前只刷索引文件，内存目录要等用户重连/重启 apply() 才更新）。
        coordinator.onSyncCompleted = { [weak self] serverID, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.libraryCatalogIndex.refresh(
                    serverID: serverID,
                    catalog: self.catalogCoordinator.store
                )
                await self.refreshCatalogFromStore(serverID: serverID)
                // 同步完成后补缓存歌单曲目，保证 Agent 能读到歌单里的歌。
                self.cachePlaylistContentsInBackground()
            }
        }
        return coordinator
    }()
    /// App 级公开音乐资料服务：歌曲信息 UI、Agent、无歌词补全共用同一实例。
    public private(set) lazy var musicEnrichment = MusicEnrichmentService(catalog: catalogCoordinator.store)
    /// AI 助手运行时（会话 / 工具调用 / 确认 / 操作日志 / 偏好）。
    private(set) var agentCoordinatorWasInitialized = false
    public private(set) lazy var agentCoordinator: AgentCoordinator = {
        agentCoordinatorWasInitialized = true
        return AgentCoordinator(
            model: self,
            coordinator: catalogCoordinator,
            musicEnrichment: musicEnrichment
        )
    }()

    private let engine: any PlaybackControlling
    private let connector: any ServerConnecting
    /// 生产 composition root 创建的唯一目录 actor；Connector/Coordinator/Agent 共用。
    private let runtimeCatalogStore: LocalCatalogStore?
    /// 目录 SQLite 是否发生过降级（临时文件/内存库）。为 true 时设置页会展示提示，
    /// 避免「目录库打不开」被静默吞掉、用户只看到空资料库。
    @Published public private(set) var catalogFallbackUsed: Bool = false
    private let cacheStore: TrackCacheStore
    /// 封面磁盘缓存：冷启动直接读本地，不再每次打开 App 都重下全部封面。
    public let artworkCache: ArtworkDiskCache
    /// 歌词磁盘缓存（含「确认无歌词」负缓存），避免重复空跑请求。
    public let lyricsCache: LyricsDiskCache
    private let defaults: UserDefaults
    private let storeURL: URL?
    private var attemptedRestore = false
    /// 上一次 apply() 时的服务器 ID，用于判断是「同一台服务器的增量刷新」
    /// 还是「切换到另一台服务器」。只有后者才需要清空封面 / 歌词缓存。
    private var appliedServerID: ServerID?
    private var progressTimer: Timer?
    private var lyricsInFlight: Set<GlobalID> = []
    private var lyricsUnavailable: Set<GlobalID> = []
    /// R04：歌词加载结果三态，区分「成功 / 服务器确认无歌词 / 网络等失败」，
    /// 避免临时网络错误被写成负缓存导致永久不再请求。
    private enum LyricsLoadOutcome {
        case loaded(LyricsDocument)
        case notFound
        case failed
    }
    private var lyricsLoadTasks: [GlobalID: Task<LyricsLoadOutcome, Never>] = [:]
    /// 当前播放任务，用于取消之前的播放操作（快速切歌时避免竞态条件）。
    private var playbackTask: Task<Void, Never>?
    /// Handoff 活动：把当前播放（歌曲/队列/进度）接力到其他 Apple 设备。
    /// 只携带必要标识（serverID + trackID + 队列 ID + 进度），不含凭据 / 地址 / 文件路径。
    private static let handoffActivityType = "com.auralis.player.playback"
    private var handoffActivity: NSUserActivity?
    /// 当前曲目流地址失败重试次数（selectAndPlay 时清零），避免无限重试。
    private var streamRetryAttempts: [GlobalID: Int] = [:]
    private static let maxStreamRetryAttempts = 2
    /// 睡眠定时模式。
    public enum SleepTimerMode: String, Codable, Sendable, CaseIterable {
        case off
        case afterMinutes
        case afterCurrentTrack
        case afterCurrentAlbum
        case afterCurrentQueue

        public var title: String {
            switch self {
            case .off: String(localized: "关闭", bundle: .module)
            case .afterMinutes: String(localized: "若干分钟后停止", bundle: .module)
            case .afterCurrentTrack: String(localized: "当前歌曲结束后停止", bundle: .module)
            case .afterCurrentAlbum: String(localized: "当前专辑结束后停止", bundle: .module)
            case .afterCurrentQueue: String(localized: "当前队列结束后停止", bundle: .module)
            }
        }
    }

    /// 睡眠定时状态（内存态，不持久化；进程重启后不自动触发）。
    @Published public private(set) var sleepTimerMode: SleepTimerMode = .off
    /// 倒计时模式的结束时间（当前时间之前的时刻表示已过期）。
    @Published public private(set) var sleepTimerEndsAt: Date?
    private var sleepTimerTask: Task<Void, Never>?
    /// 最近一次播放停止原因（持久化，供诊断与后台播放审计）。
    @Published public private(set) var lastStopReason: PlaybackStopReason = .unknown
    private static let lastStopReasonDefaultsKey = "auralis.lastStopReason"
    /// 搜索历史（最近在前，最多 10 条），供搜索页快捷回填。
    @Published public private(set) var recentSearches: [String] = []
    private static let recentSearchesDefaultsKey = "auralis.recentSearches"

    /// 本地首次见到该曲目的时间（有真实数据时返回；否则 nil，不伪造）。
    public func addedDate(for track: Track) -> Date? {
        libraryAddedTracker.date(for: track)
    }
    /// Siri / URL Scheme 传入的待播放请求（歌曲名/歌手名；空字符串表示「播放音乐」）。
    /// 资料库尚未恢复（冷启动）时先暂存，待 apply() 恢复资料库后再消费，
    /// 避免找不到曲目。
    private var pendingSiriQuery: String?
    /// Siri 媒体项携带的精确 GlobalID（Intents 扩展从共享资料库解析而来）。
    private var pendingSiriGlobalID: GlobalID?

    private static let playCountsDefaultsKey = "auralis.playCounts"
    private static let volumeDefaultsKey = "auralis.volume"
    private static let replayGainModeDefaultsKey = "auralis.replayGain.mode"
    private static let replayGainPreampDefaultsKey = "auralis.replayGain.preampDB"
    private static let replayGainPeakProtectionDefaultsKey = "auralis.replayGain.peakProtection"
    private static let repeatModeDefaultsKey = "auralis.repeatMode"
    private static let shuffleDefaultsKey = "auralis.isShuffled"
    private static let legacyLastTrackDefaultsKey = "auralis.lastTrackID"
    private static func lastTrackKey(_ serverID: ServerID) -> String {
        "auralis.lastTrackID.\(serverID.rawValue)"
    }
    private static let recentlyPlayedDefaultsKey = "auralis.recentlyPlayed"
    private static let libraryAddedDefaultsKey = "auralis.libraryAdded"
    private static func playbackSessionKey(_ serverID: ServerID) -> String {
        "auralis.playbackSession.\(serverID.rawValue)"
    }

    /// 上次活跃服务器 ID（UserDefaults），用于冷启动与切换服务器时恢复正确的资料库。
    private static let lastActiveServerKey = "auralis.lastActiveServer"

    public init(
        catalog: LibraryCatalog = .empty,
        engine: any PlaybackControlling = AVFoundationPlaybackEngine(),
        connector: (any ServerConnecting)? = nil,
        cacheStore: TrackCacheStore = TrackCacheStore(),
        artworkCache: ArtworkDiskCache = ArtworkDiskCache(),
        lyricsCache: LyricsDiskCache = LyricsDiskCache(),
        defaults: UserDefaults = .standard,
        storeURL: URL? = nil,
        catalogStore: LocalCatalogStore? = nil
    ) {
        let appModelInitStartedAt = ContinuousClock.now
        let runtime: ApplicationRuntimeDependencies?
        if connector == nil {
            if let catalogStore {
                runtime = ApplicationComposition.makeRuntimeDependencies(catalogStore: catalogStore)
            } else {
                runtime = ApplicationComposition.makeRuntimeDependencies(catalogStoreURL: storeURL)
            }
        } else {
            runtime = nil
        }
        let resolvedConnector = connector ?? runtime!.connector
        let resolvedCatalogStore = catalogStore ?? runtime?.catalogStore
        let initialTrack = catalog.tracks.first ?? Track(
            id: "placeholder", serverID: "local",
            albumID: "placeholder", artistID: "placeholder",
            title: "请先连接服务器", artistName: "", albumTitle: "", duration: 0
        )
        self.playbackStore = PlaybackStore(currentTrack: initialTrack)
        self.homeStore = HomeStore(defaults: defaults)
        self.libraryStore = LibraryStore(catalog: catalog)
        self.serverStore = ServerStore()
        self.downloadStore = DownloadStore(connector: resolvedConnector, cacheStore: cacheStore)
        self.engine = engine
        self.connector = resolvedConnector
        self.runtimeCatalogStore = resolvedCatalogStore
        self.catalogFallbackUsed = runtime?.catalogFallbackUsed ?? false
        self.cacheStore = cacheStore
        self.artworkCache = artworkCache
        self.artworkStore = ArtworkStore(
            connector: resolvedConnector,
            diskCache: artworkCache,
            initialServerID: catalog.activeServerID?.rawValue ?? catalog.tracks.first?.serverID.rawValue
        )
        self.lyricsCache = lyricsCache
        self.defaults = defaults
        self.storeURL = storeURL
        let storedRate = defaults.object(forKey: Self.playbackRateDefaultsKey) as? Double
        self.playbackRate = Float(min(max(storedRate ?? 1.0, 0.5), 2.0))
        let storedVolume = defaults.object(forKey: Self.volumeDefaultsKey) as? Double
        self.volume = Float(storedVolume ?? 0.8)
        let storedReplayGainMode = ReplayGainMode(
            rawValue: defaults.string(forKey: Self.replayGainModeDefaultsKey) ?? ""
        ) ?? .off
        let storedPreamp = defaults.object(forKey: Self.replayGainPreampDefaultsKey) as? Double ?? 0
        let storedPeakProtection = defaults.object(forKey: Self.replayGainPeakProtectionDefaultsKey) as? Bool ?? true
        self.replayGainSettings = ReplayGainSettings(
            mode: storedReplayGainMode,
            preampDB: storedPreamp,
            peakProtection: storedPeakProtection
        )
        let storedCounts = defaults.dictionary(forKey: Self.playCountsDefaultsKey) as? [String: Int] ?? [:]
        self.lastStopReason = PlaybackStopReason(
            rawValue: defaults.string(forKey: Self.lastStopReasonDefaultsKey) ?? ""
        ) ?? .unknown
        self.recentSearches = defaults.array(forKey: Self.recentSearchesDefaultsKey) as? [String] ?? []
        self.repeatMode = RepeatMode(rawValue: defaults.string(forKey: Self.repeatModeDefaultsKey) ?? "") ?? .off
        self.isShuffled = defaults.bool(forKey: Self.shuffleDefaultsKey)
        // 最近播放按「serverID:trackID」组合键存储；旧格式（纯 trackID，无冒号）无法归属服务器，直接丢弃。
        let storedRecent = defaults.array(forKey: Self.recentlyPlayedDefaultsKey) as? [String] ?? []
        let legacyHistoryServerID = defaults.string(forKey: Self.lastActiveServerKey).map(ServerID.init(rawValue:))
        self.playbackHistoryStore = PlaybackHistoryStore(
            counts: storedCounts,
            recentKeys: storedRecent,
            legacyServerID: legacyHistoryServerID
        )
        let storedAdded = defaults.dictionary(forKey: Self.libraryAddedDefaultsKey) as? [String: Double] ?? [:]
        let legacyAddedServerID = legacyHistoryServerID
        self.libraryAddedTracker = LibraryAddedTracker(stored: storedAdded, legacyServerID: legacyAddedServerID)
        self.artworkStore.onArtworkLoaded = { [weak self] key, data in
            guard let self, key == self.currentTrack.artworkKey else { return }
            self.mediaIntegration.artworkLoaded(
                data,
                position: self.playbackPosition,
                isPlaying: self.playbackState == .playing
            )
        }

        // 安装崩溃日志处理器（仅首次）
        CrashLog.shared.installHandlers()
        let activity = NSUserActivity(activityType: Self.handoffActivityType)
        activity.title = "Auralis 播放"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.requiredUserInfoKeys = ["serverID", "currentTrackID", "queueTrackIDs", "position"]
        handoffActivity = activity
        startMediaIntegration()
        // 兼容现有观察模型的视图：领域 Store 在变更前转发一次全局失效通知。
        // 新视图可以直接观察具体 Store，逐步缩小重绘范围；这里不复制任何状态。
        homeStore.objectWillChange
            .sink { [weak self] _ in self?.scheduleChildStoreInvalidation() }
            .store(in: &childStoreSubscriptions)
        libraryStore.objectWillChange
            .sink { [weak self] _ in self?.scheduleChildStoreInvalidation() }
            .store(in: &childStoreSubscriptions)
        serverStore.objectWillChange
            .sink { [weak self] _ in self?.scheduleChildStoreInvalidation() }
            .store(in: &childStoreSubscriptions)
        downloadStore.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleChildStoreInvalidation()
            }
            .store(in: &childStoreSubscriptions)

        // 下载地址用活动连接器获取；等待期间服务器切换时按此判断放弃（P1-2）。
        self.downloadStore.serverIDProvider = { [weak self] in self?.catalog.activeServerID }
        Task { [self] in
            await engine.setVolume(volume)
            await engine.setRate(playbackRate)
            await engine.configureReplayGain(replayGainSettings)
            await engine.setTrackEndedHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleTrackEnded()
                }
            }
            // 播放中途失败（流地址失效 / 解码失败 / 网络错误）：
            // 刷新流地址重试；重试耗尽后自动下一首或提示。
            await engine.setPlaybackFailureHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleStreamFailure()
                }
            }
            await engine.setPreparedTrackStartedHandler { [weak self] track in
                Task { @MainActor [weak self] in
                    self?.handlePreparedTrackStarted(track)
                }
            }
            if let serverID = catalog.activeServerID {
                await cacheStore.migrateLegacyEntries(to: serverID)
                await lyricsCache.migrateLegacyEntries(to: serverID)
                // R09：旧版有损文件名（safeEncode 碰撞）迁移到无损 percent-encoding 文件名。
                await lyricsCache.migrateLegacyFilenames(to: serverID)
            }
            await downloadStore.restoreCachedIDs()
        }
        StartupPerformanceTrace.record(.appModelInit, since: appModelInitStartedAt)
    }

    /// 确保音频会话保持激活（进入后台/返回前台/输出设备切换时调用，防后台停止）。
    public func keepAudioSessionActive() async {
        await mediaIntegration.audioSession.activate()
    }

    // MARK: - 灵动岛（Live Activity）

    // MARK: - 睡眠定时

    /// 设置睡眠定时。mode=off 取消；afterMinutes 立即开始倒计时；
    /// afterCurrentTrack/Album/Queue 在当前歌曲/专辑/队列结束时停止（不自动出声恢复）。
    public func setSleepTimer(mode: SleepTimerMode, minutes: TimeInterval = 30) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMode = mode
        sleepTimerEndsAt = nil
        guard mode != .off else {
            schedulePreparedNext()
            return
        }
        if mode == .afterMinutes {
            let duration = max(minutes, 0.1)
            sleepTimerEndsAt = Date().addingTimeInterval(duration * 60)
            sleepTimerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration * 60))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.stopForSleepTimer(reason: .userStopped) }
            }
        }
        schedulePreparedNext()
    }

    /// 取消睡眠定时。
    public func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMode = .off
        sleepTimerEndsAt = nil
        schedulePreparedNext()
    }

    /// 当前睡眠定时的剩余描述（用于 Agent / UI 展示）。
    public func sleepTimerStatus() -> (mode: SleepTimerMode, remaining: TimeInterval) {
        if let endsAt = sleepTimerEndsAt {
            return (sleepTimerMode, max(endsAt.timeIntervalSinceNow, 0))
        }
        return (sleepTimerMode, 0)
    }

    /// 曲目自然结束时由 handleTrackEnded 调用：按睡眠模式决定「继续切歌」还是「停止」。
    /// 返回 true 表示已处理（停止），调用方不再继续切歌。
    private func applySleepTimerAtTrackEnd() -> Bool {
        switch sleepTimerMode {
        case .off:
            return false
        case .afterMinutes:
            return false
        case .afterCurrentTrack:
            stopForSleepTimer(reason: .userStopped)
            return true
        case .afterCurrentAlbum:
            if let index = currentQueueIndex,
               let next = queueStore.track(at: index + 1),
               next.albumID == currentTrack.albumID {
                return false
            }
            stopForSleepTimer(reason: .queueEnded)
            return true
        case .afterCurrentQueue:
            if hasNext {
                return false
            }
            stopForSleepTimer(reason: .queueEnded)
            return true
        }
    }

    private func stopForSleepTimer(reason: PlaybackStopReason) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMode = .off
        sleepTimerEndsAt = nil
        lastStopReason = reason
        playbackPosition = 0
        playbackTask?.cancel()
        Task { @MainActor in
            await self.engine.stop()
            self.playbackState = await self.engine.state()
            self.syncProgressTimer()
            self.mediaIntegration.stop()
            self.schedulePlaybackSessionPersistence()
        }
    }

    // MARK: - System media integration

    /// 注册远程命令回调：控制中心、锁屏、耳机线控、媒体键都从这里进来。
    private func startMediaIntegration() {
        mediaIntegration.start(
            handlers: RemoteCommandHandlers(
                onPlay: { [weak self] in self?.resumePlayback() },
                onPause: { [weak self] in self?.pausePlayback() },
                onToggle: { [weak self] in self?.togglePlayback() },
                onPrevious: { [weak self] in self?.previous() },
                onNext: { [weak self] in self?.next() },
                onSeek: { [weak self] position in
                    guard let self, self.effectivePlaybackDuration > 0 else { return }
                    self.seek(toProgress: position / self.effectivePlaybackDuration)
                },
                onShuffle: { [weak self] enabled in self?.setShuffle(enabled) },
                onRepeatMode: { [weak self] mode in self?.setRepeatMode(mode) }
            ),
            // 区分「系统中断暂停」与「用户暂停 / 设备断开」，用于正确记录停止原因。
            onInterruptionBegan: { [weak self] in self?.pausePlayback(reason: .audioSessionInterrupted) },
            onInterruptionShouldResume: { [weak self] in self?.resumePlayback() },
            onOutputDetached: { [weak self] in self?.pausePlayback(reason: .outputDisconnected) },
            onRouteChanged: { [weak self] in
                // 新设备（蓝牙/AirPlay/有线）接入后重新激活会话，确保后台持续输出。
                Task { @MainActor in await self?.keepAudioSessionActive() }
            }
        )
        mediaIntegration.modeChanged(isShuffled: isShuffled, repeatMode: repeatMode)
    }

    // MARK: - Siri / URL Scheme 播放请求

    /// 处理来自 `auralis://play?q=<名称>` URL Scheme 的播放请求。
    /// 资料库未恢复时先触发恢复，恢复完成后由 apply() 末尾的 processSiriPlayRequest() 消费。
    public func handleIncomingURL(_ url: URL) {
        guard url.scheme == "auralis", url.host == "play" else { return }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value?
            .removingPercentEncoding
        let query = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pendingSiriQuery = query.isEmpty ? nil : query
        Task { [weak self] in
            await self?.restorePersistedLibrary()
            self?.processSiriPlayRequest()
        }
    }

    /// 处理 Siri 经 continueUserActivity 交还的 INPlayMediaIntent（播放某首歌 / 播放音乐）。
    public func handleSiriUserActivity(_ userActivity: NSUserActivity) {
        #if os(iOS)
        var title: String
        if let intent = userActivity.interaction?.intent as? INPlayMediaIntent,
           let item = intent.mediaItems?.first {
            // Intents 扩展已从共享资料库解析出精确媒体项：identifier 形如「服务器ID:歌曲ID」。
            if let identifier = item.identifier, let gid = GlobalID(identifier) {
                pendingSiriGlobalID = gid
                pendingSiriQuery = nil
            } else {
                title = item.title ?? item.identifier ?? ""
                let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSiriQuery = query.isEmpty ? nil : query
                pendingSiriGlobalID = nil
            }
        } else {
            title = userActivity.title ?? ""
            let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSiriQuery = query.isEmpty ? nil : query
            pendingSiriGlobalID = nil
        }
        #else
        let query = (userActivity.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSiriQuery = query.isEmpty ? nil : query
        pendingSiriGlobalID = nil
        #endif
        Task { [weak self] in
            await self?.restorePersistedLibrary()
            self?.processSiriPlayRequest()
        }
    }

    /// 处理 Spotlight 搜索结果打开：`auralis://track|album|artist|playlist/<serverID>:<id>`。
    public func handleSpotlightIdentifier(_ identifier: String) {
        guard let components = URLComponents(string: identifier),
              components.scheme == "auralis", let host = components.host
        else { return }
        let ref = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let gid = GlobalID(ref) else { return }
        switch host {
        case "track":
            if let track = catalog.tracks.first(where: { $0.id.rawValue == gid.remoteID && $0.serverID == gid.serverID }) {
                selectAndPlay(track)
            }
        case "album":
            if let album = catalog.albums.first(where: { $0.id.rawValue == gid.remoteID && $0.serverID == gid.serverID }) {
                browseDestination = .album(album)
            }
        case "artist":
            if let artist = catalog.artists.first(where: { $0.id.rawValue == gid.remoteID && $0.serverID == gid.serverID }) {
                browseDestination = .artist(artist)
            }
        case "playlist":
            if let playlist = catalog.playlists.first(where: { $0.id.rawValue == gid.remoteID && $0.serverID == gid.serverID }) {
                browseDestination = .playlist(playlist)
            }
        default:
            break
        }
    }

    /// 执行待处理的 Siri 播放请求。资料库为空（未连接服务器）时静默放弃。
    /// 优先使用本地持久化资料库匹配；唯一匹配直接播放，多匹配按类型与文本相似度选择最接近的。
    public func processSiriPlayRequest() {
        // 优先精确 GlobalID（来自共享资料库的 Siri 媒体解析）。
        if let gid = pendingSiriGlobalID {
            pendingSiriGlobalID = nil
            guard !catalog.tracks.isEmpty else { return }
            if let track = catalog.tracks.first(where: {
                $0.id.rawValue == gid.remoteID && $0.serverID == gid.serverID
            }) {
                playTracks([track])
                return
            }
        }
        guard let query = pendingSiriQuery else { return }
        guard !catalog.tracks.isEmpty else { return }
        pendingSiriQuery = nil
        Task { @MainActor in
            await self.executeSiriIntent(query)
        }
    }

    /// Siri 意图的分类。
    private enum SiriControl: Sendable {
        case pause, resume, previous, next, toggleShuffle, toggleRepeat
    }

    /// 把语音请求解析为具体播放意图（中文语义优先，其次关键词）。
    private func parseSiriIntent(_ raw: String) -> SiriIntentKind {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        if query.isEmpty { return .playMusic }
        // 以下关键词是「代理内部固定的语音/命令匹配令牌」（中文源语言），用于把用户/语音原文
        // 映射到意图，不属于用户可见 UI 文案，不随界面语言翻译——否则英文环境下 Siri 匹配会失效。
        // i18n:ignore - 以下为 Siri/语音命令内部匹配令牌（中文源语言），不随界面语言翻译
        if lower.contains("暂停") { return .control(.pause) }
        if lower.contains("继续") { return .control(.resume) }
        if lower.contains("上一首") || lower.contains("上首") { return .control(.previous) }
        if lower.contains("下一首") || lower.contains("下首") { return .control(.next) }
        if lower.contains("切换随机") || (lower.contains("随机") && lower.contains("播放")) { return .control(.toggleShuffle) }
        if lower.contains("切换循环") || (lower.contains("循环") && lower.contains("播放")) { return .control(.toggleRepeat) }
        if lower.contains("收藏") { return .playFavorites }
        if lower.contains("最近") || lower.contains("听过") { return .playRecent }
        if lower.contains("随机") { return .playRandom }
        if lower.contains("流派") || lower.contains("风格") {
            let name = Self.extractName(query, markers: ["播放", "流派", "风格", "的", "音乐", "歌"])
            return .playGenre(name.isEmpty ? query : name)
        }
        if lower.contains("歌单") {
            let name = Self.extractName(query, markers: ["播放", "歌单", "的", "音乐"])
            return .playPlaylist(name.isEmpty ? query : name)
        }
        if lower.contains("专辑") {
            let name = Self.extractName(query, markers: ["播放", "专辑", "的", "音乐"])
            return .playAlbum(name.isEmpty ? query : name)
        }
        if lower.contains("的歌") || lower.contains("的歌曲") || lower.contains("歌手") {
            let name = Self.extractName(query, markers: ["播放", "的歌曲", "的歌", "歌手", "音乐"])
            return .playArtist(name.isEmpty ? query : name)
        }
        return .playSong(query)
    }

    private enum SiriIntentKind: Sendable {
        case playMusic
        case control(SiriControl)
        case playFavorites
        case playRecent
        case playRandom
        case playGenre(String)
        case playPlaylist(String)
        case playAlbum(String)
        case playArtist(String)
        case playSong(String)
    }

    /// 从语音串里提取目标名称：去掉语气/类型词。
    private static func extractName(_ query: String, markers: [String]) -> String {
        var value = query
        for marker in markers where !marker.isEmpty {
            value = value.replacingOccurrences(of: marker, with: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 执行解析后的 Siri 意图。所有分支都落到同一个播放服务（AppModel），
    /// 控制中心 / 锁屏 / 迷你播放条自动同步。
    func executeSiriIntent(_ raw: String) async {
        // 自动选歌前刷新 dislike 镜像：Siri/快捷指令必须遵循 Hard Exclusion。
        await refreshDislikedState()
        switch parseSiriIntent(raw) {
        case .playMusic:
            if playbackState == .playing { return }
            if currentTrack.id.rawValue != "placeholder" {
                togglePlayback()
            } else if let first = queueStore.firstTrack ?? autoCandidate(catalog.tracks).first {
                selectAndPlay(first)
            }
        case let .control(action):
            switch action {
            case .pause: pausePlayback()
            case .resume: resumePlayback()
            case .previous: previous()
            case .next: next()
            case .toggleShuffle: setShuffle(!isShuffled)
            case .toggleRepeat: setRepeatMode(repeatMode.next)
            }
        case .playFavorites:
            let favorites = favoriteTracks
            if favorites.isEmpty {
                let list = catalog.tracks.filter(\.isFavorite)
                playTracks(list.isEmpty ? autoCandidate(catalog.tracks).prefix(20).map { $0 } : list)
            } else {
                playTracks(favorites)
            }
        case .playRecent:
            let recent = recentlyPlayedTracks
            if recent.isEmpty {
                // 没有最近播放记录时退到收藏 / 随机，避免 Siri 报失败；自动兜底排除 disliked。
                let favorites = favoriteTracks
                playTracks(favorites.isEmpty ? autoCandidate(catalog.tracks).prefix(20).map { $0 } : favorites)
            } else {
                playTracks(recent)
            }
        case .playRandom:
            // 整库随机属于自动发现：排除 disliked。
            playTracks(autoCandidate(catalog.tracks).shuffled().prefix(30).map { $0 })
        case let .playGenre(name):
            let tracks = tracks(for: Genre(name: name, songCount: 0))
            if tracks.isEmpty {
                // 本地流派为空时按需从服务器拉取该流派歌曲。
                if let serverID = catalog.activeServerID,
                   let serverTracks = try? await connector.tracks(byGenre: name, serverID: serverID) {
                    playTracks(serverTracks)
                }
            } else {
                playTracks(tracks)
            }
        case let .playPlaylist(name):
            await playPlaylistNamed(name)
        case let .playAlbum(title):
            playAlbumTitled(title)
        case let .playArtist(name):
            playArtistNamed(name)
        case let .playSong(title):
            playSongMatching(title)
        }
    }

    /// 自动选歌候选：硬排除“不喜欢”（Siri 兜底 / 随机等自动发现路径专用；
    /// 用户明确指定歌曲/专辑/歌单/艺术家不经过这里）。
    private func autoCandidate(_ tracks: [Track]) -> [Track] {
        tracks.filter { !dislikedTrackIDs.contains(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)) }
    }

    /// 快捷指令 / Siri 通用播放入口：把用户语音/快捷指令文本交给统一的意图引擎执行，
    /// 保证所有入口（页面、控制中心、锁屏、Siri、快捷指令）操作同一个播放服务。
    public func handlePlaybackCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            await self.executeSiriIntent(trimmed)
        }
    }

    /// 所有入口（页面、控制中心、Siri）最终都经过这里与 selectAndPlay，状态天然一致。
    public func playTracks(_ tracks: [Track]) {
        let unique = uniquedTracks(tracks)
        guard !unique.isEmpty else { return }
        queue = unique
        selectAndPlay(unique[0])
    }

    /// 播放名为 name 的歌单：本地 trackIDs 优先，必要时按需拉取歌单详情。
    private func playPlaylistNamed(_ name: String) async {
        guard let playlist = catalog.playlists.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            ?? catalog.playlists.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
        else {
            playSongMatching(name)
            return
        }
        // 优先使用已缓存的歌单详情，其次用 catalog 内解析，最后按需拉取。
        var ids = playlist.trackIDs
        if ids.isEmpty, let loaded = playlistTracks[playlist.id] {
            ids = loaded.map(\.id)
        }
        if !ids.isEmpty {
            let tracks = ids.compactMap { id in catalog.tracks.first(where: { $0.id == id }) }
            if !tracks.isEmpty { playTracks(tracks); return }
        }
        // 歌单详情尚未加载：拉取后播放。
        // fetchPlaylistTracks 已改为 throws：拉取失败按空处理（与下方两处调用一致），不打断自然语言播放。
        let fetched = (try? await connector.fetchPlaylistTracks(serverID: playlist.serverID, playlistID: playlist.id)) ?? []
        playTracks(fetched)
    }

    /// 播放标题为 title 的专辑（该专辑全部曲目）。
    private func playAlbumTitled(_ title: String) {
        guard let album = catalog.albums.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame })
            ?? catalog.albums.first(where: { $0.title.localizedCaseInsensitiveContains(title) })
        else {
            playSongMatching(title)
            return
        }
        let tracks = catalog.tracks.filter { $0.albumID == album.id }
        if !tracks.isEmpty {
            playTracks(tracks)
        } else {
            playSongMatching(title)
        }
    }

    /// 播放名为 name 的艺术家（该艺术家全部曲目）。
    private func playArtistNamed(_ name: String) {
        let tracks = catalog.tracks.filter {
            $0.artistName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        if !tracks.isEmpty {
            playTracks(tracks)
        } else {
            let contains = catalog.tracks.filter { $0.artistName.localizedCaseInsensitiveContains(name) }
            if !contains.isEmpty {
                playTracks(contains)
            } else {
                playSongMatching(name)
            }
        }
    }

    /// 播放标题匹配的歌曲：精确 > 前缀 > 包含 > 歌手精确 > 歌手包含，取最接近的确定结果。
    private func playSongMatching(_ title: String) {
        let candidates = catalog.tracks
        if let exact = candidates.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            selectAndPlay(exact)
        } else if let prefix = candidates.first(where: { $0.title.lowercased().hasPrefix(title.lowercased()) }) {
            selectAndPlay(prefix)
        } else if let contains = candidates.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
            selectAndPlay(contains)
        } else if let artistExact = candidates.first(where: { $0.artistName.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            selectAndPlay(artistExact)
        } else if let artistContains = candidates.first(where: { $0.artistName.localizedCaseInsensitiveContains(title) }) {
            selectAndPlay(artistContains)
        } else {
            // 找不到明确匹配：不随意播放错误内容。
            return
        }
    }

    /// 当前曲目的封面数据（用于 Now Playing），未加载时为 nil。
    /// R01：按 currentTrack.serverID 取封面——播 A 浏览 B 时，Now Playing 必须拿 A
    /// 的封面（缓存键落在 A 命名空间），不能因为浏览服务器是 B 而串用 B 的同名封面。
    /// 已改为直接复用管线返回的原始 encodedData（JPEG/PNG），避免在双击热路径上
    /// 同步执行 NSImage → TIFF → PNG 的编解码；未命中则返回 nil，待
    /// artworkStore.onArtworkLoaded 异步补齐。
    private func currentArtworkData() -> Data? {
        guard let key = currentTrack.artworkKey else { return nil }
        return artworkStore.encodedData(remoteKey: key, serverID: currentTrack.serverID)
    }

    /// 切歌后同步 Now Playing 全量信息（含队列位置 / 总数，控制中心可显示）。
    private func syncNowPlayingTrack() {
        let queueIndex = currentQueueIndex
        mediaIntegration.trackChanged(
            currentTrack,
            position: playbackPosition,
            isPlaying: playbackState == .playing,
            artworkData: currentArtworkData(),
            queueIndex: queueIndex,
            queueCount: queueStore.count,
            rate: playbackState == .playing ? playbackRate : 0,
            duration: effectivePlaybackDuration
        )
        // 灵动岛 / 锁屏实时活动与「正在播放」小组件（P1-4）。
        let content = liveActivityContent()
        Task { await liveActivityManager.updatePlayback(content, reason: .trackChanged) }
        updateHandoffActivity()
    }

    /// 构建 Live Activity 展示内容（不含凭据/地址/路径）。
    /// R01：serverID 必须是「当前播放歌曲」的服务器，而不是当前浏览服务器——
    /// 播放 A 的歌、浏览 B 时，锁屏控件点封面要能回到 A。
    private func liveActivityContent() -> PlaybackActivityAttributes.ContentState {
        PlaybackActivityAttributes.ContentState(
            title: currentTrack.id.rawValue == "placeholder" ? "" : currentTrack.title,
            artist: currentTrack.artistName,
            album: currentTrack.albumTitle,
            artworkKey: currentTrack.artworkKey,
            serverID: currentTrack.serverID.rawValue,
            trackID: currentTrack.id.rawValue,
            duration: effectivePlaybackDuration,
            position: playbackPosition,
            isPlaying: playbackState == .playing
        )
    }

    /// 更新实时活动为当前状态（暂停/继续/停止时显式刷新）。
    private func syncLiveActivity() {
        if playbackState == .idle {
            Task { await liveActivityManager.endPlayback() }
        } else if case .failed = playbackState {
            Task { await liveActivityManager.endPlayback() }
        } else {
            let content = liveActivityContent()
            Task { await liveActivityManager.updatePlayback(content, reason: .playbackStateChanged) }
        }
    }

    /// 更新 Handoff 活动：把当前播放接力到其他设备（不自动出声，由接收端用户点击播放）。
    /// R01：serverID 记录「当前播放歌曲」的服务器，接收端据此在对应服务器曲库中恢复。
    private func updateHandoffActivity() {
        guard currentTrack.id.rawValue != "placeholder",
              let activity = handoffActivity
        else { return }
        activity.title = "\(currentTrack.title) · \(currentTrack.artistName)"
        activity.userInfo = [
            "serverID": currentTrack.serverID.rawValue,
            "currentTrackID": currentTrack.id.rawValue,
            "queueTrackIDs": queueStore.persistenceTrackIDs,
            "position": playbackPosition,
            // R05：记录当前队列项下标，接收端恢复重复歌曲时不丢失 occurrence。
            "currentQueueIndex": queueStore.currentIndex as Any,
        ]
        activity.becomeCurrent()
    }

    /// 处理来自其他设备的 Handoff 活动：恢复歌曲 / 队列 / 进度（不自动播放）。
    public func handleHandoffActivity(_ activity: NSUserActivity) {
        guard activity.activityType == Self.handoffActivityType,
              let info = activity.userInfo,
              let serverIDRaw = info["serverID"] as? String,
              catalog.activeServerID?.rawValue == serverIDRaw
        else { return }
        let trackByID = Dictionary(uniqueKeysWithValues: catalog.tracks.map { ($0.id.rawValue, $0) })
        var restoredQueue: [Track] = []
        // R05：Handoff 队列不去重——源设备 [A, B, A] 跨设备后必须仍是 [A, B, A]，
        // 重复歌曲是队列的合法状态（每次都是独立队列项）。
        // 同时做 source-index → restored-index 映射：接收端曲库可能缺失源队列中
        // 的某些项目（服务器删除/未同步），跳过后下标错位——用映射后的下标定位当前项。
        let handoffIndex = info["currentQueueIndex"] as? Int
        var restoredCurrentIndex: Int?
        if let ids = info["queueTrackIDs"] as? [String] {
            for (originalIndex, id) in ids.enumerated() {
                guard let track = trackByID[id] else { continue }
                if originalIndex == handoffIndex {
                    restoredCurrentIndex = restoredQueue.count
                }
                restoredQueue.append(track)
            }
        }
        guard !restoredQueue.isEmpty else { return }
        queue = restoredQueue
        // R05：优先用「映射后的」下标定位队列项（重复歌曲 [A,B,A] 恢复后仍指
        // 第二个 A，缺失项目导致的下标错位也被修正）；无下标或越界时回退按
        // currentTrackID 匹配第一个。
        if let restoredCurrentIndex,
           queueStore.entries.indices.contains(restoredCurrentIndex) {
            let entry = queueStore.entries[restoredCurrentIndex]
            _ = queueStore.play(entryID: entry.id)
            currentTrack = entry.track
        } else if let currentRaw = info["currentTrackID"] as? String, let current = trackByID[currentRaw] {
            if !queue.contains(where: { queueIdentity($0) == queueIdentity(current) }) { queue.insert(current, at: 0) }
            currentTrack = current
        } else {
            currentTrack = restoredQueue[0]
        }
        let position = (info["position"] as? Double) ?? 0
        // 不按 metadata 时长截断保存位置：metadata 可能比真实音频短，
        // 截断会把“已听到 243s”的会话退回 240s。真实时长由引擎解析后校正。
        playbackPosition = max(position, 0)
        playbackState = .idle
        loadLyricsIfNeeded(for: currentTrack)
        schedulePlaybackSessionPersistence()
    }

    public var currentLyrics: LyricsDocument? { lyrics(for: currentTrack) }

    public func lyrics(for track: Track) -> LyricsDocument? {
        catalog.lyrics[track.id]
    }

    /// 确保当前曲目歌词已按需加载（播放器/歌词面板打开时调用）。
    public func ensureLyricsLoadedForCurrentTrack() {
        loadLyricsIfNeeded(for: currentTrack)
    }

    /// 读取指定歌曲的歌词，供信息面板等非当前播放曲目使用；结果只属于传入的 GlobalID。
    /// R04：网络/认证/解析失败绝不写入「无歌词」负缓存——只有服务器明确确认无歌词
    /// 才标记 unavailable，避免 Wi-Fi 抖动一次就永久不再请求歌词。
    public func loadLyrics(for track: Track) async -> LyricsDocument? {
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        if let lyrics = lyrics(for: track) { return lyrics }
        if lyricsUnavailable.contains(globalID) { return nil }
        if let task = lyricsLoadTasks[globalID] {
            switch await task.value {
            case let .loaded(lyrics): return lyrics
            case .notFound, .failed: return nil
            }
        }

        lyricsInFlight.insert(globalID)
        let task = Task<LyricsLoadOutcome, Never> { [connector, lyricsCache] in
            if let cached = await lyricsCache.document(forServer: track.serverID, trackID: track.id) {
                return .loaded(cached)
            }
            if await lyricsCache.isKnownMissing(serverID: track.serverID, trackID: track.id) {
                return .notFound
            }
            // R01：歌词按 track.serverID 路由（fetchLyrics 内部用 clients[track.serverID]），
            // 与当前浏览服务器无关——播放 A 的歌、切到 B 浏览时，A 的歌词照常加载。
            // 磁盘缓存键也按 track.serverID 隔离，旧任务不会污染新服务器的键。
            // R04：用 throwing fetchLyrics 区分「失败」与「服务器无歌词」。
            let document: LyricsDocument?
            do {
                document = try await connector.fetchLyrics(for: track)
            } catch is CancellationError {
                return .failed
            } catch {
                AuralisLog.network.error("歌词拉取失败（不写负缓存）: \(error.localizedDescription)")
                return .failed
            }
            if let document {
                await lyricsCache.store(document, forServer: track.serverID, trackID: track.id)
                return .loaded(document)
            } else {
                // 只有这里（服务器明确返回无歌词）才写负缓存。
                await lyricsCache.markMissing(serverID: track.serverID, trackID: track.id)
                return .notFound
            }
        }
        lyricsLoadTasks[globalID] = task
        let outcome = await task.value
        lyricsLoadTasks[globalID] = nil
        lyricsInFlight.remove(globalID)

        switch outcome {
        case let .loaded(document):
            // catalog 当前仅展示活动服务器；切服后的旧任务不能回写到新服务器的 TrackID 键。
            if catalog.activeServerID == track.serverID {
                catalog.lyrics[track.id] = document
            }
            return document
        case .notFound:
            lyricsUnavailable.insert(globalID)
            Task.detached(priority: .utility) { [musicEnrichment] in
                _ = await musicEnrichment.prefetchForMissingLyrics(track: track)
            }
            return nil
        case .failed:
            // 失败不写 unavailable：保留「未知」状态，下次调用会重新请求。
            return nil
        }
    }

    /// Agent 歌词状态查询：区分“有歌词 / 已确认无歌词 / 尚未确认”，
    /// 不把“还没查”误报成“没有歌词”。
    func lyricsAvailability(for globalID: GlobalID) -> AgentLyricsState {
        if catalog.lyrics[TrackID(rawValue: globalID.remoteID)] != nil { return .available }
        if lyricsUnavailable.contains(globalID) { return .unavailable }
        return .unknown
    }

    /// 唯一时长事实源：优先引擎解析出的真实 item 时长；否则 metadata 时长。
    /// 两种情况下都保证分母不小于真实 position：
    /// - 真实时长已解析：返回 max(actualDuration, position)；
    /// - 真实时长尚未解析而 position 已超过 metadata（metadata 偏短的真实播放）：
    ///   动态扩容为 position + 1，进度条比例 < 1，不会“提前到头”；
    /// - metadata 缺失（0/未知）时以当前位置兜底并留 1 秒余量。
    public var effectivePlaybackDuration: TimeInterval {
        if let actualDuration, actualDuration.isFinite, actualDuration > 0 {
            return max(actualDuration, playbackPosition)
        }
        let metadata = max(currentTrack.duration, 0)
        if playbackPosition > metadata {
            return playbackPosition + 1
        }
        return metadata
    }

    /// 0...1 playback progress of the current track。
    public var playbackProgress: Double {
        get {
            let duration = effectivePlaybackDuration
            guard duration > 0 else { return 0 }
            return min(max(playbackPosition / duration, 0), 1)
        }
        set { seek(toProgress: newValue) }
    }

    /// 物理队列中是否存在相邻的下一首（不包含 shuffle / repeat 语义）。
    public var hasNext: Bool {
        guard let index = currentQueueIndex else { return false }
        return queueStore.track(at: index + 1) != nil
    }

    /// 用户当前是否可以执行“下一首”动作。
    /// 除物理相邻项外，shuffle 模式下 next() 会从队列随机选一首非当前曲目，
    /// 列表循环到队尾也能绕回第一首——这些都必须反映在 capability 里。
    public var canGoNext: Bool {
        guard hasCurrentTrack else { return false }
        if isShuffled {
            // 随机模式下以“本轮随机候选池”为准（物理相邻项不代表随机可继续）：
            // 随机 + 不循环：本轮随机已播完则不能再“下一首”；
            // 随机 + 列表循环：可以继续随机。
            guard queueStore.count > 1 else { return false }
            if repeatMode == .off, shuffleRemainingPool.isEmpty { return false }
            return true
        }
        if hasNext { return true }
        if repeatMode == .all && queueStore.count > 1 { return true }
        return false
    }

    /// 随机模式下尚未在本轮播放过的候选池（排除当前队列项与已随机播放过的队列项）。
    /// R05：按 entry UUID 判定——重复歌曲 A₁ 播过后 A₂ 仍是候选。
    private var shuffleRemainingPool: [Track] {
        let currentEntryID = queueStore.currentEntryID
        return queueStore.entries
            .filter { $0.id != currentEntryID && !shufflePlayedEntryIDs.contains($0.id) }
            .map(\.track)
    }

    /// 物理队列中是否存在相邻的上一首（不包含 repeat 语义）。
    public var hasPrevious: Bool {
        guard let index = currentQueueIndex else { return false }
        return queueStore.track(at: index - 1) != nil
    }

    /// 用户当前是否可以执行“上一首”动作：只要有正在播放的曲目，
    /// previous() 要么回本曲开头、要么去物理上一首、要么列表循环绕回队尾，总是可执行。
    public var canGoPrevious: Bool {
        hasCurrentTrack
    }

    /// 播放一组曲目（用于 macOS 表格「播放全部」等）。
    public func playQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        selectAndPlay(tracks[0])
    }

    /// 在指定上下文内播放某一首歌曲（macOS 表格双击等）。
    /// 原则：**当前歌曲立即播放**优先于「建立完整播放上下文」——
    /// 大 context（如全库 10000 首）先去重/准备放后台，不再同步阻塞双击事件；
    /// 后台准备完成后校验当前歌曲未变，再替换播放队列。
    public func playTrack(_ track: Track, in context: [Track]) {
        if context.isEmpty {
            selectAndPlay(track)
            return
        }
        let expectedID = queueIdentity(track)
        AuralisLog.playback.debug("PLAY_REQUEST_RECEIVED contextCount=\(context.count, privacy: .public)")
        // 1) 第一优先级：立即开始播放当前歌曲（UI 立即切换，engine 不等待大队列）。
        #if DEBUG
        let selectStarted = ContinuousClock.now
        #endif
        selectAndPlay(track, reconcileQueue: false)
        #if DEBUG
        let selectMs = durationMs(selectStarted.duration(to: .now))
        AuralisLog.playback.debug("PLAY_SELECT_DISPATCHED id=\(expectedID.description, privacy: .public) duration_ms=\(selectMs, privacy: .public)")
        #endif
        // 2) 后台一次性构建整个队列（去重 + QueueEntry + selected index + persistence IDs + 索引字典），
        //    MainActor 只安装结果，不再做 map / firstIndex / 生成 UUID / 构建 ID。
        let contextSnapshot = context
        Task { @MainActor [weak self] in
            guard let self else { return }
            let prepareStarted = ContinuousClock.now
            let prepared = await Task.detached(priority: .userInitiated) {
                PlaybackQueuePresentationStore.prepare(
                    tracks: contextSnapshot,
                    selectedTrackID: expectedID
                )
            }.value
            let prepareMs = durationMs(prepareStarted.duration(to: .now))
            AuralisLog.playback.debug("PLAY_CONTEXT_PREPARED count=\(prepared.entries.count, privacy: .public) duration_ms=\(prepareMs, privacy: .public)")
            // 快速连点 A→B→C：旧请求完成后若当前歌曲已变，丢弃，禁止旧队列覆盖新歌。
            guard queueIdentity(self.currentTrack) == expectedID else { return }
            let installStarted = ContinuousClock.now
            self.queueStore.installPreparedQueue(prepared)
            let installMs = durationMs(installStarted.duration(to: .now))
            AuralisLog.playback.debug("QUEUE_INSTALL_FINISHED count=\(prepared.entries.count, privacy: .public) revision=\(self.queueStore.revision, privacy: .public) duration_ms=\(installMs, privacy: .public)")
            self.schedulePlaybackSessionPersistence()
            self.schedulePreparedNext()
        }
    }

    /// 在用户明确选择的集合内随机播放（最近播放 / 最近添加 / 收藏等页面）。
    /// 只随机传入的集合，绝不回退到整库 discovery playRandom()。
    public func playShuffledQueue(_ tracks: [Track]) {
        playQueue(Array(tracks.shuffled()))
    }

    /// 随机播放（30 首）。整库随机属于自动发现：必须排除“不喜欢”的歌曲。
    public func playRandom() {
        let candidates = catalog.tracks.filter { !isDisliked($0) }
        let tracks = Array(candidates.shuffled().prefix(30))
        guard !tracks.isEmpty else { return }
        queue = tracks
        selectAndPlay(tracks[0])
    }

    /// GlobalID → 内存 catalog 中 Track 的统一解析：必须同时匹配 serverID 与 remoteID。
    /// 禁止 API 声明 GlobalID、内部却只按 remoteID（TrackID）查找导致跨服务器误匹配。
    public func track(for globalID: GlobalID) -> Track? {
        libraryStore.track(for: globalID)
    }

    private func queueIdentity(_ track: Track) -> GlobalID {
        GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    }

    /// ContinuousClock 耗时 → 毫秒（Double）。日志统一 `duration_ms=` 而非秒。
    private func durationMs(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }

    /// 把歌曲加入队列末尾（macOS 表格右键 / 双击等）。
    /// R05：允许同一首歌加入多次（每次独立队列项）。
    public func addToQueue(globalID: GlobalID) {
        guard let track = track(for: globalID) else { return }
        queueStore.append([track], currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
        schedulePreparedNext()
    }

    /// R05：追加单曲到队尾——queueStore.append 直调，**不重建 entry UUID**。
    /// 队列 [A, B, A, C] 当前播第二个 A 时，Agent/UI 追加 D，currentEntryID
    /// 不会被 queue setter 的 firstIndex 匹配漂回第一个 A；下一首仍是 C。
    public func appendToQueue(_ track: Track) {
        queueStore.append([track], currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
        schedulePreparedNext()
    }

    /// 下一首播放：插入到当前歌曲之后（新队列项；重复歌曲不被移除）。
    public func playNext(globalID: GlobalID) {
        guard let track = track(for: globalID) else { return }
        queueStore.playNext(track, currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
        schedulePreparedNext()
    }

    public func selectAndPlay(_ track: Track) {
        selectAndPlay(track, reconcileQueue: true)
    }

    private func selectAndPlay(_ track: Track, reconcileQueue: Bool) {
        CrashLog.shared.log("selectAndPlay 开始: \(track.title) (id=\(track.id.rawValue))")
        actualDuration = nil
        streamRetryAttempts.removeValue(forKey: queueIdentity(track))
        playbackHistoryStore.resetSelection()
        if reconcileQueue {
            currentTrack = track
        } else {
            // 上下文播放的 deferred 路径：新队列即将后台构建并整体安装，
            // 不在此扫描旧队列的 10000 首定位/插入，避免双击的 O(N) 热路径。
            setCurrentTrackWithoutQueueUpdate(track)
        }
        // 随机模式下记录“本轮已播放”：保证随机 + 不循环时每首只播一次，播完即停。
        // R05：按队列项 UUID 记录——重复歌曲是两个独立 occurrence，播过 A₁ 不误伤 A₂。
        // deferred 路径下当前 entry 尚未安装，暂缓记录。
        if reconcileQueue, isShuffled, let entryID = queueStore.currentEntryID {
            shufflePlayedEntryIDs.insert(entryID)
        }
        playbackPosition = 0
        if reconcileQueue {
            // 当前歌曲立即落进队列（避免旧逻辑的 queue getter 完整 map + contains）。
            // deferred 路径下新队列即将整体安装，不扫描/插入旧队列。
            let trackGID = queueIdentity(track)
            if !queueStore.contains(globalID: trackGID) {
                queueStore.insertAtFront(track, currentTrackID: trackGID)
            }
        }
        // 播放时自动缓存：当前歌曲的歌词 + 专辑封面（loadArtwork 在 UI 请求时落盘），
        // 并预缓存队列接下来几首的封面缩略图与歌词（写磁盘，不占内存）。
        loadLyricsIfNeeded(for: track)

        // ── 关键安全守卫 ──
        // 手势回调可能在 com.apple.uikit.eventdispatch 队列上执行。
        // AVPlayer / MPNowPlayingInfoCenter 等框架断言必须在主线程运行，
        // 因此后续媒体操作通过 Task { @MainActor in } 显式跳回主线程
        // （历史注释中的 DispatchQueue.main.async 现已由 Task @MainActor 替代）。
        //
        // 快速切歌时取消之前的播放任务，避免多个 engine.play() 并发导致竞态条件和卡死。
        playbackTask?.cancel()
        CrashLog.shared.log("取消之前的播放任务，创建新任务")
        playbackTask = Task { @MainActor in
            // 先立即同步控制中心 / 锁屏 / 灵动岛：即使歌曲还在缓冲，也先显示歌曲信息，
            // 避免「播放了但控制中心看不到」。播放成功后再刷新进度。
            self.syncNowPlayingTrack()

            // 已下载文件 → 现有 URL → 按需刷新，所有播放入口共用同一解析规则。
            guard var playable = await self.resolvePlayableTrack(track) else {
                self.playbackError = .engineFailure(String(localized: "无法取得可播放地址", bundle: .module))
                self.playbackState = .failed(.engineFailure(String(localized: "无法取得可播放地址", bundle: .module)))
                self.syncProgressTimer()
                return
            }
            // 只记录脱敏后的流地址（去掉查询串与主机信息，查询串含认证参数）。
            let safeURL = playable.streamURL.map { AVFoundationPlaybackEngine.redactedURL($0) } ?? "nil"
            CrashLog.shared.log("准备调用 engine.play，streamURL=\(safeURL)")
            do {
                try await self.engine.play(track: playable)
                self.playbackError = nil
                CrashLog.shared.log("engine.play 成功")
            } catch is CancellationError {
                // 被新的切歌取消，忽略
                CrashLog.shared.log("播放任务被取消 (CancellationError)")
                return
            } catch {
                // 自动兜底：本地记录的流地址缺失/失效时，先自动从服务器刷新流地址重播一次，
                // 仍失败再用服务器最新曲目（getSong + 补流地址）在线流播一次；
                // 都失败才弹出提示。避免「Agent 播放 → 弹『需要重试』→ 手动点重试才正常」。
                CrashLog.shared.log("engine.play 失败，尝试自动兜底: \(error)")
                var finalError: Error = error
                var autoSucceeded = false

                // 尝试 1：刷新流地址后重播。
                if self.catalog.activeServerID != nil,
                   let freshURL = await self.connector.refreshStreamURL(serverID: track.serverID, trackID: track.id) {
                    playable.streamURL = freshURL
                    do {
                        try await self.engine.play(track: playable)
                        self.playbackError = nil
                        CrashLog.shared.log("自动刷新流地址后播放成功")
                        autoSucceeded = true
                    } catch is CancellationError {
                        return
                    } catch {
                        finalError = error
                        CrashLog.shared.log("自动刷新流地址后仍失败: \(error)")
                    }
                }

                // 尝试 2：直接取服务器最新曲目（含新流地址）在线流播。
                if !autoSucceeded, self.catalog.activeServerID != nil,
                   let fresh = try? await self.connector.serverTrack(serverID: track.serverID, trackID: track.id) {
                    do {
                        try await self.engine.play(track: fresh)
                        self.playbackError = nil
                        CrashLog.shared.log("服务器在线曲目兜底播放成功")
                        autoSucceeded = true
                    } catch is CancellationError {
                        return
                    } catch {
                        finalError = error
                        CrashLog.shared.log("服务器在线曲目兜底仍失败: \(error)")
                    }
                }

                if !autoSucceeded {
                    self.playbackError = finalError as? PlaybackError
                    switch finalError as? PlaybackError {
                    case .networkUnavailable: self.lastStopReason = .networkInterrupted
                    case .unsupportedFormat: self.lastStopReason = .decodeFailed
                    case .authorizationFailed:
                        self.lastStopReason = .serverDisconnected
                        self.serverAuthenticationFailed = true
                    case .engineFailure: self.lastStopReason = .streamExpired
                    case nil: self.lastStopReason = .unknown
                    }
                }
            }
            self.playbackState = await self.engine.state()
            CrashLog.shared.log("播放状态: \(String(describing: self.playbackState))")
            self.syncProgressTimer()
            self.syncNowPlayingTrack()
            if self.playbackState == .playing || self.playbackState == .buffering {
                self.schedulePreparedNext()
            }
        }
    }

    // MARK: - Repeat / Shuffle / Volume

    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
    }

    /// 组合播放模式：单个按钮完整覆盖顺序、随机、列表循环与单曲循环。
    /// 旧实现把所有非关闭的 RepeatMode 都压成同一个 `.loop`，导致 `.one`
    /// 无法从播放界面进入，看起来就像循环按钮没有真正工作。
    public var playMode: PlayMode {
        if isShuffled { return .shuffle }
        switch repeatMode {
        case .off: return .list
        case .all: return .repeatAll
        case .one: return .repeatOne
        }
    }

    /// 切换播放模式：列表 → 随机 → 列表循环 → 单曲循环 → 列表。
    public func cyclePlayMode() {
        applyPlayMode(playMode.next())
    }

    private func applyPlayMode(_ mode: PlayMode) {
        switch mode {
        case .list:
            isShuffled = false
            repeatMode = .off
        case .shuffle:
            isShuffled = true
            repeatMode = .off
        case .repeatAll:
            isShuffled = false
            repeatMode = .all
        case .repeatOne:
            isShuffled = false
            repeatMode = .one
        }
    }

    public func setShuffle(_ enabled: Bool) {
        isShuffled = enabled
    }

    public func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        // 变化阈值：Slider 拖动/进度回调可能高频带几乎相同的值，
        // 值没实际变化时不 publish、不写 defaults、不创建引擎 Task。
        guard abs(clamped - volume) > 0.0005 else { return }
        volume = clamped
        defaults.set(Double(clamped), forKey: Self.volumeDefaultsKey)
        Task { [engine] in
            await engine.setVolume(clamped)
        }
    }

    public func setReplayGainMode(_ mode: ReplayGainMode) {
        var settings = replayGainSettings
        settings.mode = mode
        updateReplayGainSettings(settings)
    }

    public func setReplayGainPreamp(_ decibels: Double) {
        var settings = replayGainSettings
        settings.preampDB = min(max(decibels.isFinite ? decibels : 0, -12), 12)
        updateReplayGainSettings(settings)
    }

    public func setReplayGainPeakProtection(_ enabled: Bool) {
        var settings = replayGainSettings
        settings.peakProtection = enabled
        updateReplayGainSettings(settings)
    }

    private func updateReplayGainSettings(_ settings: ReplayGainSettings) {
        replayGainSettings = settings
        defaults.set(settings.mode.rawValue, forKey: Self.replayGainModeDefaultsKey)
        defaults.set(settings.preampDB, forKey: Self.replayGainPreampDefaultsKey)
        defaults.set(settings.peakProtection, forKey: Self.replayGainPeakProtectionDefaultsKey)
        Task { await engine.configureReplayGain(settings) }
    }

    /// 设置播放速度（0.5x–2.0x），同步控制中心速率与本地持久化。
    public func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 2.0)
        playbackRate = clamped
        defaults.set(Double(clamped), forKey: Self.playbackRateDefaultsKey)
        Task {
            await engine.setRate(clamped)
            mediaIntegration.playbackStateChanged(
                isPlaying: playbackState == .playing,
                position: playbackPosition,
                rate: playbackState == .playing ? clamped : 0
            )
        }
    }

    /// 重新随机抽取一批随机音乐，供首页「随机音乐」点开后的「换一批」使用。
    public func regenerateRandomMusic() {
        let tracks = catalog.tracks
        guard !tracks.isEmpty else { return }
        homeStore.regenerateRandom(from: tracks, dislikedTrackIDs: dislikedTrackIDs)
    }


    // MARK: - 首页布局偏好（可编辑首页）

    /// 开启 / 关闭某个首页模块。只改布局偏好，不删除任何数据 / 缓存 / 播放记录。
    /// 关闭的模块首页完全不渲染；「用户关闭」与「当前无数据」在渲染层区分：
    /// 这里只记录用户开关，数据为空时由 HomeView 暂不渲染但保持本配置开启。
    public func setHomeModuleVisible(_ moduleID: String, isVisible: Bool) {
        guard HomeModuleRegistry.module(forID: moduleID) != nil else { return }
        homeStore.setModuleVisible(moduleID, isVisible: isVisible)
    }

    /// 拖动排序：把分组内 fromOffsets 位置的模块移动到 toOffset。顺序立即生效并持久化。
    /// 语义与 SwiftUI List.onMove 的 Array.move(fromOffsets:toOffset:) 一致：
    /// 目标下标按「先移除再插入」调整，避免 onMove 与自实现位移不一致导致排序错乱。
    public func moveHomeModule(in group: HomeModuleGroup, fromOffsets: IndexSet, toOffset: Int) {
        homeStore.moveModule(in: group, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// 编辑页整组写回首页布局（本地数组为权威，排序与开关一次提交）。
    /// 编辑页的 List 以本地 @State 数组为数据源，拖动/开关后整组提交，
    /// 避免 onMove 期间增量写 @Published 与 SwiftUI 集合视图移动事务竞争导致的崩溃。
    public func replaceHomeLayout(quickEntries: [HomeModulePreference], contentModules: [HomeModulePreference]) {
        homeStore.replaceLayout(quickEntries: quickEntries, contentModules: contentModules)
    }

    /// 恢复默认布局：仅重置首页布局偏好（HomeLayoutStore 键），不删任何数据 / 缓存 / 播放记录。
    public func resetHomeLayout() {
        homeStore.resetLayout()
    }

    /// 重新采样「收藏里随便听」：只在本机收藏里本地随机，不发网络请求、不重新下载服务器资料。
    public func regenerateFavoriteRandomMusic() {
        homeStore.regenerateFavoriteRandom(from: catalog.tracks, dislikedTrackIDs: dislikedTrackIDs)
    }

    /// 清除播放错误（供 UI 在展示后调用）。
    /// 播放失败后重试：刷新流地址（若可用）并重新播放当前曲目。
    public func retryPlayback() {
        dismissPlaybackError()
        guard currentTrack.id.rawValue != "placeholder" else { return }
        Task { @MainActor in
            guard let track = await self.resolvePlayableTrack(self.currentTrack, forceRefresh: true) else {
                self.playbackError = .engineFailure(String(localized: "无法取得可播放地址", bundle: .module))
                return
            }
            self.selectAndPlay(track)
        }
    }

    /// 清除播放错误（供 UI 在展示后调用）。
    /// 注意：`.alert` 的 isPresented 绑定 setter（点外部 / 系统收起）与按钮动作会在
    /// SwiftUI 视图更新事务内同步执行，此时直接写 `@Published playbackError` 会触发
    /// "Publishing changes from within view updates is not allowed" 断言。
    /// 因此把写操作推迟到下一轮 RunLoop，待当前视图更新提交完成后再清除；
    /// alert 由绑定 getter（playbackError != nil）在下一帧自然收起，无可见差异。
    public func dismissPlaybackError() {
        Task { @MainActor in
            playbackError = nil
        }
    }

    // MARK: - AI 助手输入

    /// 发送助手草稿：清理首尾空白后交给 Agent，并清空草稿。
    /// 服务器在线搜索结果（本地无结果时使用）。
    @Published public private(set) var serverSearchResults: [Track] = []
    @Published public private(set) var isServerSearching = false

    /// 在服务器上在线搜索歌曲（search3）；本地离线搜索无结果时调用。
    public func searchOnServer(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isServerSearching else { return }
        guard let serverID = catalog.activeServerID else { return }
        isServerSearching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // R15：网络失败与“无结果”区分——失败保留旧结果并复位标志，不伪装成空结果。
            do {
                self.serverSearchResults = try await self.connector.serverSearch(query: trimmed, limit: 50, serverID: serverID)
            } catch {
                self.serverSearchResults = []
            }
            self.isServerSearching = false
        }
    }

    public func clearServerSearch() {
        serverSearchResults = []
        isServerSearching = false
    }

    /// 服务器在线搜索的可等待版本（Agent 工具用）：直接返回结果，不写 @Published 状态。
    /// 失败返回空数组（Agent 侧统一按“无结果”处理，不抛给工具调用）。
    public func searchOnServerAwaiting(query: String, limit: Int) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let serverID = catalog.activeServerID else { return [] }
        return (try? await connector.serverSearch(query: trimmed, limit: min(max(limit, 1), 100), serverID: serverID)) ?? []
    }

    /// 记录一条搜索历史（去重、最近在前、最多 10 条）。
    public func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recentSearches = list
        defaults.set(list, forKey: Self.recentSearchesDefaultsKey)
    }

    /// 清空搜索历史。
    public func clearSearchHistory() {
        recentSearches = []
        defaults.set([String](), forKey: Self.recentSearchesDefaultsKey)
    }

    public func sendAssistantMessage() {
        let text = assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        assistantDraft = ""
        agentCoordinator.send(text)
    }

    /// 一级分区切换（iPhone CompactShell 唯一入口，iPad 通过 selection onChange 复用同一
    /// 语义）：必须同时清掉浏览详情，否则 NavigationStack 的 navigationDestination(item:)
    /// 详情仍盖在新分区之上，表现为“歌单/收藏详情里点音乐库/AI 助手跳不过去”。
    /// 纯状态操作，可单测；UI 层（Dock 滚动复位等）由调用方负责。
    public func selectTopLevelSection(_ section: AppSection) {
        browseDestination = nil
        selectedSection = section
    }

    /// 测试钩子：确定性等待 apply() 排队的后台派生（首页货架 / 随机音乐 /
    /// library-added 对齐）完成。生产 UI 首帧不等待它（首屏只依赖 catalog 本身）。
    func awaitPendingApplyDerivations() async {
        await pendingApplyDerivations?.value
        pendingApplyDerivations = nil
    }

    /// 设置页的快捷入口：复用 Agent 已验证的“状态 → 分批分类 → 写回至 0”流程，
    /// 由 AgentRunner 的索引任务约束保证不会在中途把自然语言回复误报为完成。
    public func startOrContinueRecommendationIndexV2() {
        selectTopLevelSection(.assistant)
        agentCoordinator.send(
            "开始并一次性完成推荐索引 V2：先读取状态，持续分批分类并写回，直到待分类为 0。",
            intent: .libraryManagement
        )
    }

    /// 助手是否正在运行（输入框按钮在「发送 / 停止」之间切换）。
    public var assistantIsRunning: Bool { agentCoordinator.isRunning }

    /// 手动刷新曲库分类索引文件（同步完成后也会自动刷新）。
    public func refreshLibraryCatalogIndex() async {
        guard let serverID = catalog.activeServerID else { return }
        try? await libraryCatalogIndex.refresh(serverID: serverID, catalog: catalogCoordinator.store)
    }

    /// Siri / 快捷指令入口：把请求交给 App 内 AI 助手执行并等待结果（无界面模式）。
    /// 返回助手本轮最终文本回复；没有可用回复时返回空字符串。
    /// 会先确保本地资料库恢复完成，再交给 Agent 运行，避免冷启动时找不到曲目。
    @discardableResult
    public func askAssistant(_ text: String) async -> String {
        await restorePersistedLibrary()
        return await agentCoordinator.sendAndWait(text)
    }

    /// 停止助手当前任务。
    public func cancelAssistant() {
        agentCoordinator.cancel()
    }

    // MARK: - Play counts / collections

    private func recordPlaybackStarted(for track: Track) {
        guard track.id.rawValue != "placeholder" else { return }
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        let recentChanged = playbackHistoryStore.markStarted(globalID)
        let recentRaw = playbackHistoryStore.encodedRecentKeys
        let trackID = track.id.rawValue
        Task { @Sendable [defaults] in
            defaults.set(recentRaw, forKey: Self.recentlyPlayedDefaultsKey)
            defaults.set(trackID, forKey: Self.lastTrackKey(track.serverID))
        }
        if recentChanged {
            recentlyPlayedRevision &+= 1
            refreshHomeSnapshots()
        }
    }

    private func qualifyCurrentPlaybackIfNeeded(force: Bool = false) {
        let track = currentTrack
        guard track.id.rawValue != "placeholder" else { return }
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        guard playbackHistoryStore.qualifyIfNeeded(
            globalID: globalID,
            position: playbackPosition,
            duration: effectivePlaybackDuration,
            force: force
        ) else { return }
        libraryRowMetadataRevision &+= 1
        let storedCounts = playbackHistoryStore.encodedCounts
        Task { @Sendable [defaults, catalogStore = catalogCoordinator.store] in
            defaults.set(storedCounts, forKey: Self.playCountsDefaultsKey)
            try? await catalogStore.recordPlay(globalID, completed: false)
        }
        refreshHomeSnapshots()
    }

    // MARK: - Playback session persistence

    /// 播放会话持久化任务（debounce）：队列/进度变更不立即同步落盘，
    /// 350ms 合并 + utility 后台执行 JSON encode 与 UserDefaults 写入。
    /// 连续变更只保存最后一次；大队列（如 10000 首）不再阻塞双击事件同步链。
    private var playbackSessionPersistenceTask: Task<Void, Never>?

    private func schedulePlaybackSessionPersistence() {
        playbackSessionPersistenceTask?.cancel()
        guard let serverID = catalog.activeServerID else { return }
        let snapshot = PlaybackSessionSnapshot(
            currentTrackID: currentTrack.id.rawValue == "placeholder" ? nil : currentTrack.id.rawValue,
            queueTrackIDs: queueStore.persistenceTrackIDs,
            position: playbackPosition,
            // R05：记录当前队列项下标，重复歌曲恢复时不丢失 occurrence。
            currentQueueIndex: queueStore.currentIndex
        )
        let qCount = queueStore.count
        let qRevision = queueStore.revision
        AuralisLog.playback.debug("SESSION_SNAPSHOT_SCHEDULED queue_count=\(qCount, privacy: .public) revision=\(qRevision, privacy: .public) reuse_persistence_ids=true")
        let defaults = self.defaults
        let key = Self.playbackSessionKey(serverID)
        playbackSessionPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            // JSON encode 在 detached 后台做（只捕获 Sendable 快照）；
            // UserDefaults 写入回到 MainActor。
            let data = await Task.detached(priority: .utility) {
                try? JSONEncoder().encode(snapshot)
            }.value
            guard let data, !Task.isCancelled else { return }
            defaults.set(data, forKey: key)
        }
    }

    /// 从本地恢复上次播放会话（当前曲目、队列、进度）。返回是否成功恢复。
    /// 只恢复展示状态：playbackState 置为 .idle，不自动播放，由用户点击播放后从该进度继续。
    @discardableResult
    private func restorePlaybackSession(from tracks: [Track], serverID: ServerID) -> Bool {
        guard let data = defaults.data(forKey: Self.playbackSessionKey(serverID)),
              let snapshot = try? JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
        else { return false }
        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id.rawValue, $0) })
        var restoredQueue: [Track] = []
        // R05：会话恢复不去重——保存时队列可能含重复歌曲（每次独立队列项），
        // 恢复后必须保持原样 [A, B, A]，不能折叠成 [A, B]。
        // 同时做 source-index → restored-index 映射：保存的 currentQueueIndex 是
        // 源队列下标，恢复过程中被跳过的项目（服务器已删除）会让下标错位——
        // [A, X, A, C] 保存 index 2（第二个 A），X 缺失后恢复成 [A, A, C]，
        // 必须定位到新的 index 1，而不是原 index 2（那会是 C）。
        var restoredCurrentIndex: Int?
        for (originalIndex, id) in snapshot.queueTrackIDs.enumerated() {
            guard let track = trackByID[id] else { continue }
            if originalIndex == snapshot.currentQueueIndex {
                restoredCurrentIndex = restoredQueue.count
            }
            restoredQueue.append(track)
        }
        guard !restoredQueue.isEmpty else { return false }
        let current: Track
        if let currentID = snapshot.currentTrackID, let track = trackByID[currentID] {
            current = track
        } else {
            current = restoredQueue[0]
        }
        queue = restoredQueue
        // R05：优先用「映射后的」下标精确定位队列项——重复歌曲 [A, B, A, C] 保存时
        // 是 index 2 的 A，恢复后必须仍是第二个 A，next() 才正确走到 C。
        // 旧快照没有 currentQueueIndex 时回退按 currentTrackID 匹配第一个。
        if let restoredCurrentIndex,
           queueStore.entries.indices.contains(restoredCurrentIndex) {
            let entry = queueStore.entries[restoredCurrentIndex]
            _ = queueStore.play(entryID: entry.id)
            currentTrack = entry.track
        } else {
            if !queue.contains(where: { queueIdentity($0) == queueIdentity(current) }) { queue.insert(current, at: 0) }
            currentTrack = current
        }
        // 不按 metadata 时长截断保存位置：metadata 可能比真实音频短，
        // 截断会把“已听到 243s”的会话退回 240s。真实时长由引擎解析后校正。
        playbackPosition = max(snapshot.position, 0)
        playbackState = .idle
        loadLyricsIfNeeded(for: current)
        // 有持久化播放会话但此前没有显式停止记录 → 进程被系统终止（诊断用启发式）。
        if lastStopReason == .unknown {
            lastStopReason = .processTerminated
        }
        return true
    }

    /// 已收藏（喜爱）的歌曲。
    public var favoriteTracks: [Track] {
        catalog.tracks.filter(\.isFavorite)
    }

    /// 按本地播放次数降序的「最常听」。
    public var mostPlayedTracks: [Track] {
        // playCounts 是计算属性（每次访问都要从 playCountStorage 重建字典）；
        // 先取一次局部快照，避免 filter/sort 的每次比较都重建 → 从 O(n·m) 降到 O(n log n)。
        let counts = playCounts
        return catalog.tracks
            .filter { (counts[$0.id] ?? 0) > 0 }
            .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
    }

    /// 最近播放（曲目列表，最近在前）。
    public var recentlyPlayedTracks: [Track] {
        recentlyPlayedIDs.compactMap { id in catalog.tracks.first(where: { $0.id == id }) }
    }

    /// 最近添加（按首次进入本地目录的时间倒序）。服务端不提供「添加时间」时，
    /// 以本机首次见到该曲目的时间作为代理，新同步进来的曲目自然排在最前。
    /// 最近 N 天内添加的歌曲（按添加时间倒序）。
    public func recentlyAddedTracks(inLastDays days: Int) -> [Track] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return catalog.tracks
            .filter { libraryAddedTracker.date(for: $0).map { $0 >= cutoff } ?? false }
            .sorted { (libraryAddedTracker.date(for: $0) ?? .distantPast) > (libraryAddedTracker.date(for: $1) ?? .distantPast) }
    }

    public var recentlyAddedTracks: [Track] {
        return catalog.tracks.sorted {
            (libraryAddedTracker.date(for: $0) ?? .distantPast) > (libraryAddedTracker.date(for: $1) ?? .distantPast)
        }
    }

    private func reconcileLibraryAddedDates(tracks: [Track], serverID: ServerID) {
        guard libraryAddedTracker.reconcile(tracks: tracks, serverID: serverID) else { return }
        libraryRowMetadataRevision &+= 1
        let stored = libraryAddedTracker.encoded
        Task { @Sendable [defaults] in
            defaults.set(stored, forKey: Self.libraryAddedDefaultsKey)
        }
    }

    /// 刷新首页货架快照。保持与旧计算属性一致的过滤 / 排序语义。
    /// 只在数据真正变化时调用（资料库同步 / 播放记录 / 收藏切换 / 服务器收藏合并），
    /// 不在 body 里做任何 O(n) 计算，避免首页滚动卡顿与重复全表遍历。
    /// 各模块数据规则：
    /// - 很久没听：播放过（playCount>0）但不在最近播放历史里。当前只有播放次数与最近播放顺序、
    ///   没有「每首歌最后播放时间戳」，因此以「不在最近 100 次播放内」（recentlyPlayedIDs 上限 100）
    ///   作为「较久未播放」的产品定义；按播放次数降序展示（更常听但很久没听的最靠前）。
    /// - 从未播放：播放次数为 0 且不在播放历史（定义不依赖添加时间；展示排序用入库时间倒序，
    ///   让「最新入库但还没听过」的排前面）。
    /// - 最近添加：近 30 天真正新增的歌曲，标题显示「近30天新增 N 首」。
    /// - 收藏里随便听：从真实收藏随机采样 18 首，刷新时采样一次，换一批时重新采样（不发网络请求）。
    /// - 常听艺术家 / 常听专辑：按真实播放次数聚合统计，仅包含播放过的。
    private func refreshHomeSnapshots() {
        homeStore.refresh(
            catalog: catalog,
            playCounts: playCounts,
            recentIDs: recentlyPlayedIDs,
            addedDates: libraryAddedTracker.dates,
            dislikedTrackIDs: dislikedTrackIDs
        )
    }

    /// 按流派筛选：返回属于指定流派的曲目（名称大小写不敏感）。
    public func tracks(for genre: Genre) -> [Track] {
        let name = genre.name
        return catalog.tracks.filter { track in
            track.genres.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// 进入「流派」页时若本地流派为空，重新向服务器拉取一次（getGenres）。
    public func refreshGenres() {
        guard let serverID = catalog.activeServerID else { return }
        Task { [weak self, connector] in
            // R15：失败不伪装成“无流派”，仅保留本地已有流派。
            let serverGenres = (try? await connector.genres(serverID: serverID)) ?? []
            guard !serverGenres.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.mergeServerGenres(serverGenres)
            }
        }
    }

    /// 按流派从服务器加载歌曲（本地筛选为空时调用），结果写入 `genreTracks`。
    public func loadGenreTracks(_ genre: Genre) {
        guard loadingGenre?.name != genre.name else { return }
        guard let serverID = catalog.activeServerID else { return }
        loadingGenre = genre
        genreTracks = nil
        Task { [weak self] in
            guard let self else { return }
            let tracks = (try? await connector.tracks(byGenre: genre.name, serverID: serverID)) ?? []
            await MainActor.run { [weak self] in
                guard let self else { return }
                if loadingGenre?.name == genre.name {
                    genreTracks = tracks
                    loadingGenre = nil
                }
            }
        }
    }

    /// 保持顺序、按 GlobalID 去重。服务端偶发会对同一首歌返回重复条目，
    /// 若直接喂给 SwiftUI 的 ForEach / List，会因 duplicate ID 在运行期 fatal error 崩溃。
    /// 全链路（队列、随机货架、最近添加、流派筛选）统一在此收敛，避免重复 ID 进入界面。
    func uniquedTracks(_ tracks: [Track]) -> [Track] {
        CatalogEntityUniquing.uniquedTracks(tracks)
    }

    // MARK: - Downloads

    /// Track 的 TrackCacheStore 组合键（等价于 GlobalID.description）。
    private func cacheID(for track: Track) -> TrackCacheStore.TrackCacheID {
        TrackCacheStore.TrackCacheID(serverID: track.serverID, trackID: track.id)
    }

    /// 唯一的可播放曲目解析入口：本地下载优先，其次复用仍可用的 URL，最后只为
    /// 当前需要播放/预载的单曲向 connector 解析 URL。目录本身允许 streamURL 为 nil。
    private func resolvePlayableTrack(
        _ track: Track,
        forceRefresh: Bool = false
    ) async -> Track? {
        if let localURL = await cacheStore.cachedFileURL(for: cacheID(for: track)) {
            var playable = track
            playable.streamURL = localURL
            // 不记录本地文件路径（隐私：完整路径不得进日志/诊断）。
            CrashLog.shared.log("使用本地缓存播放")
            return playable
        }
        if !forceRefresh, track.streamURL != nil {
            return track
        }
        // 跨服务器安全（P0-1/P1-1）：非活动服务器的曲目不得用活动连接器刷新流地址，
        // 否则旧服务器的同 TrackID 会被解析成新服务器的音频。本地缓存与既有 URL 仍可用。
        guard track.serverID == catalog.activeServerID else {
            return track.streamURL == nil ? nil : track
        }
        if catalog.activeServerID != nil,
           let refreshedURL = await connector.refreshStreamURL(serverID: track.serverID, trackID: track.id) {
            var playable = track
            playable.streamURL = refreshedURL
            return playable
        }
        // 无活动服务器的测试/本地来源仍可继续使用已有 URL；forceRefresh 只要求
        // 服务器曲目刷新，不能让本地独立 URL 因没有服务器而失效。
        return track.streamURL == nil ? nil : track
    }

    /// 已下载到本地的曲目（首页「下载」快捷入口与下载浏览页的数据源）。
    public var downloadedTracks: [Track] {
        catalog.tracks.filter { downloadStore.isDownloaded($0) }
    }

    public func isDownloaded(_ track: Track) -> Bool { downloadStore.isDownloaded(track) }

    /// 当前本地缓存中的全部曲目 ID（供缓存维护 / 陈旧缓存检测）。
    public func allCachedTrackIDs() async -> Set<GlobalID> {
        await downloadStore.allCachedTrackIDs()
    }
    public func isDownloading(_ track: Track) -> Bool { downloadStore.isDownloading(track) }

    public func downloadInfo(for track: Track) -> DownloadTaskInfo? {
        downloadStore.info(for: track)
    }

    public func downloadedEntry(for track: Track) -> TrackCacheStore.CachedTrackEntry? {
        downloadStore.cachedEntry(for: track)
    }

    public var activeDownloadTracks: [Track] {
        catalog.tracks.filter {
            guard let status = downloadStore.info(for: $0)?.status else { return false }
            return status == .queued || status == .downloading
        }
    }

    public var failedDownloadTracks: [Track] {
        catalog.tracks.filter { downloadStore.info(for: $0)?.status == .failed }
    }

    /// 下载歌曲到本地缓存；完成后该歌曲优先本地播放。
    public func download(_ track: Track) {
        downloadStore.download(track)
    }

    /// 后台下载会话事件转发（系统在后台恢复下载后调用）。
    public func handleBackgroundDownloadEvents(identifier: String, completion: @escaping () -> Void) {
        // delegate 队列是主队列，completion 在 urlSessionDidFinishEvents 时直接调用。
        downloadStore.handleBackgroundEvents(identifier: identifier, completion: completion)
    }

    /// 取消正在进行的下载。
    public func cancelDownload(_ track: Track) {
        downloadStore.cancel(track)
    }

    public func retryDownload(_ track: Track) {
        downloadStore.retry(track)
    }

    public func cancelAllDownloads() {
        downloadStore.cancelAll()
    }

    public func clearDownloadOperationError() {
        downloadStore.clearOperationError()
    }

    /// 删除本地缓存文件。
    /// 批量下载：跳过已下载 / 正在下载的曲目。用于专辑 / 歌单 / 艺术家整批离线。
    public func downloadAll(_ tracks: [Track]) {
        for track in tracks {
            if !isDownloaded(track), !isDownloading(track) {
                download(track)
            }
        }
    }

    public func removeDownload(_ track: Track) {
        Task { await downloadStore.remove(track) }
    }

    public func removeAllDownloads() async {
        await downloadStore.removeAll()
    }

    // MARK: - Playlists

    /// 把歌曲追加到服务器歌单，成功后同步更新本地歌单缓存。
    @discardableResult
    public func addToPlaylist(_ playlist: Playlist, track: Track) async -> Bool {
        // R06：readonly 歌单禁止修改（服务器权威，UI 也应隐藏编辑入口）。
        guard !playlist.isReadOnly else { return false }
        let succeeded = await connector.addToPlaylist(serverID: playlist.serverID, playlistID: playlist.id, trackID: track.id)
        if succeeded,
           let index = catalog.playlists.firstIndex(where: { $0.id == playlist.id }),
           !catalog.playlists[index].trackIDs.contains(track.id) {
            catalog.playlists[index].trackIDs.append(track.id)
            catalog.playlists[index].modifiedAt = Date()
        }
        // 曲目关系写回 SQLite，保证 Agent/UI 的 getPlaylist 看到最新顺序。
        if let serverID = catalog.activeServerID {
            persistServerPlaylists(catalog.playlists, serverID: serverID)
        }
        return succeeded
    }

    /// 新建歌单（服务器侧创建，成功后写入本地 catalog）。
    @discardableResult
    public func createPlaylist(named name: String, trackIDs: [TrackID] = []) async -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let serverID = catalog.activeServerID else { return nil }
        guard let playlist = await connector.createPlaylist(serverID: serverID, name: trimmed, trackIDs: trackIDs) else { return nil }
        if let index = catalog.playlists.firstIndex(where: { $0.id == playlist.id }) {
            catalog.playlists[index] = playlist
        } else {
            catalog.playlists.append(playlist)
        }
        // 新歌单立即可见：写入 SQLite，后续「把歌曲加入这个歌单」才能解析到该歌单 ID。
        persistServerPlaylists(catalog.playlists, serverID: serverID)
        return playlist
    }

    /// 重命名歌单。
    @discardableResult
    public func renamePlaylist(id: PlaylistID, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let playlist = catalog.playlists.first(where: { $0.id == id }) else { return false }
        // R06：readonly 歌单禁止修改。
        guard !playlist.isReadOnly else { return false }
        let serverID = playlist.serverID
        let succeeded = await connector.renamePlaylist(serverID: serverID, playlistID: id, name: trimmed)
        if succeeded, let index = catalog.playlists.firstIndex(where: { $0.id == id }) {
            catalog.playlists[index].name = trimmed
            catalog.playlists[index].modifiedAt = Date()
            persistServerPlaylists(catalog.playlists, serverID: serverID)
        }
        return succeeded
    }

    /// 按下标批量移除歌单中的曲目（曲目本身仍留在音乐库）。
    @discardableResult
    public func removeFromPlaylist(id: PlaylistID, atIndices indices: [Int]) async -> Bool {
        guard !indices.isEmpty else { return false }
        guard let playlist = catalog.playlists.first(where: { $0.id == id }) else { return false }
        // R06：readonly 歌单禁止修改。
        guard !playlist.isReadOnly else { return false }
        let serverID = playlist.serverID
        let succeeded = await connector.removeFromPlaylist(serverID: serverID, playlistID: id, indices: indices)
        if succeeded {
            if let index = catalog.playlists.firstIndex(where: { $0.id == id }) {
                for offset in Set(indices).sorted(by: >)
                where catalog.playlists[index].trackIDs.indices.contains(offset) {
                    catalog.playlists[index].trackIDs.remove(at: offset)
                }
                catalog.playlists[index].modifiedAt = Date()
                if let serverID = catalog.activeServerID {
                    persistServerPlaylists(catalog.playlists, serverID: serverID)
                }
            }
            // 同步刷新歌单详情已加载的曲目缓存，让 UI（滑动删除）立即反映删除结果。
            if var loaded = playlistTracks[id] {
                for offset in Set(indices).sorted(by: >) where loaded.indices.contains(offset) {
                    loaded.remove(at: offset)
                }
                playlistTracks[id] = loaded
            }
        }
        return succeeded
    }

    /// 调整歌单内曲目顺序（R02：单请求整表替换，避免「清空→追加」的数据丢失窗口）。
    @discardableResult
    public func reorderPlaylist(id: PlaylistID, from: Int, to: Int) async -> Bool {
        guard let index = catalog.playlists.firstIndex(where: { $0.id == id }) else { return false }
        // R06：readonly 歌单禁止修改。
        guard !catalog.playlists[index].isReadOnly else { return false }
        let serverID = catalog.playlists[index].serverID
        var ids = catalog.playlists[index].trackIDs
        guard ids.indices.contains(from) else { return false }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: min(max(to, 0), ids.count))
        let succeeded = await connector.replacePlaylistTracks(serverID: serverID, playlistID: id, trackIDs: ids)
        if succeeded {
            catalog.playlists[index].trackIDs = ids
            catalog.playlists[index].modifiedAt = Date()
            persistServerPlaylists(catalog.playlists, serverID: serverID)
        }
        return succeeded
    }

    /// 删除歌单（破坏性操作，调用方必须已完成确认）。
    @discardableResult
    /// 复制歌单（副本命名「原名 副本」），逐首添加到服务器，失败返回 nil。
    public func duplicatePlaylist(id: PlaylistID) async -> Playlist? {
        guard let source = catalog.playlists.first(where: { $0.id == id }) else { return nil }
        // R06：readonly 歌单不可作为修改来源，但允许复制其内容为普通副本。
        guard let copy = await createPlaylist(named: "\(source.name) 副本") else { return nil }
        let ids = Set(source.trackIDs)
        for track in catalog.tracks where ids.contains(track.id) {
            _ = await addToPlaylist(copy, track: track)
        }
        return copy
    }

    public func deletePlaylist(id: PlaylistID) async -> Bool {
        playlistDeletionError = nil
        guard let playlist = catalog.playlists.first(where: { $0.id == id }) else {
            playlistDeletionError = String(localized: "无法定位歌单所属服务器。", bundle: .module)
            return false
        }
        // R06：readonly 歌单禁止删除。
        guard !playlist.isReadOnly else {
            playlistDeletionError = String(localized: "该歌单为只读歌单，无法删除。", bundle: .module)
            return false
        }
        let serverID = playlist.serverID
        let succeeded = await connector.deletePlaylist(serverID: serverID, playlistID: id)
        guard succeeded else {
            playlistDeletionError = String(localized: "服务器未确认删除。请检查网络与歌单权限后重试。", bundle: .module)
            return false
        }
        deletedPlaylistIDs.insert(id)
        catalog.playlists.removeAll { $0.id == id }
        playlistTracks.removeValue(forKey: id)
        playlistIDsNeedingContentRefresh.remove(id)
        if case let .playlist(shown) = browseDestination, shown.id == id {
            browseDestination = .playlists
        }
        if let serverID = catalog.activeServerID {
            let gid = GlobalID(serverID: serverID, remoteID: id.rawValue)
            try? await catalogCoordinator.store.deletePlaylist(gid)
        }
        return true
    }

    public func clearPlaylistDeletionError() {
        playlistDeletionError = nil
    }

    /// 按需从服务器拉取歌单内的完整曲目列表并缓存。
    /// getPlaylists（复数）只返回歌单元数据不含 entry，必须调 getPlaylist（单数）才有曲目。
    public func loadPlaylistTracks(playlistID: PlaylistID) {
        guard playlistTracks[playlistID] == nil,
              !loadingPlaylistIDs.contains(playlistID)
        else { return }
        // 歌单 ID 跨服务器可能重复：优先用本地歌单记录的 serverID，回退当前浏览服务器。
        let serverID = catalog.playlists.first(where: { $0.id == playlistID })?.serverID ?? catalog.activeServerID
        guard let serverID else { return }
        loadingPlaylistIDs.insert(playlistID)
        Task {
            let tracks = (try? await connector.fetchPlaylistTracks(serverID: serverID, playlistID: playlistID)) ?? []
            loadingPlaylistIDs.remove(playlistID)
            playlistTracks[playlistID] = tracks
            playlistIDsNeedingContentRefresh.remove(playlistID)
            // 同步更新 catalog 中歌单的 trackIDs
            if let index = catalog.playlists.firstIndex(where: { $0.id == playlistID }),
               !tracks.isEmpty {
                catalog.playlists[index].trackIDs = tracks.map(\.id)
                // 歌单详情拉取后写回 SQLite，让 Agent 的 getPlaylist / 播放歌单使用真实曲目顺序。
                persistServerPlaylists(catalog.playlists, serverID: serverID)
            }
        }
    }

    private var isCachingPlaylistContents = false

    /// 后台整体缓存歌单曲目（仅元数据）。
    /// 根因：getPlaylists（复数）只返回歌单壳、不含 entry，导致 Agent 的
    /// getPlaylist / playback_play_playlist 看到「空壳歌单」。
    /// 这里对每个「本地还没有曲目的歌单」调 getPlaylist（单数）拉全量曲目，
    /// 写回内存 catalog + SQLite（playlist_tracks），让 Agent 下次直接看到真实歌曲，
    /// 无需用户先打开歌单详情。除空壳歌单外，服务器 `changed` 更新过的歌单也会
    /// 刷新完整曲目列表，避免仅拿到名称与时间、却继续显示旧曲目顺序。
    public func cachePlaylistContentsInBackground() {
        guard !isCachingPlaylistContents else { return }
        let pending = catalog.playlists.filter {
            $0.trackIDs.isEmpty || playlistIDsNeedingContentRefresh.contains($0.id)
        }
        guard !pending.isEmpty else { return }
        isCachingPlaylistContents = true
        Task { @MainActor in
            defer { self.isCachingPlaylistContents = false }
            for playlist in pending {
                let tracks = (try? await self.connector.fetchPlaylistTracks(serverID: playlist.serverID, playlistID: playlist.id)) ?? []
                self.playlistTracks[playlist.id] = tracks
                if let index = self.catalog.playlists.firstIndex(where: { $0.id == playlist.id }) {
                    self.catalog.playlists[index].trackIDs = tracks.map(\.id)
                }
                let store = self.catalogCoordinator.store
                let gid = GlobalID(serverID: playlist.serverID, remoteID: playlist.id.rawValue)
                let trackGIDs = tracks.map { GlobalID(serverID: playlist.serverID, remoteID: $0.id.rawValue) }
                try? await store.setPlaylistTracks(gid, trackGIDs: trackGIDs)
                self.playlistIDsNeedingContentRefresh.remove(playlist.id)
            }
        }
    }

    // MARK: - Annotations

    /// 收藏 / 取消收藏专辑（服务器 star / unstar）。
    /// 专辑 / 艺术家收藏集合（按当前服务器，切换服务器时清空）。
    @Published public private(set) var favoriteAlbumIDs: Set<AlbumID> = []
    @Published public private(set) var favoriteArtistIDs: Set<ArtistID> = []
    private static func favoriteAlbumsKey(_ serverID: ServerID) -> String { "auralis.favAlbums.\(serverID.rawValue)" }
    private static func favoriteArtistsKey(_ serverID: ServerID) -> String { "auralis.favArtists.\(serverID.rawValue)" }

    public func isAlbumFavorite(_ album: Album) -> Bool { favoriteAlbumIDs.contains(album.id) }
    public func isArtistFavorite(_ artist: Artist) -> Bool { favoriteArtistIDs.contains(artist.id) }

    /// 切换专辑收藏（同步服务器 star/unstar）。
    public func toggleAlbumFavorite(_ album: Album) {
        let isFavorite = !favoriteAlbumIDs.contains(album.id)
        if isFavorite {
            favoriteAlbumIDs.insert(album.id)
        } else {
            favoriteAlbumIDs.remove(album.id)
        }
        if let serverID = catalog.activeServerID {
            defaults.set(Array(favoriteAlbumIDs.map(\.rawValue)), forKey: Self.favoriteAlbumsKey(serverID))
        }
        Task { await setAlbumFavorite(id: album.id, isFavorite: isFavorite) }
    }

    /// 切换艺术家收藏（同步服务器 star/unstar）。
    public func toggleArtistFavorite(_ artist: Artist) {
        let isFavorite = !favoriteArtistIDs.contains(artist.id)
        if isFavorite {
            favoriteArtistIDs.insert(artist.id)
        } else {
            favoriteArtistIDs.remove(artist.id)
        }
        if let serverID = catalog.activeServerID {
            defaults.set(Array(favoriteArtistIDs.map(\.rawValue)), forKey: Self.favoriteArtistsKey(serverID))
        }
        Task { await setArtistFavorite(id: artist.id, isFavorite: isFavorite) }
    }

    /// 去除歌单内重复曲目（保留首次出现），同步服务器。
    public func removeDuplicateSongs(from playlistID: PlaylistID) async {
        guard let playlist = catalog.playlists.first(where: { $0.id == playlistID }) else { return }
        var seen = Set<TrackID>()
        var duplicates: [Int] = []
        for (index, trackID) in playlist.trackIDs.enumerated() {
            if !seen.insert(trackID).inserted { duplicates.append(index) }
        }
        guard !duplicates.isEmpty else { return }
        _ = await removeFromPlaylist(id: playlistID, atIndices: duplicates)
    }

    public func setAlbumFavorite(id: AlbumID, isFavorite: Bool) async {
        // AlbumID 跨服务器可能重复：优先用本地专辑记录的 serverID，回退当前浏览服务器。
        let serverID = catalog.albums.first(where: { $0.id == id })?.serverID ?? catalog.activeServerID
        guard let serverID else { return }
        await connector.setAlbumFavorite(serverID: serverID, albumID: id, isFavorite: isFavorite)
    }

    /// 收藏 / 取消收藏艺术家。
    public func setArtistFavorite(id: ArtistID, isFavorite: Bool) async {
        // ArtistID 跨服务器可能重复：优先用本地艺术家记录的 serverID，回退当前浏览服务器。
        let serverID = catalog.artists.first(where: { $0.id == id })?.serverID ?? catalog.activeServerID
        guard let serverID else { return }
        await connector.setArtistFavorite(serverID: serverID, artistID: id, isFavorite: isFavorite)
    }

    /// 设置曲目评分，0 表示清除评分。
    /// 使用 GlobalID：只对活动服务器的曲目生效，避免旧服务器的同 TrackID 在切服后
    /// 被当前连接器误评分，或把 currentTrack 误更新成旧服务器曲目（RC §26）。
    public func setRating(globalID: GlobalID, rating: Int) async {
        let clamped = min(max(rating, 0), 5)
        guard globalID.serverID == catalog.activeServerID else { return }
        if let index = catalog.tracks.firstIndex(where: {
            $0.serverID == globalID.serverID && $0.id.rawValue == globalID.remoteID
        }) {
            catalog.tracks[index].rating = clamped == 0 ? nil : clamped
            if currentTrack.isSame(as: catalog.tracks[index]) { currentTrack = catalog.tracks[index] }
        }
        await connector.setRating(serverID: globalID.serverID, trackID: TrackID(rawValue: globalID.remoteID), rating: clamped)
    }

    // MARK: - Server lifecycle

    /// 探活当前服务器（用于设置页与 Agent 的连接自检）。
    public func testActiveServerConnection() async -> Bool {
        guard let serverID = catalog.activeServerID else { return false }
        return await connector.ping(serverID: serverID)
    }

    /// 切换活跃服务器：先记录目标服务器，再恢复其本地资料库（零网络出界面，
    /// 随后后台增量同步）。切换不会清空播放队列或停止当前音频会话之外的状态——
    /// apply() 对同库刷新保留播放上下文；跨服务器切换由 apply() 清理内存缓存。
    public func switchServer(serverID: ServerID) async {
        guard catalog.activeServerID != serverID else { return }
        defaults.set(serverID.rawValue, forKey: Self.lastActiveServerKey)
        attemptedRestore = false
        await restorePersistedLibrary()
    }

    /// 修改服务器显示名称（持久化到本地库与 SQLite 目录，不影响凭据 / 连接 / 资料库）。
    public func renameServer(serverID: ServerID, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let account = (try? await catalogCoordinator.store.listServers())?
            .first(where: { $0.id == serverID })
        else { return false }
        var updated = account
        updated.displayName = trimmed
        guard await connector.updateServerDisplayName(serverID: serverID, displayName: trimmed) else { return false }
        try? await catalogCoordinator.store.upsertServer(updated)
        if catalog.activeServerID == serverID {
            catalog = LibraryCatalog(
                account: updated,
                artists: catalog.artists,
                albums: catalog.albums,
                tracks: catalog.tracks,
                genres: catalog.genres,
                playlists: catalog.playlists,
                history: catalog.history,
                downloads: catalog.downloads,
                lyrics: catalog.lyrics,
                recommendations: catalog.recommendations
            )
        }
        return true
    }

    /// 只更新外网降级地址；内网主地址、服务器身份和 Keychain 凭据保持不变。
    public func updateServerExternalBaseURL(serverID: ServerID, to url: URL?) async -> Bool {
        guard let account = (try? await catalogCoordinator.store.listServers())?
            .first(where: { $0.id == serverID })
        else { return false }
        var updated = account
        updated.externalBaseURL = url
        guard await connector.updateServerExternalBaseURL(serverID: serverID, externalBaseURL: url) else { return false }
        try? await catalogCoordinator.store.upsertServer(updated)
        if catalog.activeServerID == serverID {
            catalog = LibraryCatalog(
                account: updated,
                artists: catalog.artists,
                albums: catalog.albums,
                tracks: catalog.tracks,
                genres: catalog.genres,
                playlists: catalog.playlists,
                history: catalog.history,
                downloads: catalog.downloads,
                lyrics: catalog.lyrics,
                recommendations: catalog.recommendations
            )
        }
        return true
    }

    public func updateServerConfiguration(serverID: ServerID, update: ServerConfigurationUpdate) async -> Bool {
        guard let updated = await connector.updateServerConfiguration(serverID: serverID, update: update) else { return false }
        try? await catalogCoordinator.store.upsertServer(updated)
        if catalog.activeServerID == serverID {
            catalog = LibraryCatalog(
                account: updated,
                artists: catalog.artists,
                albums: catalog.albums,
                tracks: catalog.tracks,
                genres: catalog.genres,
                playlists: catalog.playlists,
                history: catalog.history,
                downloads: catalog.downloads,
                lyrics: catalog.lyrics,
                recommendations: catalog.recommendations
            )
        }
        return true
    }

    /// 备份恢复：把服务器账号与登录凭据写回本地（不联网、不触发资料同步）。
    /// 仅登记账号信息，不会自动下载 / 同步音乐资料库。
    /// 关键写入失败必须抛出，禁止「界面显示恢复成功、实际凭据没写进去」（P2-4）。
    public func restoreServerAccountFromBackup(_ account: ServerAccount, secret: String?) async throws {
        try await connector.restoreAccountFromBackup(account, secret: secret)
    }

    /// 移除服务器：只清理本地凭据与本地数据，绝不向远端发送删除请求。
    public func removeServerLocally(serverID: ServerID) async {
        await connector.forgetServer(serverID: serverID)
        guard catalog.activeServerID == serverID else { return }
        Task { await liveActivityManager.endPlayback() }
        actualDuration = nil
        mediaIntegration.stop()
        catalog = .empty
        queue = []
        playbackPosition = 0
        artworkStore.setServerID(nil)
        artworkStore.reset()
        playlistTracks = [:]
        loadingPlaylistIDs = []
        playlistIDsNeedingContentRefresh = []
        lyricsInFlight = []
        lyricsUnavailable = []
        downloadStore.clearVisibleState()
        currentTrack = Track(
            id: "placeholder", serverID: "local",
            albumID: "placeholder", artistID: "placeholder",
            title: "请先连接服务器", artistName: "", albumTitle: "", duration: 0
        )
        serverConnectionState = .idle
        attemptedRestore = false
        shouldPresentServerSetup = true
        handoffActivity?.invalidate()
        SpotlightIndexer.clearAll()
        Task { await engine.stop() }
    }

    // MARK: - Lyrics

    /// 按需从服务器拉取歌词并写入 catalog，播放页与检查器会自动刷新。
    /// 拉取过（无论成败）的曲目不会重复请求。
    private func loadLyricsIfNeeded(for track: Track) {
        let globalID = queueIdentity(track)
        guard catalog.lyrics[track.id] == nil,
              !lyricsUnavailable.contains(globalID),
              !lyricsInFlight.contains(globalID)
        else { return }
        Task { [weak self] in
            _ = await self?.loadLyrics(for: track)
        }
    }

    // MARK: - Artwork

    /// 已缓存的封面图；未加载时返回 nil，视图应展示占位封面并调用 loadArtwork。
    /// R01：播放器/当前曲目场景必须显式传 serverID（currentTrack.serverID）——
    /// 浏览型调用（专辑页等）不传，按当前浏览服务器兜底。
    public func artworkImage(key: String?, targetPixelSize: Int, serverID: ServerID? = nil) -> PlatformImage? {
        artworkStore.image(remoteKey: key, targetPixelSize: targetPixelSize, serverID: serverID)
    }

    /// 兼容非 SwiftUI 调用者；磁盘、网络、请求去重与后台解码均由独立管线负责。
    public func loadArtwork(key: String?, targetPixelSize: Int) {
        Task { [artworkStore] in
            _ = await artworkStore.load(remoteKey: key, targetPixelSize: targetPixelSize)
        }
    }

    public func togglePlayback() {
        // 与 selectAndPlay 同理：按钮点击在 eventdispatch 队列上，
        // engine.play() / engine.pause() 内部触发 FIG/MediaRemote 断言，必须 defer 到主线程。
        DispatchQueue.main.async {
            Task { @MainActor in
                if self.playbackState == .playing {
                    self.lastStopReason = .userPaused
                    await self.engine.pause()
                } else if case .failed = self.playbackState {
                    // 失败态：重新起播（刷新流地址并重试），不要 resume——
                    // 对已失败的 AVPlayer resume 会静默无声（F16）。
                    self.retryPlayback()
                } else {
                    do {
                        if self.playbackState == .idle {
                            // 进程重启恢复后引擎没有加载曲目：直接从头播放并 seek 到保存的进度。
                            guard let playable = await self.resolvePlayableTrack(self.currentTrack) else {
                                throw PlaybackError.engineFailure(String(localized: "无法取得可播放地址", bundle: .module))
                            }
                            try await self.engine.play(track: playable)
                            if self.playbackPosition > 0 {
                                await self.engine.seek(to: self.playbackPosition)
                            }
                        } else {
                            try await self.engine.resume()
                        }
                    } catch {
                        self.playbackState = .failed(.engineFailure(error.localizedDescription))
                    }
                }
                self.playbackState = await self.engine.state()
                self.syncProgressTimer()
                self.schedulePlaybackSessionPersistence()
                self.mediaIntegration.playbackStateChanged(
                    isPlaying: self.playbackState == .playing,
                    position: self.playbackPosition,
                    rate: self.playbackState == .playing ? self.playbackRate : 0
                )
                self.syncLiveActivity()
            }
        }
    }

    /// 远程命令专用：仅在暂停时恢复。
    public func resumePlayback() {
        if playbackState != .playing { togglePlayback() }
    }

    /// 远程命令专用：仅在播放时暂停。reason 用于区分用户暂停 / 系统中断 / 设备断开。
    public func pausePlayback(reason: PlaybackStopReason = .userPaused) {
        lastStopReason = reason
        if playbackState == .playing { togglePlayback() }
    }

    /// 用户明确停止整个播放会话：停止引擎、清除系统正在播放信息、记录停止原因。
    /// 队列保留，用户可随时继续播放；系统信息只在此时清空（符合「仅用户主动停止才清空」）。
    public func stopPlayback() {
        guard currentTrack.id.rawValue != "placeholder" else { return }
        lastStopReason = .userStopped
        playbackPosition = 0
        playbackTask?.cancel()
        handoffActivity?.invalidate()
        schedulePlaybackSessionPersistence()
        Task { @MainActor in
            await self.engine.stop()
            self.playbackState = await self.engine.state()
            self.syncProgressTimer()
            self.mediaIntegration.stop()
        }
    }

    /// 向前跳转（默认 30 秒）。
    public func skipForward(seconds: TimeInterval = 30) {
        let duration = effectivePlaybackDuration
        let target = duration > 0 ? min(playbackPosition + seconds, duration) : playbackPosition + seconds
        seekToAbsolute(target)
    }

    /// 向后跳转（默认 15 秒）。
    public func skipBackward(seconds: TimeInterval = 15) {
        seekToAbsolute(max(playbackPosition - seconds, 0))
    }

    private func seekToAbsolute(_ position: TimeInterval) {
        playbackPosition = position
        schedulePlaybackSessionPersistence()
        let identity = queueIdentity(currentTrack)
        Task {
            // seek 竞态防护（P2-18）：执行前若已切歌则放弃旧 seek，避免落到新曲目。
            // 用 GlobalID 比较，切换服务器后同 TrackID 不会误通过。
            guard queueIdentity(self.currentTrack) == identity else { return }
            await engine.seek(to: position)
            mediaIntegration.seekCompleted(position: position, isPlaying: playbackState == .playing, rate: playbackState == .playing ? playbackRate : 0)
        }
    }

    public func next() {
        if isShuffled {
            playRandomFromQueue()
            return
        }
        // R05：队列推进用 queueStore.advanceForward()——currentIndex 是权威状态，
        // 绝不从歌曲 TrackID 反推：重复歌曲不会回退到第一个匹配，
        // 例如 [A, B, A, C] 播放第二个 A 时，next() 正确走到 C。
        if let next = queueStore.advanceForward() {
            selectAndPlay(next)
        } else if repeatMode == .all, queueStore.count > 1, let firstEntry = queueStore.entries.first {
            // 列表循环：到队尾绕回第一首（用队首 entry 定位，保持 index 语义）。
            _ = queueStore.play(entryID: firstEntry.id)
            selectAndPlay(firstEntry.track)
        }
    }

    /// 只随机尚未播放的剩余队列（当前曲目之后），保持已播放部分顺序不变。
    /// R05：在 entry 层面 shuffle（保留 UUID）——当前项身份不因重建而丢失，
    /// 重复歌曲播放第二个 A 时 currentIndex 不会漂移到第一个 A。
    public func shuffleRemainingInQueue() {
        guard let index = currentQueueIndex, queueStore.entries.indices.contains(index) else { return }
        let tailCount = queueStore.count - (index + 1)
        guard tailCount > 1 else { return }
        let entries = queueStore.entries
        let head = Array(entries.prefix(index + 1))
        let tail = Array(entries.suffix(tailCount)).shuffled()
        queueStore.replace(entries: head + tail, currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
    }

    /// 把当前播放队列保存为服务器歌单；失败返回 false。
    public func saveQueueAsPlaylist(named name: String) async -> Bool {
        guard !queueStore.isEmpty, let playlist = await createPlaylist(named: name) else { return false }
        for track in queue {
            _ = await addToPlaylist(playlist, track: track)
        }
        return true
    }

    /// 随机模式：从队列里随机挑一首尚未在本轮随机中播放过的非当前队列项。
    /// R05：随机池与「已播放」记录都用 QueueEntry（UUID）——重复歌曲是两个独立
    /// occurrence，选中 A₂ 就播 A₂（play(entryID:)），而不是只能表达「A」。
    /// 返回 false 表示本轮随机已播完（且不循环）或队列不足，由调用方决定暂停/重播。
    @discardableResult
    private func playRandomFromQueue() -> Bool {
        guard queueStore.entries.count > 1 else { return false }
        let currentEntryID = queueStore.currentEntryID
        var pool = queueStore.entries.filter {
            $0.id != currentEntryID && !shufflePlayedEntryIDs.contains($0.id)
        }
        if pool.isEmpty {
            if repeatMode == .all {
                // 列表循环 + 随机：一轮播完，重置后继续随机。
                shufflePlayedEntryIDs.removeAll()
                pool = queueStore.entries.filter { $0.id != currentEntryID }
            } else {
                // 随机 + 不循环：一轮播完即停（不把“随机”当成隐式循环）。
                return false
            }
        }
        guard let entry = pool.randomElement() else { return false }
        shufflePlayedEntryIDs.insert(entry.id)
        _ = queueStore.play(entryID: entry.id)
        selectAndPlay(entry.track)
        return true
    }

    /// 切换曲目的收藏状态，并同步到服务器（star/unstar）。
    public func toggleFavorite(_ track: Track) {
        Task { @MainActor [weak self] in
            await self?.toggleFavoritePersisted(track)
        }
    }

    /// 可等待的收藏切换（含与不喜欢的互斥）；测试直接调用以同步断言。
    func toggleFavoritePersisted(_ track: Track) async {
        // 收藏与不喜欢互斥：点击收藏时若歌曲处于“不喜欢”，先取消不喜欢再收藏。
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        if dislikedTrackIDs.contains(gid) {
            dislikedTrackIDs.remove(gid)
            dislikedRevision &+= 1
            try? await catalogCoordinator.store.setDisliked(gid, value: false, source: "user")
            refreshHomeSnapshots()
        }
        // 曲目可能不在本地目录（例如刚由「服务器在线流播」播放、尚未同步的歌曲）：
        // 先翻转本地副本，再同步到目录（若在）与服务器，保证播放页红心即时响应。
        var updated = track
        updated.isFavorite.toggle()
        if let index = catalog.tracks.firstIndex(where: { $0.id == track.id }) {
            catalog.tracks[index].isFavorite = updated.isFavorite
        }
        favoritesRevision &+= 1
        if currentTrack.isSame(as: track) { currentTrack = updated }
        refreshHomeSnapshots()
        await connector.setFavorite(serverID: updated.serverID, trackID: updated.id, isFavorite: updated.isFavorite)
    }

    /// 是否“不喜欢”：只影响自动推荐/发现；搜索、浏览与显式播放不受影响。
    public func isDisliked(_ track: Track) -> Bool {
        dislikedTrackIDs.contains(GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
    }

    /// 从 SQLite 权威状态刷新“不喜欢”内存镜像。
    /// 读取失败视为“权威数据暂不可用”：保留现有内存状态并记录错误，
    /// 绝不因为一次数据库读取失败就把用户的不喜欢列表清空（P1-4）。
    public func refreshDislikedState() async {
        guard let serverID = catalog.activeServerID else {
            dislikedTrackIDs = []
            dislikedStateServerID = nil
            dislikedRevision &+= 1
            return
        }
        let loaded = await loadDislikedTrackIDs(serverID: serverID)
        guard catalog.activeServerID == serverID else { return }
        if let loaded {
            dislikedTrackIDs = loaded
            dislikedStateServerID = serverID
            dislikedRevision &+= 1
        }
    }

    /// 读取指定服务器的不喜欢状态，不触碰当前内存镜像。
    private func loadDislikedTrackIDs(serverID: ServerID) async -> Set<GlobalID>? {
        do {
            return try await catalogCoordinator.store.dislikedTrackIDs(serverID: serverID)
        } catch {
            AuralisLog.library.error("读取 dislikedTrackIDs 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 设置/取消“不喜欢”。产品规则：
    /// - 设置不喜欢时若当前已收藏，先取消收藏（收藏与不喜欢互斥）；
    /// - 取消不喜欢不会恢复旧收藏；
    /// - 不改变当前播放、不改变队列、不跳歌、不删除任何内容。
    public func setDisliked(_ track: Track, value: Bool, source: String? = nil) {
        Task { @MainActor [weak self] in
            await self?.persistDisliked(track, value: value, source: source)
        }
    }

    public func toggleDisliked(_ track: Track) {
        setDisliked(track, value: !isDisliked(track), source: "user")
    }

    /// 可等待的 dislike 持久化（UI 通过 setDisliked 触发；测试直接调用以同步断言）。
    func persistDisliked(_ track: Track, value: Bool, source: String?) async {
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        dislikedStateServerID = track.serverID
        if value == dislikedTrackIDs.contains(gid) { return }
        if value {
            dislikedTrackIDs.insert(gid)
            if track.isFavorite {
                // 复用现有收藏取消实现，不重新实现一套 OpenSubsonic favorite API。
                await unfavoriteTrack(track)
            }
        } else {
            dislikedTrackIDs.remove(gid)
        }
        dislikedRevision &+= 1
        refreshHomeSnapshots()
        try? await catalogCoordinator.store.setDisliked(gid, value: value, source: source)
    }

    /// 取消收藏（供 dislike 互斥复用）。收藏状态本地与服务器同步。
    private func unfavoriteTrack(_ track: Track) async {
        var updated = track
        updated.isFavorite = false
        favoritesRevision &+= 1
        if let index = catalog.tracks.firstIndex(where: { $0.id == track.id }) {
            catalog.tracks[index].isFavorite = false
        }
        if currentTrack.isSame(as: track) { currentTrack = updated }
        refreshHomeSnapshots()
        await connector.setFavorite(serverID: updated.serverID, trackID: updated.id, isFavorite: false)
    }

    /// 跳到上一首；播放已超过 3 秒时先回到本曲开头（主流播放器的习惯行为）。
    public func previous() {
        if playbackPosition > 3 {
            // 超过 3 秒：回到本曲开头——真实 seek 引擎并同步控制中心/锁屏（P2-10）。
            seekToAbsolute(0)
            return
        }
        guard currentQueueIndex != nil else {
            seekToAbsolute(0)
            return
        }
        // R05：队列回退用 queueStore.advanceBackward()，重复歌曲不串位。
        if let previous = queueStore.advanceBackward() {
            selectAndPlay(previous)
        } else if repeatMode == .all, let lastEntry = queueStore.entries.last {
            // 列表循环：队首回绕到队尾最后一首，而不是停在原曲（P2-10）。
            _ = queueStore.play(entryID: lastEntry.id)
            selectAndPlay(lastEntry.track)
        } else {
            // 没有上一首：回到本曲开头，真实 seek 引擎（P2-10）。
            seekToAbsolute(0)
        }
    }

    /// 拖动进度：同时更新 UI 位置、驱动引擎真实 seek，并同步锁屏进度。
    public func seek(toProgress progress: Double) {
        playbackPosition = min(max(progress, 0), 1) * effectivePlaybackDuration
        let position = playbackPosition
        let identity = queueIdentity(currentTrack)
        schedulePlaybackSessionPersistence()
        Task {
            // seek 竞态防护（P2-18）：执行前若已切歌则放弃旧 seek，避免落到新曲目。
            guard queueIdentity(self.currentTrack) == identity else { return }
            await engine.seek(to: position)
            mediaIntegration.seekCompleted(position: position, isPlaying: playbackState == .playing, rate: playbackState == .playing ? playbackRate : 0)
            let content = liveActivityContent()
            await liveActivityManager.updatePlayback(content, reason: .seek)
        }
    }

    // MARK: - Queue editing

    /// 当前曲目在播放队列中的下标（O(1)，由 queueStore 维护）。
    public var currentQueueIndex: Int? {
        queueStore.currentIndex
    }

    /// 待播队列：当前曲目之后的部分。只映射 upcoming 切片，不复制完整队列。
    public var upcomingTracks: [Track] {
        queueStore.entries(after: currentQueueIndex).map(\.track)
    }

    /// 清空待播队列：保留当前曲目，不删除队列里正在播放的歌曲。
    public func clearUpcoming() {
        guard let index = currentQueueIndex else { return }
        queueStore.removeUpcoming(from: index, currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
    }

    /// 拖动调整队列顺序：保持当前曲目位置，移动后持久化播放会话。
    /// 按队列项 id 移动（R05），重复歌曲互不干扰。
    public func moveQueue(from source: IndexSet, to destination: Int) {
        queueStore.move(from: source, to: destination, currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
    }

    public func removeFromQueue(atOffsets offsets: IndexSet) {
        // R05：按队列项 id 移除——重复歌曲只移除被滑动的具体那一项。
        let entryIDs = offsets.compactMap { queueStore.entries.indices.contains($0) ? queueStore.entries[$0].id : nil }
        var removedCurrent = false
        for entryID in entryIDs {
            if let entry = queueStore.entries.first(where: { $0.id == entryID }),
               queueIdentity(entry.track) == queueIdentity(currentTrack) {
                removedCurrent = true
            }
            queueStore.remove(entryID: entryID, currentTrackID: queueIdentity(currentTrack))
        }
        schedulePlaybackSessionPersistence()
        guard removedCurrent else { return }
        // 删除正在播放的曲目时自动切到下一首；队列清空后回到空闲状态。
        if let next = queueStore.currentTrack {
            selectAndPlay(next)
        } else {
            playbackPosition = 0
            Task {
                await engine.stop()
                playbackState = await engine.state()
                syncProgressTimer()
                // 队列清空、播放停止：清理系统 Now Playing 与灵动岛
                mediaIntegration.stop()
            }
        }
    }

    /// 从队列移除曲目。删除正在播放的曲目时自动切到下一首；
    /// 队列清空后回到空闲状态。曲目仍保留在音乐库中。
    public func removeFromQueue(_ track: Track) {
        guard let entry = queueStore.entries.first(where: { queueIdentity($0.track) == queueIdentity(track) }) else { return }
        removeQueueEntry(id: entry.id)
    }

    /// 按队列项 id 移除（R05）：重复歌曲只移除指定那一项。
    /// 删除正在播放的曲目时自动切到下一首；队列清空后回到空闲状态。
    public func removeQueueEntry(id: UUID) {
        let wasCurrent = queueStore.entries.first(where: { $0.id == id })
            .map { queueIdentity($0.track) == queueIdentity(currentTrack) } ?? false
        queueStore.remove(entryID: id, currentTrackID: queueIdentity(currentTrack))
        schedulePlaybackSessionPersistence()
        guard wasCurrent else { return }
        if let next = queueStore.currentTrack {
            selectAndPlay(next)
        } else {
            playbackPosition = 0
            Task {
                await engine.stop()
                playbackState = await engine.state()
                syncProgressTimer()
                // 队列清空、播放停止：清理系统 Now Playing 与灵动岛
                mediaIntegration.stop()
            }
        }
    }

    /// 播放队列中的指定项（用户点击队列 UI）。R05：以队列项 UUID 定位——
    /// 重复歌曲点击第二个 A 就播第二个 A，不会误播第一个匹配项。
    public func playQueueEntry(id: UUID) {
        guard let track = queueStore.play(entryID: id) else { return }
        selectAndPlay(track)
    }

    // MARK: - Progress timer

    private func syncProgressTimer() {
        if playbackState == .playing {
            recordPlaybackStarted(for: currentTrack)
            startProgressTimer()
        } else {
            stopProgressTimer()
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// 进度刷新：优先采用引擎（AVPlayer）真实位置；取不到才按计时器估算，
    /// 估算模式下播完由这里兜底检测（真实模式下由引擎的播完通知驱动）。
    /// 同时以低频节流把播放位置写入本地，进程终止后能恢复进度。
    private var lastPlaybackPersistAt: Date = .distantPast
    /// 进度 tick 合并：`advanceProgress` 每 0.5 秒触发一次；若上一次的引擎位置查询
    /// 还没返回，跳过本次，避免 Task 叠加（P2-4）。
    private var isAdvancingProgress = false
    private func advanceProgress() {
        guard playbackState == .playing, !isAdvancingProgress else { return }
        isAdvancingProgress = true
        Task { @MainActor in
            defer { self.isAdvancingProgress = false }
            // 时长只读缓存：引擎按 item 解析一次/变化时更新，tick 不做重负载读取。
            if let realDuration = await self.engine.currentDuration() {
                self.actualDuration = realDuration
            }
            // 只显示/持久化位置；不把真实位置 clamp 回可能偏短的 metadata 时长。
            if let real = await self.engine.currentPosition() {
                self.playbackPosition = max(real, 0)
            } else {
                self.playbackPosition += 0.5
            }
            // 注意：不在这里宣布“歌曲播完”。自然结束的唯一权威事件是
            // AVPlayerItemDidPlayToEndTime + PlayerItemBoundaryCoordinator。
            self.qualifyCurrentPlaybackIfNeeded()
            // 每 2 秒落盘一次进度，避免高频写入。
            if Date().timeIntervalSince(self.lastPlaybackPersistAt) >= 2 {
                self.lastPlaybackPersistAt = .now
                self.schedulePlaybackSessionPersistence()
            }
        }
    }

    /// 曲目播完：按循环/随机模式决定重播、切下一首、绕回队首或暂停。
    /// 睡眠定时优先：当前歌曲/专辑/队列结束时停止而不是继续切歌。
    public func handleTrackEnded() {
        finalizeCompletedTrack(currentTrack)
        if applySleepTimerAtTrackEnd() { return }
        switch repeatMode {
        case .one:
            selectAndPlay(currentTrack)
        case .all:
            if isShuffled {
                if !playRandomFromQueue(), queueStore.count == 1 {
                    // 单曲队列 + 随机：与 .one 一致，循环播放当前曲目。
                    selectAndPlay(currentTrack)
                }
            } else if hasNext {
                next()
            } else if queueStore.count == 1 {
                // 单曲队列：与 .one 一致，循环播放当前曲目（F15）。
                selectAndPlay(currentTrack)
            } else if let first = queueStore.firstTrack {
                selectAndPlay(first)
            } else {
                pauseAtQueueEnd()
            }
        case .off:
            if isShuffled {
                if !playRandomFromQueue() {
                    // 随机 + 不循环：本轮随机已播完，停止而不是继续隐式循环。
                    pauseAtQueueEnd()
                }
            } else if hasNext {
                next()
            } else {
                pauseAtQueueEnd()
            }
        }
    }

    /// AVQueuePlayer has already advanced into this item. Update only model,
    /// history and platform metadata; calling selectAndPlay here would tear
    /// down the prebuffered player and reintroduce the gap we just removed.
    private func handlePreparedTrackStarted(_ prepared: Track) {
        // gapless A→B：B 的前几个 UI tick 不得沿用 A 的真实时长。
        actualDuration = nil
        let finished = currentTrack
        finalizeCompletedTrack(finished)
        if applySleepTimerAtTrackEnd() { return }

        // 单曲循环下不应存在预载下一首；若模式切换竞态导致旧预载项被引擎自动推进，
        // 回到单曲循环语义：重播当前曲目，而不是被旧预载项带跑（避免“单曲循环不起作用”）。
        if repeatMode == .one {
            selectAndPlay(currentTrack)
            return
        }

        guard seamlessNextCandidate().map(queueIdentity) == queueIdentity(prepared),
              let canonical = queueStore.entries.first(where: { queueIdentity($0.track) == queueIdentity(prepared) })?.track else {
            // Queue changed at the boundary after preparation. Stop the stale
            // transition and let the current queue policy choose deterministically.
            if let expected = seamlessNextCandidate() {
                selectAndPlay(expected)
            } else {
                pauseAtQueueEnd()
            }
            return
        }
        playbackHistoryStore.resetSelection()
        currentTrack = canonical
        playbackPosition = 0
        playbackState = .playing
        loadLyricsIfNeeded(for: canonical)
        syncProgressTimer()
        syncNowPlayingTrack()
        schedulePlaybackSessionPersistence()
        schedulePreparedNext()
    }

    private func finalizeCompletedTrack(_ finished: Track) {
        // 短曲也必须在真正播完时记一次合格播放；选择或播放失败仍不会计数。
        qualifyCurrentPlaybackIfNeeded(force: true)
        // Navidrome 只在 scrobble(submission=true) 时记录播放次数，stream 不会标记。
        // 曲目自然播完即上报当前曲目，保持服务器端播放计数与本地一致。
        // 仅在当前曲目属于活动服务器时上报，避免跨服务器串库。
        if finished.id.rawValue != "placeholder",
           finished.serverID == catalog.activeServerID {
            let connector = self.connector
            let store = catalogCoordinator.store
            let globalID = GlobalID(serverID: finished.serverID, remoteID: finished.id.rawValue)
            Task {
                await connector.scrobble(serverID: finished.serverID, trackID: finished.id, submission: true)
                try? await store.markPlayCompleted(globalID)
            }
        }
    }

    private func schedulePreparedNext() {
        prepareNextTask?.cancel()
        let candidate = seamlessNextCandidate()
        guard let candidate,
              playbackState == .playing || playbackState == .buffering || playbackState == .preparing
        else {
            prepareNextTask = Task { [engine] in await engine.prepareNext(track: nil) }
            return
        }
        let currentIdentity = queueIdentity(currentTrack)
        let candidateIdentity = queueIdentity(candidate)
        prepareNextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let playable = await resolvePlayableTrack(candidate) else { return }
            guard !Task.isCancelled,
                  queueIdentity(currentTrack) == currentIdentity,
                  seamlessNextCandidate().map(queueIdentity) == candidateIdentity,
                  playable.streamURL != nil else { return }
            await engine.prepareNext(track: playable)
        }
    }

    private func seamlessNextCandidate() -> Track? {
        guard !isShuffled, repeatMode != .one,
              let index = currentQueueIndex else { return nil }
        if sleepTimerMode == .afterCurrentTrack { return nil }

        let candidate: Track?
        if let next = queueStore.track(at: index + 1) {
            candidate = next
        } else if repeatMode == .all {
            candidate = queueStore.firstTrack
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        if sleepTimerMode == .afterCurrentAlbum, candidate.albumID != currentTrack.albumID { return nil }
        if sleepTimerMode == .afterCurrentQueue, queueStore.track(at: index + 1) == nil { return nil }
        return candidate
    }

    private func pauseAtQueueEnd() {
        lastStopReason = .queueEnded
        playbackPosition = 0
        actualDuration = nil
        Task { await liveActivityManager.endPlayback() }
        Task {
            await engine.pause()
            playbackState = await engine.state()
            syncProgressTimer()
            mediaIntegration.playbackStateChanged(isPlaying: false, position: 0, rate: 0)
        }
    }

    /// 播放中途失败（流地址失效 / 解码失败 / 网络错误）：
    /// 1. 刷新流地址并重试（最多 Self.maxStreamRetryAttempts 次，不无限重试）；
    /// 2. 重试耗尽后，若队列有下一首则自动切下一首，否则保留失败状态并提示用户。
    private func handleStreamFailure() {
        let track = currentTrack
        guard track.id.rawValue != "placeholder" else { return }
        // 重试预算按 GlobalID 隔离：切换服务器后即使远端 TrackID 相同也不会串扰。
        let gid = queueIdentity(track)
        let attempts = streamRetryAttempts[gid, default: 0]
        guard attempts < Self.maxStreamRetryAttempts else {
            streamRetryAttempts[gid] = 0
            lastStopReason = .streamExpired
            playbackError = .engineFailure(String(localized: "流地址失效，已重试仍无法播放", bundle: .module))
            playbackState = .failed(.engineFailure(String(localized: "流地址失效，已重试仍无法播放", bundle: .module)))
            syncProgressTimer()
            // 统一用 canGoNext（含列表循环绕回、shuffle 剩余候选），而不是物理队列 hasNext：
            // repeat all 队尾可绕回；repeat off 队尾停止；不产生 fail→repeat→fail 自旋。
            if canGoNext {
                next()
            }
            return
        }
        streamRetryAttempts[gid] = attempts + 1
        playbackState = .buffering
        CrashLog.shared.log("流地址失效，刷新后重试（第 \(attempts + 1) 次）")
        Task { @MainActor in
            let refreshed = await resolvePlayableTrack(track, forceRefresh: true)
            guard self.currentTrack.isSame(as: track) else { return }
            guard let refreshed else {
                // 无法获取新流地址（服务器离线等）：按重试耗尽处理，自动下一首或提示。
                self.streamRetryAttempts[gid] = Self.maxStreamRetryAttempts
                self.handleStreamFailure()
                return
            }
            do {
                try await self.engine.play(track: refreshed)
                self.playbackError = nil
                self.playbackState = await self.engine.state()
                self.syncProgressTimer()
                self.syncNowPlayingTrack()
            } catch {
                self.handleStreamFailure()
            }
        }
    }

    public func connect(to input: ServerConnectionInput) async {
        serverConnectionState = .connecting(.validating)
        do {
            try ServerURLPolicy.validate(input.baseURL)
            guard !input.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerConnectionError.missingDisplayName
            }
            guard !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerConnectionError.missingUsername
            }
            guard !input.password.isEmpty else { throw ServerConnectionError.missingCredential }
            let result = try await connector.connect(input) { [weak self] stage in
                await MainActor.run { [weak self] in
                    self?.serverConnectionState = .connecting(stage)
                }
            }
            guard !result.tracks.isEmpty else { throw ServerConnectionError.emptyLibrary }
            apply(result)
            recordConnectionDiagnostics(host: input.baseURL.host, url: input.baseURL, error: nil, message: "连接成功", requestAttempted: true)
        } catch is CancellationError {
            serverConnectionState = .failed(ServerConnectionError.cancelled.localizedDescription)
        } catch {
            // 统一分类错误文案（地址/认证/超时/局域网权限/ATS/非 OpenSubsonic 等），
            // 不把所有失败都显示成笼统的"连接未完成"。
            let message = ConnectionErrorDescription.describe(error)
            recordConnectionDiagnostics(host: input.baseURL.host, url: input.baseURL, error: error, message: message, requestAttempted: true)
            serverConnectionState = .failed(message)
        }
    }

    /// 连接测试结果（可安全展示的文本）。
    public enum ConnectionTestOutcome: Sendable {
        case success(String)
        case failure(String)
    }

    /// 用「用户当前输入」执行一次真实连接测试（不保存、不同步、不关闭配置界面）。
    /// 返回 .success(可展示的服务器信息) 或 .failure(分类错误文案)。
    public func testServerConnectionWithInput(_ input: ServerConnectionInput) async -> ConnectionTestOutcome {
        do {
            try ServerURLPolicy.validate(input.baseURL)
            guard !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(ServerConnectionError.missingUsername.localizedDescription)
            }
            guard !input.password.isEmpty else {
                return .failure(ServerConnectionError.missingCredential.localizedDescription)
            }
            let result = try await connector.testConnection(input)
            var parts: [String] = []
            parts.append("服务器可连接")
            if let type = result.serverType { parts.append("软件：\(type)") }
            if let version = result.serverVersion { parts.append("版本：\(version)") }
            if let api = result.apiVersion { parts.append("协议：\(api)") }
            parts.append("认证成功（\(result.username ?? "当前用户")）")
            let message = parts.joined(separator: " · ")
            recordConnectionDiagnostics(host: input.baseURL.host, url: input.baseURL, error: nil, message: message, requestAttempted: true)
            return .success(message)
        } catch {
            let message = ConnectionErrorDescription.describe(error)
            recordConnectionDiagnostics(host: input.baseURL.host, url: input.baseURL, error: error, message: message, requestAttempted: true)
            return .failure(message)
        }
    }

    public func restorePersistedLibrary() async {
        guard !attemptedRestore else { return }
        attemptedRestore = true
        let restoreStartedAt = ContinuousClock.now
        do {
            // 优先恢复「上次活跃服务器」，其次回退到首个已保存账户，
            // 保证切换服务器后冷启动不会错误地回到第一台服务器。
            var result: ServerConnectionResult?
            if let lastID = defaults.string(forKey: Self.lastActiveServerKey) {
                result = try await connector.restoreConnection(serverID: ServerID(rawValue: lastID))
            }
            if result == nil {
                result = try await connector.restoreLastConnection()
            }
            // 允许「已配置但未同步」的服务器：备份恢复或首次切换时可能还没有本地快照，
            // 此时仍然登记账号并进入已连接状态，由 registerAndSync 在后台完成首次同步，
            // 而不是错误地弹出「重新添加服务器」。
            guard let result else {
                // 没有任何已保存账号，自动弹出服务器配置窗口
                shouldPresentServerSetup = true
                return
            }
            apply(result)
            let startupMetadata = StartupPerformanceTrace.Metadata(
                entityCount: result.tracks.count,
                serverIDHash: StartupPerformanceTrace.redactedServerID(result.account.id.rawValue)
            )
            StartupPerformanceTrace.record(
                .localCatalogReady,
                since: restoreStartedAt,
                metadata: startupMetadata
            )
            StartupPerformanceTrace.record(
                .serverConnectionStateConnected,
                since: restoreStartedAt,
                metadata: startupMetadata
            )
            schedulePostRestoreMaintenance()
            // apply() 末尾已触发 registerAndSync，此处不再重复。
            // 自愈：恢复出的资料库为空（旧快照损坏 / 历史某次同步失败遗留）时，
            // 后台用服务器凭据重新全量同步并刷回界面，避免资料库一直显示 0 首。
            if result.tracks.isEmpty {
                let serverID = result.account.id
                Task { @MainActor [weak self, connector] in
                    guard let self else { return }
                    if let fresh = try? await connector.resync(serverID: serverID) {
                        self.apply(fresh)
                    }
                }
            }
        } catch {
            // 持久化状态是增强功能；恢复失败时弹出服务器配置让用户重新连接
            serverConnectionState = .idle
            shouldPresentServerSetup = true
        }
    }

    /// 本地目录已可见后再执行完整性检查与旧 dislike 迁移。Agent 在此之前完全不会
    /// 初始化；utility task 也先让出首帧，避免与窗口首次交互竞争主线程/磁盘。
    private func schedulePostRestoreMaintenance() {
        let store = catalogCoordinator.store
        Task.detached(priority: .utility) { [weak self, store] in
            try? await Task.sleep(for: .seconds(2))
            do {
                try await store.verifyIntegrityIfDue()
            } catch {
                // 完整性检查失败是数据库损坏信号，必须留痕；不阻塞本地目录继续使用。
                AuralisLog.library.error("catalog integrity check failed: \(error.localizedDescription)")
            }
            await self?.performDeferredAgentMaintenance()
        }
    }

    private func performDeferredAgentMaintenance() async {
        let startedAt = ContinuousClock.now
        await agentCoordinator.migrateLegacyDislikedIfNeeded()
        StartupPerformanceTrace.record(.restoreDislikeMigration, since: startedAt)
        await refreshDislikedState()
    }

    private func apply(_ result: ServerConnectionResult) {
        serverAuthenticationFailed = false
        serverCapabilities = result.capabilities
        let serverHash = StartupPerformanceTrace.redactedServerID(result.account.id.rawValue)
        // 全链路以去重后的曲目为准，避免服务端返回的重复 ID 进入界面导致 ForEach 崩溃。
        let dedupeStartedAt = ContinuousClock.now
        let tracks = uniquedTracks(result.tracks)
        // Artist / Album 同样按 GlobalID 去重：跨服务器相同 remoteID 或服务端重复条目
        // 会让 ForEach(id: \.macGlobalID) 产生 duplicate identity，Mac 艺术家页会崩溃。
        let artists = CatalogEntityUniquing.uniquedArtists(result.artists)
        let albums = CatalogEntityUniquing.uniquedAlbums(result.albums)
        StartupPerformanceTrace.record(
            .appApplyDedupe,
            since: dedupeStartedAt,
            metadata: .init(entityCount: tracks.count, serverIDHash: serverHash)
        )
        let genresStartedAt = ContinuousClock.now
        let derivedGenres = Dictionary(grouping: tracks.flatMap(\.genres), by: { $0.lowercased() })
            .map { Genre(name: $0.key, songCount: $0.value.count) }
        // 合并「服务器 getGenres」与「按曲目标签推导」两套流派来源（按名称小写归并，
        // 计数取较大值，命名优先采用服务器侧）。Navidrome 等服务器 getGenres 常返回空，
        // 单靠其一都会让「流派」为空；合并后只要任一侧有数据就能显示。
        let serverGenres = result.genres
        var genreIndex: [String: Genre] = [:]
        for g in derivedGenres { genreIndex[g.name.lowercased()] = g }
        for g in serverGenres {
            let key = g.name.lowercased()
            if let existing = genreIndex[key] {
                let count = max(existing.songCount, g.songCount)
                let name = g.songCount >= existing.songCount ? g.name : existing.name
                genreIndex[key] = Genre(name: name, songCount: count)
            } else {
                genreIndex[key] = g
            }
        }
        let mergedGenres = genreIndex.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        StartupPerformanceTrace.record(
            .appApplyGenres,
            since: genresStartedAt,
            metadata: .init(entityCount: mergedGenres.count, serverIDHash: serverHash)
        )
        // 是否换了一台服务器。同一台服务器的增量刷新不应丢弃已加载的封面 / 歌词，
        // 否则每次同步都要把所有封面重新下载一遍。
        let switchedServer = appliedServerID != nil && appliedServerID != result.account.id
        appliedServerID = result.account.id
        defaults.set(result.account.id.rawValue, forKey: Self.lastActiveServerKey)
        if playbackHistoryStore.reconcileLegacy(serverID: result.account.id) {
            libraryRowMetadataRevision &+= 1
            defaults.set(playbackHistoryStore.encodedCounts, forKey: Self.playCountsDefaultsKey)
            defaults.set(playbackHistoryStore.encodedRecentKeys, forKey: Self.recentlyPlayedDefaultsKey)
        }
        artworkStore.setServerID(result.account.id.rawValue)
        let migrationServerID = result.account.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cacheStore.migrateLegacyEntries(to: migrationServerID)
            await self.lyricsCache.migrateLegacyEntries(to: migrationServerID)
            await self.downloadStore.restoreCachedIDs()
        }
        catalog = LibraryCatalog(
            account: result.account,
            artists: artists,
            albums: albums,
            tracks: tracks,
            genres: mergedGenres,
            playlists: result.playlists,
            history: [],
            downloads: [],
            // 同一台服务器：保留已加载的歌词，避免重复请求。
            lyrics: switchedServer ? [:] : catalog.lyrics,
            recommendations: []
        )
        // 只有真正切换服务器才清空封面 / 歌词内存缓存，避免串库。
        if switchedServer {
            lyricsInFlight = []
            lyricsUnavailable = []
            playlistTracks = [:]
            loadingPlaylistIDs = []
            playlistIDsNeedingContentRefresh = []
            deletedPlaylistIDs = []
            favoriteAlbumIDs = []
            favoriteArtistIDs = []
        } else {
            // 同库刷新：只清理「本次失败」的负缓存，让新同步进来的曲目有机会重试，
            // 已经拿到的图片与歌词原样保留。
            artworkStore.clearUnavailable()
            lyricsUnavailable = []
        }
        // 恢复该服务器的专辑/艺术家收藏集合（首帧进入时从本地读回）。
        if let lastID = defaults.string(forKey: Self.lastActiveServerKey) {
            let server = ServerID(rawValue: lastID)
            if favoriteAlbumIDs.isEmpty {
                let raw = defaults.array(forKey: Self.favoriteAlbumsKey(server)) as? [String] ?? []
                favoriteAlbumIDs = Set(raw.map(AlbumID.init(rawValue:)))
            }
            if favoriteArtistIDs.isEmpty {
                let raw = defaults.array(forKey: Self.favoriteArtistsKey(server)) as? [String] ?? []
                favoriteArtistIDs = Set(raw.map(ArtistID.init(rawValue:)))
            }
        }
        // 资料库刷新时若正在播放，保留当前播放上下文（歌曲/队列/进度），
        // 避免后台增量同步把正在播放的音乐打断或把队列清空。
        let wasPlaying = playbackState == .playing || playbackState == .paused
        if switchedServer {
            // 播放中切换服务器：停止当前播放、清空旧服务器队列/进度并落盘，
            // 避免「切库后点下一首仍播旧库歌曲」以及用新服务器键写旧 trackID 快照。
            playbackTask?.cancel()
            playbackTask = nil
            prepareNextTask?.cancel()
            prepareNextTask = nil
            playbackError = nil
            lastStopReason = .serverDisconnected
            playbackPosition = 0
            actualDuration = nil
            queue = Array(tracks.prefix(30))
            // 关键：把 currentTrack 重置为新服务器的曲目（或占位），避免旧服务器曲目
            // 在切换后仍显示在播放条上、且点播放时被新服务器连接器按相同 TrackID 解析（P0-1）。
            if let first = tracks.first {
                currentTrack = first
                loadLyricsIfNeeded(for: first)
            } else {
                currentTrack = Track(
                    id: "placeholder", serverID: result.account.id,
                    albumID: "placeholder", artistID: "placeholder",
                    title: "请先连接服务器", artistName: "", albumTitle: "", duration: 0
                )
            }
            handoffActivity?.invalidate()
            Task { @MainActor in
                await self.engine.stop()
                self.playbackState = await self.engine.state()
                self.syncProgressTimer()
                self.mediaIntegration.stop()
                self.schedulePlaybackSessionPersistence()
            }
        } else if !wasPlaying {
            queue = Array(tracks.prefix(30))
        }
        // 重要：catalog 更新绝不调用 mediaIntegration.stop()——
        // 那会停用 AVAudioSession 并清空 MPNowPlayingInfoCenter，导致后台播放被杀、
        // 控制中心丢失歌曲信息。正在播放时只更新目录，音频与系统信息保持不变。

        // 派生任务（P1-2/3/4）：
        // - 先刷新权威「不喜欢」状态（SQLite），再基于其派生一次，避免随机货架
        //   使用旧服务器/空集合；
        // - library-added 对齐与随机采样在 utility 后台任务计算（不再阻塞 MainActor）；
        // - cancel + applyGeneration 代际守卫：连续 apply / 快速切服时，旧代际结果作废。
        applyGeneration &+= 1
        let generation = applyGeneration
        let tracksSnapshot = tracks
        let serverIDSnapshot = result.account.id
        let trackerSnapshot = libraryAddedTracker
        let serverHashForTrace = serverHash
        pendingApplyDerivations?.cancel()
        pendingApplyDerivations = Task { [weak self] in
            guard let self else { return }
            let libraryAddedStartedAt = ContinuousClock.now
            // 1) 读取这次同步对应服务器的权威状态，避免异步切服后旧结果反扑。
            let loadedDisliked = await self.loadDislikedTrackIDs(serverID: serverIDSnapshot)
            guard !Task.isCancelled else { return }
            guard self.applyGeneration == generation else { return }
            guard self.catalog.activeServerID == serverIDSnapshot else { return }
            let dislikedSnapshot: Set<GlobalID>
            if let loadedDisliked {
                dislikedSnapshot = loadedDisliked
            } else if self.dislikedStateServerID == serverIDSnapshot {
                dislikedSnapshot = self.dislikedTrackIDs
            } else {
                dislikedSnapshot = []
            }

            // 2) 真正的后台计算（utility）：library-added 对齐 + 随机采样。
            let derived = await Task.detached(priority: .utility) {
                LibraryDerivedBuilder.build(
                    tracks: tracksSnapshot,
                    serverID: serverIDSnapshot,
                    dislikedTrackIDs: dislikedSnapshot,
                    tracker: trackerSnapshot
                )
            }.value
            guard !Task.isCancelled else { return }

            // 3) 仅当代际仍为当前时才应用结果，否则静默丢弃（旧任务反扑防护）。
            await MainActor.run {
                // self 在上方已强捕获（guard let self），这里只做代际校验。
                guard self.applyGeneration == generation else { return }
                guard self.catalog.activeServerID == serverIDSnapshot else { return }
                if let loadedDisliked {
                    self.dislikedTrackIDs = loadedDisliked
                    self.dislikedStateServerID = serverIDSnapshot
                }
                if derived.addedDatesChanged {
                    self.libraryAddedTracker = derived.tracker
                    self.libraryRowMetadataRevision &+= 1
                    let stored = derived.tracker.encoded
                    Task { @Sendable [defaults = self.defaults] in
                        defaults.set(stored, forKey: Self.libraryAddedDefaultsKey)
                    }
                }
                StartupPerformanceTrace.record(
                    .appApplyLibraryAdded,
                    since: libraryAddedStartedAt,
                    metadata: .init(entityCount: tracksSnapshot.count, serverIDHash: serverHashForTrace)
                )
                // 随机音乐：使用后台已算好的采样（保持稳定，不二次 shuffle）。
                let homeSnapshotStartedAt = ContinuousClock.now
                self.homeStore.applyRandomSample(derived.randomTracks)
                // 资料库就绪：刷新首页货架快照（收藏 / 最常听 / 最近播放 / 最近添加）。
                self.refreshHomeSnapshots()
                StartupPerformanceTrace.record(
                    .appApplyHomeSnapshot,
                    since: homeSnapshotStartedAt,
                    metadata: .init(entityCount: tracksSnapshot.count, serverIDHash: serverHashForTrace)
                )
            }
        }

        // 仅在未播放时恢复「上次播放会话」（队列 + 当前曲目 + 进度），
        // 不自动播放，由用户点击播放后从保存的进度继续；
        // 正在播放时保留当前曲目、队列与进度，增量同步不打断播放。
        if !wasPlaying {
            // 优先恢复按服务器隔离的播放会话快照；无快照时回退到「上次收听曲目」。
            if !restorePlaybackSession(from: result.tracks, serverID: result.account.id) {
                // 恢复上次收听的那一首（若仍存在于新目录），否则取队列首；
                // 这样「继续聆听 / 播放条」在重新打开时显示的是上次听过的曲目，而非目录第一首。
                let lastID = defaults.string(forKey: Self.lastTrackKey(result.account.id))
                    ?? defaults.string(forKey: Self.legacyLastTrackDefaultsKey)
                if let id = lastID, let restored = result.tracks.first(where: { $0.id.rawValue == id }) {
                    defaults.set(id, forKey: Self.lastTrackKey(result.account.id))
                    currentTrack = restored
                    loadLyricsIfNeeded(for: restored)
                    // 恢复曲目可能位于队列前 30 首之外，确保它进入队列，避免上一首/下一首静默失效。
                    if !queue.contains(where: { queueIdentity($0) == queueIdentity(restored) }) {
                        queue.insert(restored, at: 0)
                    }
                } else if let first = queue.first {
                    currentTrack = first
                    loadLyricsIfNeeded(for: first)
                }
                playbackPosition = 0
            }
        }
        serverConnectionState = .connected(
            account: result.account,
            serverType: result.serverType,
            serverVersion: result.serverVersion,
            // 用去重后的曲目数：catalog.tracks 是 uniquedTracks(result.tracks)，
            // 若同步结果含重复 TrackID（旧快照 / 同一首歌在多张专辑），
            // 用 result.tracks.count 会导致「设置-服务器 已同步」与「音乐库 歌曲数」不一致。
            trackCount: tracks.count
        )
        // 登记服务器并按需触发首次全量 / 增量目录同步（后台进行，不阻塞 UI）。
        let account = result.account
        Task { [catalogCoordinator] in
            await catalogCoordinator.registerAndSync(account: account)
        }
        // 冷启动此刻界面已经用本地缓存渲染完毕，这里再后台对照服务器刷新歌单 / 流派。
        refreshAuxiliaryDataInBackground()

        // 把歌单写入本地 SQLite，让 Agent/搜索的 listPlaylists 返回真实歌单（此前 SQLite 恒为 0，
        // 导致助手问「有多少个歌单」返回 0 并触发 400 回退）。
        persistServerPlaylists(catalog.playlists, serverID: result.account.id)

        // 若 Siri / URL Scheme 在恢复资料库前就发来了播放请求，这里资料库已就绪，立即消费。
        processSiriPlayRequest()

        // Spotlight：把本地资料库登记到系统搜索（后台执行，幂等覆盖）。
        let spotlightArtists = artists
        let spotlightAlbums = albums
        let spotlightTracks = tracks
        let spotlightPlaylists = result.playlists
        Task { @MainActor in
            SpotlightIndexer.reindex(
                artists: spotlightArtists,
                albums: spotlightAlbums,
                tracks: spotlightTracks,
                playlists: spotlightPlaylists,
                dislikedTrackIDs: dislikedTrackIDs
            )
        }

        // 冷启动回填本地评分：从 SQLite 读回该服务器的评分并写回内存 catalog，
        // 让「评分」在重启后仍然可见（Agent 与后续 UI 共用同一数据）。
        let ratingServerID = result.account.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ratings = (try? await self.catalogCoordinator.store.ratings(serverID: ratingServerID)) ?? [:]
            guard !ratings.isEmpty else { return }
            var changed = false
            for index in self.catalog.tracks.indices {
                let gid = GlobalID(serverID: ratingServerID, remoteID: self.catalog.tracks[index].id.rawValue)
                if let value = ratings[gid], self.catalog.tracks[index].rating != value {
                    self.catalog.tracks[index].rating = value
                    changed = true
                }
            }
            if changed,
               self.currentTrack.id.rawValue != "placeholder",
               let index = self.catalog.tracks.firstIndex(where: { $0.id == self.currentTrack.id }) {
                self.currentTrack = self.catalog.tracks[index]
            }
        }
    }

    /// 同步完成后把内存目录从本地 SQLite 重建出来（同库刷新，不切换服务器）。
    ///
    /// 后台/增量同步（CatalogCoordinator.backgroundRefresh → startSync(.incremental)）把
    /// 新下载到服务器的歌写进本地 SQLite 后，这里把目录从 store 读回内存，让首页
    /// 「最近添加」与音乐库立刻更新，而不是等用户重连/重启（apply()）。
    /// 逻辑对齐 apply() 的「同库刷新」分支：
    /// - 保留当前歌词（catalog.lyrics）、playlistTracks 与正在播放的上下文
    ///   （currentTrack / queue / 进度）不被清掉；
    /// - 更新按 GlobalID 隔离的首次入库时间，并异步持久化到 UserDefaults；
    /// - 重建 catalog 并调用 refreshHomeSnapshots()。
    func refreshCatalogFromStore(serverID: ServerID) async {
        let refreshStartedAt = ContinuousClock.now
        var refreshedTrackCount = 0
        defer {
            StartupPerformanceTrace.record(
                .refreshCatalogFromStore,
                since: refreshStartedAt,
                metadata: .init(
                    entityCount: refreshedTrackCount,
                    serverIDHash: StartupPerformanceTrace.redactedServerID(serverID.rawValue)
                )
            )
        }
        // 防呆：尚未 apply（或已切到其它服务器）时忽略本次刷新。
        guard catalog.activeServerID == serverID else { return }
        let store = catalogCoordinator.store
        let fetchedTracks: [Track]
        let fetchedAlbums: [Album]
        let fetchedArtists: [Artist]
        do {
            let snapshot = try await store.catalogSnapshot(serverID: serverID)
            fetchedTracks = snapshot.tracks
            fetchedAlbums = snapshot.albums
            fetchedArtists = snapshot.artists
            refreshedTrackCount = snapshot.tracks.count
        } catch {
            // 读库失败：保持现有目录，等下次同步 / apply() 再试。
            return
        }
        // await 期间用户可能已切换服务器：再校验一次，避免把旧库写回新库。
        guard catalog.activeServerID == serverID else { return }

        let tracks = uniquedTracks(fetchedTracks)
        let artists = CatalogEntityUniquing.uniquedArtists(fetchedArtists)
        let albums = CatalogEntityUniquing.uniquedAlbums(fetchedAlbums)
        // 同步不落 genres 表，按 apply() 的做法从曲目标签派生。
        let genres = Dictionary(grouping: tracks.flatMap(\.genres), by: { $0.lowercased() })
            .map { Genre(name: $0.key, songCount: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // 歌单：以 store 为准合并现有 catalog（保留本地尚未同步 / 已加载曲目的歌单）。
        let playlists = await mergePlaylistsFromStore(serverID: serverID, existing: catalog.playlists)

        catalog = LibraryCatalog(
            account: catalog.account,
            artists: artists,
            albums: albums,
            tracks: tracks,
            genres: genres,
            playlists: playlists,
            history: catalog.history,
            downloads: catalog.downloads,
            // 同库刷新：保留已加载的歌词，避免重复请求。
            lyrics: catalog.lyrics,
            recommendations: catalog.recommendations
        )
        // 同库刷新：只清理「本次失败」的负缓存，已拿到的图片与歌词原样保留
        // （与 apply() 的非切库分支一致）。
        artworkStore.clearUnavailable()
        lyricsUnavailable = []

        // 正在播放上下文原样保留：不碰 currentTrack / queue / playbackPosition / engine。

        reconcileLibraryAddedDates(tracks: tracks, serverID: serverID)

        // 资料库就绪：刷新首页货架快照（收藏 / 最常听 / 最近播放 / 最近添加）。
        refreshHomeSnapshots()
    }

    /// 以本地 SQLite 歌单为基准合并内存 catalog 歌单：
    /// store 有曲目顺序时以 store 为准，否则保留内存里已加载的 trackIDs；
    /// 服务器已删除的歌单随之移除，本地尚未同步的歌单保留。
    private func mergePlaylistsFromStore(serverID: ServerID, existing: [Playlist]) async -> [Playlist] {
        let storePlaylists = (try? await catalogCoordinator.store.listPlaylists(serverID: serverID)) ?? []
        var byID: [PlaylistID: Playlist] = [:]
        for playlist in existing { byID[playlist.id] = playlist }
        for summary in storePlaylists {
            let id = PlaylistID(rawValue: summary.globalID.remoteID)
            let trackIDs = summary.trackIDs.map { TrackID(rawValue: $0.remoteID) }
            if var existing = byID[id] {
                if !trackIDs.isEmpty { existing.trackIDs = trackIDs }
                if let modifiedAt = summary.modifiedAt { existing.modifiedAt = modifiedAt }
                byID[id] = existing
            } else {
                byID[id] = Playlist(
                    id: id,
                    serverID: serverID,
                    name: summary.name,
                    trackIDs: trackIDs,
                    modifiedAt: summary.modifiedAt
                )
            }
        }
        return byID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 手动触发一次增量同步（快捷指令「同步音乐库」入口）。
    public func syncLibraryNow() async {
        guard let serverID = catalog.activeServerID else { return }
        await catalogCoordinator.backgroundRefresh(serverID: serverID)
        refreshAuxiliaryDataInBackground()
    }

    /// 应用进入前台或系统后台刷新时调用：静默做一次增量同步。
    public func refreshCatalogInBackground() async {
        guard let serverID = catalog.activeServerID else { return }
        await catalogCoordinator.backgroundRefresh(serverID: serverID)
        refreshAuxiliaryDataInBackground()
    }

    /// 后台对照服务器刷新歌单、流派与收藏。
    /// 冷启动时界面已由本地缓存渲染，这里做「服务器权威回流」的增量刷新；
    /// 离线或请求失败时直接返回，界面保持本地缓存内容、不会闪成空白。
    public func refreshAuxiliaryDataInBackground() {
        guard let serverID = catalog.activeServerID else { return }
        Task { [weak self, connector] in
            guard let refreshed = await connector.refreshAuxiliaryData(serverID: serverID) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                mergeServerPlaylists(
                    refreshed.playlists,
                    isAuthoritative: refreshed.playlistsAreAuthoritative
                )
                mergeServerFavorites(
                    refreshed.favoriteTrackIDs,
                    isAuthoritative: refreshed.favoriteTrackIDsAreAuthoritative
                )
                mergeServerGenres(refreshed.genres)
                // 服务器刷新后的歌单同步写入 SQLite（保留本地已加载的 trackIDs）。
                if let serverID = self.catalog.activeServerID {
                    self.persistServerPlaylists(self.catalog.playlists, serverID: serverID)
                }
                // 后台整体缓存歌单曲目（仅元数据），让 Agent 的 getPlaylist 直接看到真实歌曲。
                // 放在 persist 之后，并配合 upsertPlaylist 的空曲目保留逻辑，避免竞态清空缓存。
                self.cachePlaylistContentsInBackground()
            }
        }
    }

    /// 把歌单写入本地 SQLite（Agent / 搜索的 listPlaylists 与「播放歌单」直接读这里）。
    /// 与 auxiliaryCache(JSON) 双写：JSON 服务冷启动 UI，SQLite 服务 Agent 结构化查询，
    /// 避免 Agent 查询返回 0 个歌单（此前 SQLite 从未写入歌单）。
    private func persistServerPlaylists(_ playlists: [Playlist], serverID: ServerID) {
        guard !playlists.isEmpty else { return }
        let store = catalogCoordinator.store
        Task { @MainActor [weak self] in
            guard let self else { return }
            for playlist in playlists {
                // 已删除或不再属于当前 catalog 的歌单不得被旧的异步持久化任务写回。
                guard !self.deletedPlaylistIDs.contains(playlist.id),
                      self.catalog.playlists.contains(where: { $0.id == playlist.id })
                else { continue }
                try? await store.upsertPlaylist(playlist, serverID: serverID)
            }
        }
    }

    /// 合并服务器与本地歌单，按 OpenSubsonic `changed` 执行“最近修改优先”。
    ///
    /// getPlaylists 只返回歌单壳，因此当服务器元数据较新时保留旧的曲目列表作
    /// 临时展示，并标记为需要再调 getPlaylist 拉取；这既避免列表闪空，也不会把
    /// 旧的本地曲目顺序永久当作最新内容。
    private func mergeServerPlaylists(_ serverPlaylists: [Playlist], isAuthoritative: Bool) {
        var merged: [Playlist] = []
        var seen = Set<PlaylistID>()
        for server in serverPlaylists {
            // 删除请求完成后，可能仍有一轮更早发出的刷新携带旧歌单；绝不能让它复活。
            guard !deletedPlaylistIDs.contains(server.id) else { continue }
            var value = server
            if let local = catalog.playlists.first(where: { $0.id == server.id }) {
                let serverIsNewer = shouldUseServerPlaylist(server, over: local)
                if serverIsNewer {
                    // 列表接口通常不带 entry；完整内容由后续 getPlaylist 刷新。
                    if server.trackIDs.isEmpty, !local.trackIDs.isEmpty {
                        value.trackIDs = local.trackIDs
                    }
                    if server.modifiedAt != nil,
                       server.modifiedAt != local.modifiedAt {
                        playlistIDsNeedingContentRefresh.insert(server.id)
                    }
                } else {
                    value = local
                }
            }
            merged.append(value)
            seen.insert(server.id)
        }
        if isAuthoritative {
            // getPlaylists 成功返回完整集合时，缺失项才是真正的服务器删除。
            // 失败时给的是旧缓存，必须保留现有本地目录，不能误删。
            deletedPlaylistIDs.formUnion(
                catalog.playlists.lazy.filter { !seen.contains($0.id) }.map(\.id)
            )
        } else {
            // 服务器尚未返回完整列表时保留本地歌单，避免离线刷新把列表清空。
            for local in catalog.playlists
            where !seen.contains(local.id) && !deletedPlaylistIDs.contains(local.id) {
                merged.append(local)
            }
        }
        catalog.playlists = merged
        let currentIDs = Set(merged.map(\.id))
        playlistTracks = playlistTracks.filter { currentIDs.contains($0.key) }
    }

    /// 时间缺失的旧服务器不具备可靠冲突依据，保持既有的“服务器列表优先”兼容行为；
    /// 两侧都有时间时，时间相同也选服务器，作为确定性的并发冲突裁决。
    private func shouldUseServerPlaylist(_ server: Playlist, over local: Playlist) -> Bool {
        guard let serverModifiedAt = server.modifiedAt else { return true }
        guard let localModifiedAt = local.modifiedAt else { return true }
        return serverModifiedAt >= localModifiedAt
    }

    /// 仅在 getStarred2 成功后以完整结果覆盖本地收藏；请求失败时保留原状，
    /// 避免把离线状态误写成“服务器没有任何收藏”。
    private func mergeServerFavorites(_ favoriteTrackIDs: [String], isAuthoritative: Bool) {
        guard isAuthoritative else { return }
        let favoriteSet = Set(favoriteTrackIDs)
        var changed = false
        for index in catalog.tracks.indices {
            let shouldBeFavorite = favoriteSet.contains(catalog.tracks[index].id.rawValue)
            guard catalog.tracks[index].isFavorite != shouldBeFavorite else { continue }
            catalog.tracks[index].isFavorite = shouldBeFavorite
            changed = true
        }
        if changed,
           currentTrack.id.rawValue != "placeholder",
           let index = catalog.tracks.firstIndex(where: { $0.id == currentTrack.id }) {
            currentTrack = catalog.tracks[index]
        }
        if changed {
            refreshHomeSnapshots()
        }
        if let serverID = catalog.activeServerID {
            let store = catalogCoordinator.store
            Task {
                try? await store.replaceFavoriteTracks(
                    favoriteTrackIDs.map { GlobalID(serverID: serverID, remoteID: $0) },
                    serverID: serverID
                )
            }
        }
    }

    /// 把服务器返回的流派并入本地流派（按名称小写归并，计数取较大值）。
    private func mergeServerGenres(_ serverGenres: [Genre]) {
        guard !serverGenres.isEmpty else { return }
        var genreIndex: [String: Genre] = [:]
        for g in catalog.genres { genreIndex[g.name.lowercased()] = g }
        for g in serverGenres {
            let key = g.name.lowercased()
            if let existing = genreIndex[key] {
                let count = max(existing.songCount, g.songCount)
                let name = g.songCount >= existing.songCount ? g.name : existing.name
                genreIndex[key] = Genre(name: name, songCount: count)
            } else {
                genreIndex[key] = g
            }
        }
        let merged = genreIndex.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard merged != catalog.genres else { return }
        catalog.genres = merged
    }

    // MARK: - 缓存管理（设置页）

    /// 各类本地缓存的用量快照，供设置页展示。
    public struct CacheUsage: Sendable, Equatable {
        public var artworkBytes: Int64 = 0
        public var artworkCount: Int = 0
        public var lyricsBytes: Int64 = 0
        public var lyricsCount: Int = 0
        public var audioBytes: Int64 = 0
        public var audioCount: Int = 0
        /// 元数据目录（catalog.sqlite）体积。
        public var catalogBytes: Int64 = 0
    }

    /// 统计三类缓存（封面 / 歌词 / 音频）与元数据目录的占用。
    public func cacheUsage() async -> CacheUsage {
        var usage = CacheUsage()
        usage.artworkBytes = await artworkCache.totalBytes()
        usage.artworkCount = await artworkCache.fileCount()
        usage.lyricsBytes = await lyricsCache.totalBytes()
        usage.lyricsCount = await lyricsCache.documentCount()
        usage.audioBytes = await cacheStore.totalBytes()
        usage.audioCount = downloadedTrackIDs.count
        let catalogURL = storeURL ?? CatalogCoordinator.defaultStoreURL()
        usage.catalogBytes = Int64(
            (try? catalogURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        )
        return usage
    }

    /// 清空封面缓存（仅本机文件，服务器不受影响）。
    public func clearArtworkCache() async {
        await artworkCache.clear()
        artworkStore.reset()
    }

    /// 清空歌词缓存。
    public func clearLyricsCache() async {
        await lyricsCache.clear()
        catalog.lyrics = [:]
        lyricsUnavailable = []
    }

    /// 清空已下载的音频缓存。
    public func clearAudioCache() async {
        await downloadStore.removeAll()
    }

}

/// 组合播放模式：单个按钮循环切换的四种真实播放状态。
public enum PlayMode: Int, CaseIterable, Identifiable, Sendable {
    case list    // 列表顺序（不随机、不循环）
    case shuffle // 随机播放
    case repeatAll // 列表循环
    case repeatOne // 单曲循环
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .list: String(localized: "列表顺序", bundle: .module)
        case .shuffle: String(localized: "随机播放", bundle: .module)
        case .repeatAll: String(localized: "列表循环", bundle: .module)
        case .repeatOne: String(localized: "单曲循环", bundle: .module)
        }
    }
    public var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .shuffle: "shuffle"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        }
    }
    public func next() -> PlayMode {
        switch self {
        case .list: return .shuffle
        case .shuffle: return .repeatAll
        case .repeatAll: return .repeatOne
        case .repeatOne: return .list
        }
    }
}

public enum ServerConnectionViewState: Equatable, Sendable {
    case idle
    case connecting(ServerConnectionStage)
    case connected(account: ServerAccount, serverType: String?, serverVersion: String?, trackCount: Int)
    case failed(String)

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var serverType: String? {
        if case .connected(_, let type, _, _) = self { return type }
        return nil
    }

    public var account: ServerAccount? {
        if case .connected(let account, _, _, _) = self { return account }
        return nil
    }
}

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case library
    case assistant
    case search
    case settings

    /// 紧凑设备的主 Dock。搜索保留为助手内的兜底能力，不再占用一级入口。
    public static let compactDockSections: [AppSection] = [.home, .library, .assistant]

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: String(localized: "首页", bundle: .module)
        case .library: String(localized: "音乐库", bundle: .module)
        case .assistant: String(localized: "AI 助手", bundle: .module)
        case .search: String(localized: "搜索", bundle: .module)
        case .settings: String(localized: "设置", bundle: .module)
        }
    }
    public var symbol: String {
        switch self {
        case .home: "house.fill"
        case .library: "square.stack.fill"
        case .assistant: "sparkles"
        case .search: "magnifyingglass"
        case .settings: "gearshape.fill"
        }
    }
}

public enum InspectorSection: String, CaseIterable, Identifiable, Sendable {
    case queue
    case lyrics
    case quality
    case metadata
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .queue: String(localized: "队列", bundle: .module)
        case .lyrics: String(localized: "歌词", bundle: .module)
        case .quality: String(localized: "音质", bundle: .module)
        case .metadata: String(localized: "元数据", bundle: .module)
        }
    }
}

/// 目录实体的 GlobalID 去重（保持顺序）。
///
/// 服务端偶发会对同一实体返回重复条目；跨服务器时相同 remoteID 也绝不代表同一实体。
/// Track / Artist / Album 在进入 catalog 前统一按 `(serverID, remoteID)` 收敛，
/// 否则 SwiftUI 的 ForEach(id:) 会因 duplicate identity 在运行期崩溃。
/// 纯逻辑、可单测；Artist 页面/列表即使不经过 catalog 也能用同一 helper 防御。
enum CatalogEntityUniquing {
    static func uniquedTracks(_ tracks: [Track]) -> [Track] {
        var seen = Set<GlobalID>()
        return tracks.filter {
            seen.insert(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)).inserted
        }
    }

    static func uniquedArtists(_ artists: [Artist]) -> [Artist] {
        var seen = Set<GlobalID>()
        return artists.filter {
            seen.insert(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)).inserted
        }
    }

    static func uniquedAlbums(_ albums: [Album]) -> [Album] {
        var seen = Set<GlobalID>()
        return albums.filter {
            seen.insert(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)).inserted
        }
    }
}

/// 浏览目标：专辑、艺术家、单个歌单、歌单总览、收藏与最常听、流派和 AI 分类。
public enum BrowseDestination: Identifiable, Hashable, Sendable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case playlists
    case favorites
    case mostPlayed
    case genre(Genre)
    case recommendationCategory(RecommendationIndexV2Category)
    case random
    case recentlyPlayed
    case recentlyAdded
    case longUnplayed
    case neverPlayed
    case favoriteRandom
    case topArtists
    case topAlbums
    case downloads
    public var id: String {
        switch self {
        case let .album(a): return "album.\(a.id.rawValue)"
        case let .artist(a): return "artist.\(a.id.rawValue)"
        case let .playlist(p): return "playlist.\(p.id.rawValue)"
        case .playlists: return "playlists"
        case .favorites: return "favorites"
        case .mostPlayed: return "mostPlayed"
        case let .genre(g): return "genre.\(g.id)"
        case let .recommendationCategory(category): return "recommendationCategory.\(category.id)"
        case .random: return "random"
        case .recentlyPlayed: return "recentlyPlayed"
        case .recentlyAdded: return "recentlyAdded"
        case .longUnplayed: return "longUnplayed"
        case .neverPlayed: return "neverPlayed"
        case .favoriteRandom: return "favoriteRandom"
        case .topArtists: return "topArtists"
        case .topAlbums: return "topAlbums"
        case .downloads: return "downloads"
        }
    }
}