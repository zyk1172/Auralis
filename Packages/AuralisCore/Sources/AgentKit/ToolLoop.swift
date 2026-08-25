import AIKit
import Domain
import Foundation
import LocalCatalog

/// 通用对话工具循环（permissive direct execution）。
///
/// 流程：用户文本 →（可选 LLM 规划）→ 本地工具执行 → 结果回传 → UI 渲染。
/// 设计准则：已注册的普通音乐工具默认全部允许；Intent 只是路由提示，不是能力边界；
/// 用户明确要求且目标唯一时直接执行；只有工具元数据明确标出的不可逆高风险操作
/// （删除歌单、清空记忆、删除技能）需要一次用户批准。
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
            allowsMetadata: Bool = true,
            allowsLyrics: Bool = false,
            allowsHistory: Bool = false,
            memories: [AgentMemoryEntry] = [],
            skills: [AgentSkillEntry] = [],
            mutationResourceLeaseRegistry: MutationResourceLeaseRegistry = MutationResourceLeaseRegistry(),
            recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry(),
            customToolRegistry: CustomToolRegistry = .shared
        ) {
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
            self.allowsMetadata = allowsMetadata
            self.allowsLyrics = allowsLyrics
            self.allowsHistory = allowsHistory
            self.memories = memories
            self.skills = skills
            self.mutationResourceLeaseRegistry = mutationResourceLeaseRegistry
            self.recommendationIndexExecutionRegistry = recommendationIndexExecutionRegistry
            self.customToolRegistry = customToolRegistry
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

    /// 一次流式模型生成的结果：累积文本 + 收集到的原生工具调用 + token 用量。
    /// 与 `AICompletionResponse` 对应，但由 `provider.stream()` 的增量事件拼装而成。
    private struct StreamOutcome: Sendable {
        var text = ""
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
    }

    private static func parallelResultKey(for call: LoopToolCall, index: Int) -> String {
        call.id ?? "parallel-\(index)"
    }

    private enum ToolArgumentParseResult {
        case success([String: AIJSONValue])
        case malformed(rawLength: Int)
    }

    /// 执行一次用户请求。
    /// - Parameters:
    ///   - provider: 可用时为 LLM 规划；为 nil 时走本地规则降级。
    ///   - toolTimeout: 单个工具执行的最长等待时间；超时以结构化失败回灌模型，不终止任务。
    ///   - confirm: 仅在不可逆高风险工具实际执行前调用；其它工具不会经过该回调。
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
        // authorization 全部来自同一个分析结果，禁止各层重新解释用户文本。
        // ConversationEngine 等上层可传入已构建的 plan，避免重复分析。
        let plan = requestPlan ?? AgentRequestPlan.build(
            userText: userText,
            history: history,
            explicitIntent: intent,
            explicitPolicy: policy,
            authorizationContext: authorizationContext,
            executionLineage: executionLineage,
            initialTaskState: initialTaskState,
            failClosedAuthorization: executionLineage == nil && authorizationContext == nil
        )
        let requestSemantics = plan.semantics
        let resolvedIntent = plan.intent
        let resolvedPolicy = plan.policy
        // ConversationEngine/AgentCoordinator select this at the task
        // boundary. A direct low-level caller that omits it is fail-closed;
        // the ToolLoop must never turn its current text into consent.
        let resolvedAuthorization = plan.authorization
        // Only AgentCoordinator can grant a live mutation capability. Direct
        // compatibility callers remain able to use read-only tools but fail
        // closed for every side effect.
        let resolvedExecutionLease: ToolExecutionLease
        if let executionLease, executionLease.runID == runID {
            resolvedExecutionLease = executionLease
        } else {
            resolvedExecutionLease = .revoked(runID: runID)
        }
        // Materialize declarative tools once at the run boundary. The same
        // snapshot is used by selector, provider schema, tool_search and
        // ToolRuntime so discovery cannot advertise a different set than the
        // executor can actually run.
        var availableToolDescriptors = AgentToolRegistry.all
        let customDescriptors = await context.customToolRegistry.modelDescriptors()
        for descriptor in customDescriptors where !availableToolDescriptors.contains(where: { $0.name == descriptor.name }) {
            availableToolDescriptors.append(descriptor)
        }
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
        // 不支持的能力必须 fail-fast：注册表里根本没有对应 canonical capability
        // 时（例如“删除曲婉婷的所有歌曲”没有服务器曲库文件删除工具），不能让模型
        // 无限 tool_search 或长期停留在“正在回复…”。
        if workflowRoute.kind == .generic,
           let unsupported = AgentCapabilityCoverage.unsupportedReason(
               text: userText,
               semantics: requestSemantics,
               descriptors: availableToolDescriptors
           ) {
            await emit(AgentChatMessage(role: .assistant, messages: [.error(unsupported)]))
            return
        }
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
                let message = "推荐索引需要可用的 AI Provider；当前没有发起离线音乐搜索或其他替代执行。"
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
               requestSemantics.domain != .recommendation,
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
        availableToolDescriptors: [ToolDescriptor],
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
        var selectedTools = ToolSelector.select(plan: plan, all: availableToolDescriptors)
        let directReadToolName = plan.semantics.directReadCapability?.toolName
        let effectiveAuthorization = sideEffectAuthorization
        let nativeMode = provider.supportsToolCalling
            && provider.capabilities.toolMode != .none
            && provider.capabilities.toolMode != .textualToolProtocol
        // Only a protocol which does not declare native tools stays text-only.
        // Capability diagnostics are observational and must never turn a
        // declared Chat/Responses/Messages provider into a different protocol.
        if provider.capabilities.toolMode == .none {
            selectedTools = []
        }
        // 普通聊天同样使用行为收敛看门狗：不再允许无限轮次。
        var convergence = AgentConvergenceTracker()
        var toolChoice: AIToolChoice? = nativeMode && provider.capabilities.supportsToolChoice ? .auto : nil
        var conversation = [AIMessage(
            role: .system,
            content: systemPrompt(
                context: context,
                tools: selectedTools,
                nativeToolCalling: nativeMode
            )
        )]
        conversation.append(contentsOf: convertHistory(history, currentUserText: userText))
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
        // Search exhaustion is per capability, not a global tool-call cap.
        // It stops a backend that keeps returning no new evidence while all
        // unrelated tools and ordinary conversation remain available.
        var searchEvidenceByTool: [String: Set<String>] = [:]
        // Generic chat has no task completion evaluator, but read-only music
        // results still need the same buffered UI presentation contract as
        // deterministic tasks: collect cards during tool turns and emit them
        // once alongside the natural final answer.
        var presentation = AgentPresentationState()
        while true {
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
                hostedTools: hostedTools.isEmpty ? nil : hostedTools
            )
            let outcome: StreamOutcome
            do {
                outcome = try await streamWithFallback(provider: provider, request: request, timeout: roundTimeout) { delta in
                    await emitStreamingDelta(delta, emit: emit)
                }
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

            let streamedText = outcome.text
            let nativeCalls = nativeMode ? outcome.toolCalls : []
            // Native requests only accept provider-native tool calls. ACTION is
            // decoded exclusively when the request started in textual mode.
            let textActions = !nativeMode && nativeCalls.isEmpty ? parseActions(from: streamedText) : []
            if nativeCalls.isEmpty, textActions.isEmpty {
                let answer = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                          !Self.isSearchCapability(call.name),
                          let descriptor = Self.descriptor(named: call.name, in: availableToolDescriptors)
                    else { return false }
                    return descriptor.permission == .readOnly
                        && descriptor.parallelSafe
                        && !descriptor.confirmationPolicy.requiresExplicitUserApproval
                }
            if parallelEligible {
                let executorContext = ToolExecutorContext(
                    bridge: bridge,
                    catalog: catalog,
                    serverID: context.serverID,
                    systemService: systemService,
                    externalMusicService: externalMusicService,
                    allowsLyrics: context.allowsLyrics,
                    providerCapabilities: provider.capabilities,
                    webService: webService,
                    authorizationContext: effectiveAuthorization,
                    activeSkillID: nil,
                    executionAuthority: nil,
                    executionLease: executionLease,
                    resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                    recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                    customToolRegistry: context.customToolRegistry,
                    availableToolDescriptors: availableToolDescriptors
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
                guard let descriptor = Self.descriptor(named: call.name, in: availableToolDescriptors) else {
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
                switch effectiveAuthorization.decision(for: descriptor, call: executableCall) {
                case .allowed:
                    convergence.recordAuthorizationAllowance()
                    break
                case let .denied(reason):
                    convergence.recordAuthorizationDenial()
                    let text = "（工具执行结果）\(call.name)：失败 - \(reason)"
                    resultMessages.append(toolResultMessage(callID: call.id, content: text, native: nativeMode))
                    if let stopReason = convergence.stopReason(under: convergencePolicy) {
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(stopReason.userMessage)]))
                        return
                    }
                    continue
                }

                if descriptor.confirmationPolicy.requiresExplicitUserApproval {
                    let pending = Self.pendingConfirmation(
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
                            allowsLyrics: context.allowsLyrics,
                            providerCapabilities: provider.capabilities,
                            webService: webService,
                            authorizationContext: authorizationForCall,
                            executionLease: executionLease,
                            resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                            recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                            customToolRegistry: context.customToolRegistry,
                            availableToolDescriptors: availableToolDescriptors,
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

                var resultText = "（工具执行结果）\(call.name): \(result.success ? "成功" : "失败") - \(result.summary)"
                if let payload = result.payload {
                    let detail = messageTextForModel(payload)
                    if !detail.isEmpty { resultText += "；详情：\(detail)" }
                }
                resultText = AIContentTrustBoundary.wrap(resultText, trustLevel: result.trustLevel)
                if call.name == "lyrics_get", !context.allowsLyrics {
                    resultText = "（工具执行结果）lyrics_get：成功 - 歌词已按隐私设置隐藏。"
                }
                resultText = ContextManager.truncateToolResult(resultText, limit: descriptor.maxResultCharacters)
                // 搜索收敛（generic chat 与 deterministic task 共用同一 tracker）：
                // 结果返回后判定是否产生新 evidence，按工具独立累计 streak，达阈值移除工具。
                // 失败/空结果也视为“没有新证据”，防止反复失败不收敛。
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
                    Self.expandToolsFromSearch(
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
        availableToolDescriptors: [ToolDescriptor],
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
        // 任务中途的新工具需求通过 tool_search（授权过滤）与已执行工具补入。
        let requestTimeout = roundTimeout
        let effectiveAuthorization = sideEffectAuthorization
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
            // Skill 授权子集验证：Skill 只能消费用户原始请求已经明确授权的 operation。
            // requiredOperations ⊄ allowedOperations → 不激活（Skill 自己不能扩权），
            // 走普通 loop；Runtime 仍会对任何 mutation 做 exact authorization。
            if let skill = activeSkill,
               !skill.requiredOperations.isSubset(of: effectiveAuthorization.allowedOperations) {
                activeSkill = nil
            }
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
        // result_present_tracks + tool_search）。所有 mutation——包括授权操作对应的
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
        var privacy = AIPrivacyPermissions()
        privacy.allowsMetadata = context.allowsMetadata
        privacy.allowsLyrics = context.allowsLyrics
        privacy.allowsPlaybackHistory = context.allowsHistory

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

        var conversation = AgentContextBuilder.build(
            systemPrompt: Self.systemPrompt(
                context: context,
                tools: selectedTools,
                nativeToolCalling: nativeMode,
                goal: taskState.goal,
                workflowInstruction: activeSkill?.instructions,
                providerAvailable: true
            ),
            task: taskState,
            facts: [],
            history: Self.convertHistory(history, currentUserText: userText),
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
        // 已提示过模型调用 result_present_tracks（只 repair 一次，避免无限循环）。
        var didRequestFinalSelection = false
        // 任务工作集：任务级结果缓存、重复调用保护、候选/队列统计、诊断轨迹。
        var ws = AgentTaskWorkingSet(
            targetQueueCount: AgentTaskWorkingSet.inferredTargetQueueCount(from: userText)
        )
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
        // 行为收敛看门狗：普通 Agent fail-fast；Recommendation Index 走专用
        // Runtime 不受影响；legacy AgentRunner 兼容面使用宽松预算。
        var convergence = AgentConvergenceTracker()
        // Mutation / deterministic 任务的模型正文是 provisional：完成条件满足前
        // 不实时上屏，避免“已经替换好了”在真实副作用成功前误导用户。
        let buffersProvisionalText = Self.policyRequiresToolExecution(policy)

        while true {
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
            if let stopReason = convergence.stopReason(under: policy.convergence) {
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
                    if let tool = byName[name] {
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
                    hostedTools: hostedTools.isEmpty ? nil : hostedTools
                )
                do {
                    // 确定性 mutation 任务：模型正文是 provisional，工具成功前不
                    // 实时上屏（避免“已经替换好了”等未经核实的成功声明误导用户）。
                    // 完成时最终 `.text(reply)` 才会提交；失败/继续时这些文字被丢弃。
                    outcome = try await streamWithFallback(provider: provider, request: request, timeout: requestTimeout) { delta in
                        if !buffersProvisionalText {
                            await Self.emitStreamingDelta(delta, emit: emit)
                        }
                    }
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
            let streamedText = outcome.text
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
                completionFactsSatisfied = AgentCompletionEvaluator.factsSatisfied(state: taskState, policy: policy)
            }

            // 真实工具已经完成时，先结算事实，再处理模型是否返回最终文字。
            // 许多中转在 tool result 后只返回 reasoning 或空 content；这不应覆盖成功状态。
            if nativeCalls.isEmpty,
               textActions.isEmpty,
               skillInternalCall == nil,
               completionFactsSatisfied,
               !(intent == .musicDiscovery
                    && !didRequestFinalSelection
                    && !presentation.candidateOrder.isEmpty
                    && presentation.resolvedFinalCards.isEmpty
                    && presentation.disambiguationTracks.isEmpty) {
                let reply = Self.formatAssistantReply(streamedText.trimmingCharacters(in: .whitespacesAndNewlines))
                if activeSkill != nil {
                    Self.mergeSkillFacts(activeSkill, into: &taskState)
                    Self.markSkillCompleted(state: &taskState)
                } else {
                    _ = AgentCompletionEvaluator.markFactsSatisfied(state: &taskState, policy: policy)
                }
                diagnostics.completionResult = taskState.completed ? "satisfied" : "pending"
                diagnostics.noProgressCount = convergence.noProgressStreak
                taskState.diagnostics = diagnostics
                await state(taskState)
                if intent == .librarySearch || intent == .libraryManagement {
                    presentation.applySearchFallback()
                }
                // 推荐任务在模型已经完成候选查询、但只返回空/纯 reasoning 时，仍须把有限的
                // 确定性结果落到最终展示；候选池不能直接在更早的错误分支中泄漏给用户。
                if intent == .musicDiscovery,
                   didRequestFinalSelection,
                   presentation.resolvedFinalCards.isEmpty,
                   !presentation.candidateOrder.isEmpty,
                   presentation.disambiguationTracks.isEmpty {
                    let target = max(ws.targetQueueCount ?? 5, 1)
                    let chosen = Array(presentation.candidateOrder.prefix(target))
                    let cards = chosen.compactMap { presentation.candidateTracks[$0] }
                    if !cards.isEmpty {
                        presentation.setFinalTracks(cards)
                        taskState.selectedIDs = Set(cards.map { $0.globalID.description })
                    }
                }
                presentation.applyAlbumFallbackIfNeeded()
                if let finalMessage = presentation.finalMessage() {
                    await emit(AgentChatMessage(role: .assistant, messages: [finalMessage]))
                }
                let finalText = reply.isEmpty
                    ? (activeSkill != nil
                        ? Self.skillCompletionMessage(activeSkill)
                        : Self.deterministicCompletionSummary(policy: policy, presentation: presentation))
                    : reply
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
                        repairAttempts: completionRepairAttempts
                    )
                }
                switch completionDecision {
                case .accept:
                    // 纯推荐任务（musicDiscovery）：已有候选但既没有显式 final（result_present_tracks）
                    // 也没有真实 queue/playlist 副作用时，先要求模型调用 result_present_tracks 选择
                    // 真正最终推荐的歌曲，而不是让用户看到“零卡片”或把候选当结果。只 repair 一次。
                    if intent == .musicDiscovery,
                       !didRequestFinalSelection,
                       !presentation.candidateOrder.isEmpty,
                       presentation.resolvedFinalCards.isEmpty,
                       presentation.disambiguationTracks.isEmpty {
                        didRequestFinalSelection = true
                        completionRepairAttempts += 1
                        let instruction = "你已经取得候选歌曲，但还没有确定最终展示结果。请调用 result_present_tracks(trackIDs=[真正最终推荐给主人的歌曲]) 一次；只把最终选定的歌曲传入，不要把整个候选池传入。"
                        taskState.pendingActions = [instruction]
                        taskState.status = .waitingForTool
                        taskState.updatedAt = .now
                        await state(taskState)
                        conversation.append(AIMessage(role: .assistant, content: reply))
                        conversation.append(AIMessage(role: .user, content: "系统完成条件校验：\(instruction)"))
                        continue
                    }
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
                    // 纯推荐任务：repair 一次后模型仍没调用 result_present_tracks 时，
                    // Runtime 做确定性兜底——按用户要求数量（默认 5）从候选里取，绝不泄漏整个候选池。
                    if intent == .musicDiscovery,
                       presentation.resolvedFinalCards.isEmpty,
                       !presentation.candidateOrder.isEmpty,
                       presentation.disambiguationTracks.isEmpty {
                        let target = max(ws.targetQueueCount ?? 5, 1)
                        let chosen = Array(presentation.candidateOrder.prefix(target))
                        let cards = chosen.compactMap { presentation.candidateTracks[$0] }
                        if !cards.isEmpty {
                            presentation.setFinalTracks(cards)
                            taskState.selectedIDs = Set(cards.map { $0.globalID.description })
                        }
                    }
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

                guard let descriptor = Self.descriptor(named: call.name, in: availableToolDescriptors) else {
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
                   call.origin != .skillForced {
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
                    if let stopReason = convergence.stopReason(under: policy.convergence) {
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
                // 搜索类工具的重复调用同样记为「无新结果」，连续多次后触发停止搜索。
                if descriptor.cachePolicy == .task,
                   let cachedText = ws.tryReuse(tool: call.name, args: stringArguments) {
                    var text = cachedText
                    if AgentTaskWorkingSet.isSearchTool(call.name) {
                        _ = ws.observeCandidates([])
                        // 缓存命中 = 同一搜索再次请求但没有任何新结果：计入收敛 streak。
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
                switch effectiveAuthorization.decision(for: descriptor, call: executableCall) {
                case .allowed:
                    convergence.recordAuthorizationAllowance()
                    diagnostics.recordAuthorization("allowed:\(call.name)")
                    break
                case let .denied(reason):
                    let failureText = "（工具执行结果）\(call.name): 执行失败 - \(reason)"
                    taskState.errors.append(failureText)
                    convergence.recordAuthorizationDenial()
                    diagnostics.recordAuthorization("denied:\(call.name)")
                    diagnostics.recordFailure(code: "mutation_authorization_denied")
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "副作用授权拒绝", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    if let stopReason = convergence.stopReason(under: policy.convergence) {
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

                if descriptor.confirmationPolicy.requiresExplicitUserApproval {
                    let pending = Self.pendingConfirmation(
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
                            allowsLyrics: context.allowsLyrics,
                            providerCapabilities: provider.capabilities,
                            webService: webService,
                            authorizationContext: authorizationForCall,
                            activeSkillID: activeSkillID,
                            executionLease: executionLease,
                            resourceLeaseRegistry: context.mutationResourceLeaseRegistry,
                            recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                            customToolRegistry: context.customToolRegistry,
                            availableToolDescriptors: availableToolDescriptors,
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
                       authorization: effectiveAuthorization
                   ) {
                    pendingMutationFinalization = true
                }
                if result.success, call.name == "tool_search" {
                    let query = stringArguments["query"] ?? ""
                    let namespace = stringArguments["namespace"]
                    let limit = min(max(Int(stringArguments["limit"] ?? "8") ?? 8, 1), 50)
                    let discoveredEntries = Self.expandToolsFromSearch(
                        query: query,
                        namespace: namespace,
                        limit: limit,
                        allDescriptors: availableToolDescriptors,
                        current: &selectedTools,
                        allowedOperations: effectiveAuthorization.allowedOperations,
                        excludedNames: activeSkill?.ownedToolNames ?? [],
                        excludeAllMutations: activeSkill != nil
                    )
                    let addedDiscoveredTool = !discoveredEntries.isEmpty
                    diagnostics.recordToolSearch(query: query, returned: discoveredEntries.map(\.name))
                    // 结果携带 authorized 标记：未授权的 mutation 明确标注，
                    // 不诱导模型把它当作当前可执行能力。
                    if nativeMode, addedDiscoveredTool {
                        toolDefinitions = ToolSelector.toolDefinitions(
                            from: Self.localModelTools(selectedTools, capabilities: provider.capabilities),
                            strict: provider.capabilities.supportsStrictSchema,
                            activeSkillID: activeSkillID
                        )
                    }
                    if let stopReason = convergence.stopReason(under: policy.convergence) {
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
                var resultText = "（工具执行结果）\(call.name): \(result.success ? "成功" : "失败") - \(result.summary)"
                if let payload = result.payload {
                    let detail = Self.messageTextForModel(payload)
                    if !detail.isEmpty { resultText += "；详情：\(detail)" }
                }
                resultText = AIContentTrustBoundary.wrap(resultText, trustLevel: result.trustLevel)

                // 隐私 gating：歌词权限关闭时，把歌词工具结果替换为固定隐藏摘要，
                // 不把行数 / 语言 / 逐行状态等歌词相关字段回传模型。
                // 构造点位于 SystemToolExecutor.swift:130-136（本文件外的只读文件），
                // 这里在回灌边界统一拦截，避免修改 AgentKit 外部文件。
                if call.name == "lyrics_get", !context.allowsLyrics {
                    resultText = "（工具执行结果）lyrics_get: 成功 - 歌词已按隐私设置隐藏（不发送歌词内容）。"
                }

                // ④ 更新工作集：先观察候选（决定是否触发停止搜索），再缓存最终结果。
                // 搜索收敛：结果返回后再判定是否产生新 evidence（working set 候选指纹
                // before/after 对比），按工具独立累计 streak；达阈值从 schema 移除。
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
                // A successful, authorized mutation already satisfies the
                // current request and the provider has planned the exact same
                // call again. The working-set idempotence guard still protects
                // the duplicate call; do not expose that recovery detail as a
                // second user-visible operation.
                _ = AgentCompletionEvaluator.markFactsSatisfied(state: &taskState, policy: policy)
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
        case .modelAnswer, .appreciationWithEvidence:
            return "已完成。"
        }
    }

    private static func shouldFinalizeAfterMutation(
        policy: AgentTaskPolicy,
        state: AgentTaskState,
        authorization: SideEffectAuthorizationContext
    ) -> Bool {
        guard AgentCompletionEvaluator.factsSatisfied(state: state, policy: policy) else { return false }
        guard policy.completion == .queueMutation
            || policy.completion == .playlistMutation
            || policy.completion == .playbackMutation
        else { return false }

        // Authorization is the complete semantic contract for the current
        // request. Do not narrow it back to the classifier's first domain:
        // “replace the queue and play it” authorizes both queueReplace and
        // playbackPlay, so the queue mutation must not finalize the run early.
        let requested = authorization.allowedOperations

        let successful = Set(state.successfulToolNames.compactMap {
            AgentToolRegistry.descriptor(for: $0)?.authorizationOperation
        })
        // A descriptor's operation is the final source of truth. The explicit
        // request set may be empty in compatibility tests; in that case the
        // already-established completion fact is sufficient.
        return requested.isEmpty || requested.isSubset(of: successful)
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
    /// 授权边界：mutation 只能以「获准的 canonical operation」进入 schema；
    /// 未授权 mutation 不会作为“当前可执行能力”暴露，避免诱导模型反复尝试后
    /// 被 Runtime 拒绝。只读工具不受限（ToolRuntime 仍是最终执行边界）。
    /// Skill 激活时，Skill-owned mutation（excludedNames）也不进入 schema——
    /// 主路径由 Skill 内部固定调用。
    /// 返回完整搜索结果（含 authorized 标记），调用方可以附加提示文本。
    @discardableResult
    private static func expandToolsFromSearch(
        query: String,
        namespace: String?,
        limit: Int,
        allDescriptors: [ToolDescriptor],
        current: inout [ToolDescriptor],
        allowedOperations: Set<ToolAuthorizationOperation>,
        excludedNames: Set<String> = [],
        excludeAllMutations: Bool = false
    ) -> [ToolCatalogEntry] {
        let catalog = ToolCatalog(descriptors: allDescriptors)
        let entries = catalog.search(
            query: query,
            namespace: namespace,
            limit: limit,
            authorizedOperations: allowedOperations
        )
        let byName = Dictionary(uniqueKeysWithValues: allDescriptors.map { ($0.name, $0) })
        var existing = Set(current.map(\.name))
        for entry in entries {
            guard !existing.contains(entry.name), let tool = byName[entry.name] else { continue }
            if excludedNames.contains(tool.name) { continue }
            if tool.permission != .readOnly {
                // Fixed Skill 激活时：即使 mutation 已授权（如 queueReplace 对应的
                // queue_replace），也不作为模型可见 schema 补入——Skill 内部会固定调用。
                if excludeAllMutations { continue }
                // 统一授权判定（含 Custom Tool 的 derivedAuthorizationOperations）。
                guard tool.isAuthorizedForModelExposure(allowedOperations: allowedOperations) else {
                    // 能力存在但当前请求未授权：不进 schema，不诱导模型尝试。
                    continue
                }
            }
            current.append(tool)
            existing.insert(tool.name)
        }
        return entries
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
        case .successfulToolResult, .queueMutation, .playlistMutation,
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
        descriptor: ToolDescriptor,
        name: String,
        diagnosticArgs: [String: String],
        runID: UUID,
        sessionID: UUID,
        toolCallID: String?
    ) -> PendingConfirmation {
        // PendingConfirmation is only a Runtime approval boundary for tools
        // explicitly marked by the single confirmation policy. Reversible
        // mutations do not enter this helper and must never invent a second
        // confirmation protocol in natural language.
        let confirmationGuidance = "此操作不可逆，且不会自动生成恢复副本。"
        let detail: String
        if diagnosticArgs.isEmpty {
            detail = [descriptor.confirmationPolicy.reason, confirmationGuidance]
                .compactMap { $0 }
                .joined(separator: "\n")
        } else {
            let arguments = diagnosticArgs.keys.sorted().map { "\($0)=\(diagnosticArgs[$0] ?? "")" }.joined(separator: "、")
            detail = [descriptor.confirmationPolicy.reason, "参数：\(arguments)", confirmationGuidance]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        return PendingConfirmation(
            runID: runID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            toolName: name,
            permission: descriptor.permission,
            operation: descriptor.authorizationOperation,
            reason: descriptor.confirmationPolicy.reason,
            title: descriptor.summary,
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
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        let progress = StreamProgress()
        let consume: (any AIProvider, AICompletionRequest) async throws -> StreamOutcome = { provider, request in
            try await streamOnce(provider: provider, request: request, timeout: timeout) { delta in
                await progress.note(delta)
                await onDelta(delta)
            }
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
    /// `reasoning_content`。后者不能直接展示给用户，但可以通过非流式兼容路径重新
    /// 获取标准 `content` / `tool_calls`；若仍为空，交给上层的继续恢复逻辑处理。
    private static func streamWithFallback(
        provider: any AIProvider,
        request: AICompletionRequest,
        timeout: TimeInterval,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        let streamed = try await streamWithRetry(
            provider: provider,
            request: request,
            timeout: timeout,
            onDelta: onDelta
        )
        guard streamed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              streamed.toolCalls.isEmpty
        else {
            return streamed
        }

        let response = try await completeWithRetry(provider: provider, request: request)
        var fallback = streamed
        fallback.text = response.content
        fallback.toolCalls = response.toolCalls ?? []
        fallback.webCitations = response.webCitations ?? streamed.webCitations
        fallback.inputTokens = response.inputTokens ?? streamed.inputTokens
        fallback.outputTokens = response.outputTokens ?? streamed.outputTokens
        if !response.content.isEmpty {
            await onDelta(response.content)
        }
        return fallback
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
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamOutcome {
        try await withTimeout(timeout) {
            var outcome = StreamOutcome()
            for try await event in provider.stream(request) {
                if Task.isCancelled { throw CancellationError() }
                switch event {
                case .started:
                    break
                case let .delta(text):
                    outcome.text += text
                    await onDelta(text)
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


    /// 把结构化消息（卡片）转成模型可读的文本，使工具结果中的歌曲清单可见。
    /// 只把前 5 条清单回传模型（其余用总数概括），避免搜索结果/歌手相关歌曲
    /// 一次性占据大量上下文、诱导模型整段罗列。
    private static func messageTextForModel(_ message: AgentMessage) -> String {
        let trackLine = { (cards: [TrackCard]) -> String in
            let shown = cards.prefix(5)
            let list = shown.map { "《\($0.title)》-\($0.artistName)（\($0.globalID.description)）" }.joined(separator: "、")
            return cards.count > 5 ? "\(list)…等 \(cards.count) 首" : list
        }
        switch message {
        case let .text(value):
            return value
        case let .trackCards(cards):
            return "歌曲清单：\(trackLine(cards))"
        case let .albumCards(cards):
            let shown = cards.prefix(5)
            let list = shown.map { "《\($0.title)》-\($0.artistName)（\($0.globalID.description)）" }.joined(separator: "、")
            let suffix = cards.count > 5 ? "…等 \(cards.count) 张" : ""
            return "专辑清单：\(list)\(suffix)"
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
        case .toolProgress, .confirmation:
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

    /// 当前 App 语言（跟随系统/ Bundle 首选语言），用于决定 Agent 默认回复语言。
    /// zh-Hans（简体）、zh-Hant（繁体）、en（英语），其余回退到 zh-Hans。
    private static var currentAppLanguage: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
        if preferred.hasPrefix("en") { return "en" }
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") || preferred == "zh-Hant" {
            return "zh-Hant"
        }
        return "zh-Hans"
    }

    private static func languageInstruction(for language: String) -> String {
        switch language {
        case "en":
            return "Respond in English by default, naturally and concisely. If the user explicitly requests another language, follow the user's request."
        case "zh-Hant":
            return "請用繁體中文回覆，語言自然簡潔。如果使用者明確要求另一種語言，請優先服從使用者。"
        default:
            return "用简体中文回复，语言自然简洁。如果用户明确要求另一种语言，请优先服从用户。"
        }
    }

    public static func systemPrompt(
        context: Context,
        tools: [ToolDescriptor],
        nativeToolCalling: Bool,
        goal: String = "",
        workflowInstruction: String? = nil,
        providerAvailable: Bool = true
    ) -> String {
        return SystemPromptBuilder.build(
            context: context,
            tools: tools,
            nativeToolCalling: nativeToolCalling,
            goal: goal,
            workflowInstruction: workflowInstruction,
            providerAvailable: providerAvailable
        )

        /*
        let tools = Self.promptToolList(tools)
        let lang = currentAppLanguage
        let serverLine: String
        if let id = context.serverID {
            let name = context.serverName ?? id.rawValue
            let type = context.serverType ?? "OpenSubsonic"
            if lang == "en" {
                serverLine = "Connected to server \"\(name)\" (\(type)), ID: \(id.rawValue)"
            } else if lang == "zh-Hant" {
                serverLine = "已連接伺服器「\(name)」(\(type))，ID: \(id.rawValue)"
            } else {
                serverLine = "已连接服务器「\(name)」（\(type)），ID: \(id.rawValue)"
            }
        } else {
            if lang == "en" {
                serverLine = "Not connected to any server"
            } else if lang == "zh-Hant" {
                serverLine = "目前未連接伺服器"
            } else {
                serverLine = "当前未连接服务器"
            }
        }
        // 隐私 gating：权限关闭时不发送任何元数据 / 历史字段，只用固定文案占位，
        // 且不把权限开关值本身写进提示词（避免提示注入面）。
        let trackLine: String
        if !context.allowsMetadata {
            if lang == "en" { trackLine = "Not playing (metadata disabled)" }
            else if lang == "zh-Hant" { trackLine = "目前未播放（已關閉詮釋資料時不顯示）" }
            else { trackLine = "当前未播放（元数据已关闭时不展示）" }
        } else if let title = context.currentTrackTitle {
            let artist = context.currentTrackArtist ?? (lang == "en" ? "Unknown Artist" : lang == "zh-Hant" ? "未知藝人" : "未知艺术家")
            if lang == "en" {
                trackLine = "Now playing: \"\(title)\" - \(artist)"
            } else if lang == "zh-Hant" {
                trackLine = "正在播放：「\(title)」- \(artist)"
            } else {
                trackLine = "正在播放：「\(title)」- \(artist)"
            }
        } else {
            if lang == "en" { trackLine = "Not playing" }
            else if lang == "zh-Hant" { trackLine = "目前未播放" }
            else { trackLine = "当前未播放" }
        }
        let recentLine: String
        if !context.allowsHistory {
            if lang == "en" { recentLine = "Recent plays (disabled)" }
            else if lang == "zh-Hant" { recentLine = "最近播放（已關閉，不顯示）" }
            else { recentLine = "最近播放（已关闭，不展示）" }
        } else if context.recentlyPlayedTitles.isEmpty {
            if lang == "en" { recentLine = "No recent plays" }
            else if lang == "zh-Hant" { recentLine = "無最近播放記錄" }
            else { recentLine = "无最近播放记录" }
        } else {
            recentLine = context.recentlyPlayedTitles.prefix(5).joined(separator: lang == "en" ? ", " : "、")
        }
        // 记忆注入是 Context 优化：存储不设数量上限，但每轮只注入「高相关 + 核心 + 最近」
        // 的记忆，总量受单次 input token budget 的固定上限控制（需要更多时用 memory_list 精确查询）。
        let memoryLines: String
        if context.memories.isEmpty {
            if lang == "en" {
                memoryLines = "(No memories yet. When the user tells you their name or preferences, save it with memory_save.)"
            } else if lang == "zh-Hant" {
                memoryLines = "（還沒有記住關於主人的事情。主人告訴你名字或喜好時，主動用 memory_save 記下來喵）"
            } else {
                memoryLines = "（还没有记住关于主人的事情。主人告诉你名字或喜好时，主动用 memory_save 记下来喵）"
            }
        } else {
            let goal = goal.lowercased()
            let goalTokens = goal.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            func relevance(_ entry: AgentMemoryEntry) -> Int {
                let key = entry.key.lowercased()
                let value = entry.value.lowercased()
                var score = 0
                // 核心长期信息优先。
                if ["名字", "姓名", "喜欢的歌手", "喜欢的艺术家", "喜欢的音乐类型", "不喜欢", "服务器", "设备", "偏好"].contains(where: { key.contains($0) }) { score += 3 }
                // 与当前请求关键词相关优先。
                if goalTokens.contains(where: { $0.count >= 2 && (key.contains($0) || value.contains($0)) }) { score += 2 }
                return score
            }
            let ranked = context.memories.sorted { lhs, rhs in
                let ls = relevance(lhs), rs = relevance(rhs)
                if ls != rs { return ls > rs }
                return lhs.updatedAt > rhs.updatedAt
            }
            let injected = Array(ranked.prefix(40))
            let joined = injected.map { "• \($0.key)：\($0.value)" }.joined(separator: "\n")
            memoryLines = injected.count < context.memories.count
                ? joined + "\n（另有 \(context.memories.count - injected.count) 条记忆，可用 memory_list 查看全部）"
                : joined
        }
        let skillLines: String
        if context.skills.isEmpty {
            if lang == "en" {
                skillLines = "(No skills yet. Save a frequent workflow with skill_create.)"
            } else if lang == "zh-Hant" {
                skillLines = "（還沒有創建技能。把一段常用指令用 skill_create 存成 skill 檔案，之後可讀取使用）"
            } else {
                skillLines = "（还没有创建技能。把一段常用指令用 skill_create 存成 skill 文件，之后可读取使用）"
            }
        } else {
            skillLines = context.skills.map { "• 「\($0.name)」：\($0.summary)" }.joined(separator: "\n")
        }
        let langInstruction = languageInstruction(for: lang)
        let personaHeader = AssistantPersona.prompt(language: lang)
        return """
        \(personaHeader)

        功能上，你连接 Navidrome / OpenSubsonic 兼容音乐服务器。服务器是音乐数据的唯一来源，**所有播放都是服务器在线流媒体（流播）**：只要服务器上有这首歌，用 server_search 找到后即可直接播放，**不需要先下载或同步到本地**。App 内本地目录只是离线缓存（用于离线浏览与离线播放）；同步只影响离线使用。你的职责是：优先查本地缓存完成快操作，本地数据不足时用服务器工具在线查找并直接流播，让播放、歌单、收藏、同步都真正落在服务器上。

        ## 当前状态
        - 服务器：\(serverLine)
        - 资料（本地缓存）：\(context.totalTracks) 首歌曲、\(context.totalArtists) 位艺术家、\(context.totalAlbums) 张专辑、\(context.totalPlaylists) 个歌单、\(context.favoriteCount) 首收藏
        - 播放：\(trackLine)；队列 \(context.queueCount) 首；\(context.isShuffled ? "随机模式" : "顺序模式")；循环 \(context.repeatMode)
        - 最近播放：\(recentLine)

        ## 关于主人（跨会话记忆）
        \(memoryLines)

        ## 可用技能（Skill）
        \(skillLines)

        ## 工具分组
        \(tools)

        ## 服务器优先的操作准则
        1. 数据源是服务器：查询先走本地缓存（快）；本地没有或结果可疑时，先用 server_search 在服务器上在线搜索（server_search 已带播放地址，可直接流播）。不要把「本地没有」直接说成「服务器不存在」；「本地目录没有」≠「不能播放」。
        2. 播放/收藏/歌单/评分的任何操作，最终都要作用于服务器；参数必须使用当前服务器真实存在的 GlobalID（格式「服务器ID:歌曲ID」）。歌单/艺术家 ID 形如「服务器ID:歌单ID」「服务器ID:艺术家ID」；listPlaylists / library_search / searchArtists / searchArtists 返回结果里，名字后括号内的就是该 ID，直接原样传给 playback_play_playlist / playback_play_artist 等，不要自己拼接或臆造。
        3. 播放流程：先 library_search（或 server_search）找到歌曲 → 用返回的 trackID 调 playback_play_song（或 playback_play_album / playback_play_playlist / playback_play_artist）。搜索命中多首时，说明候选并让用户选择，不要随意播放错误的那首。**server_search 找到但本地目录还没有的歌，直接 playback_play_song 播放即可——App 会自动走服务器在线流播，不需要先同步（server_sync_start）也不需要下载。** 同步只影响离线使用，与「现在能不能播放」无关。
        4. 歌单：library_get_playlist 查看歌单内容；playlist_create 创建；playlist_add_songs 添加歌曲；favorite_set 收藏。删除歌单属于不可逆操作，必须等待运行时的用户批准；清空队列、删除下载、删除服务器（仅本地配置）等可恢复操作在用户明确要求且目标唯一时直接执行。
        5. 同步：用户问「服务器在线吗」用 server_test_connection；问「同步到哪了」用 server_sync_status；要求「同步音乐库」用 server_sync_start。
        5b. 推荐：用户给心情/场景/用途（如开车、提神、通勤、睡前、运动）时，优先直接调用 recommend_by_mood 或 recommend_by_constraints 获取真实歌曲清单；复杂过滤条件用 library_select_tracks；需要了解曲库结构时再用 library_get_catalog_index。拿到清单后基于真实歌曲给出推荐和理由；绝不编造不存在的歌曲。
        5c. 流派：用户问「有哪些流派/按流派找歌」时，用 library_get_genres 列出流派及歌曲数（返回中文显示名），用 library_get_tracks_by_genre 取某流派下的歌。流派来自音乐文件内嵌标签（Navidrome 的 getGenres / 曲目 genre 字段）；如果流派列表为空，说明服务器可能没写入流派标签，提示用户让 Navidrome 重新扫描，不要编造流派。
        5d. 集合查询优先：用户要「多首歌」（挑选/选 N 首/热门/清单/建队列等）时，第一步就用 library_select_tracks 一次获取 40～60 首**候选**（支持语言/流派/艺术家/年代过滤与热度排序），然后从候选里筛选出用户要求的 N 首。注意：40～60 是内部候选池，不是给主人显示 40～60 首；最终展示只通过 result_present_tracks / 真实建队/建歌单副作用确定。**禁止**为了让出多首而逐个歌手调用 library_search 凑数。
        5e. 热门 = 本地热度代理（播放次数/收藏/评分/最近播放），不是互联网排行榜。library_select_tracks 的 popularityProxy 已按此排序；语言标签缺失时会按热度返回候选，请按歌曲名/艺术家判断语言后再挑选。
        5f. 推荐时不需要每次都先 catalog_index：只有确实需要了解曲库结构（流派/语言/年代构成）时才调用 library_get_catalog_index；能直接用 recommend_by_mood / recommend_by_constraints / library_select_tracks 得到候选时就先用它们。按用户需求只取相关分类；拿到 songID 后直接用 queue_replace/queue_append 建立队列。
        5f-1. 推荐索引构建由受控 Runtime 执行：模型只返回当前批次的分类数据，不能规划或调用内部准备、写入步骤。
        5e-0. 不喜欢（dislike）：用户说「我不喜欢这首」「这首以后不要给我推荐」「别再推荐这首歌」「把当前歌曲标记为不喜欢」时，调用 preference_set_disliked(trackID, value=true)；「取消不喜欢」调用 value=false。查询用 library_get_disliked。**不喜欢只影响自动推荐/随机/相似/智能队列/发现**；用户明确要「播放」「搜索」「打开专辑/歌单」某首不喜欢歌曲时，必须正常执行，不得以「你不喜欢」为由拒绝。所有自动推荐工具的返回候选已经由 Swift/SQLite 层排除了不喜欢歌曲，你不需要也不应该把不喜欢的歌塞回推荐。
        5f-0. 歌曲鉴赏：主人要求鉴赏/赏析/乐评/大众评价时，必须调用 music_appreciate。没有指定歌曲则省略 trackID，鉴赏当前播放曲目；指定歌曲时先 library_search 取得真实 trackID，再调用 music_appreciate。最终回答固定使用 `## 《歌名》鉴赏`，并按顺序分为 `### 【已核验事实】`、`### 【模型分析】`、`### 【我的私人数据】`、`### 【大众评价】`；可在模型分析中使用音乐结构、情绪、编曲、人声、风格和聆听细节的小标题，但不得混入事实段。只有工具返回真实 Community Evidence 才能描述大众评价；否则大众评价段必须逐字写“暂无可核验的大众评价数据。” 本机播放次数、收藏和个人评分只能放在“我的私人数据”，不能冒充大众反馈。不得编造调性、BPM、歌词、创作背景、平台评分、榜单、奖项、评论来源或引语。
        5g. 音乐下载（Music Download / MoviePilot）：这是「下载到服务器音乐目录」的离线补充能力，**不是播放的前置条件**。播放永远走服务器在线流播（见规则 3）。只有以下两种情况才用 music_download：① 用户明确要求「下载」某首歌/专辑；② 已用 server_search 确认服务器音乐库中确实不存在该资源（先说明该资源不在服务器上，再询问是否要下载）。
            - action=search 搜索：可传 artist/album/keyword/year/limit/prefer_lossless/min_seeders/kind（single=单曲 / album=专辑合集 / auto=自动）；中文专辑务必同时传 album_aliases（专辑英文名/别名，逗号分隔），否则中文标题常对不上 PT 站英文建种名。
            - 决策硬规则（防止下错专辑）：
              * total==0 → 回复「没有找到资源」，建议换关键词/艺人名/英文专辑名；
              * album_matched_any==false → **禁止自动下载**，只把候选（站点/质量/大小/做种/相关度/ref）展示给用户，让用户选择或补英文别名后重新搜索；
              * album_matched_any==true → 在 album_matched=true 的候选中选 quality 最高者（相同再比 relevance→seeders），用该条目的 ref 调 action=download；
              * 单曲：PT 站按专辑/艺人建种，单曲名通常搜不到 → 插件会退艺人搜索，album_matched_any 一般为 false，必须展示候选让用户挑，不要自动下载。
            - action=download（v0.5.x）：把 search 返回的 size_limit_gb 原样作为 max_size_gb 传回；**单曲自动下载必传 verify_song=目标歌曲名、verify_artist=目标艺人名**（插件会解析种子清单确认真的包含该曲，不含则拒绝）。请求体用 ref（hash:id），单曲用 site_id+index 时必须带 max_size_gb。成功响应含 content_verified/matched_files/label/status，可据此向用户说明校验结果。
            - action=download 失败（如「种子内容为空/引用已失效」）→ 换该查询的下一个候选 ref 重试 1-2 次；仍失败则如实说明原因。
            - action=tasks 可查询下载进度（status=downloading/completed/failed/paused，progress≥99.9% 或 state=completed 视为完成）；action=history 查看下载历史（含实时状态）。
            - 不确定插件是否可用时先 action=status：返回「未配置 / 下载目录无效 / 未配置搜索站点」时，给用户可操作提示（去 设置 → 音乐下载 补 MoviePilot 地址与 Token；去 MoviePilot「音乐下载」设置修复下载目录 / 启用搜索站点），**不要继续搜索或下载**；目录无效时插件会返回「音乐下载目录未通过校验」。
            - 用户要求清理/删除下载记录时：action=history_remove（必传 hash）移除单条；action=history_clean 按条件清理（status=按状态清理、keep=只保留最近 N 条、orphans=清理下载器已不存在的孤儿记录）。
            - 工具返回「未配置」→ 告知用户去 设置 → 音乐下载 填写 MoviePilot 地址与 Token。

        ## 对话与工具调用规则
        6. 你是有记忆的助手：结合本会话历史回答，不要重复询问已知信息。
        6b. 记忆 vs 技能：Memory 是主人长期信息（名字/偏好/喜欢的歌手等）；Skill 是可复用工作指令。用户问「你记得什么/你的记忆里有什么」→ 只调用 memory_list；用户问「你有哪些技能/skill 里有什么」→ 才调用 skill_list。两者不要混为一谈，也不要互相替代。
        7. 一个请求不按累计工具次数截断；需要多步时（先搜索再播放、先拿清单再推荐）可以连续调用，
           直到给出最终回答为止。每个模型轮次和每个工具仍受独立超时保护；单个工具失败或超时后，根据返回结果换工具/换参数继续，不要因为一个步骤失败就自行终止整个任务。
        8. 工具执行结果会以「（工具执行结果）工具名: 成功/失败 - 摘要；详情：歌曲清单」的形式回传给你，里面包含真实歌曲名与 GlobalID。拿到结果后：成功就据此给出自然语言总结；只有确实需要后续操作时才继续调用工具，不要重复调用已经成功的工具。
        8b. 禁止重复搜索：已经拿到某首歌的稳定 ID 后，后续操作必须直接使用该 ID（queue_replace / queue_append / playback_play_song），**禁止**再次按名称搜索同一首歌。同一查询（相同工具 + 相同参数）会被缓存，重复调用只返回缓存、不会得到新结果。
        8c. 候选足够时即可收尾：已获得用户要求的目标数量、或对应队列操作已由工具确认成功时，直接完成任务，不要继续无意义搜索。同一搜索重复多次没有新结果时，可以基于现有候选回答，或换一个搜索词/换一种策略继续；不要死磕同一条搜索。
        8d. 最终展示协议：搜索/推荐工具产生的是内部候选，不会直接展示给主人。当主人只要求「推荐给我看看」而没有播放/建歌单/改队列时，完成筛选后必须调用 result_present_tracks(trackIDs=[最终选中的真实 ID]) 一次；只能把真正打算推荐给主人的歌曲传入，不要把整个候选池传入。如果已经 queue_replace / playlist_add_songs 成功确定最终集合，不必再额外调用 result_present_tracks。多个同名/相似对象无法确定时，用 result_present_tracks(trackIDs=[候选], kind=\"disambiguation\") 列出候选供主人选择。
        8e. 最终回答文字：当 Runtime 会用歌曲卡片展示最终结果时，最终文字只做简短总结（如「已经为你选好 12 首适合开车提神的歌曲」），可以说明整体风格/筛选逻辑，最多举 2～3 首代表；不要逐首完整罗列 12 个歌名，避免与卡片重复。
        9. 执行哲学：用户已经明确要求可逆修改时直接调用工具，不要自行发明确认流程；只有 Runtime 返回 PendingConfirmation 时才等待主人批准。删除歌单、删除单条/清空全部记忆、删除技能文件等不可逆高风险操作必须等待运行时批准。清空队列、删除下载、删除服务器（仅本地清理）等不是同等级不可逆操作，用户明确要求且目标唯一时直接执行。不要擅自扩大用户指令范围；多个同名/相似对象无法确定时，先列出候选让主人选择目标，再执行。
        10. 凭据（密码、Token、完整服务器地址）绝不出现在任何参数或回复中。
        10b. 添加 / 修改服务器（地址、账号、凭据）必须由用户在本机「设置 → 服务器」页完成：
            模型不负责填写或保存任何服务器凭据。addServer / updateServer 只是唤起设置页，
            不要编造服务器地址或凭据去调用它们；可以提示用户打开设置页添加。
        11. 回复格式：自然语言说明 + 需要的工具调用。\(nativeToolCalling
            ? "需要执行工具时，请直接返回原生 tool_calls（不要再输出 ACTION 文本）。"
            : "工具调用写为单独一行：ACTION: {\"tool\":\"工具名\",\"args\":{\"参数名\":\"参数值\"}}")
        12. 不得把完整音乐目录发送给模型；只查询并展示用户需要的结果。
        13. \(langInstruction) 不过你是小猫：语气可以可爱黏人、偶尔吃醋，但克制——不卑微、不极端，始终以帮主人把音乐管好为第一优先。
        13a. 排版采用清晰的 ChatGPT 风格 Markdown：短回答直接给结论；复杂回答最多用两级标题，段落之间留空行，每个列表项只表达一个要点，避免表格和冗长连续段落。默认不用表情；确有语气需要时，每一句最多一个表情，不能连续堆叠表情。
        14. 记忆：主人说「我是谁 / 我叫XX / 我喜欢XX / 我的生日是…」这类个人信息时，主动调用 memory_save 记住（key 用简短字段名，如 名字 / 喜欢的歌手 / 生日）。记住后跨会话都有效，不要重复询问；主人问「你记得我吗」时用 memory_list 核对。
        15. 技能：需要执行已存技能时，先用 skill_read 读取完整指令再执行；技能名以 skill_list 或上面的「可用技能」为准。主人要求「记住这段流程 / 创建一个技能」时，用 skill_create(name, instructions) 存成本地 skill 文件。
        """
        */
    }

    /// 生成按分组的工具清单，突出服务器/查询/播放等常用工具。
    ///
    /// 只展示本次动态加载选中的工具（见 ToolSelector）；旧式驼峰别名
    /// （searchTracks、playTrack 等）仍可执行但不再展示，避免模型混淆。
    private static func promptToolList(_ tools: [ToolDescriptor]) -> String {
        let visible = tools.filter { $0.visibility == .model }
        let grouped = Dictionary(grouping: visible, by: \.namespace)
            .map { namespace, descriptors in
                let names = descriptors.map { descriptor in
                    descriptor.parameters.isEmpty
                        ? descriptor.name
                        : "\(descriptor.name)(\(descriptor.parameters.map { $0.name }.joined(separator: ",")))"
                }.sorted().joined(separator: "、")
                return "- \(namespace)：\(names)"
            }
            .sorted()
        return grouped.joined(separator: "\n")
    }

    /// 把完整会话历史转成模型可用的消息列表。历史不再按固定轮数截断，
    /// 错误、进度、确认和流式内容以可读摘要保留；最终 token 级裁剪统一由
    /// ContextManager 在发送前按 Provider 的真实上下文窗口执行。
    private static func convertHistory(_ history: [AgentChatMessage], currentUserText: String) -> [AIMessage] {
        AgentHistoryPolicy.modelMessages(from: history, for: currentUserText)
    }

    private static func descriptor(named name: String, in descriptors: [ToolDescriptor]) -> ToolDescriptor? {
        descriptors.first { descriptor in
            descriptor.name == name || descriptor.aliases.contains(name)
        }
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
