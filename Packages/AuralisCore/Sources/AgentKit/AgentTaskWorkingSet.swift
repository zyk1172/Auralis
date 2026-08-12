import Domain
import Foundation
import LocalCatalog

/// 单条工具调用的诊断轨迹（供操作记录 / 暂停诊断使用，不携带凭据）。
public struct AgentToolTrace: Codable, Sendable {
    public let tool: String
    public let args: [String: String]
    public let summary: String
    public let reused: Bool
    public let at: Date

    public init(tool: String, args: [String: String], summary: String, reused: Bool, at: Date = .now) {
        self.tool = tool
        self.args = args
        self.summary = summary
        self.reused = reused
        self.at = at
    }
}

/// 音乐候选/队列任务的轻量领域工作集（纯值类型，可独立测试）。
/// 通用生命周期、完成条件、Evidence 与预算由 `AgentTaskState` / `AgentRuntime` 持有；
/// 本类型不再充当 Runtime 核心状态，也不假设所有任务都要凑固定数量的歌曲。
///
/// 职责：
/// 1. **任务级 Tool Result Cache**：同一工具 + 规范化参数再次出现时直接复用结果，
///    避免重复查询 / 重复写操作（缓存键含 toolName + 排序后的参数）；
/// 2. **幂等副作用**：相同写操作（同工具 + 同参数）只真正执行一次；不同参数照常执行，
///    不存在“每任务一次”的互斥保护（例如 queue_replace 可用不同参数多次调用）；
/// 3. **Task Working Set**：累计唯一候选歌曲、已入队歌曲，仅供诊断/提示统计，
///    不阻止模型换搜索词或换策略继续；
/// 4. **诊断统计**：每工具调用次数、缓存命中、唯一歌曲数、最后 N 次调用轨迹。
public struct AgentTaskWorkingSet: Sendable {
    /// 唯一候选歌曲（来自所有 trackCards 结果）。
    public private(set) var uniqueSongIDs: Set<GlobalID> = []
    /// 已入队 / 已播放的歌曲。
    public private(set) var queuedSongIDs: Set<GlobalID> = []
    /// 任务级结果缓存：签名 → 回灌给模型的文本。
    public private(set) var cache: [String: String] = [:]
    /// 每工具调用次数。
    public private(set) var perToolCounts: [String: Int] = [:]
    /// 缓存命中次数（被复用的调用数）。
    public private(set) var cacheHits = 0
    /// 实际执行（非缓存复用）的工具调用次数。
    public private(set) var executedCalls = 0
    /// 连续“无新歌曲”的搜索次数。
    public private(set) var noNewResultsStreak = 0
    /// 最近若干次调用轨迹（诊断用）。
    public private(set) var lastTraces: [AgentToolTrace] = []
    /// 本次任务明确要求的队列数量。未明确数量时为 nil，不以任意固定常量判定完成。
    public let targetQueueCount: Int?
    /// 已成功执行的修改型操作：同工具 + 同参数幂等复用；不同参数照常执行。
    private var successfulSideEffects: [String: String] = [:]

    /// 缓存条数上限（LRU 语义：超出时丢弃最旧）。
    public static let maxCacheSize = 60
    /// 连续多少次“无新结果”后给模型一条信息性提示（不终止任务，模型可换策略）。
    public static let noNewResultsLimit = 3
    /// 允许缓存的只读查询工具（缓存仅限查询，绝不含播放/收藏/评分等可变操作）。
    public static let cacheableTools: Set<String> = [
        "library_search", "library_select_tracks", "server_search", "searchTracks",
        "library_get_song", "library_get_album", "library_get_artist",
        "getFavorites", "library_get_starred", "getRecentHistory", "library_get_recently_played",
        "library_get_random_songs", "library_get_most_played", "library_get_recently_added",
        "library_get_similar_songs", "library_get_genres", "library_get_tracks_by_genre",
        "getLeastPlayed", "getDownloadedTracks", "listPlaylists", "library_get_playlist",
        "recommend_by_mood", "recommend_by_constraints", "smart_queue_generate",
    ]
    /// 受“无新结果”保护约束的搜索类工具（其结果为歌曲清单）。
    public static let searchTools: Set<String> = [
        "library_search", "server_search", "searchTracks", "library_select_tracks",
        "library_get_random_songs", "library_get_tracks_by_genre",
        "recommend_by_mood", "recommend_by_constraints", "smart_queue_generate",
        "getFavorites", "library_get_starred", "getRecentHistory", "library_get_recently_played",
    ]
    /// 会向队列写入歌曲的工具（用于工作集统计入队数量）。
    public static let queueWritingTools: Set<String> = [
        "queue_replace", "queue_append", "queue_play_next",
        "playback_play_song", "playback_play_album", "playback_play_artist",
        "playback_play_playlist", "playback_play_random", "playTrack",
    ]

    public init(targetQueueCount: Int? = nil) {
        if let targetQueueCount, targetQueueCount > 0 {
            self.targetQueueCount = targetQueueCount
        } else {
            self.targetQueueCount = nil
        }
    }

    /// 只从用户明确写出的“首/首歌/歌曲”数量建立目标；没有明确数量就保持开放，
    /// 由 Intent 的 Completion Predicate 决定何时完成。
    public static func inferredTargetQueueCount(from text: String) -> Int? {
        let pattern = #"(?:找|推荐|选择|播放|来|给我)?\s*(\d{1,3})\s*首(?:歌|歌曲)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let count = Int(text[range]),
              (1...200).contains(count)
        else { return nil }
        return count
    }

    // MARK: - 签名与缓存

    /// 规范化工具调用签名（工具名 + 排序后的参数，键值做空白折叠）。
    public static func signature(tool: String, args: [String: String]) -> String {
        let normalized = args.map { key, value in
            "\(key)=\(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }.sorted().joined(separator: "&")
        return "\(tool)|\(normalized)"
    }

    public static func isCacheable(_ tool: String) -> Bool { cacheableTools.contains(tool) }
    public static func isSearchTool(_ tool: String) -> Bool { searchTools.contains(tool) }

    /// 旧工具名和 V2 工具名可能同时被模型看到；先归一成同一副作用语义，
    /// 避免 `replaceQueue` 后又以 `queue_replace` 覆盖队列。
    private static func canonicalSideEffectTool(_ tool: String) -> String {
        switch tool {
        case "replaceQueue", "queue_replace": "queue_replace"
        case "appendToQueue", "queue_append": "queue_append"
        case "playNext", "queue_play_next": "queue_play_next"
        case "playTrack", "playback_play_song": "playback_play_song"
        default: tool
        }
    }

    /// 返回不可执行原因：相同工具 + 相同参数已成功执行过（幂等复用）。
    /// 不同参数（例如第二次 queue_replace 使用不同的歌曲列表）不受任何互斥保护，照常执行。
    public func sideEffectBlockReason(tool: String, args: [String: String]) -> String? {
        let canonical = Self.canonicalSideEffectTool(tool)
        let signature = Self.signature(tool: canonical, args: args)
        if let summary = successfulSideEffects[signature] {
            return "已跳过重复操作：相同的 \(canonical) 已成功执行（\(summary)），不会再次修改播放器状态。"
        }
        return nil
    }

    /// 只在工具成功后登记，失败或超时不会错误地阻止用户的后续重试。
    public mutating func recordSuccessfulSideEffect(tool: String, args: [String: String], summary: String) {
        let canonical = Self.canonicalSideEffectTool(tool)
        let signature = Self.signature(tool: canonical, args: args)
        successfulSideEffects[signature] = summary
    }

    /// 尝试命中缓存：命中返回 true 并更新统计。
    public mutating func tryReuse(tool: String, args: [String: String]) -> String? {
        guard Self.isCacheable(tool) else { return nil }
        let key = Self.signature(tool: tool, args: args)
        guard let text = cache[key] else { return nil }
        cacheHits += 1
        recordCount(tool)
        return text
    }

    /// 记录一次实际执行：写入缓存（仅限可缓存工具）、统计调用次数。
    public mutating func recordExecution(tool: String, args: [String: String], resultText: String) {
        if Self.isCacheable(tool) {
            let key = Self.signature(tool: tool, args: args)
            cache[key] = resultText
            if cache.count > Self.maxCacheSize, let oldest = cache.keys.first {
                cache.removeValue(forKey: oldest)
            }
        }
        executedCalls += 1
        recordCount(tool)
    }

    private mutating func recordCount(_ tool: String) {
        perToolCounts[tool, default: 0] += 1
    }

    // MARK: - 候选 / 队列工作集

    /// 记录一批候选歌曲，返回“是否全部重复（无新歌）”。
    @discardableResult
    public mutating func observeCandidates(_ ids: [GlobalID]) -> Bool {
        let new = Set(ids).subtracting(uniqueSongIDs)
        uniqueSongIDs.formUnion(ids)
        if new.isEmpty {
            noNewResultsStreak += 1
        } else {
            noNewResultsStreak = 0
        }
        // 仅统计“连续无新结果”的轮次，供信息性提示；不终止搜索、不设置任何停止标志。
        return new.isEmpty
    }

    /// 记录一次入队 / 播放的歌曲 ID（仅诊断统计）。
    public mutating func noteQueued(_ ids: [GlobalID]) {
        queuedSongIDs.formUnion(ids)
    }

    /// 从工具参数里解析歌曲 ID 列表（trackIDs / trackID / songIDs / songID）。
    public static func songIDs(from args: [String: String]) -> [GlobalID] {
        var result: [GlobalID] = []
        for key in ["trackIDs", "trackID", "songIDs", "songID"] {
            guard let raw = args[key] else { continue }
            for piece in raw.split(separator: ",") {
                let trimmed = String(piece).trimmingCharacters(in: .whitespaces)
                if let gid = GlobalID(trimmed) { result.append(gid) }
            }
        }
        return result
    }

    // MARK: - 轨迹

    public mutating func recordTrace(_ trace: AgentToolTrace) {
        lastTraces.append(trace)
        if lastTraces.count > 5 { lastTraces.removeFirst(lastTraces.count - 5) }
    }

    // MARK: - 诊断

    /// 暂停 / 上限时的诊断摘要。
    public var diagnosticSummary: String {
        let sorted = perToolCounts.sorted { $0.value > $1.value }
        let perTool = sorted.map { "\($0.key) × \($0.value)" }.joined(separator: "；")
        let traces = lastTraces.map { "\($0.tool)(\($0.args.map { "\($0.key)=\($0.value)" }.joined(separator: ",")))→\($0.summary.prefix(40))" }.joined(separator: " | ")
        return "总调用 \(executedCalls) 次（缓存命中 \(cacheHits) 次）；\(perTool)；唯一候选歌曲 \(uniqueSongIDs.count) 首；已入队 \(queuedSongIDs.count) 首；最后调用：\(traces)"
    }
}
