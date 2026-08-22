import Domain
import Foundation
import LocalCatalog

/// Agent 工具权限分级（deprecated / diagnostics-only）。
/// permissive runtime 不再依据权限拒绝已注册工具，也不再触发确认；
/// 保留枚举仅为旧任务记录 / 日志 / UI 分类兼容。
public enum ToolPermission: String, Codable, Sendable, Hashable {
    /// 只读：查询本地目录、当前播放状态等。
    case readOnly
    /// 可逆：收藏、评分、加入队列等，可撤销/可恢复。
    case reversible
    /// 破坏性：删除歌单、删除服务器、清空队列等（仅元数据分类，不再触发确认）。
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

/// Agent 工具调用。arguments 为已解析的参数字典（值经 Agent 内部编码，不含任何凭据）。
public struct ToolCall: Codable, Sendable {
    public let name: String
    public let arguments: [String: String]

    public init(name: String, arguments: [String: String] = [:]) {
        self.name = name
        self.arguments = arguments
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

    public init(
        call: ToolCall,
        permission: ToolPermission,
        success: Bool,
        summary: String,
        payload: AgentMessage? = nil,
        facts: [String: String] = [:],
        evidence: [AgentEvidence] = [],
        presentationRole: ToolPresentationRole = .none,
        hasIndeterminateSideEffect: Bool = false
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
    func pause() async
    func resume() async
    func seek(seconds: TimeInterval) async
    func next() async
    func previous() async
    func setShuffle(_ enabled: Bool) async
    func setRepeatMode(_ mode: RepeatMode) async
    func setPlaybackRate(_ rate: Float) async
    /// 设置睡眠定时。mode 取值：off / afterMinutes / afterCurrentTrack / afterCurrentAlbum / afterCurrentQueue。
    func setSleepTimer(mode: String, minutes: TimeInterval) async
    func cancelSleepTimer() async
    /// 返回 (模式, 剩余秒数)。
    func getSleepTimer() async -> (mode: String, remaining: TimeInterval)
    func addToQueue(globalID: GlobalID) async -> AgentMutationResult
    func playNext(globalID: GlobalID) async -> AgentMutationResult
    func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult
    func removeFromQueue(at index: Int) async -> AgentMutationResult
    func reorderQueue(from: Int, to: Int) async -> AgentMutationResult
    func clearQueue() async -> AgentMutationResult
    /// 只随机尚未播放的剩余队列。
    func shuffleRemaining() async -> AgentMutationResult
    /// 把当前队列保存为服务器歌单；成功返回 true。
    func saveQueueAsPlaylist(name: String) async -> Bool

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
    func likeTrack(globalID: GlobalID) async
    func unlikeTrack(globalID: GlobalID) async
    func favoriteAlbum(globalID: GlobalID) async
    func unfavoriteAlbum(globalID: GlobalID) async
    func favoriteArtist(globalID: GlobalID) async
    func unfavoriteArtist(globalID: GlobalID) async
    func setRating(globalID: GlobalID, rating: Int) async
    func clearRating(globalID: GlobalID) async

    // Server
    func listServers() async -> [ServerAccount]
    func getActiveServer() async -> ServerAccount?
    func testServerConnection(serverID: ServerID) async -> Bool
    func addServer(displayName: String, baseURL: String, username: String, token: String) async -> AgentMutationResult
    func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> AgentMutationResult
    func switchServer(serverID: ServerID) async -> AgentMutationResult
    func refreshLibrary() async
    func getSyncStatus() async -> [CatalogSyncStatus]
    func removeServer(serverID: ServerID) async
    /// 在服务器上在线搜索歌曲（HTTP，search3）；本地无结果时使用。未连接或失败返回空数组。
    func serverSearch(query: String, limit: Int) async -> [Track]
}

public extension AgentBridge {
    func serverSearch(query: String, limit: Int) async -> [Track] { [] }
    func playServerTrack(globalID: GlobalID) async -> Bool { false }
    func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { .unknown }
}

/// 需要用户确认的待定操作。
public struct PendingConfirmation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let permission: ToolPermission
    public let title: String
    public let detail: String
    public let call: ToolCall

    public init(id: UUID = UUID(), toolName: String, permission: ToolPermission, title: String, detail: String, call: ToolCall) {
        self.id = id
        self.toolName = toolName
        self.permission = permission
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
