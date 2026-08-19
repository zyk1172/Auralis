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
    /// V2 是可恢复的长任务：当前批身份与缩批状态只存活于当前任务，数据库仍是 pending 的事实来源。
    private struct RecommendationIndexV2RuntimeState: Sendable {
        var preferredBatchSize: Int =
            RecommendationIndexV2BatchPolicy.fallbackTracksPerBatch

        var lastBatchMode: String?
        var lastBatchIDs: [String] = []
        var malformedWriteAttempts = 0
    }
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
    private var recommendationIndexV2 = RecommendationIndexV2RuntimeState()

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

    // MARK: - Recommendation Index V2 transport state

    public mutating func configureRecommendationIndexV2(maxOutputTokens: Int) {
        recommendationIndexV2.preferredBatchSize = RecommendationIndexV2BatchPolicy.recommendedLimit(
            maxOutputTokens: maxOutputTokens
        )
    }

    public var recommendationIndexV2PreferredBatchSize: Int {
        recommendationIndexV2.preferredBatchSize
    }

    /// 原生 arguments 被截断、合法对象却漏 items、或批身份不符时，丢弃瞬态批状态并缩批。
    /// 已完成条目不受影响；下一次 next_batch 会从数据库 pending 事实重新取得未写入的前缀。
    public mutating func recoverRecommendationIndexV2Batch() -> Int {
        recommendationIndexV2.preferredBatchSize = RecommendationIndexV2BatchPolicy.reducedLimit(
            from: recommendationIndexV2.preferredBatchSize
        )
        recommendationIndexV2.lastBatchMode = nil
        recommendationIndexV2.lastBatchIDs = []
        recommendationIndexV2.malformedWriteAttempts += 1
        return recommendationIndexV2.preferredBatchSize
    }

    public mutating func recordRecommendationIndexV2Batch(facts: [String: String]) {
        guard let rawIDs = facts["recommendation.index.currentBatchIDs"], !rawIDs.isEmpty else { return }
        recommendationIndexV2.lastBatchIDs = rawIDs.split(separator: ",").map(String.init)
        recommendationIndexV2.lastBatchMode = facts["recommendation.index.currentBatchMode"]
    }

    public mutating func completeRecommendationIndexV2Batch() {
        recommendationIndexV2.lastBatchMode = nil
        recommendationIndexV2.lastBatchIDs = []
        recommendationIndexV2.malformedWriteAttempts = 0
    }

    /// 返回不安全调用的原因；nil 表示当前 items 与刚取得的批次完全一致。
    public func recommendationIndexV2WriteIssue(arguments: [String: String]) -> String? {
        guard let raw = arguments["items"] ?? arguments["itemsJSON"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "缺少必填 items" }
        guard let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([RecommendationIndexV2Classification].self, from: data)
        else { return "items 不是完整的结构化 JSON 数组" }
        guard !recommendationIndexV2.lastBatchIDs.isEmpty else {
            return "没有刚刚由 library_index_v2_next_batch 返回的当前批次"
        }
        let ids = items.map(\.id)
        guard ids.count == Set(ids).count,
              Set(ids) == Set(recommendationIndexV2.lastBatchIDs),
              ids.count == recommendationIndexV2.lastBatchIDs.count
        else { return "items 必须恰好覆盖当前批次的每个真实 ID 一次" }
        if recommendationIndexV2.lastBatchMode == "semanticTagsOnly",
           items.contains(where: { $0.mode != "semanticTagsOnly" }) {
            return "当前批次为 semanticTagsOnly，每项必须使用 mode=semanticTagsOnly" }
        if recommendationIndexV2.lastBatchMode == "full",
           items.contains(where: { $0.mode == "semanticTagsOnly" }) {
            return "当前批次为 full，不能伪装成 semanticTagsOnly" }
        return nil
    }

    /// 只从用户明确写出的“首/首歌/歌曲”数量建立目标；没有明确数量就保持开放，
    /// 由 Intent 的 Completion Predicate 决定何时完成。
    public static func inferredTargetQueueCount(from text: String) -> Int? {
        // 1) 阿拉伯数字：12首 / 20首歌 / 给我12首 / 推荐20首歌曲
        let pattern = #"(?:找|推荐|选择|播放|来|给我)?\s*(\d{1,3})\s*首(?:歌|歌曲)?"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let count = Int(text[range]),
           (1...200).contains(count) {
            return count
        }
        // 2) 中文数字：十二首 / 二十三首 / 一百二十三首 / 两百首（紧邻“首/首歌/首歌曲”才计）
        let chinesePattern = #"([零〇一二两三四五六七八九十百]{1,8})\s*首(?:歌|歌曲)?"#
        guard let chineseRegex = try? NSRegularExpression(pattern: chinesePattern),
              let match = chineseRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return parseChineseCount(String(text[range]))
    }

    /// 中文数字解析：支持 零〇一二两三四五六七八九十百（最大 200）。
    /// “2020年的歌”不会命中（必须紧邻 首/首歌/首歌曲）。
    static func parseChineseCount(_ value: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0,
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        var total = 0
        var digit: Int?
        for ch in value {
            if let number = digits[ch] {
                digit = number
                continue
            }
            switch ch {
            case "十":
                total += (digit ?? 1) * 10
                digit = nil
            case "百":
                total += (digit ?? 1) * 100
                digit = nil
            default:
                return nil
            }
        }
        total += digit ?? 0
        return (1...200).contains(total) ? total : nil
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
    /// 兼容 native JSON 数组（["srv:1","srv:2"]）与文本 ACTION 逗号字符串。
    public static func songIDs(from args: [String: String]) -> [GlobalID] {
        var result: [GlobalID] = []
        for key in ["trackIDs", "trackID", "songIDs", "songID"] {
            guard let raw = args[key] else { continue }
            var pieces: [String] = []
            if let data = raw.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                pieces = array
            } else {
                pieces = raw.split(separator: ",").map(String.init)
            }
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
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
