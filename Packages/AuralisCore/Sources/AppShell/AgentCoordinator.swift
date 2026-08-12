import AIKit
import AgentKit
import Domain
import Foundation
import LocalCatalog

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
/// - 只把用户输入与工具「结果摘要」发给模型，永不发送完整音乐目录或任何凭据。
/// - AI 已发起的工具调用直接执行；调用记录仍会保留在本地操作日志中。
/// - 隐私：三个隐私开关真实生效（元数据 / 播放历史 / 歌词）；首次外发前需用户确认。
/// - 模型不可用时自动降级到本地规则模式，搜索/播放/收藏等仍然可用。
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
    /// 无界面模式：来自 Siri / 快捷指令等系统入口时置为 true。
    /// 所有工具调用与有界面模式一致，直接执行。
    public var headless = false
    /// 当前正在运行（或最近一次运行）的 Agent 任务；供 UI 展示步骤与状态。
    @Published public private(set) var activeTask: AgentTaskRecord?
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
    /// 系统服务工具适配：App / 设备 / 服务器 / 缓存 / 统计 / 诊断 / 记忆与技能。
    private let systemService: AuralisSystemToolService
    /// 按需开放音乐数据；与歌曲信息 UI、无歌词补全共用同一个 MusicEnrichmentService 实例。
    private let externalMusicService: MusicEnrichmentService
    /// 跨会话记忆与技能存储：会话开始时注入提示词；memory_*/skill_* 工具读写同一实例。
    public let memoryStore: AgentMemoryStore

    private var runTask: Task<Void, Never>?
    private var consentContinuation: CheckedContinuation<AIConsentDecision, Never>?
    /// 当前运行身份：任何迟到 callback 只要 runID 不匹配就丢弃，绝不污染新运行/新会话。
    var currentRunID: UUID?
    /// 每个 Run 独立的流式状态（key = runID）。`.streaming` 增量累加进该 run 的气泡，
    /// 直到收到非流式消息（最终文本 / 工具进度 / 卡片等）把它原地定型为止。
    /// 用 runID 隔离后，Session A 的流式气泡永远不会与 Session B 共享。
    private struct AgentStreamingState {
        var messageID: UUID?
    }
    private var streamingStates: [UUID: AgentStreamingState] = [:]

    /// 单次请求带给模型的总上下文上限（256K，超出时裁剪历史并预留输出）。
    public static let tokenBudget = ContextManager.maxContextTokens
    /// 首次外发确认的持久化标记键（UserDefaults，默认 false）。
    public static let consentGivenDefaultsKey = "auralis.ai.consentGiven"
    /// 设置接口的展示名（与 AIConnectionSettings.makeProvider 的配置名保持一致）。
    private static let providerDisplayName = "OpenAI 兼容接口"

    public init(
        model: AuralisAppModel,
        coordinator: CatalogCoordinator,
        directory: URL? = nil,
        musicEnrichment: MusicEnrichmentService? = nil
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
        self.sessionStore = SessionStore(fileURL: dir.appendingPathComponent("agent-sessions.json"))
        self.actionLog = AgentActionLog(fileURL: dir.appendingPathComponent("agent-actions.json"))
        self.preferencesStore = PreferencesStore(fileURL: dir.appendingPathComponent("agent-preferences.json"))
        self.taskStore = AgentTaskStore(fileURL: dir.appendingPathComponent("agent-tasks.json"))
        self.runtime = AgentRuntime()
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
        await reloadSessions()
        if id == activeSessionID { messages = [] }
    }

    public func delete(_ id: UUID) async {
        await sessionStore.delete(id)
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
        for id in ids { await sessionStore.delete(id) }
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
        guard !trimmed.isEmpty, !isRunning else { return }
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
    /// 供 Siri / 快捷指令等系统入口调用（此时 headless 临时置为 true）。
    /// 工具调用直接执行；调用结束恢复原值，不影响 App 内运行状态。
    @discardableResult
    public func sendAndWait(
        _ text: String,
        provider: (any AIProvider)? = nil,
        intent explicitIntent: AgentTaskIntent? = nil
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 确保存在活动会话：send() 在有会话时同步创建 runTask，便于直接等待。
        if activeSessionID == nil {
            _ = await newSession()
        }
        let startCount = messages.count
        let previousHeadless = headless
        headless = true
        defer { headless = previousHeadless }
        send(trimmed, provider: provider, intent: explicitIntent)
        if let task = runTask {
            _ = await task.value
        } else {
            // send 走异步建会话路径（理论上不会发生，但保留兜底）：
            // 短轮询等待 runTask 出现并完成，避免直接返回空结果。
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let task = runTask {
                    _ = await task.value
                    break
                }
            }
        }
        return Self.collectAssistantText(messages.dropFirst(startCount))
    }

    /// 无界面入口（Siri / 快捷指令）返回给系统调用方的最终文本长度上限。
    /// Agent 单次输出上限为 16_000 token。无界面入口保留足够大的字符上限，
    /// 不会像旧值 500 字符那样把长回答截断成残句。
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
        sessionID: UUID
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

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
        let context = AgentRunner.Context(
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
            skills: memoryStore.skills
        )
        let bridge = self.bridge
        let catalog = self.catalog
        let systemService = self.systemService
        // 创建并持久化任务记录（不依赖任何 View 生命周期）。
        // 历史只从 SessionStore 读取（Session A 只能看到 A 的历史），不依赖全局 messages。
        runTask = Task { [weak self] in
            guard let self else { return }
            let runID = UUID()
            self.currentRunID = runID
            // 用户在任务真正开始前点了停止：直接结束，不回任何消息。
            if Task.isCancelled {
                if self.currentRunID == runID { self.currentRunID = nil }
                self.runTask = nil
                await MainActor.run { [weak self] in self?.isRunning = false }
                return
            }
            // 历史只从 SessionStore 读取：Session A 只能看到 A 的聊天记录。
            let history = await self.sessionStore.session(sessionID)?.messages ?? []
            let historyText = history.flatMap(\.messages).compactMap { item -> String? in
                switch item {
                case let .text(value), let .streaming(value), let .error(value): value
                default: nil
                }
            }.joined(separator: " ")
            let resolvedPolicy = AgentTaskPolicyResolver.resolve(
                text: trimmed,
                historyText: historyText,
                explicitIntent: explicitIntent
            )
            let taskID = self.taskStore.start(
                conversationID: sessionID,
                intent: resolvedPolicy.intent,
                goal: trimmed,
                budget: resolvedPolicy.budget
            ).id
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
                switch await self.ensureConsentIfNeeded(consent) {
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
                    taskStore.update(taskID, status: .cancelled, error: "用户未授权首次外发请求。")
                    if self.currentRunID == runID { self.currentRunID = nil }
                    self.runTask = nil
                    await MainActor.run { [weak self] in self?.isRunning = false }
                    return
                case .allowOnce, .allowAndRemember:
                    break
                }
            }

            await self.runtime.run(
                taskID: taskID,
                userText: trimmed,
                explicitIntent: explicitIntent,
                policy: resolvedPolicy,
                provider: resolvedProvider,
                model: modelName,
                bridge: bridge,
                catalog: catalog,
                context: context,
                history: history,
                systemService: systemService,
                externalMusicService: externalMusicService,
                confirm: { _ in true },
                emit: { [weak self] message in
                    await self?.receive(message, sessionID: sessionID, runID: runID)
                },
                log: { [weak self] record in
                    await self?.record(record)
                },
                progress: { [weak self] p in
                    await self?.updateTaskProgress(p, taskID: taskID, sessionID: sessionID)
                },
                state: { [weak self] taskState in
                    await self?.updateTaskState(taskState, taskID: taskID, sessionID: sessionID)
                }
            )
            // 收尾顺序：先结算任务 → 再清理运行身份 → 最后才释放 isRunning。
            // currentRunID 只在仍属于本次运行时才清空，避免旧 Run 清掉新 Run 的身份。
            let wasCancelled = Task.isCancelled
            let sessionMessages = await self.sessionStore.session(sessionID)?.messages ?? []
            let failure = Self.failureSummary(in: sessionMessages.dropFirst(history.count))
            await self.finishTask(taskID, sessionID: sessionID, wasCancelled: wasCancelled, failure: failure)
            if self.activeSessionID == sessionID {
                await self.summarizeActiveSession()
            }
            if self.currentRunID == runID { self.currentRunID = nil }
            self.runTask = nil
            await MainActor.run { [weak self] in self?.isRunning = false }
        }
    }

    /// 更新任务进度（工具步骤 / 当前阶段 / token 用量）。
    private func updateTaskProgress(_ progress: AgentRunner.AgentProgress, taskID: UUID, sessionID: UUID) async {
        taskStore.update(
            taskID,
            step: progress.currentStep,
            toolSteps: progress.toolSteps,
            inputTokens: progress.inputTokens ?? 0,
            outputTokens: progress.outputTokens ?? 0
        )
        // 只有属于当前活动会话的任务才更新 UI 进度，避免 Session A 的步骤显示在 B 界面。
        if activeSessionID == sessionID {
            activeTask = taskStore.record(taskID)
        }
    }

    /// Runtime 是任务状态的权威；把结构化状态同步进持久化仓库，App 重启后可审计
    /// 已完成动作与停止原因，而不是只剩一条“正在执行工具”的 UI 文本。
    private func updateTaskState(_ state: AgentTaskState, taskID: UUID, sessionID: UUID) async {
        taskStore.update(
            taskID,
            status: Self.persistedStatus(for: state.status),
            step: state.pendingActions.last ?? state.completedActions.last,
            toolSteps: state.progress.toolCalls,
            inputTokens: state.progress.inputTokens,
            outputTokens: state.progress.outputTokens,
            error: state.errorState,
            completedActions: state.completedActions,
            noProgressRounds: state.progress.noProgressRounds
        )
        if activeSessionID == sessionID {
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
    private func finishTask(_ taskID: UUID, sessionID: UUID, wasCancelled: Bool, failure: String?) async {
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
        if activeSessionID == sessionID {
            activeTask = taskStore.record(taskID)
        }
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
        runTask?.cancel()
        runTask = nil
        currentRunID = nil
        streamingStates.removeAll()
        resolveConsent(.deny)
        isRunning = false
        if let taskID = activeTask?.id {
            taskStore.update(taskID, status: .cancelled, error: "用户取消。")
            activeTask = nil
        }
    }

    /// 接收 Runner 发出的消息。
    ///
    /// 流式处理规则（保证「流式半成品 + 成品」不重复出现）：
    /// - `.streaming` 增量 → 累加进当前 in-flight 气泡；没有气泡时先新建一条；
    /// - 非流式消息（最终 `.text` / 工具进度 / 卡片 / 错误等）→ 若存在 in-flight
    ///   气泡，则**原地替换**该气泡（同一位置，不另起一条），并持久化最终消息。
    ///   流式增量本身不写盘，收尾时统一落一次，避免每 token 一次磁盘写。
    /// 接收 Runner 发出的消息。消息先绑定 sessionID + runID：
    /// 1. 只有 currentRunID == runID 的 callback 才被接受（迟到/过期 callback 一律丢弃）；
    /// 2. 持久化永远写入目标 session 的 SessionStore；
    /// 3. 只有 activeSessionID == sessionID 时才更新当前屏幕的 `messages`。
    ///
    /// 流式处理规则（保证「流式半成品 + 成品」不重复出现）：
    /// - `.streaming` 增量 → 累加进该 run 的 in-flight 气泡（key = runID）；
    /// - 非流式消息（最终 `.text` / 工具进度 / 卡片 / 错误等）→ 原地定型 in-flight 气泡并持久化。
    ///   流式增量本身不写盘，收尾时统一落一次，避免每 token 一次磁盘写。
    func receive(_ message: AgentChatMessage, sessionID: UUID, runID: UUID) async {
        // 过期 callback（旧 run 的迟到 token / 旧 run 的 final answer）→ 丢弃，不污染新运行。
        guard currentRunID == runID else { return }
        let isActiveSession = activeSessionID == sessionID

        // 流式增量：累加进该 run 的 in-flight 气泡（只在活动会话上更新 UI）。
        if let delta = Self.streamingDeltaText(from: message) {
            var state = streamingStates[runID] ?? AgentStreamingState(messageID: nil)
            if isActiveSession {
                if let streamingID = state.messageID,
                   let index = messages.lastIndex(where: { $0.id == streamingID }) {
                    var existing = messages[index]
                    let accumulated = Self.accumulatedStreamingText(existing) + delta
                    existing = AgentChatMessage(
                        id: existing.id,
                        role: .assistant,
                        messages: [.streaming(accumulated)],
                        createdAt: existing.createdAt
                    )
                    messages[index] = existing
                } else {
                    state.messageID = message.id
                    messages.append(message)
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
            messages[index] = message
            await sessionStore.append(message, to: sessionID)
            await trimHistoryIfNeeded(sessionID: sessionID)
            return
        }
        if isActiveSession {
            messages.append(message)
        }
        await sessionStore.append(message, to: sessionID)
        await trimHistoryIfNeeded(sessionID: sessionID)
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

    /// 汇总一条消息里已有的流式文本（用于在 in-flight 气泡上继续累加）。
    private static func accumulatedStreamingText(_ message: AgentChatMessage) -> String {
        var pieces: [String] = []
        for item in message.messages {
            if case let .streaming(text) = item { pieces.append(text) }
        }
        return pieces.joined()
    }

    /// token 预算保护：会话过长时保留最近的消息，避免请求被服务端拒绝。
    private func trimHistoryIfNeeded(sessionID: UUID) async {
        guard let session = await sessionStore.session(sessionID),
              session.tokenEstimate > Self.tokenBudget,
              session.messages.count > 12
        else { return }
        let kept = Array(session.messages.suffix(12))
        await sessionStore.clearMessages(sessionID)
        for message in kept { await sessionStore.append(message, to: sessionID) }
        // 只有被裁剪的会话正是当前活动会话时，才更新屏幕上的 messages。
        if activeSessionID == sessionID { messages = kept }
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
            fields.append("歌曲元数据（当前播放曲目）")
        }
        if permissions.allowsPlaybackHistory {
            fields.append("最近播放历史（最近 5 首）")
        }
        if permissions.allowsLyrics {
            fields.append("歌词（查询到时）")
        }
        fields.append("服务器名称与资料库统计（运行基础信息）")
        return AIPrivacyConsentRequest(
            providerName: providerName,
            modelName: modelName,
            fields: fields,
            purpose: "处理你的音乐请求（搜索、播放、推荐、收藏等）"
        )
    }

    /// 首次外发确认门槛：`auralis.ai.consentGiven` 已写入则直接放行；
    /// 未写入时挂起，等待 UI 决策（AssistantView 弹确认框）。
    /// 无界面模式（Siri / 快捷指令）没有可见确认框，按默认拒绝处理，不发起网络请求。
    private func ensureConsentIfNeeded(_ request: AIPrivacyConsentRequest) async -> AIConsentDecision {
        if UserDefaults.standard.bool(forKey: Self.consentGivenDefaultsKey) {
            return .allowAndRemember
        }
        if headless { return .deny }
        // 上一个确认还没结束时直接拒绝，避免弹窗互相覆盖。
        guard consentContinuation == nil else { return .deny }
        pendingConsent = request
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
        }
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
        return """
        为保护隐私，本次请求未发送到模型。首次外发需要确认：确认后将把以下内容发送到「\(request.providerName)」（模型：\(request.modelName)）：
        \(fieldsText)
        用途：\(request.purpose)
        请在弹窗中选择「允许一次」或「允许并记住」，或到「设置 → OpenAI 兼容接口」查看隐私选项。
        """
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
