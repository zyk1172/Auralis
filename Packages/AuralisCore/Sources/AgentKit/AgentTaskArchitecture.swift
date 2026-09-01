import AIKit
import Domain
import Foundation
import LocalCatalog

/// 用户请求的粗粒度意图。意图只用于任务理解、工具排序、提示、完成语义与 UI/诊断，
/// 不再是普通模型工具或可信 Stateful Skill 之外工具的执行权限边界。
public enum AgentTaskIntent: String, Codable, CaseIterable, Sendable {
    case conversation
    case librarySearch
    case playbackControl
    case playbackQuery
    case musicDiscovery
    case queueManagement
    case queueQuery
    case playlistManagement
    case playlistQuery
    case libraryManagement
    case serverManagement
    case diagnostics
    case musicAppreciation
    case musicDownload
    case memoryManagement
}

/// 工具副作用风险（deprecated / diagnostics-only）。Runtime 不再据此拒绝任何普通工具；
/// 保留枚举仅为旧任务记录、日志与 UI 分类兼容。
public enum AgentRisk: Int, Codable, Comparable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 能力域描述（deprecated / diagnostics-only）。
/// 曾用于按意图隔离工具；现在保留类型仅为 migration / Codable / 日志兼容，
/// Runtime 不再因缺少 scope 而拒绝已注册的普通工具。
public enum GrantedScope: String, Codable, CaseIterable, Sendable, Hashable {
    case catalogRead
    case playbackWrite
    case queueWrite
    case playlistWrite
    case annotationWrite
    case serverRead
    case serverWrite
    case downloadWrite
    case memoryRead
    case memoryWrite
    case diagnosticsRead
    case externalRead
}

public struct AgentTaskBudget: Codable, Equatable, Sendable {
    /// 0 表示不额外限制，直接跟随当前 Provider / ModelCapabilities。
    public static let followProvider = 0

    /// 极端看门狗：任务总墙钟时间。
    public var wallClockSeconds: TimeInterval

    /// 单次模型请求的输入限制。
    /// 0 = 跟随 Provider。
    public var maxInputTokens: Int

    /// 单次模型请求的输出限制。
    /// 0 = 跟随 Provider。
    public var maxOutputTokens: Int

    /// 极端防失控模型轮次看门狗。
    public var maxModelRounds: Int

    /// 仅诊断，不作为正常任务终止条件。
    public var maxNoProgressRounds: Int

    /// 仅诊断，不作为正常任务终止条件。
    public var maxRepeatedToolPattern: Int

    public init(
        wallClockSeconds: TimeInterval = 60 * 60,
        maxInputTokens: Int = AgentTaskBudget.followProvider,
        maxOutputTokens: Int = AgentTaskBudget.followProvider,
        maxModelRounds: Int = 1_000,
        maxNoProgressRounds: Int = 3,
        maxRepeatedToolPattern: Int = 4
    ) {
        self.wallClockSeconds = wallClockSeconds
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxModelRounds = maxModelRounds
        self.maxNoProgressRounds = maxNoProgressRounds
        self.maxRepeatedToolPattern = maxRepeatedToolPattern
    }

    public func resolvedInputTokens(
        capabilities: ModelCapabilities
    ) -> Int {
        guard maxInputTokens > 0 else {
            return capabilities.maxContextTokens
        }

        return min(
            maxInputTokens,
            capabilities.maxContextTokens
        )
    }

    public func resolvedOutputTokens(
        capabilities: ModelCapabilities
    ) -> Int {
        guard maxOutputTokens > 0 else {
            return capabilities.maxOutputTokens
        }

        return min(
            maxOutputTokens,
            capabilities.maxOutputTokens
        )
    }
}

public enum AgentCompletionPredicate: Codable, Equatable, Sendable {
    case modelAnswer
    /// 真实成功执行了至少一个工具（Tool Success ≠ Evidence）。
    case successfulToolResult
    /// 已产生最终歌曲选择（result_present_tracks final）。targetCount 存在时
    /// 必须 finalSelection.count >= targetCount，否则不完成。
    case finalTrackSelection
    case queueMutation
    case playlistMutation
    case playbackMutation
    case indexPendingCountIsZero
    case appreciationWithEvidence

    /// 诊断用稳定标识。
    public var predicateName: String {
        switch self {
        case .modelAnswer: return "modelAnswer"
        case .successfulToolResult: return "successfulToolResult"
        case .finalTrackSelection: return "finalTrackSelection"
        case .queueMutation: return "queueMutation"
        case .playlistMutation: return "playlistMutation"
        case .playbackMutation: return "playbackMutation"
        case .indexPendingCountIsZero: return "indexPendingCountIsZero"
        case .appreciationWithEvidence: return "appreciationWithEvidence"
        }
    }
}

/// 每个任务的路由/诊断策略（intent、completion、budget 等）。
/// `authorizes` 不再构成模型能力门禁，保留方法仅为兼容旧调用方，恒返回 true；
/// 真实副作用授权由 ToolRuntime 按 canonical operation 执行。
public struct AgentTaskPolicy: Codable, Equatable, Sendable {
    public let intent: AgentTaskIntent
    public let scopes: Set<GrantedScope>
    public let allowedToolGroups: Set<ToolGroup>
    public let allowedPermissions: Set<ToolPermission>
    public let maxRisk: AgentRisk
    public let completion: AgentCompletionPredicate
    public let budget: AgentTaskBudget
    /// 普通交互式 Agent 的行为收敛预算（模型轮次/总调用/相同参数/搜索/拒绝/畸形参数）。
    /// 推荐索引走专用 Runtime，不经过普通循环；legacy `AgentRunner` 兼容面使用宽松预算。
    public let convergence: AgentConvergencePolicy

    /// `.successfulToolResult` 的完成条件不是“任意工具成功”，而是当前任务
    /// 至少有一个与意图匹配的真实工具成功。这样 app_get_context、memory_list
    /// 等旁路工具不会误报搜索/诊断/管理任务已经完成。
    public var completionToolNames: Set<String> {
        switch intent {
        case .conversation:
            return []
        case .librarySearch:
            return [
                "searchTracks", "searchAlbums", "searchArtists", "getTrack", "getAlbum", "getArtist",
                "library_search", "server_search", "library_get_song", "library_get_album", "library_get_artist",
                "library_get_playlist", "library_get_catalog_index", "library_get_catalog_tracks",
                "getFavorites", "library_get_starred", "library_get_disliked", "library_get_recently_played",
            ]
        case .playbackControl:
            return [
                "playTrack", "playAlbum", "playPlaylist", "pause", "resume", "seek", "next", "previous",
                "playback_play_song", "playback_play_album", "playback_play_artist", "playback_play_playlist",
                "playback_play_random", "playback_pause", "playback_resume", "playback_next", "playback_previous",
                "playback_seek", "playback_set_shuffle", "playback_set_repeat", "playback_set_speed",
                "playback_set_sleep_timer", "playback_cancel_sleep_timer",
            ]
        case .playbackQuery:
            return [
                "playback_get_state", "diagnostics_now_playing", "getCurrentTrack", "getCurrentQueue",
            ]
        case .musicDiscovery:
            return [
                "library_search", "library_select_tracks", "library_get_catalog_index", "library_get_catalog_tracks",
                "library_index_read", "server_search", "recommend_by_mood", "recommend_by_constraints",
                "result_present_tracks", "getSimilarTracks", "library_get_similar_songs",
            ]
        case .queueManagement:
            return [
                "queue_remove", "removeFromQueue", "reorderQueue", "clearQueue", "queue_get", "queue_append",
                "queue_append_many", "queue_play_next", "queue_play_next_many", "queue_replace", "queue_clear", "queue_shuffle_remaining", "queue_move",
            ]
        case .queueQuery:
            return ["queue_get", "getCurrentQueue"]
        case .playlistManagement:
            return [
                "listPlaylists", "getPlaylist", "createPlaylist", "renamePlaylist", "addTracksToPlaylist",
                "removeTracksFromPlaylist", "reorderPlaylist", "duplicatePlaylist", "mergePlaylists", "deletePlaylist",
                "playlist_create", "playlist_add_songs", "playlist_rename", "playlist_remove_songs", "playlist_move",
                "playlist_duplicate", "playlist_merge", "playlist_delete", "queue_save_as_playlist",
            ]
        case .playlistQuery:
            return ["listPlaylists", "getPlaylist", "library_get_playlist"]
        case .libraryManagement:
            return [
                "getFavorites", "library_search", "library_get_summary", "library_get_song", "library_get_album", "library_get_artist",
                "library_get_recently_added", "library_get_most_played", "library_get_recently_played",
                "library_get_starred", "library_get_disliked", "library_find_duplicates", "library_find_metadata_issues",
                "library_find_broken_artwork", "library_find_stale_cache", "library_find_unplayable",
                "likeTrack", "unlikeTrack", "favoriteAlbum", "unfavoriteAlbum", "favoriteArtist", "unfavoriteArtist",
                "setRating", "clearRating", "favorite_set", "rating_set", "preference_set_disliked",
                "refreshLibrary", "server_sync_start", "library_index_status", "library_index_read",
            ]
        case .serverManagement:
            return [
                "listServers", "getActiveServer", "testServerConnection", "getSyncStatus", "server_list",
                "server_get_current", "server_test_connection", "server_get_capabilities", "server_sync_status",
                "server_search", "server_sync_start", "server_switch", "server_remove", "switchServer", "removeServer",
                "addServer", "updateServer",
            ]
        case .diagnostics:
            return [
                "app_get_context", "app_get_feature_status", "device_get_network_status", "device_get_audio_route",
                "device_get_storage_status", "playback_get_state", "getCurrentTrack", "getCurrentQueue",
                "diagnostics_export_report", "diagnostics_now_playing", "diagnostics_playback", "diagnostics_get_recent_errors",
                "ios_siri_get_status", "ios_shortcuts_list", "stats_get_listening_summary", "stats_get_format_distribution",
                "stats_get_storage_distribution",
            ]
        case .musicAppreciation:
            return ["music_appreciate", "music_get_public_evidence", "lyrics_get", "library_get_song"]
        case .musicDownload:
            return ["music_download", "music_download_search", "music_download_submit", "music_download_status", "music_download_tasks", "music_download_history", "music_download_history_remove", "music_download_history_clean", "media_download_offline", "cache_get_status"]
        case .memoryManagement:
            return ["memory_save", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"]
        }
    }

    public init(
        intent: AgentTaskIntent,
        scopes: Set<GrantedScope>,
        allowedToolGroups: Set<ToolGroup>,
        allowedPermissions: Set<ToolPermission> = [.readOnly],
        maxRisk: AgentRisk = .none,
        completion: AgentCompletionPredicate = .modelAnswer,
        budget: AgentTaskBudget = AgentTaskBudget(),
        convergence: AgentConvergencePolicy = .interactive
    ) {
        self.intent = intent
        self.scopes = scopes
        self.allowedToolGroups = allowedToolGroups
        self.allowedPermissions = allowedPermissions
        self.maxRisk = maxRisk
        self.completion = completion
        self.budget = budget
        self.convergence = convergence
    }

    /// deprecated / diagnostics-only：permissive direct-execution runtime 不再用
    /// 意图/权限/风险/scope 拒绝已注册的普通音乐工具。恒返回 true。
    public func authorizes(_ descriptor: ToolDescriptor) -> Bool {
        true
    }

    public static func risk(for permission: ToolPermission) -> AgentRisk {
        switch permission {
        case .readOnly: .none
        case .reversible: .medium
        case .destructive: .high
        }
    }

    public static func policy(for intent: AgentTaskIntent) -> AgentTaskPolicy {
        let read: Set<ToolPermission> = [.readOnly]
        let write: Set<ToolPermission> = [.readOnly, .reversible]
        let destructive: Set<ToolPermission> = [.readOnly, .reversible, .destructive]
        switch intent {
        case .conversation:
            return .init(intent: intent, scopes: [.catalogRead, .memoryRead], allowedToolGroups: [.catalog, .memory], allowedPermissions: read)
        case .librarySearch:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead], allowedToolGroups: [.catalog, .server], allowedPermissions: read, completion: .successfulToolResult)
        case .playbackControl:
            return .init(intent: intent, scopes: [.catalogRead, .playbackWrite], allowedToolGroups: [.catalog, .playback], allowedPermissions: write, maxRisk: .medium, completion: .playbackMutation, convergence: .compoundTask)
        case .playbackQuery:
            return .init(intent: intent, scopes: [.catalogRead, .diagnosticsRead], allowedToolGroups: [.catalog, .playback], allowedPermissions: read)
        case .musicDiscovery:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .queueWrite, .externalRead], allowedToolGroups: [.catalog, .server, .playback], allowedPermissions: write, maxRisk: .medium, completion: .modelAnswer, convergence: .compoundTask)
        case .queueManagement:
            return .init(intent: intent, scopes: [.catalogRead, .playbackWrite, .queueWrite], allowedToolGroups: [.catalog, .playback], allowedPermissions: destructive, maxRisk: .high, completion: .queueMutation, convergence: .compoundTask)
        case .queueQuery:
            return .init(intent: intent, scopes: [.catalogRead], allowedToolGroups: [.catalog, .playback], allowedPermissions: read)
        case .playlistManagement:
            return .init(intent: intent, scopes: [.catalogRead, .playlistWrite], allowedToolGroups: [.catalog, .playlist], allowedPermissions: destructive, maxRisk: .high, completion: .playlistMutation, convergence: .compoundTask)
        case .playlistQuery:
            return .init(intent: intent, scopes: [.catalogRead], allowedToolGroups: [.catalog, .playlist], allowedPermissions: read)
        case .libraryManagement:
            return .init(intent: intent, scopes: [.catalogRead, .annotationWrite], allowedToolGroups: [.catalog, .annotation], allowedPermissions: write, maxRisk: .medium, completion: .successfulToolResult, convergence: .compoundTask)
        case .serverManagement:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .serverWrite], allowedToolGroups: [.catalog, .server], allowedPermissions: destructive, maxRisk: .high, completion: .successfulToolResult, convergence: .compoundTask)
        case .diagnostics:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .diagnosticsRead], allowedToolGroups: [.catalog, .playback, .server], allowedPermissions: read, completion: .successfulToolResult)
        case .musicAppreciation:
            return .init(intent: intent, scopes: [.catalogRead, .externalRead], allowedToolGroups: [.catalog], allowedPermissions: read, completion: .appreciationWithEvidence)
        case .musicDownload:
            return .init(intent: intent, scopes: [.catalogRead, .serverRead, .downloadWrite], allowedToolGroups: [.catalog, .server, .download], allowedPermissions: write, maxRisk: .medium, completion: .successfulToolResult, convergence: .longRunning)
        case .memoryManagement:
            return .init(intent: intent, scopes: [.memoryRead, .memoryWrite], allowedToolGroups: [.memory], allowedPermissions: destructive, maxRisk: .high, completion: .successfulToolResult)
        }
    }
}

public enum AgentEvidenceSource: String, Codable, Sendable {
    case localCatalog
    case derivedLocalStatistic
    case playbackState
    case server
    case externalAPI
    case musicBrainz
    case listenBrainz
    case critiqueBrainz
    case userStatement
    case modelInference
}

public struct AgentEvidence: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: AgentEvidenceSource
    public let provenance: String
    public let confidence: Double
    public let fetchedAt: Date
    public let entityID: String?
    public let claim: String
    /// Exact disclosure domains required to replay this claim to a Provider.
    /// The optional initializer input keeps old persisted evidence fail-closed:
    /// legacy combined local statistics require both private domains.
    public let requiredDisclosureCategories: Set<AIPrivacyCategory>

    public init(
        id: UUID = UUID(),
        source: AgentEvidenceSource,
        provenance: String,
        confidence: Double,
        fetchedAt: Date = .now,
        entityID: String? = nil,
        claim: String,
        requiredDisclosureCategories: Set<AIPrivacyCategory>? = nil
    ) {
        self.id = id
        self.source = source
        self.provenance = provenance
        self.confidence = min(max(confidence, 0), 1)
        self.fetchedAt = fetchedAt
        self.entityID = entityID
        self.claim = claim
        self.requiredDisclosureCategories = requiredDisclosureCategories
            ?? Self.legacyDisclosureCategories(for: source)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case provenance
        case confidence
        case fetchedAt
        case entityID
        case claim
        case requiredDisclosureCategories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(AgentEvidenceSource.self, forKey: .source)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.source = source
        self.provenance = try container.decode(String.self, forKey: .provenance)
        let decodedConfidence = try container.decode(Double.self, forKey: .confidence)
        self.confidence = min(max(decodedConfidence, 0), 1)
        self.fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        self.entityID = try container.decodeIfPresent(String.self, forKey: .entityID)
        self.claim = try container.decode(String.self, forKey: .claim)
        self.requiredDisclosureCategories = try container.decodeIfPresent(
            Set<AIPrivacyCategory>.self,
            forKey: .requiredDisclosureCategories
        ) ?? Self.legacyDisclosureCategories(for: source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encodeIfPresent(entityID, forKey: .entityID)
        try container.encode(claim, forKey: .claim)
        try container.encode(requiredDisclosureCategories, forKey: .requiredDisclosureCategories)
    }

    private static func legacyDisclosureCategories(for source: AgentEvidenceSource) -> Set<AIPrivacyCategory> {
        switch source {
        case .localCatalog, .playbackState:
            return [.metadata]
        case .derivedLocalStatistic:
            // PR #11 persisted one claim containing both play count and
            // favorite/rating state. Replaying it needs both permissions.
            return [.playbackHistory, .favoritesAndRatings]
        case .server, .externalAPI, .musicBrainz, .listenBrainz, .critiqueBrainz,
             .userStatement, .modelInference:
            return []
        }
    }
}

public struct AgentTaskProgress: Codable, Sendable, Equatable {
    public var modelRounds = 0
    public var toolCalls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var noProgressRounds = 0
    public var lastProgressAt = Date()
}

public enum AgentTaskLifecycleStatus: String, Codable, Sendable {
    case queued
    case running
    case waitingForModel
    case waitingForTool
    case completed
    case insufficient
    case failed
    case cancelled
    case interrupted
}

public enum AgentTaskCompletionState: String, Codable, Sendable {
    case pending
    case satisfied
    case insufficientEvidence
    case failed
}

/// 与音乐领域工作集分离的通用任务状态。领域状态可增量附加，不再成为主循环本身。
public struct AgentTaskState: Codable, Identifiable, Sendable {
    public let id: UUID
    public let intent: AgentTaskIntent
    public let goal: String
    public var status: AgentTaskLifecycleStatus
    public var facts: [String: String]
    public var evidence: [AgentEvidence]
    public var candidateIDs: Set<String>
    public var selectedIDs: Set<String>
    public var completedActions: [String]
    public var pendingActions: [String]
    public var errors: [String]
    public var progress: AgentTaskProgress
    public var completed: Bool
    public var completionState: AgentTaskCompletionState
    public var errorState: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var recentToolSignatures: [String]
    public var repeatedToolPatternCount: Int
    /// 真实成功执行过的工具名（每次成功追加）。
    public var successfulToolNames: [String]
    /// 真实成功执行的工具总数（Tool Success 是独立于 Evidence 的事实）。
    public var successfulToolCount: Int
    /// 本次 run 的结构化诊断（不含凭据/敏感数据；用于排查不收敛等行为问题）。
    public var diagnostics: AgentRunDiagnostics?

    public init(id: UUID = UUID(), intent: AgentTaskIntent, goal: String, startedAt: Date = .now) {
        self.id = id
        self.intent = intent
        self.goal = goal
        self.status = .running
        self.facts = [:]
        self.evidence = []
        self.candidateIDs = []
        self.selectedIDs = []
        self.completedActions = []
        self.pendingActions = []
        self.errors = []
        self.progress = AgentTaskProgress(lastProgressAt: startedAt)
        self.completed = false
        self.completionState = .pending
        self.errorState = nil
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.recentToolSignatures = []
        self.repeatedToolPatternCount = 0
        self.successfulToolNames = []
        self.successfulToolCount = 0
        self.diagnostics = nil
    }

    public mutating func recordProgress(action: String? = nil, at date: Date = .now) {
        if let action, !action.isEmpty { completedActions.append(action) }
        progress.noProgressRounds = 0
        progress.lastProgressAt = date
        updatedAt = date
    }

    public mutating func recordNoProgress() {
        progress.noProgressRounds += 1
        updatedAt = .now
    }

    public mutating func recordToolCall(name: String, arguments: [String: String]) {
        let values = arguments.map { "\($0.key)=\($0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }.sorted()
        let signature = name + "|" + values.joined(separator: "&")
        if recentToolSignatures.last == signature {
            repeatedToolPatternCount += 1
        } else {
            repeatedToolPatternCount = 1
        }
        recentToolSignatures.append(signature)
        if recentToolSignatures.count > 12 { recentToolSignatures.removeFirst(recentToolSignatures.count - 12) }
        updatedAt = .now
    }

    /// 仅剩两个极端看门狗：总墙钟时间、模型轮次（默认 1000）。
    /// noProgress / repeatedToolPattern 只作诊断统计，不再终止任何正常任务。
    public func budgetViolation(policy: AgentTaskPolicy, now: Date = .now) -> AgentRuntimeError? {
        if now.timeIntervalSince(startedAt) > policy.budget.wallClockSeconds { return .wallClockBudgetExceeded }
        if progress.modelRounds >= policy.budget.maxModelRounds { return .modelRoundBudgetExceeded }
        return nil
    }
}

public enum AgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    /// 未知工具（注册表里不存在），而不是“权限不足”。
    case toolOutsidePolicy(String)
    case wallClockBudgetExceeded
    case modelRoundBudgetExceeded
    /// deprecated：不再作为任务终止条件；保留仅为兼容旧代码。
    case noProgress
    /// deprecated：不再作为任务终止条件；保留仅为兼容旧代码。
    case repeatedToolPattern

    public var errorDescription: String? {
        switch self {
        case let .toolOutsidePolicy(name): "无法执行：工具 \(name) 不存在。"
        case .wallClockBudgetExceeded: "任务运行时间过长，已停止以保护设备。"
        case .modelRoundBudgetExceeded: "任务运行轮次异常过多，已停止以保护设备。"
        case .noProgress: "任务连续多轮没有取得新进展。"
        case .repeatedToolPattern: "任务重复调用同一工具且没有形成新进展。"
        }
    }
}

public enum AgentFailureKind: String, Codable, Sendable {
    case cancelled
    case timeout
    case authentication
    case rateLimited
    case transientNetwork
    case serverUnavailable
    case invalidConfiguration
    case incompatibleResponse
    case permanent

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transientNetwork, .serverUnavailable: true
        default: false
        }
    }
}

public enum AgentFailureClassifier {
    public static func classify(_ error: Error) -> AgentFailureKind {
        if error is CancellationError { return .cancelled }
        if error is AgentRunnerError { return .timeout }
        if let provider = error as? AIProviderError {
            switch provider {
            case .missingCredential, .invalidEndpoint, .unsupportedEndpointProtocol, .insecureEndpoint:
                return .invalidConfiguration
            case .outputTruncated:
                // 由推荐索引 Runtime 缩批恢复；不能触发同一超大请求的通用网络重试。
                return .permanent
            case let .httpStatus(status):
                if status == 401 || status == 403 { return .authentication }
                if status == 429 { return .rateLimited }
                if (500...599).contains(status) { return .serverUnavailable }
                return .permanent
            case let .httpStatusDetail(status, _):
                if status == 401 || status == 403 { return .authentication }
                if status == 429 { return .rateLimited }
                if (500...599).contains(status) { return .serverUnavailable }
                return .permanent
            case .transport:
                return .transientNetwork
            case let .malformedResponse(_, retryable):
                return retryable ? .transientNetwork : .incompatibleResponse
            }
        }
        if let url = error as? URLError {
            if url.code == .cancelled { return .cancelled }
            if url.code == .timedOut { return .timeout }
            return .transientNetwork
        }
        return .permanent
    }
}

public enum AgentIntentClassifier {
    public static func classify(_ text: String, historyText: String = "") -> AgentTaskIntent {
        classify(
            text: text,
            historyText: historyText,
            precomputedSemantics: nil
        )
    }

    /// 复用一次 turn 的共享 semantics，禁止各层独立重新分析同一段用户文本。
    public static func classify(
        text: String,
        historyText: String = "",
        precomputedSemantics: AgentRequestSemantics? = nil
    ) -> AgentTaskIntent {
        let directIntent = classifyDirect(text, precomputedSemantics: precomputedSemantics)
        guard !historyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              directIntent == .conversation,
              isContinuation(text)
        else { return directIntent }

        // “继续”本身没有业务语义；只有在它是短后续指令时，才继承最近一条
        // 完整任务的意图。这样“继续构建索引”不会因为上一轮报错后再次输入
        // “继续”而退回 conversation，索引工具也会重新进入 schema。
        let historyIntent = classifyDirect(historyText)
        return historyIntent == .conversation ? directIntent : historyIntent
    }

    private static func classifyDirect(
        _ text: String,
        precomputedSemantics: AgentRequestSemantics? = nil
    ) -> AgentTaskIntent {
        let semantics = precomputedSemantics ?? AgentRequestSemantics.analyze(text)

        // Appreciation is a deterministic evidence workflow, so it is
        // checked before the shared playback/diagnostic domain mapping.
        if semantics.isMusicAppreciation {
            return .musicAppreciation
        }
        if semantics.domain == .memory { return .memoryManagement }
        if semantics.isRecommendationIndex {
            return .libraryManagement
        }
        if semantics.domain == .download { return .musicDownload }
        if semantics.domain == .server { return .serverManagement }
        if semantics.domain == .diagnostics {
            return .diagnostics
        }
        switch semantics.domain {
        case .playlist:
            return semantics.isReadOnly ? .playlistQuery : .playlistManagement
        case .queue:
            return semantics.isReadOnly ? .queueQuery : .queueManagement
        case .playback:
            return semantics.isReadOnly ? .playbackQuery : .playbackControl
        case .recommendation:
            return .musicDiscovery
        case .musicLibrary:
            return .librarySearch
        case .conversation, .web, .system, .memory, .download, .server, .diagnostics, .customTool:
            break
        }
        return .conversation
    }

    private static func isContinuation(_ text: String) -> Bool {
        AgentHistoryPolicy.isExplicitContinuation(text)
    }
}

/// 将文字入口或 UI 显式入口解析为单次任务策略。业务识别只发生在任务创建时，
/// 低层模型循环只消费结构化 policy，不再包含推荐索引等业务分支。
public enum AgentTaskPolicyResolver {
    public static func resolve(
        text: String,
        historyText: String = "",
        explicitIntent: AgentTaskIntent? = nil
    ) -> AgentTaskPolicy {
        resolve(
            text: text,
            historyText: historyText,
            explicitIntent: explicitIntent,
            precomputedSemantics: nil
        )
    }

    public static func resolve(
        text: String,
        historyText: String = "",
        explicitIntent: AgentTaskIntent? = nil,
        precomputedSemantics: AgentRequestSemantics? = nil
    ) -> AgentTaskPolicy {
        let intent = explicitIntent ?? AgentIntentClassifier.classify(
            text: text,
            historyText: historyText,
            precomputedSemantics: precomputedSemantics
        )
        let base = AgentTaskPolicy.policy(for: intent)
        guard intent == .libraryManagement,
              RecommendationIndexTaskRules.requiresCompleteBuild(
                text: text,
                historyText: historyText,
                precomputedSemantics: precomputedSemantics
              )
        else { return base }

        var budget = base.budget

        // 全库索引属于可持续推进的长任务。
        // 单次 token 完全跟随用户配置的 Provider，不再二次写死 256K / 16K。
        budget.wallClockSeconds = 24 * 60 * 60
        budget.maxInputTokens = AgentTaskBudget.followProvider
        budget.maxOutputTokens = AgentTaskBudget.followProvider

        // 这里只是极端防死循环看门狗。
        // 10,000+ 首库即使缩到最小 8 首 / batch 也不能正常撞到这里。
        budget.maxModelRounds = 10_000

        // 仅诊断，不作为正常终止条件。
        budget.maxNoProgressRounds = 3
        return AgentTaskPolicy(
            intent: intent,
            scopes: base.scopes,
            allowedToolGroups: base.allowedToolGroups,
            allowedPermissions: base.allowedPermissions,
            maxRisk: base.maxRisk,
            completion: .indexPendingCountIsZero,
            budget: budget,
            convergence: .longRunning
        )
    }
}

/// Recommendation Index 的任务兼容规则只负责在任务创建边界选择恢复策略；真正的
/// 批次状态、重试、checkpoint 和完成判定由 RecommendationIndexSkillRuntime 持有。
public enum RecommendationIndexTaskRules {
    public static func requiresCompleteBuild(text: String, historyText: String = "") -> Bool {
        requiresCompleteBuild(text: text, historyText: historyText, precomputedSemantics: nil)
    }

    public static func requiresCompleteBuild(
        text: String,
        historyText: String = "",
        precomputedSemantics: AgentRequestSemantics? = nil
    ) -> Bool {
        let semantics = precomputedSemantics ?? AgentRequestSemantics.analyze(text, historyText: historyText)
        return semantics.isRecommendationIndexBuild
    }
}

public enum AgentModelAnswerDecision: Sendable, Equatable {
    case accept
    case continueTask(String)
    case fail(String)
}

/// 把工具输出归并为 TaskState。Runner 不再解析工具摘要中的中文数字或业务关键词。
public enum AgentTaskReducer {
    @discardableResult
    public static func apply(
        result: ToolResult,
        descriptor: ToolDescriptor,
        to state: inout AgentTaskState
    ) -> Bool {
        guard result.success else {
            // 失败本身也是新信息（新错误事实）：换策略的判断依据。记录为进展，不当作停滞。
            state.errors.append(result.summary)
            state.errorState = result.summary
            state.recordProgress(action: "\(descriptor.name) 失败：\(result.summary)")
            return false
        }

        // 真实成功工具结果：独立于 Evidence 的事实（memory_list 等不产生 Evidence 但确实执行成功）。
        state.successfulToolNames.append(descriptor.name)
        state.successfulToolCount += 1

        var changed = false
        for (key, value) in result.facts where state.facts[key] != value {
            state.facts[key] = value
            changed = true
        }

        var evidence = result.evidence
        if evidence.isEmpty, let source = evidenceSource(for: descriptor.evidencePolicy) {
            evidence = [AgentEvidence(
                source: source,
                provenance: "tool:\(descriptor.name)",
                confidence: 1,
                claim: result.summary
            )]
        }
        for item in evidence {
            let duplicate = state.evidence.contains {
                $0.source == item.source && $0.provenance == item.provenance && $0.claim == item.claim
            }
            if !duplicate {
                state.evidence.append(item)
                changed = true
            }
        }

        if descriptor.sideEffectPolicy != .none {
            let key = "sideEffect.\(descriptor.sideEffectPolicy.rawValue)"
            if state.facts[key] != "success" {
                state.facts[key] = "success"
            }
            // 每一次真正成功、且未被工作集幂等保护拦截的副作用都是实际进展。
            // 即使完成事实已经是 success，不同参数的合法批量操作也不能被误判为停滞。
            changed = true
        }

        // Record each canonical mutation that actually returned success. This
        // feeds the task's completion contract for compound requests (for
        // example queue append + play-next); it is deliberately independent
        // from authorization and is never written for a failed call.
        if descriptor.permission != .readOnly,
           let operation = descriptor.authorizationOperation {
            let key = AgentCompletionEvaluator.completionOperationFactKey(operation)
            if state.facts[key] != "success" {
                state.facts[key] = "success"
                changed = true
            }
        }

        if let payload = result.payload, case let .trackCards(cards) = payload {
            let before = state.candidateIDs.count
            state.candidateIDs.formUnion(cards.map { $0.globalID.description })
            changed = changed || state.candidateIDs.count != before
        }

        if changed {
            state.recordProgress(action: "\(descriptor.name): \(result.summary)")
        } else {
            state.recordNoProgress()
        }
        state.errorState = nil
        return changed
    }

    private static func evidenceSource(for policy: ToolEvidencePolicy) -> AgentEvidenceSource? {
        switch policy {
        case .none: nil
        case .localCatalog: .localCatalog
        case .playbackState: .playbackState
        case .server: .server
        case .externalAPI: .externalAPI
        }
    }
}

/// Runtime 层的确定性完成判定。LLM 的自然语言只是一份候选答案；任务事实未满足时，
/// Runtime 要求继续或明确失败，不能把“看起来完成”当成真实完成。
///
/// 普通聊天不会进入这里；活动 Recommendation Index 路径由专用 Runtime 完整拥有。
/// index 分支只读取历史 task facts，绝不再向模型下发 batch/commit 控制指令。
public enum AgentCompletionEvaluator {
    /// Stable task-state key for a successfully executed canonical mutation.
    /// The fact records completion progress, not permission; the descriptor's
    /// risk/confirmation policy still owns whether execution may start.
    public static func completionOperationFactKey(
        _ operation: ToolAuthorizationOperation
    ) -> String {
        "completion.operation.\(operation.rawValue)"
    }

    private static func requiredOperationsSatisfied(
        state: AgentTaskState,
        requiredOperations: Set<ToolAuthorizationOperation>
    ) -> Bool {
        requiredOperations.allSatisfy {
            state.facts[completionOperationFactKey($0)] == "success"
        }
    }

    /// 判断任务事实是否已经足够完成，不依赖模型是否又输出了一句客套话。
    /// 播放、搜索、队列、歌单等真实工具成功后，空 content 也不能覆盖成功事实。
    public static func factsSatisfied(
        state: AgentTaskState,
        policy: AgentTaskPolicy,
        requiredCompletionOperations: Set<ToolAuthorizationOperation> = []
    ) -> Bool {
        switch policy.completion {
        case .modelAnswer, .appreciationWithEvidence:
            return false
        case .successfulToolResult:
            return state.successfulToolNames.contains(where: policy.completionToolNames.contains)
        case .finalTrackSelection:
            // 必须有最终选择事实；有目标数量时数量必须达标。
            guard let count = Int(state.facts["task.finalSelection.count"] ?? ""), count > 0 else {
                return false
            }
            if let targetText = state.facts["task.targetCount"], let target = Int(targetText) {
                return count >= target
            }
            return true
        case .queueMutation:
            if !requiredCompletionOperations.isEmpty {
                return state.facts["sideEffect.queue"] == "success"
                    && requiredOperationsSatisfied(
                        state: state,
                        requiredOperations: requiredCompletionOperations
                    )
            }
            return state.facts["sideEffect.queue"] == "success"
        case .playlistMutation:
            let deletesPlaylist = !Set(state.successfulToolNames)
                .intersection(["playlist_delete", "deletePlaylist"]).isEmpty
            if !requiredCompletionOperations.isEmpty {
                let operationFactsSatisfied = requiredOperationsSatisfied(
                    state: state,
                    requiredOperations: requiredCompletionOperations
                )
                if requiredCompletionOperations.contains(.playlistDelete) || deletesPlaylist {
                    return operationFactsSatisfied
                        && state.facts["playlist.deleted.verified"] == "true"
                }
                return operationFactsSatisfied
                    && state.facts["sideEffect.playlist"] == "success"
            }
            return deletesPlaylist
                ? state.facts["playlist.deleted.verified"] == "true"
                : state.facts["sideEffect.playlist"] == "success"
        case .playbackMutation:
            if !requiredCompletionOperations.isEmpty {
                return (state.facts["sideEffect.playback"] == "success"
                    || state.facts["sideEffect.queue"] == "success")
                    && requiredOperationsSatisfied(
                        state: state,
                        requiredOperations: requiredCompletionOperations
                    )
            }
            return state.facts["sideEffect.playback"] == "success"
                || state.facts["sideEffect.queue"] == "success"
        case .indexPendingCountIsZero:
            return state.facts["recommendation.index.pending"] == "0"
        }
    }

    @discardableResult
    public static func markFactsSatisfied(
        state: inout AgentTaskState,
        policy: AgentTaskPolicy,
        requiredCompletionOperations: Set<ToolAuthorizationOperation> = []
    ) -> Bool {
        guard factsSatisfied(
            state: state,
            policy: policy,
            requiredCompletionOperations: requiredCompletionOperations
        ) else { return false }
        state.completed = true
        state.completionState = .satisfied
        state.status = .completed
        state.updatedAt = .now
        return true
    }

    public static func evaluateModelAnswer(
        _ answer: String,
        state: inout AgentTaskState,
        policy: AgentTaskPolicy,
        repairAttempts: Int,
        requiredCompletionOperations: Set<ToolAuthorizationOperation> = []
    ) -> AgentModelAnswerDecision {
        // 工具事实优先于模型最终文本。部分中转在 tool result 后会返回空 content，
        // 这不应把已经真实完成的播放/搜索/队列操作重新判成失败。
        if markFactsSatisfied(
            state: &state,
            policy: policy,
            requiredCompletionOperations: requiredCompletionOperations
        ) {
            return .accept
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return repairAttempts == 0
                ? .continueTask("模型返回了空内容。请根据当前任务状态调用获准工具，或给出明确且完整的最终回答。")
                : .fail("模型连续返回空内容，任务未完成。")
        }

        let satisfied: Bool
        let continuation: String
        switch policy.completion {
        case .modelAnswer:
            satisfied = true
            continuation = ""
        case .successfulToolResult:
            // Tool Success ≠ Evidence：只要真实成功执行过工具就算完成条件达成。
            // Evidence 只用于外部事实/大众评价/诊断 provenance，不承担“工具是否执行过”的语义。
            satisfied = state.successfulToolNames.contains(where: policy.completionToolNames.contains)
            continuation = "当前任务需要至少一次与当前意图匹配的真实成功工具结果。请调用相关工具后再依据真实结果回答。"
        case .finalTrackSelection:
            let count = Int(state.facts["task.finalSelection.count"] ?? "")
            if let target = Int(state.facts["task.targetCount"] ?? "") {
                satisfied = (count ?? 0) >= target
                continuation = "最终歌曲选择尚未达到目标数量（需要 \(target) 首，当前 \(count ?? 0) 首）。请基于真实候选调用 result_present_tracks 提交最终选择。"
            } else {
                satisfied = (count ?? 0) > 0
                continuation = "尚未提交最终歌曲选择。请基于真实候选调用 result_present_tracks(trackIDs=[最终歌曲]) 提交。"
            }
        case .queueMutation:
            satisfied = factsSatisfied(
                state: state,
                policy: policy,
                requiredCompletionOperations: requiredCompletionOperations
            )
            continuation = requiredCompletionOperations.isEmpty
                ? "队列修改尚未得到成功工具结果。请执行获准的队列工具；不要仅用文字声称已经完成。"
                : "队列任务仍有未完成的操作。请执行尚未成功的队列工具；不要重复已经成功的步骤，也不要仅用文字声称已经完成。"
        case .playlistMutation:
            let deletesPlaylist = !Set(state.successfulToolNames)
                .intersection(["playlist_delete", "deletePlaylist"]).isEmpty
            if deletesPlaylist {
                satisfied = factsSatisfied(
                    state: state,
                    policy: policy,
                    requiredCompletionOperations: requiredCompletionOperations
                )
                continuation = "删除歌单尚未同时通过服务器与本地目录核验。请依据真实删除结果回答，不要仅用文字声称完成。"
            } else {
                satisfied = factsSatisfied(
                    state: state,
                    policy: policy,
                    requiredCompletionOperations: requiredCompletionOperations
                )
                continuation = requiredCompletionOperations.isEmpty
                    ? "歌单修改尚未得到成功工具结果。请执行获准的歌单工具；不要仅用文字声称已经完成。"
                    : "歌单任务仍有未完成的操作。请执行尚未成功的歌单工具；不要重复已经成功的步骤，也不要仅用文字声称已经完成。"
            }
        case .playbackMutation:
            satisfied = factsSatisfied(
                state: state,
                policy: policy,
                requiredCompletionOperations: requiredCompletionOperations
            )
            continuation = requiredCompletionOperations.isEmpty
                ? "播放操作尚未得到成功工具结果。请执行获准的播放工具；不要仅用文字声称已经完成。"
                : "播放任务仍有未完成的操作。请执行尚未成功的播放工具；不要重复已经成功的步骤，也不要仅用文字声称已经完成。"
        case .indexPendingCountIsZero:
            // v3 完整完成只由固定 taxonomy 分类的 authoritative pending 决定。
            let pendingFixed = state.facts["recommendation.index.pending"]
            satisfied = pendingFixed == "0"
            continuation = pendingFixed == nil
                ? "推荐索引尚未获得状态事实。"
                : "推荐索引仍有待处理歌曲；专用 Runtime 会继续处理并核验。"
        case .appreciationWithEvidence:
            let metadataReady = state.facts["appreciation.metadata"] == "available"
            let lyricsResolved = state.facts["appreciation.lyrics"] != nil
            let communityResolved = state.facts["appreciation.community"] != nil
            let requiredSections = ["【已核验事实】", "【模型分析】", "【我的私人数据】", "【大众评价】"]
            let hasRequiredSections = requiredSections.allSatisfy(answer.contains)
            let hasCommunityEvidence = state.facts["appreciation.community"] == "available"
            let communityBoundarySatisfied = hasCommunityEvidence
                || answer.contains("暂无可核验的大众评价数据。")
            let unsupportedCommunityClaim = !hasCommunityEvidence && [
                "大众普遍认为", "广受好评", "听众一致认为",
            ].contains(where: answer.contains)
            satisfied = metadataReady
                && lyricsResolved
                && communityResolved
                && hasRequiredSections
                && communityBoundarySatisfied
                && !unsupportedCommunityClaim
            continuation = "歌曲鉴赏必须先调用 music_appreciate，并以【已核验事实】【模型分析】【我的私人数据】【大众评价】分层回答。没有 Community Evidence 时，大众评价段必须写“暂无可核验的大众评价数据。”"
        }

        if satisfied {
            state.completed = true
            state.completionState = .satisfied
            state.status = .completed
            state.updatedAt = .now
            return .accept
        }
        if repairAttempts == 0 { return .continueTask(continuation) }
        state.completionState = .insufficientEvidence
        state.status = .insufficient
        state.errorState = continuation
        return .fail("任务没有满足确定性完成条件：\(continuation)")
    }
}

/// Runtime 是确定性任务的生命周期与策略拥有者；通用聊天直接进入
/// ConversationEngine/ToolLoop，旧 AgentRunner 只保留 source-compatible forwarding。
public actor AgentRuntime {
    private var runningTaskIDs: Set<UUID> = []
    private let conversationEngine: ConversationEngine

    public init(conversationEngine: ConversationEngine = ConversationEngine()) {
        self.conversationEngine = conversationEngine
    }

    public func isRunning(_ id: UUID) -> Bool { runningTaskIDs.contains(id) }

    /// 解析并校验工具存在性。已注册工具一律放行（permissive direct execution）；
    /// 只有注册表里不存在的工具才抛错。
    public func authorize(tool name: String, policy: AgentTaskPolicy) throws -> ToolDescriptor {
        guard let descriptor = AgentToolRegistry.descriptor(for: name) else {
            throw AgentRuntimeError.toolOutsidePolicy(name)
        }
        return descriptor
    }

    public func run(
        taskID: UUID,
        userText: String,
        explicitIntent: AgentTaskIntent? = nil,
        policy explicitPolicy: AgentTaskPolicy? = nil,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: ToolLoop.Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        webService: (any AgentWebService)? = nil,
        initialTaskState: AgentTaskState? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        executionLineage: ExecutionLineage? = nil,
        runID: UUID = UUID(),
        executionLease: ToolExecutionLease? = nil,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (ToolLoop.AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in },
        observeRecommendationIndex: @escaping @Sendable (RecommendationIndexExecutionEvent) async -> Void = { _ in }
    ) async {
        let historyText = AgentHistoryPolicy.relevantHistoryText(for: userText, in: history)
        // AppShell 已经为任务记录解析过策略时必须复用同一份值，避免持久化预算/意图
        // 与真正运行的策略因历史上下文不同而分叉。独立调用者仍可省略并在此解析。
        let policy = explicitPolicy ?? AgentTaskPolicyResolver.resolve(
            text: userText,
            historyText: historyText,
            explicitIntent: explicitIntent
        )
        let intent = policy.intent
        let taskState = initialTaskState ?? AgentTaskState(id: taskID, intent: intent, goal: userText)
        runningTaskIDs.insert(taskID)
        defer { runningTaskIDs.remove(taskID) }
        await state(taskState)
        await conversationEngine.run(
            userText: userText,
            provider: provider,
            model: model,
            bridge: bridge,
            catalog: catalog,
            context: context,
            history: history,
            systemService: systemService,
            externalMusicService: externalMusicService,
            webService: webService,
            intent: intent,
            policy: policy,
            initialTaskState: taskState,
            authorizationContext: authorizationContext,
            executionLineage: executionLineage,
            runID: runID,
            executionLease: executionLease,
            confirm: confirm,
            emit: emit,
            log: log,
            progress: progress,
            state: state,
            observeRecommendationIndex: observeRecommendationIndex
        )
    }
}
