import AIKit
import Domain
import Foundation
import LocalCatalog

/// 受控工具调用 Agent 的执行引擎。
///
/// 流程：用户文本 →（可选 LLM 规划）→ 权限检查 → 本地工具执行 → 结果回传 → UI 渲染。
/// 硬性约束：每一轮模型请求和每一次工具执行都有独立超时；支持取消与防循环。
/// 不以累计工具次数截断任务，避免长任务在进展正常时被人为暂停；一旦某一步超时，
/// 立即停止当前任务并保留此前已成功落库的结果。破坏性操作仍需确认。
public struct AgentRunner {
    /// 单个工具调用的最长执行时间。超过后取消该调用并结束整项 Agent 任务，
    /// 防止某个网络/系统服务工具卡住而让任务无限悬挂。
    public static let toolExecutionTimeout: TimeInterval = 6 * 60
    /// 模型每一轮的总响应时限。长回答、复杂规划和批量 JSON 分类都可能持续数分钟；
    /// 整项任务没有总轮数上限，但每个独立模型请求最多等待六分钟。
    public static let roundTimeout: TimeInterval = 6 * 60
    /// 推荐索引 V2 与普通模型轮次采用相同的六分钟上限，保留独立常量便于未来
    /// 按任务类型单独调节。
    public static let recommendationIndexRoundTimeout: TimeInterval = 6 * 60

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

    /// 执行一次用户请求。
    /// - Parameters:
    ///   - provider: 可用时为 LLM 规划；为 nil 时走本地规则降级。
    ///   - confirm: 破坏性/需确认操作的裁决回调（返回 true 表示用户批准）。
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
        intent: AgentTaskIntent? = nil,
        policy: AgentTaskPolicy? = nil,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentProgress) async -> Void = { _ in }
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
                intent: intent ?? AgentIntentClassifier.classify(userText),
                policy: policy ?? AgentTaskPolicy.policy(for: intent ?? AgentIntentClassifier.classify(userText)),
                confirm: confirm,
                emit: emit,
                log: log,
                progress: progress
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
    /// - 任一模型轮次或工具调用超时 → 取消该步骤并明确停止任务；此前成功操作保留。
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
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void,
        progress: @escaping @Sendable (AgentProgress) async -> Void
    ) async {
        // 动态工具加载：只向模型暴露与本次意图相关的工具，降低 schema 对上下文的占用。
        let selectedTools = ToolSelector.select(for: userText, intent: intent, policy: policy, all: AgentToolRegistry.all)
        let isRecommendationIndexTask = Self.isRecommendationIndexTask(userText, history: history)
        let requiresCompleteRecommendationIndex = Self.requiresCompleteRecommendationIndex(userText, history: history)
        let requestTimeout = isRecommendationIndexTask
            ? recommendationIndexRoundTimeout
            : roundTimeout
        let toolDefinitions = provider.supportsToolCalling
            ? ToolSelector.toolDefinitions(from: selectedTools)
            : []

        var taskState = AgentTaskState(intent: intent, goal: userText)
        var privacy = AIPrivacyPermissions()
        privacy.allowsMetadata = context.allowsMetadata
        privacy.allowsLyrics = context.allowsLyrics
        privacy.allowsPlaybackHistory = context.allowsHistory
        var conversation = AgentContextBuilder.build(
            systemPrompt: Self.systemPrompt(
                context: context,
                tools: selectedTools,
                nativeToolCalling: provider.supportsToolCalling
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
        // 索引任务没有至少一次真实的本地工具结果时，模型的自然语言不能被视为完成。
        // 这能阻止「工具不可用 / 网络断开」之类的模型臆测伪装成任务执行结果。
        var hasExecutedRecommendationIndexTool = false
        var indexToolRepairAttempts = 0
        // 全量索引任务中，只要状态仍有待分类或工具已经给出了下一批，模型不能用自然语言提前结束。
        var recommendationIndexHasPendingWork = false
        var recommendationIndexNextBatchIsAvailable = false
        var indexCompletionRepairAttempts = 0
        // 音乐清单（歌曲/专辑/歌单提案）在整轮任务里累积，只在最终回答时展示一次，
        // 避免执行过程中（搜索/加歌等中间步骤）频繁弹出清单。
        var bufferedCards: [AgentMessage] = []
        // 任务工作集：任务级结果缓存、重复调用保护、候选/队列统计、诊断轨迹。
        var ws = AgentTaskWorkingSet()

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

            // 显式指定输出上限：Agent 回复必须完整，不受历史默认 1_200 影响。
            // 8_192 是主流 OpenAI 兼容模型通用的最大输出上限（见
            // AIKit.auralisDefaultMaxOutputTokens 的注释依据）。
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
                        if isRecommendationIndexTask {
                            await emit(AgentChatMessage(role: .assistant, messages: [.error(Self.recommendationIndexFailureText(error: error))]))
                            return
                        }
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
                    if isRecommendationIndexTask {
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(Self.recommendationIndexFailureText(error: error))]))
                        return
                    }
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

            // 解析本轮工具调用：原生 tool_calls 优先（流式事件收集），文本 ACTION 兜底。
            let streamedText = outcome.text
            let nativeCalls = nativeMode ? outcome.toolCalls : []
            let textActions = nativeCalls.isEmpty ? parseActions(from: streamedText) : []

            if nativeCalls.isEmpty && textActions.isEmpty {
                // 模型已输出最终回答 → 正常终止本轮任务。
                // 流式收尾：Coordinator 会把 in-flight 流式气泡原地定型为该最终文本，
                // 不会出现「流式半成品 + 成品」两条重复气泡。
                let reply = Self.formatAssistantReply(streamedText.trimmingCharacters(in: .whitespacesAndNewlines))
                if isRecommendationIndexTask, !hasExecutedRecommendationIndexTool {
                    // 原生接口偶尔会返回正文而非 function_call；先明确纠正一次，
                    // 仍不调用工具时再如实失败，绝不把模型的解释当作索引结果。
                    if indexToolRepairAttempts == 0 {
                        indexToolRepairAttempts += 1
                        conversation.append(AIMessage(role: .assistant, content: reply))
                        conversation.append(AIMessage(
                            role: .user,
                            content: "系统校验：推荐索引 V2 尚未执行任何工具。不要解释工具是否可用，必须立即调用 library_index_v2_status；只有得到真实工具结果后才能回复。"
                        ))
                        continue
                    }
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(
                        "推荐索引 V2 未开始：模型连续两次没有返回工具调用，因此没有读取状态、没有取歌曲、也没有写入任何分类。请检查当前模型是否支持 OpenAI function calling；本次不会降级为普通推荐。"
                    )]))
                    return
                }
                if requiresCompleteRecommendationIndex, recommendationIndexHasPendingWork {
                    if indexCompletionRepairAttempts == 0 {
                        indexCompletionRepairAttempts += 1
                        conversation.append(AIMessage(role: .assistant, content: reply))
                        conversation.append(AIMessage(
                            role: .user,
                            content: recommendationIndexNextBatchIsAvailable
                                ? "系统校验：推荐索引 V2 仍有待分类歌曲，当前任务要求一次性完成全部索引。上一条工具结果已经提供了下一批元数据；不要输出总结，必须立即调用 library_index_v2_write_batch 写回这一批。仅当工具结果明确显示待分类为 0 时才可结束。"
                                : "系统校验：推荐索引 V2 仍有待分类歌曲，当前任务要求一次性完成全部索引。不要输出总结，必须立即调用 library_index_v2_next_batch(limit=80) 取得首批，再继续写入。仅当工具结果明确显示待分类为 0 时才可结束。"
                        ))
                        continue
                    }
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(
                        "推荐索引 V2 未完成：仍有待分类歌曲，但模型连续两次没有继续写入下一批。没有把任务误报为完成；请检查当前模型的 function calling 输出。"
                    )]))
                    return
                }
                guard !reply.isEmpty else {
                    if isRecommendationIndexTask {
                        await emit(AgentChatMessage(role: .assistant, messages: [.error(
                            "推荐索引 V2 未开始：模型返回了空内容，未执行任何索引工具，也没有写入分类。"
                        )]))
                        return
                    }
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("模型这次返回了空内容，已改用本地能力处理。")]))
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
                await Self.emitBufferedCards(bufferedCards, emit: emit)
                await emit(AgentChatMessage(role: .assistant, messages: [.text(reply)]))
                return
            }

            // 有工具调用：先把 assistant 消息（含 tool_calls）写入对话，再逐条执行回灌。
            if nativeMode, !nativeCalls.isEmpty {
                conversation.append(AIMessage(role: .assistant, content: streamedText, toolCalls: nativeCalls))
            } else {
                conversation.append(AIMessage(role: .assistant, content: streamedText))
            }

            // 统一调用视图：原生调用带稳定 id，文本 ACTION 合成 text-N。
            let calls: [(id: String?, name: String, args: [String: String])]
            if nativeMode, !nativeCalls.isEmpty {
                calls = nativeCalls.map {
                    (id: $0.id, name: $0.name, args: Self.parseArguments($0.arguments))
                }
            } else {
                calls = textActions.enumerated().map {
                    (id: "text-\($0.offset)", name: $0.element.tool, args: $0.element.args)
                }
            }

            var toolMessages: [AIMessage] = []
            // 本轮统计（用于合并工具轨迹展示）。
            var roundSearchCalls = 0
            var roundToolNames: Set<String> = []

            for call in calls {
                toolStepCount += 1
                taskState.progress.toolCalls += 1
                taskState.recordToolCall(name: call.name, arguments: call.args)
                let diagnosticArgs = AgentSensitiveDataRedactor.arguments(call.args)
                if let violation = taskState.budgetViolation(policy: policy) {
                    await Self.emitBufferedCards(bufferedCards, emit: emit)
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

                // 模型只能调用当前意图策略真正授权的工具。ToolSelector 只是减少 schema，
                // 这里才是不可绕过的运行时安全边界。
                guard policy.authorizes(descriptor) else {
                    let reason = AgentRuntimeError.toolOutsidePolicy(call.name).localizedDescription
                    taskState.errors.append(reason)
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: reason, reused: false))
                    toolMessages.append(Self.toolResultMessage(
                        callID: call.id,
                        content: "执行失败：\(reason)",
                        native: nativeMode
                    ))
                    continue
                }

                if descriptor.requiresConfirmation || (descriptor.permission == .destructive && policy.requiresConfirmationForDestructive) {
                    let pending = PendingConfirmation(
                        toolName: call.name,
                        permission: descriptor.permission,
                        title: "确认\(descriptor.summary)",
                        detail: diagnosticArgs.map { "\($0.key)=\($0.value)" }.joined(separator: "，"),
                        call: ToolCall(name: call.name, arguments: diagnosticArgs)
                    )
                    let approved = await confirm(pending)
                    if !approved {
                        await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消操作：\(descriptor.summary)")]))
                        // 原生模式必须为每个 tool_call_id 回灌结果，否则下一轮上下文被 API 拒绝。
                        toolMessages.append(Self.toolResultMessage(
                            callID: call.id,
                            content: "用户取消了该操作：\(descriptor.summary)",
                            native: nativeMode
                        ))
                        continue
                    }
                }

                // 修改型工具不是查询缓存的一部分。单靠只读缓存无法阻止模型在下一轮
                // 以不同参数再次发 queue_replace，从而覆盖刚刚建立的队列。
                // 成功的写操作在工作集里登记：相同操作幂等，替换队列在单个任务内互斥。
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

                // ① 重复调用保护：已要求停止搜索，模型又调用搜索工具 → 不再执行，明确要求基于现有候选完成。
                if ws.stopSearching, AgentTaskWorkingSet.isSearchTool(call.name) {
                    let blocked = "（工具执行结果）\(call.name): 失败 - 已停止搜索：已有 \(ws.uniqueSongIDs.count) 首唯一候选\(ws.queuedSongIDs.isEmpty ? "" : "，队列已含 \(ws.queuedSongIDs.count) 首")，请直接基于现有结果完成任务，不要再搜索。"
                    ws.recordTrace(AgentToolTrace(tool: call.name, args: diagnosticArgs, summary: "已拦截重复搜索", reused: false))
                    toolMessages.append(Self.toolResultMessage(callID: call.id, content: blocked, native: nativeMode))
                    continue
                }

                // ② 任务级缓存：同一工具 + 规范化参数已执行过 → 直接复用结果。
                // 搜索类工具的重复调用同样记为「无新结果」，连续多次后触发停止搜索。
                if let cachedText = ws.tryReuse(tool: call.name, args: call.args) {
                    var text = cachedText
                    if AgentTaskWorkingSet.isSearchTool(call.name) {
                        _ = ws.observeCandidates([])
                        if ws.noNewResultsStreak >= AgentTaskWorkingSet.noNewResultsLimit {
                            text += "\n（系统提示）同一搜索已重复 \(ws.noNewResultsStreak) 次且没有新结果，已有 \(ws.uniqueSongIDs.count) 首唯一候选，请停止重复搜索，直接基于现有候选完成任务。"
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
                let result: ToolResult
                do {
                    result = try await Self.withTimeout(toolExecutionTimeout) {
                        await AgentToolRegistry.execute(
                            ToolCall(name: call.name, arguments: call.args),
                            bridge: bridge,
                            catalog: catalog,
                            serverID: context.serverID,
                            systemService: systemService
                        )
                    }
                } catch is CancellationError {
                    await Self.emitBufferedCards(bufferedCards, emit: emit)
                    await emit(AgentChatMessage(role: .assistant, messages: [.text("已取消。")]))
                    return
                } catch AgentRunnerError.timeout {
                    await Self.emitBufferedCards(bufferedCards, emit: emit)
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(
                        "工具 \(call.name) 超过 \(Int(toolExecutionTimeout)) 秒仍未完成，已停止本次任务；此前已成功执行的操作会保留。"
                    )]))
                    return
                } catch {
                    await Self.emitBufferedCards(bufferedCards, emit: emit)
                    await emit(AgentChatMessage(role: .assistant, messages: [.error(
                        "工具 \(call.name) 执行中断（\(Self.errorText(error))），已停止本次任务；此前已成功执行的操作会保留。"
                    )]))
                    return
                }
                if result.success, Self.recommendationIndexToolNames.contains(call.name) {
                    hasExecutedRecommendationIndexTool = true
                }
                if result.success, result.permission != .readOnly {
                    ws.recordSuccessfulSideEffect(tool: call.name, args: call.args, summary: result.summary)
                }
                if result.success {
                    taskState.recordProgress(action: "\(call.name): \(result.summary)")
                } else {
                    taskState.recordNoProgress()
                    taskState.errors.append(result.summary)
                }
                if result.success, requiresCompleteRecommendationIndex {
                    recommendationIndexHasPendingWork = Self.recommendationIndexResultHasPendingWork(
                        tool: call.name,
                        summary: result.summary
                    ) ?? recommendationIndexHasPendingWork
                    recommendationIndexNextBatchIsAvailable = Self.recommendationIndexNextBatchIsAvailable(
                        tool: call.name,
                        summary: result.summary
                    ) ?? recommendationIndexNextBatchIsAvailable
                }
                // 音乐清单只在整轮结束时统一展示；中间步骤只回灌给模型、不弹给用户。
                if let payload = result.payload, Self.isPresentableCard(payload) {
                    bufferedCards.append(payload)
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
                    // 连续多次无新结果 → 明确要求模型停止搜索。
                    if noNew, ws.noNewResultsStreak >= AgentTaskWorkingSet.noNewResultsLimit {
                        resultText += "\n（系统提示）搜索已连续 \(ws.noNewResultsStreak) 次没有新结果，已有 \(ws.uniqueSongIDs.count) 首唯一候选，请停止重复搜索，直接基于现有候选完成任务。"
                    }
                }
                if AgentTaskWorkingSet.isSearchTool(call.name) == false, AgentTaskWorkingSet.queueWritingTools.contains(call.name) {
                    let queued = AgentTaskWorkingSet.songIDs(from: call.args)
                    if !queued.isEmpty { ws.noteQueued(queued) }
                }
                resultText = ContextManager.truncateToolResult(resultText, limit: Self.toolResultLimit(for: call.name))
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

    /// 只有展示型结果（歌曲/专辑清单、歌单提案）才值得在最终回答时展示。
    private static func isPresentableCard(_ message: AgentMessage) -> Bool {
        switch message {
        case .trackCards, .albumCards, .playlistProposal:
            return true
        default:
            return false
        }
    }

    /// 在整轮结束时统一展示缓冲的音乐清单（去重、限量）。
    private static func emitBufferedCards(
        _ cards: [AgentMessage],
        emit: @escaping @Sendable (AgentChatMessage) async -> Void
    ) async {
        let deduped = Self.dedupeCards(cards)
        guard !deduped.isEmpty else { return }
        await emit(AgentChatMessage(role: .assistant, messages: deduped))
    }

    /// 去重：同一首歌 / 同一张专辑只出现一次；歌曲清单每份最多 60 首，避免整库倾倒。
    private static func dedupeCards(_ cards: [AgentMessage]) -> [AgentMessage] {
        var seenTracks: Set<GlobalID> = []
        var seenAlbums: Set<GlobalID> = []
        var result: [AgentMessage] = []
        for card in cards {
            switch card {
            case let .trackCards(list):
                let fresh = list.filter { seenTracks.insert($0.globalID).inserted }.prefix(60)
                if !fresh.isEmpty { result.append(.trackCards(Array(fresh))) }
            case let .albumCards(list):
                let fresh = list.filter { seenAlbums.insert($0.globalID).inserted }
                if !fresh.isEmpty { result.append(.albumCards(Array(fresh))) }
            case .playlistProposal:
                result.append(card)
            default:
                break
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
    private static func parseArguments(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var args: [String: String] = [:]
        for (key, value) in object { args[key] = String(describing: value) }
        return args
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

    private static let recommendationIndexToolNames: Set<String> = [
        "library_index_v2_status",
        "library_index_v2_read",
        "library_index_v2_next_batch",
        "library_index_v2_write_batch",
    ]

    /// 除了本条输入外，也检查会话历史：用户在同一索引任务里只回复「继续」时，
    /// 仍需沿用索引的长时限和「必须有真实工具结果」约束。
    private static func isRecommendationIndexTask(_ userText: String, history: [AgentChatMessage]) -> Bool {
        let markers = ["推荐索引", "索引 v2", "index v2", "library_index_v2", "构建索引", "重建索引"]
        func containsMarker(_ text: String) -> Bool {
            let lower = text.lowercased()
            return markers.contains { lower.contains($0) }
        }
        if containsMarker(userText) { return true }
        return history.contains { message in
            message.messages.contains { item in
                switch item {
                case let .text(text), let .streaming(text), let .error(text):
                    return containsMarker(text)
                default:
                    return false
                }
            }
        }
    }

    /// 只有“构建/继续/全量处理”才强制跑到 0；单纯查看状态或读取分类仍允许正常结束。
    private static func requiresCompleteRecommendationIndex(_ userText: String, history: [AgentChatMessage]) -> Bool {
        let markers = ["构建", "重建", "继续", "处理", "分类", "一次性", "全部", "完成索引"]
        func hasMarker(_ text: String) -> Bool {
            let lower = text.lowercased()
            return markers.contains { lower.contains($0) }
        }
        if hasMarker(userText), isRecommendationIndexTask(userText, history: history) { return true }
        return history.contains { message in
            guard message.role == .user else { return false }
            let text = message.messages.compactMap { item -> String? in
                if case let .text(value) = item { return value }
                return nil
            }.joined(separator: " ")
            return isRecommendationIndexTask(text, history: []) && hasMarker(text)
        }
    }

    /// 返回 nil 表示该工具与“是否还有待处理批次”无关。
    private static func recommendationIndexResultHasPendingWork(tool: String, summary: String) -> Bool? {
        switch tool {
        case "library_index_v2_status", "library_index_v2_next_batch", "library_index_v2_write_batch":
            return !summary.contains("待分类 0") && !summary.contains("已完成，无待分类")
        default:
            return nil
        }
    }

    /// next_batch 的成功结果、或未完成 write_batch 的直接回灌，都会附带可立即写回的曲目元数据。
    private static func recommendationIndexNextBatchIsAvailable(tool: String, summary: String) -> Bool? {
        switch tool {
        case "library_index_v2_status":
            return false
        case "library_index_v2_next_batch", "library_index_v2_write_batch":
            return !summary.contains("待分类 0") && !summary.contains("已完成，无待分类")
        default:
            return nil
        }
    }

    private static func recommendationIndexFailureText(error: Error) -> String {
        "推荐索引 V2 未开始：模型请求失败（\(errorText(error))）。索引工具完全在本机 SQLite 数据库执行，此错误发生在请求模型规划工具调用的阶段；没有读取状态、没有取歌曲、没有写入分类。本次不会降级为普通推荐。"
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

    /// 工具结果回灌上限：曲库索引/分类清单允许更大体积（否则模型看不到曲库全貌）。
    private static func toolResultLimit(for tool: String) -> Int {
        if tool == "library_get_catalog_index" || tool == "library_get_catalog_tracks" {
            return ContextManager.maxIndexCharacters
        }
        if tool == "library_index_v2_next_batch" || tool == "library_index_v2_write_batch" || tool == "library_index_v2_read" {
            return 24_000
        }
        return ContextManager.maxToolResultCharacters
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
                    args[key] = String(describing: value)
                }
            }
            results.append((tool, args))
        }
        return results
    }

    public static func systemPrompt(context: Context, tools: [ToolDescriptor], nativeToolCalling: Bool) -> String {
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
        let memoryLines: String
        if context.memories.isEmpty {
            memoryLines = "（还没有记住关于主人的事情。主人告诉你名字或喜好时，主动用 memory_save 记下来喵）"
        } else {
            memoryLines = context.memories.map { "• \($0.key)：\($0.value)" }.joined(separator: "\n")
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
        4. 歌单：library_get_playlist 查看歌单内容；playlist_create 创建；playlist_add_songs 添加歌曲；favorite_set 收藏。删除歌单、替换歌单内容等破坏性操作由 Runner 向用户确认。
        5. 同步：用户问「服务器在线吗」用 server_test_connection；问「同步到哪了」用 server_sync_status；要求「同步音乐库」用 server_sync_start。
        5b. 推荐：用户要「推荐」时，必须先调用 recommend_by_mood（按心情）或 recommend_by_constraints（按约束）获取真实歌曲清单，再基于清单给出推荐和理由；绝不编造不存在的歌曲。工具结果会附带歌曲清单。
        5c. 流派：用户问「有哪些流派/按流派找歌」时，用 library_get_genres 列出流派及歌曲数（返回中文显示名），用 library_get_tracks_by_genre 取某流派下的歌。流派来自音乐文件内嵌标签（Navidrome 的 getGenres / 曲目 genre 字段）；如果流派列表为空，说明服务器可能没写入流派标签，提示用户让 Navidrome 重新扫描，不要编造流派。
        5d. 集合查询优先：用户要「多首歌」（挑选/选 N 首/热门/清单/建队列等）时，第一步就用 library_select_tracks 一次获取 40～60 首候选（支持语言/流派/艺术家/年代过滤与热度排序），然后从候选里挑选。**禁止**为了让出多首而逐个歌手调用 library_search 凑数。
        5e. 热门 = 本地热度代理（播放次数/收藏/评分/最近播放），不是互联网排行榜。library_select_tracks 的 popularityProxy 已按此排序；语言标签缺失时会按热度返回候选，请按歌曲名/艺术家判断语言后再挑选。
        5f. 推荐前先了解曲库：先用 library_get_catalog_index 查看流派/语言/年代/歌手构成；需要具体候选时用 library_get_catalog_tracks(category, value, limit) 取该分类的歌曲清单（只含元数据，无歌词/海报）。按用户需求只取相关分类，不要把全部分类一次性拉进对话；拿到 songID 后直接用 queue_replace/queue_append 建立队列。
        5f-0. 歌曲鉴赏：主人要求鉴赏/赏析/乐评/大众评价时，必须调用 music_appreciate。没有指定歌曲则省略 trackID，鉴赏当前播放曲目；指定歌曲时先 library_search 取得真实 trackID，再调用 music_appreciate。输出使用：`## 《歌名》鉴赏`、`### 音乐性`、`### 听感与场景`、`### 大众评价`、`### 版本信息`、`### 一句话结论` 六段；只保留有依据的段落。专业分析要区分“工具已核验事实”和“听感/常见观点”，不编造调性、BPM、歌词含义、平台评分、榜单、奖项、评论引语。大众评价没有可靠把握时，明确说“未接入实时评论数据”，再给出本地播放/收藏/评分这一可核验反馈。
        5f-1. AI 推荐索引 V2：仅当主人明确要求「构建 / 继续 / 更新 / 重建推荐索引 V2」时执行。先调 library_index_v2_status，再只调一次 library_index_v2_next_batch(limit=80) 取得首批。每次只能根据该批歌曲的标题、艺人、专辑、年份、流派、语言、时长、收藏、评分、播放次数分类，绝不请求或传输歌词、文件路径、播放地址。对本批每个 id 恰好生成一条 JSON：{"id":"…","moods":[…],"scenes":[…],"energy":1-10,"tempo":1-5,"acousticness":1-5,"danceability":1-5,"vocals":[…],"textures":[…],"styles":[…],"confidence":0-1}，随后立刻用 library_index_v2_write_batch(itemsJSON=这个 JSON 数组字符串) 写回。**每次写回成功后，工具结果会直接包含下一批元数据；此时禁止再调 next_batch，必须直接为该批生成 JSON 并再次 write_batch。**主人要求查看、统计、寻找已完成索引条目时，调用 library_index_v2_read；它可以按 dimension 和 value 筛选，并会返回完整标签，绝不能用 next_batch 代替。可用且只能使用：moods=平静/治愈/忧郁/浪漫/明亮/激昂/神秘/紧张/怀旧/温暖/冷冽/慵懒/梦幻/迷离/释然/孤独/甜蜜/愤怒/庄严/俏皮；scenes=深夜/清晨/通勤/学习/专注/运动/聚会/独处/旅行/雨天/驾车/工作/阅读/冥想/约会/派对/睡前/散步；vocals=女声/男声/童声/合唱/对唱/器乐/说唱/未知；textures=原声/电子/钢琴/吉他/贝斯/鼓组/弦乐/管乐/合成器/人声采样/现场/氛围/Lo-fi/失真；styles=流行/摇滚/民谣/爵士/古典/嘻哈/R&B/灵魂乐/电子/舞曲/金属/朋克/乡村/蓝调/雷鬼/世界音乐/原声带/氛围/轻音乐/实验。数值：energy 是能量强度 1-10，tempo 是速度感 1-5，acousticness 是原声感 1-5，danceability 是舞动性 1-5。缺乏可靠依据时使用中性数值和「未知」，不要臆造。写回后若仍有待分类，继续下一批，整个过程不要要求主人逐批确认、不要在批次间输出自然语言；完成后再简短报告进度。
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
        7. 一个请求不按累计工具次数截断；需要多步时（先搜索再播放、先拿清单再推荐，或构建索引 V2）可以连续调用，
           直到给出最终回答为止。每个模型轮次和每个工具仍受独立超时保护；某一步超时就停止当前任务并保留此前成功结果。
        8. 工具执行结果会以「（工具执行结果）工具名: 成功/失败 - 摘要；详情：歌曲清单」的形式回传给你，里面包含真实歌曲名与 GlobalID。拿到结果后：成功就据此给出自然语言总结；只有确实需要后续操作时才继续调用工具，不要重复调用已经成功的工具。
        8b. 禁止重复搜索：已经拿到某首歌的稳定 ID 后，后续操作必须直接使用该 ID（queue_replace / queue_append / playback_play_song），**禁止**再次按名称搜索同一首歌。同一查询（相同工具 + 相同参数）会被缓存，重复调用只返回缓存、不会得到新结果。
        8c. 已有候选足够时立即停止搜索：只要已获得 ≥ 目标数量的候选、或队列已建立（含 ≥ 20 首），就不要再调用任何搜索工具；直接建立队列 / 播放 / 给出最终回答。若工具结果提示「已停止搜索」或「连续多次没有新结果」，必须停止搜索并基于现有候选完成任务。
        9. 需要用户确认的破坏性操作（删除歌单/清空队列/删除服务器等）照常发出 ACTION，Runner 会向用户索取确认。
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
