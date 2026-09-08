// SPDX-License-Identifier: GPL-3.0-only
import AIKit
import Domain
import Foundation
import LocalCatalog

/// Agent 工具权限分级。
/// 已注册工具不会因为权限分级而被拒绝；是否需要 UI 批准只由
/// `ToolDescriptor.confirmationPolicy` 决定，不由权限等级推导。
public enum ToolPermission: String, Codable, Sendable, Hashable {
    /// 只读：查询本地目录、当前播放状态等。
    case readOnly
    /// 可逆：收藏、评分、加入队列等，可撤销/可恢复。
    case reversible
    /// 破坏性：删除/清理类操作的审计分类；是否需要批准由工具元数据精确声明。
    case destructive
}

/// 工具分组，对应需求中的 Catalog/Playback/Playlist/Annotation/Server。
public enum ToolGroup: String, Codable, Sendable, Hashable {
    case catalog
    case playback
    case playlist
    case annotation
    case server
    case download
    case memory
}

/// Values accepted by the deprecated text-argument compatibility initializer.
/// The runtime canonical representation remains `AIJSONValue`.
public protocol ToolArgumentValue: Sendable {
    var aiJSONValue: AIJSONValue { get }
}

extension AIJSONValue: ToolArgumentValue {
    public var aiJSONValue: AIJSONValue { self }
}

extension String: ToolArgumentValue {
    public var aiJSONValue: AIJSONValue { .string(self) }
}

/// Agent 工具调用。arguments 是 Runtime 的 canonical 结构化 JSON 对象；
/// ACTION 文本兼容层只在进入此类型时把字符串包装成 `.string`。
public struct ToolCall: Codable, Sendable {
    public let name: String
    public let arguments: [String: AIJSONValue]

    public init(name: String, arguments: [String: AIJSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    /// 兼容 ACTION / 旧持久化调用点。Canonical property 仍然是 JSON value。
    @available(*, deprecated, message: "Use structured AIJSONValue arguments")
    public init<T: ToolArgumentValue>(name: String, arguments: [String: T]) {
        self.name = name
        self.arguments = arguments.mapValues(\.aiJSONValue)
    }

    public init(name: String, rawArguments: [String: String]) {
        self.name = name
        self.arguments = rawArguments.mapValues(AIJSONValue.string)
    }

    public func string(_ key: String) throws -> String {
        guard let value = arguments[key] else { throw ToolArgumentError.missing(key) }
        switch value {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        default: throw ToolArgumentError.invalid(key, expected: "string")
        }
    }

    public func optionalString(_ key: String) -> String? {
        try? string(key)
    }

    /// Returns legacy text unchanged for string values, or canonical JSON for
    /// arrays/objects. This is only for service adapters that still decode a
    /// domain payload from text; the ToolCall itself remains structured.
    public func jsonText(_ key: String) -> String? {
        guard let value = arguments[key] else { return nil }
        if case let .string(value) = value { return value }
        return value.jsonString
    }

    public func int(_ key: String) throws -> Int {
        guard let value = arguments[key] else { throw ToolArgumentError.missing(key) }
        switch value {
        case let .number(value) where value.isFinite && value.rounded() == value:
            return Int(value)
        case let .string(value) where Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))!
        default: throw ToolArgumentError.invalid(key, expected: "integer")
        }
    }

    public func double(_ key: String) throws -> Double {
        guard let value = arguments[key] else { throw ToolArgumentError.missing(key) }
        switch value {
        case let .number(value): return value
        case let .string(value) where Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))!
        default: throw ToolArgumentError.invalid(key, expected: "number")
        }
    }

    public func bool(_ key: String) throws -> Bool {
        guard let value = arguments[key] else { throw ToolArgumentError.missing(key) }
        switch value {
        case let .bool(value): return value
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: throw ToolArgumentError.invalid(key, expected: "boolean")
            }
        default: throw ToolArgumentError.invalid(key, expected: "boolean")
        }
    }

    public func strings(_ key: String) throws -> [String] {
        guard let value = arguments[key] else { throw ToolArgumentError.missing(key) }
        switch value {
        case let .array(values):
            return try values.map { value in
                guard case let .string(string) = value else {
                    throw ToolArgumentError.invalid(key, expected: "array of strings")
                }
                return string
            }
        case let .string(value):
            // ACTION compatibility only; native structured calls arrive as an array.
            return value.split { $0 == "," || $0 == "，" }.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        default: throw ToolArgumentError.invalid(key, expected: "array of strings")
        }
    }

    public func object(_ key: String) throws -> [String: AIJSONValue] {
        guard let value = arguments[key], case let .object(object) = value else {
            throw ToolArgumentError.invalid(key, expected: "object")
        }
        return object
    }

    /// Stable string projection for legacy diagnostics and task persistence.
    public var stringArguments: [String: String] {
        arguments.mapValues(Self.stringValue)
    }

    private static func stringValue(_ value: AIJSONValue) -> String {
        switch value {
        case let .string(value): return value
        default: return value.jsonString
        }
    }
}

public enum ToolArgumentError: Error, LocalizedError, Sendable, Equatable {
    case missing(String)
    case invalid(String, expected: String)

    public var errorDescription: String? {
        switch self {
        case let .missing(key): return "缺少参数：\(key)"
        case let .invalid(key, expected): return "参数 \(key) 应为 \(expected)"
        }
    }
}

/// 在任何提示词、日志、任务记录或诊断 UI 边界统一移除凭据与完整地址。
public enum AgentSensitiveDataRedactor {
    private static let sensitiveFragments = [
        "password", "passwd", "token", "apikey", "api_key", "authorization",
        "secret", "credential", "cookie", "baseurl", "base_url", "url",
    ]

    public static func arguments(_ values: [String: String]) -> [String: String] {
        values.mapValues { $0 }.map { key, value in
            let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
            let isSensitive = sensitiveFragments.contains { normalized.contains($0) }
            return (key, isSensitive ? "<redacted>" : value)
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    public static func arguments(_ values: [String: AIJSONValue]) -> [String: String] {
        arguments(values.mapValues { value in
            if case let .string(string) = value { return string }
            return value.jsonString
        })
    }
}

public struct ToolFailureEnvelope: Codable, Sendable, Equatable, Hashable {
    public enum Phase: String, Codable, Sendable, Equatable {
        case discovery
        case inputValidation
        case entityResolution
        case authorization
        case resourceLease
        case execution
        case network
        case outputValidation
        case timeout
    }

    public let toolName: String
    public let phase: Phase
    public let code: String
    public let retryable: Bool
    public let safeDetails: [String: AIJSONValue]

    public init(
        toolName: String,
        phase: Phase,
        code: String,
        retryable: Bool,
        safeDetails: [String: AIJSONValue] = [:]
    ) {
        self.toolName = toolName
        self.phase = phase
        self.code = code
        self.retryable = retryable
        self.safeDetails = safeDetails
    }
}

/// 工具执行结果。
public struct ToolResult: Sendable {
    public let call: ToolCall
    public let permission: ToolPermission
    public let success: Bool
    public let summary: String
    public let payload: AgentMessage?
    /// 可直接归并到任务状态的结构化事实。键由工具域拥有，Runtime 不解析自然语言摘要。
    public let facts: [String: String]
    /// 工具产生的可追溯证据。模型推断不能伪装成这里的事实。
    public let evidence: [AgentEvidence]
    /// 展示角色（候选 / 最终 / 歧义 / 无）。由 Tool 执行或 Descriptor 声明，模型不能决定。
    public let presentationRole: ToolPresentationRole
    /// 工具已产生部分写入或服务端状态无法确认。即使 `success == false`，Runner 也必须
    /// 阻止相同参数自动重试，避免创建重复歌单、重复添加歌曲等副作用。
    public let hasIndeterminateSideEffect: Bool
    /// 外部 Web 内容只能作为数据回灌 Provider，不能变成系统指令或用户授权。
    public let trustLevel: AIContentTrustLevel
    /// Structured failure facts are kept separate from the localized summary
    /// so the model/runtime can decide whether repair or retry is appropriate
    /// without parsing user-facing prose.
    public let failure: ToolFailureEnvelope?

    public init(
        call: ToolCall,
        permission: ToolPermission,
        success: Bool,
        summary: String,
        payload: AgentMessage? = nil,
        facts: [String: String] = [:],
        evidence: [AgentEvidence] = [],
        presentationRole: ToolPresentationRole = .none,
        hasIndeterminateSideEffect: Bool = false,
        trustLevel: AIContentTrustLevel = .trustedTool,
        failure: ToolFailureEnvelope? = nil
    ) {
        self.call = call
        self.permission = permission
        self.success = success
        self.summary = summary
        self.payload = payload
        self.facts = facts
        self.evidence = evidence
        self.presentationRole = presentationRole
        self.hasIndeterminateSideEffect = hasIndeterminateSideEffect
        self.trustLevel = trustLevel
        self.failure = failure
    }
}

/// Agent 修改型工具的真实落地结果。`indeterminate` 用于取消/超时后服务端是否已写入
/// 无法确认的情况，绝不能被映射为工具成功。
public struct AgentMutationResult: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case confirmed
        case failed
        case indeterminate
    }

    public let state: State
    public let summary: String

    public init(state: State, summary: String) {
        self.state = state
        self.summary = summary
    }

    public static func confirmed(_ summary: String) -> Self { .init(state: .confirmed, summary: summary) }
    public static func failed(_ summary: String) -> Self { .init(state: .failed, summary: summary) }
    public static func indeterminate(_ summary: String) -> Self { .init(state: .indeterminate, summary: summary) }
    public var succeeded: Bool { state == .confirmed }
}

/// Agent 与播放器/服务器/偏好之间的桥接协议。
/// 所有修改型操作经此协议落到真实播放器与服务器；AppModel 负责实现。
/// 协议仅引用 Domain 与 LocalCatalog，保持 AgentKit 不依赖 Application。
/// 歌曲鉴赏等工具使用的歌词真实状态。
/// 隐私 gating 在工具执行层结合 `allowsLyrics` 决定是否报告 `availableButPrivate`。
public enum AgentLyricsState: String, Sendable, Equatable {
    /// 已有歌词且允许发送正文。
    case available
    /// 已有歌词但隐私设置不允许发送歌词正文。
    case availableButPrivate
    /// 已确认无歌词（服务器/缓存确认，不是“还没查”）。
    case unavailable
    /// 尚未确认（仍在加载或未请求）。
    case unknown
}

public protocol AgentBridge: Sendable {
    /// 全部方法都是 async：桥接实现通常运行在 @MainActor（播放器状态所在），
    /// 用 async 让跨隔离域调用在 Swift 6 严格并发下保持安全。
    var activeServerID: ServerID? { get async }
    func currentTrack() async -> Track?
    func currentQueue() async -> [Track]
    /// 某首歌的歌词真实状态（有/无/未确认）；默认 unknown，测试桥接可覆盖。
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState

    // Playback（返回是否真正开始播放：目标在本地目录且已交给播放引擎）
    func playTrack(globalID: GlobalID) async -> Bool
    /// 服务器曲目在线流播回退：本地目录尚未同步到这首歌时，按服务器 ID 拉取并直接流播。
    /// 成功返回 true。默认实现返回 false（未接入服务器流播的桥接层视为不可用）。
    func playServerTrack(globalID: GlobalID) async -> Bool
    func playAlbum(globalID: GlobalID) async -> Bool
    func playPlaylist(globalID: GlobalID) async -> Bool
    func playRandom(limit: Int) async -> AgentMutationResult
    func pause() async -> AgentMutationResult
    func resume() async -> AgentMutationResult
    func seek(seconds: TimeInterval) async -> AgentMutationResult
    func next() async -> AgentMutationResult
    func previous() async -> AgentMutationResult
    func setShuffle(_ enabled: Bool) async -> AgentMutationResult
    func setRepeatMode(_ mode: RepeatMode) async -> AgentMutationResult
    func setPlaybackRate(_ rate: Float) async -> AgentMutationResult
    /// 设置睡眠定时。mode 取值：off / afterMinutes / afterCurrentTrack / afterCurrentAlbum / afterCurrentQueue。
    func setSleepTimer(mode: String, minutes: TimeInterval) async -> AgentMutationResult
    func cancelSleepTimer() async -> AgentMutationResult
    /// 返回 (模式, 剩余秒数)。
    func getSleepTimer() async -> (mode: String, remaining: TimeInterval)
    func addToQueue(globalID: GlobalID) async -> AgentMutationResult
    func playNext(globalID: GlobalID) async -> AgentMutationResult
    /// 原子地把多首歌曲按输入顺序插入当前歌曲之后。
    /// 生产桥接必须在一次队列 mutation 中完成，不能由调用方逐首拼接。
    func playNext(globalIDs: [GlobalID]) async -> AgentMutationResult
    func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult
    func removeFromQueue(at index: Int) async -> AgentMutationResult
    func reorderQueue(from: Int, to: Int) async -> AgentMutationResult
    func clearQueue() async -> AgentMutationResult
    /// 只随机尚未播放的剩余队列。
    func shuffleRemaining() async -> AgentMutationResult
    /// 把当前队列保存为服务器歌单。
    func saveQueueAsPlaylist(name: String) async -> AgentMutationResult

    // Playlist
    func createPlaylist(name: String) async -> GlobalID?
    func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult
    func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult
    func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult
    func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult
    func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult
    func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult

    // Annotation
    func likeTrack(globalID: GlobalID) async -> AgentMutationResult
    func unlikeTrack(globalID: GlobalID) async -> AgentMutationResult
    func favoriteAlbum(globalID: GlobalID) async -> AgentMutationResult
    func unfavoriteAlbum(globalID: GlobalID) async -> AgentMutationResult
    func favoriteArtist(globalID: GlobalID) async -> AgentMutationResult
    func unfavoriteArtist(globalID: GlobalID) async -> AgentMutationResult
    func setRating(globalID: GlobalID, rating: Int) async -> AgentMutationResult
    func clearRating(globalID: GlobalID) async -> AgentMutationResult

    // Server
    func listServers() async -> [ServerAccount]
    func getActiveServer() async -> ServerAccount?
    func testServerConnection(serverID: ServerID) async -> Bool
    func addServer(displayName: String, baseURL: String, username: String, token: String) async -> AgentMutationResult
    func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> AgentMutationResult
    func switchServer(serverID: ServerID) async -> AgentMutationResult
    func refreshLibrary() async -> AgentMutationResult
    func getSyncStatus() async -> [CatalogSyncStatus]
    func removeServer(serverID: ServerID) async -> AgentMutationResult
    /// 在服务器上在线搜索歌曲（HTTP，search3）；本地无结果时使用。未连接或失败返回空数组。
    func serverSearch(query: String, limit: Int) async -> [Track]
}

public extension AgentBridge {
    func serverSearch(query: String, limit: Int) async -> [Track] { [] }
    func playServerTrack(globalID: GlobalID) async -> Bool { false }
    func playNext(globalIDs: [GlobalID]) async -> AgentMutationResult {
        .failed("播放器桥接未实现批量下一首")
    }
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { .unknown }
    func pause() async -> AgentMutationResult { .failed("播放器桥接未实现暂停") }
    func resume() async -> AgentMutationResult { .failed("播放器桥接未实现继续播放") }
    func seek(seconds: TimeInterval) async -> AgentMutationResult { .failed("播放器桥接未实现定位") }
    func next() async -> AgentMutationResult { .failed("播放器桥接未实现下一首") }
    func previous() async -> AgentMutationResult { .failed("播放器桥接未实现上一首") }
    func setShuffle(_ enabled: Bool) async -> AgentMutationResult { .failed("播放器桥接未实现随机设置") }
    func setRepeatMode(_ mode: RepeatMode) async -> AgentMutationResult { .failed("播放器桥接未实现循环设置") }
    func setPlaybackRate(_ rate: Float) async -> AgentMutationResult { .failed("播放器桥接未实现倍速设置") }
    func setSleepTimer(mode: String, minutes: TimeInterval) async -> AgentMutationResult { .failed("播放器桥接未实现睡眠定时") }
    func cancelSleepTimer() async -> AgentMutationResult { .failed("播放器桥接未实现取消睡眠定时") }
    func saveQueueAsPlaylist(name: String) async -> AgentMutationResult { .failed("播放器桥接未实现保存队列") }
    func likeTrack(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现收藏") }
    func unlikeTrack(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现取消收藏") }
    func favoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现收藏专辑") }
    func unfavoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现取消收藏专辑") }
    func favoriteArtist(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现收藏艺术家") }
    func unfavoriteArtist(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现取消收藏艺术家") }
    func setRating(globalID: GlobalID, rating: Int) async -> AgentMutationResult { .failed("播放器桥接未实现评分") }
    func clearRating(globalID: GlobalID) async -> AgentMutationResult { .failed("播放器桥接未实现清除评分") }
    func refreshLibrary() async -> AgentMutationResult { .failed("播放器桥接未实现音乐库同步") }
    func removeServer(serverID: ServerID) async -> AgentMutationResult { .failed("播放器桥接未实现删除服务器") }
}

/// 需要用户确认的待定操作。
public struct PendingConfirmation: Codable, Sendable, Identifiable {
    public let id: UUID
    /// Bind the approval to the originating run/session. Optional values keep
    /// old persisted confirmations decodable during the migration.
    public let runID: UUID?
    public let sessionID: UUID?
    public let toolCallID: String?
    public let toolName: String
    public let permission: ToolPermission
    public let operation: ToolAuthorizationOperation?
    public let reason: String?
    public let title: String
    public let detail: String
    public let call: ToolCall

    public init(
        id: UUID = UUID(),
        runID: UUID? = nil,
        sessionID: UUID? = nil,
        toolCallID: String? = nil,
        toolName: String,
        permission: ToolPermission,
        operation: ToolAuthorizationOperation? = nil,
        reason: String? = nil,
        title: String,
        detail: String,
        call: ToolCall
    ) {
        self.id = id
        self.runID = runID
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.permission = permission
        self.operation = operation
        self.reason = reason
        self.title = title
        self.detail = detail
        self.call = call
    }
}

/// 一条可撤销的修改型操作记录。
public struct AgentActionRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let toolName: String
    public let permission: ToolPermission
    public let summary: String
    public var undone: Bool

    public init(id: UUID = UUID(), timestamp: Date = .now, toolName: String, permission: ToolPermission, summary: String, undone: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.toolName = toolName
        self.permission = permission
        self.summary = summary
        self.undone = undone
    }
}
