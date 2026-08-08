import Domain
import Foundation
import LocalCatalog

/// 需要系统服务的工具名集合（App / 设备 / 服务器 / 歌词 / 下载 / 缓存 / 统计 / 诊断）。
/// 这些工具在 AgentToolkit 中无法仅凭 bridge+catalog 执行，必须由 AppShell 提供的
/// AgentSystemService 实现。
public enum SystemToolNames {
    public static let all: Set<String> = [
        "app_get_context",
        "app_open_page",
        "app_get_feature_status",
        "device_get_network_status",
        "device_get_audio_route",
        "device_get_storage_status",
        "server_list",
        "server_get_current",
        "server_test_connection",
        "server_get_capabilities",
        "server_sync_status",
        "lyrics_get",
        "media_download_offline",
        "cache_get_status",
        "stats_get_listening_summary",
        "recommend_by_mood",
        "recommend_by_constraints",
        "stats_get_top_items",
        "library_get_recently_added",
        "library_get_most_played",
        "stats_get_format_distribution",
        "stats_get_storage_distribution",
        "library_find_broken_artwork",
        "library_find_stale_cache",
        "diagnostics_export_report",
        "diagnostics_now_playing",
        "ios_siri_get_status",
        "ios_shortcuts_list",
        "diagnostics_playback",
        "diagnostics_get_recent_errors",
        "music_download",
    ]

    public static func contains(_ name: String) -> Bool { all.contains(name) }
}

/// 系统服务工具的固定执行器：参数校验 → 调用 AgentSystemService → 返回结构化摘要。
/// 所有结果都是简洁、脱敏的文本，不包含凭据 / 完整认证地址 / Token。
public struct SystemToolExecutor {
    public static func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        systemService: any AgentSystemService
    ) async -> ToolResult {
        do {
            switch call.name {
            case "app_get_context":
                let ctx = await systemService.appContext()
                let text = "页面：\(ctx.page) · 服务器：\(ctx.serverName ?? "未连接") · 播放：\(ctx.currentTrackTitle.map { "《\($0)》" } ?? "无") · 状态：\(ctx.playbackState) · 队列 \(ctx.queueCount) 首 · 随机 \(ctx.isShuffled ? "开" : "关") · 循环 \(ctx.repeatMode) · 网络 \(ctx.networkType)\(ctx.isOffline ? "（离线）" : "")"
                return .ok(call, descriptor, text, .text(text))
            case "app_open_page":
                let page = try require(call, "page")
                let allowed = ["首页", "音乐库", "搜索", "ai助手", "设置", "当前播放", "歌词", "播放队列", "下载管理", "服务器管理", "home", "library", "search", "assistant", "settings", "nowplaying", "lyrics", "queue", "downloads", "servers"]
                let normalized = page.lowercased()
                guard allowed.contains(where: { $0 == normalized || $0 == page }) else {
                    throw SystemToolError.invalidParameter("page", page)
                }
                let ok = await systemService.openPage(page)
                return ok ? .ok(call, descriptor, "已打开：\(page)") : .fail(call, descriptor, "无法打开该页面")
            case "app_get_feature_status":
                let status = await systemService.featureStatus()
                var flags: [String] = []
                flags.append("后台播放 \(status.backgroundAudioEnabled ? "可用" : "不可用")")
                flags.append("Siri \(status.siriEnabled ? "可用" : "不可用")")
                flags.append("快捷指令 \(status.shortcutsEnabled ? "可用" : "不可用")")
                flags.append("本地网络权限 \(status.localNetworkPermissionGranted ? "已授权" : "未授权")")
                flags.append("离线模式 \(status.offlineModeEnabled ? "开启" : "关闭")")
                flags.append("本地资料库 \(status.localLibraryAvailable ? "可用" : "不可用")")
                let text = flags.joined(separator: " · ")
                return .ok(call, descriptor, text, .text(text))
            case "device_get_network_status":
                let status = await systemService.networkStatus()
                let text = "网络 \(status.networkType) · \(status.isOffline ? "离线" : "在线") · 服务器 \(status.isServerReachable ? "可达" : "不可达") · \(status.isConstrained ? "受限网络" : "非受限")"
                return .ok(call, descriptor, text, .text(text))
            case "device_get_audio_route":
                let route = await systemService.audioRoute()
                let text = "输出：\(route.outputName)（\(route.outputType)）"
                return .ok(call, descriptor, text, .text(text))
            case "device_get_storage_status":
                let storage = await systemService.storageStatus()
                let text = "元数据 \(Self.bytes(storage.catalogBytes)) · 封面 \(Self.bytes(storage.artworkBytes))（\(storage.artworkCount)） · 歌词 \(Self.bytes(storage.lyricsBytes)) · 离线音频 \(Self.bytes(storage.offlineAudioBytes))（\(storage.offlineAudioCount)） · 剩余空间 \(Self.bytes(storage.freeBytes))"
                return .ok(call, descriptor, text, .text(text))
            case "server_list":
                let servers = await systemService.listServers()
                let text = servers.isEmpty ? "未配置服务器" : servers.map { "\($0.displayName)（\($0.host ?? "?")）" }.joined(separator: "、")
                return .ok(call, descriptor, "服务器 \(servers.count) 个", .text(text))
            case "server_get_current":
                if let server = await systemService.currentServer() {
                    let text = "\(server.displayName)（\(server.serverType ?? "OpenSubsonic") · v\(server.serverVersion ?? "?") · \(server.host ?? "?")）"
                    return .ok(call, descriptor, text, .text(text))
                }
                return .ok(call, descriptor, "未连接服务器", .text("当前未连接服务器"))
            case "server_test_connection":
                let result = await systemService.testServerConnection()
                if result.success {
                    let text = "连接成功 · 延迟 \(Int(result.latencyMs ?? 0))ms · \(result.serverType ?? "") v\(result.serverVersion ?? "?")"
                    return .ok(call, descriptor, text, .text(text))
                }
                return ToolResult(call: call, permission: descriptor.permission, success: false,
                                  summary: "连接失败：\(result.error ?? "未知错误")")
            case "server_get_capabilities":
                let caps = await systemService.serverCapabilities()
                var flags: [String] = []
                flags.append(caps.supportsStructuredLyrics ? "结构化歌词" : "无结构化歌词")
                flags.append(caps.supportsSonicSimilarity ? "声纹相似" : "无声纹相似")
                flags.append(caps.supportsTranscoding ? "转码" : "无转码")
                flags.append(caps.supportsAPIKeyAuthentication ? "APIKey 认证" : "Token 认证")
                flags.append(caps.supportsPodcasts ? "播客" : "无播客")
                flags.append(caps.supportsShares ? "分享" : "无分享")
                let text = flags.joined(separator: " · ")
                return .ok(call, descriptor, text, .text(text))
            case "server_sync_status":
                let status = await systemService.syncStatus()
                var text = status.isRunning ? "同步中（\(status.mode ?? "?")）" : "空闲"
                if let last = status.lastCompletedAt {
                    text += " · 上次同步 \(Self.dateText(last)) · 处理 \(status.lastProcessedCount) 条"
                } else {
                    text += " · 尚未完成过同步"
                }
                if status.isStale { text += " · 已过期" }
                return .ok(call, descriptor, text, .text(text))
            case "lyrics_get":
                let gid = try parseGlobalID(call, "trackID")
                let result = await systemService.lyrics(for: TrackID(rawValue: gid.remoteID))
                let text = result.hasLyrics
                    ? "有歌词（\(result.isSynced ? "逐行" : "纯文本") · \(result.lineCount) 行\(result.language.map { " · \($0)" } ?? "")）"
                    : "暂无歌词"
                return .ok(call, descriptor, text, .text(text))
            case "media_download_offline":
                let gid = try parseGlobalID(call, "trackID")
                let ok = await systemService.downloadOffline(trackID: TrackID(rawValue: gid.remoteID))
                return ok ? .ok(call, descriptor, "已开始下载到离线缓存") : .fail(call, descriptor, "下载失败或已在下载")
            case "cache_get_status":
                let status = await systemService.cacheStatus()
                let text = "封面 \(Self.bytes(status.artworkBytes))（\(status.artworkCount)） · 歌词 \(Self.bytes(status.lyricsBytes)) · 离线音频 \(Self.bytes(status.offlineAudioBytes))（\(status.offlineAudioCount)） · 临时音频 \(Self.bytes(status.tempAudioBytes))"
                return .ok(call, descriptor, text, .text(text))
            case "stats_get_listening_summary":
                let summary = await systemService.listeningSummary()
                var text = "累计播放 \(summary.totalPlays) 次 · \(summary.uniqueTracks) 首 · \(Int(summary.totalListeningSeconds / 60)) 分钟"
                if let artist = summary.topArtist { text += " · 最常听 \(artist)" }
                text += " · 收藏 \(summary.totalFavorites) 首"
                return .ok(call, descriptor, text, .text(text))
            case "recommend_by_mood":
                let mood = try require(call, "mood")
                let limit = (try? intParam(call, "limit")) ?? 10
                let recommendation = await systemService.recommendByMood(mood, limit: limit)
                let text = "按「\(recommendation.mood)」推荐 \(recommendation.tracks.count) 首"
                return .ok(call, descriptor, text, .trackCards(recommendation.tracks))
            case "recommend_by_constraints":
                let constraints = AgentRecommendationConstraints(
                    languages: (call.arguments["languages"] ?? "").split(separator: ",").map(String.init),
                    genres: (call.arguments["genres"] ?? "").split(separator: ",").map(String.init),
                    yearFrom: try? intParam(call, "yearFrom"),
                    yearTo: try? intParam(call, "yearTo"),
                    favoritesOnly: (try? boolParam(call, "favoritesOnly")) ?? false,
                    excludeRecentlyPlayed: (try? boolParam(call, "excludeRecentlyPlayed")) ?? false,
                    onlyOffline: (try? boolParam(call, "onlyOffline")) ?? false,
                    excludeArtist: call.arguments["excludeArtist"],
                    maxTotalMinutes: try? doubleParam(call, "maxTotalMinutes"),
                    losslessOnly: (try? boolParam(call, "losslessOnly")) ?? false,
                    limit: (try? intParam(call, "limit")) ?? 20
                )
                let result = await systemService.recommendByConstraints(constraints)
                let text = "约束推荐 \(result.tracks.count) 首"
                return .ok(call, descriptor, text, .trackCards(result.tracks))
            case "library_get_recently_added":
                let days = (try? intParam(call, "days")) ?? 30
                let limit = (try? intParam(call, "limit")) ?? 20
                let cards = await systemService.recentlyAdded(days: days, limit: limit)
                let text = "最近 \(days) 天添加 \(cards.count) 首"
                return .ok(call, descriptor, text, .trackCards(cards))
            case "library_get_most_played":
                let limit = (try? intParam(call, "limit")) ?? 20
                let cards = await systemService.mostPlayed(limit: limit)
                let text = "最常播放 \(cards.count) 首"
                return .ok(call, descriptor, text, .trackCards(cards))
            case "stats_get_top_items":
                let kind = try require(call, "kind")
                let limit = (try? intParam(call, "limit")) ?? 10
                let items = await systemService.topItems(kind: kind, limit: limit)
                let text = items.isEmpty ? "暂无数据" : items.map { "\($0.name)（\($0.value) 次）" }.joined(separator: "、")
                return .ok(call, descriptor, "最常听 \(items.count) 项", .text(text))
            case "stats_get_format_distribution":
                let dist = await systemService.formatDistribution()
                let text = dist.isEmpty ? "暂无数据" : dist.map { "\($0.format): \($0.count)" }.joined(separator: "、")
                return .ok(call, descriptor, "格式分布 \(dist.count) 种", .text(text))
            case "stats_get_storage_distribution":
                let storage = await systemService.storageStatus()
                let text = "元数据 \(Self.bytes(storage.catalogBytes)) · 封面 \(Self.bytes(storage.artworkBytes))（\(storage.artworkCount)） · 歌词 \(Self.bytes(storage.lyricsBytes)) · 离线音频 \(Self.bytes(storage.offlineAudioBytes))（\(storage.offlineAudioCount)） · 剩余 \(Self.bytes(storage.freeBytes))"
                return .ok(call, descriptor, text, .text(text))
            case "library_find_broken_artwork":
                let limit = (try? intParam(call, "limit")) ?? 10
                let broken = await systemService.brokenArtwork(limit: limit)
                let text = broken.isEmpty ? "未发现封面缓存缺失" : "封面缓存缺失：" + broken.joined(separator: "、")
                return .ok(call, descriptor, text, .text(text))
            case "library_find_stale_cache":
                let limit = (try? intParam(call, "limit")) ?? 10
                let stale = await systemService.staleCache(limit: limit)
                let text = stale.isEmpty ? "未发现陈旧缓存" : "陈旧缓存：" + stale.joined(separator: "、")
                return .ok(call, descriptor, text, .text(text))
            case "diagnostics_export_report":
                let report = await systemService.diagnosticsReport()
                return .ok(call, descriptor, "已生成脱敏诊断报告", .text(report))
            case "ios_siri_get_status":
                let status = await systemService.featureStatus()
                let text = "Siri \(status.siriEnabled ? "可用" : "不可用") · 快捷指令 \(status.shortcutsEnabled ? "可用" : "不可用") · 本地资料库 \(status.localLibraryAvailable ? "可用" : "不可用")"
                return .ok(call, descriptor, text, .text(text))
            case "ios_shortcuts_list":
                let shortcuts = [
                    "问 AI 助手", "播放或暂停", "下一首", "上一首", "播放我的收藏",
                    "播放最近听过的音乐", "播放随机音乐", "切换随机播放", "播放歌曲",
                    "设置睡眠定时", "同步音乐库",
                ]
                let text = shortcuts.joined(separator: "、")
                return .ok(call, descriptor, "快捷指令 \(shortcuts.count) 个", .text(text))
            case "diagnostics_now_playing":
                let status = await systemService.nowPlayingStatus()
                var text = "控制中心/锁屏：\(status.title ?? "无") · \(status.artist ?? "") · 封面 \(status.artworkLoaded ? "已加载" : "未加载")"
                text += " · \(Int(status.position))/\(Int(status.duration)) 秒 · 速率 \(status.rate)"
                if let index = status.queueIndex, let count = status.queueCount {
                    text += " · 队列 \(index + 1)/\(count)"
                }
                text += status.consistentWithApp ? " · 与 App 一致" : " · **与 App 不一致**"
                return .ok(call, descriptor, text, .text(text))
            case "diagnostics_playback":
                let diag = await systemService.playbackDiagnostics()
                var text = "状态 \(diag.state) · 来源 \(diag.mediaSource)"
                if let title = diag.currentTrackTitle { text += " · 《\(title)》" }
                text += " · 音频会话 \(diag.audioSessionActive ? "激活" : "未激活") · 队列 \(diag.queueValid ? "有效" : "无效")"
                if let reason = diag.lastStopReason { text += " · 最近停止原因 \(reason)" }
                if let error = diag.lastError { text += " · 最近错误 \(error)" }
                return .ok(call, descriptor, text, .text(text))
            case "diagnostics_get_recent_errors":
                let limit = (try? intParam(call, "limit")) ?? 20
                let records = await systemService.recentErrors(limit: min(max(limit, 1), 100))
                if records.isEmpty {
                    return .ok(call, descriptor, "暂无错误记录", .text("最近没有记录到错误"))
                }
                let text = records.map { "\(Self.timeText($0.timestamp)) [\($0.category)] \($0.message)" }.joined(separator: "\n")
                return .ok(call, descriptor, "最近错误 \(records.count) 条", .text(text))
            case "music_download":
                let action = (try? require(call, "action"))?.lowercased() ?? ""
                switch action {
                case "search":
                    let result = await systemService.musicSearch(
                        artist: optionalParam(call, "artist"),
                        album: optionalParam(call, "album"),
                        albumAliases: (call.arguments["album_aliases"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                        keyword: optionalParam(call, "keyword"),
                        year: optionalIntParam(call, "year"),
                        limit: optionalIntParam(call, "limit") ?? 10,
                        preferLossless: optionalBoolParam(call, "prefer_lossless") ?? true,
                        minSeeders: optionalIntParam(call, "min_seeders") ?? 0
                    )
                    return Self.musicSearchResult(call, descriptor, result)
                case "download":
                    let result = await systemService.musicDownload(
                        ref: optionalParam(call, "ref"),
                        siteID: optionalIntParam(call, "site_id"),
                        index: optionalIntParam(call, "index"),
                        magnet: optionalParam(call, "magnet"),
                        title: optionalParam(call, "title")
                    )
                    return Self.musicDownloadResult(call, descriptor, result)
                case "tasks":
                    let tasks = await systemService.musicTasks(status: optionalParam(call, "status"))
                    return Self.musicTasksResult(call, descriptor, tasks)
                default:
                    throw SystemToolError.invalidParameter("action", action)
                }

            default:
                return ToolResult(call: call, permission: descriptor.permission, success: false, summary: "未实现的系统工具：\(call.name)")
            }
        } catch let error as SystemToolError {
            return ToolResult(call: call, permission: descriptor.permission, success: false,
                              summary: "\(error.errorDescription ?? "执行失败")")
        } catch {
            return ToolResult(call: call, permission: descriptor.permission, success: false,
                              summary: "执行失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func require(_ call: ToolCall, _ key: String) throws -> String {
        guard let value = call.arguments[key], !value.isEmpty else {
            throw SystemToolError.missingParameter(key)
        }
        return value
    }

    private static func boolParam(_ call: ToolCall, _ key: String) throws -> Bool {
        guard let raw = call.arguments[key] else { throw SystemToolError.invalidParameter(key, "缺失") }
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw SystemToolError.invalidParameter(key, raw)
        }
    }

    private static func doubleParam(_ call: ToolCall, _ key: String) throws -> Double {
        guard let raw = call.arguments[key], let value = Double(raw) else {
            throw SystemToolError.invalidParameter(key, call.arguments[key] ?? "缺失")
        }
        return value
    }

    private static func intParam(_ call: ToolCall, _ key: String) throws -> Int {
        guard let raw = call.arguments[key], let value = Int(raw) else {
            throw SystemToolError.invalidParameter(key, call.arguments[key] ?? "")
        }
        return value
    }


    private static func optionalParam(_ call: ToolCall, _ key: String) -> String? {
        guard let value = call.arguments[key], !value.isEmpty else { return nil }
        return value
    }

    private static func optionalIntParam(_ call: ToolCall, _ key: String) -> Int? {
        guard let raw = call.arguments[key], let value = Int(raw) else { return nil }
        return value
    }

    private static func optionalBoolParam(_ call: ToolCall, _ key: String) -> Bool? {
        guard let raw = call.arguments[key] else { return nil }
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    // MARK: - 音乐下载结果格式化

    private static func musicSearchResult(_ call: ToolCall, _ descriptor: ToolDescriptor, _ result: AgentMusicSearchResult) -> ToolResult {
        guard result.configured else {
            return ToolResult(call: call, permission: descriptor.permission, success: false,
                              summary: "音乐下载未配置：请在 设置 → 音乐下载 填写 MovipNote 地址与 Token")
        }
        if !result.message.isEmpty && result.total == 0 && result.candidates.isEmpty {
            return .ok(call, descriptor, "音乐下载搜索失败", .text("搜索失败：\(result.message)"))
        }
        guard result.total > 0, !result.candidates.isEmpty else {
            return .ok(call, descriptor, "没有找到资源", .text("未找到「\(result.keyword ?? "该音乐")」的音乐资源，可换关键词 / 艺人名 / 英文专辑名重试。"))
        }
        var lines = result.candidates.prefix(10).map { candidate in
            var parts = ["\(candidate.index). [\(candidate.siteName ?? "?")] \(candidate.title)"]
            if let label = candidate.qualityLabel { parts.append("质量=\(label)") }
            if let size = candidate.size { parts.append("大小=\(size)") }
            parts.append("做种=\(candidate.seeders)")
            parts.append("相关度=\(candidate.relevance)")
            if candidate.albumMatched { parts.append("专辑命中") }
            if let ref = candidate.ref { parts.append("ref=\(ref)") }
            return parts.joined(separator: "，")
        }
        lines.insert("共 \(result.total) 条候选（丢弃影视/不确定 \(result.droppedVideo) 条）\(result.albumMatchedAny ? "，已命中目标专辑" : "，未确认命中目标专辑")", at: 0)
        return .ok(call, descriptor, "找到 \(result.total) 条候选", .text(lines.joined(separator: "\n")))
    }

    private static func musicDownloadResult(_ call: ToolCall, _ descriptor: ToolDescriptor, _ result: AgentMusicDownloadResult) -> ToolResult {
        guard result.configured else {
            return ToolResult(call: call, permission: descriptor.permission, success: false,
                              summary: "音乐下载未配置：请在 设置 → 音乐下载 填写 MovipNote 地址与 Token")
        }
        if result.success, let hash = result.hash {
            let text = "已加入下载：\(hash)（状态 \(result.status ?? "downloading")）\(result.savePath.map { "，保存到 \($0)" } ?? "")"
            return .ok(call, descriptor, "已开始下载", .text(text))
        }
        return ToolResult(call: call, permission: descriptor.permission, success: false,
                          summary: "下载失败：\(result.message.isEmpty ? "未知原因" : result.message)")
    }

    private static func musicTasksResult(_ call: ToolCall, _ descriptor: ToolDescriptor, _ tasks: [AgentMusicTask]) -> ToolResult {
        guard !tasks.isEmpty else {
            return .ok(call, descriptor, "暂无下载任务", .text("当前没有音乐下载任务"))
        }
        let text = tasks.prefix(20).map { task in
            "\(task.title)（\(task.state) \(String(format: "%.0f", task.progress))%）\(task.site.map { " · \($0)" } ?? "")"
        }.joined(separator: "\n")
        return .ok(call, descriptor, "下载任务 \(tasks.count) 个", .text(text))
    }

    private static func parseGlobalID(_ call: ToolCall, _ key: String) throws -> GlobalID {
        let raw = try require(call, key)
        guard let gid = GlobalID(raw) else {
            throw SystemToolError.invalidParameter(key, raw)
        }
        return gid
    }

    private static func bytes(_ value: Int64) -> String {
        let mb = Double(value) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(Int(value / 1024)) KB"
    }

    private static func dateText(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static func timeText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

public enum SystemToolError: Error, LocalizedError, Sendable {
    case missingParameter(String)
    case invalidParameter(String, String)

    public var errorDescription: String? {
        switch self {
        case let .missingParameter(key): "缺少参数：\(key)"
        case let .invalidParameter(key, value): "参数 \(key) 非法：\(value)"
        }
    }
}
