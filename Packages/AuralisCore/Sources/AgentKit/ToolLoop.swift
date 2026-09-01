import AIKit
import Domain
import Foundation
import LocalCatalog

/// 通用对话工具循环（permissive direct execution）。
///
/// 流程：用户文本 →（可选 LLM 规划）→ 本地工具执行 → 结果回传 → UI 渲染。
/// 设计准则：已注册的普通音乐工具默认全部允许；Intent 只是路由提示，不是能力边界；
/// 用户明确要求且目标唯一时直接执行；只有 `ToolDescriptor` 明确要求确认的操作
/// （通常是不可逆高风险操作，如删除歌单、清空记忆、删除技能）需要一次用户批准。
/// 硬性约束：每一轮模型请求和每一次工具执行都有独立超时；支持取消与防循环。
/// 单工具超时/失败回灌结构化结果让模型换策略继续，不终止整项任务；
/// 不设正常任务累计工具调用上限；noProgress / repeatedToolPattern 只做诊断统计。
public struct ToolLoop {
    /// 单个工具调用的最长执行时间。超过后取消该调用并结束整项 Agent 任务，
    /// 防止某个网络/系统服务工具卡住而让任务无限悬挂。
    public static let toolExecutionTimeout: TimeInterval = 3 * 60
    /// 模型每一轮的总响应时限。长回答、复杂规划和批量 JSON 分类都可能持续数分钟；
    /// 整项任务没有总轮数上限，但每个独立模型请求最多等待 180 秒。
    public static let roundTimeout: TimeInterval = 3 * 60

    public struct Context: Sendable {
        public let serverID: ServerID?
        public let serverName: String?
        public let serverType: String?
        public let currentTrackTitle: String?
        public let currentTrackArtist: String?
        public let queueCount: Int
        public let totalTracks: Int
        public let totalArtists: Int
        public let totalAlbums: Int
        public let totalPlaylists: Int
        public let favoriteCount: Int
        public let recentlyPlayedTitles: [String]
        public let isShuffled: Bool
        public let repeatMode: String
        /// 隐私：是否允许发送当前歌曲元数据（对应设置页「允许发送歌曲元数据」）。
        public let allowsMetadata: Bool
        /// 隐私：是否允许发送歌词内容（对应设置页「允许发送歌词」）。
        public let allowsLyrics: Bool
        /// 隐私：是否允许发送最近播放历史（对应设置页「允许发送播放历史摘要」）。
        public let allowsHistory: Bool
        /// 隐私：是否允许发送收藏与评分（对应设置页「允许发送收藏和评分」）。
        public let allowsFavoritesAndRatings: Bool
        /// 隐私：是否允许将歌曲内容元数据用于公开网络检索。
        public let allowsExternalDiscovery: Bool
        /// Complete run-scoped privacy policy propagated to every tool result.
        /// The individual fields above remain as source-compatible projections.
        public let privacyPermissions: AIPrivacyPermissions
        /// 跨会话记忆：主人告诉 Agent 的个人信息（由 memory_* 工具维护，注入提示词）。
        public let memories: [AgentMemoryEntry]
        /// 已创建的技能列表（由 skill_* 工具维护，注入提示词）。
        public let skills: [AgentSkillEntry]
        /// Shared by runs owned by one application coordinator. Standalone
        /// ToolLoop callers receive an isolated registry by default.
        public let mutationResourceLeaseRegistry: MutationResourceLeaseRegistry
        /// Authoritative live state for Recommendation Index runs. It is
        /// coordinator-scoped so status queries can distinguish persisted
        /// pending data from an actually running background task.
        public let recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry
        /// Persisted declarative tools are joined to the canonical model
        /// catalog at the run boundary. Discovery and execution receive the
        /// same registry snapshot for this run.
        public let customToolRegistry: CustomToolRegistry
        /// User-selected reasoning intent. Provider codecs decide whether the
        /// selected endpoint can project it onto a request.
        public let reasoning: AIReasoningConfiguration

        public init(
            serverID: ServerID? = nil,
            serverName: String? = nil,
            serverType: String? = nil,
            currentTrackTitle: String? = nil,
            currentTrackArtist: String? = nil,
            queueCount: Int = 0,
            totalTracks: Int = 0,
            totalArtists: Int = 0,
            totalAlbums: Int = 0,
            totalPlaylists: Int = 0,
            favoriteCount: Int = 0,
            recentlyPlayedTitles: [String] = [],
            isShuffled: Bool = false,
            repeatMode: String = "顺序",
            privacyPermissions: AIPrivacyPermissions? = nil,
            allowsMetadata: Bool = true,
            allowsLyrics: Bool = false,
            allowsHistory: Bool = false,
            allowsFavoritesAndRatings: Bool = false,
            allowsExternalDiscovery: Bool = false,
            memories: [AgentMemoryEntry] = [],
            skills: [AgentSkillEntry] = [],
            mutationResourceLeaseRegistry: MutationResourceLeaseRegistry = MutationResourceLeaseRegistry(),
            recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry(),
            customToolRegistry: CustomToolRegistry = .shared,
            reasoning: AIReasoningConfiguration = AIReasoningConfiguration()
        ) {
            var resolvedPrivacy = privacyPermissions ?? AIPrivacyPermissions()
            if privacyPermissions == nil {
                resolvedPrivacy.allowsMetadata = allowsMetadata
                resolvedPrivacy.allowsLyrics = allowsLyrics
                resolvedPrivacy.allowsPlaybackHistory = allowsHistory
                resolvedPrivacy.allowsFavoritesAndRatings = allowsFavoritesAndRatings
                resolvedPrivacy.allowsExternalDiscovery = allowsExternalDiscovery
            }
            self.privacyPermissions = resolvedPrivacy
            self.serverID = serverID
            self.serverName = serverName
            self.serverType = serverType
            self.currentTrackTitle = currentTrackTitle
            self.currentTrackArtist = currentTrackArtist
            self.queueCount = queueCount
            self.totalTracks = totalTracks
            self.totalArtists = totalArtists
            self.totalAlbums = totalAlbums
            self.totalPlaylists = totalPlaylists
            self.favoriteCount = favoriteCount
            self.recentlyPlayedTitles = recentlyPlayedTitles
            self.isShuffled = isShuffled
            self.repeatMode = repeatMode
            self.allowsMetadata = resolvedPrivacy.allowsMetadata
            self.allowsLyrics = resolvedPrivacy.allowsLyrics
            self.allowsHistory = resolvedPrivacy.allowsPlaybackHistory
            self.allowsFavoritesAndRatings = resolvedPrivacy.allowsFavoritesAndRatings
            self.allowsExternalDiscovery = resolvedPrivacy.allowsExternalDiscovery
            self.memories = memories
            self.skills = skills
            self.mutationResourceLeaseRegistry = mutationResourceLeaseRegistry
            self.recommendationIndexExecutionRegistry = recommendationIndexExecutionRegistry
            self.customToolRegistry = customToolRegistry
            self.reasoning = reasoning
        }
    }

    /// 任务进度快照（供 AgentTaskManager / UI 展示，不携带任何凭据）。
    public struct AgentProgress: Sendable {
        public enum Activity: Sendable, Equatable {
            case ordinary
            case workflow(skillID: String, phase: String, detail: String)
        }

        public let toolSteps: Int
        public let currentStep: String
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let activity: Activity

        public init(
            toolSteps: Int,
            currentStep: String,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            activity: Activity = .ordinary
        ) {
            self.toolSteps = toolSteps
            self.currentStep = currentStep
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.activity = activity
        }
    }

    /// 一次流式模型生成的结果：分离的思考/正文缓冲、原生工具调用和 token 用量。
    /// 与 `AICompletionResponse` 对应，但由 `provider.stream()` 的增量事件拼装而成。
    private struct StreamOutcome: Sendable {
        var reasoningText = ""
        var answerText = ""
        var toolCalls: [AIToolCall] = []
        var webCitations: [AIWebCitation] = []
        var inputTokens: Int?
        var outputTokens: Int?
    }

    /// Internal loop representation. Native provider calls stay structured all
    /// the way into ToolRuntime; `stringArguments` exists only for legacy
    /// ledgers, diagnostics, and the ACTION compatibility codec.
    private struct LoopToolCall {
        /// 调用的结构化来源。Skill 模式下只允许 `.skillForced` 执行 mutation；
        /// 模型/provider 的 tool_call.id 属于不可信输入，绝不能作为权限来源。
        let origin: LoopToolCallOrigin
        let id: String?
        let name: String
        var arguments: [String: AIJSONValue]
        let malformedArguments: Bool
        let usesTextProtocol: Bool

        var stringArguments: [String: String] {
            ToolCall(name: name, arguments: arguments).stringArguments
        }
    }

    private enum LoopToolCallOrigin: Sendable, Equatable {
        case providerNative
        case textualAction
        case skillForced
        case skillGenerated

        var isRuntimeOwned: Bool {
            switch self {
            case .skillForced, .skillGenerated:
                return true
            case .providerNative, .textualAction:
                return false
            }
        }

        var isModelOwned: Bool { !isRuntimeOwned }
    }

    /// Provider 一次请求发出前的 schema admission 快照。
    /// `tool_search` 可以扩展下一轮 schema，但不得让同一份 Provider 响应
    /// 中稍后出现的调用获得本轮尚未见过的工具权限。
    private struct RoundToolAdmission: Sendable {
        private let names: Set<String>

        init(_ selectedTools: [ToolDescriptor]) {
            var names = Set<String>()
            for descriptor in selectedTools {
                names.insert(descriptor.name)
                names.insert(ToolSelector.canonicalAliases[descriptor.name] ?? descriptor.name)
                for alias in descriptor.aliases {
                    names.insert(alias)
                    names.insert(ToolSelector.canonicalAliases[alias] ?? alias)
                }
            }
            self.names = names
        }

        func contains(_ call: LoopToolCall) -> Bool {
            let canonicalName = ToolSelector.canonicalAliases[call.name] ?? call.name
            return names.contains(call.name) || names.contains(canonicalName)
        }
    }

    /// Model calls must come from the tool schema loaded for this round.
    /// Stateful Skills may emit their own forced/generated calls because those
    /// calls are Runtime-owned control-flow edges rather than model authority.
    private static func isModelToolCallAdmitted(
        _ call: LoopToolCall,
        admission: RoundToolAdmission
    ) -> Bool {
        switch call.origin {
        case .skillForced, .skillGenerated:
            return true
        case .providerNative, .textualAction:
            // Provider schema uses canonical names, while the textual
            // compatibility protocol may still emit a legacy alias.  An
            // alias is admitted only when its canonical descriptor was
            // loaded for this round; this does not broaden the model schema
            // or grant a hidden capability.
            return admission.contains(call)
        }
    }

    private static func parallelResultKey(for call: LoopToolCall, index: Int) -> String {
        call.id ?? "parallel-\(index)"
    }

    private enum ToolArgumentParseResult {
        case success([String: AIJSONValue])
        case malformed(rawLength: Int)
    }

    /// Separates what `tool_search` discovered from what the current model
    /// schema actually accepted.  A Stateful Skill can intentionally discover
    /// an owned mutation while still refusing to expose it to the model.
    private struct ToolSearchExpansionResult {
        let discoveredEntries: [ToolCatalogEntry]
        let addedEntries: [ToolCatalogEntry]
    }

    /// 执行一次用户请求。
    /// - Parameters:
    ///   - provider: AI Provider；为 nil 时 AI Assistant 明确返回不可用（只保留
    ///     Direct Read Fast Path 的确定性只读查询，不做关键词规则降级）。
    ///   - toolTimeout: 单个工具执行的最长等待时间；超时以结构化失败回灌模型，不终止任务。
    ///   - confirm: 仅在 `ToolDescriptor.requiresExplicitUserApproval` 的工具实际执行前调用；其它工具不会经过该回调。
    ///   - emit: 逐步向 UI 发送结构化消息。
    ///   - log: 所有修改型（reversible / destructive）工具调用的落盘回调。
    public static func run(
        userText: String,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        webService: (any AgentWebService)? = nil,
        intent: AgentTaskIntent? = nil,
        policy: AgentTaskPolicy? = nil,
        initialTaskState: AgentTaskState? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        executionLineage: ExecutionLineage? = nil,
        requestPlan: AgentRequestPlan? = nil,
        convergencePolicy: AgentConvergencePolicy? = nil,
        enabledFixedSkills: Bool = true,
        runID: UUID = UUID(),
        executionLease: ToolExecutionLease? = nil,
        toolTimeout: TimeInterval = ToolLoop.toolExecutionTimeout,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in },
        observeRecommendationIndex: @escaping @Sendable (RecommendationIndexExecutionEvent) async -> Void = { _ in }
    ) async {
        if let scopedWebService = webService as? any AgentWebRunScopedService {
            await scopedWebService.beginRun(runID)
        }
        // 用户消息先回显
        await emit(AgentChatMessage(
            id: executionLineage?.originUserMessageID ?? UUID(),
            role: .user,
            messages: [.text(userText)]
        ))

        // 一次 turn 只生成一份共享请求计划：semantics / intent / policy /
        // operation metadata 全部来自同一个分析结果，禁止各层重新解释用户文本。
        // ConversationEngine 等上层可传入已构建的 plan，避免重复分析。
        let plan = requestPlan ?? AgentRequestPlan.build(
            userText: userText,
            history: history,
            explicitIntent: intent,
            explicitPolicy: policy,
            authorizationContext: authorizationContext,
            executionLineage: executionLineage,
            initialTaskState: initialTaskState
        )
        let requestSemantics = plan.semantics
        let resolvedIntent = plan.intent
        let resolvedPolicy = plan.policy
        // ConversationEngine/AgentCoordinator may supply a run-owned lease so
        // cancellation and stale callbacks can revoke a mutation. A direct
        // compatibility caller gets a fresh local lease; this is lifecycle
        // ownership, not a semantic permission grant.
        let resolvedAuthorization = plan.authorization
        let resolvedExecutionLease: ToolExecutionLease
        if let executionLease, executionLease.runID == runID {
            resolvedExecutionLease = executionLease
        } else if executionLease == nil {
            resolvedExecutionLease = ToolExecutionLease(
                runID: runID,
                sessionID: executionLineage?.taskID ?? runID,
                generation: 0
            )
        } else {
            resolvedExecutionLease = .revoked(runID: runID)
        }
        // Materialize declarative tools once at the run boundary. The same
        // snapshot is used by selector, provider schema, tool_search and
        // ToolRuntime so discovery cannot advertise a different set than the
        // executor can actually run.
        let customSnapshot = await context.customToolRegistry.modelSnapshot()
        let availableToolDescriptors = Self.descriptorsWithCustomTools(customSnapshot.descriptors)
        let workflowRoute = WorkflowEngine.route(
            intent: resolvedIntent,
            text: userText,
            semantics: requestSemantics,
            initialTaskState: initialTaskState,
            executionLineage: executionLineage
        )
        let providerName = provider.map { String(describing: type(of: $0)) }
        // High-confidence, read-only collection/status queries are complete
        // local requests. Execute the canonical descriptor once and return;
        // neither provider planning nor tool_search is needed for these
        // deterministic reads. Resumed workflows remain on their stateful
        // route so a pending task cannot be accidentally short-circuited.
        if workflowRoute.kind != .recommendationIndex,
           let directReadCapability = requestSemantics.directReadCapability,
           requestSemantics.isReadOnly,
           initialTaskState == nil,
           !requestSemantics.isMusicAppreciation,
           let directDescriptor = descriptor(named: directReadCapability.toolName, in: availableToolDescriptors) {
            await runDirectReadFastPath(
                descriptor: directDescriptor,
                arguments: directReadCapability.arguments,
                providerCapabilities: provider?.capabilities,
                bridge: bridge,
                catalog: catalog,
                context: context,
                systemService: systemService,
                externalMusicService: externalMusicService,
                webService: webService,
                authorizationContext: resolvedAuthorization,
                runID: runID,
                executionLease: resolvedExecutionLease,
                toolTimeout: toolTimeout,
                emit: emit,
                progress: progress
            )
            return
        }
        // Generic Agent 不再在模型规划前由 Runtime 判定“能力不足”并提前结束。
        // 工具可用性与真实执行结果交给模型，由模型决定继续、换策略或结束。
        if workflowRoute.kind == .recommendationIndex {
            await observeRecommendationIndex(RecommendationIndexExecutionEvent(
                kind: .routeSelected,
                runID: resolvedExecutionLease.runID,
                sessionID: resolvedExecutionLease.sessionID,
                serverID: context.serverID,
                phase: .readingStatus,
                provider: providerName,
                model: model,
                message: provider == nil
                    ? "RecommendationIndexSkillRuntime provider unavailable"
                    : "RecommendationIndexSkillRuntime"
            ))
            guard let provider else {
                var taskState = initialTaskState ?? AgentTaskState(
                    intent: .libraryManagement,
                    goal: userText
                )
                let message = "推荐索引执行失败（stage=providerOutput）：需要可用的 AI Provider；当前没有发起离线音乐搜索或其他替代执行。"
                taskState.status = .failed
                taskState.completionState = .failed
                taskState.errorState = message
                taskState.errors.append(message)
                taskState.pendingActions = []
                await state(taskState)
                await observeRecommendationIndex(RecommendationIndexExecutionEvent(
                    kind: .failed,
                    runID: resolvedExecutionLease.runID,
                    sessionID: resolvedExecutionLease.sessionID,
                    serverID: context.serverID,
                    phase: .readingStatus,
                    provider: providerName,
                    model: model,
                    message: message
                ))
                await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                return
            }
            await RecommendationIndexSkillRuntime.run(
                userText: userText,
                provider: provider,
                model: model,
                bridge: bridge,
                catalog: catalog,
                serverID: context.serverID,
                systemService: systemService,
                externalMusicService: externalMusicService,
                webService: webService,
                privacyPermissions: context.privacyPermissions,
                allowsMetadata: context.allowsMetadata,
                allowsLyrics: context.allowsLyrics,
                allowsHistory: context.allowsHistory,
                allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                availableToolDescriptors: availableToolDescriptors,
                policy: resolvedPolicy,
                initialTaskState: initialTaskState,
                authorizationContext: resolvedAuthorization,
                lineageID: executionLineage?.lineageID ?? UUID(),
                executionLease: resolvedExecutionLease,
                requestTimeout: roundTimeout,
                resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                executionStateRegistry: context.recommendationIndexExecutionRegistry,
                emit: emit,
                log: log,
                progress: progress,
                state: state,
                observe: observeRecommendationIndex,
                providerName: providerName,
                modelName: model
            )
            return
        }
        if let provider {
            if !requestSemantics.requiresSideEffect,
               resolvedPolicy.completion != .appreciationWithEvidence,
               initialTaskState == nil {
                await runGenericChat(
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
                    plan: plan,
                    availableToolDescriptors: availableToolDescriptors,
                    initialCustomToolRevision: customSnapshot.revision,
                    sideEffectAuthorization: resolvedAuthorization,
                    convergencePolicy: convergencePolicy ?? .interactive,
                    runID: runID,
                    executionLease: resolvedExecutionLease,
                    toolTimeout: toolTimeout,
                    confirm: confirm,
                    emit: emit,
                    log: log,
                    progress: progress
                )
            } else {
                await runWithLLM(
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
                    plan: plan,
                    availableToolDescriptors: availableToolDescriptors,
                    initialCustomToolRevision: customSnapshot.revision,
                    intent: resolvedIntent,
                    policy: resolvedPolicy,
                    initialTaskState: initialTaskState,
                    sideEffectAuthorization: resolvedAuthorization,
                    enabledFixedSkills: enabledFixedSkills,
                    runID: runID,
                    executionLease: resolvedExecutionLease,
                    toolTimeout: toolTimeout,
                    confirm: confirm,
                    emit: emit,
                    log: log,
                    progress: progress,
                    state: state
                )
            }
        } else {
            // AI Provider 不可用：AI Assistant 是智能层，不降级为关键词规则伪 Agent。
            // 普通聊天 / 复杂音乐任务 / 推荐 / 鉴赏 / 歌单构建一律明确不可用；
            // 播放器 UI、搜索页、歌单页、队列页等系统命令入口不受影响。
            await emit(AgentChatMessage(
                role: .assistant,
                messages: [.error("AI 服务未配置或暂时不可用；本次 AI 任务无法执行。播放器、搜索、歌单、队列等 App 内普通功能仍可正常使用，但不会改写为本地关键词规则或随机推荐。请先配置可用的 AI Provider。")]
            ))
        }
    }

    /// Deterministic execution path for one high-confidence read. This is
    /// intentionally separate from `runGenericChat`: the latter is a model
    /// conversation loop and cannot guarantee that a simple request results
    /// in exactly one target tool call.
    private static func runDirectReadFastPath(
        descriptor: ToolDescriptor,
        arguments: [String: AIJSONValue],
        providerCapabilities: ModelCapabilities?,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: Context,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)?,
        webService: (any AgentWebService)?,
        authorizationContext: SideEffectAuthorizationContext,
        runID: UUID,
        executionLease: ToolExecutionLease,
        toolTimeout: TimeInterval,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        progress: @escaping @Sendable (AgentProgress) async -> Void
    ) async {
        let call = ToolCall(name: descriptor.name, arguments: arguments)
        await progress(AgentProgress(toolSteps: 1, currentStep: "读取 \(descriptor.summary)"))

        let result: ToolResult
        do {
            result = try await withTimeout(
                effectiveToolTimeout(descriptor, requested: toolTimeout)
            ) {
                await ToolRuntime.executeMeasured(
                    call,
                    bridge: bridge,
                    catalog: catalog,
                    serverID: context.serverID,
                    systemService: systemService,
                    externalMusicService: externalMusicService,
                    privacyPermissions: context.privacyPermissions,
                    allowsLyrics: context.allowsLyrics,
                    providerCapabilities: providerCapabilities,
                    webService: webService,
                    authorizationContext: authorizationContext,
                    executionLease: executionLease,
                    resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                    recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                    customToolRegistry: context.customToolRegistry,
                    availableToolDescriptors: [descriptor],
                    runID: runID,
                    callID: "direct-\(runID.uuidString)"
                )
            }
        } catch is CancellationError {
            await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
            return
        } catch {
            await emit(AgentChatMessage(
                role: .assistant,
                messages: [.error("读取 \(descriptor.summary) 失败：\(errorText(error))")]
            ))
            return
        }

        guard result.success else {
            await emit(AgentChatMessage(
                role: .assistant,
                messages: [.error("读取 \(descriptor.summary) 失败：\(result.summary)")]
            ))
            return
        }

        var messages: [AgentMessage] = []
        if let payload = result.payload {
            messages.append(payload)
            if case .text = payload {
                // The text payload already contains the complete direct-read
                // answer; avoid duplicating the compact result summary.
            } else if !result.summary.isEmpty {
                messages.append(.text(result.summary))
            }
        } else if !result.summary.isEmpty {
            messages.append(.text(result.summary))
        }
        if !messages.isEmpty {
            await emit(AgentChatMessage(role: .assistant, messages: messages))
        }
    }

    // MARK: - Generic conversation loop

    /// A provider-first chat loop. It deliberately has no AgentTaskState,
    /// WorkflowEngine route or CompletionEvaluator: a normal answer is a
    /// complete answer, while optional tools are executed only when the model
    /// actually requests them.
    private static func runGenericChat(
        userText: String,
        provider: any AIProvider,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: Context,
        history: [AgentChatMessage],
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)?,
        webService: (any AgentWebService)?,
        plan: AgentRequestPlan,
        availableToolDescriptors initialAvailableToolDescriptors: [ToolDescriptor],
        initialCustomToolRevision: UInt64,
        sideEffectAuthorization: SideEffectAuthorizationContext,
        convergencePolicy: AgentConvergencePolicy,
        runID: UUID,
        executionLease: ToolExecutionLease,
        toolTimeout: TimeInterval,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void,
        progress: @escaping @Sendable (AgentProgress) async -> Void
    ) async {
        var availableToolDescriptors = initialAvailableToolDescriptors
        // The initial selector already consumed this exact snapshot. Do not
        // treat it as a hot-reload event: doing so would append every custom
        // tool to the first schema and bypass tool_search's on-demand
        // discovery contract.
        var loadedCustomToolRevision: UInt64? = initialCustomToolRevision
        var selectedTools = ToolSelector.select(plan: plan, all: availableToolDescriptors)
        let directReadToolName = plan.semantics.directReadCapability?.toolName
        let effectiveAuthorization = sideEffectAuthorization
        // run-scoped Capability 快照：普通聊天路径的 capabilities_get 与
        // System Prompt 摘要共用同一份真实状态。getActiveServer 用 try? 保护：
        // 任务取消时静默降级（activeServer=false），不打断既有的取消处理路径。
        let capabilityEnvironment = Self.capabilityEnvironment(
            provider: provider,
            catalog: catalog,
            systemService: systemService,
            webService: webService,
            activeServer: (await bridge.getActiveServer()) != nil
        )
        let nativeMode = provider.supportsToolCalling
            && provider.capabilities.toolMode != .none
            && provider.capabilities.toolMode != .textualToolProtocol
        // Only a protocol which does not declare native tools stays text-only.
        // Capability diagnostics are observational and must never turn a
        // declared Chat/Responses/Messages provider into a different protocol.
        if provider.capabilities.toolMode == .none {
            selectedTools = []
        }
        // 普通聊天保留行为计数供 diagnostics；这些计数不作为 convergence 终止条件。
        var convergence = AgentConvergenceTracker()
        var toolChoice: AIToolChoice? = nativeMode && provider.capabilities.supportsToolChoice ? .auto : nil
        var conversation = [AIMessage(
            role: .system,
            content: systemPrompt(
                context: context,
                tools: selectedTools,
                nativeToolCalling: nativeMode,
                environment: capabilityEnvironment,
                awarenessTools: availableToolDescriptors,
                authorizedOperations: effectiveAuthorization.allowedOperations
            )
        )]
        conversation.append(contentsOf: convertHistory(history, currentUserText: userText, permissions: context.privacyPermissions))
        conversation.append(AIMessage(role: .user, content: userText))

        var toolSteps = 0
        // Generic chat still needs execution safety, but it does not need a
        // business completion evaluator. These ledgers are deliberately
        // protocol-agnostic: they prevent an accidental duplicate mutation
        // and reuse repeatable reads without imposing a tool-call budget.
        var completedSideEffects = Set<String>()
        var indeterminateSideEffects = Set<String>()
        var cachedReadResults: [String: String] = [:]
        var readRepeatCounts: [String: Int] = [:]
        // A one-time, Runtime-owned read-only expansion is a recovery from a
        // thin first schema window, not a substitute for model planning.
        var didAutomaticToolExpansion = false
        // Search evidence is tracked per capability for diagnostics. The
        // streak does not remove a tool or stop ordinary model planning.
        var searchEvidenceByTool: [String: Set<String>] = [:]
        // Generic chat has no task completion evaluator, but read-only music
        // results still need the same buffered UI presentation contract as
        // deterministic tasks: collect cards during tool turns and emit them
        // once alongside the natural final answer.
        var presentation = AgentPresentationState()
        while true {
            let customSnapshot = await context.customToolRegistry.modelSnapshot()
            if loadedCustomToolRevision != customSnapshot.revision {
                availableToolDescriptors = Self.descriptorsWithCustomTools(customSnapshot.descriptors)
                loadedCustomToolRevision = customSnapshot.revision
                selectedTools.removeAll { $0.customToolID != nil }
                for descriptor in customSnapshot.descriptors where Self.shouldExposeDescriptorForPlan(
                    descriptor,
                    semantics: plan.semantics,
                    activeSkillID: nil
                ) {
                    guard !selectedTools.contains(where: { $0.name == descriptor.name }) else { continue }
                    selectedTools.append(descriptor)
                }
                conversation[0] = AIMessage(
                    role: .system,
                    content: Self.systemPrompt(
                        context: context,
                        tools: selectedTools,
                        nativeToolCalling: nativeMode,
                        environment: capabilityEnvironment,
                        awarenessTools: availableToolDescriptors,
                        authorizedOperations: effectiveAuthorization.allowedOperations
                    )
                )
            }
            if Task.isCancelled {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                return
            }
            convergence.recordModelRound()
            if let stopReason = convergence.stopReason(under: convergencePolicy) {
                await emit(AgentChatMessage(role: .assistant, messages: [.error(stopReason.userMessage)]))
                return
            }

            let hostedTools = nativeMode
                ? hostedTools(for: provider.capabilities, availableTools: selectedTools)
                : []
            let modelTools = localModelTools(selectedTools, capabilities: provider.capabilities)
            let toolDefinitions = nativeMode
                ? ToolSelector.toolDefinitions(from: modelTools, strict: provider.capabilities.supportsStrictSchema)
                : []
            let roundAdmission = RoundToolAdmission(selectedTools)
            let schemaTokens = nativeMode ? ContextManager.estimatedTokens(toolDefinitions) : 0
            let inputBudget = ContextManager.inputBudget(
                capabilities: provider.capabilities,
                requestedInputBudget: provider.capabilities.maxContextTokens,
                reservedOutputTokens: provider.capabilities.maxOutputTokens + schemaTokens
            )
            guard ContextManager.canFitCurrentUser(conversation, userText: userText, maxTokens: inputBudget) else {
                await emit(AgentChatMessage(role: .assistant, messages: [.error("当前模型上下文不足，无法发送完整对话。请切换到上下文更大的模型。")]))
                return
            }
            conversation = ContextManager.trimByTokens(
                conversation,
                maxTokens: inputBudget,
                preservingUserText: userText
            )

            let request = AICompletionRequest(
                model: model,
                transcript: AITranscript(messages: conversation),
                temperature: 0.3,
                maxTokens: provider.capabilities.maxOutputTokens,
                tools: nativeMode ? toolDefinitions : nil,
                toolChoice: nativeMode ? toolChoice : nil,
                hostedTools: hostedTools.isEmpty ? nil : hostedTools,
                reasoning: context.reasoning
            )
            let outcome: StreamOutcome
            do {
                outcome = try await streamWithFallback(
                    provider: provider,
                    request: request,
                    timeout: roundTimeout,
                    onAnswerDelta: { delta in
                        await emitStreamingDelta(delta, emit: emit)
                    },
                    onReasoningDelta: { delta in
                        await emitStreamingReasoningDelta(delta, emit: emit)
                    }
                )
            } catch is CancellationError {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                return
            } catch {
                // A provider failure is a provider failure. Generic chat never
                // changes protocol or silently becomes a local music search.
                await emit(AgentChatMessage(role: .assistant, messages: [.error("AI Provider 请求失败：\(errorText(error))")]))
                return
            }

            if !outcome.webCitations.isEmpty {
                let sources = webSources(from: outcome.webCitations)
                if !sources.isEmpty {
                    await registerWebSources(sources, webService: webService, runID: runID)
                    await emit(AgentChatMessage(role: .assistant, messages: [.webSources(sources)]))
                }
            }

            let streamedText = outcome.answerText
            let nativeCalls = nativeMode ? outcome.toolCalls : []
            // Native requests only accept provider-native tool calls. ACTION is
            // decoded exclusively when the request started in textual mode.
            let textActions = !nativeMode && nativeCalls.isEmpty ? parseActions(from: streamedText) : []
            if nativeCalls.isEmpty, textActions.isEmpty {
                let answer = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !didAutomaticToolExpansion,
                   shouldAutomaticallyExpandToolSurface(
                       answer: answer,
                       plan: plan,
                       current: selectedTools,
                       allDescriptors: availableToolDescriptors
                   ) {
                    let added = automaticallyExpandReadOnlyTools(
                        userText: userText,
                        plan: plan,
                        allDescriptors: availableToolDescriptors,
                        current: &selectedTools
                    )
                    didAutomaticToolExpansion = true
                    if !added.isEmpty {
                        conversation.append(AIMessage(role: .assistant, content: answer))
                        conversation.append(AIMessage(
                            role: .user,
                            content: "Runtime 已为本轮补充只读工具 schema：\(added.map(\.name).joined(separator: ", "))。请基于完整工具目录判断是否调用它们；若已有足够证据可直接回答。"
                        ))
                        continue
                    }
                }
                if answer.isEmpty {
                    await emit(AgentChatMessage(role: .assistant, messages: [.error("AI Provider 返回了空回答。")]))
                } else {
                    presentation.applySearchFallback()
                    var messages: [AgentMessage] = []
                    if let finalMessage = presentation.finalMessage() {
                        messages.append(finalMessage)
                    }
                    messages.append(.text(answer))
                    await emit(AgentChatMessage(role: .assistant, messages: messages))
                }
                return
            }

            if nativeMode, !nativeCalls.isEmpty {
                conversation.append(AIMessage(role: .assistant, content: streamedText, toolCalls: nativeCalls))
            } else {
                conversation.append(AIMessage(role: .assistant, content: streamedText))
            }

            let calls: [LoopToolCall]
            if nativeMode, !nativeCalls.isEmpty {
                calls = nativeCalls.map { native in
                    switch parseArguments(native.arguments) {
                    case let .success(args):
                        LoopToolCall(
                            origin: .providerNative,
                            id: native.id,
                            name: native.name,
                            arguments: args,
                            malformedArguments: false,
                            usesTextProtocol: false
                        )
                    case .malformed:
                        LoopToolCall(
                            origin: .providerNative,
                            id: native.id,
                            name: native.name,
                            arguments: [:],
                            malformedArguments: true,
                            usesTextProtocol: false
                        )
                    }
                }
            } else {
                calls = textActions.enumerated().map {
                    LoopToolCall(
                        origin: .textualAction,
                        id: "text-\($0.offset)",
                        name: $0.element.tool,
                        arguments: $0.element.args.mapValues(AIJSONValue.string),
                        malformedArguments: false,
                        usesTextProtocol: true
                    )
                }
            }

            var parallelResultsByID: [String: ToolResult] = [:]
            let parallelEligible = provider.capabilities.supportsParallelTools
                && calls.count > 1
                && calls.allSatisfy { call in
                    guard !call.malformedArguments,
                          Self.isModelToolCallAdmitted(call, admission: roundAdmission),
                          !Self.isSearchCapability(call.name),
                          let descriptor = Self.descriptor(for: call, in: availableToolDescriptors)
                    else { return false }
                    return descriptor.permission == .readOnly
                        && descriptor.parallelSafe
                        && !descriptor.requiresExplicitUserApproval
                }
            if parallelEligible {
                let executorContext = ToolExecutorContext(
                    bridge: bridge,
                    catalog: catalog,
                    serverID: context.serverID,
                    systemService: systemService,
                    externalMusicService: externalMusicService,
                    privacyPermissions: context.privacyPermissions,
                    allowsLyrics: context.allowsLyrics,
                    allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                    providerCapabilities: provider.capabilities,
                    webService: webService,
                    authorizationContext: effectiveAuthorization,
                    activeSkillID: nil,
                    executionAuthority: nil,
                    executionLease: executionLease,
                    resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                    recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                    customToolRegistry: context.customToolRegistry,
                    availableToolDescriptors: availableToolDescriptors,
                    capabilityEnvironment: capabilityEnvironment
                )
                let structuredCalls = calls.map { call in
                    call.usesTextProtocol
                        ? structuredToolCall(name: call.name, legacyArguments: call.stringArguments)
                        : ToolCall(name: call.name, arguments: call.arguments)
                }
                let parallelResults = await ToolRuntime.executeReadOnlyParallel(
                    structuredCalls,
                    context: executorContext,
                    providerAllowsParallel: true,
                    runID: runID
                )
                for (index, call) in calls.enumerated() {
                    parallelResultsByID[parallelResultKey(for: call, index: index)] = parallelResults[index]
                }
            }

            var resultMessages: [AIMessage] = []
            var successfulDirectReadResult: ToolResult?
            for (index, call) in calls.enumerated() {
                toolSteps += 1
                convergence.recordTotalCall()
                // tool_search 计数在调用层记录：缓存命中/幂等拦截也不漏计，
                // 防止同一 tool_search 反复出现却永不触发收敛。
                if call.name == "tool_search" {
                    convergence.recordToolSearch()
                }
                await progress(AgentProgress(toolSteps: toolSteps, currentStep: "执行 \(call.name)"))
                guard Self.isModelToolCallAdmitted(call, admission: roundAdmission) else {
                    resultMessages.append(toolResultMessage(
                        callID: call.id,
                        content: "（工具执行结果）\(call.name)：未执行 - 该工具尚未加载到本轮工具 schema。如确实需要此能力，请先使用 tool_search 发现并加载。",
                        native: nativeMode
                    ))
                    continue
                }
                guard let descriptor = Self.descriptor(for: call, in: availableToolDescriptors) else {
                    resultMessages.append(toolResultMessage(
                        callID: call.id,
                        content: "（工具执行结果）\(call.name)：失败 - 未知工具。请先使用 tool_search 发现可用的 canonical 工具。",
                        native: nativeMode
                    ))
                    continue
                }
                if call.malformedArguments {
                    convergence.recordMalformedCall()
                    if let stopReason = convergence.stopReason(under: convergencePolicy) {
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(stopReason.userMessage)]))
                        return
                    }
                    resultMessages.append(toolResultMessage(
                        callID: call.id,
                        content: "（工具执行结果）\(call.name)：失败 - 工具参数不是合法 JSON 对象。",
                        native: nativeMode
                    ))
                    continue
                }
                // malformed streak 只对“真正连续”的畸形调用生效。
                convergence.recordValidCall()
                let signature = confirmationSignature(name: call.name, args: call.stringArguments)
                if convergence.exhaustedSearchTools.contains(call.name) {
                    resultMessages.append(toolResultMessage(
                        callID: call.id,
                        content: "（工具执行结果）\(call.name)：本轮该搜索能力连续没有提供新证据，已停止继续搜索；请基于已有结果直接回答，并如实说明没有找到的部分。",
                        native: nativeMode
                    ))
                    continue
                }
                if descriptor.permission != .readOnly {
                    if indeterminateSideEffects.contains(signature) {
                        resultMessages.append(toolResultMessage(
                            callID: call.id,
                            content: "（工具执行结果）\(call.name)：已跳过 - 相同参数的上一次写操作结果未知，为避免重复副作用不会自动重试；请先查询真实状态。",
                            native: nativeMode
                        ))
                        continue
                    }
                    if completedSideEffects.contains(signature) {
                        resultMessages.append(toolResultMessage(
                            callID: call.id,
                            content: "（工具执行结果）\(call.name)：已跳过 - 相同参数已经成功执行，本轮不会自动重试。",
                            native: nativeMode
                        ))
                        continue
                    }
                } else if descriptor.cachePolicy == .task {
                    let count = (readRepeatCounts[signature] ?? 0) + 1
                    readRepeatCounts[signature] = count
                    if let cached = cachedReadResults[signature] {
                        let hint = count >= 3
                            ? "\n（提示）同一搜索已执行 \(count) 次且没有新结果，当前结果可以直接用于回答，或换一个搜索词继续。"
                            : ""
                        resultMessages.append(toolResultMessage(
                            callID: call.id,
                            content: cached + hint,
                            native: nativeMode
                        ))
                        continue
                    }
                }
                let executableCall = call.usesTextProtocol
                    ? structuredToolCall(name: call.name, legacyArguments: call.stringArguments)
                    : ToolCall(name: call.name, arguments: call.arguments)

                if descriptor.requiresExplicitUserApproval {
                    let pending = await Self.pendingConfirmation(
                        catalog: catalog,
                        descriptor: descriptor,
                        name: call.name,
                        diagnosticArgs: AgentSensitiveDataRedactor.arguments(call.arguments),
                        runID: runID,
                        sessionID: executionLease.sessionID,
                        toolCallID: call.id
                    )
                    await emit(AgentChatMessage(role: .assistant, messages: [.confirmation(pending)]))
                    guard await confirm(pending) else {
                        let text = "（工具执行结果）\(call.name)：失败 - 用户未批准该操作。"
                        resultMessages.append(toolResultMessage(callID: call.id, content: text, native: nativeMode))
                        continue
                    }
                }
                let authorizationForCall = effectiveAuthorization
                let effectiveToolTimeout = Self.effectiveToolTimeout(descriptor, requested: toolTimeout)
                let descriptorsForExecution = availableToolDescriptors
                let result: ToolResult
                do {
                    result = if let parallelResult = parallelResultsByID[parallelResultKey(for: call, index: index)] {
                        parallelResult
                    } else {
                        try await withTimeout(effectiveToolTimeout) {
                        await ToolRuntime.executeMeasured(
                            executableCall,
                            bridge: bridge,
                            catalog: catalog,
                            serverID: context.serverID,
                            systemService: systemService,
                            externalMusicService: externalMusicService,
                            privacyPermissions: context.privacyPermissions,
                            allowsLyrics: context.allowsLyrics,
                            allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                            providerCapabilities: provider.capabilities,
                            webService: webService,
                            authorizationContext: authorizationForCall,
                            executionLease: executionLease,
                            resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                            recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                            customToolRegistry: context.customToolRegistry,
                            availableToolDescriptors: descriptorsForExecution,
                            runID: runID,
                            callID: call.id
                        )
                        }
                    }
                } catch is CancellationError {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                    return
                } catch {
                    let timeoutFailure = error is AgentRunnerError
                        ? ToolRuntime.timeoutResult(call: executableCall, descriptor: descriptor)
                        : nil
                    let isTimeout = timeoutFailure != nil
                    let reason = timeoutFailure?.summary ?? errorText(error)
                    if descriptor.permission != .readOnly, isTimeout {
                        indeterminateSideEffects.insert(signature)
                    }
                    let text: String
                    if let timeoutFailure {
                        let code = timeoutFailure.failure?.code ?? "tool_timeout"
                        text = "（工具执行结果）\(call.name): 超时 - \(reason) [failure_code=\(code); indeterminate=\(timeoutFailure.hasIndeterminateSideEffect)]"
                    } else {
                        text = "（工具执行结果）\(call.name)：失败 - \(reason)"
                    }
                    let presentationText = timeoutFailure != nil
                        ? "工具 \(call.name) 执行超时，结果可能未知；为避免重复副作用不会自动重试。"
                        : "（工具执行结果）\(call.name)：失败 - \(reason)"
                    resultMessages.append(toolResultMessage(callID: call.id, content: text, native: nativeMode))
                    await emit(AgentChatMessage(role: .assistant, messages: [.text(presentationText)]))
                    continue
                }

                // Generic chat owns the UI-facing tool loop too. Preserve
                // structured web sources as a separate message instead of
                // flattening them into model-only text; the assistant view
                // can render title/domain/snippet/link without parsing prose.
                if case let .webSources(sources)? = result.payload, !sources.isEmpty {
                    await emit(AgentChatMessage(role: .assistant, messages: [.webSources(sources)]))
                }
                if result.success,
                   calls.count == 1,
                   call.name == directReadToolName {
                    successfulDirectReadResult = result
                }
                if let payload = result.payload {
                    let role = result.presentationRole == .none ? descriptor.defaultPresentationRole : result.presentationRole
                    switch (role, payload) {
                    case (.candidate, let .trackCards(cards)):
                        presentation.addCandidateTracks(cards)
                    case (.finalResult, let .trackCards(cards)):
                        presentation.setFinalTracks(cards)
                    case (.disambiguation, let .trackCards(cards)):
                        presentation.setDisambiguation(cards)
                    case (.candidate, let .albumCards(albums)):
                        presentation.addCandidateAlbums(albums)
                    case (.finalResult, let .albumCards(albums)):
                        presentation.setFinalAlbums(albums)
                    case (.candidate, let .playlistProposal(name, tracks)):
                        presentation.addCandidateTracks(tracks)
                        presentation.setFinalPlaylistProposal(name, tracks)
                    default:
                        break
                    }
                }

                var resultText = providerToolResultText(
                    callName: call.name,
                    descriptor: descriptor,
                    result: result,
                    context: context,
                    targetCount: AgentTaskWorkingSet.inferredTargetQueueCount(from: userText)
                )
                resultText = AIContentTrustBoundary.wrap(resultText, trustLevel: result.trustLevel)
                if call.name == "lyrics_get", !context.allowsLyrics {
                    resultText = "（工具执行结果）lyrics_get：成功 - 歌词已按隐私设置隐藏。"
                }
                resultText = ContextManager.truncateToolResult(resultText, limit: descriptor.maxResultCharacters)
                // 搜索诊断（generic chat 与 deterministic task 共用同一 tracker）：
                // 结果返回后判定是否产生新 evidence，按工具独立累计 streak；
                // 失败/空结果也视为“没有新证据”，但不会移除工具或终止循环。
                if Self.isSearchCapability(call.name) {
                    var foundNewEvidence = false
                    if result.success, let evidence = Self.searchEvidenceIDs(from: result.payload) {
                        let known = searchEvidenceByTool[call.name, default: []]
                        foundNewEvidence = !evidence.isSubset(of: known)
                        searchEvidenceByTool[call.name, default: []].formUnion(evidence)
                    }
                    let exhausted = convergence.recordSearchOutcome(
                        toolName: call.name,
                        foundNewEvidence: foundNewEvidence,
                        policy: convergencePolicy
                    )
                    if exhausted {
                        selectedTools.removeAll { $0.name == call.name }
                        resultText += "\n（搜索收敛）\(call.name) 已连续 \(convergencePolicy.maxSameToolNoNewEvidence) 次没有提供新证据，本轮不再暴露该搜索能力。请直接根据已有事实回答；若没有结果，请明确说明。"
                    }
                }
                if descriptor.permission == .readOnly, descriptor.cachePolicy == .task, result.success {
                    cachedReadResults[signature] = resultText
                } else if descriptor.permission != .readOnly, result.success {
                    completedSideEffects.insert(signature)
                } else if descriptor.permission != .readOnly, result.hasIndeterminateSideEffect {
                    indeterminateSideEffects.insert(signature)
                    await emit(AgentChatMessage(
                        role: .assistant,
                        messages: [.text("\(call.name) 的写操作结果未知；为避免重复副作用不会自动重试，请先查询真实状态。")]
                    ))
                }
                resultMessages.append(toolResultMessage(callID: call.id, content: resultText, native: nativeMode))

                if result.success, call.name == "tool_search" {
                    let stringArguments = call.stringArguments
                    let query = stringArguments["query"] ?? ""
                    let namespace = stringArguments["namespace"]
                    let limit = min(max(Int(stringArguments["limit"] ?? "8") ?? 8, 1), 50)
                    _ = Self.expandToolsFromSearch(
                        query: query,
                        namespace: namespace,
                        limit: limit,
                        allDescriptors: availableToolDescriptors,
                        current: &selectedTools,
                        allowedOperations: effectiveAuthorization.allowedOperations
                    )
                    if let stopReason = convergence.stopReason(under: convergencePolicy) {
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(stopReason.userMessage)]))
                        return
                    }
                }
                if result.success, descriptor.permission != .readOnly {
                    await log(AgentActionRecord(toolName: call.name, permission: descriptor.permission, summary: result.summary))
                }
            }

            // A high-confidence local read is already a deterministic answer.
            // Do not send the same result back through another open planning
            // round: that is how simple requests such as “列出我的歌单” used
            // to become tool_search → repeated lookup loops.  We still emit
            // the structured payload (cards when present) and a compact
            // summary, so this path does not trade away the normal UI result.
            if let result = successfulDirectReadResult {
                var directMessages: [AgentMessage] = []
                if let payload = result.payload {
                    switch payload {
                    case .text:
                        directMessages.append(payload)
                    default:
                        directMessages.append(payload)
                        directMessages.append(.text(result.summary))
                    }
                } else if !result.summary.isEmpty {
                    directMessages.append(.text(result.summary))
                }
                if !directMessages.isEmpty {
                    await emit(AgentChatMessage(role: .assistant, messages: directMessages))
                    return
                }
            }

            conversation.append(contentsOf: resultMessages)
            // The view has one current activity state through `progress`; do
            // not append a permanent chat bubble after every tool round.
            // Give provider-side test doubles and URLSession-backed streams a
            // scheduling boundary before the next request is observed. This
            // is not a retry or a loop limit; it only preserves ordered
            // request bookkeeping for asynchronous stream implementations.
            await Task.yield()
            if nativeMode, !nativeCalls.isEmpty {
                toolChoice = provider.capabilities.supportsToolChoice ? .auto : nil
            }
        }
    }

    // MARK: - LLM loop

    /// 受控 Agent 主循环（独立实现，参考 OpenAI function calling 的标准语义）。
    ///
    /// 终止条件：
    /// - 正常结束：模型返回最终文本（无原生 tool_calls、无文本 ACTION 行）；
    /// - 用户取消 / 不可恢复错误（配置错误、API Key 无效、数据库损坏等）；
    /// - 单工具失败或超时 → 以结构化失败回灌模型，模型换工具/换参数继续，不终止整项任务。
    ///
    /// Tool Call / Tool Result 关联：
    /// - 原生模式（provider.supportsToolCalling）：每个 tool call 有稳定 `tool_call_id`，
    ///   每条结果以 `role: .tool` + `tool_call_id` 回灌，与 assistant 的 `tool_calls` 严格配对；
    /// - 文本兜底模式：无原生支持时沿用 ACTION 文本协议，结果以 `role: .user` 回灌，
    ///   并为每个动作合成 `text-N` 序号便于诊断与日志关联。
    ///
    /// 工具失败不终止循环：错误以结构化文本（含失败原因）回灌模型，让模型决定
    /// 换一种方式继续；只有配置类严重错误才结束。
    private static func runWithLLM(
        userText: String,
        provider: any AIProvider,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: Context,
        history: [AgentChatMessage],
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)?,
        webService: (any AgentWebService)?,
        plan: AgentRequestPlan,
        availableToolDescriptors initialAvailableToolDescriptors: [ToolDescriptor],
        initialCustomToolRevision: UInt64,
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        initialTaskState: AgentTaskState?,
        sideEffectAuthorization: SideEffectAuthorizationContext,
        enabledFixedSkills: Bool,
        runID: UUID,
        executionLease: ToolExecutionLease,
        toolTimeout: TimeInterval,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void,
        progress: @escaping @Sendable (AgentProgress) async -> Void,
        state: @escaping @Sendable (AgentTaskState) async -> Void
    ) async {
        // 动态工具加载：只向模型暴露与本次意图相关的工具，降低 schema 对上下文的占用。
        // 每轮使用同一份共享 AgentRequestPlan（不允许 ToolSelector 重新分析用户文本），
        // 任务中途的新工具需求通过 tool_search（相关性过滤）与已执行工具补入。
        var availableToolDescriptors = initialAvailableToolDescriptors
        // The initial selector already consumed this exact snapshot. A reload
        // is only meaningful after a later registry revision changes.
        var loadedCustomToolRevision: UInt64? = initialCustomToolRevision
        let requestTimeout = roundTimeout
        let effectiveAuthorization = sideEffectAuthorization
        let requiredCompletionOperations = plan.requiredCompletionOperations
        let nativeMode = provider.supportsToolCalling
            && provider.capabilities.toolMode != .none
            && provider.capabilities.toolMode != .textualToolProtocol
        if provider.capabilities.toolMode == .none {
            await emit(AgentChatMessage(role: .assistant, messages: [.error(
                "当前接口未配置 Auralis 原生工具调用协议；请在设置中选择兼容的 Chat Completions、Responses 或 Messages 协议后再执行播放、队列、歌单或索引操作。"
            )]))
            return
        }
        var taskState = initialTaskState ?? AgentTaskState(intent: intent, goal: userText)
        // 结构化诊断：只记行为事实，不含凭据/敏感数据。
        var diagnostics = AgentRunDiagnostics(runID: runID)
        diagnostics.intent = intent.rawValue
        diagnostics.semanticDomain = plan.semantics.domain.rawValue
        diagnostics.semanticOperation = plan.semantics.operation.rawValue
        diagnostics.requestedOperations = plan.semantics.requestedOperations.map(\.rawValue).sorted()
        diagnostics.allowedOperations = effectiveAuthorization.allowedOperations.map(\.rawValue).sorted()
        diagnostics.completionPredicate = policy.completion.predicateName
        // Stateful Skill 激活复用同一份共享 semantics，不再独立分析。
        let skillSemantics = plan.semantics
        let inferredTargetCount = AgentTaskWorkingSet.inferredTargetQueueCount(from: userText)
        var activeSkill: (any AgentStatefulSkillRuntime)?
        if enabledFixedSkills {
            activeSkill = BuiltInStatefulSkillRegistry.activate(
                semantics: skillSemantics,
                userText: userText,
                initialTaskState: initialTaskState,
                allowedOperations: effectiveAuthorization.allowedOperations,
                inferredTargetCount: inferredTargetCount
            )
            // Skill activation is semantic routing, not a second operation
            // whitelist. Its concrete local mutations still pass through the
            // normal argument validation, lease and descriptor-owned
            // confirmation policy paths when executed.
        }
        let activeSkillID = activeSkill?.skillID
        activeSkill?.configure(maxOutputTokens: provider.capabilities.maxOutputTokens)
        activeSkill?.configure(authorization: effectiveAuthorization)
        Self.mergeSkillFacts(activeSkill, into: &taskState)
        var selectedTools = ToolSelector.select(
            plan: plan,
            all: availableToolDescriptors,
            activeSkillID: activeSkillID
        )
        // Skill 激活后：模型面只保留只读工具（read/search/recommend/select +
        // result_present_tracks + tool_search）。所有 mutation——包括该流程涉及的
        // 其它同族工具（playback_play_artist/album/playlist/random 等）——都从模型
        // schema 隐藏，由 Skill 内部 forced call 固定调用 ToolRuntime。
        if let activeSkill {
            selectedTools.removeAll { $0.permission != .readOnly }
            diagnostics.activeSkillID = activeSkill.skillID
        }
        for tool in selectedTools { diagnostics.recordSelectedTool(tool.name) }
        var toolChoice: AIToolChoice? = nativeMode && provider.capabilities.supportsToolChoice ? .auto : nil
        var toolDefinitions = nativeMode
            ? ToolSelector.toolDefinitions(
                from: Self.localModelTools(selectedTools, capabilities: provider.capabilities),
                strict: provider.capabilities.supportsStrictSchema,
                activeSkillID: activeSkillID
            )
            : []
        let privacy = context.privacyPermissions

        // 统一解析真正的 Provider 预算：Agent 不再自带第二套 256K/16K 硬限制，
        // 输入/输出直接跟随 Provider capabilities（即用户在设置页填写的模型能力），
        // 后续 request.maxTokens 与上下文裁剪都基于这两个已解析值。
        let resolvedInputBudget = policy.budget.resolvedInputTokens(
            capabilities: provider.capabilities
        )

        let resolvedOutputBudget = policy.budget.resolvedOutputTokens(
            capabilities: provider.capabilities
        )
        activeSkill?.configure(maxOutputTokens: resolvedOutputBudget)
        Self.mergeSkillFacts(activeSkill, into: &taskState)

        // run-scoped Capability 环境快照：System Prompt 与 capabilities_get 使用
        // 同一来源的真实状态（activeServer 真实查询，不再硬编码 false）。
        let capabilityEnvironment = Self.capabilityEnvironment(
            provider: provider,
            catalog: catalog,
            systemService: systemService,
            webService: webService,
            activeServer: (await bridge.getActiveServer()) != nil
        )
        var conversation = AgentContextBuilder.build(
            systemPrompt: Self.systemPrompt(
                context: context,
                tools: selectedTools,
                nativeToolCalling: nativeMode,
                goal: taskState.goal,
                workflowInstruction: activeSkill?.instructions,
                environment: capabilityEnvironment,
                relevantCapabilityIDs: Self.relevantCapabilityIDs(for: intent, semantics: plan.semantics),
                awarenessTools: availableToolDescriptors,
                activeSkillID: activeSkillID,
                authorizedOperations: effectiveAuthorization.allowedOperations
            ),
            task: taskState,
            facts: [],
            history: Self.convertHistory(history, currentUserText: userText, permissions: context.privacyPermissions),
            permissions: privacy,
            capabilities: provider.capabilities,
            inputBudget: resolvedInputBudget,
            reservedOutputTokens: resolvedOutputBudget
                + ContextManager.estimatedTokens(toolDefinitions)
        )
        conversation.append(AIMessage(role: .user, content: userText))
        if initialTaskState != nil, activeSkill != nil {
            conversation.append(AIMessage(
                role: .user,
                content: "系统恢复要求：这是一个已保存的 Stateful Skill。请先执行 Skill Runtime 当前步骤，从真实状态继续；不要重复已完成动作。"
            ))
        }

        var toolStepCount = 0
        var completionRepairAttempts = 0
        // A successful mutation may already satisfy the current request. Keep
        // a marker while processing the current provider turn so a legitimate
        // second mutation with a different requested operation can still run;
        // a repeated successful call can be finalized without asking the model
        // to plan an unnecessary follow-up mutation.
        var pendingMutationFinalization = false
        var duplicateMutationFinalization = false
        // 展示状态：候选池（内部，绝不上屏）与最终展示彻底分离。
        // 最终展示只来自 result_present_tracks / 真实副作用 / 搜索收尾合并。
        var presentation = AgentPresentationState()
        // 任务工作集：任务级结果缓存、重复调用保护、候选/队列统计、诊断轨迹。
        let mutationTargetCount: Int? = {
            guard activeSkill != nil || plan.semantics.requiresSideEffect else { return nil }
            return inferredTargetCount
        }()
        var ws = AgentTaskWorkingSet(targetQueueCount: mutationTargetCount)
        // 用户拒绝后同一轮模型可能再次发出完全相同的调用；记住拒绝签名，
        // 后续只回灌“仍未执行”，避免反复弹窗或在无界面入口形成循环。
        var deniedConfirmationSignatures = Set<String>()
        // A transient Provider failure may be recovered at the current skill
        // checkpoint. This is protocol-preserving recovery, not a tool-call or
        // model-capability limit.
        var didRecoverSkillProviderFailure = false
        // A fixed skill may repair a malformed classification response a
        // couple of times, but it must never turn a non-compliant provider
        // into an unbounded correction loop.
        var skillOutputRepairAttempts = 0
        // 行为计数供 diagnostics；普通 Agent 不因 convergence 阈值 fail-fast。
        // Recommendation Index 仍走专用 Runtime，legacy AgentRunner 兼容面不变。
        var convergence = AgentConvergenceTracker()
        // Mutation / deterministic 任务的模型正文是 provisional：完成条件满足前
        // 不实时上屏，避免“已经替换好了”在真实副作用成功前误导用户。
        let buffersProvisionalText = Self.policyRequiresToolExecution(policy)

        while true {
            let customSnapshot = await context.customToolRegistry.modelSnapshot()
            if loadedCustomToolRevision != customSnapshot.revision {
                availableToolDescriptors = Self.descriptorsWithCustomTools(customSnapshot.descriptors)
                loadedCustomToolRevision = customSnapshot.revision
                selectedTools.removeAll { $0.customToolID != nil }
                for descriptor in customSnapshot.descriptors where Self.shouldExposeDescriptorForPlan(
                    descriptor,
                    semantics: plan.semantics,
                    activeSkillID: activeSkillID
                ) {
                    guard !selectedTools.contains(where: { $0.name == descriptor.name }) else { continue }
                    selectedTools.append(descriptor)
                }
                conversation[0] = AIMessage(
                    role: .system,
                    content: Self.systemPrompt(
                        context: context,
                        tools: selectedTools,
                        nativeToolCalling: nativeMode,
                        goal: taskState.goal,
                        workflowInstruction: activeSkill?.instructions,
                        environment: capabilityEnvironment,
                        relevantCapabilityIDs: Self.relevantCapabilityIDs(for: intent, semantics: plan.semantics),
                        awarenessTools: availableToolDescriptors,
                        activeSkillID: activeSkillID,
                        authorizedOperations: effectiveAuthorization.allowedOperations
                    )
                )
            }
            if Task.isCancelled {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                return
            }
            if let violation = taskState.budgetViolation(policy: policy) {
                await emit(AgentChatMessage(role: .assistant, messages: [.error(violation.localizedDescription)]))
                return
            }
            convergence.recordModelRound()
            // Skill 阶段诊断：从 Skill facts 同步（不含凭据/敏感数据）。
            if let activeSkill {
                diagnostics.skillPhase = activeSkill.facts["queue.skill.phase"]
                    ?? activeSkill.facts["playlist.skill.phase"]
                diagnostics.skillTransitionCount = Int(
                    activeSkill.facts["queue.skill.transitions"]
                        ?? activeSkill.facts["playlist.skill.transitions"]
                        ?? ""
                ) ?? 0
                if activeSkill.isCompleted {
                    diagnostics.skillCompletionResult = "completed"
                }
            }
            taskState.diagnostics = diagnostics
            if let stopReason = convergence.stopReason(under: policy.convergence, tolerateSearchExhaustion: plan.semantics.isMusicAppreciation) {
                let message = stopReason.userMessage
                taskState.status = .insufficient
                taskState.errorState = message
                taskState.updatedAt = .now
                diagnostics.convergenceStopReason = stopReason.rawValue
                diagnostics.noProgressCount = convergence.noProgressStreak
                taskState.diagnostics = diagnostics
                await state(taskState)
                await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                return
            }
            if activeSkill?.isCompleted == true {
                Self.mergeSkillFacts(activeSkill, into: &taskState)
                Self.markSkillCompleted(state: &taskState)
                await state(taskState)
                await emit(AgentChatMessage(
                    role: .assistant,
                    messages: [.text(Self.skillCompletionMessage(activeSkill))]
                ))
                return
            }
            // 动态工具扩展：每轮基于同一份共享 plan 重新展开工具集（只增不减），
            // 保证任务中途的新工具需求可达；不允许把模型自己的输出文本重新喂给
            // ToolSelector 做语义分析（避免 semantic drift / split-brain）。
            let expanded = ToolSelector.select(
                plan: plan,
                all: availableToolDescriptors,
                activeSkillID: activeSkillID
            )
            var merged = selectedTools
            var haveNames = Set(merged.map(\.name))
            for tool in expanded where !haveNames.contains(tool.name) {
                merged.append(tool)
                haveNames.insert(tool.name)
            }
            // Skill 激活时：模型 schema 只保留只读工具（read/search/select +
            // result_present_tracks + tool_search），所有 mutation 由 Skill 内部
            // 固定调用 ToolRuntime，绝不把同族 mutation 作为 alternatives 暴露。
            if activeSkill != nil {
                merged.removeAll { $0.permission != .readOnly }
            }
            // TaskRequiredTools：本轮已实际执行过的工具永远保留在 schema 中。
            if !ws.perToolCounts.isEmpty {
                let byName = Dictionary(uniqueKeysWithValues: availableToolDescriptors
                    .filter { $0.isVisible(toSkillID: activeSkillID) }
                    .map { ($0.name, $0) })
                for name in ws.perToolCounts.keys where !haveNames.contains(name) {
                    if let tool = byName[name], Self.shouldExposeDescriptorForPlan(
                        tool,
                        semantics: plan.semantics,
                        activeSkillID: activeSkillID
                    ) {
                        merged.append(tool)
                        haveNames.insert(tool.name)
                    }
                }
            }
            if merged.count != selectedTools.count {
                selectedTools = merged
                if nativeMode {
                    toolDefinitions = ToolSelector.toolDefinitions(
                        from: Self.localModelTools(selectedTools, capabilities: provider.capabilities),
                        strict: provider.capabilities.supportsStrictSchema,
                        activeSkillID: activeSkillID
                    )
                }
            }

            let hostedTools = nativeMode
                ? Self.hostedTools(for: provider.capabilities, availableTools: selectedTools)
                : []
            // Recompute after hosted routing: a local web_search function is
            // not duplicated in the Provider schema when the Provider has a
            // real native hosted web tool.
            if nativeMode {
                toolDefinitions = ToolSelector.toolDefinitions(
                    from: Self.localModelTools(selectedTools, capabilities: provider.capabilities),
                    strict: provider.capabilities.supportsStrictSchema,
                    activeSkillID: activeSkillID
                )
            }
            let roundAdmission = RoundToolAdmission(selectedTools)

            // A stateful skill owns mandatory control-flow edges. The model is
            // only asked for a turn when the skill explicitly says so.
            let forcedSkillCall: LoopToolCall? = {
                guard let activeSkill else { return nil }
                guard case let .executeTool(name, arguments) = activeSkill.nextStep() else { return nil }
                return LoopToolCall(
                    origin: .skillForced,
                    id: "skill-\(toolStepCount + 1)-\(name)",
                    name: name,
                    arguments: arguments,
                    malformedArguments: false,
                    usesTextProtocol: !nativeMode
                )
            }()
            let didUseForcedSkillCall = forcedSkillCall != nil

            let outcome: StreamOutcome
            if didUseForcedSkillCall {
                var forcedOutcome = StreamOutcome()
                if nativeMode, let forcedSkillCall {
                    forcedOutcome.toolCalls = [AIToolCall(
                        id: forcedSkillCall.id ?? "skill-\(toolStepCount + 1)",
                        name: forcedSkillCall.name,
                        arguments: .object(forcedSkillCall.arguments)
                    )]
                }
                outcome = forcedOutcome
            } else {
                // 上下文裁剪：输入预算同时扣除真实工具 Schema 成本；不能再只预留固定
                // 1024 token，否则 16K/32K 模型会在正文尚未开始前就超过窗口。
                let reservedOutput = resolvedOutputBudget
                let schemaTokens = nativeMode ? ContextManager.estimatedTokens(toolDefinitions) : 0
                let contextBudget = ContextManager.inputBudget(
                    capabilities: provider.capabilities,
                    requestedInputBudget: resolvedInputBudget,
                    reservedOutputTokens: reservedOutput + schemaTokens
                )
                guard ContextManager.canFitCurrentUser(conversation, userText: userText, maxTokens: contextBudget) else {
                    let message = "当前模型上下文过小，连系统协议与本次问题都无法同时发送。请切换到上下文更大的模型，或降低输出 Token / 关闭原生工具后重试。"
                    taskState.errors.append(message)
                    taskState.status = .failed
                    taskState.updatedAt = .now
                    await state(taskState)
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                    return
                }
                conversation = ContextManager.trimByTokens(
                    conversation,
                    maxTokens: contextBudget,
                    preservingUserText: userText
                )

                // 单次回复上限真正来自用户配置（request.maxTokens 直接使用该值）。
                // 多轮累计 token 仅用于诊断，不会被误当成单次上下文上限。

                var requestConversation = conversation
                if let activeSkill,
                   case let .modelOutput(contract) = activeSkill.nextStep() {
                    requestConversation.append(AIMessage(
                        role: .user,
                        content: "Skill Runtime 分类输出契约：\(contract.instruction)"
                    ))
                }
                let request = AICompletionRequest(
                    model: model,
                    transcript: AITranscript(messages: requestConversation),
                    temperature: 0.3,
                    maxTokens: reservedOutput,
                    tools: nativeMode ? toolDefinitions : nil,
                    toolChoice: nativeMode ? toolChoice : nil,
                    hostedTools: hostedTools.isEmpty ? nil : hostedTools,
                    reasoning: context.reasoning
                )
                do {
                    // 确定性 mutation 任务：模型正文是 provisional，工具成功前不
                    // 实时上屏（避免“已经替换好了”等未经核实的成功声明误导用户）。
                    // 完成时最终 `.text(reply)` 才会提交；失败/继续时这些文字被丢弃。
                    outcome = try await streamWithFallback(
                        provider: provider,
                        request: request,
                        timeout: requestTimeout,
                        onAnswerDelta: { delta in
                            if !buffersProvisionalText {
                                await Self.emitStreamingDelta(delta, emit: emit)
                            }
                        },
                        onReasoningDelta: { delta in
                            await Self.emitStreamingReasoningDelta(delta, emit: emit)
                        }
                    )
                } catch is CancellationError {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                    return
                } catch {
                    if let activeSkill,
                       !didRecoverSkillProviderFailure,
                       let recovery = activeSkill.handleProviderFailure(error) {
                        didRecoverSkillProviderFailure = true
                        taskState.errors.append(recovery.message)
                        taskState.pendingActions = [recovery.message]
                        taskState.status = .waitingForTool
                        taskState.updatedAt = .now
                        Self.mergeSkillFacts(activeSkill, into: &taskState)
                        await state(taskState)
                        await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: recovery.message)]))
                        conversation = Self.compactSkillTranscript(
                            conversation,
                            ownedToolNames: activeSkill.ownedToolNames,
                            droppingLatestOwnedUnit: recovery.dropCurrentBatch
                        )
                        conversation.append(AIMessage(role: .user, content: "系统恢复：\(recovery.message)"))
                        continue
                    }
                    // Provider 协议在请求前已经确定。网络瞬时错误由
                    // streamWithFallback/completeWithRetry 按同一协议重试；失败后
                    // 不能在同一任务里改写成 ACTION 或本地音乐规则。
                    let prefix = nativeMode ? "原生工具协议请求失败" : "AI 服务暂时不可用"
                    await emit(AgentChatMessage(role: .assistant, messages: [.error("\(prefix)：\(Self.errorText(error))；未切换到另一种工具协议，也未将请求改写为本地音乐搜索。")]))
                    return
                }
            }

            didRecoverSkillProviderFailure = false

            if !didUseForcedSkillCall {
                await progress(AgentProgress(
                    toolSteps: toolStepCount,
                    currentStep: "正在理解请求",
                    inputTokens: outcome.inputTokens,
                    outputTokens: outcome.outputTokens
                ))
                taskState.progress.modelRounds += 1
                taskState.progress.inputTokens += outcome.inputTokens ?? 0
                taskState.progress.outputTokens += outcome.outputTokens ?? 0
                taskState.status = .waitingForModel
                taskState.updatedAt = .now
                await state(taskState)
            } else {
                taskState.status = .waitingForTool
                taskState.updatedAt = .now
                await state(taskState)
            }

            if !outcome.webCitations.isEmpty {
                let sources = Self.webSources(from: outcome.webCitations)
                if !sources.isEmpty {
                    await Self.registerWebSources(sources, webService: webService, runID: runID)
                    await emit(AgentChatMessage(role: .assistant, messages: [.webSources(sources)]))
                }
            }

            // 解析本轮工具调用：原生请求只接受 provider-native tool_calls；
            // ACTION 仅属于请求开始时已经确定的文本协议。
            let streamedText = outcome.answerText
            let nativeCalls = nativeMode ? outcome.toolCalls : []
            let textActions = !nativeMode && nativeCalls.isEmpty ? parseActions(from: streamedText) : []

            // A stateful skill owns its state transitions.  At a model-output
            // step the provider contributes only typed data; it never has to
            // honor a named tool_choice for the internal write transition.
            // Auxiliary public tools remain available, but private skill tools
            // are not part of the provider schema and therefore cannot be
            // selected or replayed by the model.
            var generatedSkillCall: LoopToolCall?
            if let activeSkill,
               case let .modelOutput(contract) = activeSkill.nextStep(),
               !didUseForcedSkillCall {
                let returnedToolNames = nativeMode ? nativeCalls.map(\.name) : textActions.map(\.tool)
                let attemptedInternalTool = returnedToolNames.contains { activeSkill.privateToolNames.contains($0) }
                if attemptedInternalTool || returnedToolNames.isEmpty {
                    let output: AgentSkillModelOutput
                    if attemptedInternalTool {
                        output = .retry(AgentSkillRecovery(
                            message: "模型尝试调用 Runtime 内部步骤；本次未执行写入。请改为返回符合契约的 JSON 分类对象。",
                            dropCurrentBatch: false,
                            compactTranscript: false
                        ))
                    } else {
                        output = activeSkill.consumeModelOutput(streamedText, contract: contract)
                    }
                    switch output {
                case let .executeTool(name, arguments):
                    skillOutputRepairAttempts = 0
                    generatedSkillCall = LoopToolCall(
                        origin: .skillGenerated,
                        id: "skill-output-\(toolStepCount + 1)-\(name)",
                        name: name,
                        arguments: arguments,
                        malformedArguments: false,
                        usesTextProtocol: !nativeMode
                    )
                case let .retry(recovery):
                    skillOutputRepairAttempts += 1
                    if skillOutputRepairAttempts > 2 {
                        let message = "推荐索引分类输出连续无效，未执行未确认的写入。请检查当前 AI Provider 是否能稳定返回 JSON 后再继续。"
                        taskState.errors.append(message)
                        taskState.errorState = message
                        taskState.status = .failed
                        taskState.updatedAt = .now
                        Self.mergeSkillFacts(activeSkill, into: &taskState)
                        await state(taskState)
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                        return
                    }
                    taskState.errors.append(recovery.message)
                    taskState.pendingActions = [recovery.message]
                    taskState.status = .waitingForTool
                    taskState.updatedAt = .now
                    Self.mergeSkillFacts(activeSkill, into: &taskState)
                    await state(taskState)
                    await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: recovery.message)]))
                    conversation = Self.compactSkillTranscript(
                        conversation,
                        ownedToolNames: activeSkill.ownedToolNames,
                        droppingLatestOwnedUnit: recovery.dropCurrentBatch
                    )
                    conversation.append(AIMessage(
                        role: .user,
                        content: "系统恢复：\(recovery.message) \(contract.instruction)"
                    ))
                    continue
                }
                }
            }
            let skillInternalCall = forcedSkillCall ?? generatedSkillCall

            let completionFactsSatisfied: Bool
            if let activeSkill {
                completionFactsSatisfied = activeSkill.isCompleted
            } else {
                completionFactsSatisfied = AgentCompletionEvaluator.factsSatisfied(
                    state: taskState,
                    policy: policy,
                    requiredCompletionOperations: requiredCompletionOperations
                )
            }

            // 真实工具已经完成时，先结算事实，再处理模型是否返回最终文字。
            // 许多中转在 tool result 后只返回 reasoning 或空 content；这不应覆盖成功状态。
            if nativeCalls.isEmpty,
               textActions.isEmpty,
               skillInternalCall == nil,
               completionFactsSatisfied {
                let reply = Self.formatAssistantReply(streamedText.trimmingCharacters(in: .whitespacesAndNewlines))
                if activeSkill != nil {
                    Self.mergeSkillFacts(activeSkill, into: &taskState)
                    Self.markSkillCompleted(state: &taskState)
                } else {
                    _ = AgentCompletionEvaluator.markFactsSatisfied(
                        state: &taskState,
                        policy: policy,
                        requiredCompletionOperations: requiredCompletionOperations
                    )
                }
                diagnostics.completionResult = taskState.completed ? "satisfied" : "pending"
                diagnostics.noProgressCount = convergence.noProgressStreak
                taskState.diagnostics = diagnostics
                await state(taskState)
                if intent == .librarySearch || intent == .libraryManagement {
                    presentation.applySearchFallback()
                }
                presentation.applyAlbumFallbackIfNeeded()
                if let finalMessage = presentation.finalMessage() {
                    await emit(AgentChatMessage(role: .assistant, messages: [finalMessage]))
                }
                let deterministicSummary = activeSkill != nil
                    ? Self.skillCompletionMessage(activeSkill)
                    : Self.deterministicCompletionSummary(policy: policy, presentation: presentation)
                // Preserve a non-empty provider answer verbatim. Compatibility
                // providers are allowed to choose their own short completion
                // wording (for example “已处理完成。”); the deterministic
                // summary is only a fallback for empty/typeless responses.
                let finalText = reply.isEmpty ? deterministicSummary : reply
                if !finalText.isEmpty {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text(finalText)]))
                }
                return
            }

            if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               nativeCalls.isEmpty,
               textActions.isEmpty,
               skillInternalCall == nil {
                let failure = nativeMode
                    ? "原生工具协议返回了空内容，未切换到 ACTION 或本地音乐搜索；请检查 Provider 的原生工具兼容性后重试。"
                    : "模型在 ACTION 协议下未返回可用内容，任务未完成。"
                taskState.status = .insufficient
                taskState.errorState = failure
                taskState.updatedAt = .now
                await state(taskState)
                await emit(AgentChatMessage(role: .assistant, messages: [.error(failure)]))
                return
            }
            if nativeCalls.isEmpty && textActions.isEmpty && skillInternalCall == nil {
                // 模型已输出最终回答 → 正常终止本轮任务。
                // 流式收尾：Coordinator 会把 in-flight 流式气泡原地定型为该最终文本，
                // 不会出现「流式半成品 + 成品」两条重复气泡。
                let reply = Self.formatAssistantReply(streamedText.trimmingCharacters(in: .whitespacesAndNewlines))
                let completionDecision: AgentModelAnswerDecision
                if let activeSkill {
                    completionDecision = activeSkill.completionDecision(
                        repairAttempts: completionRepairAttempts
                    )
                } else {
                    completionDecision = AgentCompletionEvaluator.evaluateModelAnswer(
                        reply,
                        state: &taskState,
                        policy: policy,
                        repairAttempts: completionRepairAttempts,
                        requiredCompletionOperations: requiredCompletionOperations
                    )
                }
                switch completionDecision {
                case .accept:
                    diagnostics.completionResult = taskState.completed ? "satisfied" : "accepted"
                    diagnostics.noProgressCount = convergence.noProgressStreak
                    taskState.diagnostics = diagnostics
                    await state(taskState)
                    // 查看类任务的收尾合并（搜索 / 资料库浏览如“我的收藏”）：没有明确 final
                    // 时把候选合成一组；推荐/播放/建歌单/改队列等任务必须走显式 final。
                    if intent == .librarySearch || intent == .libraryManagement {
                        presentation.applySearchFallback()
                    }
                    presentation.applyAlbumFallbackIfNeeded()
                    if let finalMessage = presentation.finalMessage() {
                        await emit(AgentChatMessage(role: .assistant, messages: [finalMessage]))
                    }
                    await emit(AgentChatMessage(role: .assistant, messages: [.text(reply)]))
                    return
                case let .continueTask(instruction):
                    completionRepairAttempts += 1
                    if nativeMode,
                       Self.policyRequiresToolExecution(policy),
                       toolChoice == .auto {
                        // 第一次 prose 说明没有执行动作：下一轮仍使用同一 native
                        // 协议要求模型产生工具调用。
                        toolChoice = .required
                    }
                    taskState.pendingActions = [instruction]
                    taskState.status = .waitingForTool
                    taskState.updatedAt = .now
                    await state(taskState)
                    conversation.append(AIMessage(role: .assistant, content: reply))
                    conversation.append(AIMessage(role: .user, content: "系统完成条件校验：\(instruction)"))
                    continue
                case let .fail(message):
                    taskState.status = .insufficient
                    taskState.errorState = message
                    taskState.updatedAt = .now
                    await state(taskState)
                    // 失败不倾倒候选池，只显示失败原因。
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                    return
                }
            }

            // 有工具调用：先把 assistant 消息（含 tool_calls）写入对话，再逐条执行回灌。
            if let skillInternalCall, nativeMode {
                conversation.append(AIMessage(
                    role: .assistant,
                    content: didUseForcedSkillCall ? "" : "Stateful Skill 分类数据已验证。",
                    toolCalls: [AIToolCall(
                        id: skillInternalCall.id ?? "skill-\(toolStepCount + 1)",
                        name: skillInternalCall.name,
                        arguments: .object(skillInternalCall.arguments)
                    )]
                ))
            } else if let skillInternalCall {
                conversation.append(AIMessage(role: .assistant, content: "Stateful Skill 步骤：\(skillInternalCall.name)"))
            } else if nativeMode, !nativeCalls.isEmpty {
                conversation.append(AIMessage(role: .assistant, content: streamedText, toolCalls: nativeCalls))
            } else {
                conversation.append(AIMessage(role: .assistant, content: streamedText))
            }

            // 统一调用视图：原生调用带稳定 id，文本 ACTION 合成 text-N。
            let calls: [LoopToolCall]
            if let skillInternalCall {
                calls = [skillInternalCall]
            } else if nativeMode, !nativeCalls.isEmpty {
                calls = nativeCalls.map { native in
                    switch Self.parseArguments(native.arguments) {
                    case let .success(args):
                        LoopToolCall(
                            origin: .providerNative,
                            id: native.id,
                            name: native.name,
                            arguments: args,
                            malformedArguments: false,
                            usesTextProtocol: false
                        )
                    case .malformed:
                        LoopToolCall(
                            origin: .providerNative,
                            id: native.id,
                            name: native.name,
                            arguments: [:],
                            malformedArguments: true,
                            usesTextProtocol: false
                        )
                    }
                }
            } else {
                calls = textActions.enumerated().map {
                    LoopToolCall(
                        origin: .textualAction,
                        id: "text-\($0.offset)",
                        name: $0.element.tool,
                        arguments: $0.element.args.mapValues(AIJSONValue.string),
                        malformedArguments: false,
                        usesTextProtocol: true
                    )
                }
            }

            // Never echo an incomplete native skill call back to the Provider.
            // Some compatible gateways reject that follow-up transcript with
            // a generic HTTP 500, hiding the real truncation cause. No tool in
            // this round is executed; the active skill decides how to recover.
            if let malformed = calls.first(where: { $0.malformedArguments }),
               let activeSkill,
               let recovery = activeSkill.handleMalformedCall(name: malformed.name) {
                if let last = conversation.last,
                   last.role == .assistant,
                   last.toolCalls?.isEmpty == false {
                    conversation.removeLast()
                }
                taskState.progress.toolCalls += calls.count
                taskState.errors.append(recovery.message)
                taskState.pendingActions = [recovery.message]
                taskState.status = .waitingForTool
                taskState.updatedAt = .now
                Self.mergeSkillFacts(activeSkill, into: &taskState)
                await state(taskState)
                await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: recovery.message)]))
                conversation = Self.compactSkillTranscript(
                    conversation,
                    ownedToolNames: activeSkill.ownedToolNames,
                    droppingLatestOwnedUnit: recovery.dropCurrentBatch
                )
                conversation.append(AIMessage(role: .user, content: "系统恢复：\(recovery.message)"))
                continue
            }

            var toolMessages: [AIMessage] = []
            var shouldCompactSkillTranscript = false
            var fixedSkillFailure: String?
            // 本轮统计（用于合并工具轨迹展示）。
            var roundSearchCalls = 0
            var roundToolNames: Set<String> = []

            for rawCall in calls {
                var call = rawCall
                var skillOwnedToolsNotLoaded: [String] = []
                if let activeSkill, activeSkill.ownedToolNames.contains(call.name) {
                    call.arguments = activeSkill.prepareToolCall(name: call.name, arguments: call.arguments)
                    Self.mergeSkillFacts(activeSkill, into: &taskState)
                }
                toolStepCount += 1
                taskState.progress.toolCalls += 1
                let stringArguments = call.stringArguments
                taskState.recordToolCall(name: call.name, arguments: stringArguments)
                let convergenceSignature = AgentTaskWorkingSet.signature(tool: call.name, args: stringArguments)
                // 总账先记；identical streak 只在真正执行处更新（幂等/缓存拦截不计数）。
                convergence.recordTotalCall()
                // tool_search 计数在调用层记录：缓存命中/幂等拦截也不漏计。
                if call.name == "tool_search" {
                    convergence.recordToolSearch()
                }
                diagnostics.recordToolCall(call.name)
                let diagnosticArgs = AgentSensitiveDataRedactor.arguments(call.arguments)
                if let violation = taskState.budgetViolation(policy: policy) {
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(violation.localizedDescription)]))
                    return
                }
                roundToolNames.insert(call.name)
                if AgentTaskWorkingSet.isSearchTool(call.name) { roundSearchCalls += 1 }

                // Stateful Skill-owned mutation 是 Runtime 的内部编排步骤，不是
                // “尚未加载”的普通模型工具。优先给出正确反馈，避免模型被诱导
                // 反复 tool_search 一个永远不会进入模型 schema 的工具。
                if let activeSkill,
                   activeSkill.ownedToolNames.contains(call.name),
                   call.origin.isModelOwned {
                    let failureText = "（工具执行结果）\(call.name)：当前由 Stateful Skill 自动管理，不能由模型直接调用，也不需要通过 tool_search 加载。请继续使用搜索/推荐/选择工具，完成后调用 result_present_tracks 提交最终歌曲；系统会自动执行该步骤。"
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "Skill-owned 操作由 Runtime 管理", reused: false))
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: failureText,
                        native: nativeMode
                    ))
                    continue
                }

                guard Self.isModelToolCallAdmitted(call, admission: roundAdmission) else {
                    let failureText = "（工具执行结果）\(call.name)：未执行 - 该工具尚未加载到本轮工具 schema。如确实需要此能力，请先使用 tool_search 发现并加载。"
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "工具尚未加载到本轮 schema", reused: false))
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: failureText,
                        native: nativeMode
                    ))
                    continue
                }

                guard let descriptor = Self.descriptor(for: call, in: availableToolDescriptors) else {
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "未知工具", reused: false))
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: "执行失败：未知工具 \(call.name)",
                        native: nativeMode
                    ))
                    continue
                }

                // Fixed Skill 激活时模型面只有只读工具；若模型绕过 schema 硬调写操作
                //（例如 playback_play_artist），一律拒绝。来源判定使用结构化
                // LoopToolCallOrigin 而不是 tool_call.id 前缀——id 是模型/provider 输入，
                // 可伪造（如 id = "skill-forged"）；Skill 的 mutation 主路径只允许
                // origin == .skillForced 的 forced call 执行。
                if activeSkill != nil,
                   descriptor.permission != .readOnly,
                   call.origin.isModelOwned {
                    let failureText = "（工具执行结果）\(call.name)：本任务由固定 Skill 编排，写操作由系统确定性执行；请只使用搜索/推荐/选择类工具收集候选。"
                    taskState.errors.append(failureText)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "Skill 模式拒绝模型直接写调用", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    continue
                }

                if call.malformedArguments {
                    let failureText = "（工具执行结果）\(call.name): 参数 JSON 不完整或被截断，本次没有执行工具。"
                    taskState.errors.append(failureText)
                    convergence.recordMalformedCall()
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: [:], summary: "原生参数 JSON 不完整", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    if let stopReason = convergence.stopReason(under: policy.convergence, tolerateSearchExhaustion: plan.semantics.isMusicAppreciation) {
                        let message = stopReason.userMessage
                        taskState.status = .insufficient
                        taskState.errorState = message
                        taskState.updatedAt = .now
                        await state(taskState)
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                        return
                    }
                    continue
                }
                // malformed streak 只对“真正连续”的畸形调用生效：
                // 任意合法 ToolCall 都清零该 streak。
                convergence.recordValidCall()

                if let activeSkill,
                   activeSkill.ownedToolNames.contains(call.name),
                   let issue = activeSkill.validateToolCall(name: call.name, arguments: call.arguments) {
                    let recovery = activeSkill.handleMalformedCall(name: call.name)
                    let failureText = "（工具执行结果）\(call.name): \(issue)，本次没有执行写入。"
                    taskState.errors.append(failureText)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "Stateful Skill 参数无效", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    if let recovery {
                        taskState.pendingActions = [recovery.message]
                        await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: recovery.message)]))
                        shouldCompactSkillTranscript = recovery.compactTranscript
                    }
                    Self.mergeSkillFacts(activeSkill, into: &taskState)
                    continue
                }

                // 修改型工具不是查询缓存的一部分。相同工具 + 相同规范化参数再次出现时
                // 幂等复用（不重复副作用）；不同参数（例如第二次 queue_replace 使用不同
                // 歌曲列表）照常执行，任务不被“互斥保护”卡死。
                if descriptor.permission != .readOnly,
                   let reason = ws.sideEffectBlockReason(tool: call.name, args: stringArguments) {
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "已拦截重复副作用", reused: true))
                    if pendingMutationFinalization,
                       !ws.isIndeterminateSideEffect(tool: call.name, args: stringArguments) {
                        // The provider has planned the exact mutation again
                        // after a successful result.  Keep the idempotence
                        // guard, but finish this request instead of feeding a
                        // duplicate-operation message back into another open
                        // planning turn.
                        duplicateMutationFinalization = true
                    }
                    // A confirmed duplicate is an internal recovery detail,
                    // but an indeterminate remote write remains user-visible:
                    // the user must know that no automatic retry was made.
                    if ws.isIndeterminateSideEffect(tool: call.name, args: stringArguments) {
                        await emit(AgentChatMessage(role: .assistant, messages: [.text(reason)]))
                    }
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: "（工具执行结果）\(call.name): 已跳过 - \(reason)",
                        native: nativeMode
                    ))
                    continue
                }

                // The previous successful mutation was only a candidate for
                // finalization. A different write in this turn is a legitimate
                // multi-step request, so let it run and keep the loop open.
                if pendingMutationFinalization, descriptor.permission != .readOnly {
                    pendingMutationFinalization = false
                    duplicateMutationFinalization = false
                }

                // ② 任务级缓存：同一工具 + 规范化参数已执行过 → 直接复用结果。
                // 搜索类工具的重复调用同样记为「无新结果」，仅用于诊断 streak。
                if descriptor.cachePolicy == .task,
                   let cachedText = ws.tryReuse(tool: call.name, args: stringArguments) {
                    var text = cachedText
                    if AgentTaskWorkingSet.isSearchTool(call.name) {
                        _ = ws.observeCandidates([])
                        // 缓存命中 = 同一搜索再次请求但没有任何新结果：计入诊断 streak。
                        let exhausted = convergence.recordSearchOutcome(
                            toolName: call.name,
                            foundNewEvidence: false,
                            policy: policy.convergence
                        )
                        if exhausted {
                            selectedTools.removeAll { $0.name == call.name }
                        }
                        if ws.noNewResultsStreak >= AgentTaskWorkingSet.noNewResultsLimit {
                            text += "\n（提示）同一搜索已执行 \(ws.noNewResultsStreak) 次且没有新结果，当前已获得 \(ws.uniqueSongIDs.count) 首唯一候选。可以基于现有候选回答，或换一个搜索词/换一种策略继续。"
                        }
                    }
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "缓存命中", reused: true))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: text, native: nativeMode))
                    continue
                }

                // ③ 执行工具（实际只执行一次；写入任务级缓存供后续复用）。
                await progress(AgentProgress(
                    toolSteps: toolStepCount,
                    currentStep: "执行 \(call.name)"
                ))
                taskState.status = .waitingForTool
                taskState.updatedAt = .now
                await state(taskState)
                let result: ToolResult
                let executableCall = call.usesTextProtocol
                    ? structuredToolCall(name: call.name, legacyArguments: stringArguments)
                    : ToolCall(name: call.name, arguments: call.arguments)
                let signature = Self.confirmationSignature(name: call.name, args: stringArguments)

                if descriptor.requiresExplicitUserApproval {
                    let pending = await Self.pendingConfirmation(
                        catalog: catalog,
                        descriptor: descriptor,
                        name: call.name,
                        diagnosticArgs: diagnosticArgs,
                        runID: runID,
                        sessionID: executionLease.sessionID,
                        toolCallID: call.id
                    )
                    if deniedConfirmationSignatures.contains(signature) {
                        let message = "用户尚未批准「\(descriptor.summary)」，本次未执行。"
                        ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "重复调用仍未获批准", reused: true))
                        toolMessages.append(Self.toolResultMessage(
                            callID: call.id,
                            content: "（工具执行结果）\(call.name): 已跳过 - \(message)",
                            native: nativeMode
                        ))
                        continue
                    }
                    await emit(AgentChatMessage(role: .assistant, messages: [.confirmation(pending)]))
                    guard await confirm(pending) else {
                        deniedConfirmationSignatures.insert(signature)
                        let message = "用户未批准「\(descriptor.summary)」，本次未执行。"
                        taskState.errors.append(message)
                        taskState.pendingActions = [message]
                        taskState.status = .waitingForModel
                        taskState.updatedAt = .now
                        await state(taskState)
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                        ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "用户拒绝高风险操作", reused: false))
                        toolMessages.append(Self.toolResultMessage(
                            callID: call.id,
                            content: "（工具执行结果）\(call.name): 已拒绝 - \(message)",
                            native: nativeMode
                        ))
                        continue
                    }
                }
                let authorizationForCall = effectiveAuthorization
                let effectiveToolTimeout = Self.effectiveToolTimeout(descriptor, requested: toolTimeout)
                let executionCallID = call.id
                let descriptorsForExecution = availableToolDescriptors
                // 真正执行：identical signature streak 只在执行处累计；
                // totalToolCalls 已在调用层 recordTotalCall() 计过一次，这里不再计。
                convergence.recordToolExecution(signature: convergenceSignature)
                do {
                    result = try await Self.withTimeout(effectiveToolTimeout) {
                        await ToolRuntime.executeMeasured(
                            executableCall,
                            bridge: bridge,
                            catalog: catalog,
                            serverID: context.serverID,
                            systemService: systemService,
                            externalMusicService: externalMusicService,
                            privacyPermissions: context.privacyPermissions,
                            allowsLyrics: context.allowsLyrics,
                            allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                            providerCapabilities: provider.capabilities,
                            webService: webService,
                            authorizationContext: authorizationForCall,
                            activeSkillID: activeSkillID,
                            executionLease: executionLease,
                            resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                            recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                            customToolRegistry: context.customToolRegistry,
                            availableToolDescriptors: descriptorsForExecution,
                            capabilityEnvironment: capabilityEnvironment,
                            runID: runID,
                            callID: executionCallID
                        )
                    }
                } catch is CancellationError {
                    if descriptor.permission != .readOnly {
                        ws.recordIndeterminateSideEffect(tool: call.name, args: stringArguments)
                        let message = "已取消；取消请求已发出，但「\(call.name)」可能已在服务端落地，结果未知。为避免重复副作用，本任务不会自动以相同参数重试；请先查询核验。"
                        taskState.errors.append(message)
                        taskState.status = .cancelled
                        taskState.updatedAt = .now
                        ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "用户取消，写操作结果未知", reused: false))
                        await state(taskState)
                        await log(AgentActionRecord(toolName: call.name, permission: descriptor.permission, summary: message))
                        await emit(AgentChatMessage(role: .assistant, messages: [.text(message)]))
                    } else {
                        await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                    }
                    return
                } catch {
                    // 单工具超时/异常只回灌结构化失败结果，不终止整项任务；模型可换工具/换参数继续。
                    let failureText: String
                    if error is AgentRunnerError {
                        let timeoutFailure = ToolRuntime.timeoutResult(call: executableCall, descriptor: descriptor)
                        let code = timeoutFailure.failure?.code ?? "tool_timeout"
                        if descriptor.permission != .readOnly {
                            ws.recordIndeterminateSideEffect(tool: call.name, args: stringArguments)
                            failureText = "（工具执行结果）\(call.name): 超时 - \(timeoutFailure.summary) [failure_code=\(code); indeterminate=true]。为避免重复副作用，禁止自动以相同参数重试；请改用查询工具核验结果或让用户确认后再处理。"
                        } else {
                            failureText = "（工具执行结果）\(call.name): 超时 - \(timeoutFailure.summary) [failure_code=\(code); indeterminate=false] 可改用其他查询方式继续。"
                        }
                    } else {
                        failureText = "（工具执行结果）\(call.name): 执行中断 - \(Self.errorText(error))"
                    }
                    if let activeSkill,
                       activeSkill.ownedToolNames.contains(call.name) {
                        let consumption = activeSkill.handleToolFailure(name: call.name, message: failureText)
                        if case let .fail(message) = consumption {
                            fixedSkillFailure = message
                        }
                        Self.mergeSkillFacts(activeSkill, into: &taskState)
                    }
                    taskState.errors.append(failureText)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "工具超时/中断", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    continue
                }
                if result.hasIndeterminateSideEffect, result.permission != .readOnly {
                    ws.recordIndeterminateSideEffect(tool: call.name, args: stringArguments)
                } else if result.success, result.permission != .readOnly {
                    ws.recordSuccessfulSideEffect(tool: call.name, args: stringArguments, summary: result.summary)
                }
                if result.success {
                    diagnostics.recordToolSuccess()
                } else if let code = result.failure?.code {
                    diagnostics.recordFailure(code: code)
                }
                if case let .webSources(sources)? = result.payload, !sources.isEmpty {
                    await emit(AgentChatMessage(role: .assistant, messages: [.webSources(sources)]))
                }
                let madeProgress = AgentTaskReducer.apply(result: result, descriptor: descriptor, to: &taskState)
                if result.success {
                    // 失败本身就是新信息（错误事实），只对“成功但无新事实”计 no-progress。
                    if madeProgress {
                        convergence.recordProgress()
                    } else {
                        convergence.recordNoProgress()
                    }
                }
                if result.success,
                   descriptor.permission != .readOnly,
                   Self.shouldFinalizeAfterMutation(
                       policy: policy,
                       state: taskState,
                       requiredCompletionOperations: requiredCompletionOperations
                   ) {
                    pendingMutationFinalization = true
                }
                if result.success, call.name == "tool_search" {
                    let query = stringArguments["query"] ?? ""
                    let namespace = stringArguments["namespace"]
                    let limit = min(max(Int(stringArguments["limit"] ?? "8") ?? 8, 1), 50)
                    let expansion = Self.expandToolsFromSearch(
                        query: query,
                        namespace: namespace,
                        limit: limit,
                        allDescriptors: availableToolDescriptors,
                        current: &selectedTools,
                        allowedOperations: effectiveAuthorization.allowedOperations,
                        excludedNames: activeSkill?.ownedToolNames ?? [],
                        excludeAllMutations: activeSkill != nil
                    )
                    let discoveredEntries = expansion.discoveredEntries
                    let addedToolToSchema = !expansion.addedEntries.isEmpty
                    diagnostics.recordToolSearch(query: query, returned: discoveredEntries.map(\.name))
                    // 搜索结果只携带能力和风险元数据；普通本地 mutation 不因
                    // 语义分析遗漏而被标成不可执行。
                    if let activeSkill {
                        skillOwnedToolsNotLoaded = discoveredEntries
                            .map(\.name)
                            .filter { activeSkill.ownedToolNames.contains($0) }
                    }
                    if nativeMode, addedToolToSchema {
                        toolDefinitions = ToolSelector.toolDefinitions(
                            from: Self.localModelTools(selectedTools, capabilities: provider.capabilities),
                            strict: provider.capabilities.supportsStrictSchema,
                            activeSkillID: activeSkillID
                        )
                    }
                    if let stopReason = convergence.stopReason(under: policy.convergence, tolerateSearchExhaustion: plan.semantics.isMusicAppreciation) {
                        let message = stopReason.userMessage
                        taskState.status = .insufficient
                        taskState.errorState = message
                        taskState.updatedAt = .now
                        await state(taskState)
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                        return
                    }
                }
                // Skill 需要消费所有工具结果（不只 owned mutation）：
                // read / selection 工具（如 result_present_tracks）是候选提交信号，
                // Skill 据此推进状态机；owned mutation 结果用于确定性验证。
                if let activeSkill {
                    switch activeSkill.consumeToolResult(name: call.name, result: result) {
                    case .compactTranscript:
                        shouldCompactSkillTranscript = true
                    case let .fail(message):
                        fixedSkillFailure = message
                    case .none:
                        break
                    }
                    Self.mergeSkillFacts(activeSkill, into: &taskState)
                }
                if madeProgress { completionRepairAttempts = 0 }
                await state(taskState)
                // 展示状态：候选进内部池（绝不上屏）；最终/歧义由工具声明；真实副作用写 final。
                if result.success {
                    let role = result.presentationRole == .none ? descriptor.defaultPresentationRole : result.presentationRole
                    if let payload = result.payload {
                        switch (role, payload) {
                        case (.candidate, let .trackCards(cards)):
                            presentation.addCandidateTracks(cards)
                        case (.candidate, let .albumCards(albums)):
                            presentation.addCandidateAlbums(albums)
                        case (.candidate, let .playlistProposal(name, tracks)):
                            presentation.addCandidateTracks(tracks)
                            presentation.setFinalPlaylistProposal(name, tracks)
                        case (.finalResult, let .trackCards(cards)):
                            presentation.setFinalTracks(cards)
                            taskState.selectedIDs = Set(cards.map { $0.globalID.description })
                            // 最终选择事实：musicDiscovery 完成判定依据
                            // （finalTrackSelection 要求 finalSelection 存在且达标）。
                            taskState.facts["task.finalSelection.count"] = String(cards.count)
                            if let target = ws.targetQueueCount {
                                taskState.facts["task.targetCount"] = String(target)
                            }
                        case (.disambiguation, let .trackCards(cards)):
                            presentation.setDisambiguation(cards)
                        default:
                            break
                        }
                    }
                    // 真实副作用：queue / playlist 写成功 → 以实际入队/入歌单的 ID 确定 final。
                    if let gids = Self.sideEffectFinalIDs(name: call.name, args: stringArguments, descriptor: descriptor) {
                        var cards = await Self.resolveTrackCards(gids, presentation: presentation, catalog: catalog)
                        let append = descriptor.sideEffectPolicy == .queue
                            && call.name != "queue_replace" && call.name != "replaceQueue"
                        if append, !presentation.finalTrackIDs.isEmpty {
                            cards = presentation.finalTrackIDs.compactMap { presentation.candidateTracks[$0] } + cards
                        }
                        presentation.setFinalTracks(cards)
                        taskState.selectedIDs = Set(cards.map { $0.globalID.description })
                    }
                    if call.name == "queue_clear" || call.name == "clearQueue" {
                        presentation.setFinalTracks([])
                        taskState.selectedIDs = []
                    }
                }
                // 只读查询不入日志；修改型操作全部落盘，供「操作记录」查看与撤销。
                if result.permission != .readOnly, result.success {
                    await log(AgentActionRecord(
                        toolName: call.name,
                        permission: result.permission,
                        summary: result.summary
                    ))
                }

                // 工具结果回传：摘要 + 真实歌曲/专辑清单；失败也回灌（不终止循环）。
                var resultText = Self.providerToolResultText(
                    callName: call.name,
                    descriptor: descriptor,
                    result: result,
                    context: context,
                    targetCount: ws.targetQueueCount
                )
                resultText = AIContentTrustBoundary.wrap(resultText, trustLevel: result.trustLevel)

                // 隐私 gating：歌词权限关闭时，把歌词工具结果替换为固定隐藏摘要，
                // 不把行数 / 语言 / 逐行状态等歌词相关字段回传模型。
                // 构造点位于 SystemToolExecutor.swift:130-136（本文件外的只读文件），
                // 这里在回灌边界统一拦截，避免修改 AgentKit 外部文件。
                if call.name == "lyrics_get", !context.allowsLyrics {
                    resultText = "（工具执行结果）lyrics_get: 成功 - 歌词已按隐私设置隐藏（不发送歌词内容）。"
                }
                if !skillOwnedToolsNotLoaded.isEmpty {
                    let names = skillOwnedToolsNotLoaded.joined(separator: "、")
                    resultText += "\n当前 Stateful Skill 负责的工具（\(names)）不会加入本轮模型 schema，也不能通过 tool_search 加载；请继续调用 result_present_tracks 提交最终歌曲，系统会自动完成这些操作。"
                }

                // ④ 更新工作集：先观察候选（用于诊断），再缓存最终结果。
                // 搜索诊断：结果返回后判定是否产生新 evidence（working set 候选指纹
                // before/after 对比），按工具独立累计 streak；不从 schema 移除工具。
                if AgentTaskWorkingSet.isSearchTool(call.name) {
                    var foundNewEvidence = false
                    if let payload = result.payload, case let .trackCards(cards) = payload {
                        let noNew = ws.observeCandidates(cards.map(\.globalID))
                        foundNewEvidence = !noNew
                    }
                    let exhausted = convergence.recordSearchOutcome(
                        toolName: call.name,
                        foundNewEvidence: foundNewEvidence,
                        policy: policy.convergence
                    )
                    if exhausted {
                        selectedTools.removeAll { $0.name == call.name }
                        if nativeMode {
                            toolDefinitions = ToolSelector.toolDefinitions(
                                from: Self.localModelTools(selectedTools, capabilities: provider.capabilities),
                                strict: provider.capabilities.supportsStrictSchema,
                                activeSkillID: activeSkillID
                            )
                        }
                        resultText += "\n（搜索收敛）\(call.name) 已连续 \(policy.convergence.maxSameToolNoNewEvidence) 次没有提供新证据，本轮不再暴露该搜索能力。请直接根据已有事实回答；若没有结果，请明确说明。"
                    } else if !foundNewEvidence, (convergence.searchNoNewEvidenceStreakByTool[call.name] ?? 0) >= 2 {
                        resultText += "\n（提示）该搜索已连续没有新结果，当前已获得 \(ws.uniqueSongIDs.count) 首唯一候选。可以基于现有候选回答，或换一个搜索词继续。"
                    }
                }
                if AgentTaskWorkingSet.isSearchTool(call.name) == false, AgentTaskWorkingSet.queueWritingTools.contains(call.name) {
                    let queued = AgentTaskWorkingSet.songIDs(from: stringArguments)
                    if !queued.isEmpty { ws.noteQueued(queued) }
                }
                resultText = ContextManager.truncateToolResult(resultText, limit: descriptor.maxResultCharacters)
                ws.recordExecution(tool: call.name, args: stringArguments, resultText: resultText)
                ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: result.summary, reused: false))
                toolMessages.append(Self.toolResultMessage(callID: call.id, content: resultText, native: nativeMode))
            }

            conversation.append(contentsOf: toolMessages)
            if shouldCompactSkillTranscript, let activeSkill {
                conversation = Self.compactSkillTranscript(
                    conversation,
                    ownedToolNames: activeSkill.ownedToolNames
                )
            }

            if let fixedSkillFailure {
                let message = "Stateful Skill 固定链路执行失败：\(fixedSkillFailure)"
                taskState.errors.append(message)
                taskState.errorState = message
                taskState.status = .failed
                taskState.updatedAt = .now
                await state(taskState)
                await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                return
            }

            if pendingMutationFinalization, duplicateMutationFinalization {
                // A successful mutation already satisfies the
                // current request and the provider has planned the exact same
                // call again. The working-set idempotence guard still protects
                // the duplicate call; do not expose that recovery detail as a
                // second user-visible operation.
                _ = AgentCompletionEvaluator.markFactsSatisfied(
                    state: &taskState,
                    policy: policy,
                    requiredCompletionOperations: requiredCompletionOperations
                )
                taskState.pendingActions = []
                await state(taskState)
                var finalMessages: [AgentMessage] = []
                if let finalMessage = presentation.finalMessage() {
                    finalMessages.append(finalMessage)
                }
                finalMessages.append(.text(Self.deterministicCompletionSummary(policy: policy, presentation: presentation)))
                await emit(AgentChatMessage(
                    role: .assistant,
                    messages: finalMessages
                ))
                return
            }

            // 普通任务在工具回灌后回到 auto；封闭分类阶段始终锁定唯一的
            // write_batch，避免下一轮又回到旁路工具。
            if nativeMode, !nativeCalls.isEmpty {
                toolChoice = provider.capabilities.supportsToolChoice ? .auto : nil
            }

            // 合并工具轨迹：不再逐行刷「调用 X」，而是合并成一条状态。
            if !toolMessages.isEmpty {
                if roundSearchCalls > 0 {
                    await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "正在搜索音乐库… 已完成 \(ws.executedCalls) 次调用，获得 \(ws.uniqueSongIDs.count) 首候选")]))
                } else {
                    await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "正在执行：\(roundToolNames.sorted().joined(separator: "、"))…")]))
                }
            }
        }
    }

    /// 从真实副作用（队列写入 / 歌单加歌）解析最终展示用的歌曲 ID。
    /// 只解析成功副作用涉及的实际 ID；读取型工具返回 nil（不改变 final）。
    private static func sideEffectFinalIDs(name: String, args: [String: String], descriptor: ToolDescriptor) -> [GlobalID]? {
        switch descriptor.sideEffectPolicy {
        case .queue:
            if ["queue_replace", "replaceQueue", "queue_append", "queue_play_next",
                "addToQueue", "playNext"].contains(name) {
                let ids = AgentTaskWorkingSet.songIDs(from: args)
                return ids.isEmpty ? nil : ids
            }
            return nil
        case .playlist:
            if ["playlist_add_songs", "addTracksToPlaylist"].contains(name) {
                let ids = AgentTaskWorkingSet.songIDs(from: args)
                return ids.isEmpty ? nil : ids
            }
            return nil
        default:
            return nil
        }
    }

    private static func mergeSkillFacts(
        _ skill: (any AgentStatefulSkillRuntime)?,
        into state: inout AgentTaskState
    ) {
        guard let skill else { return }
        state.facts.merge(skill.facts) { _, newValue in newValue }
    }

    private static func skillCompletionMessage(
        _ skill: (any AgentStatefulSkillRuntime)?
    ) -> String {
        guard let skill else { return "已完成。" }
        if case let .completed(message) = skill.nextStep() {
            return message
        }
        return "已完成。"
    }

    private static func markSkillCompleted(state: inout AgentTaskState) {
        state.completed = true
        state.completionState = .satisfied
        state.status = .completed
        state.updatedAt = .now
    }

    /// Keep the native transcript legal while preventing any long-running
    /// stateful skill from replaying every completed payload on each request.
    /// A completed skill turn is an atomic assistant(tool_calls)+tool-result
    /// unit; only the newest owned-only unit is needed for the next decision.
    private static func compactSkillTranscript(
        _ conversation: [AIMessage],
        ownedToolNames: Set<String>,
        droppingLatestOwnedUnit: Bool = false
    ) -> [AIMessage] {
        struct ToolUnit {
            let indices: [Int]
            let isOwnedOnly: Bool
        }

        var units: [ToolUnit] = []
        var cursor = 0
        while cursor < conversation.count {
            let message = conversation[cursor]
            guard message.role == .assistant,
                  let calls = message.toolCalls,
                  !calls.isEmpty
            else {
                cursor += 1
                continue
            }

            let names = Set(calls.map(\.name))
            guard !names.isDisjoint(with: ownedToolNames) else {
                cursor += 1
                continue
            }

            let expectedIDs = Set(calls.map(\.id))
            var receivedIDs: Set<String> = []
            var end = cursor + 1
            while end < conversation.count, conversation[end].role == .tool,
                  let callID = conversation[end].toolCallID,
                  expectedIDs.contains(callID),
                  receivedIDs.insert(callID).inserted {
                end += 1
            }
            guard receivedIDs == expectedIDs else {
                cursor += 1
                continue
            }

            units.append(ToolUnit(
                indices: Array(cursor..<end),
                isOwnedOnly: names.isSubset(of: ownedToolNames)
            ))
            cursor = end
        }

        let ownedUnits = units.filter(\.isOwnedOnly)
        guard !ownedUnits.isEmpty else { return conversation }

        var indicesToRemove = Set<Int>()
        var keptUnit: ToolUnit?
        if droppingLatestOwnedUnit {
            let latest = ownedUnits.last
            indicesToRemove.formUnion(latest?.indices ?? [])
            keptUnit = ownedUnits.dropLast().last
        } else {
            keptUnit = ownedUnits.last
        }

        for unit in ownedUnits where unit.indices != keptUnit?.indices {
            indicesToRemove.formUnion(unit.indices)
        }

        return conversation.indices.compactMap { index in
            indicesToRemove.contains(index) ? nil : conversation[index]
        }
    }

    private static func localModelTools(
        _ tools: [ToolDescriptor],
        capabilities: ModelCapabilities
    ) -> [ToolDescriptor] {
        tools.filter { descriptor in
            if descriptor.name == "web_search" && capabilities.supportsHostedWebSearch {
                return false
            }
            if descriptor.name == "web_fetch" && capabilities.supportsHostedWebFetch {
                return false
            }
            return true
        }
    }

    private static func hostedTools(
        for capabilities: ModelCapabilities,
        availableTools: [ToolDescriptor]
    ) -> [AIHostedTool] {
        let names = Set(availableTools.map(\.name))
        var result: [AIHostedTool] = []
        if capabilities.supportsHostedWebSearch, names.contains("web_search") {
            result.append(.webSearch)
        }
        if capabilities.supportsHostedWebFetch, names.contains("web_fetch") {
            result.append(.webFetch)
        }
        return result
    }

    private static func webSources(from citations: [AIWebCitation]) -> [WebSource] {
        var seen = Set<String>()
        return citations.compactMap { citation in
            let canonical = WebSource.canonicalURL(citation.url).absoluteString
            guard seen.insert(canonical).inserted else { return nil }
            return WebSource(
                title: citation.title,
                url: citation.url,
                snippet: citation.snippet ?? "",
                publishedAt: citation.publishedAt,
                backend: citation.backend,
                sourceType: citation.sourceType
            )
        }
    }

    private static func registerWebSources(
        _ sources: [WebSource],
        webService: (any AgentWebService)?,
        runID: UUID
    ) async {
        guard let scopedWebService = webService as? any AgentWebRunScopedService else { return }
        await scopedWebService.register(sources: sources, runID: runID)
    }

    private static func deterministicCompletionSummary(
        policy: AgentTaskPolicy,
        presentation: AgentPresentationState
    ) -> String {
        switch policy.completion {
        case .playbackMutation:
            if let track = presentation.resolvedFinalCards.first {
                return "已开始播放《\(track.title)》。"
            }
            return "播放操作已完成。"
        case .queueMutation:
            return "队列操作已完成。"
        case .playlistMutation:
            return "歌单操作已完成。"
        case .indexPendingCountIsZero:
            return "推荐索引已完成。"
        case .successfulToolResult:
            return "已根据真实工具结果完成。"
        case .finalTrackSelection:
            return "已提交最终歌曲选择。"
        case .modelAnswer, .appreciationWithEvidence:
            return "已完成。"
        }
    }

    private static func shouldFinalizeAfterMutation(
        policy: AgentTaskPolicy,
        state: AgentTaskState,
        requiredCompletionOperations: Set<ToolAuthorizationOperation>
    ) -> Bool {
        guard AgentCompletionEvaluator.factsSatisfied(
            state: state,
            policy: policy,
            requiredCompletionOperations: requiredCompletionOperations
        ) else { return false }
        guard policy.completion == .queueMutation
            || policy.completion == .playlistMutation
            || policy.completion == .playbackMutation
        else { return false }

        // Completion is a fact check, not an authorization check. When the
        // task compiler supplied a compound contract, factsSatisfied above
        // requires every operation in that contract; a duplicate first step
        // therefore cannot finalize the task before its second step succeeds.
        return true
    }

    private static func markWorkflowCompleted(state: inout AgentTaskState) {
        state.completed = true
        state.completionState = .satisfied
        state.status = .completed
        state.updatedAt = .now
    }

    /// 把 ID 解析成有序卡片：优先用内部候选池，缺失时从本地目录补查。
    private static func resolveTrackCards(
        _ ids: [GlobalID],
        presentation: AgentPresentationState,
        catalog: LocalCatalogStore
    ) async -> [TrackCard] {
        var result: [TrackCard] = []
        for id in ids {
            if let card = presentation.candidateTracks[id] {
                result.append(card)
            } else if let track = try? await catalog.getTrack(id) {
                result.append(TrackCard.from(track))
            }
        }
        return result
    }

    /// 构造工具结果消息：原生模式用 `.tool` + tool_call_id，文本模式用 `.user`。
    private static func toolResultMessage(callID: String?, content: String, native: Bool) -> AIMessage {
        if native, let callID, !callID.isEmpty {
            return AIMessage(role: .tool, content: content, toolCallID: callID)
        }
        return AIMessage(role: .user, content: content)
    }

    /// tool_search 结果 → 当前 schema 的扩展（Generic Chat 与 Task Loop 共用，
    /// 避免两套能力扩展行为分叉）。
    ///
    /// Schema discovery is relevance-only. Mutation tools remain available;
    /// ordinary reversible calls execute directly and destructive calls use
    /// their visible confirmation policy.
    /// Skill 激活时，Skill-owned mutation（excludedNames）也不进入 schema——
    /// 主路径由 Skill 内部固定调用。
    /// 返回发现结果与实际加入当前 schema 的结果，避免 Skill 禁止加载的
    /// mutation 被误报成“已加载”。
    private static func expandToolsFromSearch(
        query: String,
        namespace: String?,
        limit: Int,
        allDescriptors: [ToolDescriptor],
        current: inout [ToolDescriptor],
        allowedOperations: Set<ToolAuthorizationOperation>,
        excludedNames: Set<String> = [],
        excludeAllMutations: Bool = false
    ) -> ToolSearchExpansionResult {
        let catalog = ToolCatalog(descriptors: allDescriptors)
        let entries = catalog.search(
            query: query,
            namespace: namespace,
            limit: limit,
            authorizedOperations: allowedOperations
        )
        let byName = Dictionary(uniqueKeysWithValues: allDescriptors.map { ($0.name, $0) })
        var existing = Set(current.map(\.name))
        var addedEntries: [ToolCatalogEntry] = []
        for entry in entries {
            guard !existing.contains(entry.name), let tool = byName[entry.name] else { continue }
            if excludedNames.contains(tool.name) { continue }
            if tool.permission != .readOnly {
                // Fixed Skill 激活时：即使 mutation 属于该流程（如 queueReplace 对应的
                // queue_replace），也不作为模型可见 schema 补入——Skill 内部会固定调用。
                if excludeAllMutations { continue }
            }
            current.append(tool)
            existing.insert(tool.name)
            addedEntries.append(entry)
        }
        return ToolSearchExpansionResult(
            discoveredEntries: entries,
            addedEntries: addedEntries
        )
    }

    /// One bounded recovery when a non-chat model turn explicitly signals it
    /// lacks factual evidence.  The selector remains only a schema optimizer:
    /// this adds at most eight *read-only* canonical descriptors and never
    /// creates a hidden permission or repeats the same expansion set.
    private static func automaticallyExpandReadOnlyTools(
        userText: String,
        plan: AgentRequestPlan,
        allDescriptors: [ToolDescriptor],
        current: inout [ToolDescriptor]
    ) -> [ToolDescriptor] {
        let candidates = ToolCatalog(descriptors: allDescriptors).search(
            query: userText,
            limit: 8,
            authorizedOperations: plan.authorization.allowedOperations
        )
        let byName = Dictionary(uniqueKeysWithValues: allDescriptors.map { ($0.name, $0) })
        var existing = Set(current.map(\.name))
        var added: [ToolDescriptor] = []
        for entry in candidates {
            guard let descriptor = byName[entry.name],
                  descriptor.visibility == .model,
                  descriptor.permission == .readOnly,
                  existing.insert(descriptor.name).inserted
            else { continue }
            current.append(descriptor)
            added.append(descriptor)
        }
        return added
    }

    private static func shouldAutomaticallyExpandToolSurface(
        answer: String,
        plan: AgentRequestPlan,
        current: [ToolDescriptor],
        allDescriptors: [ToolDescriptor]
    ) -> Bool {
        guard plan.semantics.domain != .conversation,
              current.count < allDescriptors.filter({ $0.visibility == .model && $0.permission == .readOnly }).count
        else { return false }
        let lower = answer.lowercased()
        return answer.isEmpty
            || ["没有足够", "无法判断", "无法确定", "缺少", "不知道", "不清楚", "need more", "insufficient", "cannot determine"].contains(where: lower.contains)
    }

    /// Provider codecs decode raw wire JSON before the call reaches ToolLoop.
    /// Keep the object structured here; only the ACTION compatibility branch
    /// below projects text arguments back into JSON values.
    private static func parseArguments(_ value: AIJSONValue) -> ToolArgumentParseResult {
        guard case let .object(object) = value else {
            return .malformed(rawLength: value.jsonString.utf8.count)
        }
        return .success(object)
    }

    /// ACTION/text-protocol compatibility boundary. Legacy arguments arrive as
    /// strings, but the call handed to ToolRuntime is immediately projected to
    /// canonical AIJSONValue values. Native provider calls should use the
    /// structured overload directly once the provider codec has decoded them.
    private static func structuredToolCall(
        name: String,
        legacyArguments: [String: String]
    ) -> ToolCall {
        let arguments = legacyArguments.mapValues(AIJSONValue.string)
        guard let descriptor = AgentToolRegistry.descriptor(for: name) else {
            return ToolCall(name: name, arguments: arguments)
        }
        return ToolCall(
            name: name,
            arguments: Self.projectLegacyArguments(
                legacyArguments,
                descriptor: descriptor,
                fallback: arguments
            )
        )
    }

    /// 把文本 ACTION 的字符串参数按 descriptor schema 还原为 canonical
    /// AIJSONValue（array/boolean/number/object）。无法还原的保持字符串。
    static func projectLegacyArguments(
        _ legacyArguments: [String: String],
        descriptor: ToolDescriptor,
        fallback: [String: AIJSONValue]
    ) -> [String: AIJSONValue] {
        var arguments = fallback
        for parameter in descriptor.parameters {
            guard let raw = legacyArguments[parameter.name],
                  let schemaData = parameter.schemaJSON?.data(using: .utf8),
                  let schema = try? AIJSONValue(jsonData: schemaData),
                  case let .object(schemaObject) = schema,
                  case let .string(type)? = schemaObject["type"] else { continue }
            switch type {
            case "array":
                if let parsed = try? AIJSONValue(jsonString: raw), case .array = parsed {
                    arguments[parameter.name] = parsed
                } else {
                    let items = raw.split { $0 == "," || $0 == "，" }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !items.isEmpty {
                        arguments[parameter.name] = .array(items.map(AIJSONValue.string))
                    }
                }
            case "object":
                if let parsed = try? AIJSONValue(jsonString: raw), case .object = parsed {
                    arguments[parameter.name] = parsed
                }
            case "boolean":
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1": arguments[parameter.name] = .bool(true)
                case "false", "0": arguments[parameter.name] = .bool(false)
                default: break
                }
            case "integer":
                if let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    arguments[parameter.name] = .number(Double(parsed))
                }
            case "number":
                if let parsed = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    arguments[parameter.name] = .number(parsed)
                }
            default:
                break
            }
        }
        return arguments
    }

    private static func policyRequiresToolExecution(_ policy: AgentTaskPolicy) -> Bool {
        switch policy.completion {
        case .modelAnswer, .appreciationWithEvidence:
            return false
        case .successfulToolResult, .finalTrackSelection, .queueMutation, .playlistMutation,
             .playbackMutation, .indexPendingCountIsZero:
            return true
        }
    }

    private static func confirmationSignature(name: String, args: [String: String]) -> String {
        let normalized = args.keys.sorted().map { key in
            "\(key)=\(args[key] ?? "")"
        }.joined(separator: "&")
        return "\(name)|\(normalized)"
    }

    private static func pendingConfirmation(
        catalog: LocalCatalogStore,
        descriptor: ToolDescriptor,
        name: String,
        diagnosticArgs: [String: String],
        runID: UUID,
        sessionID: UUID,
        toolCallID: String?
    ) async -> PendingConfirmation {
        // PendingConfirmation is only a Runtime approval boundary for tools
        // explicitly marked by the single confirmation policy. Reversible
        // mutations do not enter this helper and must never invent a second
        // confirmation protocol in natural language.
        let confirmationGuidance: String = if descriptor.permission == .destructive {
            "此操作属于破坏性变更，执行前需要用户确认。"
        } else {
            "此操作由工具确认策略要求执行前获得用户确认。"
        }
        var title = descriptor.summary
        var detail: String
        var resolvedPlaylist = false
        if name == "playlist_delete", let rawID = diagnosticArgs["playlistID"],
           let globalID = GlobalID(rawID),
           let playlist = try? await catalog.getPlaylist(globalID) {
            resolvedPlaylist = true
            title = "删除歌单「\(playlist.0.name)」？"
            detail = """
            将永久删除歌单「\(playlist.0.name)」（\(playlist.0.trackIDs.count) 首歌曲）。
            此操作不可逆。
            """
        } else if diagnosticArgs.isEmpty {
            detail = [descriptor.confirmationPolicy.reason, confirmationGuidance]
                .compactMap { $0 }
                .joined(separator: "\n")
        } else {
            let arguments = diagnosticArgs.keys.sorted().map { "\($0)=\(diagnosticArgs[$0] ?? "")" }.joined(separator: "、")
            detail = [descriptor.confirmationPolicy.reason, "参数：\(arguments)", confirmationGuidance]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        if !resolvedPlaylist && !detail.contains("不可逆") {
            detail += "\n\(confirmationGuidance)"
        }
        return PendingConfirmation(
            runID: runID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            toolName: name,
            permission: descriptor.permission,
            operation: descriptor.authorizationOperation,
            reason: descriptor.confirmationPolicy.reason,
            title: title,
            detail: detail,
            call: ToolCall(name: name, rawArguments: diagnosticArgs)
        )
    }

    private static func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func isOutputTruncated(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else { return false }
        if case .outputTruncated = providerError { return true }
        return false
    }

    /// 提示词负责“少用表情”，这里再做一次确定性兜底：每个句子最多保留一个 emoji。
    /// 句末和换行均视为新的句子；Markdown 原文、中文内容与链接保持不变。
    private static func formatAssistantReply(_ reply: String) -> String {
        var result = ""
        var emojiSeen = false
        var droppingEmojiSequence = false

        for character in reply {
            let scalars = character.unicodeScalars
            let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
            let isEmojiJoinerOrModifier = scalars.allSatisfy {
                $0.value == 0xFE0F || $0.value == 0x200D || (0x1F3FB...0x1F3FF).contains($0.value)
            }

            if isEmoji {
                if emojiSeen {
                    droppingEmojiSequence = true
                    continue
                }
                emojiSeen = true
                droppingEmojiSequence = false
                result.append(character)
            } else if droppingEmojiSequence && isEmojiJoinerOrModifier {
                continue
            } else {
                droppingEmojiSequence = false
                result.append(character)
            }

            if character == "。" || character == "！" || character == "？" || character == "." || character == "!" || character == "?" || character == "\n" {
                emojiSeen = false
                droppingEmojiSequence = false
            }
        }
        return result
    }

    // MARK: - LLM 调用鲁棒性

    /// 瞬时失败后自动重试一次的间隔。取值略大于 Provider 内部退避的首跳，
    /// 保证「Provider 内 3 次 + 这里再来一轮」之间有喘息时间。
    static let transientRetryDelay: TimeInterval = 0.8

    /// 助手页聊天与设置页「测试连接」共用同一个 Provider，但此前聊天路径**首次失败就降级**，
    /// 鲁棒性反而不如测试按钮（用户手点几次 = 手动重试），于是出现
    /// 「测试要试好多次才成功，成功后聊天又失败」的错觉。这里补一次自动重试，
    /// 让两条路径的容错等级对齐。
    ///
    /// 只对**瞬时故障**重试（5xx / 限流 / 网络抖动 / 空响应 / 截断 JSON / 单轮超时）；
    /// Key 无效、路径错误、格式不兼容等确定性错误立即上抛，不做无谓等待。
    private static func completeWithRetry(
        provider: any AIProvider,
        request: AICompletionRequest
    ) async throws -> AICompletionResponse {
        do {
            return try await withTimeout(roundTimeout) { try await provider.complete(request) }
        } catch let error where isTransientFailure(error) {
            // Task.sleep 在取消时抛 CancellationError，会被上层按「已取消」处理。
            try await Task.sleep(nanoseconds: UInt64(transientRetryDelay * 1_000_000_000))
            return try await withTimeout(roundTimeout) { try await provider.complete(request) }
        }
    }

    /// 判定错误是否值得再试一次。与 `AIProviderError.isTransient` 同源，额外覆盖网络层错误。
    ///
    /// 刻意**不**重试 `AgentRunnerError.timeout`：单轮超时已经耗掉完整的 180 秒，
    /// 再来一轮只会让界面持续无响应；超时后直接结束本轮，避免无感等待。
    /// 其余瞬时故障（5xx / 429 / 连接重置 / 空响应 / 截断 JSON）都是快速失败，重试成本很低。
    static func isTransientFailure(_ error: Error) -> Bool {
        AgentFailureClassifier.classify(error).isRetryable
    }

    /// 记录一次流式请求是否已经产出过可见内容。
    /// 只有「一个 delta 都还没产出就失败」的瞬时故障才值得重试，
    /// 避免把已经展示给用户的流式文本再打一遍。
    private actor StreamProgress {
        private(set) var hasOutput = false
        func note(_ delta: String) {
            if !delta.isEmpty { hasOutput = true }
        }
    }

    /// 流式生成一轮模型回答：逐 delta 推送增量，同时收集文本与原生工具调用。
    ///
    /// 与 `completeWithRetry` 对齐的容错：
    /// - 瞬时故障（5xx / 429 / 网络抖动 / 空响应 / 截断 JSON）且尚未产出任何 delta → 补一次重试；
    /// - 单轮超时 / 用户取消 → 不再重试，直接上抛（超时降级到本地能力，取消按「已取消」处理）。
    private static func streamWithRetry(
        provider: any AIProvider,
        request: AICompletionRequest,
        timeout: TimeInterval,
        onAnswerDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        let progress = StreamProgress()
        let consume: (any AIProvider, AICompletionRequest) async throws -> StreamOutcome = { provider, request in
            try await streamOnce(
                provider: provider,
                request: request,
                timeout: timeout,
                onAnswerDelta: { delta in
                    await progress.note(delta)
                    await onAnswerDelta(delta)
                },
                onReasoningDelta: { delta in
                    await progress.note(delta)
                    await onReasoningDelta(delta)
                }
            )
        }
        do {
            return try await consume(provider, request)
        } catch {
            // 取消 / 超时 / 确定性错误一律不重试，与 completeWithRetry 保持一致。
            guard Self.isTransientFailure(error), await progress.hasOutput == false else {
                throw error
            }
            try await Task.sleep(nanoseconds: UInt64(transientRetryDelay * 1_000_000_000))
            return try await consume(provider, request)
        }
    }

    /// 流式请求正常结束但没有任何可见文本/工具调用时，补发一次非流式请求。
    ///
    /// NewAPI/本地中转常见两类兼容差异：SSE 通道提前结束，或模型把内容只放在
    /// reasoning 通道。后者先做一次无工具、关闭 reasoning 的最终回答修复；若仍
    /// 为空则明确失败，绝不静默把思考链混进正文。
    private static func streamWithFallback(
        provider: any AIProvider,
        request: AICompletionRequest,
        timeout: TimeInterval,
        onAnswerDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        let streamed = try await streamWithRetry(
            provider: provider,
            request: request,
            timeout: timeout,
            onAnswerDelta: onAnswerDelta,
            onReasoningDelta: onReasoningDelta
        )
        guard streamed.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              streamed.toolCalls.isEmpty
        else {
            return streamed
        }

        // A reasoning-only stream is already a completed model turn from the
        // provider's point of view. Do not give that turn another opportunity
        // to emit a native tool call: the recovery path must only ask for a
        // user-visible answer with tools and reasoning disabled. Otherwise a
        // compatible gateway can turn a missing answer into an unexpected
        // mutation on the fallback round.
        let reasoningOnly = !streamed.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let fallbackRequest = reasoningOnly
            ? finalAnswerRepairRequest(from: request)
            : request
        let response = try await completeWithRetry(provider: provider, request: fallbackRequest)
        var fallback = streamed
        fallback.answerText = response.content
        // Never hand tool calls back to ToolLoop after a reasoning-only turn.
        // The fallback request has no tools, but keep this invariant even for
        // providers that ignore that request contract.
        fallback.toolCalls = reasoningOnly ? [] : (response.toolCalls ?? [])
        fallback.webCitations = response.webCitations ?? streamed.webCitations
        fallback.inputTokens = response.inputTokens ?? streamed.inputTokens
        fallback.outputTokens = response.outputTokens ?? streamed.outputTokens
        if fallback.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let reasoning = response.reasoning,
           !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fallback.reasoningText = reasoning
            await onReasoningDelta(reasoning)
        }
        if !response.content.isEmpty {
            await onAnswerDelta(response.content)
        }

        if fallback.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallback.toolCalls.isEmpty {
            let repair = try await completeWithRetry(
                provider: provider,
                request: finalAnswerRepairRequest(from: request)
            )
            let repairedAnswer = repair.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repairedAnswer.isEmpty, repair.toolCalls?.isEmpty != false else {
                throw AIProviderError.malformedResponse(
                    detail: "模型未产生可显示正文，且最终回答修复未产生可显示正文",
                    retryable: false
                )
            }
            fallback.answerText = repair.content
            fallback.inputTokens = repair.inputTokens ?? fallback.inputTokens
            fallback.outputTokens = repair.outputTokens ?? fallback.outputTokens
            await onAnswerDelta(repair.content)
        }
        return fallback
    }

    private static func finalAnswerRepairRequest(
        from request: AICompletionRequest
    ) -> AICompletionRequest {
        var transcript = request.transcript
        transcript.append(.userText("基于当前上下文，只输出给用户的最终答案。不要重新调用工具，不要输出思考过程。"))
        return AICompletionRequest(
            model: request.model,
            transcript: transcript,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            tools: nil,
            toolChoice: AIToolChoice.none,
            hostedTools: nil,
            outputFormat: .text,
            reasoning: AIReasoningConfiguration(
                mode: .disabled,
                effort: request.reasoning?.effort ?? .low
            )
        )
    }

    /// 单次流式消费（带单轮超时）：遍历 provider 流事件，拼装 `StreamOutcome`。
    ///
    /// 取消语义：消费方任务被取消时，`AsyncThrowingStream` 的 for-await 会迅速结束
    /// （底层 `onTermination` 同步取消网络请求），这里再显式补一个取消检查，
    /// 把「用户点停止」干净地映射成 `CancellationError`，而不是当作正常收尾继续跑工具。
    private static func streamOnce(
        provider: any AIProvider,
        request: AICompletionRequest,
        timeout: TimeInterval,
        onAnswerDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        try await withTimeout(timeout) {
            var outcome = StreamOutcome()
            for try await event in provider.stream(request) {
                if Task.isCancelled { throw CancellationError() }
                switch event {
                case .started:
                    break
                case let .reasoningDelta(text):
                    outcome.reasoningText += text
                    await onReasoningDelta(text)
                case let .answerDelta(text):
                    outcome.answerText += text
                    await onAnswerDelta(text)
                case let .unknownDelta(text):
                    // Compatibility providers may not be able to classify a
                    // text delta. Preserve it on the answer channel instead
                    // of silently losing the user's response; built-in
                    // Chat/Responses codecs already keep tool-argument
                    // fragments out of this event.
                    guard !text.isEmpty else { break }
                    outcome.answerText += text
                    await onAnswerDelta(text)
                case let .toolCall(call):
                    outcome.toolCalls.append(call)
                case let .webCitations(citations):
                    outcome.webCitations.append(contentsOf: citations)
                case let .usage(input, output):
                    outcome.inputTokens = input
                    outcome.outputTokens = output
                case .completed:
                    return outcome
                }
            }
            if Task.isCancelled { throw CancellationError() }
            return outcome
        }
    }

    /// 把一段流式文本增量推给界面：以 `.streaming` 消息发出，
    /// 由 AgentCoordinator 累加进当前 in-flight 流式气泡。
    private static func emitStreamingDelta(
        _ delta: String,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void
    ) async {
        guard !delta.isEmpty else { return }
        await emit(AgentChatMessage(role: .assistant, messages: [.streaming(delta)]))
    }

    /// Reasoning has its own transient channel. AgentCoordinator keeps this
    /// out of SessionStore and removes it when the active run completes.
    private static func emitStreamingReasoningDelta(
        _ delta: String,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void
    ) async {
        guard !delta.isEmpty else { return }
        await emit(AgentChatMessage(role: .assistant, messages: [.reasoning(delta)]))
    }

    /// Builds the projection of a local tool result that is safe to send to
    /// the configured Provider. Local execution and local presentation retain
    /// the complete result; privacy settings only redact the external model
    /// boundary. This keeps local tools usable even when the user has opted
    /// out of sending a category of personal data to a Provider.
    private static func providerToolResultText(
        callName: String,
        descriptor: ToolDescriptor,
        result: ToolResult,
        context: Context,
        targetCount: Int?
    ) -> String {
        let missingCategories = ToolPrivacyPolicy.missingDisclosureCategories(
            for: descriptor,
            payload: result.payload,
            permissions: context.privacyPermissions
        )
        let status = result.success ? "成功" : "失败"

        guard missingCategories.isEmpty else {
            let detail = result.success
                ? "本地执行已完成；详细结果按隐私设置未发送给 Provider。"
                : "本地执行失败；详细结果按隐私设置未发送给 Provider。"
            return "（工具执行结果）\(callName): \(status) - \(detail)"
        }

        var text = "（工具执行结果）\(callName): \(status) - \(result.summary)"
        if let payload = result.payload {
            let detail = messageTextForModel(payload, targetCount: targetCount)
            if !detail.isEmpty {
                text += "；详情：\(detail)"
            }
        }
        return text
    }


    /// 把结构化消息（卡片）转成模型可读的文本，使工具结果中的歌曲清单可见。
    /// 可见窗口是 targetCount 感知的：用户要求 N 首时，模型至少能看到
    /// max(N, 10) 个真实候选（单次上下文最多 50 个）。这个窗口只限制单批
    /// 回灌，不限制整个任务的目标数量；模型可以通过分页或排除 ID 继续取得后续结果。
    static func messageTextForModel(_ message: AgentMessage, targetCount: Int? = nil) -> String {
        let visibleCount = min(max(targetCount ?? 10, 10), 50)
        let trackLine = { (cards: [TrackCard]) -> String in
            let shown = cards.prefix(visibleCount)
            let list = shown.map { "《\($0.title)》-\($0.artistName)（\($0.globalID.description)）" }.joined(separator: "、")
            if cards.count > visibleCount {
                return "\(list)…本批工具结果共 \(cards.count) 首；当前上下文仅投影前 \(visibleCount) 首。这是单批上下文窗口，不是任务数量上限。如果用户任务需要更多歌曲，请继续使用分页、excludeTrackIDs 或后续查询取得下一批，不要要求用户缩小原任务。"
            }
            return list
        }
        switch message {
        case let .text(value):
            return value
        case let .trackCards(cards):
            return "歌曲清单：\(trackLine(cards))"
        case let .albumCards(cards):
            let shown = cards.prefix(visibleCount)
            let list = shown.map { "《\($0.title)》-\($0.artistName)（\($0.globalID.description)）" }.joined(separator: "、")
            let suffix = cards.count > visibleCount ? "…等 \(cards.count) 张" : ""
            return "专辑清单：\(list)\(suffix)"
        case let .playlistCards(cards):
            return "歌单清单：" + cards.map {
                "\($0.name) [playlistID=\($0.globalID.description)]"
            }.joined(separator: "、")
        case let .artistCards(cards):
            return "艺术家清单：" + cards.map {
                "\($0.name) [artistID=\($0.globalID.description)]"
            }.joined(separator: "、")
        case let .webSources(sources):
            return sources.prefix(5).map { "来源：\($0.title)（\($0.url.absoluteString)）\n\($0.snippet)" }.joined(separator: "\n")
        case let .playlistProposal(name, tracks):
            return "歌单提案「\(name)」：\(trackLine(tracks))"
        case let .actionPreview(title, detail):
            return "操作预览：\(title)（\(detail)）"
        case let .error(value):
            return "错误：\(value)"
        case let .streaming(value):
            return value
        case .reasoning, .toolProgress, .confirmation:
            return ""
        }
    }

    private static func isSearchCapability(_ name: String) -> Bool {
        AgentTaskWorkingSet.isSearchTool(name)
            || ["web_search", "web_fetch"].contains(name)
    }

    /// Stable evidence identity used only for per-capability search
    /// convergence.  A nil return means this tool does not yield a result set
    /// that can be compared, so it must not be disabled by this mechanism.
    private static func searchEvidenceIDs(from payload: AgentMessage?) -> Set<String>? {
        guard let payload else { return nil }
        switch payload {
        case let .trackCards(cards):
            return Set(cards.map { $0.globalID.description })
        case let .albumCards(cards):
            return Set(cards.map { $0.globalID.description })
        case let .webSources(sources):
            return Set(sources.map { WebSource.canonicalURL($0.url).absoluteString })
        case let .playlistProposal(_, tracks):
            return Set(tracks.map { $0.globalID.description })
        default:
            return nil
        }
    }

    /// 文本 ACTION 协议解码：把 JSON 值投影为旧协议使用的字符串（兼容入口）。
    /// Provider native tool call 不经过此转换，canonical runtime arguments 仍是 AIJSONValue。
    /// 结果可直接交给 `structuredToolCall` 还原为 canonical AIJSONValue。
    public static func decodeTextualActions(_ content: String) -> [(tool: String, args: [String: AIJSONValue])] {
        parseActions(from: content).map { item in
            let tool = item.tool
            let descriptor = AgentToolRegistry.descriptor(for: tool)
            var arguments = item.args.mapValues(AIJSONValue.string)
            if let descriptor {
                arguments = Self.projectLegacyArguments(item.args, descriptor: descriptor, fallback: arguments)
            }
            return (tool, arguments)
        }
    }

    private static func parseActions(from content: String) -> [(tool: String, args: [String: String])] {
        var results: [(String, [String: String])] = []
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ACTION:") else { continue }
            let jsonString = String(trimmed.dropFirst("ACTION:".count)).trimmingCharacters(in: .whitespaces)
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tool = obj["tool"] as? String else { continue }
            var args: [String: String] = [:]
            if let rawArgs = obj["args"] as? [String: Any] {
                for (key, value) in rawArgs {
                    args[key] = textArgumentString(value)
                }
            }
            results.append((tool, args))
        }
        return results
    }

    /// ACTION 文本协议的兼容边界：将 JSON 值投影为旧协议使用的字符串。
    /// Provider native tool call 不经过此转换，canonical runtime arguments 仍是 AIJSONValue。
    private static func textArgumentString(_ value: Any) -> String {
        if let value = value as? String { return value }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        if let value = value as? NSNumber { return value.stringValue }
        return String(describing: value)
    }

    /// run-scoped Capability 环境快照：System Prompt / capabilities_get 共用同一份，
    /// 避免各处采集不同状态导致能力声明漂移。
    /// 当前任务相关 Capability（System Prompt 只注入这些；conversation 注入全部）。
    static func relevantCapabilityIDs(
        for intent: AgentTaskIntent,
        semantics: AgentRequestSemantics
    ) -> [String]? {
        switch intent {
        case .conversation:
            return nil
        case .musicDiscovery:
            return ["music_recommendation", "catalog_search", "playlist_construction"]
        case .playlistManagement:
            return ["playlist_mutation", "playlist_construction", "catalog_search"]
        case .playbackControl:
            return ["playback_control", "catalog_search"]
        case .librarySearch, .playbackQuery, .queueQuery, .playlistQuery:
            return ["catalog_search"]
        case .queueManagement:
            return ["queue_mutation", "catalog_search"]
        case .libraryManagement:
            if semantics.isRecommendationIndex {
                return ["recommendation_index_build", "recommendation_index_status", "recommendation_index_browse", "library_analysis"]
            }
            return ["library_analysis", "catalog_search"]
        case .musicAppreciation:
            return ["music_appreciation"]
        default:
            return nil
        }
    }

    static func capabilityEnvironment(
        provider: (any AIProvider)?,
        catalog: LocalCatalogStore,
        systemService: (any AgentSystemService)?,
        webService: (any AgentWebService)?,
        activeServer: Bool
    ) -> AgentCapabilityEnvironment {
        // Provider 自带 Hosted Web Search / Fetch 时，即使没有 App 自有
        // AgentWebService，联网能力仍真实可用——避免模型自省误报不可用。
        let providerCaps = provider?.capabilities
        return AgentCapabilityEnvironment(
            providerAvailable: provider != nil,
            catalogAvailable: true,
            activeServer: activeServer,
            webAvailable: webService != nil,
            webSearchAvailable: webService != nil || (providerCaps?.supportsHostedWebSearch ?? false),
            webFetchAvailable: webService != nil || (providerCaps?.supportsHostedWebFetch ?? false),
            downloadServiceAvailable: systemService != nil,
            systemServiceAvailable: systemService != nil
        )
    }

    public static func systemPrompt(
        context: Context,
        tools: [ToolDescriptor],
        nativeToolCalling: Bool,
        goal: String = "",
        workflowInstruction: String? = nil,
        environment: AgentCapabilityEnvironment = AgentCapabilityEnvironment(providerAvailable: true),
        relevantCapabilityIDs: [String]? = nil,
        awarenessTools: [ToolDescriptor]? = nil,
        activeSkillID: String? = nil,
        authorizedOperations: Set<ToolAuthorizationOperation>? = nil
    ) -> String {
        return SystemPromptBuilder.build(
            context: context,
            tools: tools,
            nativeToolCalling: nativeToolCalling,
            goal: goal,
            workflowInstruction: workflowInstruction,
            environment: environment,
            relevantCapabilityIDs: relevantCapabilityIDs,
            awarenessTools: awarenessTools,
            activeSkillID: activeSkillID,
            authorizedOperations: authorizedOperations
        )
    }

    private static func descriptorsWithCustomTools(_ customDescriptors: [ToolDescriptor]) -> [ToolDescriptor] {
        var descriptors = AgentToolRegistry.all
        for descriptor in customDescriptors where !descriptors.contains(where: { $0.name == descriptor.name }) {
            descriptors.append(descriptor)
        }
        return descriptors
    }

    /// Keep registry refresh and task-required-tool retention aligned with
    /// ToolSelector. Neither path may turn a discovery-only recommendation
    /// into a mutation-capable model turn by appending rows directly. This is
    /// shortlist relevance, not an execution permission check: an explicitly
    /// requested reversible mutation remains visible, while destructive work
    /// still follows its descriptor-owned confirmation policy.
    private static func shouldExposeDescriptorForPlan(
        _ descriptor: ToolDescriptor,
        semantics: AgentRequestSemantics,
        activeSkillID: String?
    ) -> Bool {
        guard descriptor.isVisible(toSkillID: activeSkillID) else { return false }
        guard descriptor.permission != .readOnly else { return true }
        // Fixed Skills own their mutation calls; the model surface remains
        // read-only throughout the workflow, including a registry refresh.
        guard activeSkillID == nil else { return false }
        guard semantics.isExplicitMutation else { return false }
        guard !semantics.requestedOperations.isEmpty else { return true }
        guard let operation = descriptor.authorizationOperation else { return true }
        return semantics.requestedOperations.contains(operation)
    }

    /// 把完整会话历史转成模型可用的消息列表。历史不再按固定轮数截断，
    /// 错误、进度、确认和流式内容以可读摘要保留；最终 token 级裁剪统一由
    /// ContextManager 在发送前按 Provider 的真实上下文窗口执行。
    private static func convertHistory(
        _ history: [AgentChatMessage],
        currentUserText: String,
        permissions: AIPrivacyPermissions
    ) -> [AIMessage] {
        AgentHistoryPolicy.modelMessages(from: history, for: currentUserText, permissions: permissions)
    }

    private static func descriptor(named name: String, in descriptors: [ToolDescriptor]) -> ToolDescriptor? {
        descriptors.first { descriptor in
            descriptor.name == name || descriptor.aliases.contains(name)
        }
    }

    /// Resolve action-specific risk for the retained `music_download` text
    /// compatibility call. The legacy umbrella descriptor is intentionally
    /// reversible so ordinary search/download/history calls stay frictionless,
    /// but its `history_clean` action is the canonical destructive operation
    /// and must still pass through ToolLoop's visible confirmation path.
    private static func descriptor(for call: LoopToolCall, in descriptors: [ToolDescriptor]) -> ToolDescriptor? {
        guard let resolved = descriptor(named: call.name, in: descriptors) else { return nil }
        guard call.name == "music_download",
              call.stringArguments["action"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "history_clean"
        else {
            return resolved
        }
        return descriptor(named: "music_download_history_clean", in: descriptors) ?? resolved
    }

    private static func effectiveToolTimeout(_ descriptor: ToolDescriptor, requested: TimeInterval) -> TimeInterval {
        max(0.1, min(requested, descriptor.executionProfile.timeout))
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = TimeoutGate<T>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let operation = Task {
                    do {
                        gate.resolve(.success(try await body()))
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                let timeout = Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    gate.resolve(.failure(AgentRunnerError.timeout), cancellingOperation: true)
                }
                gate.attach(operation: operation, timeout: timeout)
            }
        }, onCancel: {
            gate.cancelForCaller()
        })
    }
}

/// Swift 任务取消是协作式的。这个门闩保证调用方在期限到达时立即恢复，晚到的
/// 非协作工具结果会被丢弃；写操作在 Runner 中相应标记为 indeterminate。
private final class TimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var callerCancelled = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let cancelled = callerCancelled
        if !cancelled {
            self.continuation = continuation
        }
        lock.unlock()
        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    func attach(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = continuation == nil || callerCancelled
        if !shouldCancel {
            self.operation = operation
            self.timeout = timeout
        }
        lock.unlock()
        if shouldCancel {
            operation.cancel()
            timeout.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>, cancellingOperation: Bool = false) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let operation = self.operation
        let timeout = self.timeout
        self.operation = nil
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        if cancellingOperation { operation?.cancel() }
        continuation?.resume(with: result)
    }

    func cancelForCaller() {
        lock.lock()
        callerCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let operation = self.operation
        let timeout = self.timeout
        self.operation = nil
        self.timeout = nil
        lock.unlock()
        operation?.cancel()
        timeout?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

public enum AgentRunnerError: Error, Sendable, LocalizedError {
    case timeout

    public var errorDescription: String? {
        switch self {
        case .timeout:
            "模型在限定时间内没有完成本轮响应。"
        }
    }
}
