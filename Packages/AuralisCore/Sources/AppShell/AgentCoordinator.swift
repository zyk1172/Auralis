import AIKit
import AgentKit
import Domain
import Foundation
import LocalCatalog
import Observability

/// 首次外发确认的决策。
public enum AIConsentDecision: Sendable {
    /// 仅本次放行，不写持久化标记。
    case allowOnce
    /// 放行并写入 `auralis.ai.consentGiven`，后续不再询问。
    case allowAndRemember
    /// 拒绝：不发起网络请求，只回本地提示。
    case deny
}

/// 首次请求外发前需要用户确认的内容描述（只描述将发送什么，不含任何真实数据）。
public struct AIPrivacyConsentRequest: Sendable, Identifiable {
    public let id: UUID
    public let providerName: String
    public let modelName: String
    /// 将发送的字段清单（中文描述）。
    public let fields: [String]
    /// 发送目的。
    public let purpose: String

    public init(
        id: UUID = UUID(),
        providerName: String,
        modelName: String,
        fields: [String],
        purpose: String
    ) {
        self.id = id
        self.providerName = providerName
        self.modelName = modelName
        self.fields = fields
        self.purpose = purpose
    }
}

/// AI 助手的运行时协调器：会话管理、消息流、确认流程、操作日志与偏好。
///
/// 边界约定：
/// - 把完整会话与工具「结果摘要」发给模型，永不发送完整音乐目录或任何凭据。
/// - 已注册工具默认直接执行；只有明确不可逆的高风险工具由 ToolLoop 请求一次批准，
///   调用记录仍会保留在本地操作日志中。
/// - 隐私：三个隐私开关真实生效（元数据 / 播放历史 / 歌词）；首次外发前需用户确认。
/// - 模型不可用时，仅显式音乐请求可降级到本地规则模式；普通聊天保持 Provider 错误语义，
///   不会被改写为本地音乐搜索。
@MainActor
public final class AgentCoordinator: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var activeSessionID: UUID?
    @Published public private(set) var messages: [AgentChatMessage] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var actionRecords: [AgentActionRecord] = []
    @Published public private(set) var preferences = UserPreferences()
    /// 当前待用户裁决的首次外发确认；非 nil 时 AssistantView 弹确认 UI（B5）。
    @Published public private(set) var pendingConsent: AIPrivacyConsentRequest?
    /// 当前待用户裁决的不可逆高风险 Agent 操作；普通工具不会进入此状态。
    @Published public private(set) var pendingOperationConfirmation: PendingConfirmation?
    /// 当前正在运行（或最近一次运行）的 Agent 任务；供 UI 展示步骤与状态。
    @Published public private(set) var activeTask: AgentTaskRecord?
    /// Exactly one transient activity belongs to the current run.  Streaming,
    /// tools, confirmation and Runtime retries update this value in place;
    /// they do not accumulate as independent presentation states.
    @Published public private(set) var runPresentationState: AssistantRunPresentationState?
    /// A presentation snapshot of the coordinator-owned Recommendation Index
    /// execution registry. Catalog counts describe persisted data only; this
    /// property is the live-run fact exposed to the UI and system tools.
    @Published public private(set) var recommendationIndexExecutionState: RecommendationIndexExecutionState = .idle
    /// 会话列表搜索词。
    @Published public var sessionQuery = "" { didSet { refreshSessionList() } }
    /// 是否在会话列表里显示已归档会话（默认隐藏）。
    @Published public var showArchivedSessions = false { didSet { refreshSessionList() } }

    // MARK: - Dependencies

    private unowned let model: AuralisAppModel
    private let bridge: AuralisAgentBridge
    private let catalog: LocalCatalogStore
    private let sessionStore: SessionStore
    private let actionLog: AgentActionLog
    private let preferencesStore: PreferencesStore
    /// 长期存活的任务仓库：任务状态落盘，App 重启后标记 interrupted。
    private let taskStore: AgentTaskStore
    /// 真正拥有任务生命周期与策略边界的独立运行时。
    private let runtime: AgentRuntime
    /// 普通聊天不创建业务 AgentTask，直接进入 ConversationEngine。
    private let conversationEngine: ConversationEngine
    /// 系统服务工具适配：App / 设备 / 服务器 / 缓存 / 统计 / 诊断 / 记忆与技能。
    private let systemService: AuralisSystemToolService
    /// 按需开放音乐数据；与歌曲信息 UI、无歌词补全共用同一个 MusicEnrichmentService 实例。
    private let externalMusicService: MusicEnrichmentService
    /// Provider 没有托管联网工具时使用的可替换 WebCapability 实现。
    private let webService: any AgentWebService
    /// All runs owned by this coordinator share resource-level mutation
    /// ownership; unrelated ToolLoop instances do not share this registry.
    private let mutationResourceLeaseRegistry: MutationResourceLeaseRegistry
    /// Authoritative live state for Recommendation Index runs. Unlike catalog
    /// counts, this registry can prove whether a run is actually active.
    private let recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry
    /// 跨会话记忆与技能存储：会话开始时注入提示词；memory_*/skill_* 工具读写同一实例。
    public let memoryStore: AgentMemoryStore

    /// The active session's task is kept for compatibility with synchronous
    /// callers; all live runs are owned by these per-run maps so switching
    /// sessions does not cancel unrelated work.
    private enum RunMode {
        case interactive
        case headless
    }

    private var runTask: Task<Void, Never>?
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var runSessions: [UUID: UUID] = [:]
    private var runModes: [UUID: RunMode] = [:]
    private var runLeases: [UUID: ToolExecutionLease] = [:]
    private var runIDsBySession: [UUID: UUID] = [:]
    private var consentContinuation: CheckedContinuation<AIConsentDecision, Never>?
    /// Destructive confirmations belong to the run that requested them.  A
    /// single coordinator can keep a background run waiting while another
    /// session is active; a global continuation would either block the wrong
    /// session or let its UI answer the wrong run.
    private var operationConfirmationContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var operationConfirmations: [UUID: PendingConfirmation] = [:]
    /// 当前运行身份：任何迟到 callback 只要 runID 不匹配就丢弃，绝不污染新运行/新会话。
    var currentRunID: UUID?
    /// generation 单调递增，防止相同会话恢复后误接受上一代异步结果。
    private var executionGeneration: UInt64 = 0
    /// Internal so lifecycle regression tests can assert ownership directly;
    /// production callers cannot access it outside AppShell.
    var currentExecutionLease: ToolExecutionLease?
    /// Conversation history is persisted by SessionStore; executable authority
    /// is deliberately kept in this separate per-session lineage map.
    /// A substantive user request replaces the entry instead of inheriting a
    /// stale task completion or mutation authorization.
    var executionLineages: [UUID: ExecutionLineage] = [:]
    /// 每个 Run 独立的流式状态（key = runID）。`.streaming` 增量累加进该 run 的气泡，
    /// 直到收到非流式消息（最终文本 / 工具进度 / 卡片等）把它原地定型为止。
    /// 用 runID 隔离后，Session A 的流式气泡永远不会与 Session B 共享。
    private struct AgentStreamingState {
        var messageID: UUID?
        var rawText = ""
    }
    private var streamingStates: [UUID: AgentStreamingState] = [:]
    private var runPresentationStates: [UUID: AssistantRunPresentationState] = [:]

    /// 兼容旧调用方的默认上下文参考值；真实请求预算始终来自 Provider capabilities，
    /// 不在 Agent 层额外限制模型的 token 或上下文。
    public static let tokenBudget = ContextManager.maxContextTokens
    /// 首次外发确认的持久化标记键（UserDefaults，默认 false）。
    public static let consentGivenDefaultsKey = "auralis.ai.consentGiven"
    /// 设置接口的展示名（与 AIConnectionSettings.makeProvider 的配置名保持一致）。
    private static let providerDisplayName = String(localized: "OpenAI 兼容接口", bundle: .module)

    public init(
        model: AuralisAppModel,
        coordinator: CatalogCoordinator,
        directory: URL? = nil,
        musicEnrichment: MusicEnrichmentService? = nil,
        webService: (any AgentWebService)? = nil
    ) {
        self.model = model
        self.catalog = coordinator.store
        self.bridge = AuralisAgentBridge(model: model, coordinator: coordinator)
        let dir = directory ?? Self.defaultDirectory()
        let memoryStore = AgentMemoryStore(directory: dir)
        self.memoryStore = memoryStore
        self.systemService = AuralisSystemToolService(model: model, memoryStore: memoryStore)
        // UI / Agent / 歌词补全共用同一个 MusicEnrichmentService；未传入时自建（测试用）。
        self.externalMusicService = musicEnrichment ?? MusicEnrichmentService(catalog: coordinator.store)
        self.webService = webService ?? WebCapabilityRouter(
            instantAnswerFallback: DuckDuckGoInstantAnswerService()
        )
        self.mutationResourceLeaseRegistry = MutationResourceLeaseRegistry()
        self.recommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry()
        self.sessionStore = SessionStore(fileURL: dir.appendingPathComponent("agent-sessions.json"))
        self.actionLog = AgentActionLog(fileURL: dir.appendingPathComponent("agent-actions.json"))
        self.preferencesStore = PreferencesStore(fileURL: dir.appendingPathComponent("agent-preferences.json"))
        self.taskStore = AgentTaskStore(fileURL: dir.appendingPathComponent("agent-tasks.json"))
        self.runtime = AgentRuntime()
        self.conversationEngine = ConversationEngine()
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Auralis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 旧「不感兴趣」反馈 → disliked_tracks 权威状态的一次性迁移（幂等）。
    public func migrateLegacyDislikedIfNeeded() async {
        _ = try? await DislikedMigration.migrateNotInterestedFeedback(
            catalog: catalog,
            preferences: preferencesStore
        )
    }

    /// 歌曲信息页与歌曲鉴赏共用同一按需服务和 SQLite 缓存。
    /// 该入口不会被启动或整库同步调用，只有用户打开歌曲信息时才会联网。
    public func externalMusicData(for track: Track) async -> AgentExternalMusicResult {
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        return await externalMusicService.enrich(track: track, globalID: globalID)
    }

    /// 清除按需查询产生的公开音乐元数据、大众指标、评论与候选缓存；保留 Stable Identity。
    /// 偏好开关不会被重置，也不会触碰歌曲、播放历史、收藏或推荐索引。
    public func clearExternalMusicDataCache() async throws {
        try await externalMusicService.clearCache()
    }

    /// 高级“重置音乐身份匹配”：连 Stable Identity 一起清空，下次按需重新识别 MBID。
    public func resetExternalMusicIdentity() async throws {
        try await externalMusicService.resetIdentity()
    }

    // MARK: - Bootstrap

    /// 恢复上次的会话列表、操作日志与偏好。
    public func bootstrap() async {
        // App 重启：把上次仍在运行的任务标记为 interrupted，不自动重放已完成的写操作。
        taskStore.markInterruptedOnLaunch()
        await migrateLegacyDislikedIfNeeded()
        await reloadAll()
        if activeSessionID == nil {
            if let latest = sessions.first {
                await activate(latest.id)
            } else {
                await newSession()
            }
        }
    }

    private func reloadAll() async {
        let all = await sessionStore.all
        applySessions(all)
        actionRecords = await actionLog.all
        preferences = await preferencesStore.current
    }

    // MARK: - Session management

    @discardableResult
    public func newSession() async -> UUID {
        let session = await sessionStore.create(serverID: model.catalog.activeServerID)
        await reloadSessions()
        await activate(session.id)
        return session.id
    }

    public func activate(_ id: UUID) async {
        activeSessionID = id
        messages = await sessionStore.session(id)?.messages ?? []
        let runID = runIDsBySession[id]
        currentRunID = runID
        runTask = runID.flatMap { runTasks[$0] }
        currentExecutionLease = runID.flatMap { runLeases[$0] }
        runPresentationState = runID.flatMap { runPresentationStates[$0] }
        refreshActiveRunState()
    }

    public func rename(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await sessionStore.rename(id, to: trimmed)
        await reloadSessions()
    }

    public func togglePin(_ id: UUID) async {
        let pinned = await sessionStore.session(id)?.isPinned ?? false
        await sessionStore.setPinned(id, !pinned)
        await reloadSessions()
    }

    public func clearMessages(_ id: UUID) async {
        await sessionStore.clearMessages(id)
        executionLineages[id] = nil
        await reloadSessions()
        if id == activeSessionID { messages = [] }
    }

    public func delete(_ id: UUID) async {
        if id == activeSessionID {
            let cancelledTask = revokeCurrentRun(markTaskCancelled: true)
            if let cancelledTask { await cancelledTask.value }
        } else if let runID = runIDsBySession[id], let cancelledTask = revokeRun(runID) {
            // Deleting a background session must revoke its mutation authority
            // too; otherwise its late bridge call could outlive the session.
            await cancelledTask.value
        }
        await sessionStore.delete(id)
        executionLineages[id] = nil
        await reloadSessions()
        if id == activeSessionID {
            if let next = sessions.first {
                await activate(next.id)
            } else {
                await newSession()
            }
        }
    }

    /// 归档会话：从主列表隐藏（isArchived），不删除任何消息。
    public func archive(_ id: UUID) async {
        await sessionStore.setArchived(id, true)
        await reloadSessions()
    }

    /// 取消归档：会话重新出现在主列表。
    public func unarchive(_ id: UUID) async {
        await sessionStore.setArchived(id, false)
        await reloadSessions()
    }

    /// 批量归档。
    public func archive(_ ids: [UUID]) async {
        for id in ids { await sessionStore.setArchived(id, true) }
        await reloadSessions()
    }

    /// 批量删除（会话管理页使用）。若包含当前会话，自动切换到下一个或新建。
    public func delete(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        if let active = activeSessionID, ids.contains(active) {
            let cancelledTask = revokeCurrentRun(markTaskCancelled: true)
            if let cancelledTask { await cancelledTask.value }
        }
        for id in ids where id != activeSessionID {
            if let runID = runIDsBySession[id], let cancelledTask = revokeRun(runID) {
                await cancelledTask.value
            }
        }
        for id in ids { await sessionStore.delete(id) }
        for id in ids { executionLineages[id] = nil }
        await reloadSessions()
        if let active = activeSessionID, ids.contains(active) {
            if let next = sessions.first {
                await activate(next.id)
            } else {
                await newSession()
            }
        }
    }

    /// 为会话生成一句话摘要（取首条用户消息，无需调用模型）。
    public func summarizeActiveSession() async {
        guard let id = activeSessionID else { return }
        let firstUserText = messages.first { $0.role == .user }
            .flatMap { message -> String? in
                for item in message.messages { if case let .text(text) = item { return text } }
                return nil
            }
        guard let summary = firstUserText, !summary.isEmpty else { return }
        let clipped = summary.count > 40 ? String(summary.prefix(40)) + "…" : summary
        await sessionStore.setSummary(id, clipped)
        // 会话仍是默认标题时顺手改成摘要，列表更好认。
        if let session = await sessionStore.session(id), session.title == "新会话" {
            await sessionStore.rename(id, to: clipped)
        }
        await reloadSessions()
    }

    private func reloadSessions() async {
        applySessions(await sessionStore.all)
    }

    private func refreshSessionList() {
        Task { await reloadSessions() }
    }

    private func applySessions(_ all: [AgentSession]) {
        var result = all
        let query = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { session in
                if session.title.lowercased().contains(query) { return true }
                if session.summary?.lowercased().contains(query) == true { return true }
                return session.messages.contains { message in
                    message.messages.contains { item in
                        if case let .text(text) = item { return text.lowercased().contains(query) }
                        return false
                    }
                }
            }
        }
        if !showArchivedSessions {
            result = result.filter { !$0.isArchived }
        }
        // 置顶优先，其次按更新时间倒序。
        sessions = result.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: - Running

    /// 发送一条用户消息并执行 Agent 循环。
    /// - Parameter provider: 可选的注入式 AIProvider，便于测试；默认读取用户配置。
    ///
    /// 没有活动会话时自动新建一个会话再运行，避免「发送按钮点了没反应」。
    public func send(
        _ text: String,
        provider: (any AIProvider)? = nil,
        intent explicitIntent: AgentTaskIntent? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionID = activeSessionID,
           pendingConfirmation(for: sessionID) != nil {
            // A pending destructive approval is resolved only by its
            // dedicated UI buttons. Natural-language text such as “确认” or
            // “继续” must never become Runtime approval or resume the paused
            // mutation with a different call.
            return
        }
        guard !trimmed.isEmpty else { return }
        if let sessionID = activeSessionID {
            startRun(text: trimmed, provider: provider, explicitIntent: explicitIntent, sessionID: sessionID)
        } else {
            // 会话列表尚未 bootstrap 完成（或没有选中任何会话）：先建会话再运行。
            Task { [weak self] in
                guard let self else { return }
                let sessionID = await self.newSession()
                self.startRun(text: trimmed, provider: provider, explicitIntent: explicitIntent, sessionID: sessionID)
            }
        }
    }

    /// 无界面执行：发送一条消息并等待本轮运行结束，返回助手新增的文本回复。
    /// 供 Siri / 快捷指令等系统入口调用。无界面身份只绑定到本次 run，
    /// 不会改变 Coordinator 上其他会话的确认能力。
    @discardableResult
    public func sendAndWait(
        _ text: String,
        provider: (any AIProvider)? = nil,
        intent explicitIntent: AgentTaskIntent? = nil
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 确保存在活动会话。
        if activeSessionID == nil {
            _ = await newSession()
        }
        guard let sessionID = activeSessionID,
              pendingConfirmation(for: sessionID) == nil,
              runIDsBySession[sessionID] == nil
        else { return "" }

        // Capture both the session and its starting message count. The UI may
        // switch to another session while this run is awaiting the provider;
        // the return value must still come from the captured SessionStore row.
        let startCount = await sessionStore.session(sessionID)?.messages.count ?? 0
        startRun(
            text: trimmed,
            provider: provider,
            explicitIntent: explicitIntent,
            sessionID: sessionID,
            mode: .headless
        )
        guard let startedRunID = runIDsBySession[sessionID],
              let task = runTasks[startedRunID]
        else { return "" }
        _ = await task.value

        let sessionMessages = await sessionStore.session(sessionID)?.messages ?? []
        return Self.collectAssistantText(sessionMessages.dropFirst(startCount))
    }

    /// 无界面入口（Siri / 快捷指令）返回给系统调用方的最终文本长度上限。
    /// 无界面入口保留足够大的字符上限；Agent 单次输出由 Provider / 用户配置的
    /// ModelCapabilities 决定，不在 Coordinator 再加一层 token 限制。
    private static let maxHeadlessReplyCharacters = 1_000_000

    /// 从本轮新增的助手消息中提取最终文本回复（取最后一个非空文本块，控制长度）。
    private static func collectAssistantText(_ messages: ArraySlice<AgentChatMessage>) -> String {
        var blocks: [String] = []
        for message in messages where message.role == .assistant {
            for item in message.messages {
                switch item {
                case let .text(text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { blocks.append(t) }
                case let .error(text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { blocks.append(t) }
                case let .streaming(text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { blocks.append(t) }
                default:
                    break
                }
            }
        }
        guard let last = blocks.last else { return "" }
        return String(last.prefix(Self.maxHeadlessReplyCharacters))
    }

    private func startRun(
        text: String,
        provider: (any AIProvider)?,
        explicitIntent: AgentTaskIntent?,
        sessionID: UUID,
        mode: RunMode = .interactive
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, runIDsBySession[sessionID] == nil else { return }

        isRunning = true
        let aiSettings = AIConnectionSettings()
        let resolvedProvider = provider ?? aiSettings.makeProvider()
        // 首次外发确认只对「从用户设置解析出的真实 provider」生效；注入的 provider
        // 仅用于测试（MockAIProvider / ScriptedAIProvider），不经过真实外发，无需确认。
        let needsFirstSendConsent = provider == nil && resolvedProvider != nil
        // 使用设置页配置的真实模型名，确保与「测试连接」走完全相同的模型。
        // 注意命名：本类的 `model` 是 AuralisAppModel，这里必须另起名字避免遮蔽。
        let modelName = aiSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)

        // 隐私 gating（B2）：按用户权限过滤上下文；权限关闭的字段不进入 Context。
        let permissions = AIPrivacyPermissions.current()
        let cat = model.catalog
        let currentTrackTitle = permissions.allowsMetadata
            ? (cat.isConnected ? model.currentTrack.title : nil)
            : nil
        let currentTrackArtist = permissions.allowsMetadata
            ? (cat.isConnected ? model.currentTrack.artistName : nil)
            : nil
        let recentlyPlayedTitles = permissions.allowsPlaybackHistory
            ? model.recentlyPlayedTracks.prefix(5).map(\.title)
            : []
        // 服务器名称 / 目录计数属于运行基础信息（隐私报告未禁此项），最简一致地保留。
        let context = ToolLoop.Context(
            serverID: cat.activeServerID,
            serverName: cat.isConnected ? cat.account.displayName : nil,
            serverType: model.serverConnectionState.serverType,
            currentTrackTitle: currentTrackTitle,
            currentTrackArtist: currentTrackArtist,
            queueCount: model.queue.count,
            totalTracks: cat.tracks.count,
            totalArtists: cat.artists.count,
            totalAlbums: cat.albums.count,
            totalPlaylists: cat.playlists.count,
            favoriteCount: model.favoriteTracks.count,
            recentlyPlayedTitles: recentlyPlayedTitles,
            isShuffled: model.isShuffled,
            repeatMode: model.repeatMode.title,
            allowsMetadata: permissions.allowsMetadata,
            allowsLyrics: permissions.allowsLyrics,
            allowsHistory: permissions.allowsPlaybackHistory,
            memories: memoryStore.memories,
            skills: memoryStore.skills,
            mutationResourceLeaseRegistry: mutationResourceLeaseRegistry,
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry
        )
        let bridge = self.bridge
        let catalog = self.catalog
        let systemService = self.systemService
        // 创建并持久化任务记录（不依赖任何 View 生命周期）。
        // 历史只从 SessionStore 读取（Session A 只能看到 A 的历史），不依赖全局 messages。
        // Allocate ownership before the task starts.  A cancellation can arrive
        // before a newly-created Task gets its first executor turn; keeping the
        // identity outside the task makes that race harmless.
        let runID = UUID()
        executionGeneration &+= 1
        let executionLease = ToolExecutionLease(
            runID: runID,
            sessionID: sessionID,
            generation: executionGeneration
        )
        runSessions[runID] = sessionID
        runModes[runID] = mode
        runLeases[runID] = executionLease
        runIDsBySession[sessionID] = runID
        currentExecutionLease = executionLease
        currentRunID = runID
        beginRunPresentation(runID: runID, sessionID: sessionID)
        let task = Task { [weak self] in
            guard let self else { return }
            // 用户在任务真正开始前点了停止：直接结束，不回任何消息。
            if Task.isCancelled {
                self.finishOwnedRun(runID)
                return
            }
            // 历史只从 SessionStore 读取：Session A 只能看到 A 的聊天记录。
            let history = await self.sessionStore.session(sessionID)?.messages ?? []
            let originUserMessageID = UUID()
            // “继续”可能连续出现多次（尤其是上一轮被 429/工具错误打断后）。
            // 只取最近一条完整任务指令，避免第二次“继续”把索引/批处理意图
            // 降级成 conversation，进而让索引工具从动态 schema 中消失。
            let historyText = AgentHistoryPolicy.relevantHistoryText(for: trimmed, in: history)
            var executionLineage = ExecutionLineageResolver.resolve(
                currentUserText: trimmed,
                originUserMessageID: originUserMessageID,
                previous: self.executionLineages[sessionID]
            )
            let resolvedPolicy = AgentTaskPolicyResolver.resolve(
                text: trimmed,
                historyText: historyText,
                explicitIntent: explicitIntent
            )

            // Generic chat is a first-class provider conversation. It must not
            // be represented as a business task merely to reach the model
            // loop; otherwise CompletionEvaluator and task persistence become
            // an accidental capability boundary for ordinary questions.
            let requestSemantics = AgentRequestSemantics.analyze(trimmed, historyText: historyText)
            let canUseGenericConversation = !requestSemantics.requiresSideEffect
                && requestSemantics.domain != .recommendation
                && resolvedPolicy.completion != .appreciationWithEvidence
            if canUseGenericConversation {
                self.executionLineages[sessionID] = executionLineage
                if needsFirstSendConsent {
                    let consent = Self.consentRequest(
                        providerName: Self.providerDisplayName,
                        modelName: modelName,
                        permissions: permissions
                    )
                    switch await self.ensureConsentIfNeeded(consent, runID: runID) {
                    case .deny:
                        await self.receive(
                            AgentChatMessage(role: .user, messages: [.text(trimmed)]),
                            sessionID: sessionID,
                            runID: runID
                        )
                        await self.receive(
                            AgentChatMessage(role: .assistant, messages: [.text(Self.consentDeniedText(consent))]),
                            sessionID: sessionID,
                            runID: runID
                        )
                        self.finishOwnedRun(runID)
                        return
                    case .allowOnce, .allowAndRemember:
                        break
                    }
                }

                await self.conversationEngine.run(
                    userText: trimmed,
                    provider: resolvedProvider,
                    model: modelName,
                    bridge: bridge,
                    catalog: catalog,
                    context: context,
                    history: history,
                    systemService: systemService,
                    externalMusicService: externalMusicService,
                    webService: webService,
                    intent: resolvedPolicy.intent,
                    policy: resolvedPolicy,
                    authorizationContext: executionLineage.authorization,
                    executionLineage: executionLineage,
                    runID: runID,
                    executionLease: executionLease,
                    confirm: { [weak self] pending in
                        guard let self else { return false }
                        return await self.requestOperationConfirmation(
                            pending,
                            runID: runID,
                            sessionID: sessionID
                        )
                    },
                    emit: { [weak self] message in
                        await self?.receive(message, sessionID: sessionID, runID: runID)
                    },
                    log: { [weak self] record in
                        await self?.record(record)
                    },
                    progress: { _ in },
                    state: { _ in },
                    observeRecommendationIndex: { [weak self] event in
                        await self?.observeRecommendationIndex(event, sessionID: sessionID, runID: runID)
                    }
                )
                if self.activeSessionID == sessionID {
                    await self.summarizeActiveSession()
                }
                self.finishOwnedRun(runID)
                return
            }

            let resumeRecord = self.taskStore.recommendationIndexResumeCandidate(
                conversationID: sessionID,
                requestText: trimmed
            )
            let taskRecord = resumeRecord ?? self.taskStore.start(
                conversationID: sessionID,
                intent: resolvedPolicy.intent,
                goal: trimmed,
                budget: resolvedPolicy.budget
            )
            let taskID = taskRecord.id
            if let resumeRecord, let savedGoal = resumeRecord.goal {
                executionLineage = .resumedTask(
                    goal: savedGoal,
                    taskID: taskID,
                    originUserMessageID: originUserMessageID,
                    activeSkillID: "recommendation-index"
                )
            } else {
                executionLineage = executionLineage.attaching(
                    taskID: taskID,
                    activeSkillID: requestSemantics.isRecommendationIndexBuild
                        ? "recommendation-index"
                        : nil
                )
            }
            self.executionLineages[sessionID] = executionLineage
            let taskPolicy: AgentTaskPolicy
            if let resumeRecord,
               let savedIntent = resumeRecord.intent,
               let savedGoal = resumeRecord.goal {
                let reconstructed = AgentTaskPolicyResolver.resolve(
                    text: savedGoal,
                    explicitIntent: savedIntent
                )
                // 恢复时复用任务记录中的预算，不能因为当前输入只是“继续”而
                // 退回普通会话预算。
                taskPolicy = AgentTaskPolicy(
                    intent: reconstructed.intent,
                    scopes: reconstructed.scopes,
                    allowedToolGroups: reconstructed.allowedToolGroups,
                    allowedPermissions: reconstructed.allowedPermissions,
                    maxRisk: reconstructed.maxRisk,
                    completion: reconstructed.completion,
                    budget: resumeRecord.budget ?? reconstructed.budget
                )
            } else {
                taskPolicy = resolvedPolicy
            }
            let initialTaskState: AgentTaskState? = resumeRecord.flatMap { record in
                guard let intent = record.intent, let goal = record.goal else { return nil }
                var state = AgentTaskState(
                    id: record.id,
                    intent: intent,
                    goal: goal,
                    startedAt: record.createdAt
                )
                state.completedActions = record.completedActions ?? []
                if let checkpointJSON = record.checkpointJSON {
                    state.facts["recommendation.index.checkpoint"] = checkpointJSON
                }
                state.pendingActions = [
                    "这是一个已恢复的 Stateful Skill。请先从真实状态继续，不要重复已完成动作。"
                ]
                state.status = .running
                state.updatedAt = .now
                return state
            }
            if resumeRecord != nil {
                self.taskStore.update(taskID, status: .running)
            }
            if self.activeSessionID == sessionID {
                self.activeTask = self.taskStore.record(taskID)
            }
            // 首次外发确认门槛（B5）：只有真实网络请求需要确认。
            if needsFirstSendConsent {
                let consent = Self.consentRequest(
                    providerName: Self.providerDisplayName,
                    modelName: modelName,
                    permissions: permissions
                )
                switch await self.ensureConsentIfNeeded(consent, runID: runID) {
                case .deny:
                    // 不发起网络请求，只回本地提示（用户消息回显 + 隐私说明）。
                    await self.receive(
                        AgentChatMessage(role: .user, messages: [.text(trimmed)]),
                        sessionID: sessionID,
                        runID: runID
                    )
                    await self.receive(
                        AgentChatMessage(role: .assistant, messages: [.text(Self.consentDeniedText(consent))]),
                        sessionID: sessionID,
                        runID: runID
                    )
                    taskStore.update(taskID, status: .cancelled, error: String(localized: "用户未授权首次外发请求。", bundle: .module))
                    self.finishOwnedRun(runID)
                    return
                case .allowOnce, .allowAndRemember:
                    break
                }
            }

            await self.runtime.run(
                taskID: taskID,
                userText: trimmed,
                explicitIntent: explicitIntent,
                policy: taskPolicy,
                provider: resolvedProvider,
                model: modelName,
                bridge: bridge,
                catalog: catalog,
                context: context,
                history: history,
                systemService: systemService,
                externalMusicService: externalMusicService,
                webService: webService,
                initialTaskState: initialTaskState,
                authorizationContext: executionLineage.authorization,
                executionLineage: executionLineage,
                runID: runID,
                executionLease: executionLease,
                confirm: { [weak self] pending in
                    guard let self else { return false }
                    return await self.requestOperationConfirmation(
                        pending,
                        runID: runID,
                        sessionID: sessionID
                    )
                },
                emit: { [weak self] message in
                    await self?.receive(message, sessionID: sessionID, runID: runID)
                },
                log: { [weak self] record in
                    await self?.record(record)
                },
                progress: { [weak self] p in
                    await self?.updateTaskProgress(p, taskID: taskID, sessionID: sessionID, runID: runID)
                },
                state: { [weak self] taskState in
                    await self?.updateTaskState(taskState, taskID: taskID, sessionID: sessionID, runID: runID)
                },
                observeRecommendationIndex: { [weak self] event in
                    await self?.observeRecommendationIndex(event, sessionID: sessionID, runID: runID)
                }
            )
            // 收尾顺序：先结算任务 → 再清理运行身份 → 最后才释放 isRunning。
            // currentRunID 只在仍属于本次运行时才清空，避免旧 Run 清掉新 Run 的身份。
            let wasCancelled = Task.isCancelled
            let sessionMessages = await self.sessionStore.session(sessionID)?.messages ?? []
            let failure = Self.failureSummary(in: sessionMessages.dropFirst(history.count))
            await self.finishTask(taskID, sessionID: sessionID, runID: runID, wasCancelled: wasCancelled, failure: failure)
            if self.currentRunID == runID, self.activeSessionID == sessionID {
                await self.summarizeActiveSession()
            }
            self.finishOwnedRun(runID)
        }
        runTasks[runID] = task
        runTask = task
    }

    /// 更新任务进度（工具步骤 / 当前阶段 / token 用量）。
    private func updateTaskProgress(
        _ progress: ToolLoop.AgentProgress,
        taskID: UUID,
        sessionID: UUID,
        runID: UUID
    ) async {
        taskStore.update(
            taskID,
            step: progress.currentStep,
            toolSteps: progress.toolSteps,
            inputTokens: progress.inputTokens ?? 0,
            outputTokens: progress.outputTokens ?? 0
        )
        // 只有属于当前活动会话的任务才更新 UI 进度，避免 Session A 的步骤显示在 B 界面。
        if ownsRun(runID, sessionID: sessionID), activeSessionID == sessionID {
            activeTask = taskStore.record(taskID)
        }
        guard ownsRun(runID, sessionID: sessionID),
              var presentation = runPresentationStates[runID],
              presentation.sessionID == sessionID else { return }
        if case let .workflow(skillID, phase, detail) = progress.activity {
            presentation.phase = .workflow(skillID: skillID, phase: phase, detail: detail)
            runPresentationStates[runID] = presentation
            if activeSessionID == sessionID, currentRunID == runID {
                runPresentationState = presentation
            }
        }
    }

    /// Project structured Recommendation Index observations into the one
    /// transient presentation state owned by this run. The execution registry
    /// remains authoritative; catalog counts are never used to infer that a
    /// task is running.
    private func observeRecommendationIndex(
        _ event: RecommendationIndexExecutionEvent,
        sessionID: UUID,
        runID: UUID
    ) async {
        AuralisLog.artificialIntelligence.info(
            "RECOMMENDATION_INDEX \(event.compactSummary, privacy: .public)"
        )

        guard ownsRun(runID, sessionID: sessionID),
              event.runID == runID,
              event.sessionID == sessionID else { return }

        let eventServerID = event.serverID.map { ServerID(rawValue: $0) }
        let snapshot = await recommendationIndexExecutionRegistry.snapshot(serverID: eventServerID)
        recommendationIndexExecutionState = snapshot

        guard var presentation = runPresentationStates[runID],
              presentation.sessionID == sessionID else { return }

        let detail = Self.recommendationIndexPresentationDetail(for: event)
        switch event.kind {
        case .retrying:
            presentation.phase = .retrying(message: detail)
        case .failed:
            presentation.phase = .failed(message: detail)
        case .cancelled:
            presentation.phase = .failed(message: detail)
        default:
            presentation.phase = .workflow(
                skillID: RecommendationIndexSkillRuntime.skillID,
                phase: event.phase.rawValue,
                detail: detail
            )
        }

        runPresentationStates[runID] = presentation
        if activeSessionID == sessionID, currentRunID == runID {
            runPresentationState = presentation
        }
    }

    private static func recommendationIndexPresentationDetail(
        for event: RecommendationIndexExecutionEvent
    ) -> String {
        let total = event.totalTracks ?? 0
        let indexed = event.indexedTracks ?? 0
        let progress = total > 0 ? "\(indexed) / \(total)" : nil
        let batch = event.batchSize > 0 ? "当前批次 \(event.batchSize) 首" : nil

        switch event.kind {
        case .routeSelected, .started:
            return "正在启动推荐索引…"
        case .statusLoaded:
            if let progress { return "推荐索引：已完成 \(progress)，正在读取下一批" }
            return "正在读取推荐索引状态…"
        case .batchPrepared:
            if let batch { return "推荐索引：已准备（\(batch)）" }
            return "正在准备推荐索引批次…"
        case .classificationStarted:
            if let progress, let batch { return "推荐索引：正在分类（\(progress)，\(batch)）" }
            if let batch { return "推荐索引：正在分类（\(batch)）" }
            return "推荐索引：正在分类当前批次…"
        case .classificationCompleted:
            return "推荐索引：分类完成，准备写入…"
        case .classificationFailed:
            return "推荐索引：当前批次分类失败，准备重试…"
        case .commitStarted:
            if let batch { return "推荐索引：正在写入（\(batch)）" }
            return "推荐索引：正在写入分类…"
        case .commitCompleted:
            return "推荐索引：分类已写入，准备核验…"
        case .verifyStarted:
            return "推荐索引：正在核验写入进度…"
        case .verifyCompleted:
            return "推荐索引：写入进度已核验，准备继续…"
        case .noProgress:
            return "推荐索引：连续提交未产生进度，已暂停以避免重复写入。"
        case .retrying:
            return "推荐索引正在重试当前批次…"
        case .completed:
            if let progress { return "推荐索引已完成（\(progress)）" }
            return "推荐索引已完成"
        case .cancelled:
            return "推荐索引已取消"
        case .failed:
            return "推荐索引已暂停：模型请求或服务暂时失败。"
        case .phaseChanged:
            return event.message ?? "推荐索引正在处理…"
        }
    }

    /// Runtime 是任务状态的权威；把结构化状态同步进持久化仓库，App 重启后可审计
    /// 已完成动作与停止原因，而不是只剩一条“正在执行工具”的 UI 文本。
    private func updateTaskState(
        _ state: AgentTaskState,
        taskID: UUID,
        sessionID: UUID,
        runID: UUID
    ) async {
        taskStore.update(
            taskID,
            status: Self.persistedStatus(for: state.status),
            step: state.pendingActions.last ?? state.completedActions.last,
            toolSteps: state.progress.toolCalls,
            inputTokens: state.progress.inputTokens,
            outputTokens: state.progress.outputTokens,
            error: state.errorState,
            completedActions: state.completedActions,
            noProgressRounds: state.progress.noProgressRounds,
            checkpointJSON: state.facts["recommendation.index.checkpoint"]
        )
        if ownsRun(runID, sessionID: sessionID), activeSessionID == sessionID {
            activeTask = taskStore.record(taskID)
        }
    }

    private static func persistedStatus(for status: AgentTaskLifecycleStatus) -> AgentTaskStatus {
        switch status {
        case .queued: .queued
        case .running: .running
        case .waitingForModel: .waitingForModel
        case .waitingForTool: .waitingForTool
        case .completed: .completed
        case .insufficient, .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        }
    }

    /// 任务结束后按真实结果落盘。此前 Runner 已发出 `.error` 时仍被一律标为
    /// completed，导致用户看到失败、任务记录却显示完成，无法诊断或恢复。
    private func finishTask(
        _ taskID: UUID,
        sessionID: UUID,
        runID: UUID,
        wasCancelled: Bool,
        failure: String?
    ) async {
        let status: AgentTaskStatus
        if wasCancelled {
            status = .cancelled
        } else if failure != nil {
            status = .failed
        } else {
            status = .completed
        }
        taskStore.update(taskID, status: status, error: failure)
        // 只有属于当前活动会话的任务才更新 UI 任务状态，避免 A 的收尾污染 B 界面。
        if ownsRun(runID, sessionID: sessionID), activeSessionID == sessionID {
            activeTask = taskStore.record(taskID)
        }
    }

    /// Releases only the state owned by `runID`.  An older cancelled task may
    /// finish after a newer request has started; it must never clear that new
    /// task's `runTask`, spinner or streaming state.
    /// Internal for the lifecycle regression test; callers can only release
    /// their own run identity.
    func finishOwnedRun(_ runID: UUID) {
        guard runSessions[runID] != nil || currentRunID == runID else { return }
        let sessionID = runSessions[runID]
        // A run that exits while waiting for approval must fail closed and
        // release only its own continuation.  Never leave a confirmation
        // belonging to a finished run visible in another session.
        resolveOperationConfirmation(false, for: runID)
        runLeases[runID]?.revoke()
        if currentExecutionLease?.runID == runID {
            currentExecutionLease = nil
        }
        runLeases[runID] = nil
        runSessions[runID] = nil
        runModes[runID] = nil
        runTasks[runID] = nil
        if let sessionID, runIDsBySession[sessionID] == runID {
            runIDsBySession[sessionID] = nil
        }
        if currentRunID == runID {
            currentRunID = nil
            runTask = nil
        }
        streamingStates[runID] = nil
        runPresentationStates[runID] = nil
        if runPresentationState?.runID == runID {
            runPresentationState = nil
        }
        if case let .running(snapshot) = recommendationIndexExecutionState,
           snapshot.runID == runID {
            recommendationIndexExecutionState = .idle
        }
        refreshActiveRunState()
    }

    /// Establish the one transient phase row for a new owned run.  Kept
    /// internal so lifecycle tests can exercise stale-callback isolation
    /// without needing to manufacture a live Provider request.
    func beginRunPresentation(runID: UUID, sessionID: UUID) {
        guard currentRunID == runID else { return }
        let presentation = AssistantRunPresentationState(runID: runID, sessionID: sessionID, phase: .thinking)
        runPresentationStates[runID] = presentation
        runPresentationState = presentation
    }

    private static func failureSummary(in messages: ArraySlice<AgentChatMessage>) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            for item in message.messages.reversed() {
                if case let .error(text) = item {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    /// 用户主动取消当前运行。
    public func cancel() {
        _ = revokeCurrentRun(markTaskCancelled: true)
    }

    /// Revoke execution authority before requesting cooperative cancellation.
    /// Returning the detached task lets session switches wait for all old
    /// async frames to leave their mutation barriers before presenting the new
    /// session.
    @discardableResult
    private func revokeCurrentRun(markTaskCancelled: Bool) -> Task<Void, Never>? {
        let cancelledRunID = currentRunID
        let cancelledTask = cancelledRunID.flatMap { revokeRun($0) }
        runTask = nil
        currentRunID = nil
        currentExecutionLease = nil
        resolveConsent(.deny)
        resolveOperationConfirmation(false, for: cancelledRunID)
        refreshActiveRunState()
        if markTaskCancelled, let taskID = activeTask?.id {
            taskStore.update(taskID, status: .cancelled, error: String(localized: "用户取消。", bundle: .module))
            activeTask = nil
        }
        return cancelledTask
    }

    /// Revoke one registered run without touching another session's UI. This
    /// is used when a background session is deleted and by the foreground
    /// cancellation wrapper above.
    @discardableResult
    private func revokeRun(_ runID: UUID) -> Task<Void, Never>? {
        guard runSessions[runID] != nil || currentRunID == runID else { return nil }
        let task = runTasks[runID]
        // Revoke the UI approval wait before cancelling the async task.  Task
        // cancellation alone cannot resume a CheckedContinuation.
        resolveOperationConfirmation(false, for: runID)
        runLeases[runID]?.revoke()
        task?.cancel()
        let sessionID = runSessions[runID]
        runTasks[runID] = nil
        runSessions[runID] = nil
        runModes[runID] = nil
        runLeases[runID] = nil
        if let sessionID, runIDsBySession[sessionID] == runID {
            runIDsBySession[sessionID] = nil
        }
        streamingStates[runID] = nil
        runPresentationStates[runID] = nil
        if currentRunID == runID {
            currentRunID = nil
            runTask = nil
            currentExecutionLease = nil
            if runPresentationState?.runID == runID {
                runPresentationState = nil
            }
        }
        refreshActiveRunState()
        return task
    }

    private func ownsRun(_ runID: UUID, sessionID: UUID) -> Bool {
        runSessions[runID] == sessionID || (runSessions[runID] == nil && currentRunID == runID)
    }

    /// `isRunning` is a presentation property for the active session, not a
    /// global count of background work. Session A may continue indexing while
    /// Session B is idle and must not show A's spinner.
    private func refreshActiveRunState() {
        // 只在值真正变化时赋值 @Published，避免无意义的重复 publication
        // （dismiss/approve 的延迟 resolve 与 SwiftUI 事务收尾叠加时，重复
        //  publish 可能加剧 view-update 期间的同步变更告警）。
        let running = activeSessionID.flatMap { runIDsBySession[$0] } != nil
        if running != isRunning {
            isRunning = running
        }
        let activeRunID = activeSessionID.flatMap { runIDsBySession[$0] }
        let confirmation = activeRunID.flatMap { operationConfirmations[$0] }
        // PendingConfirmation 用稳定 id 比较；不改变其业务语义。
        if confirmation?.id != pendingOperationConfirmation?.id {
            pendingOperationConfirmation = confirmation
        }
    }

    /// The published property above is deliberately only a projection for
    /// the active UI session. Runtime guards must resolve through the
    /// session-to-run map so a background session can never block another
    /// session's send or confirmation UI.
    private func pendingConfirmation(for sessionID: UUID) -> PendingConfirmation? {
        guard let runID = runIDsBySession[sessionID] else { return nil }
        return operationConfirmations[runID]
    }

    /// 接收 Runner 发出的消息。
    ///
    /// 流式处理规则（保证「流式半成品 + 成品」不重复出现）：
    /// - `.streaming` 增量 → 累加进当前 in-flight 气泡；没有气泡时先新建一条；
    /// - 非流式消息（最终 `.text` / 工具进度 / 卡片 / 错误等）→ 若存在 in-flight
    ///   气泡，则**原地替换**该气泡（同一位置，不另起一条），并持久化最终消息。
    ///   流式增量本身不写盘，收尾时统一落一次，避免每 token 一次磁盘写。
    /// 接收 Runner 发出的消息。消息先绑定 sessionID + runID：
    /// 1. 只有仍登记在目标 session 的 run callback 才被接受（迟到/过期 callback 一律丢弃）；
    /// 2. 持久化永远写入目标 session 的 SessionStore；
    /// 3. 只有 activeSessionID == sessionID 时才更新当前屏幕的 `messages`。
    ///
    /// 流式处理规则（保证「流式半成品 + 成品」不重复出现）：
    /// - `.streaming` 增量 → 累加进该 run 的 in-flight 气泡（key = runID）；
    /// - 非流式消息（最终 `.text` / 工具进度 / 卡片 / 错误等）→ 原地定型 in-flight 气泡并持久化。
    ///   流式增量本身不写盘，收尾时统一落一次，避免每 token 一次磁盘写。
    func receive(_ message: AgentChatMessage, sessionID: UUID, runID: UUID) async {
        // 过期 callback（旧 run 的迟到 token / 旧 run 的 final answer）→ 丢弃，不污染新运行。
        guard ownsRun(runID, sessionID: sessionID) else { return }
        let isActiveSession = activeSessionID == sessionID

        let sanitizedMessage = AgentUserFacingSanitizer.chatMessage(message)
        updateRunPresentation(for: sanitizedMessage, sessionID: sessionID, runID: runID)

        // 流式增量：累加进该 run 的 in-flight 气泡（只在活动会话上更新 UI）。
        if let delta = Self.streamingDeltaText(from: message) {
            var state = streamingStates[runID] ?? AgentStreamingState(messageID: nil)
            state.rawText += delta
            if isActiveSession {
                if let streamingID = state.messageID,
                   let index = messages.lastIndex(where: { $0.id == streamingID }) {
                    var existing = messages[index]
                    let accumulated = AgentUserFacingSanitizer.text(state.rawText)
                    existing = AgentChatMessage(
                        id: existing.id,
                        role: .assistant,
                        messages: [.streaming(accumulated)],
                        createdAt: existing.createdAt
                    )
                    messages[index] = existing
                } else {
                    state.messageID = message.id
                    messages.append(AgentChatMessage(
                        id: message.id,
                        role: .assistant,
                        messages: [.streaming(AgentUserFacingSanitizer.text(state.rawText))],
                        createdAt: message.createdAt
                    ))
                }
            } else if state.messageID == nil {
                state.messageID = message.id
            }
            streamingStates[runID] = state
            return
        }

        // 非流式消息：把该 run 的 in-flight 气泡原地定型并持久化。
        let state = streamingStates[runID]
        streamingStates[runID] = nil
        if let streamingID = state?.messageID, isActiveSession,
           let index = messages.lastIndex(where: { $0.id == streamingID }) {
            messages[index] = sanitizedMessage
            await sessionStore.append(sanitizedMessage, to: sessionID)
            return
        }
        // Tool activity is transient run state, not a chat transcript.  Keep
        // exactly one trailing activity row and replace it in both the live
        // UI and persistence; a long index run no longer fills the screen
        // with one bubble per status/next/write operation.
        if Self.isToolProgress(message), isActiveSession,
           let index = messages.indices.last,
           messages[index].role == .assistant,
           Self.isToolProgress(messages[index]) {
            messages[index] = sanitizedMessage
            if await sessionStore.replaceTrailingToolProgress(message, in: sessionID) {
                return
            }
        }
        if isActiveSession {
            messages.append(sanitizedMessage)
        }
        await sessionStore.append(sanitizedMessage, to: sessionID)
    }

    /// Message-derived phases are intentionally transient.  The final answer
    /// remains represented by the normal persisted assistant message, while
    /// this state drives the single running indicator.
    private func updateRunPresentation(
        for message: AgentChatMessage,
        sessionID: UUID,
        runID: UUID
    ) {
        guard var presentation = runPresentationStates[runID],
              presentation.sessionID == sessionID else { return }
        if Self.streamingDeltaText(from: message) != nil {
            presentation.phase = .streaming
        } else if let item = message.messages.last {
            switch item {
            case let .toolProgress(step):
                if step.contains("重试") {
                    presentation.phase = .retrying(message: step)
                } else {
                    presentation.phase = .usingTool(name: step)
                }
            case .confirmation:
                presentation.phase = .waitingForConfirmation
            case let .error(text):
                presentation.phase = .failed(message: text)
            default:
                break
            }
        }
        runPresentationStates[runID] = presentation
        if activeSessionID == sessionID, currentRunID == runID {
            runPresentationState = presentation
        }
    }

    /// 若消息是流式增量消息，返回其增量文本；否则返回 nil。
    private static func streamingDeltaText(from message: AgentChatMessage) -> String? {
        guard message.role == .assistant, !message.messages.isEmpty else { return nil }
        var pieces: [String] = []
        for item in message.messages {
            if case let .streaming(text) = item { pieces.append(text) }
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined()
    }

    private static func isToolProgress(_ message: AgentChatMessage) -> Bool {
        !message.messages.isEmpty && message.messages.allSatisfy { item in
            if case .toolProgress = item { return true }
            return false
        }
    }

    /// 汇总一条消息里已有的流式文本（用于在 in-flight 气泡上继续累加）。
    private static func accumulatedStreamingText(_ message: AgentChatMessage) -> String {
        var pieces: [String] = []
        for item in message.messages {
            if case let .streaming(text) = item { pieces.append(text) }
        }
        return pieces.joined()
    }

    private func record(_ record: AgentActionRecord) async {
        await actionLog.add(record)
        actionRecords = await actionLog.all
    }

    // MARK: - First-send consent (B5)

    /// 依据当前权限构建「将发送内容」清单，供首次外发确认展示。
    private static func consentRequest(
        providerName: String,
        modelName: String,
        permissions: AIPrivacyPermissions
    ) -> AIPrivacyConsentRequest {
        var fields: [String] = []
        if permissions.allowsMetadata {
            fields.append(String(localized: "歌曲元数据（当前播放曲目）", bundle: .module))
        }
        if permissions.allowsPlaybackHistory {
            fields.append(String(localized: "最近播放历史（最近 5 首）", bundle: .module))
        }
        if permissions.allowsLyrics {
            fields.append(String(localized: "歌词（查询到时）", bundle: .module))
        }
        fields.append(String(localized: "服务器名称与资料库统计（运行基础信息）", bundle: .module))
        return AIPrivacyConsentRequest(
            providerName: providerName,
            modelName: modelName,
            fields: fields,
            purpose: String(localized: "处理你的音乐请求（搜索、播放、推荐、收藏等）", bundle: .module)
        )
    }

    /// 首次外发确认门槛：`auralis.ai.consentGiven` 已写入则直接放行；
    /// 未写入时挂起，等待 UI 决策（AssistantView 弹确认框）。
    /// 无界面模式（Siri / 快捷指令）没有可见确认框，按默认拒绝处理，不发起网络请求。
    private func ensureConsentIfNeeded(
        _ request: AIPrivacyConsentRequest,
        runID: UUID
    ) async -> AIConsentDecision {
        if UserDefaults.standard.bool(forKey: Self.consentGivenDefaultsKey) {
            return .allowAndRemember
        }
        if runModes[runID] == .headless { return .deny }
        // 上一个确认还没结束时直接拒绝，避免弹窗互相覆盖。
        guard consentContinuation == nil else { return .deny }
        pendingConsent = request
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
        }
    }

    /// 运行时操作确认：不可逆工具以及需要补齐具体操作授权的调用都复用同一
    /// PendingConfirmation 通道。确认属于具体 run/session；模型输出的“确认”、
    /// “继续”等文本不会进入这里，也不能替代 Runtime 的批准。
    func requestOperationConfirmation(
        _ pending: PendingConfirmation,
        runID: UUID,
        sessionID: UUID
    ) async -> Bool {
        guard runModes[runID] == .interactive, !Task.isCancelled else { return false }
        guard runSessions[runID] == sessionID,
              pending.runID == nil || pending.runID == runID,
              pending.sessionID == nil || pending.sessionID == sessionID,
              runLeases[runID]?.isValidSnapshot == true else { return false }
        guard operationConfirmationContinuations[runID] == nil else { return false }
        // Keep the exact ToolCall intact, but never let diagnostics text leak
        // identifiers through the alert title/detail projection.
        operationConfirmations[runID] = AgentUserFacingSanitizer.confirmation(pending)
        refreshActiveRunState()
        return await withCheckedContinuation { continuation in
            operationConfirmationContinuations[runID] = continuation
        }
    }

    public func denyOperationConfirmation() {
        resolveOperationConfirmation(false, for: activeConfirmationRunID)
    }

    public func approveOperationConfirmation() {
        resolveOperationConfirmation(true, for: activeConfirmationRunID)
    }

    private var activeConfirmationRunID: UUID? {
        activeSessionID.flatMap { runIDsBySession[$0] }
    }

    private func resolveOperationConfirmation(_ approved: Bool, for runID: UUID?) {
        guard let runID else { return }
        let continuation = operationConfirmationContinuations.removeValue(forKey: runID)
        operationConfirmations[runID] = nil
        refreshActiveRunState()
        continuation?.resume(returning: approved)
    }

    public func approveConsent(remember: Bool) {
        resolveConsent(remember ? .allowAndRemember : .allowOnce)
    }

    public func denyConsent() {
        resolveConsent(.deny)
    }

    private func resolveConsent(_ decision: AIConsentDecision) {
        guard let continuation = consentContinuation else { return }
        consentContinuation = nil
        pendingConsent = nil
        if case .allowAndRemember = decision {
            UserDefaults.standard.set(true, forKey: Self.consentGivenDefaultsKey)
        }
        continuation.resume(returning: decision)
    }

    /// 未授权首次外发时的本地提示（不发起任何网络请求）。
    private static func consentDeniedText(_ request: AIPrivacyConsentRequest) -> String {
        let fieldsText = request.fields.map { "· \($0)" }.joined(separator: "\n")
        return String(localized: """
        为保护隐私，本次请求未发送到模型。首次外发需要确认：确认后将把以下内容发送到「\(request.providerName)」（模型：\(request.modelName)）：
        \(fieldsText)
        用途：\(request.purpose)
        请在弹窗中选择「允许一次」或「允许并记住」，或到「设置 → OpenAI 兼容接口」查看隐私选项。
        """, bundle: .module)
    }

    // MARK: - Action log

    public func refreshActionRecords() async {
        actionRecords = await actionLog.all
    }

    /// 尽力撤销一条操作记录。仅可逆操作可撤销。
    public func undo(_ record: AgentActionRecord) async {
        guard !record.undone, record.permission == .reversible else { return }
        await actionLog.markUndone(record.id)
        actionRecords = await actionLog.all
    }

    public func clearActionLog() async {
        await actionLog.clear()
        actionRecords = []
    }

    // MARK: - Preferences & feedback

    public func updatePreferences(_ mutation: @escaping @Sendable (inout UserPreferences) -> Void) async {
        await preferencesStore.update(mutation)
        preferences = await preferencesStore.current
    }

    /// 推荐反馈按钮：记录后立即影响后续本地排序与提示词偏好。
    public func sendFeedback(_ kind: RecommendationFeedback, for card: TrackCard) async {
        await preferencesStore.recordFeedback(trackID: card.globalID, kind: kind)
        preferences = await preferencesStore.current
    }

    public func removeFeedback(_ id: UUID) async {
        await preferencesStore.removeFeedback(id)
        preferences = await preferencesStore.current
    }

    // MARK: - Card interaction

    /// 点击歌曲卡片：直接本地播放，不再调用大模型。
    public func play(card: TrackCard) {
        Task { await bridge.playTrack(globalID: card.globalID) }
    }

    public func queue(card: TrackCard) {
        Task { await bridge.addToQueue(globalID: card.globalID) }
    }

    public func toggleFavorite(card: TrackCard) {
        Task {
            if card.isFavorite {
                await bridge.unlikeTrack(globalID: card.globalID)
            } else {
                await bridge.likeTrack(globalID: card.globalID)
            }
        }
    }

    /// 把提案歌单一次性排入队列并播放（本地操作，不经模型）。
    public func playAll(cards: [TrackCard]) {
        guard !cards.isEmpty else { return }
        Task { await bridge.replaceQueue(globalIDs: cards.map(\.globalID)) }
    }
}
