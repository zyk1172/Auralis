import AIKit
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
    @Published public var currentTrack: Track
    /// 迷你播放器是否应显示：仅在存在真实曲目（非未连接时的占位曲目）时展示，
    /// 这样未连接服务器时底部不会留出无意义的迷你播放器高度，也不会与 Tab Bar 叠出多余留白。
    /// 用户是否希望显示迷你播放条（设置项，持久化到 UserDefaults，默认 true）。
    /// 设为 false 时，即便有正在播放的曲目，底部也只保留主菜单栏、不显示迷你播放条，
    /// 给内容（如 AI 助手的输入框）让出更多空间。
    @Published public var showMiniPlayer: Bool = true {
        didSet { defaults.set(showMiniPlayer, forKey: Self.showMiniPlayerDefaultsKey) }
    }
    /// AI 助手输入框的草稿文本。提升到模型层是为了让底部 Dock（iOS）
    /// 与助手页面（macOS）共用同一份输入，避免嵌套 safeAreaInset 造成的布局重叠。
    @Published public var assistantDraft: String = ""
    /// 迷你播放器是否应显示：仅在存在真实曲目（非未连接时的占位曲目）且用户未关闭时展示，
    /// 这样未连接服务器时底部不会留出无意义的迷你播放条高度，也不会与 Tab Bar 叠出多余留白。
    public var isMiniPlayerVisible: Bool { currentTrack.id.rawValue != "placeholder" && showMiniPlayer }
    @Published public var playbackState: PlaybackState = .paused
    @Published public var playbackPosition: TimeInterval = 0
    /// 播放队列。SwiftUI 的 ForEach / List 要求元素 id 唯一，队列里出现重复 TrackID 时
    /// 会在渲染期直接 fatalError（EXC_BREAKPOINT）→ 点击歌曲/打开播放队列即闪退。
    /// 这里在每次写入时强制去重（保留首次出现的位置），从根源杜绝重复 id 进入界面。
    /// 这样即便调用方（加入队列 / 下一首播放 / AI 代理 / 首页货架）忘记去重，也不会崩溃。
    @Published public var queue: [Track] {
        didSet {
            let unique = uniquedTracks(queue)
            if unique.count != queue.count { queue = unique }
            // 队列是播放会话的一部分：变更即持久化（按服务器隔离），
            // 进程重启后可恢复上次的队列与当前曲目。
            persistPlaybackSession()
        }
    }
    @Published public var isNowPlayingPresented = false
    @Published public var shouldPresentServerSetup = false
    @Published public var browseDestination: BrowseDestination?
    /// 首页布局偏好（模块显示 / 排序）。持久化到 UserDefaults（HomeLayoutStore），
    /// App 完全退出重开仍保留；「恢复默认布局」只重置这一份偏好，不删任何数据。
    @Published public private(set) var homeLayout: HomeLayoutPreference
    @Published public var inspector: InspectorSection = .queue
    @Published public private(set) var serverConnectionState: ServerConnectionViewState = .idle
    /// 服务器认证是否可能已失效（流播放返回 authorizationFailed 时置位，
    /// 成功连接 / 切换服务器后清除）。用于提示用户重新登录。
    @Published public private(set) var serverAuthenticationFailed = false
    @Published public private(set) var serverCapabilities = ServerCapabilities()
    @Published public private(set) var catalog: LibraryCatalog
    /// 已加载的服务器封面缓存（独立 @Observable 存储，键为 "serverID|封面Key@像素尺寸"）。
    /// 故意不放进 @Published：封面按需加载完成时写 @Published 会触发包括首页在内的所有
    /// model 观察者整体重算，滚动时大量封面陆续到达形成刷新风暴，导致上下滑动卡顿与
    /// "cannot add handler … dropping" 日志刷屏。独立存储只刷新真正读取封面的视图。
    let artworkStore = ArtworkStore()
    /// 循环模式，持久化到 UserDefaults。
    @Published public var repeatMode: RepeatMode {
        didSet {
            defaults.set(repeatMode.rawValue, forKey: Self.repeatModeDefaultsKey)
            mediaIntegration.modeChanged(isShuffled: isShuffled, repeatMode: repeatMode)
        }
    }
    /// 播放速度 0.5...2.0（默认 1.0），持久化到 UserDefaults。
    @Published public private(set) var playbackRate: Float = 1.0
    private static let playbackRateDefaultsKey = "auralis.playbackRate"
    /// 播放器音量 0...1，持久化到 UserDefaults。
    @Published public private(set) var volume: Float
    /// macOS 侧边栏搜索框的查询词（搜索页实时使用）。
    @Published public var macSearchQuery: String = ""
    /// 本地播放次数统计（组合键 "serverID:trackID" → 次数），按服务器隔离，
    /// 避免两台服务器同 ID 歌曲串库（P0-5）。驱动首页「最常听」。
    @Published public private(set) var playCountStorage: [String: Int] = [:]

    /// 当前活跃服务器下的播放次数（trackID → 次数）。跨服务器查询时为空。
    public var playCounts: [TrackID: Int] {
        guard let serverID = catalog.activeServerID else { return [:] }
        let prefix = serverID.rawValue + ":"
        return Dictionary(uniqueKeysWithValues: playCountStorage.compactMap { key, count in
            guard key.hasPrefix(prefix) else { return nil }
            return (TrackID(rawValue: String(key.dropFirst(prefix.count))), count)
        })
    }
    /// 已下载到本地的歌曲。
    @Published public private(set) var downloadedTrackIDs: Set<GlobalID> = []
    /// 正在下载的歌曲。
    @Published public private(set) var downloadingTrackIDs: Set<GlobalID> = []
    /// 下载进度（0...1）。保留裸 TrackID 键以兼容 PlayerViews（非写权限文件）；
    /// DownloadManager 内部按裸 TrackID 串行化下载，进度键不会跨服务器并发冲突。
    @Published public private(set) var downloadingProgress: [TrackID: Double] = [:]
    /// 裸 TrackID → GlobalID 的下载映射（DownloadManager 回调用裸 TrackID，P0-1 隔离）。
    private var downloadGlobalIDs: [TrackID: GlobalID] = [:]
    /// 随机播放模式，持久化到 UserDefaults。
    @Published public private(set) var isShuffled: Bool {
        didSet {
            defaults.set(isShuffled, forKey: Self.shuffleDefaultsKey)
            mediaIntegration.modeChanged(isShuffled: isShuffled, repeatMode: repeatMode)
        }
    }
    /// 最近播放的曲目 ID（最近在前），持久化到 UserDefaults，驱动首页「最近播放」。
    /// 最近播放的曲目组合键（"serverID:trackID"，最近在前），按服务器隔离持久化。
    @Published private var recentPlayedKeys: [String] = []

    /// 最近播放的曲目 ID（最近在前，按当前服务器过滤，避免两台服务器同 ID 歌曲混在一起）。
    public var recentlyPlayedIDs: [TrackID] {
        guard let serverID = catalog.activeServerID else { return [] }
        return recentPlayedKeys.compactMap { key -> TrackID? in
            guard let gid = GlobalID(key), gid.serverID == serverID else { return nil }
            return TrackID(rawValue: gid.remoteID)
        }
    }

    /// 播放会话持久化快照（按服务器隔离，存 UserDefaults）：当前曲目、队列、进度。
    /// 故意不保存「正在播放」标记——进程重启后恢复为暂停，由用户点击播放继续。
    private struct PlaybackSessionSnapshot: Codable, Sendable, Equatable {
        var currentTrackID: String?
        var queueTrackIDs: [String]
        var position: TimeInterval
        var updatedAt: Date

        init(currentTrackID: String?, queueTrackIDs: [String], position: TimeInterval, updatedAt: Date = .now) {
            self.currentTrackID = currentTrackID
            self.queueTrackIDs = queueTrackIDs
            self.position = position
            self.updatedAt = updatedAt
        }
    }
    /// 已缓存歌单的完整曲目（按歌单 ID 索引），从服务器按需拉取。
    @Published public private(set) var playlistTracks: [PlaylistID: [Track]] = [:]
    /// 正在加载曲目的歌单 ID。
    @Published public private(set) var loadingPlaylistIDs: Set<PlaylistID> = []
    /// 随机音乐（首页「随机音乐」货架）：资料库载入时随机采样一次，避免界面频繁重排。
    @Published public private(set) var randomTracks: [Track] = []
    /// 首页「收藏 / 最常听 / 最近播放 / 最近添加」货架快照。
    /// 只在数据真正变化时刷新（资料库同步 / 播放记录 / 收藏切换），
    /// 避免滚动等场景下每次 body 重算都全库过滤 + 排序一遍——大曲库时
    /// 这是首页上下滑动卡顿的重要来源之一。
    @Published public private(set) var homeFavoriteTracks: [Track] = []
    @Published public private(set) var homeMostPlayedTracks: [Track] = []
    @Published public private(set) var homeRecentlyPlayedTracks: [Track] = []
    @Published public private(set) var homeRecentlyAddedTracks: [Track] = []
    /// 首页「很久没听」：播放过但较久未播放（快照，见 refreshHomeSnapshots 的规则注释）。
    @Published public private(set) var homeLongUnplayedTracks: [Track] = []
    /// 首页「从未播放」：播放次数为 0 且不在播放历史（快照）。
    @Published public private(set) var homeNeverPlayedTracks: [Track] = []
    /// 首页「收藏里随便听」：从真实收藏随机采样（刷新时采样一次，换一批时重新采样）。
    @Published public private(set) var homeFavoriteRandomTracks: [Track] = []
    /// 首页「最近添加」：近 30 天真正新增的歌曲（数量显示「近30天新增 N 首」，而非全库总数）。
    @Published public private(set) var homeRecentlyAdded30DaysTracks: [Track] = []
    /// 首页「常听艺术家 / 常听专辑」：按真实播放次数聚合（仅含播放过的）。
    @Published public private(set) var homeTopArtists: [Artist] = []
    @Published public private(set) var homeTopAlbums: [Album] = []
    /// 常听艺术家 / 常听专辑的累计播放次数（供详情页显示「N 次播放」）。
    @Published public private(set) var homeTopArtistPlayCounts: [ArtistID: Int] = [:]
    @Published public private(set) var homeTopAlbumPlayCounts: [AlbumID: Int] = [:]
    /// 流派详情从服务器按需拉取的歌曲（本地按曲目标签筛选为空时回退到服务器）。
    @Published public private(set) var genreTracks: [Track]? = nil
    /// 当前正在按流派从服务器加载的流派；为 nil 表示没有进行中的加载。
    @Published public private(set) var loadingGenre: Genre? = nil
    /// 播放错误（streamURL 为 nil 等），供 UI 展示提示。
    @Published public private(set) var playbackError: PlaybackError? = nil
    /// 每首曲目首次进入本地目录的时间，用于首页「最近添加」排序。仅进程内使用，持久化在 UserDefaults。
    private var libraryAddedAt: [TrackID: Date] = [:]

    /// 系统媒体集成（Now Playing / 远程命令 / 中断与路由）。
    public let mediaIntegration = SystemMediaIntegrationController()

    /// 本地音乐目录（SQLite + FTS5）与同步生命周期。首次访问时惰性创建。
    /// 曲库分类索引文件（Agent 按需读取；同步完成后刷新）。
    public private(set) lazy var libraryCatalogIndex = LibraryCatalogIndexStore(
        directoryURL: LibraryCatalogIndexStore.defaultDirectory()
    )
    public private(set) lazy var catalogCoordinator: CatalogCoordinator = {
        let coordinator = CatalogCoordinator(
            connector: connector,
            storeURL: storeURL,
            trackCache: cacheStore,
            lyricsCache: lyricsCache
        )
        // 同步完成后刷新曲库分类索引文件，让 Agent 始终能读到最新元数据。
        coordinator.onSyncCompleted = { [weak self] serverID, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.libraryCatalogIndex.refresh(
                    serverID: serverID,
                    catalog: self.catalogCoordinator.store
                )
            }
        }
        return coordinator
    }()
    /// AI 助手运行时（会话 / 工具调用 / 确认 / 操作日志 / 偏好）。
    public private(set) lazy var agentCoordinator = AgentCoordinator(
        model: self,
        coordinator: catalogCoordinator
    )

    private let engine: any PlaybackControlling
    private let connector: any ServerConnecting
    private let cacheStore: TrackCacheStore
    private let downloadManager: DownloadManager
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
    private var lyricsInFlight: Set<TrackID> = []
    private var lyricsUnavailable: Set<TrackID> = []
    private var artworkInFlight: Set<String> = []
    /// 限制同时进行的封面网络请求数，避免服务器不可达时一次性发起几十条
    /// 挂起请求、淹没网络与控制台。
    private let artworkLimiter = ArtworkConcurrencyLimiter(max: 6)
    /// 当前播放任务，用于取消之前的播放操作（快速切歌时避免竞态条件）。
    private var playbackTask: Task<Void, Never>?
    /// Handoff 活动：把当前播放（歌曲/队列/进度）接力到其他 Apple 设备。
    /// 只携带必要标识（serverID + trackID + 队列 ID + 进度），不含凭据 / 地址 / 文件路径。
    private static let handoffActivityType = "com.auralis.player.playback"
    private var handoffActivity: NSUserActivity?
    /// 当前曲目流地址失败重试次数（selectAndPlay 时清零），避免无限重试。
    private var streamRetryAttempts: [TrackID: Int] = [:]
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
            case .off: String(localized: "关闭")
            case .afterMinutes: String(localized: "若干分钟后停止")
            case .afterCurrentTrack: String(localized: "当前歌曲结束后停止")
            case .afterCurrentAlbum: String(localized: "当前专辑结束后停止")
            case .afterCurrentQueue: String(localized: "当前队列结束后停止")
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
    /// Siri / URL Scheme 传入的待播放请求（歌曲名/歌手名；空字符串表示「播放音乐」）。
    /// 资料库尚未恢复（冷启动）时先暂存，待 apply() 恢复资料库后再消费，
    /// 避免找不到曲目。
    private var pendingSiriQuery: String?
    /// Siri 媒体项携带的精确 GlobalID（Intents 扩展从共享资料库解析而来）。
    private var pendingSiriGlobalID: GlobalID?

    private static let playCountsDefaultsKey = "auralis.playCounts"
    private static let volumeDefaultsKey = "auralis.volume"
    private static let repeatModeDefaultsKey = "auralis.repeatMode"
    private static let shuffleDefaultsKey = "auralis.isShuffled"
    private static let lastTrackDefaultsKey = "auralis.lastTrackID"
    private static let recentlyPlayedDefaultsKey = "auralis.recentlyPlayed"
    private static let libraryAddedDefaultsKey = "auralis.libraryAdded"
    private static let showMiniPlayerDefaultsKey = "auralis.ui.showMiniPlayer"
    private static func playbackSessionKey(_ serverID: ServerID) -> String {
        "auralis.playbackSession.\(serverID.rawValue)"
    }

    /// 上次活跃服务器 ID（UserDefaults），用于冷启动与切换服务器时恢复正确的资料库。
    private static let lastActiveServerKey = "auralis.lastActiveServer"

    public init(
        catalog: LibraryCatalog = .empty,
        engine: any PlaybackControlling = AVFoundationPlaybackEngine(),
        connector: any ServerConnecting = ApplicationComposition.makeServerConnector(),
        cacheStore: TrackCacheStore = TrackCacheStore(),
        artworkCache: ArtworkDiskCache = ArtworkDiskCache(),
        lyricsCache: LyricsDiskCache = LyricsDiskCache(),
        defaults: UserDefaults = .standard,
        storeURL: URL? = nil
    ) {
        self.catalog = catalog
        self.engine = engine
        self.connector = connector
        self.cacheStore = cacheStore
        self.artworkCache = artworkCache
        self.lyricsCache = lyricsCache
        self.defaults = defaults
        self.storeURL = storeURL
        self.queue = []
        let storedRate = defaults.object(forKey: Self.playbackRateDefaultsKey) as? Double
        self.playbackRate = Float(min(max(storedRate ?? 1.0, 0.5), 2.0))
        let storedVolume = defaults.object(forKey: Self.volumeDefaultsKey) as? Double
        self.volume = Float(storedVolume ?? 0.8)
        let storedCounts = defaults.dictionary(forKey: Self.playCountsDefaultsKey) as? [String: Int] ?? [:]
        // 旧版本按裸 trackID 存储（无 ":" 分隔），无法归属服务器，直接丢弃避免串库。
        self.playCountStorage = storedCounts.filter { $0.key.contains(":") }
        self.lastStopReason = PlaybackStopReason(
            rawValue: defaults.string(forKey: Self.lastStopReasonDefaultsKey) ?? ""
        ) ?? .unknown
        self.recentSearches = defaults.array(forKey: Self.recentSearchesDefaultsKey) as? [String] ?? []
        self.repeatMode = RepeatMode(rawValue: defaults.string(forKey: Self.repeatModeDefaultsKey) ?? "") ?? .off
        self.isShuffled = defaults.bool(forKey: Self.shuffleDefaultsKey)
        self.showMiniPlayer = (defaults.object(forKey: Self.showMiniPlayerDefaultsKey) as? Bool) ?? true
        // 首页布局偏好：无配置时用默认布局，读取时自动归一化并补齐新模块。
        self.homeLayout = HomeLayoutStore.load(from: defaults)
        // 最近播放按「serverID:trackID」组合键存储；旧格式（纯 trackID，无冒号）无法归属服务器，直接丢弃。
        let storedRecent = defaults.array(forKey: Self.recentlyPlayedDefaultsKey) as? [String] ?? []
        self.recentPlayedKeys = storedRecent.filter { $0.contains(":") }
        let storedAdded = defaults.dictionary(forKey: Self.libraryAddedDefaultsKey) as? [String: Double] ?? [:]
        self.libraryAddedAt = Dictionary(uniqueKeysWithValues: storedAdded.map { (TrackID(rawValue: $0.key), Date(timeIntervalSince1970: $0.value)) })
        if let first = catalog.tracks.first {
            self.currentTrack = first
        } else {
            // 未连接服务器时的占位 track
            self.currentTrack = Track(
                id: "placeholder", serverID: "local",
                albumID: "placeholder", artistID: "placeholder",
                title: "请先连接服务器", artistName: "", albumTitle: "", duration: 0
            )
        }
        // 下载管理器：init 期不捕获 self，回调在下方 Task（init 完成）中注入。
        self.downloadManager = DownloadManager(store: cacheStore)

        // 安装崩溃日志处理器（仅首次）
        CrashLog.shared.installHandlers()
        let activity = NSUserActivity(activityType: Self.handoffActivityType)
        activity.title = "Auralis 播放"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.requiredUserInfoKeys = ["serverID", "currentTrackID", "queueTrackIDs", "position"]
        handoffActivity = activity
        startMediaIntegration()
        Task { [self] in
            // init 完成后注入下载状态回调。
            self.downloadManager.onStateChange = { [weak self] trackID, status, progress in
                Task { @MainActor in
                    guard let self else { return }
                    // DownloadManager 回调仍使用裸 TrackID；经 download() 登记的映射
                    // 还原成 GlobalID（P0-1 多服务器隔离）。
                    guard let globalID = self.downloadGlobalIDs[trackID] else { return }
                    switch status {
                    case .downloading:
                        self.downloadingTrackIDs.insert(globalID)
                        self.downloadingProgress[trackID] = progress
                    case .downloaded:
                        self.downloadingTrackIDs.remove(globalID)
                        self.downloadingProgress[trackID] = nil
                        self.downloadedTrackIDs.insert(globalID)
                        self.downloadGlobalIDs[trackID] = nil
                    case .failed, .notDownloaded:
                        self.downloadingTrackIDs.remove(globalID)
                        self.downloadingProgress[trackID] = nil
                        self.downloadGlobalIDs[trackID] = nil
                    case .queued:
                        break
                    }
                }
            }
            await engine.setVolume(volume)
            await engine.setRate(playbackRate)
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
            downloadedTrackIDs = Set(await cacheStore.cachedTrackIDs().map {
                GlobalID(serverID: $0.serverID, remoteID: $0.trackID.rawValue)
            })
        }
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
        guard mode != .off else { return }
        if mode == .afterMinutes {
            let duration = max(minutes, 0.1)
            sleepTimerEndsAt = Date().addingTimeInterval(duration * 60)
            sleepTimerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration * 60))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.stopForSleepTimer(reason: .userStopped) }
            }
        }
    }

    /// 取消睡眠定时。
    public func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMode = .off
        sleepTimerEndsAt = nil
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
            if let index = queue.firstIndex(where: { $0.id == currentTrack.id }),
               queue.indices.contains(index + 1),
               queue[index + 1].albumID == currentTrack.albumID {
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
            self.persistPlaybackSession()
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
                    guard let self, self.currentTrack.duration > 0 else { return }
                    self.seek(toProgress: position / self.currentTrack.duration)
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
    private func executeSiriIntent(_ raw: String) async {
        switch parseSiriIntent(raw) {
        case .playMusic:
            if playbackState == .playing { return }
            if currentTrack.id.rawValue != "placeholder" {
                togglePlayback()
            } else if let first = queue.first ?? catalog.tracks.first {
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
                playTracks(list.isEmpty ? Array(catalog.tracks.prefix(20)) : list)
            } else {
                playTracks(favorites)
            }
        case .playRecent:
            let recent = recentlyPlayedTracks
            if recent.isEmpty {
                // 没有最近播放记录时退到收藏 / 随机，避免 Siri 报失败。
                let favorites = favoriteTracks
                playTracks(favorites.isEmpty ? Array(catalog.tracks.prefix(20)) : favorites)
            } else {
                playTracks(recent)
            }
        case .playRandom:
            playTracks(Array(catalog.tracks.shuffled().prefix(30)))
        case let .playGenre(name):
            let tracks = tracks(for: Genre(name: name, songCount: 0))
            if tracks.isEmpty {
                // 本地流派为空时按需从服务器拉取该流派歌曲。
                let serverTracks = await connector.tracks(byGenre: name)
                playTracks(serverTracks)
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
        let fetched = await connector.fetchPlaylistTracks(playlistID: playlist.id)
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
    private func currentArtworkData() -> Data? {
        guard let key = currentTrack.artworkKey else { return nil }
        // Now Playing 只需要一张中等尺寸封面
        for size in [620, 284, 264, 96] {
            if let image = artworkStore.image(forKey: artworkCacheKey(key, size)) {
                #if os(macOS)
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    return png
                }
                #else
                if let png = image.pngData() { return png }
                #endif
            }
        }
        return nil
    }

    /// 切歌后同步 Now Playing 全量信息（含队列位置 / 总数，控制中心可显示）。
    private func syncNowPlayingTrack() {
        let queueIndex = queue.firstIndex(where: { $0.id == currentTrack.id })
        mediaIntegration.trackChanged(
            currentTrack,
            position: playbackPosition,
            isPlaying: playbackState == .playing,
            artworkData: currentArtworkData(),
            queueIndex: queueIndex,
            queueCount: queue.count,
            rate: playbackState == .playing ? playbackRate : 0
        )
        updateHandoffActivity()
    }

    /// 更新 Handoff 活动：把当前播放接力到其他设备（不自动出声，由接收端用户点击播放）。
    private func updateHandoffActivity() {
        guard let serverID = catalog.activeServerID,
              currentTrack.id.rawValue != "placeholder",
              let activity = handoffActivity
        else { return }
        activity.title = "\(currentTrack.title) · \(currentTrack.artistName)"
        activity.userInfo = [
            "serverID": serverID.rawValue,
            "currentTrackID": currentTrack.id.rawValue,
            "queueTrackIDs": queue.map(\.id.rawValue),
            "position": playbackPosition,
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
        var seen = Set<TrackID>()
        if let ids = info["queueTrackIDs"] as? [String] {
            for id in ids {
                if let track = trackByID[id], seen.insert(track.id).inserted {
                    restoredQueue.append(track)
                }
            }
        }
        guard !restoredQueue.isEmpty else { return }
        queue = restoredQueue
        if let currentRaw = info["currentTrackID"] as? String, let current = trackByID[currentRaw] {
            if !queue.contains(where: { $0.id == current.id }) { queue.insert(current, at: 0) }
            currentTrack = current
        } else {
            currentTrack = restoredQueue[0]
        }
        let position = (info["position"] as? Double) ?? 0
        let duration = currentTrack.duration > 0 ? currentTrack.duration : position
        playbackPosition = min(max(position, 0), duration)
        playbackState = .idle
        loadLyricsIfNeeded(for: currentTrack)
        persistPlaybackSession()
    }

    public var currentLyrics: LyricsDocument? { catalog.lyrics[currentTrack.id] }

    /// 0...1 playback progress of the current track.
    public var playbackProgress: Double {
        get {
            guard currentTrack.duration > 0 else { return 0 }
            return min(max(playbackPosition / currentTrack.duration, 0), 1)
        }
        set { seek(toProgress: newValue) }
    }

    public var hasNext: Bool {
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return false }
        return queue.indices.contains(index + 1)
    }

    /// 列表循环时到队尾还能绕回第一首，下一首按钮不置灰。
    public var canGoNext: Bool {
        hasNext || (repeatMode == .all && queue.count > 1)
    }

    public var hasPrevious: Bool {
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return false }
        return queue.indices.contains(index - 1)
    }

    /// 播放一组曲目（用于 macOS 表格「播放全部」等）。
    public func playQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        selectAndPlay(tracks[0])
    }

    /// 随机播放（30 首）。
    public func playRandom() {
        let tracks = Array(catalog.tracks.shuffled().prefix(30))
        guard !tracks.isEmpty else { return }
        queue = tracks
        selectAndPlay(tracks[0])
    }

    /// 把歌曲加入队列末尾（macOS 表格右键 / 双击等）。
    public func addToQueue(globalID: GlobalID) {
        guard let track = catalog.tracks.first(where: { $0.id.rawValue == globalID.remoteID }),
              !queue.contains(where: { $0.id == track.id }) else { return }
        queue.append(track)
    }

    /// 下一首播放：插入到当前歌曲之后。
    public func playNext(globalID: GlobalID) {
        guard let track = catalog.tracks.first(where: { $0.id.rawValue == globalID.remoteID }) else { return }
        queue.removeAll { $0.id == track.id }
        if let index = queue.firstIndex(where: { $0.id == currentTrack.id }) {
            queue.insert(track, at: index + 1)
        } else {
            queue.insert(track, at: 0)
        }
    }

    public func selectAndPlay(_ track: Track) {
        CrashLog.shared.log("selectAndPlay 开始: \(track.title) (id=\(track.id.rawValue))")
        streamRetryAttempts.removeValue(forKey: track.id)
        currentTrack = track
        playbackPosition = 0
        if !queue.contains(where: { $0.id == track.id }) { queue.insert(track, at: 0) }
        // 播放时自动缓存：当前歌曲的歌词 + 专辑封面（loadArtwork 在 UI 请求时落盘），
        // 并预缓存队列接下来几首的封面缩略图与歌词（写磁盘，不占内存）。
        loadLyricsIfNeeded(for: track)
        recordPlay(for: track)

        // ── 关键安全守卫 ──
        // 手势回调在 com.apple.uikit.eventdispatch 队列上执行（非 Thread 1 主线程）。
        // AVPlayer / MPNowPlayingInfoCenter / FIGApplicationStateMonitor 等 Apple 内部框架
        // 会通过 _dispatch_assert_queue_fail 断言自己必须在主线程上运行。
        // 若直接在 Task {} 里调用 engine.play() / syncNowPlayingTrack()，
        // 继承的 @MainActor 仍可能落在 eventdispatch 队列上 → EXC_BREAKPOINT 崩溃。
        // 因此把所有媒体操作 DispatchQueue.main.async 到下一轮 RunLoop，
        // 确保它们在 Thread 1 上执行。
        //
        // 快速切歌时取消之前的播放任务，避免多个 engine.play() 并发导致竞态条件和卡死。
        playbackTask?.cancel()
        CrashLog.shared.log("取消之前的播放任务，创建新任务")
        playbackTask = Task { @MainActor in
            // 先立即同步控制中心 / 锁屏 / 灵动岛：即使歌曲还在缓冲，也先显示歌曲信息，
            // 避免「播放了但控制中心看不到」。播放成功后再刷新进度。
            self.syncNowPlayingTrack()

            // 已下载的歌曲优先播放本地缓存文件
            var playable = track
            if let localURL = await self.cacheStore.cachedFileURL(for: self.cacheID(for: track)) {
                playable.streamURL = localURL
                // 不记录本地文件路径（隐私：完整路径不得进日志/诊断）。
                CrashLog.shared.log("使用本地缓存播放")
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
                CrashLog.shared.log("engine.play 失败: \(error)")
                self.playbackError = error as? PlaybackError
                switch error as? PlaybackError {
                case .networkUnavailable: self.lastStopReason = .networkInterrupted
                case .unsupportedFormat: self.lastStopReason = .decodeFailed
                case .authorizationFailed:
                    self.lastStopReason = .serverDisconnected
                    self.serverAuthenticationFailed = true
                case .engineFailure: self.lastStopReason = .streamExpired
                case nil: self.lastStopReason = .unknown
                }
            }
            self.playbackState = await self.engine.state()
            CrashLog.shared.log("播放状态: \(String(describing: self.playbackState))")
            self.syncProgressTimer()
            self.syncNowPlayingTrack()
        }
    }

    // MARK: - Repeat / Shuffle / Volume

    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
    }

    /// 组合播放模式：单个按钮循环切换「列表顺序 → 随机播放 → 循环播放」。
    /// 随机与循环不再是两个独立按钮，而是同一状态机的三种表现。
    public var playMode: PlayMode {
        if isShuffled { return .shuffle }
        if repeatMode != .off { return .loop }
        return .list
    }

    /// 切换播放模式：列表 → 随机 → 循环 → 列表。
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
        case .loop:
            isShuffled = false
            repeatMode = .all
        }
    }

    public func setShuffle(_ enabled: Bool) {
        isShuffled = enabled
    }

    public func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        defaults.set(Double(clamped), forKey: Self.volumeDefaultsKey)
        Task { await engine.setVolume(clamped) }
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
        randomTracks = Array(tracks.shuffled().prefix(18))
    }


    // MARK: - 首页布局偏好（可编辑首页）

    /// 开启 / 关闭某个首页模块。只改布局偏好，不删除任何数据 / 缓存 / 播放记录。
    /// 关闭的模块首页完全不渲染；「用户关闭」与「当前无数据」在渲染层区分：
    /// 这里只记录用户开关，数据为空时由 HomeView 暂不渲染但保持本配置开启。
    public func setHomeModuleVisible(_ moduleID: String, isVisible: Bool) {
        guard HomeModuleRegistry.module(forID: moduleID) != nil else { return }
        var layout = homeLayout
        func update(in group: HomeModuleGroup, keyPath: WritableKeyPath<HomeLayoutPreference, [HomeModulePreference]>) {
            var list = layout[keyPath: keyPath]
            guard let index = list.firstIndex(where: { $0.moduleID == moduleID }) else { return }
            list[index].isVisible = isVisible
            layout[keyPath: keyPath] = list
        }
        if HomeModuleRegistry.modules(in: .quickEntry).contains(where: { $0.id.rawValue == moduleID }) {
            update(in: .quickEntry, keyPath: \.quickEntries)
        } else {
            update(in: .content, keyPath: \.contentModules)
        }
        homeLayout = layout
        persistHomeLayout()
    }

    /// 拖动排序：把分组内 fromOffsets 位置的模块移动到 toOffset。顺序立即生效并持久化。
    /// 语义与 SwiftUI List.onMove 的 Array.move(fromOffsets:toOffset:) 一致：
    /// 目标下标按「先移除再插入」调整，避免 onMove 与自实现位移不一致导致排序错乱。
    public func moveHomeModule(in group: HomeModuleGroup, fromOffsets: IndexSet, toOffset: Int) {
        var layout = homeLayout
        switch group {
        case .quickEntry:
            layout.quickEntries = Self.reordered(layout.quickEntries, fromOffsets: fromOffsets, toOffset: toOffset)
        case .content:
            layout.contentModules = Self.reordered(layout.contentModules, fromOffsets: fromOffsets, toOffset: toOffset)
        }
        homeLayout = layout
        persistHomeLayout()
    }

    /// 复刻 Array.move(fromOffsets:toOffset:) 的位移语义（不依赖 SwiftUI 扩展，
    /// 模型层可独立测试）：倒序移除被移动元素，再按调整后的目标下标整体插回。
    private static func reordered<T>(_ array: [T], fromOffsets: IndexSet, toOffset: Int) -> [T] {
        guard !fromOffsets.isEmpty else { return array }
        let moving = array.indices.filter { fromOffsets.contains($0) }
        let target: Int
        if let first = moving.first, toOffset > first {
            target = toOffset - moving.count
        } else {
            target = toOffset
        }
        var result = array
        let removed: [T] = moving.reversed().map { result.remove(at: $0) }
        result.insert(contentsOf: removed.reversed(), at: min(target, result.count))
        return result
    }

    /// 编辑页整组写回首页布局（本地数组为权威，排序与开关一次提交）。
    /// 编辑页的 List 以本地 @State 数组为数据源，拖动/开关后整组提交，
    /// 避免 onMove 期间增量写 @Published 与 SwiftUI 集合视图移动事务竞争导致的崩溃。
    public func replaceHomeLayout(quickEntries: [HomeModulePreference], contentModules: [HomeModulePreference]) {
        homeLayout = HomeLayoutPreference(quickEntries: quickEntries, contentModules: contentModules)
        persistHomeLayout()
    }

    /// 恢复默认布局：仅重置首页布局偏好（HomeLayoutStore 键），不删任何数据 / 缓存 / 播放记录。
    public func resetHomeLayout() {
        homeLayout = HomeModuleRegistry.defaultPreference()
        persistHomeLayout()
    }

    private func persistHomeLayout() {
        HomeLayoutStore.save(homeLayout, to: defaults)
    }

    /// 重新采样「收藏里随便听」：只在本机收藏里本地随机，不发网络请求、不重新下载服务器资料。
    public func regenerateFavoriteRandomMusic() {
        homeFavoriteRandomTracks = favoriteRandomSample()
    }

    /// 从真实收藏随机采样 18 首。
    private func favoriteRandomSample() -> [Track] {
        Array(catalog.tracks.filter(\.isFavorite).shuffled().prefix(18))
    }

    /// 清除播放错误（供 UI 在展示后调用）。
    /// 播放失败后重试：刷新流地址（若可用）并重新播放当前曲目。
    public func retryPlayback() {
        dismissPlaybackError()
        guard currentTrack.id.rawValue != "placeholder" else { return }
        Task { @MainActor in
            var track = self.currentTrack
            if self.catalog.activeServerID != nil,
               let url = await self.connector.refreshStreamURL(trackID: track.id) {
                track.streamURL = url
            }
            self.selectAndPlay(track)
        }
    }

    public func dismissPlaybackError() {
        playbackError = nil
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
        isServerSearching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.serverSearchResults = await self.connector.serverSearch(query: trimmed, limit: 50)
            self.isServerSearching = false
        }
    }

    public func clearServerSearch() {
        serverSearchResults = []
        isServerSearching = false
    }

    /// 服务器在线搜索的可等待版本（Agent 工具用）：直接返回结果，不写 @Published 状态。
    public func searchOnServerAwaiting(query: String, limit: Int) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await connector.serverSearch(query: trimmed, limit: min(max(limit, 1), 100))
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

    private func recordPlay(for track: Track) {
        // 内存状态更新（主线程，即时生效，驱动 UI 刷新）。
        // 播放次数按「serverID:trackID」组合键隔离存储，避免跨服务器串库。
        let countKey = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue).description
        playCountStorage[countKey, default: 0] += 1
        // 最近播放按「serverID:trackID」组合键隔离存储：不同服务器同 ID 歌曲不会混在一起。
        let key = countKey
        // 彻底去重：不仅移除被点击的那一条，也清除历史遗留的重复 ID，
        // 否则最近播放列表 / 播放队列里会出现重复 id，触发 ForEach 运行期崩溃。
        var seen = Set<String>()
        var recent: [String] = []
        for existing in recentPlayedKeys where existing != key {
            if seen.insert(existing).inserted { recent.append(existing) }
        }
        recent.insert(key, at: 0)
        if recent.count > 100 { recent = Array(recent.prefix(100)) }
        recentPlayedKeys = recent

        // 持久化全部移到后台，避免同步磁盘 I/O 阻塞主线程导致
        // _dispatch_assert_queue_fail / Gesture gate timeout 崩溃。
        let storedCounts = playCountStorage
        let recentRaw = recent
        let trackID = track.id.rawValue
        Task { @Sendable [defaults] in
            defaults.set(storedCounts, forKey: Self.playCountsDefaultsKey)
            defaults.set(recentRaw, forKey: Self.recentlyPlayedDefaultsKey)
            defaults.set(trackID, forKey: Self.lastTrackDefaultsKey)
        }
        // 播放次数 / 最近播放变化后刷新首页「最常听 / 最近播放」快照。
        refreshHomeSnapshots()
    }

    // MARK: - Playback session persistence

    /// 保存当前播放会话（当前曲目、队列、进度），按服务器隔离。
    /// 只记录展示状态：不保存「正在播放」标记，进程重启后永远恢复为暂停。
    private func persistPlaybackSession() {
        guard let serverID = catalog.activeServerID else { return }
        let snapshot = PlaybackSessionSnapshot(
            currentTrackID: currentTrack.id.rawValue == "placeholder" ? nil : currentTrack.id.rawValue,
            queueTrackIDs: queue.map(\.id.rawValue),
            position: playbackPosition
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.playbackSessionKey(serverID))
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
        var seen = Set<TrackID>()
        for id in snapshot.queueTrackIDs {
            guard let track = trackByID[id], seen.insert(track.id).inserted else { continue }
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
        if !queue.contains(where: { $0.id == current.id }) { queue.insert(current, at: 0) }
        currentTrack = current
        let duration = current.duration > 0 ? current.duration : snapshot.position
        playbackPosition = min(max(snapshot.position, 0), duration)
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
            .filter { libraryAddedAt[$0.id].map { $0 >= cutoff } ?? false }
            .sorted { (libraryAddedAt[$0.id] ?? .distantPast) > (libraryAddedAt[$1.id] ?? .distantPast) }
    }

    public var recentlyAddedTracks: [Track] {
        let added = libraryAddedAt
        return catalog.tracks.sorted {
            (added[$0.id] ?? .distantPast) > (added[$1.id] ?? .distantPast)
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
        let tracks = catalog.tracks
        let counts = playCounts
        let recentIDs = recentlyPlayedIDs
        let recent = Set(recentIDs)
        let added = libraryAddedAt

        homeFavoriteTracks = tracks.filter(\.isFavorite)
        homeMostPlayedTracks = tracks
            .filter { (counts[$0.id] ?? 0) > 0 }
            .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
        homeRecentlyPlayedTracks = recentIDs.compactMap { id in
            tracks.first(where: { $0.id == id })
        }
        homeRecentlyAddedTracks = tracks.sorted {
            (added[$0.id] ?? .distantPast) > (added[$1.id] ?? .distantPast)
        }

        // 很久没听：播放过但不在最近 100 次播放内（规则见函数注释）。
        homeLongUnplayedTracks = Array(tracks
            .filter { (counts[$0.id] ?? 0) > 0 && !recent.contains($0.id) }
            .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
            .prefix(24))

        // 从未播放：播放次数为 0 且不在播放历史；展示排序用入库时间倒序。
        homeNeverPlayedTracks = Array(tracks
            .filter { (counts[$0.id] ?? 0) == 0 && !recent.contains($0.id) }
            .sorted { (added[$0.id] ?? .distantPast) > (added[$1.id] ?? .distantPast) }
            .prefix(24))

        // 最近添加（近 30 天）。
        homeRecentlyAdded30DaysTracks = Array(recentlyAddedTracks(inLastDays: 30).prefix(24))

        // 常听艺术家 / 常听专辑：一次遍历聚合，避免每个模块重复全表遍历。
        var artistTotals: [ArtistID: Int] = [:]
        var albumTotals: [AlbumID: Int] = [:]
        for track in tracks {
            let count = counts[track.id] ?? 0
            if count > 0 {
                artistTotals[track.artistID, default: 0] += count
                albumTotals[track.albumID, default: 0] += count
            }
        }
        homeTopArtistPlayCounts = artistTotals
        homeTopAlbumPlayCounts = albumTotals
        homeTopArtists = Array(catalog.artists
            .filter { (artistTotals[$0.id] ?? 0) > 0 }
            .sorted { (artistTotals[$0.id] ?? 0, $0.name) > (artistTotals[$1.id] ?? 0, $1.name) }
            .prefix(24))
        homeTopAlbums = Array(catalog.albums
            .filter { (albumTotals[$0.id] ?? 0) > 0 }
            .sorted { (albumTotals[$0.id] ?? 0, $0.title) > (albumTotals[$1.id] ?? 0, $1.title) }
            .prefix(24))

        // 收藏里随便听：从真实收藏随机采样一次。
        homeFavoriteRandomTracks = favoriteRandomSample()
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
        guard catalog.activeServerID != nil else { return }
        Task { [weak self, connector] in
            let serverGenres = await connector.genres()
            guard !serverGenres.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.mergeServerGenres(serverGenres)
            }
        }
    }

    /// 按流派从服务器加载歌曲（本地筛选为空时调用），结果写入 `genreTracks`。
    public func loadGenreTracks(_ genre: Genre) {
        guard loadingGenre?.name != genre.name else { return }
        loadingGenre = genre
        genreTracks = nil
        Task { [weak self] in
            guard let self else { return }
            let tracks = await connector.tracks(byGenre: genre.name)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if loadingGenre?.name == genre.name {
                    genreTracks = tracks
                    loadingGenre = nil
                }
            }
        }
    }

    /// 保持顺序、按 id 去重。服务端偶发会对同一首歌返回重复条目，
    /// 若直接喂给 SwiftUI 的 ForEach / List，会因 duplicate ID 在运行期 fatal error 崩溃。
    /// 全链路（队列、随机货架、最近添加、流派筛选）统一在此收敛，避免重复 ID 进入界面。
    func uniquedTracks(_ tracks: [Track]) -> [Track] {
        var seen = Set<TrackID>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Downloads

    /// Track 的 GlobalID（serverID:trackID），下载/缓存状态一律用它隔离（P0-1）。
    private func globalID(for track: Track) -> GlobalID {
        GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    }

    /// Track 的 TrackCacheStore 组合键（等价于 GlobalID.description）。
    private func cacheID(for track: Track) -> TrackCacheStore.TrackCacheID {
        TrackCacheStore.TrackCacheID(serverID: track.serverID, trackID: track.id)
    }

    /// 已下载到本地的曲目（首页「下载」快捷入口与下载浏览页的数据源）。
    public var downloadedTracks: [Track] {
        catalog.tracks.filter { downloadedTrackIDs.contains(globalID(for: $0)) }
    }

    public func isDownloaded(_ track: Track) -> Bool { downloadedTrackIDs.contains(globalID(for: track)) }

    /// 当前本地缓存中的全部曲目 ID（供缓存维护 / 陈旧缓存检测）。
    public func allCachedTrackIDs() async -> Set<GlobalID> {
        Set(await cacheStore.cachedTrackIDs().map {
            GlobalID(serverID: $0.serverID, remoteID: $0.trackID.rawValue)
        })
    }
    public func isDownloading(_ track: Track) -> Bool { downloadingTrackIDs.contains(globalID(for: track)) }

    /// 下载歌曲到本地缓存；完成后该歌曲优先本地播放。
    public func download(_ track: Track) {
        let globalID = globalID(for: track)
        guard !downloadedTrackIDs.contains(globalID), !downloadingTrackIDs.contains(globalID) else { return }
        Task { @MainActor in
            guard let url = await self.connector.downloadURL(trackID: track.id) else { return }
            // 同一裸 trackID 已有下载任务（可能属于另一台服务器）时不覆盖映射，
            // 避免完成回调把下载结果记到错误服务器；DownloadManager 内部按裸 trackID 串行化。
            guard !self.downloadManager.isDownloading(track.id) else { return }
            self.downloadGlobalIDs[track.id] = globalID
            self.downloadingTrackIDs.insert(globalID)
            self.downloadingProgress[track.id] = 0
            self.downloadManager.start(trackID: track.id, url: url, codec: track.sourceInfo.codec, serverID: track.serverID)
        }
    }

    /// 后台下载会话事件转发（系统在后台恢复下载后调用）。
    public func handleBackgroundDownloadEvents(identifier: String, completion: @escaping () -> Void) {
        // delegate 队列是主队列，completion 在 urlSessionDidFinishEvents 时直接调用。
        downloadManager.handleEventsForBackgroundURLSession(identifier: identifier, completion: completion)
    }

    /// 取消正在进行的下载。
    public func cancelDownload(_ track: Track) {
        downloadManager.cancel(track.id)
        downloadingTrackIDs.remove(globalID(for: track))
        downloadingProgress[track.id] = nil
        downloadGlobalIDs[track.id] = nil
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
        Task {
            try? await cacheStore.remove(for: cacheID(for: track))
            downloadedTrackIDs.remove(globalID(for: track))
        }
    }

    // MARK: - Playlists

    /// 把歌曲追加到服务器歌单，成功后同步更新本地歌单缓存。
    @discardableResult
    public func addToPlaylist(_ playlist: Playlist, track: Track) async -> Bool {
        let succeeded = await connector.addToPlaylist(playlistID: playlist.id, trackID: track.id)
        if succeeded,
           let index = catalog.playlists.firstIndex(where: { $0.id == playlist.id }),
           !catalog.playlists[index].trackIDs.contains(track.id) {
            catalog.playlists[index].trackIDs.append(track.id)
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
        guard let playlist = await connector.createPlaylist(name: trimmed, trackIDs: trackIDs) else { return nil }
        if let index = catalog.playlists.firstIndex(where: { $0.id == playlist.id }) {
            catalog.playlists[index] = playlist
        } else {
            catalog.playlists.append(playlist)
        }
        // 新歌单立即可见：写入 SQLite，后续「把歌曲加入这个歌单」才能解析到该歌单 ID。
        if let serverID = catalog.activeServerID {
            persistServerPlaylists(catalog.playlists, serverID: serverID)
        }
        return playlist
    }

    /// 重命名歌单。
    @discardableResult
    public func renamePlaylist(id: PlaylistID, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let succeeded = await connector.renamePlaylist(playlistID: id, name: trimmed)
        if succeeded, let index = catalog.playlists.firstIndex(where: { $0.id == id }) {
            catalog.playlists[index].name = trimmed
            if let serverID = catalog.activeServerID {
                persistServerPlaylists(catalog.playlists, serverID: serverID)
            }
        }
        return succeeded
    }

    /// 按下标批量移除歌单中的曲目（曲目本身仍留在音乐库）。
    @discardableResult
    public func removeFromPlaylist(id: PlaylistID, atIndices indices: [Int]) async -> Bool {
        guard !indices.isEmpty else { return false }
        let succeeded = await connector.removeFromPlaylist(playlistID: id, indices: indices)
        if succeeded, let index = catalog.playlists.firstIndex(where: { $0.id == id }) {
            for offset in Set(indices).sorted(by: >)
            where catalog.playlists[index].trackIDs.indices.contains(offset) {
                catalog.playlists[index].trackIDs.remove(at: offset)
            }
            if let serverID = catalog.activeServerID {
                persistServerPlaylists(catalog.playlists, serverID: serverID)
            }
        }
        return succeeded
    }

    /// 调整歌单内曲目顺序（OpenSubsonic 无原子重排，走「整表替换」）。
    @discardableResult
    public func reorderPlaylist(id: PlaylistID, from: Int, to: Int) async -> Bool {
        guard let index = catalog.playlists.firstIndex(where: { $0.id == id }) else { return false }
        var ids = catalog.playlists[index].trackIDs
        guard ids.indices.contains(from) else { return false }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: min(max(to, 0), ids.count))
        let succeeded = await connector.replacePlaylistTracks(playlistID: id, trackIDs: ids)
        if succeeded {
            catalog.playlists[index].trackIDs = ids
            if let serverID = catalog.activeServerID {
                persistServerPlaylists(catalog.playlists, serverID: serverID)
            }
        }
        return succeeded
    }

    /// 删除歌单（破坏性操作，调用方必须已完成确认）。
    @discardableResult
    /// 复制歌单（副本命名「原名 副本」），逐首添加到服务器，失败返回 nil。
    public func duplicatePlaylist(id: PlaylistID) async -> Playlist? {
        guard let source = catalog.playlists.first(where: { $0.id == id }) else { return nil }
        guard let copy = await createPlaylist(named: "\(source.name) 副本") else { return nil }
        let ids = Set(source.trackIDs)
        for track in catalog.tracks where ids.contains(track.id) {
            _ = await addToPlaylist(copy, track: track)
        }
        return copy
    }

    public func deletePlaylist(id: PlaylistID) async -> Bool {
        let succeeded = await connector.deletePlaylist(playlistID: id)
        if succeeded {
            catalog.playlists.removeAll { $0.id == id }
            playlistTracks.removeValue(forKey: id)
            if case let .playlist(shown) = browseDestination, shown.id == id {
                browseDestination = .playlists
            }
            if let serverID = catalog.activeServerID {
                deleteLocalPlaylist(id, serverID: serverID)
            }
        }
        return succeeded
    }

    /// 按需从服务器拉取歌单内的完整曲目列表并缓存。
    /// getPlaylists（复数）只返回歌单元数据不含 entry，必须调 getPlaylist（单数）才有曲目。
    public func loadPlaylistTracks(playlistID: PlaylistID) {
        guard playlistTracks[playlistID] == nil,
              !loadingPlaylistIDs.contains(playlistID)
        else { return }
        loadingPlaylistIDs.insert(playlistID)
        Task {
            let tracks = await connector.fetchPlaylistTracks(playlistID: playlistID)
            loadingPlaylistIDs.remove(playlistID)
            playlistTracks[playlistID] = tracks
            // 同步更新 catalog 中歌单的 trackIDs
            if let index = catalog.playlists.firstIndex(where: { $0.id == playlistID }),
               !tracks.isEmpty {
                catalog.playlists[index].trackIDs = tracks.map(\.id)
                // 歌单详情拉取后写回 SQLite，让 Agent 的 getPlaylist / 播放歌单使用真实曲目顺序。
                if let serverID = catalog.activeServerID {
                    persistServerPlaylists(catalog.playlists, serverID: serverID)
                }
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
        await connector.setAlbumFavorite(albumID: id, isFavorite: isFavorite)
    }

    /// 收藏 / 取消收藏艺术家。
    public func setArtistFavorite(id: ArtistID, isFavorite: Bool) async {
        await connector.setArtistFavorite(artistID: id, isFavorite: isFavorite)
    }

    /// 设置曲目评分，0 表示清除评分。
    public func setRating(trackID: TrackID, rating: Int) async {
        let clamped = min(max(rating, 0), 5)
        if let index = catalog.tracks.firstIndex(where: { $0.id == trackID }) {
            catalog.tracks[index].rating = clamped == 0 ? nil : clamped
            if currentTrack.id == trackID { currentTrack = catalog.tracks[index] }
        }
        await connector.setRating(trackID: trackID, rating: clamped)
    }

    // MARK: - Server lifecycle

    /// 探活当前服务器（用于设置页与 Agent 的连接自检）。
    public func testActiveServerConnection() async -> Bool {
        await connector.ping()
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

    /// 备份恢复：把服务器账号与登录凭据写回本地（不联网、不触发资料同步）。
    /// 仅登记账号信息，不会自动下载 / 同步音乐资料库。
    public func restoreServerAccountFromBackup(_ account: ServerAccount, secret: String?) async {
        try? await catalogCoordinator.store.upsertServer(account)
        await connector.restoreAccountFromBackup(account, secret: secret)
    }

    /// 移除服务器：只清理本地凭据与本地数据，绝不向远端发送删除请求。
    public func removeServerLocally(serverID: ServerID) async {
        await connector.forgetServer(serverID: serverID)
        guard catalog.activeServerID == serverID else { return }
        mediaIntegration.stop()
        catalog = .empty
        queue = []
        playbackPosition = 0
        artworkStore.reset()
        playlistTracks = [:]
        loadingPlaylistIDs = []
        lyricsInFlight = []
        lyricsUnavailable = []
        artworkInFlight = []
        downloadedTrackIDs = []
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
        guard catalog.lyrics[track.id] == nil,
              !lyricsUnavailable.contains(track.id),
              !lyricsInFlight.contains(track.id)
        else { return }
        lyricsInFlight.insert(track.id)
        Task { [lyricsCache] in
            // 第一优先：本地歌词缓存（冷启动后无需任何网络请求）。
            // 键按「serverID:trackID」隔离（P0-2），避免读到别家服务器的歌词。
            if let cached = await lyricsCache.document(forServer: track.serverID, trackID: track.id) {
                lyricsInFlight.remove(track.id)
                catalog.lyrics[track.id] = cached
                return
            }
            // 该服务器此前已确认没有这首歌的歌词，不再重复请求（负缓存按服务器隔离）。
            if await lyricsCache.isKnownMissing(serverID: track.serverID, trackID: track.id) {
                lyricsInFlight.remove(track.id)
                lyricsUnavailable.insert(track.id)
                return
            }
            let document = await connector.lyrics(for: track)
            lyricsInFlight.remove(track.id)
            if let document {
                catalog.lyrics[track.id] = document
                await lyricsCache.store(document, forServer: track.serverID, trackID: track.id)
            } else {
                lyricsUnavailable.insert(track.id)
                await lyricsCache.markMissing(serverID: track.serverID, trackID: track.id)
            }
        }
    }

    // MARK: - Artwork

    /// 已缓存的封面图；未加载时返回 nil，视图应展示占位封面并调用 loadArtwork。
    public func artworkImage(key: String?, targetPixelSize: Int) -> PlatformImage? {
        guard let key else { return nil }
        return artworkStore.image(forKey: artworkCacheKey(key, targetPixelSize))
    }

    /// 按需从服务器拉取封面并缓存。拉取过（无论成败）的封面不会重复请求。
    public func loadArtwork(key: String?, targetPixelSize: Int) {
        guard let key, !key.isEmpty else { return }
        let cacheKey = artworkCacheKey(key, targetPixelSize)
        guard artworkStore.image(forKey: cacheKey) == nil,
              !artworkStore.isUnavailable(cacheKey),
              !artworkInFlight.contains(cacheKey)
        else { return }
        artworkInFlight.insert(cacheKey)
        Task { [artworkCache, artworkStore] in
            // 第一优先：磁盘缓存。命中就完全不联网——这是「每次打开 App
            // 都要把所有封面重新下一遍」的根治点。
            // 精确尺寸未命中时，回退到「全量缓存」的固定尺寸（512），解码后缩放到目标尺寸，
            // 让全量缓存后的封面在任意控件尺寸下都能直接命中磁盘、不再联网。
            let fullCacheKey = artworkCacheKey(key, Self.fullCacheArtworkSize)
            var cached = await artworkCache.data(for: cacheKey)
            if cached == nil, cacheKey != fullCacheKey {
                cached = await artworkCache.data(for: fullCacheKey)
            }
            if let cached,
               let image = PlatformImage(data: cached) {
                artworkInFlight.remove(cacheKey)
                let displayImage: PlatformImage?
                if cacheKey != fullCacheKey, targetPixelSize != Self.fullCacheArtworkSize {
                    displayImage = Self.resizedPlatformImage(image, to: targetPixelSize)
                } else {
                    displayImage = image
                }
                artworkStore.setImage(displayImage ?? image, forKey: cacheKey)
                if key == currentTrack.artworkKey {
                    mediaIntegration.artworkLoaded(cached, position: playbackPosition, isPlaying: playbackState == .playing)
                }
                return
            }
            await artworkLimiter.enter()
            let data = await connector.artworkData(key: key, targetPixelSize: targetPixelSize)
            artworkInFlight.remove(cacheKey)
            await artworkLimiter.leave()
            if let data, let image = PlatformImage(data: data) {
                artworkStore.setImage(image, forKey: cacheKey)
                // 落盘，下次冷启动直接命中。
                await artworkCache.store(data, for: cacheKey)
                // 封面晚于切歌到达时，补一次 Now Playing 刷新
                if key == currentTrack.artworkKey {
                    mediaIntegration.artworkLoaded(data, position: playbackPosition, isPlaying: playbackState == .playing)
                }
            } else {
                artworkStore.markUnavailable(cacheKey)
            }
        }
    }

    /// 封面缓存键：**必须包含服务器 ID**，否则两台服务器相同 ID 的封面会在
    /// 磁盘缓存里互相覆盖（P0-4）。内存与磁盘共用同一键，天然按服务器隔离。
    func artworkCacheKey(_ key: String, _ targetPixelSize: Int) -> String {
        let serverID = catalog.activeServerID?.rawValue
            ?? (currentTrack.id.rawValue == "placeholder" ? "local" : currentTrack.serverID.rawValue)
        return "\(serverID)|\(key)@\(targetPixelSize)"
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
                            try await self.engine.play(track: self.currentTrack)
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
                self.persistPlaybackSession()
                self.mediaIntegration.playbackStateChanged(
                    isPlaying: self.playbackState == .playing,
                    position: self.playbackPosition,
                    rate: self.playbackState == .playing ? self.playbackRate : 0
                )
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
        persistPlaybackSession()
        Task { @MainActor in
            await self.engine.stop()
            self.playbackState = await self.engine.state()
            self.syncProgressTimer()
            self.mediaIntegration.stop()
        }
    }

    /// 向前跳转（默认 30 秒）。
    public func skipForward(seconds: TimeInterval = 30) {
        let duration = currentTrack.duration
        let target = duration > 0 ? min(playbackPosition + seconds, duration) : playbackPosition + seconds
        seekToAbsolute(target)
    }

    /// 向后跳转（默认 15 秒）。
    public func skipBackward(seconds: TimeInterval = 15) {
        seekToAbsolute(max(playbackPosition - seconds, 0))
    }

    private func seekToAbsolute(_ position: TimeInterval) {
        playbackPosition = position
        persistPlaybackSession()
        let trackID = currentTrack.id
        Task {
            // seek 竞态防护（P2-18）：执行前若已切歌则放弃旧 seek，避免落到新曲目。
            guard self.currentTrack.id == trackID else { return }
            await engine.seek(to: position)
            mediaIntegration.seekCompleted(position: position, isPlaying: playbackState == .playing, rate: playbackState == .playing ? playbackRate : 0)
        }
    }

    public func next() {
        if isShuffled {
            playRandomFromQueue()
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return }
        if queue.indices.contains(index + 1) {
            selectAndPlay(queue[index + 1])
        } else if repeatMode == .all, queue.count > 1, let first = queue.first {
            // 列表循环：到队尾绕回第一首
            selectAndPlay(first)
        }
    }

    /// 只随机尚未播放的剩余队列（当前曲目之后），保持已播放部分顺序不变。
    public func shuffleRemainingInQueue() {
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return }
        let tail = Array(queue.dropFirst(index + 1))
        guard tail.count > 1 else { return }
        queue = Array(queue.prefix(index + 1)) + tail.shuffled()
    }

    /// 把当前播放队列保存为服务器歌单；失败返回 false。
    public func saveQueueAsPlaylist(named name: String) async -> Bool {
        guard !queue.isEmpty, let playlist = await createPlaylist(named: name) else { return false }
        for track in queue {
            _ = await addToPlaylist(playlist, track: track)
        }
        return true
    }

    /// 随机模式：从队列里随机挑一首非当前曲目。
    private func playRandomFromQueue() {
        guard queue.count > 1,
              let next = queue.filter({ $0.id != currentTrack.id }).randomElement()
        else { return }
        selectAndPlay(next)
    }

    /// 切换曲目的收藏状态，并同步到服务器（star/unstar）。
    public func toggleFavorite(_ track: Track) {
        guard let index = catalog.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        catalog.tracks[index].isFavorite.toggle()
        let updated = catalog.tracks[index]
        if currentTrack.id == track.id { currentTrack = updated }
        refreshHomeSnapshots()
        Task { await connector.setFavorite(trackID: updated.id, isFavorite: updated.isFavorite) }
    }

    /// 跳到上一首；播放已超过 3 秒时先回到本曲开头（主流播放器的习惯行为）。
    public func previous() {
        if playbackPosition > 3 {
            // 超过 3 秒：回到本曲开头——真实 seek 引擎并同步控制中心/锁屏（P2-10）。
            seekToAbsolute(0)
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else {
            seekToAbsolute(0)
            return
        }
        if queue.indices.contains(index - 1) {
            selectAndPlay(queue[index - 1])
        } else if repeatMode == .all, let last = queue.last {
            // 列表循环：队首回绕到队尾最后一首，而不是停在原曲（P2-10）。
            selectAndPlay(last)
        } else {
            // 没有上一首：回到本曲开头，真实 seek 引擎（P2-10）。
            seekToAbsolute(0)
        }
    }

    /// 拖动进度：同时更新 UI 位置、驱动引擎真实 seek，并同步锁屏进度。
    public func seek(toProgress progress: Double) {
        playbackPosition = min(max(progress, 0), 1) * currentTrack.duration
        let position = playbackPosition
        let trackID = currentTrack.id
        persistPlaybackSession()
        Task {
            // seek 竞态防护（P2-18）：执行前若已切歌则放弃旧 seek，避免落到新曲目。
            guard self.currentTrack.id == trackID else { return }
            await engine.seek(to: position)
            mediaIntegration.seekCompleted(position: position, isPlaying: playbackState == .playing, rate: playbackState == .playing ? playbackRate : 0)
        }
    }

    // MARK: - Queue editing

    /// 拖动调整队列顺序：保持当前曲目位置，移动后持久化播放会话。
    public func moveQueue(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        guard !moving.isEmpty else { return }
        let currentID = currentTrack.id
        let movingIDs = Set(moving.map(\.id))
        var newQueue = queue.filter { !movingIDs.contains($0.id) }
        let insertion = min(max(0, destination - source.filter { $0 < destination }.count), newQueue.count)
        newQueue.insert(contentsOf: moving, at: insertion)
        queue = newQueue
        // 保持当前曲目在队列中的位置指向不变。
        _ = currentID
    }

    public func removeFromQueue(atOffsets offsets: IndexSet) {
        let targets = offsets.compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        for track in targets { removeFromQueue(track) }
    }

    /// 从队列移除曲目。删除正在播放的曲目时自动切到下一首；
    /// 队列清空后回到空闲状态。曲目仍保留在音乐库中。
    public func removeFromQueue(_ track: Track) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        let wasCurrent = track.id == currentTrack.id
        queue.remove(at: index)
        guard wasCurrent else { return }

        if let next = queue.indices.contains(index) ? queue[index] : queue.last {
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

    // MARK: - Progress timer

    private func syncProgressTimer() {
        if playbackState == .playing {
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
    private func advanceProgress() {
        guard playbackState == .playing else { return }
        Task { @MainActor in
            if let real = await self.engine.currentPosition() {
                self.playbackPosition = min(real, self.currentTrack.duration)
            } else {
                self.playbackPosition += 0.5
                if self.playbackPosition >= self.currentTrack.duration {
                    self.handleTrackEnded()
                    return
                }
            }
            // 每 2 秒落盘一次进度，避免高频写入。
            if Date().timeIntervalSince(self.lastPlaybackPersistAt) >= 2 {
                self.lastPlaybackPersistAt = .now
                self.persistPlaybackSession()
            }
        }
    }

    /// 曲目播完：按循环/随机模式决定重播、切下一首、绕回队首或暂停。
    /// 睡眠定时优先：当前歌曲/专辑/队列结束时停止而不是继续切歌。
    public func handleTrackEnded() {
        // Navidrome 只在 scrobble(submission=true) 时记录播放次数，stream 不会标记。
        // 曲目自然播完即上报当前曲目，保持服务器端播放计数与本地一致。
        // 仅在当前曲目属于活动服务器时上报，避免跨服务器串库。
        let finished = currentTrack
        if finished.id.rawValue != "placeholder",
           finished.serverID == catalog.activeServerID {
            let connector = self.connector
            Task { await connector.scrobble(trackID: finished.id, submission: true) }
        }
        if applySleepTimerAtTrackEnd() { return }
        switch repeatMode {
        case .one:
            selectAndPlay(currentTrack)
        case .all:
            if isShuffled {
                playRandomFromQueue()
            } else if hasNext {
                next()
            } else if queue.count == 1 {
                // 单曲队列：与 .one 一致，循环播放当前曲目（F15）。
                selectAndPlay(currentTrack)
            } else if let first = queue.first {
                selectAndPlay(first)
            } else {
                pauseAtQueueEnd()
            }
        case .off:
            if isShuffled, queue.count > 1 {
                playRandomFromQueue()
            } else if hasNext {
                next()
            } else {
                pauseAtQueueEnd()
            }
        }
    }

    private func pauseAtQueueEnd() {
        lastStopReason = .queueEnded
        playbackPosition = 0
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
        let attempts = streamRetryAttempts[track.id, default: 0]
        guard attempts < Self.maxStreamRetryAttempts else {
            streamRetryAttempts[track.id] = 0
            lastStopReason = .streamExpired
            playbackError = .engineFailure("流地址失效，已重试仍无法播放")
            playbackState = .failed(.engineFailure("流地址失效，已重试仍无法播放"))
            syncProgressTimer()
            if hasNext {
                next()
            }
            return
        }
        streamRetryAttempts[track.id] = attempts + 1
        playbackState = .buffering
        CrashLog.shared.log("流地址失效，刷新后重试（第 \(attempts + 1) 次）")
        Task { @MainActor in
            var refreshed: Track?
            if catalog.activeServerID != nil {
                if let url = await connector.refreshStreamURL(trackID: track.id) {
                    var updated = track
                    updated.streamURL = url
                    refreshed = updated
                }
            } else if track.streamURL != nil {
                refreshed = track
            }
            guard self.currentTrack.id == track.id else { return }
            guard let refreshed else {
                // 无法获取新流地址（服务器离线等）：按重试耗尽处理，自动下一首或提示。
                self.streamRetryAttempts[track.id] = Self.maxStreamRetryAttempts
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
        } catch is CancellationError {
            serverConnectionState = .failed(ServerConnectionError.cancelled.localizedDescription)
        } catch {
            // 统一分类错误文案（地址/认证/超时/局域网权限/ATS/非 OpenSubsonic 等），
            // 不把所有失败都显示成笼统的"连接未完成"。
            serverConnectionState = .failed(ConnectionErrorDescription.describe(error))
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
            return .success(parts.joined(separator: " · "))
        } catch {
            return .failure(ConnectionErrorDescription.describe(error))
        }
    }

    public func restorePersistedLibrary() async {
        guard !attemptedRestore else { return }
        attemptedRestore = true
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

    private func apply(_ result: ServerConnectionResult) {
        serverAuthenticationFailed = false
        serverCapabilities = result.capabilities
        // 全链路以去重后的曲目为准，避免服务端返回的重复 ID 进入界面导致 ForEach 崩溃。
        let tracks = uniquedTracks(result.tracks)
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
        // 是否换了一台服务器。同一台服务器的增量刷新不应丢弃已加载的封面 / 歌词，
        // 否则每次同步都要把所有封面重新下载一遍。
        let switchedServer = appliedServerID != nil && appliedServerID != result.account.id
        appliedServerID = result.account.id
        defaults.set(result.account.id.rawValue, forKey: Self.lastActiveServerKey)
        catalog = LibraryCatalog(
            account: result.account,
            artists: result.artists,
            albums: result.albums,
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
            artworkInFlight = []
            artworkStore.reset()
            playlistTracks = [:]
            loadingPlaylistIDs = []
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
            playbackError = nil
            lastStopReason = .serverDisconnected
            playbackPosition = 0
            queue = Array(tracks.prefix(30))
            handoffActivity?.invalidate()
            Task { @MainActor in
                await self.engine.stop()
                self.playbackState = await self.engine.state()
                self.syncProgressTimer()
                self.mediaIntegration.stop()
                self.persistPlaybackSession()
            }
        } else if !wasPlaying {
            queue = Array(tracks.prefix(30))
        }
        // 重要：catalog 更新绝不调用 mediaIntegration.stop()——
        // 那会停用 AVAudioSession 并清空 MPNowPlayingInfoCenter，导致后台播放被杀、
        // 控制中心丢失歌曲信息。正在播放时只更新目录，音频与系统信息保持不变。

        // 记录每首曲目首次进入本地目录的时间（仅首次出现时写入），用于「最近添加」。
        var added = libraryAddedAt
        let now = Date()
        for track in tracks where added[track.id] == nil {
            added[track.id] = now
        }
        // 仅保留当前目录内曲目的时间戳，避免无限增长。
        added = Dictionary(uniqueKeysWithValues: added.filter { id, _ in tracks.contains(where: { $0.id == id }) })
        libraryAddedAt = added
        let addedForDefaults = added.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = $1.value.timeIntervalSince1970 }
        // 异步持久化，避免大资料库时阻塞主线程。
        Task { @Sendable [defaults] in
            defaults.set(addedForDefaults, forKey: Self.libraryAddedDefaultsKey)
        }

        // 随机音乐：从资料库随机采样，载入时定一次，避免界面频繁重排。
        randomTracks = Array(tracks.shuffled().prefix(18))
        // 资料库就绪：刷新首页货架快照（收藏 / 最常听 / 最近播放 / 最近添加）。
        refreshHomeSnapshots()

        // 仅在未播放时恢复「上次播放会话」（队列 + 当前曲目 + 进度），
        // 不自动播放，由用户点击播放后从保存的进度继续；
        // 正在播放时保留当前曲目、队列与进度，增量同步不打断播放。
        if !wasPlaying {
            // 优先恢复按服务器隔离的播放会话快照；无快照时回退到「上次收听曲目」。
            if !restorePlaybackSession(from: result.tracks, serverID: result.account.id) {
                // 恢复上次收听的那一首（若仍存在于新目录），否则取队列首；
                // 这样「继续聆听 / 播放条」在重新打开时显示的是上次听过的曲目，而非目录第一首。
                let lastID = defaults.string(forKey: Self.lastTrackDefaultsKey)
                if let id = lastID, let restored = result.tracks.first(where: { $0.id.rawValue == id }) {
                    currentTrack = restored
                    loadLyricsIfNeeded(for: restored)
                    // 恢复曲目可能位于队列前 30 首之外，确保它进入队列，避免上一首/下一首静默失效。
                    if !queue.contains(where: { $0.id == restored.id }) {
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
        let spotlightArtists = result.artists
        let spotlightAlbums = result.albums
        let spotlightTracks = tracks
        let spotlightPlaylists = result.playlists
        Task { @MainActor in
            SpotlightIndexer.reindex(
                artists: spotlightArtists,
                albums: spotlightAlbums,
                tracks: spotlightTracks,
                playlists: spotlightPlaylists
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
        Task { [weak self, connector] in
            guard let refreshed = await connector.refreshAuxiliaryData() else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                mergeServerPlaylists(refreshed.playlists)
                mergeServerFavorites(refreshed.favoriteTrackIDs)
                mergeServerGenres(refreshed.genres)
                // 服务器刷新后的歌单同步写入 SQLite（保留本地已加载的 trackIDs）。
                if let serverID = self.catalog.activeServerID {
                    self.persistServerPlaylists(self.catalog.playlists, serverID: serverID)
                }
            }
        }
    }

    /// 把歌单写入本地 SQLite（Agent / 搜索的 listPlaylists 与「播放歌单」直接读这里）。
    /// 与 auxiliaryCache(JSON) 双写：JSON 服务冷启动 UI，SQLite 服务 Agent 结构化查询，
    /// 避免 Agent 查询返回 0 个歌单（此前 SQLite 从未写入歌单）。
    private func persistServerPlaylists(_ playlists: [Playlist], serverID: ServerID) {
        guard !playlists.isEmpty else { return }
        let store = catalogCoordinator.store
        Task { @MainActor in
            for playlist in playlists {
                try? await store.upsertPlaylist(playlist, serverID: serverID)
            }
        }
    }

    /// 删除本地 SQLite 中的单个歌单（配合服务器删除 / 用户删除后清理）。
    private func deleteLocalPlaylist(_ id: PlaylistID, serverID: ServerID) {
        let store = catalogCoordinator.store
        let gid = GlobalID(serverID: serverID, remoteID: id.rawValue)
        Task { @MainActor in
            try? await store.deletePlaylist(gid)
        }
    }

    /// 以服务器歌单为基准合并本地歌单：
    /// - 服务器新增 / 改名 / 删除的歌单按服务器为准；
    /// - 已加载过详情的歌单保留本地 trackIDs（服务器 getPlaylists 常不含 entry），避免列表闪空。
    private func mergeServerPlaylists(_ serverPlaylists: [Playlist]) {
        var merged: [Playlist] = []
        var seen = Set<PlaylistID>()
        for server in serverPlaylists {
            var value = server
            if let local = catalog.playlists.first(where: { $0.id == server.id }),
               !local.trackIDs.isEmpty {
                value.trackIDs = local.trackIDs
            }
            merged.append(value)
            seen.insert(server.id)
        }
        // 服务器尚未收录的本地歌单（例如刚创建、服务器列表还未刷新）保留；
        // 服务器已删除的歌单随之移除。
        for local in catalog.playlists where !seen.contains(local.id) {
            merged.append(local)
        }
        catalog.playlists = merged
        let currentIDs = Set(serverPlaylists.map(\.id))
        playlistTracks = playlistTracks.filter { currentIDs.contains($0.key) }
    }

    /// 服务器收藏回流：以 getStarred2 为准，把服务器上已收藏的曲目标记为 isFavorite。
    /// 只补正「服务器有、本地缺」的收藏，不把本地刚收藏但服务器尚未确认的曲目清掉，
    /// 避免网络抖动时用户刚点的收藏被后台刷新抹掉。
    private func mergeServerFavorites(_ favoriteTrackIDs: [String]) {
        guard !favoriteTrackIDs.isEmpty else { return }
        let favoriteSet = Set(favoriteTrackIDs)
        var changed = false
        for index in catalog.tracks.indices
        where favoriteSet.contains(catalog.tracks[index].id.rawValue)
            && !catalog.tracks[index].isFavorite {
            catalog.tracks[index].isFavorite = true
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
        for globalID in downloadedTrackIDs {
            try? await cacheStore.remove(for: TrackCacheStore.TrackCacheID(
                serverID: globalID.serverID,
                trackID: TrackID(rawValue: globalID.remoteID)
            ))
        }
        downloadedTrackIDs = []
    }

    // MARK: - 渐进式缓存（封面 + 歌词，不再全量下载）

    /// 渐进预缓存封面使用的固定尺寸（px）= 256×256 缩略图。
    /// 大尺寸（512/1024）仅在打开全屏播放器、专辑详情或控制中心需要时按需下载，
    /// 并受 ArtworkDiskCache 的 LRU 容量预算约束。同一专辑多首歌曲共享同一封面文件。
    static let fullCacheArtworkSize = 256

    /// 默认每批缓存歌曲数。
    /// 把封面图缩放到目标边长（供全量缓存回退命中后适配控件尺寸）。
    private static func resizedPlatformImage(_ image: PlatformImage, to pixel: Int) -> PlatformImage? {
        let target = CGFloat(pixel)
        #if os(iOS)
        let size = CGSize(width: target, height: target)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        #else
        let targetSize = NSSize(width: target, height: target)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: target, height: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let resized = NSImage(size: targetSize)
        resized.addRepresentation(rep)
        return resized
        #endif
    }
}

/// 组合播放模式：单个按钮循环切换的三种状态。
public enum PlayMode: Int, CaseIterable, Identifiable, Sendable {
    case list    // 列表顺序（不随机、不循环）
    case shuffle // 随机播放
    case loop    // 循环播放
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .list: String(localized: "列表顺序")
        case .shuffle: String(localized: "随机播放")
        case .loop: String(localized: "循环播放")
        }
    }
    public var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .shuffle: "shuffle"
        case .loop: "repeat"
        }
    }
    public func next() -> PlayMode {
        switch self {
        case .list: return .shuffle
        case .shuffle: return .loop
        case .loop: return .list
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

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: String(localized: "首页")
        case .library: String(localized: "音乐库")
        case .assistant: String(localized: "AI 助手")
        case .search: String(localized: "搜索")
        case .settings: String(localized: "设置")
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
        case .queue: String(localized: "队列")
        case .lyrics: String(localized: "歌词")
        case .quality: String(localized: "音质")
        case .metadata: String(localized: "元数据")
        }
    }
}

/// 浏览目标：专辑、艺术家、单个歌单、歌单总览、收藏与最常听、流派。
public enum BrowseDestination: Identifiable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case playlists
    case favorites
    case mostPlayed
    case genre(Genre)
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

/// 协作式并发限制器：最多允许 `max` 个调用同时越过 `enter()`，
/// 超出部分在 `enter()` 处挂起，直到有调用 `leave()`。用于限制封面等
/// 按需网络请求的并发数，避免服务器不可达时一次性发起大量挂起请求。
private actor ArtworkConcurrencyLimiter {
    private var active = 0
    private let max: Int
    private let pollIntervalNanoseconds: UInt64 = 50_000_000

    init(max: Int) {
        self.max = max
    }

    func enter() async {
        while active >= max {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        active += 1
    }

    func leave() {
        active = Swift.max(0, active - 1)
    }
}
