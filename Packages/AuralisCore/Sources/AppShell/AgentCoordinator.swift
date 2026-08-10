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
    /// 只显示当前服务器的会话。
    @Published public var filtersByActiveServer = false { didSet { refreshSessionList() } }

    // MARK: - Dependencies

    private unowned let model: AuralisAppModel
    private let bridge: AuralisAgentBridge
    private let catalog: LocalCatalogStore
    private let sessionStore: SessionStore
    private let actionLog: AgentActionLog
    private let preferencesStore: PreferencesStore
    /// 长期存活的任务仓库：任务状态落盘，App 重启后标记 interrupted。
    private let taskStore: AgentTaskStore
    /// 系统服务工具适配：App / 设备 / 服务器 / 缓存 / 统计 / 诊断 / 记忆与技能。
    private let systemService: AuralisSystemToolService
    /// 跨会话记忆与技能存储：会话开始时注入提示词；memory_*/skill_* 工具读写同一实例。
    public let memoryStore: AgentMemoryStore

    private var runTask: Task<Void, Never>?
    private var consentContinuation: CheckedContinuation<AIConsentDecision, Never>?
    /// 当前正在流式输出的 assistant 气泡 id：`.streaming` 增量累加进该消息，
    /// 直到收到非流式消息（最终文本 / 工具进度 / 卡片等）把它原地定型为止。
    private var streamingMessageID: UUID?

    /// 单次请求带给模型的最大 token 预算（超出时裁剪历史）。
    public static let tokenBudget = 256_000
    /// 首次外发确认的持久化标记键（UserDefaults，默认 false）。
    public static let consentGivenDefaultsKey = "auralis.ai.consentGiven"
    /// 设置接口的展示名（与 AIConnectionSettings.makeProvider 的配置名保持一致）。
    private static let providerDisplayName = "OpenAI 兼容接口"

    public init(model: AuralisAppModel, coordinator: CatalogCoordinator, directory: URL? = nil) {
        self.model = model
        self.catalog = coordinator.store
        self.bridge = AuralisAgentBridge(model: model, coordinator: coordinator)
        let dir = directory ?? Self.defaultDirectory()
        let memoryStore = AgentMemoryStore(directory: dir)
        self.memoryStore = memoryStore
        self.systemService = AuralisSystemToolService(model: model, memoryStore: memoryStore)
        self.sessionStore = SessionStore(fileURL: dir.appendingPathComponent("agent-sessions.json"))
        self.actionLog = AgentActionLog(fileURL: dir.appendingPathComponent("agent-actions.json"))
        self.preferencesStore = PreferencesStore(fileURL: dir.appendingPathComponent("agent-preferences.json"))
        self.taskStore = AgentTaskStore(fileURL: dir.appendingPathComponent("agent-tasks.json"))
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Auralis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Bootstrap

    /// 恢复上次的会话列表、操作日志与偏好。
    public func bootstrap() async {
        // App 重启：把上次仍在运行的任务标记为 interrupted，不自动重放已完成的写操作。
        taskStore.markInterruptedOnLaunch()
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
        if filtersByActiveServer, let serverID = model.catalog.activeServerID {
            result = result.filter { $0.serverID == serverID }
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
    public func send(_ text: String, provider: (any AIProvider)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        if let sessionID = activeSessionID {
            startRun(text: trimmed, provider: provider, sessionID: sessionID)
        } else {
            // 会话列表尚未 bootstrap 完成（或没有选中任何会话）：先建会话再运行。
            Task { [weak self] in
                guard let self else { return }
                let sessionID = await self.newSession()
                self.startRun(text: trimmed, provider: provider, sessionID: sessionID)
            }
        }
    }

    /// 无界面执行：发送一条消息并等待本轮运行结束，返回助手新增的文本回复。
    /// 供 Siri / 快捷指令等系统入口调用（此时 headless 临时置为 true）。
    /// 工具调用直接执行；调用结束恢复原值，不影响 App 内运行状态。
    @discardableResult
    public func sendAndWait(_ text: String, provider: (any AIProvider)? = nil) async -> String {
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
        send(trimmed, provider: provider)
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
    /// Agent 输出上限已是 8_192 token：中文约 1 字/token、英文约 4 字符/token，
    /// 完整回复约 8k–33k 字符。40_000 字符覆盖完整回复且留足余量，
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

    private func startRun(text: String, provider: (any AIProvider)?, sessionID: UUID) {
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
        let history = messages
        let systemService = self.systemService
        let messageCountBeforeRun = messages.count
        // 创建并持久化任务记录（不依赖任何 View 生命周期）。
        let taskID = taskStore.start(conversationID: activeSessionID).id
        activeTask = taskStore.record(taskID)

        runTask = Task { [weak self] in
            guard let self else { return }
            // 用户在任务真正开始前点了停止：直接结束，不回任何消息。
            if Task.isCancelled {
                await MainActor.run { [weak self] in self?.isRunning = false }
                self.runTask = nil
                return
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
                        sessionID: sessionID
                    )
                    await self.receive(
                        AgentChatMessage(role: .assistant, messages: [.text(Self.consentDeniedText(consent))]),
                        sessionID: sessionID
                    )
                    taskStore.update(taskID, status: .cancelled, error: "用户未授权首次外发请求。")
                    activeTask = taskStore.record(taskID)
                    await MainActor.run { [weak self] in self?.isRunning = false }
                    self.runTask = nil
                    return
                case .allowOnce, .allowAndRemember:
                    break
                }
            }

            await AgentRunner.run(
                userText: trimmed,
                provider: resolvedProvider,
                model: modelName,
                bridge: bridge,
                catalog: catalog,
                context: context,
                history: history,
                systemService: systemService,
                confirm: { _ in true },
                emit: { [weak self] message in
                    await self?.receive(message, sessionID: sessionID)
                },
                log: { [weak self] record in
                    await self?.record(record)
                },
                progress: { [weak self] p in
                    await self?.updateTaskProgress(p, taskID: taskID)
                }
            )
            await MainActor.run { [weak self] in self?.isRunning = false }
            let failure = Self.failureSummary(in: self.messages.dropFirst(messageCountBeforeRun))
            await self.finishTask(taskID, failure: failure)
            await self.summarizeActiveSession()
            // 任务结束即释放对 self 的强引用，避免 runTask 长期持有协调器。
            self.runTask = nil
        }
    }

    /// 更新任务进度（工具步骤 / 当前阶段 / token 用量）。
    private func updateTaskProgress(_ progress: AgentRunner.AgentProgress, taskID: UUID) async {
        taskStore.update(
            taskID,
            step: progress.currentStep,
            toolSteps: progress.toolSteps,
            inputTokens: progress.inputTokens ?? 0,
            outputTokens: progress.outputTokens ?? 0
        )
        activeTask = taskStore.record(taskID)
    }

    /// 任务结束后按真实结果落盘。此前 Runner 已发出 `.error` 时仍被一律标为
    /// completed，导致用户看到失败、任务记录却显示完成，无法诊断或恢复。
    private func finishTask(_ taskID: UUID, failure: String?) async {
        let status: AgentTaskStatus
        if runTask?.isCancelled == true {
            status = .cancelled
        } else if failure != nil {
            status = .failed
        } else {
            status = .completed
        }
        taskStore.update(taskID, status: status, error: failure)
        activeTask = taskStore.record(taskID)
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
    private func receive(_ message: AgentChatMessage, sessionID: UUID) async {
        // 流式增量：累加进 in-flight 气泡（或在没有气泡时新建一条）。
        if let delta = Self.streamingDeltaText(from: message) {
            if let streamingID = streamingMessageID,
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
                streamingMessageID = message.id
                messages.append(message)
            }
            return
        }

        // 非流式消息：把 in-flight 气泡原地定型为这条最终消息（同一位置，不另起一条）。
        if let streamingID = streamingMessageID {
            streamingMessageID = nil
            if let index = messages.lastIndex(where: { $0.id == streamingID }) {
                messages[index] = message
                await sessionStore.append(message, to: sessionID)
                await trimHistoryIfNeeded(sessionID: sessionID)
                return
            }
        }
        messages.append(message)
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
        messages = kept
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
