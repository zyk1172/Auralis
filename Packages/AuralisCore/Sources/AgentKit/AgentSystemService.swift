import Domain
import Foundation

// MARK: - 结构化输出类型（均 Sendable，只含必要信息，不含凭据 / 完整地址 / Token）

/// App 上下文：页面、服务器、当前歌曲、播放状态、队列、网络、未完成任务。
public struct AgentAppContext: Sendable, Equatable {
    public var page: String
    public var serverName: String?
    public var currentTrackTitle: String?
    public var currentTrackArtist: String?
    public var playbackState: String
    public var queueCount: Int
    public var isShuffled: Bool
    public var repeatMode: String
    public var networkType: String
    public var isOffline: Bool
    public var hasPendingTask: Bool

    public init(
        page: String = "home",
        serverName: String? = nil,
        currentTrackTitle: String? = nil,
        currentTrackArtist: String? = nil,
        playbackState: String = "idle",
        queueCount: Int = 0,
        isShuffled: Bool = false,
        repeatMode: String = "off",
        networkType: String = "unknown",
        isOffline: Bool = false,
        hasPendingTask: Bool = false
    ) {
        self.page = page
        self.serverName = serverName
        self.currentTrackTitle = currentTrackTitle
        self.currentTrackArtist = currentTrackArtist
        self.playbackState = playbackState
        self.queueCount = queueCount
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
        self.networkType = networkType
        self.isOffline = isOffline
        self.hasPendingTask = hasPendingTask
    }
}

/// 服务器摘要（绝不包含密码 / Token / 完整认证地址）。
public struct AgentServerInfo: Sendable, Equatable {
    public var id: String
    public var displayName: String
    /// 仅主机名（无路径、无查询、无认证信息）。
    public var host: String?
    public var username: String?
    public var serverType: String?
    public var serverVersion: String?

    public init(id: String, displayName: String, host: String? = nil, username: String? = nil, serverType: String? = nil, serverVersion: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.username = username
        self.serverType = serverType
        self.serverVersion = serverVersion
    }
}

/// 真实 API 连通性测试结果。
public struct AgentConnectionTestResult: Sendable, Equatable {
    public var success: Bool
    public var latencyMs: Double?
    public var serverType: String?
    public var serverVersion: String?
    public var error: String?

    public init(success: Bool, latencyMs: Double? = nil, serverType: String? = nil, serverVersion: String? = nil, error: String? = nil) {
        self.success = success
        self.latencyMs = latencyMs
        self.serverType = serverType
        self.serverVersion = serverVersion
        self.error = error
    }
}

/// 服务器能力摘要。
public struct AgentCapabilitiesSummary: Sendable, Equatable {
    public var supportsStructuredLyrics: Bool
    public var supportsSonicSimilarity: Bool
    public var supportsIndexedQueue: Bool
    public var supportsPlaybackReport: Bool
    public var supportsTranscoding: Bool
    public var supportsAPIKeyAuthentication: Bool
    public var supportsPodcasts: Bool
    public var supportsShares: Bool

    public init(
        supportsStructuredLyrics: Bool = false,
        supportsSonicSimilarity: Bool = false,
        supportsIndexedQueue: Bool = false,
        supportsPlaybackReport: Bool = false,
        supportsTranscoding: Bool = false,
        supportsAPIKeyAuthentication: Bool = false,
        supportsPodcasts: Bool = false,
        supportsShares: Bool = false
    ) {
        self.supportsStructuredLyrics = supportsStructuredLyrics
        self.supportsSonicSimilarity = supportsSonicSimilarity
        self.supportsIndexedQueue = supportsIndexedQueue
        self.supportsPlaybackReport = supportsPlaybackReport
        self.supportsTranscoding = supportsTranscoding
        self.supportsAPIKeyAuthentication = supportsAPIKeyAuthentication
        self.supportsPodcasts = supportsPodcasts
        self.supportsShares = supportsShares
    }
}

/// 同步状态。
public struct AgentSyncStatus: Sendable, Equatable {
    public var isRunning: Bool
    public var mode: String?
    public var lastCompletedAt: Date?
    public var lastProcessedCount: Int
    public var isStale: Bool

    public init(isRunning: Bool = false, mode: String? = nil, lastCompletedAt: Date? = nil, lastProcessedCount: Int = 0, isStale: Bool = false) {
        self.isRunning = isRunning
        self.mode = mode
        self.lastCompletedAt = lastCompletedAt
        self.lastProcessedCount = lastProcessedCount
        self.isStale = isStale
    }
}

/// 网络状态。
public struct AgentNetworkStatus: Sendable, Equatable {
    public var networkType: String
    public var isOffline: Bool
    public var isServerReachable: Bool
    public var isConstrained: Bool

    public init(networkType: String = "unknown", isOffline: Bool = false, isServerReachable: Bool = false, isConstrained: Bool = false) {
        self.networkType = networkType
        self.isOffline = isOffline
        self.isServerReachable = isServerReachable
        self.isConstrained = isConstrained
    }
}

/// 音频输出路由。
public struct AgentAudioRoute: Sendable, Equatable {
    public var outputName: String
    public var outputType: String

    public init(outputName: String = "未知", outputType: String = "unknown") {
        self.outputName = outputName
        self.outputType = outputType
    }
}

/// 存储状态。
public struct AgentStorageStatus: Sendable, Equatable {
    public var catalogBytes: Int64
    public var artworkBytes: Int64
    public var artworkCount: Int
    public var lyricsBytes: Int64
    public var lyricsCount: Int
    public var offlineAudioBytes: Int64
    public var offlineAudioCount: Int
    public var tempAudioBytes: Int64
    public var freeBytes: Int64
    public var totalBytes: Int64

    public init(catalogBytes: Int64 = 0, artworkBytes: Int64 = 0, artworkCount: Int = 0, lyricsBytes: Int64 = 0, lyricsCount: Int = 0, offlineAudioBytes: Int64 = 0, offlineAudioCount: Int = 0, tempAudioBytes: Int64 = 0, freeBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.catalogBytes = catalogBytes
        self.artworkBytes = artworkBytes
        self.artworkCount = artworkCount
        self.lyricsBytes = lyricsBytes
        self.lyricsCount = lyricsCount
        self.offlineAudioBytes = offlineAudioBytes
        self.offlineAudioCount = offlineAudioCount
        self.tempAudioBytes = tempAudioBytes
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }
}

/// 歌词状态。
public struct AgentLyricsResult: Sendable, Equatable {
    public var hasLyrics: Bool
    public var isSynced: Bool
    public var language: String?
    public var lineCount: Int

    public init(hasLyrics: Bool = false, isSynced: Bool = false, language: String? = nil, lineCount: Int = 0) {
        self.hasLyrics = hasLyrics
        self.isSynced = isSynced
        self.language = language
        self.lineCount = lineCount
    }
}

/// 缓存状态。
public struct AgentCacheStatus: Sendable, Equatable {
    public var artworkBytes: Int64
    public var artworkCount: Int
    public var lyricsBytes: Int64
    public var lyricsCount: Int
    public var offlineAudioBytes: Int64
    public var offlineAudioCount: Int
    public var tempAudioBytes: Int64

    public init(artworkBytes: Int64 = 0, artworkCount: Int = 0, lyricsBytes: Int64 = 0, lyricsCount: Int = 0, offlineAudioBytes: Int64 = 0, offlineAudioCount: Int = 0, tempAudioBytes: Int64 = 0) {
        self.artworkBytes = artworkBytes
        self.artworkCount = artworkCount
        self.lyricsBytes = lyricsBytes
        self.lyricsCount = lyricsCount
        self.offlineAudioBytes = offlineAudioBytes
        self.offlineAudioCount = offlineAudioCount
        self.tempAudioBytes = tempAudioBytes
    }
}

/// 收听统计。
public struct AgentListeningSummary: Sendable, Equatable {
    public var totalPlays: Int
    public var uniqueTracks: Int
    public var totalListeningSeconds: Double
    public var topArtist: String?
    public var topAlbum: String?
    public var totalFavorites: Int

    public init(totalPlays: Int = 0, uniqueTracks: Int = 0, totalListeningSeconds: Double = 0, topArtist: String? = nil, topAlbum: String? = nil, totalFavorites: Int = 0) {
        self.totalPlays = totalPlays
        self.uniqueTracks = uniqueTracks
        self.totalListeningSeconds = totalListeningSeconds
        self.topArtist = topArtist
        self.topAlbum = topAlbum
        self.totalFavorites = totalFavorites
    }
}

/// 播放诊断。
public struct AgentPlaybackDiagnostics: Sendable, Equatable {
    public var state: String
    public var currentTrackTitle: String?
    public var mediaSource: String
    public var lastError: String?
    public var lastStopReason: String?
    public var audioSessionActive: Bool
    public var queueValid: Bool
    public var isPlaying: Bool
    public var position: Double
    public var duration: Double

    public init(state: String = "idle", currentTrackTitle: String? = nil, mediaSource: String = "none", lastError: String? = nil, lastStopReason: String? = nil, audioSessionActive: Bool = false, queueValid: Bool = false, isPlaying: Bool = false, position: Double = 0, duration: Double = 0) {
        self.state = state
        self.currentTrackTitle = currentTrackTitle
        self.mediaSource = mediaSource
        self.lastError = lastError
        self.lastStopReason = lastStopReason
        self.audioSessionActive = audioSessionActive
        self.queueValid = queueValid
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
    }
}

/// 脱敏错误记录。
public struct AgentErrorRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var category: String
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = .now, category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

/// 功能状态。
public struct AgentFeatureStatus: Sendable, Equatable {
    public var backgroundAudioEnabled: Bool
    public var siriEnabled: Bool
    public var shortcutsEnabled: Bool
    public var localNetworkPermissionGranted: Bool
    public var notificationsEnabled: Bool
    public var offlineModeEnabled: Bool
    public var localLibraryAvailable: Bool

    public init(backgroundAudioEnabled: Bool = false, siriEnabled: Bool = false, shortcutsEnabled: Bool = false, localNetworkPermissionGranted: Bool = false, notificationsEnabled: Bool = false, offlineModeEnabled: Bool = false, localLibraryAvailable: Bool = false) {
        self.backgroundAudioEnabled = backgroundAudioEnabled
        self.siriEnabled = siriEnabled
        self.shortcutsEnabled = shortcutsEnabled
        self.localNetworkPermissionGranted = localNetworkPermissionGranted
        self.notificationsEnabled = notificationsEnabled
        self.offlineModeEnabled = offlineModeEnabled
        self.localLibraryAvailable = localLibraryAvailable
    }
}

/// 统计条目（名称 → 数值）。
public struct AgentTopItem: Sendable, Equatable {
    public var name: String
    public var value: Int
    public init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}

/// 格式分布（格式 → 歌曲数）。
public struct AgentFormatCount: Sendable, Equatable {
    public var format: String
    public var count: Int
    public init(format: String, count: Int) {
        self.format = format
        self.count = count
    }
}

/// 控制中心 / 锁屏当前收到的 Now Playing 信息，以及是否与 App 内一致。
public struct AgentNowPlayingStatus: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artworkLoaded: Bool
    public var duration: Double
    public var position: Double
    public var rate: Float
    public var queueIndex: Int?
    public var queueCount: Int?
    /// App 内播放状态与系统 Now Playing 是否一致。
    public var consistentWithApp: Bool

    public init(
        title: String? = nil, artist: String? = nil, album: String? = nil,
        artworkLoaded: Bool = false, duration: Double = 0, position: Double = 0,
        rate: Float = 0, queueIndex: Int? = nil, queueCount: Int? = nil,
        consistentWithApp: Bool = true
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkLoaded = artworkLoaded
        self.duration = duration
        self.position = position
        self.rate = rate
        self.queueIndex = queueIndex
        self.queueCount = queueCount
        self.consistentWithApp = consistentWithApp
    }
}

/// 按情绪推荐的歌曲结果（真实资料库数据，模型不编造歌曲）。
public struct AgentRecommendationResult: Sendable, Equatable {
    public var mood: String
    public var tracks: [TrackCard]

    public init(mood: String, tracks: [TrackCard]) {
        self.mood = mood
        self.tracks = tracks
    }
}

/// 组合推荐约束（recommend_by_constraints 的结构化输入）。
public struct AgentRecommendationConstraints: Sendable, Equatable {
    public var languages: [String]
    public var genres: [String]
    public var yearFrom: Int?
    public var yearTo: Int?
    public var favoritesOnly: Bool
    public var excludeRecentlyPlayed: Bool
    public var onlyOffline: Bool
    public var excludeArtist: String?
    public var maxTotalMinutes: Double?
    public var losslessOnly: Bool
    public var limit: Int

    public init(
        languages: [String] = [],
        genres: [String] = [],
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        favoritesOnly: Bool = false,
        excludeRecentlyPlayed: Bool = false,
        onlyOffline: Bool = false,
        excludeArtist: String? = nil,
        maxTotalMinutes: Double? = nil,
        losslessOnly: Bool = false,
        limit: Int = 20
    ) {
        self.languages = languages
        self.genres = genres
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.favoritesOnly = favoritesOnly
        self.excludeRecentlyPlayed = excludeRecentlyPlayed
        self.onlyOffline = onlyOffline
        self.excludeArtist = excludeArtist
        self.maxTotalMinutes = maxTotalMinutes
        self.losslessOnly = losslessOnly
        self.limit = min(max(limit, 1), 100)
    }
}

// MARK: - 统一执行结果

/// 统一工具结果类别。
public enum ToolOutcome: Sendable, Equatable {
    case success
    case confirmationRequired
    case notFound
    case multipleMatches
    case serverOffline
    case unsupported
    case permissionDenied
    case invalidParameter
    case networkError
    case playbackError
    case failure

    public var label: String {
        switch self {
        case .success: "成功"
        case .confirmationRequired: "需要用户确认"
        case .notFound: "未找到"
        case .multipleMatches: "存在多个匹配结果"
        case .serverOffline: "服务器离线"
        case .unsupported: "服务器不支持"
        case .permissionDenied: "权限不足"
        case .invalidParameter: "参数错误"
        case .networkError: "网络错误"
        case .playbackError: "播放错误"
        case .failure: "执行失败"
        }
    }
}

// MARK: - 系统服务协议

/// 系统级 Agent 工具所需的 App / 设备 / 服务器 / 缓存 / 诊断服务抽象。
/// 由 AppShell 层适配 AuralisAppModel 实现；AgentKit 不依赖 Application。
// MARK: - 音乐下载（MoviePilot / MoviePilot）

/// 音乐下载搜索结果（不含凭据 / 完整地址）。
public struct AgentMusicSearchResult: Sendable, Equatable {
    public var configured: Bool
    public var message: String
    public var keyword: String?
    public var searchedSites: [String]?
    public var total: Int
    public var albumMatchedAny: Bool
    public var droppedVideo: Int
    public var droppedUncertain: Int
    public var fallbackTried: Bool
    public var fallbackResolved: String?
    public var kind: String?
    /// 本次生效的大小上限（GB，v0.5.x）：下载时原样传回 max_size_gb。
    public var sizeLimitGB: Double?
    public var candidates: [AgentMusicCandidate]

    public init(
        configured: Bool = false,
        message: String = "",
        keyword: String? = nil,
        searchedSites: [String]? = nil,
        total: Int = 0,
        albumMatchedAny: Bool = false,
        droppedVideo: Int = 0,
        droppedUncertain: Int = 0,
        fallbackTried: Bool = false,
        fallbackResolved: String? = nil,
        kind: String? = nil,
        sizeLimitGB: Double? = nil,
        candidates: [AgentMusicCandidate] = []
    ) {
        self.configured = configured
        self.message = message
        self.keyword = keyword
        self.searchedSites = searchedSites
        self.total = total
        self.albumMatchedAny = albumMatchedAny
        self.droppedVideo = droppedVideo
        self.droppedUncertain = droppedUncertain
        self.fallbackTried = fallbackTried
        self.fallbackResolved = fallbackResolved
        self.kind = kind
        self.sizeLimitGB = sizeLimitGB
        self.candidates = candidates
    }
}

/// 单条音乐资源候选（含用于下载的 ref 引用）。
public struct AgentMusicCandidate: Sendable, Equatable {
    public var index: Int
    public var ref: String?
    public var siteName: String?
    public var title: String
    public var audioFormat: String?
    public var qualityLabel: String?
    public var quality: Int
    public var relevance: Int
    public var albumMatched: Bool
    /// 体积（字节字符串，插件可能是数字或字符串，统一透传为字符串）。
    public var size: String?
    /// 可读体积（如 "303.2 MB"，v0.5.x）。
    public var sizeText: String?
    /// 候选级大小上限（GB，个别插件版本带出；通常用搜索顶层 sizeLimitGB）。
    public var sizeLimitGB: Double?
    public var seeders: Int
    public var grabs: Int

    public init(
        index: Int,
        ref: String? = nil,
        siteName: String? = nil,
        title: String,
        audioFormat: String? = nil,
        qualityLabel: String? = nil,
        quality: Int = 0,
        relevance: Int = 0,
        albumMatched: Bool = false,
        size: String? = nil,
        sizeText: String? = nil,
        sizeLimitGB: Double? = nil,
        seeders: Int = 0,
        grabs: Int = 0
    ) {
        self.index = index
        self.ref = ref
        self.siteName = siteName
        self.title = title
        self.audioFormat = audioFormat
        self.qualityLabel = qualityLabel
        self.quality = quality
        self.relevance = relevance
        self.albumMatched = albumMatched
        self.size = size
        self.sizeText = sizeText
        self.sizeLimitGB = sizeLimitGB
        self.seeders = seeders
        self.grabs = grabs
    }
}

/// 音乐下载提交结果。
public struct AgentMusicDownloadResult: Sendable, Equatable {
    public var configured: Bool
    public var success: Bool
    public var message: String
    public var hash: String?
    public var savePath: String?
    public var status: String?
    /// 曲目级内容校验结果（v0.5.2+）：true=包含目标歌曲 / false=被拒绝 / nil=整轨无法逐曲校验。
    public var contentVerified: Bool?

    public init(
        configured: Bool = false,
        success: Bool = false,
        message: String = "",
        hash: String? = nil,
        savePath: String? = nil,
        status: String? = nil,
        contentVerified: Bool? = nil
    ) {
        self.configured = configured
        self.success = success
        self.message = message
        self.hash = hash
        self.savePath = savePath
        self.status = status
        self.contentVerified = contentVerified
    }
}

/// 音乐下载任务状态。
public struct AgentMusicTask: Sendable, Equatable {
    public var hash: String
    public var title: String
    public var site: String?
    public var state: String
    public var progress: Double
    public var savePath: String?

    public init(hash: String, title: String, site: String? = nil, state: String, progress: Double = 0, savePath: String? = nil) {
        self.hash = hash
        self.title = title
        self.site = site
        self.state = state
        self.progress = progress
        self.savePath = savePath
    }
}

/// 音乐下载历史（含下载器实时状态是否可用）。
public struct AgentMusicHistoryResult: Sendable, Equatable {
    public var configured: Bool
    public var liveAvailable: Bool
    public var tasks: [AgentMusicTask]

    public init(configured: Bool = false, liveAvailable: Bool = false, tasks: [AgentMusicTask] = []) {
        self.configured = configured
        self.liveAvailable = liveAvailable
        self.tasks = tasks
    }
}

public protocol AgentSystemService: Sendable {
    // App
    func appContext() async -> AgentAppContext
    func openPage(_ page: String) async -> Bool
    func featureStatus() async -> AgentFeatureStatus
    // Server
    func listServers() async -> [AgentServerInfo]
    func currentServer() async -> AgentServerInfo?
    func testServerConnection() async -> AgentConnectionTestResult
    func serverCapabilities() async -> AgentCapabilitiesSummary
    func syncStatus() async -> AgentSyncStatus
    // Device
    func networkStatus() async -> AgentNetworkStatus
    func audioRoute() async -> AgentAudioRoute
    func storageStatus() async -> AgentStorageStatus
    // Media
    func lyrics(for trackID: TrackID) async -> AgentLyricsResult
    func downloadOffline(trackID: TrackID) async -> Bool
    func cacheStatus() async -> AgentCacheStatus
    // 控制中心对比
    func nowPlayingStatus() async -> AgentNowPlayingStatus
    // 资料库维护
    /// 封面标识存在但本地磁盘缓存缺失的歌曲标题（可能需要重新下载封面）。
    func brokenArtwork(limit: Int) async -> [String]
    /// 本地音频缓存中存在但资料库已不存在的曲目 ID（陈旧缓存）。
    func staleCache(limit: Int) async -> [String]
    // 最近添加 / 最常播放
    func recentlyAdded(days: Int, limit: Int) async -> [TrackCard]
    func mostPlayed(limit: Int) async -> [TrackCard]
    // 统计
    func topItems(kind: String, limit: Int) async -> [AgentTopItem]
    func formatDistribution() async -> [AgentFormatCount]
    // 推荐（基于真实资料库）
    func recommendByMood(_ mood: String, limit: Int) async -> AgentRecommendationResult
    func recommendByConstraints(_ constraints: AgentRecommendationConstraints) async -> AgentRecommendationResult
    /// 导出一份脱敏诊断报告（纯文本，不含凭据 / 完整 URL / 聊天内容）。
    func diagnosticsReport() async -> String
    // Stats / Diagnostics
    func listeningSummary() async -> AgentListeningSummary
    func playbackDiagnostics() async -> AgentPlaybackDiagnostics
    func recentErrors(limit: Int) async -> [AgentErrorRecord]

    // 音乐下载（MoviePilot / MoviePilot 插件）
    /// - Parameter kind: "single"（单曲，大小上限生效）/ "album" / "auto"（v0.5.x）。
    func musicSearch(artist: String?, album: String?, albumAliases: [String], keyword: String?, year: Int?, limit: Int, preferLossless: Bool, minSeeders: Int, kind: String?) async -> AgentMusicSearchResult
    /// - Parameters:
    ///   - maxSizeGB: search 返回的 size_limit_gb 原样传回（v0.5.x）。
    ///   - verifySong / verifyArtist: 单曲自动下载必传（v0.5.2+ 曲目级内容校验）。
    func musicDownload(ref: String?, siteID: Int?, index: Int?, magnet: String?, title: String?, maxSizeGB: Double?, verifySong: String?, verifyArtist: String?) async -> AgentMusicDownloadResult
    func musicTasks(status: String?) async -> [AgentMusicTask]
    func musicHistory() async -> AgentMusicHistoryResult
}


// MARK: - 默认实现（未配置 / 不可用）

public extension AgentSystemService {
    func musicSearch(artist: String?, album: String?, albumAliases: [String], keyword: String?, year: Int?, limit: Int, preferLossless: Bool, minSeeders: Int, kind: String?) async -> AgentMusicSearchResult {
        AgentMusicSearchResult(configured: false, message: "音乐下载（MoviePilot）未配置")
    }

    func musicDownload(ref: String?, siteID: Int?, index: Int?, magnet: String?, title: String?, maxSizeGB: Double?, verifySong: String?, verifyArtist: String?) async -> AgentMusicDownloadResult {
        AgentMusicDownloadResult(configured: false, message: "音乐下载（MoviePilot）未配置")
    }

    func musicTasks(status: String?) async -> [AgentMusicTask] { [] }

    func musicHistory() async -> AgentMusicHistoryResult {
        AgentMusicHistoryResult(configured: false, liveAvailable: false)
    }
}
