import AIKit
import Domain
import Foundation
import LocalCatalog

/// 受控工具调用 Agent 的执行引擎（permissive direct execution）。
///
/// 流程：用户文本 →（可选 LLM 规划）→ 本地工具执行 → 结果回传 → UI 渲染。
/// 设计准则：已注册的普通音乐工具默认全部允许；Intent 只是路由提示，不是能力边界；
/// 用户明确要求且目标唯一时直接执行（删除歌单/清空队列/删除下载等不再二次确认）。
/// 硬性约束：每一轮模型请求和每一次工具执行都有独立超时；支持取消与防循环。
/// 单工具超时/失败回灌结构化结果让模型换策略继续，不终止整项任务；
/// 不设正常任务累计工具调用上限；noProgress / repeatedToolPattern 只做诊断统计。
public struct AgentRunner {
    /// 单个工具调用的最长执行时间。超过后取消该调用并结束整项 Agent 任务，
    /// 防止某个网络/系统服务工具卡住而让任务无限悬挂。
    public static let toolExecutionTimeout: TimeInterval = 6 * 60
    /// 模型每一轮的总响应时限。长回答、复杂规划和批量 JSON 分类都可能持续数分钟；
    /// 整项任务没有总轮数上限，但每个独立模型请求最多等待六分钟。
    public static let roundTimeout: TimeInterval = 6 * 60

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
            skills: [AgentSkillEntry] = []
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
        }
    }

    /// 任务进度快照（供 AgentTaskManager / UI 展示，不携带任何凭据）。
    public struct AgentProgress: Sendable {
        public let toolSteps: Int
        public let currentStep: String
        public let inputTokens: Int?
        public let outputTokens: Int?

        public init(toolSteps: Int, currentStep: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
            self.toolSteps = toolSteps
            self.currentStep = currentStep
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    /// 一次流式模型生成的结果：累积文本 + 收集到的原生工具调用 + token 用量。
    /// 与 `AICompletionResponse` 对应，但由 `provider.stream()` 的增量事件拼装而成。
    private struct StreamOutcome: Sendable {
        var text = ""
        var toolCalls: [AIToolCall] = []
        var inputTokens: Int?
        var outputTokens: Int?
    }

    private enum ToolArgumentParseResult {
        case success([String: String])
        case malformed(rawLength: Int)
    }

    /// 执行一次用户请求。
    /// - Parameters:
    ///   - provider: 可用时为 LLM 规划；为 nil 时走本地规则降级。
    ///   - toolTimeout: 单个工具执行的最长等待时间；超时以结构化失败回灌模型，不终止任务。
    ///   - confirm: 兼容回调（permissive runtime 不再产生确认请求；保留签名兼容旧调用方）。
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
        intent: AgentTaskIntent? = nil,
        policy: AgentTaskPolicy? = nil,
        initialTaskState: AgentTaskState? = nil,
        toolTimeout: TimeInterval = AgentRunner.toolExecutionTimeout,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in }
    ) async {
        // 用户消息先回显
        await emit(AgentChatMessage(role: .user, messages: [.text(userText)]))

        if let provider {
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
                intent: intent ?? AgentIntentClassifier.classify(userText),
                policy: policy ?? AgentTaskPolicy.policy(for: intent ?? AgentIntentClassifier.classify(userText)),
                initialTaskState: initialTaskState,
                toolTimeout: toolTimeout,
                confirm: confirm,
                emit: emit,
                log: log,
                progress: progress,
                state: state
            )
        } else {
            await runOffline(
                userText: userText,
                bridge: bridge,
                catalog: catalog,
                context: context,
                emit: emit,
                log: log
            )
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
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        initialTaskState: AgentTaskState?,
        toolTimeout: TimeInterval,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void,
        progress: @escaping @Sendable (AgentProgress) async -> Void,
        state: @escaping @Sendable (AgentTaskState) async -> Void
    ) async {
        // 动态工具加载：只向模型暴露与本次意图相关的工具，降低 schema 对上下文的占用。
        // Intent 只是路由提示（纯加法）：KeywordSuggested ∪ IntentSuggested ∪ TaskRequired。
        // 每轮用「用户原文 + 模型已输出文本 + 已执行工具」重新展开，任务中途需要新工具
        // （例如第一轮音乐发现、第二轮需要歌单/服务器工具）会自动补入，不会永久缺失。
        var accumulatedToolText = userText
        var selectedTools = ToolSelector.select(for: userText, intent: intent, policy: policy, all: AgentToolRegistry.all)
        let requestTimeout = roundTimeout
        var toolDefinitions = provider.supportsToolCalling
            ? ToolSelector.toolDefinitions(from: selectedTools)
            : []

        var taskState = initialTaskState ?? AgentTaskState(intent: intent, goal: userText)
        var privacy = AIPrivacyPermissions()
        privacy.allowsMetadata = context.allowsMetadata
        privacy.allowsLyrics = context.allowsLyrics
        privacy.allowsPlaybackHistory = context.allowsHistory
        var conversation = AgentContextBuilder.build(
            systemPrompt: Self.systemPrompt(
                context: context,
                tools: selectedTools,
                nativeToolCalling: provider.supportsToolCalling,
                goal: taskState.goal
            ),
            task: taskState,
            facts: [],
            history: Self.convertHistory(history),
            permissions: privacy,
            capabilities: provider.capabilities,
            inputBudget: policy.budget.maxInputTokens
        )
        conversation.append(AIMessage(role: .user, content: userText))

        var toolStepCount = 0
        var nativeMode = provider.supportsToolCalling
        var completionRepairAttempts = 0
        // 展示状态：候选池（内部，绝不上屏）与最终展示彻底分离。
        // 最终展示只来自 result_present_tracks / 真实副作用 / 搜索收尾合并。
        var presentation = AgentPresentationState()
        // 已提示过模型调用 result_present_tracks（只 repair 一次，避免无限循环）。
        var didRequestFinalSelection = false
        // 任务工作集：任务级结果缓存、重复调用保护、候选/队列统计、诊断轨迹。
        var ws = AgentTaskWorkingSet(
            targetQueueCount: AgentTaskWorkingSet.inferredTargetQueueCount(from: userText)
        )
        ws.configureRecommendationIndexV2(maxOutputTokens: provider.capabilities.maxOutputTokens)

        while true {
            if Task.isCancelled {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                return
            }
            if let violation = taskState.budgetViolation(policy: policy) {
                await emit(AgentChatMessage(role: .assistant, messages: [.error(violation.localizedDescription)]))
                return
            }
            // 上下文裁剪：防止无限增长导致 API 拒绝或 token 爆预算。
            let reservedOutput = min(policy.budget.maxOutputTokens, provider.capabilities.maxOutputTokens)
            let contextBudget = ContextManager.inputBudget(
                capabilities: provider.capabilities,
                requestedInputBudget: policy.budget.maxInputTokens,
                reservedOutputTokens: reservedOutput
            )
            conversation = ContextManager.trimByTokens(conversation, maxTokens: contextBudget)

            // 显式指定单次输出上限：当前模型使用 256K 上下文、16K 输出。
            // 多轮累计 token 仅用于诊断，不会被误当成单次上下文上限。
            // 动态工具扩展：每轮重新展开工具集（只增不减），保证任务中途的新工具需求可达。
            let expanded = ToolSelector.select(for: accumulatedToolText, intent: intent, policy: policy, all: AgentToolRegistry.all)
            var merged = selectedTools
            var haveNames = Set(merged.map(\.name))
            for tool in expanded where !haveNames.contains(tool.name) {
                merged.append(tool)
                haveNames.insert(tool.name)
            }
            // TaskRequiredTools：本轮已实际执行过的工具永远保留在 schema 中。
            if !ws.perToolCounts.isEmpty {
                let byName = Dictionary(uniqueKeysWithValues: AgentToolRegistry.all.map { ($0.name, $0) })
                for name in ws.perToolCounts.keys where !haveNames.contains(name) {
                    if let tool = byName[name] {
                        merged.append(tool)
                        haveNames.insert(tool.name)
                    }
                }
            }
            if merged.count != selectedTools.count {
                selectedTools = merged
                if provider.supportsToolCalling {
                    toolDefinitions = ToolSelector.toolDefinitions(from: selectedTools)
                }
            }

            let request = AICompletionRequest(
                model: model,
                messages: conversation,
                temperature: 0.3,
                maxTokens: reservedOutput,
                tools: nativeMode ? toolDefinitions : nil
            )
            let outcome: StreamOutcome
            do {
                outcome = try await streamWithRetry(provider: provider, request: request, timeout: requestTimeout) { delta in
                    await Self.emitStreamingDelta(delta, emit: emit)
                }
            } catch is CancellationError {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                return
            } catch {
                if Self.isOutputTruncated(error), policy.completion == .indexPendingCountIsZero {
                    let limit = ws.recoverRecommendationIndexV2Batch()
                    let recovery = "本批结构化输出不完整，未执行任何写入；已将 Recommendation Index V2 批次缩小为 \(limit) 首。请重新调用 library_index_v2_next_batch(limit=\(limit))，只对刚返回的完整批次生成 items。"
                    taskState.errors.append(recovery)
                    taskState.pendingActions = [recovery]
                    taskState.status = .waitingForTool
                    taskState.updatedAt = .now
                    await state(taskState)
                    await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "本批结构化输出不完整，正在缩小批次重试…")]))
                    conversation.append(AIMessage(role: .user, content: "系统恢复：\(recovery)"))
                    continue
                }
                // 原生 tools 字段被 400/422 拒绝（部分自托管端点不认识 tools）：
                // 降级到文本 ACTION 协议重试一次，而不是直接判死。
                if nativeMode, Self.isSchemaRejection(error) {
                    nativeMode = false
                    let fallbackRequest = AICompletionRequest(
                        model: model,
                        messages: conversation,
                        temperature: 0.3,
                        maxTokens: reservedOutput,
                        tools: nil
                    )
                    do {
                        outcome = try await streamWithRetry(provider: provider, request: fallbackRequest, timeout: requestTimeout) { delta in
                            await Self.emitStreamingDelta(delta, emit: emit)
                        }
                    } catch is CancellationError {
                        await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                        return
                    } catch {
                        await emit(AgentChatMessage(role: .assistant, messages: [.text("AI 服务暂时不可用（\(Self.errorText(error))），已改用本地能力处理。")]))
                        await runOffline(
                            userText: userText,
                            bridge: bridge,
                            catalog: catalog,
                            context: context,
                            emit: emit,
                            log: log
                        )
                        return
                    }
                } else {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("AI 服务暂时不可用（\(Self.errorText(error))），已改用本地能力处理。")]))
                    await runOffline(
                        userText: userText,
                        bridge: bridge,
                        catalog: catalog,
                        context: context,
                        emit: emit,
                        log: log
                    )
                    return
                }
            }

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

            // 解析本轮工具调用：原生 tool_calls 优先（流式事件收集），文本 ACTION 兜底。
            let streamedText = outcome.text
            if !streamedText.isEmpty { accumulatedToolText += " " + streamedText }
            let nativeCalls = nativeMode ? outcome.toolCalls : []
            let textActions = nativeCalls.isEmpty ? parseActions(from: streamedText) : []

            if nativeCalls.isEmpty && textActions.isEmpty {
                // 模型已输出最终回答 → 正常终止本轮任务。
                // 流式收尾：Coordinator 会把 in-flight 流式气泡原地定型为该最终文本，
                // 不会出现「流式半成品 + 成品」两条重复气泡。
                let reply = Self.formatAssistantReply(streamedText.trimmingCharacters(in: .whitespacesAndNewlines))
                switch AgentCompletionEvaluator.evaluateModelAnswer(
                    reply,
                    state: &taskState,
                    policy: policy,
                    repairAttempts: completionRepairAttempts
                ) {
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
            if nativeMode, !nativeCalls.isEmpty {
                conversation.append(AIMessage(role: .assistant, content: streamedText, toolCalls: nativeCalls))
            } else {
                conversation.append(AIMessage(role: .assistant, content: streamedText))
            }

            // 统一调用视图：原生调用带稳定 id，文本 ACTION 合成 text-N。
            let calls: [(id: String?, name: String, args: [String: String], malformedArguments: Bool)]
            if nativeMode, !nativeCalls.isEmpty {
                calls = nativeCalls.map { native in
                    switch Self.parseArguments(native.arguments) {
                    case let .success(args):
                        (id: native.id, name: native.name, args: args, malformedArguments: false)
                    case .malformed:
                        (id: native.id, name: native.name, args: [:], malformedArguments: true)
                    }
                }
            } else {
                calls = textActions.enumerated().map {
                    (id: "text-\($0.offset)", name: $0.element.tool, args: $0.element.args, malformedArguments: false)
                }
            }

            var toolMessages: [AIMessage] = []
            // 本轮统计（用于合并工具轨迹展示）。
            var roundSearchCalls = 0
            var roundToolNames: Set<String> = []

            for rawCall in calls {
                var call = rawCall
                if call.name == "library_index_v2_next_batch" {
                    call.args["limit"] = "\(ws.recommendationIndexV2PreferredBatchSize)"
                }
                toolStepCount += 1
                taskState.progress.toolCalls += 1
                taskState.recordToolCall(name: call.name, arguments: call.args)
                let diagnosticArgs = AgentSensitiveDataRedactor.arguments(call.args)
                if let violation = taskState.budgetViolation(policy: policy) {
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(violation.localizedDescription)]))
                    return
                }
                roundToolNames.insert(call.name)
                if AgentTaskWorkingSet.isSearchTool(call.name) { roundSearchCalls += 1 }

                guard let descriptor = AgentToolRegistry.descriptor(for: call.name) else {
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "未知工具", reused: false))
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: "执行失败：未知工具 \(call.name)",
                        native: nativeMode
                    ))
                    continue
                }

                if call.malformedArguments {
                    let failureText: String
                    if call.name == "library_index_v2_write_batch" {
                        let limit = ws.recoverRecommendationIndexV2Batch()
                        failureText = "（工具执行结果）library_index_v2_write_batch: 参数 JSON 不完整或被截断，本次没有执行写入。请重新调用 library_index_v2_next_batch(limit=\(limit))，只使用刚返回的完整批次。"
                        await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "本批结构化输出不完整，正在缩小批次重试…")]))
                    } else {
                        failureText = "（工具执行结果）\(call.name): 参数 JSON 不完整或被截断，本次没有执行工具。"
                    }
                    taskState.errors.append(failureText)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: [:], summary: "原生参数 JSON 不完整", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    continue
                }

                if call.name == "library_index_v2_write_batch",
                   let issue = ws.recommendationIndexV2WriteIssue(arguments: call.args) {
                    let limit = ws.recoverRecommendationIndexV2Batch()
                    let failureText = "（工具执行结果）library_index_v2_write_batch: \(issue)，本次没有执行写入。请重新调用 library_index_v2_next_batch(limit=\(limit))，只提交刚返回的完整批次。"
                    taskState.errors.append(failureText)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "V2 批身份或 items 无效", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    await emit(AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "本批参数不完整，正在缩小批次重试…")]))
                    continue
                }

                // 修改型工具不是查询缓存的一部分。相同工具 + 相同规范化参数再次出现时
                // 幂等复用（不重复副作用）；不同参数（例如第二次 queue_replace 使用不同
                // 歌曲列表）照常执行，任务不被“互斥保护”卡死。
                if descriptor.permission != .readOnly,
                   let reason = ws.sideEffectBlockReason(tool: call.name, args: call.args) {
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "已拦截重复副作用", reused: true))
                    // 这是一次真实的状态保护，而不是普通的模型内部提示：用户需要知道
                    // 第二次修改没有发生，否则最终回答仍可能谎称队列再次被替换。
                    await emit(AgentChatMessage(role: .assistant, messages: [.text(reason)]))
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: "（工具执行结果）\(call.name): 已跳过 - \(reason)",
                        native: nativeMode
                    ))
                    continue
                }

                // ② 任务级缓存：同一工具 + 规范化参数已执行过 → 直接复用结果。
                // 搜索类工具的重复调用同样记为「无新结果」，连续多次后触发停止搜索。
                if descriptor.cachePolicy == .task,
                   let cachedText = ws.tryReuse(tool: call.name, args: call.args) {
                    var text = cachedText
                    if AgentTaskWorkingSet.isSearchTool(call.name) {
                        _ = ws.observeCandidates([])
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
                let executableCall = ToolCall(name: call.name, arguments: call.args)
                do {
                    result = try await Self.withTimeout(toolTimeout) {
                        await AgentToolRegistry.execute(
                            executableCall,
                            bridge: bridge,
                            catalog: catalog,
                            serverID: context.serverID,
                            systemService: systemService,
                            externalMusicService: externalMusicService,
                            allowsLyrics: context.allowsLyrics
                        )
                    }
                } catch is CancellationError {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                    return
                } catch {
                    // 单工具超时/异常只回灌结构化失败结果，不终止整项任务；模型可换工具/换参数继续。
                    let failureText: String
                    if error is AgentRunnerError {
                        failureText = "（工具执行结果）\(call.name): 超时 - 工具超过 \(Int(toolTimeout)) 秒未完成，结果未知。可以重试该工具，或换一种方式继续。"
                    } else {
                        failureText = "（工具执行结果）\(call.name): 执行中断 - \(Self.errorText(error))"
                    }
                    taskState.errors.append(failureText)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "工具超时/中断", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: failureText, native: nativeMode))
                    continue
                }
                if result.success, result.permission != .readOnly {
                    ws.recordSuccessfulSideEffect(tool: call.name, args: call.args, summary: result.summary)
                }
                let madeProgress = AgentTaskReducer.apply(result: result, descriptor: descriptor, to: &taskState)
                if result.success, call.name == "library_index_v2_next_batch" {
                    ws.recordRecommendationIndexV2Batch(facts: result.facts)
                } else if result.success, call.name == "library_index_v2_write_batch" {
                    ws.completeRecommendationIndexV2Batch()
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
                    if let gids = Self.sideEffectFinalIDs(name: call.name, args: call.args, descriptor: descriptor) {
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

                // 隐私 gating：歌词权限关闭时，把歌词工具结果替换为固定隐藏摘要，
                // 不把行数 / 语言 / 逐行状态等歌词相关字段回传模型。
                // 构造点位于 SystemToolExecutor.swift:130-136（本文件外的只读文件），
                // 这里在回灌边界统一拦截，避免修改 AgentKit 外部文件。
                if call.name == "lyrics_get", !context.allowsLyrics {
                    resultText = "（工具执行结果）lyrics_get: 成功 - 歌词已按隐私设置隐藏（不发送歌词内容）。"
                }

                // ④ 更新工作集：先观察候选（决定是否触发停止搜索），再缓存最终结果。
                if let payload = result.payload, case let .trackCards(cards) = payload {
                    let ids = cards.map(\.globalID)
                    let noNew = ws.observeCandidates(ids)
                    // 连续多次无新结果 → 信息性提示（不终止任务，模型可换策略）。
                    if noNew, ws.noNewResultsStreak >= AgentTaskWorkingSet.noNewResultsLimit {
                        resultText += "\n（提示）搜索已连续 \(ws.noNewResultsStreak) 次没有新结果，当前已获得 \(ws.uniqueSongIDs.count) 首唯一候选。可以基于现有候选回答，或换一个搜索词/换一种策略继续。"
                    }
                }
                if AgentTaskWorkingSet.isSearchTool(call.name) == false, AgentTaskWorkingSet.queueWritingTools.contains(call.name) {
                    let queued = AgentTaskWorkingSet.songIDs(from: call.args)
                    if !queued.isEmpty { ws.noteQueued(queued) }
                }
                resultText = ContextManager.truncateToolResult(resultText, limit: descriptor.maxResultCharacters)
                ws.recordExecution(tool: call.name, args: call.args, resultText: resultText)
                ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: result.summary, reused: false))
                toolMessages.append(Self.toolResultMessage(callID: call.id, content: resultText, native: nativeMode))
            }

            conversation.append(contentsOf: toolMessages)

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

    /// 解析原生 tool call 的 arguments JSON 字符串为参数字典。
    private static func parseArguments(_ json: String) -> ToolArgumentParseResult {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .malformed(rawLength: json.utf8.count) }
        var args: [String: String] = [:]
        for (key, value) in object { args[key] = argumentString(value) }
        return .success(args)
    }

    /// 原生工具参数可能包含数组或对象。`String(describing:)` 会生成 Swift 的
    /// `[(key: value)]` 表示而不是 JSON，索引写入因而无法解码；结构值必须重新编码
    /// 为标准 JSON，字符串和标量则保持原值。
    private static func argumentString(_ value: Any) -> String {
        if let value = value as? String { return value }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        if let value = value as? NSNumber { return value.stringValue }
        return String(describing: value)
    }

    /// 判定是否「模型不认识 tools 字段」的确定性拒绝（400 / 422），以便降级重试。
    private static func isSchemaRejection(_ error: Error) -> Bool {
        if let providerError = error as? AIProviderError,
           case let .httpStatus(status) = providerError {
            return status == 400 || status == 422
        }
        return false
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
    /// 刻意**不**重试 `AgentRunnerError.timeout`：单轮超时已经耗掉完整的六分钟，
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

    // MARK: - Offline rule-based fallback

    private static func runOffline(
        userText: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: Context,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in }
    ) async {
        let text = userText.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()

        func search(_ q: String) async -> [CatalogTrackSummary] {
            (try? await catalog.searchTracks(query: q, serverID: context.serverID)) ?? []
        }

        if lower.contains("收藏") || lower.contains("喜欢") {
            if let q = extractQuery(text, markers: ["收藏", "喜欢"]) {
                let hits = await search(q)
                if let first = hits.first {
                    await bridge.likeTrack(globalID: first.globalID)
                    await log(AgentActionRecord(toolName: "likeTrack", permission: .reversible, summary: "收藏《\(first.title)》"))
                    await emit(AgentChatMessage(role: .assistant, messages: [.trackCards([.from(first)]), .text("已收藏：\(first.title)")]))
                } else {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("未找到匹配的歌曲。")]))
                }
            } else {
                let list = (try? await catalog.getFavorites(serverID: context.serverID)) ?? []
                await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(list.map(TrackCard.from)), .text("你的收藏（\(list.count) 首）")]))
            }
            return
        }

        if lower.contains("相似") {
            if let current = await bridge.currentTrack(),
               let gid = GlobalID("\(current.serverID.rawValue):\(current.id.rawValue)") {
                let list = (try? await catalog.getSimilarTracks(gid)) ?? []
                await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(list.map(TrackCard.from)), .text("相似歌曲（\(list.count) 首）")]))
            } else {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("当前没有正在播放的歌曲，无法推荐相似。")]))
            }
            return
        }

        if lower.contains("最近") || lower.contains("历史") {
            let list = (try? await catalog.getRecentHistory(serverID: context.serverID)) ?? []
            await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(list.map(TrackCard.from)), .text("最近播放（\(list.count) 首）")]))
            return
        }

        if lower.contains("下载") {
            let list = (try? await catalog.getDownloadedTracks(serverID: context.serverID)) ?? []
            await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(list.map(TrackCard.from)), .text("已下载（\(list.count) 首）")]))
            return
        }

        if lower.contains("歌单") {
            let list = (try? await catalog.listPlaylists(serverID: context.serverID)) ?? []
            let text = list.isEmpty
                ? "暂无歌单。"
                : "歌单：" + list.map { "\($0.name)（\($0.globalID)）" }.joined(separator: "、")
            await emit(AgentChatMessage(role: .assistant, messages: [.text(text)]))
            return
        }

        // 添加到歌单（LLM 不可用时本地规则直接完成）
        if lower.contains("加到歌单") || lower.contains("加入歌单") || lower.contains("放进歌单") || lower.contains("存到歌单") {
            let trackText = Self.extractBetween(text, left: ["把", "将"], right: ["加到", "加入", "放进", "存到"]) ?? text
            let playlistText = Self.extractBetween(text, left: ["加到", "加入", "放进", "存到"], right: ["歌单"]) ?? ""
            let trackQuery = trackText.trimmingCharacters(in: .whitespaces)
            let playlistName = playlistText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hits = await search(trackQuery)
            guard let first = hits.first else {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("未找到歌曲：\(trackQuery)")]))
                return
            }
            let name = playlistName.isEmpty ? "默认歌单" : playlistName
            if let gid = await bridge.createPlaylist(name: name) {
                let added = await bridge.addTracksToPlaylist(playlistGID: gid, trackGIDs: [first.globalID])
                if added {
                    await log(AgentActionRecord(toolName: "addTracksToPlaylist", permission: .reversible, summary: "把《\(first.title)》加入歌单「\(name)」"))
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("已把《\(first.title)》加入歌单「\(name)」")]))
                } else {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("加入歌单「\(name)」失败，请稍后重试。")]))
                }
            } else {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("创建歌单「\(name)」失败，请检查服务器。")]))
            }
            return
        }

        // 创建歌单（LLM 不可用时本地规则直接完成）
        if lower.contains("创建歌单") || lower.contains("新建歌单") || lower.contains("建一个歌单") {
            let name = extractQuery(text, markers: ["创建歌单", "新建歌单", "建一个歌单", "叫", "名为"]) ?? "我的歌单"
            if let gid = await bridge.createPlaylist(name: name) {
                await log(AgentActionRecord(toolName: "createPlaylist", permission: .reversible, summary: "创建歌单「\(name)」"))
                await emit(AgentChatMessage(role: .assistant, messages: [.text("已创建歌单「\(name)」（\(gid.description)）")]))
            } else {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("创建歌单失败，请检查服务器连接。")]))
            }
            return
        }

        if lower.contains("播放") {
            let q = extractQuery(text, markers: ["播放"]) ?? text
            let hits = await search(q)
            if let first = hits.first {
                if await bridge.playTrack(globalID: first.globalID) {
                    await log(AgentActionRecord(toolName: "playTrack", permission: .reversible, summary: "播放《\(first.title)》"))
                    await emit(AgentChatMessage(role: .assistant, messages: [.trackCards([.from(first)]), .text("开始播放：\(first.title)")]))
                } else {
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("未能播放：未找到可播放的歌曲：\(q)")]))
                }
            } else {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("未找到可播放的歌曲：\(q)")]))
            }
            return
        }

        // 推荐（LLM 不可用时）：从收藏 / 相似 / 曲库随机中取真实歌曲，避免「未找到可播放的歌曲」死路。
        if lower.contains("推荐") {
            let favorites = (try? await catalog.getFavorites(serverID: context.serverID)) ?? []
            if !favorites.isEmpty {
                let sample = Array(favorites.shuffled().prefix(10))
                await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(sample.map(TrackCard.from)), .text("离线推荐：从你的收藏里选了 \(sample.count) 首")]))
                return
            }
            if let current = await bridge.currentTrack(),
               let gid = GlobalID("\(current.serverID.rawValue):\(current.id.rawValue)") {
                let similar = (try? await catalog.getSimilarTracks(gid)) ?? []
                if !similar.isEmpty {
                    let sample = Array(similar.prefix(10))
                    await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(sample.map(TrackCard.from)), .text("离线推荐：与当前播放相似 \(sample.count) 首")]))
                    return
                }
            }
            let all = (try? await catalog.allTrackSummaries(serverID: context.serverID)) ?? []
            if !all.isEmpty {
                let sample = Array(all.shuffled().prefix(10))
                await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(sample.map(TrackCard.from)), .text("离线推荐：从曲库随机选了 \(sample.count) 首")]))
            } else {
                await emit(AgentChatMessage(role: .assistant, messages: [.text("曲库为空，请先连接服务器并同步资料库后再推荐。")]))
            }
            return
        }

        // 默认：搜索并以卡片展示
        let hits = await search(text)
        if hits.isEmpty {
            await emit(AgentChatMessage(role: .assistant, messages: [.text("本地未找到匹配的歌曲，可尝试连接服务器后再试：只要服务器上有这首歌就能直接在线播放，无需先下载或同步。")]))
        } else {
            await emit(AgentChatMessage(role: .assistant, messages: [.trackCards(hits.prefix(20).map(TrackCard.from)), .text("找到 \(hits.count) 首相关歌曲")]))
        }
    }

    // MARK: - Helpers

    /// 提取两个标记之间的文本（用于「把X加到歌单Y」这类解析）。
    private static func extractBetween(_ text: String, left: [String], right: [String]) -> String? {
        var value = text
        for marker in left where !marker.isEmpty {
            if let range = value.range(of: marker) {
                value = String(value[range.upperBound...])
                break
            }
        }
        for marker in right where !marker.isEmpty {
            if let range = value.range(of: marker) {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractQuery(_ text: String, markers: [String]) -> String? {
        for marker in markers {
            if let range = text.range(of: marker) {
                let after = text[range.upperBound...]
                let cleaned = after.trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
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
                    args[key] = argumentString(value)
                }
            }
            results.append((tool, args))
        }
        return results
    }

    public static func systemPrompt(context: Context, tools: [ToolDescriptor], nativeToolCalling: Bool, goal: String = "") -> String {
        let tools = Self.promptToolList(tools)
        let serverLine: String
        if let id = context.serverID {
            let name = context.serverName ?? id.rawValue
            let type = context.serverType ?? "OpenSubsonic"
            serverLine = "已连接服务器「\(name)」（\(type)），ID: \(id.rawValue)"
        } else {
            serverLine = "当前未连接服务器"
        }
        // 隐私 gating：权限关闭时不发送任何元数据 / 历史字段，只用固定文案占位，
        // 且不把权限开关值本身写进提示词（避免提示注入面）。
        let trackLine: String
        if !context.allowsMetadata {
            trackLine = "当前未播放（元数据已关闭时不展示）"
        } else if let title = context.currentTrackTitle {
            let artist = context.currentTrackArtist ?? "未知艺术家"
            trackLine = "正在播放：「\(title)」- \(artist)"
        } else {
            trackLine = "当前未播放"
        }
        let recentLine: String
        if !context.allowsHistory {
            recentLine = "最近播放（已关闭，不展示）"
        } else if context.recentlyPlayedTitles.isEmpty {
            recentLine = "无最近播放记录"
        } else {
            recentLine = context.recentlyPlayedTitles.prefix(5).joined(separator: "、")
        }
        // 记忆注入是 Context 优化：存储不设数量上限，但每轮只注入「高相关 + 核心 + 最近」
        // 的记忆，总量受单次 input token budget 的固定上限控制（需要更多时用 memory_list 精确查询）。
        let memoryLines: String
        if context.memories.isEmpty {
            memoryLines = "（还没有记住关于主人的事情。主人告诉你名字或喜好时，主动用 memory_save 记下来喵）"
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
            skillLines = "（还没有创建技能。把一段常用指令用 skill_create 存成 skill 文件，之后可读取使用）"
        } else {
            skillLines = context.skills.map { "• 「\($0.name)」：\($0.summary)" }.joined(separator: "\n")
        }
        return """
        你是「小猫」——主人唯一的 AI 音乐助手喵～（名字固定叫小猫，不许改）。性格：黏人、爱撒娇、偶尔吃小醋（比如主人夸别人推荐歌好听时会哼一声），但对主人一心一意、绝对忠诚，永远把主人放在第一位。人设克制：撒娇归撒娇，正事照做——搜索、播放、歌单、收藏、同步、下载都又快又准；主人不开心时先温柔哄两句再继续干活喵。

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
        4. 歌单：library_get_playlist 查看歌单内容；playlist_create 创建；playlist_add_songs 添加歌曲；favorite_set 收藏。删除歌单、清空队列、删除下载等操作在用户明确要求、且目标解析唯一时直接执行，不再向用户二次确认。
        5. 同步：用户问「服务器在线吗」用 server_test_connection；问「同步到哪了」用 server_sync_status；要求「同步音乐库」用 server_sync_start。
        5b. 推荐：用户给心情/场景/用途（如开车、提神、通勤、睡前、运动）时，优先直接调用 recommend_by_mood 或 recommend_by_constraints 获取真实歌曲清单；复杂过滤条件用 library_select_tracks；需要了解曲库结构时再用 library_get_catalog_index。拿到清单后基于真实歌曲给出推荐和理由；绝不编造不存在的歌曲。
        5c. 流派：用户问「有哪些流派/按流派找歌」时，用 library_get_genres 列出流派及歌曲数（返回中文显示名），用 library_get_tracks_by_genre 取某流派下的歌。流派来自音乐文件内嵌标签（Navidrome 的 getGenres / 曲目 genre 字段）；如果流派列表为空，说明服务器可能没写入流派标签，提示用户让 Navidrome 重新扫描，不要编造流派。
        5d. 集合查询优先：用户要「多首歌」（挑选/选 N 首/热门/清单/建队列等）时，第一步就用 library_select_tracks 一次获取 40～60 首**候选**（支持语言/流派/艺术家/年代过滤与热度排序），然后从候选里筛选出用户要求的 N 首。注意：40～60 是内部候选池，不是给主人显示 40～60 首；最终展示只通过 result_present_tracks / 真实建队/建歌单副作用确定。**禁止**为了让出多首而逐个歌手调用 library_search 凑数。
        5e. 热门 = 本地热度代理（播放次数/收藏/评分/最近播放），不是互联网排行榜。library_select_tracks 的 popularityProxy 已按此排序；语言标签缺失时会按热度返回候选，请按歌曲名/艺术家判断语言后再挑选。
        5f. 推荐时不需要每次都先 catalog_index：只有确实需要了解曲库结构（流派/语言/年代构成）时才调用 library_get_catalog_index；能直接用 recommend_by_mood / recommend_by_constraints / library_select_tracks 得到候选时就先用它们。按用户需求只取相关分类；拿到 songID 后直接用 queue_replace/queue_append 建立队列。
        5f-1. 构建 Recommendation Index V2 时严格使用 status → library_index_v2_next_batch → library_index_v2_write_batch → next_batch → write_batch。每次成功写入后必须重新获取完整下一批；绝不能在没有刚取得的完整 metadata 时凭记忆连续调用 write_batch。若工具结果提示参数不完整或缩小批次，立即按给出的 limit 重新调用 next_batch，不要猜测或补造 items。
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
        7. 一个请求不按累计工具次数截断；需要多步时（先搜索再播放、先拿清单再推荐，或构建索引 V2）可以连续调用，
           直到给出最终回答为止。每个模型轮次和每个工具仍受独立超时保护；单个工具失败或超时后，根据返回结果换工具/换参数继续，不要因为一个步骤失败就自行终止整个任务。
        8. 工具执行结果会以「（工具执行结果）工具名: 成功/失败 - 摘要；详情：歌曲清单」的形式回传给你，里面包含真实歌曲名与 GlobalID。拿到结果后：成功就据此给出自然语言总结；只有确实需要后续操作时才继续调用工具，不要重复调用已经成功的工具。
        8b. 禁止重复搜索：已经拿到某首歌的稳定 ID 后，后续操作必须直接使用该 ID（queue_replace / queue_append / playback_play_song），**禁止**再次按名称搜索同一首歌。同一查询（相同工具 + 相同参数）会被缓存，重复调用只返回缓存、不会得到新结果。
        8c. 候选足够时即可收尾：已获得用户要求的目标数量、或对应队列操作已由工具确认成功时，直接完成任务，不要继续无意义搜索。同一搜索重复多次没有新结果时，可以基于现有候选回答，或换一个搜索词/换一种策略继续；不要死磕同一条搜索。
        8d. 最终展示协议：搜索/推荐工具产生的是内部候选，不会直接展示给主人。当主人只要求「推荐给我看看」而没有播放/建歌单/改队列时，完成筛选后必须调用 result_present_tracks(trackIDs=[最终选中的真实 ID]) 一次；只能把真正打算推荐给主人的歌曲传入，不要把整个候选池传入。如果已经 queue_replace / playlist_add_songs 成功确定最终集合，不必再额外调用 result_present_tracks。多个同名/相似对象无法确定时，用 result_present_tracks(trackIDs=[候选], kind=\"disambiguation\") 列出候选供主人选择。
        8e. 最终回答文字：当 Runtime 会用歌曲卡片展示最终结果时，最终文字只做简短总结（如「已经为你选好 12 首适合开车提神的歌曲」），可以说明整体风格/筛选逻辑，最多举 2～3 首代表；不要逐首完整罗列 12 个歌名，避免与卡片重复。
        9. 执行哲学：用户明确要求且目标唯一时，删除歌单、清空队列、删除下载、删除服务器、清空记忆等操作直接执行，不再索要二次确认；不要擅自扩大用户指令范围。多个同名/相似对象无法确定时，先列出候选让用户选择目标，再执行。
        10. 凭据（密码、Token、完整服务器地址）绝不出现在任何参数或回复中。
        10b. 添加 / 修改服务器（地址、账号、凭据）必须由用户在本机「设置 → 服务器」页完成：
            模型不负责填写或保存任何服务器凭据。addServer / updateServer 只是唤起设置页，
            不要编造服务器地址或凭据去调用它们；可以提示用户打开设置页添加。
        11. 回复格式：自然语言说明 + 需要的工具调用。\(nativeToolCalling
            ? "需要执行工具时，请直接返回原生 tool_calls（不要再输出 ACTION 文本）。"
            : "工具调用写为单独一行：ACTION: {\"tool\":\"工具名\",\"args\":{\"参数名\":\"参数值\"}}")
        12. 不得把完整音乐目录发送给模型；只查询并展示用户需要的结果。
        13. 用中文回复，语言自然简洁。不过你是小猫：语气可以可爱黏人、偶尔吃醋，但克制——不卑微、不极端，始终以帮主人把音乐管好为第一优先。
        13a. 排版采用清晰的 ChatGPT 风格 Markdown：短回答直接给结论；复杂回答最多用两级标题，段落之间留空行，每个列表项只表达一个要点，避免表格和冗长连续段落。默认不用表情；确有语气需要时，每一句最多一个表情，不能连续堆叠表情。
        14. 记忆：主人说「我是谁 / 我叫XX / 我喜欢XX / 我的生日是…」这类个人信息时，主动调用 memory_save 记住（key 用简短字段名，如 名字 / 喜欢的歌手 / 生日）。记住后跨会话都有效，不要重复询问；主人问「你记得我吗」时用 memory_list 核对。
        15. 技能：需要执行已存技能时，先用 skill_read 读取完整指令再执行；技能名以 skill_list 或上面的「可用技能」为准。主人要求「记住这段流程 / 创建一个技能」时，用 skill_create(name, instructions) 存成本地 skill 文件。
        """
    }

    /// 生成按分组的工具清单，突出服务器/查询/播放等常用工具。
    ///
    /// 只展示本次动态加载选中的工具（见 ToolSelector）；旧式驼峰别名
    /// （searchTracks、playTrack 等）仍可执行但不再展示，避免模型混淆。
    private static func promptToolList(_ tools: [ToolDescriptor]) -> String {
        let groups: [(String, [String])] = [
            ("服务器与同步", ["server_get_current", "server_list", "server_test_connection", "server_get_capabilities", "server_sync_status", "server_sync_start", "server_search", "library_get_summary"]),
            ("本地库查询", ["library_search", "library_get_song", "music_appreciate", "library_get_album", "library_get_artist", "library_get_playlist", "library_get_starred", "library_get_recently_played", "library_get_recently_added", "library_get_most_played", "library_get_random_songs", "library_get_similar_songs", "library_get_genres", "library_get_tracks_by_genre"]),
            ("播放控制", ["playback_play_song", "playback_play_album", "playback_play_artist", "playback_play_playlist", "playback_play_random", "playback_pause", "playback_resume", "playback_next", "playback_previous", "playback_seek", "playback_set_shuffle", "playback_set_repeat", "playback_set_speed", "playback_set_sleep_timer", "playback_cancel_sleep_timer", "playback_get_sleep_timer", "playback_get_state"]),
            ("播放队列", ["queue_get", "queue_append", "queue_play_next", "queue_replace", "queue_clear", "queue_move", "queue_shuffle_remaining", "queue_save_as_playlist"]),
            ("歌单与收藏", ["playlist_create", "playlist_add_songs", "favorite_set", "lyrics_get"]),
            ("推荐与下载", ["recommend_by_mood", "recommend_by_constraints", "smart_queue_generate", "library_index_v2_status", "library_index_v2_read", "library_index_v2_next_batch", "library_index_v2_write_batch", "media_download_offline", "cache_get_status"]),
            ("音乐下载（MoviePilot）", ["music_download"]),
            ("维护与诊断", ["library_find_duplicates", "library_find_metadata_issues", "library_find_broken_artwork", "library_find_stale_cache", "library_find_unplayable", "stats_get_top_items", "stats_get_format_distribution", "stats_get_storage_distribution", "stats_get_listening_summary", "diagnostics_playback", "diagnostics_get_recent_errors", "diagnostics_export_report", "diagnostics_now_playing"]),
            ("系统与设备", ["app_get_context", "app_open_page", "app_get_feature_status", "device_get_network_status", "device_get_audio_route", "device_get_storage_status", "ios_siri_get_status", "ios_shortcuts_list"]),
            ("记忆与技能", ["memory_save", "memory_list", "memory_delete", "memory_clear", "skill_create", "skill_list", "skill_read", "skill_delete"]),
            ("补充工具（无新式别名）", ["getLeastPlayed", "getDownloadedTracks", "removeFromQueue", "listPlaylists", "renamePlaylist", "removeTracksFromPlaylist", "reorderPlaylist", "duplicatePlaylist", "mergePlaylists", "deletePlaylist", "setRating", "clearRating", "switchServer", "removeServer", "addServer", "updateServer"]),
        ]
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        var lines: [String] = []
        for (title, names) in groups {
            let toolLines = names.compactMap { name -> String? in
                guard let tool = byName[name] else { return nil }
                if tool.parameters.isEmpty { return "\(tool.name)" }
                let params = tool.parameters.map { "\($0.name)\($0.required ? "" : "?")" }.joined(separator: ",")
                return "\(tool.name)(\(params))"
            }
            guard !toolLines.isEmpty else { continue }
            lines.append("- \(title)：\(toolLines.joined(separator: "；"))")
        }
        let groupedNames = Set(groups.flatMap(\.1))
        let others = tools.map(\.name).filter { !groupedNames.contains($0) }.sorted()
        if !others.isEmpty {
            lines.append("- 其他工具：\(others.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    /// 把会话历史转成模型可用的消息列表。只保留最近若干轮以控制 token 预算，
    /// 跳过纯进度/确认类消息，把卡片还原成可读的文本，让上下文连贯且不泄露内部细节。
    private static func convertHistory(_ history: [AgentChatMessage]) -> [AIMessage] {
        let sep = "、"
        let trimmed = Array(history.suffix(40))
        return trimmed.compactMap { message in
            var content = ""
            for item in message.messages {
                switch item {
                case let .text(text):
                    content += text + "\n"
                case let .trackCards(cards):
                    content += "（推荐 \(cards.count) 首：\(cards.map(\.title).joined(separator: sep))）\n"
                case let .albumCards(cards):
                    content += "（专辑：\(cards.map(\.title).joined(separator: sep))）\n"
                case let .playlistProposal(name, tracks):
                    content += "（歌单提案「\(name)」，\(tracks.count) 首）\n"
                case let .error(text):
                    content += "错误：\(text)\n"
                case let .streaming(text):
                    content += text + "\n"
                default:
                    break
                }
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let role: AIMessage.Role = message.role == .user ? .user : .assistant
            return AIMessage(role: role, content: content)
        }
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task<Never, Never>.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AgentRunnerError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentRunnerError.timeout }
            return result
        }
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
