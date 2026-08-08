import AgentKit
import Application
import Domain
import Foundation
import LocalCatalog
import Observability
import SecurityKit
import RecommendationEngine
#if os(iOS)
import AVFAudio
import Network
import UIKit
#endif

/// 把 App 的实际服务适配为 Agent 的 `AgentSystemService`。
/// 所有返回都经过脱敏：不含密码 / Token / 完整认证 URL / 文件路径。
@MainActor
public final class AuralisSystemToolService: AgentSystemService {
    private unowned let model: AuralisAppModel

    public init(model: AuralisAppModel) {
        self.model = model
    }

    // MARK: - App

    public func appContext() async -> AgentAppContext {
        let catalog = model.catalog
        let network = await networkStatus()
        return AgentAppContext(
            page: model.selectedSection.rawValue,
            serverName: catalog.isConnected ? catalog.account.displayName : nil,
            currentTrackTitle: catalog.isConnected && model.currentTrack.id.rawValue != "placeholder" ? model.currentTrack.title : nil,
            currentTrackArtist: catalog.isConnected && model.currentTrack.id.rawValue != "placeholder" ? model.currentTrack.artistName : nil,
            playbackState: Self.playbackStateName(model.playbackState),
            queueCount: model.queue.count,
            isShuffled: model.isShuffled,
            repeatMode: model.repeatMode.rawValue,
            networkType: network.networkType,
            isOffline: network.isOffline,
            hasPendingTask: model.agentCoordinator.isRunning
        )
    }

    public func openPage(_ page: String) async -> Bool {
        let normalized = page.lowercased()
        switch normalized {
        case "首页", "home":
            model.selectedSection = .home
        case "音乐库", "library":
            model.selectedSection = .library
        case "搜索", "search":
            model.selectedSection = .search
        case "ai助手", "assistant":
            model.selectedSection = .assistant
        case "设置", "settings":
            model.selectedSection = .settings
        case "当前播放", "nowplaying":
            model.isNowPlayingPresented = true
        case "歌词", "lyrics":
            model.isNowPlayingPresented = true
            model.inspector = .lyrics
        case "播放队列", "queue":
            model.isNowPlayingPresented = true
            model.inspector = .queue
        case "下载管理", "downloads":
            model.selectedSection = .library
        case "服务器管理", "servers":
            model.shouldPresentServerSetup = true
        default:
            return false
        }
        return true
    }

    public func featureStatus() async -> AgentFeatureStatus {
        var backgroundAudio = false
        #if os(iOS)
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] {
            backgroundAudio = modes.contains("audio")
        }
        #endif
        return AgentFeatureStatus(
            backgroundAudioEnabled: backgroundAudio,
            siriEnabled: true,
            shortcutsEnabled: true,
            // iOS 无公开 API 查询本地网络授权状态；按默认拒绝（false）处理，避免向模型谎报已授权。
            localNetworkPermissionGranted: false,
            notificationsEnabled: false,
            offlineModeEnabled: model.catalog.isConnected && !model.catalog.tracks.isEmpty,
            localLibraryAvailable: !model.catalog.tracks.isEmpty
        )
    }

    // MARK: - Server

    public func listServers() async -> [AgentServerInfo] {
        let servers = (try? await model.catalogCoordinator.store.listServers()) ?? []
        return servers.map { Self.serverInfo($0) }
    }

    public func currentServer() async -> AgentServerInfo? {
        guard let account = model.catalog.activeAccount else { return nil }
        return Self.serverInfo(account)
    }

    public func testServerConnection() async -> AgentConnectionTestResult {
        let started = Date()
        let ok = await model.testActiveServerConnection()
        let latency = Date().timeIntervalSince(started) * 1000
        return AgentConnectionTestResult(
            success: ok,
            latencyMs: ok ? latency : nil,
            serverType: model.serverConnectionState.serverType,
            serverVersion: nil,
            error: ok ? nil : "服务器不可达或认证失败"
        )
    }

    public func serverCapabilities() async -> AgentCapabilitiesSummary {
        let caps = model.serverCapabilities
        return AgentCapabilitiesSummary(
            supportsStructuredLyrics: caps.supportsStructuredLyrics,
            supportsSonicSimilarity: caps.supportsSonicSimilarity,
            supportsIndexedQueue: caps.supportsIndexedQueue,
            supportsPlaybackReport: caps.supportsPlaybackReport,
            supportsTranscoding: caps.supportsTranscoding,
            supportsAPIKeyAuthentication: caps.supportsAPIKeyAuthentication,
            supportsPodcasts: false,
            supportsShares: false
        )
    }

    public func syncStatus() async -> AgentSyncStatus {
        await model.catalogCoordinator.refreshStatuses()
        guard let serverID = model.catalog.activeServerID else {
            return AgentSyncStatus(isRunning: false, isStale: true)
        }
        let status = await model.catalogCoordinator.store.syncStatus(for: serverID)
        let isRunning: Bool
        switch model.catalogCoordinator.phase {
        case .running: isRunning = true
        default: isRunning = false
        }
        return AgentSyncStatus(
            isRunning: isRunning,
            mode: status.mode?.rawValue,
            lastCompletedAt: status.lastCompletedAt,
            lastProcessedCount: status.lastProcessedCount,
            isStale: status.isStale
        )
    }

    // MARK: - Device

    public func networkStatus() async -> AgentNetworkStatus {
        // 以服务器连接状态为可达性依据；网络类型复用已 start 的 NetworkPath 单例
        // （直接新建 NWPathMonitor 且不 start 时 currentPath 恒为未满足路径，会误报 unknown）。
        let networkType: String
        switch NetworkPath.shared.interfaceType {
        case .wifi: networkType = "wifi"
        case .cellular: networkType = "cellular"
        case .ethernet: networkType = "ethernet"
        case .other, .unknown: networkType = "other"
        }
        let connected = model.catalog.isConnected
        return AgentNetworkStatus(
            networkType: networkType,
            isOffline: !connected,
            isServerReachable: connected,
            isConstrained: false
        )
    }

    public func audioRoute() async -> AgentAudioRoute {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let name = output?.portName ?? "未知"
        let type: String
        switch output?.portType {
        case .builtInSpeaker: type = "speaker"
        case .headphones, .headsetMic: type = "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: type = "bluetooth"
        case .airPlay: type = "airplay"
        case .carAudio: type = "car"
        default: type = "other"
        }
        return AgentAudioRoute(outputName: name, outputType: type)
        #else
        return AgentAudioRoute()
        #endif
    }

    public func storageStatus() async -> AgentStorageStatus {
        let usage = await model.cacheUsage()
        let freeBytes = Self.deviceFreeBytes() ?? 0
        let totalBytes = Self.deviceTotalBytes() ?? 0
        return AgentStorageStatus(
            catalogBytes: usage.catalogBytes,
            artworkBytes: usage.artworkBytes,
            artworkCount: usage.artworkCount,
            lyricsBytes: usage.lyricsBytes,
            lyricsCount: usage.lyricsCount,
            offlineAudioBytes: usage.audioBytes,
            offlineAudioCount: usage.audioCount,
            tempAudioBytes: 0,
            freeBytes: freeBytes,
            totalBytes: totalBytes
        )
    }

    // MARK: - Media

    public func lyrics(for trackID: TrackID) async -> AgentLyricsResult {
        if let document = model.catalog.lyrics[trackID] {
            return AgentLyricsResult(
                hasLyrics: !document.lines.isEmpty,
                isSynced: document.isSynced,
                language: document.language,
                lineCount: document.lines.count
            )
        }
        // 磁盘歌词缓存按「serverID:trackID」隔离（P0-2），需先解析出曲目归属服务器。
        guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else {
            return AgentLyricsResult(hasLyrics: false)
        }
        if let cached = await model.lyricsCache.document(forServer: track.serverID, trackID: trackID) {
            return AgentLyricsResult(hasLyrics: !cached.lines.isEmpty, isSynced: cached.isSynced, language: cached.language, lineCount: cached.lines.count)
        }
        return AgentLyricsResult(hasLyrics: false)
    }

    public func downloadOffline(trackID: TrackID) async -> Bool {
        guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else { return false }
        guard !model.isDownloaded(track), !model.isDownloading(track) else { return false }
        model.download(track)
        return true
    }

    public func cacheStatus() async -> AgentCacheStatus {
        let usage = await model.cacheUsage()
        return AgentCacheStatus(
            artworkBytes: usage.artworkBytes,
            artworkCount: usage.artworkCount,
            lyricsBytes: usage.lyricsBytes,
            lyricsCount: usage.lyricsCount,
            offlineAudioBytes: usage.audioBytes,
            offlineAudioCount: usage.audioCount,
            tempAudioBytes: 0
        )
    }

    // MARK: - 推荐（基于真实资料库）

    /// 情绪 → 流派关键词映射。推荐结果全部来自本地资料库，模型不编造歌曲。
    private static let moodGenres: [String: [String]] = [
        "深夜": ["轻音乐", "钢琴", "氛围", "环境"],
        "放松": ["放松", "爵士", "原声", "轻音乐"],
        "通勤": ["流行", "摇滚", "电子"],
        "学习": ["古典", "器乐", "纯音乐", "轻音乐"],
        "运动": ["电子", "摇滚", "舞曲", "嘻哈"],
        "伤感": ["伤感", "民谣", "蓝调"],
        "治愈": ["治愈", "民谣", "原声"],
        "怀旧": ["怀旧", "老歌", "经典", "经典流行"],
        "安静": ["安静", "氛围", "环境", "原声"],
        "高能量": ["电子", "摇滚", "舞曲"],
    ]

    public func recommendByMood(_ mood: String, limit: Int) async -> AgentRecommendationResult {
        let genres = Self.moodGenres[mood] ?? [mood]
        let safeLimit = min(max(limit, 1), 50)
        let query = RecommendationQuery(
            genres: Set(genres),
            maximumTracksPerArtist: 2,
            limit: safeLimit * 2
        )
        var ranked = HybridRecommendationEngine.recommend(tracks: model.catalog.tracks, query: query)
        // 排除最近播放的曲目，避免刚听完又推荐。
        let recentIDs = Set(model.recentlyPlayedTracks.prefix(20).map(\.id))
        ranked.removeAll { recentIDs.contains($0.id) }
        if ranked.isEmpty {
            // 流派未命中时回退：收藏优先，其次随机。
            let favorites = model.favoriteTracks.shuffled()
            ranked = favorites.isEmpty ? model.catalog.tracks.shuffled() : favorites
        }
        let picks = Array(ranked.prefix(safeLimit))
        let cards = picks.map { track -> TrackCard in
            TrackCard(
                globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue),
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                duration: track.duration,
                isFavorite: track.isFavorite
            )
        }
        return AgentRecommendationResult(mood: mood, tracks: cards)
    }

    /// 组合约束推荐：只从真实资料库筛选，模型不编造歌曲。
    public func recommendByConstraints(_ constraints: AgentRecommendationConstraints) async -> AgentRecommendationResult {
        let languages = Set(constraints.languages.map { $0.localizedLowercase })
        let genres = Set(constraints.genres.map { $0.localizedLowercase })
        let recentIDs = Set(model.recentlyPlayedTracks.prefix(20).map(\.id))

        var candidates = model.catalog.tracks.filter { track in
            if !languages.isEmpty, let language = track.language?.localizedLowercase, !languages.contains(language) {
                return false
            }
            if !genres.isEmpty, track.genres.map({ $0.localizedLowercase }).filter(genres.contains).isEmpty {
                return false
            }
            if let from = constraints.yearFrom, let year = track.year, year < from { return false }
            if let to = constraints.yearTo, let year = track.year, year > to { return false }
            if constraints.favoritesOnly, !track.isFavorite { return false }
            if constraints.excludeRecentlyPlayed, recentIDs.contains(track.id) { return false }
            if constraints.onlyOffline, !model.isDownloaded(track) { return false }
            if let excluded = constraints.excludeArtist, track.artistName.localizedCaseInsensitiveContains(excluded) { return false }
            if constraints.losslessOnly, !Self.isLossless(track) { return false }
            return true
        }

        // 排序：收藏优先，其次评分，再随机。
        candidates.sort { lhs, rhs in
            let ls = (lhs.isFavorite ? 2 : 0) + Double(lhs.rating ?? 0) * 0.25
            let rs = (rhs.isFavorite ? 2 : 0) + Double(rhs.rating ?? 0) * 0.25
            if ls != rs { return ls > rs }
            return lhs.title < rhs.title
        }
        if let totalMinutes = constraints.maxTotalMinutes {
            var total: Double = 0
            var picked: [Track] = []
            for track in candidates {
                if total + track.duration / 60 > totalMinutes { continue }
                picked.append(track)
                total += track.duration / 60
                if picked.count >= constraints.limit { break }
            }
            candidates = picked
        } else {
            candidates = Array(candidates.prefix(constraints.limit))
        }

        let cards = candidates.map(Self.card)
        return AgentRecommendationResult(mood: "组合约束", tracks: cards)
    }

    private static func isLossless(_ track: Track) -> Bool {
        guard let codec = track.sourceInfo.codec?.lowercased() else { return false }
        return codec == "flac" || codec == "alac" || codec == "wav" || codec == "aiff" || codec == "aif"
    }

    /// 导出脱敏诊断报告：服务器 / 网络 / 播放 / 停止原因 / 最近错误。
    public func diagnosticsReport() async -> String {
        let context = await appContext()
        let network = await networkStatus()
        let playback = await playbackDiagnostics()
        let errors = await recentErrors(limit: 5)
        var lines: [String] = []
        lines.append("Auralis 诊断报告（脱敏）")
        lines.append("页面：\(context.page) · 服务器：\(context.serverName ?? "未连接") · 网络：\(network.networkType)\(network.isOffline ? "（离线）" : "")")
        lines.append("播放：\(playback.state) · 歌曲：\(playback.currentTrackTitle ?? "无") · 来源：\(playback.mediaSource)")
        lines.append("最近停止原因：\(playback.lastStopReason ?? "未知") · 音频会话：\(playback.audioSessionActive ? "激活" : "未激活") · 队列：\(playback.queueValid ? "有效" : "无效")")
        lines.append("进度：\(Int(playback.position))/\(Int(playback.duration)) 秒 · 错误：\(playback.lastError ?? "无")")
        if !errors.isEmpty {
            lines.append("最近错误（脱敏）：")
            for entry in errors.prefix(5) {
                lines.append("- \(entry.timestamp.formatted(date: .omitted, time: .shortened)) [\(entry.category)] \(entry.message)")
            }
        }
        lines.append("—— 报告不含密码、Token、完整服务器地址与聊天内容。")
        return lines.joined(separator: "\n")
    }

    private static func card(_ track: Track) -> TrackCard {
        TrackCard(
            globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue),
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration,
            isFavorite: track.isFavorite
        )
    }

    // MARK: - 控制中心对比

    public func nowPlayingStatus() async -> AgentNowPlayingStatus {
        let snapshot = model.mediaIntegration.nowPlaying.current
        let isPlaceholder = model.currentTrack.id.rawValue == "placeholder"
        let appTitle = isPlaceholder ? nil : model.currentTrack.title
        let consistent = (snapshot?.title == appTitle)
            && (snapshot?.duration ?? 0) == model.currentTrack.duration
        return AgentNowPlayingStatus(
            title: snapshot?.title,
            artist: snapshot?.artist,
            album: snapshot?.album,
            artworkLoaded: snapshot?.artworkData != nil,
            duration: snapshot?.duration ?? 0,
            position: snapshot?.elapsed ?? 0,
            rate: snapshot?.rate ?? 0,
            queueIndex: snapshot?.queueIndex,
            queueCount: snapshot?.queueCount,
            consistentWithApp: consistent
        )
    }

    // MARK: - 资料库维护

    public func brokenArtwork(limit: Int) async -> [String] {
        let safeLimit = min(max(limit, 1), 50)
        guard let serverID = model.catalog.activeServerID else { return [] }
        var broken: [String] = []
        for track in model.catalog.tracks {
            guard broken.count < safeLimit else { break }
            guard let key = track.artworkKey else { continue }
            let cacheKey = "\(serverID.rawValue)|\(key)@96"
            if await model.artworkCache.data(for: cacheKey) == nil {
                broken.append(track.title)
            }
        }
        return broken
    }

    public func staleCache(limit: Int) async -> [String] {
        let safeLimit = min(max(limit, 1), 50)
        // 音频缓存键已改为「serverID:trackID」组合键（P0-1），用 GlobalID 与目录对齐。
        let knownIDs = Set(model.catalog.tracks.map {
            GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)
        })
        let cached = await model.allCachedTrackIDs()
        let stale = cached.subtracting(knownIDs).map(\.description).sorted()
        return Array(stale.prefix(safeLimit))
    }

    // MARK: - 最近添加 / 最常播放

    public func recentlyAdded(days: Int, limit: Int) async -> [TrackCard] {
        let tracks = model.recentlyAddedTracks(inLastDays: max(days, 1))
        return tracks.prefix(min(max(limit, 1), 100)).map(Self.card)
    }

    public func mostPlayed(limit: Int) async -> [TrackCard] {
        let counts = model.playCounts
        let sorted = counts.sorted { $0.value > $1.value }.prefix(min(max(limit, 1), 100))
        return sorted.compactMap { entry -> TrackCard? in
            guard let track = model.catalog.tracks.first(where: { $0.id == entry.key }) else { return nil }
            return Self.card(track)
        }
    }

    // MARK: - 统计

    public func topItems(kind: String, limit: Int) async -> [AgentTopItem] {
        let safeLimit = min(max(limit, 1), 50)
        let counts = model.playCounts
        switch kind.lowercased() {
        case "artist":
            var artistCounts: [String: Int] = [:]
            for (trackID, count) in counts {
                guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else { continue }
                artistCounts[track.artistName, default: 0] += count
            }
            return artistCounts.sorted { $0.value > $1.value }.prefix(safeLimit)
                .map { AgentTopItem(name: $0.key, value: $0.value) }
        case "album":
            var albumCounts: [String: Int] = [:]
            for (trackID, count) in counts {
                guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else { continue }
                albumCounts["\(track.albumTitle) · \(track.artistName)", default: 0] += count
            }
            return albumCounts.sorted { $0.value > $1.value }.prefix(safeLimit)
                .map { AgentTopItem(name: $0.key, value: $0.value) }
        default:
            return counts.sorted { $0.value > $1.value }.prefix(safeLimit)
                .compactMap { entry -> AgentTopItem? in
                    guard let track = model.catalog.tracks.first(where: { $0.id == entry.key }) else { return nil }
                    return AgentTopItem(name: "\(track.title) · \(track.artistName)", value: entry.value)
                }
        }
    }

    public func formatDistribution() async -> [AgentFormatCount] {
        var counts: [String: Int] = [:]
        for track in model.catalog.tracks {
            let format = track.sourceInfo.codec?.lowercased() ?? "未知"
            counts[format, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .map { AgentFormatCount(format: $0.key, count: $0.value) }
    }

    // MARK: - Stats / Diagnostics

    public func listeningSummary() async -> AgentListeningSummary {
        let counts = model.playCounts
        let totalPlays = counts.values.reduce(0, +)
        let uniqueTracks = counts.count
        let totalSeconds = counts.reduce(0.0) { total, entry in
            guard let track = model.catalog.tracks.first(where: { $0.id == entry.key }) else { return total }
            return total + Double(entry.value) * track.duration
        }
        let topArtist = mostPlayedArtist()
        return AgentListeningSummary(
            totalPlays: totalPlays,
            uniqueTracks: uniqueTracks,
            totalListeningSeconds: totalSeconds,
            topArtist: topArtist,
            topAlbum: nil,
            totalFavorites: model.favoriteTracks.count
        )
    }

    public func playbackDiagnostics() async -> AgentPlaybackDiagnostics {
        let track = model.currentTrack
        let isPlaceholder = track.id.rawValue == "placeholder"
        let source = isPlaceholder ? "none" : (track.streamURL?.isFileURL == true ? "local" : "server")
        return AgentPlaybackDiagnostics(
            state: Self.playbackStateName(model.playbackState),
            currentTrackTitle: isPlaceholder ? nil : track.title,
            mediaSource: source,
            lastError: model.playbackError.map(Self.playbackErrorText),
            lastStopReason: model.lastStopReason.title,
            audioSessionActive: model.playbackState == .playing || model.playbackState == .paused,
            queueValid: !model.queue.isEmpty || isPlaceholder,
            isPlaying: model.playbackState == .playing,
            position: model.playbackPosition,
            duration: track.duration
        )
    }

    public func recentErrors(limit: Int) async -> [AgentErrorRecord] {
        // Observability 的最近错误（脱敏摘要）。真实聊天内容、完整路径不进入记录。
        let entries = CrashLog.shared.recent(limit: limit)
        return entries.map {
            AgentErrorRecord(timestamp: $0.timestamp, category: $0.category, message: $0.summary)
        }
    }

    // MARK: - Helpers

    // MARK: - 音乐下载（MovipNote / MoviePilot 插件）

    public func musicSearch(artist: String?, album: String?, albumAliases: [String], keyword: String?, year: Int?, limit: Int, preferLossless: Bool, minSeeders: Int) async -> AgentMusicSearchResult {
        guard let connection = await movipNoteConnection() else {
            return AgentMusicSearchResult(configured: false, message: "音乐下载（MovipNote）未配置")
        }
        do {
            let data = try await MovipNoteClient().search(
                connection,
                artist: artist,
                album: album,
                albumAliases: albumAliases,
                keyword: keyword,
                year: year,
                limit: limit,
                preferLossless: preferLossless,
                minSeeders: minSeeders
            )
            return AgentMusicSearchResult(
                configured: true,
                keyword: data.keyword,
                total: data.total ?? 0,
                albumMatchedAny: data.albumMatchedAny ?? false,
                droppedVideo: data.droppedVideo ?? 0,
                candidates: (data.results ?? []).map(Self.musicCandidate)
            )
        } catch {
            return AgentMusicSearchResult(configured: true, message: error.localizedDescription)
        }
    }

    public func musicDownload(ref: String?, siteID: Int?, index: Int?, magnet: String?, title: String?) async -> AgentMusicDownloadResult {
        guard let connection = await movipNoteConnection() else {
            return AgentMusicDownloadResult(configured: false, message: "音乐下载（MovipNote）未配置")
        }
        do {
            let data = try await MovipNoteClient().download(connection, ref: ref, siteID: siteID, index: index, magnet: magnet, title: title)
            return AgentMusicDownloadResult(
                configured: true,
                success: true,
                hash: data.hash,
                savePath: data.savePath,
                status: data.status
            )
        } catch {
            return AgentMusicDownloadResult(configured: true, message: error.localizedDescription)
        }
    }

    public func musicTasks(status: String?) async -> [AgentMusicTask] {
        guard let connection = await movipNoteConnection() else { return [] }
        do {
            let tasks = try await MovipNoteClient().tasks(connection, status: status)
            return tasks.map {
                AgentMusicTask(
                    hash: $0.hash,
                    title: $0.title,
                    site: $0.site,
                    state: $0.state,
                    progress: $0.progress ?? 0,
                    savePath: $0.savePath
                )
            }
        } catch {
            return []
        }
    }

    /// 读取 MovipNote 连接信息：地址来自 UserDefaults，Token 只从 Keychain 读取。
    private func movipNoteConnection() async -> MovipNoteConnection? {
        let settings = MovipNoteSettings()
        guard let url = settings.normalizedURL else { return nil }
        var token: String?
        if let value = try? await KeychainCredentialVault().retrieve(id: MovipNoteSettings.tokenCredentialID) {
            token = value
        }
        return MovipNoteConnection(baseURL: url, token: token)
    }

    private static func musicCandidate(_ item: MovipNoteCandidate) -> AgentMusicCandidate {
        AgentMusicCandidate(
            index: item.index ?? 0,
            ref: item.ref,
            siteName: item.siteName,
            title: item.title ?? "未知资源",
            audioFormat: item.audioFormat,
            qualityLabel: item.qualityLabel,
            quality: item.quality ?? 0,
            relevance: item.relevance ?? 0,
            albumMatched: item.albumMatched ?? false,
            size: item.size,
            seeders: item.seeders ?? 0
        )
    }

    private func mostPlayedArtist() -> String? {
        var artistCounts: [String: Int] = [:]
        for (trackID, count) in model.playCounts {
            guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else { continue }
            artistCounts[track.artistName, default: 0] += count
        }
        return artistCounts.max { $0.value < $1.value }?.key
    }

    private static func serverInfo(_ account: ServerAccount) -> AgentServerInfo {
        // 隐私模型默认拒绝：私有/局域网主机名（NAS 地址）与用户名不随工具结果发给大模型；
        // 仅公共主机名可透出（非 NAS，且用户可自行删除服务器）。
        let rawHost = account.baseURL?.host
        let host: String? = rawHost.flatMap {
            ServerURLPolicy.isPrivateOrLocal(host: $0) ? nil : $0
        }
        return AgentServerInfo(
            id: account.id.rawValue,
            displayName: account.displayName,
            host: host,
            username: nil,
            serverType: nil,
            serverVersion: nil
        )
    }

    private static func playbackStateName(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .buffering: return "buffering"
        case .playing: return "playing"
        case .paused: return "paused"
        case .stalled: return "stalled"
        case .failed: return "failed"
        }
    }

    private static func playbackErrorText(_ error: PlaybackError) -> String {
        switch error {
        case .networkUnavailable: return "网络不可用"
        case let .unsupportedFormat(format): return "不支持的格式：\(format)"
        case .authorizationFailed: return "认证失败"
        case let .engineFailure(message): return message
        }
    }

    private static func deviceFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }

    private static func deviceTotalBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let capacity = values.volumeTotalCapacity
        else { return nil }
        return Int64(capacity)
    }
}
