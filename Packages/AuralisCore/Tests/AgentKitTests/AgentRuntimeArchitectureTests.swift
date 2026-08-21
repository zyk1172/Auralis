import AIKit
@testable import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

@Suite("AgentRuntime architecture")
struct AgentRuntimeArchitectureTests {
    @Test(arguments: [
        ("鉴赏正在播放的歌曲", AgentTaskIntent.musicAppreciation),
        ("下载这张专辑", AgentTaskIntent.musicDownload),
        ("为什么播放失败", AgentTaskIntent.diagnostics),
        ("同步 Navidrome 服务器", AgentTaskIntent.serverManagement),
        ("把这些歌加入歌单", AgentTaskIntent.playlistManagement),
        ("替换当前队列", AgentTaskIntent.queueManagement),
        ("推荐几首深夜音乐", AgentTaskIntent.musicDiscovery),
        ("暂停播放", AgentTaskIntent.playbackControl),
        ("搜索周杰伦", AgentTaskIntent.librarySearch),
        ("记住我喜欢爵士", AgentTaskIntent.memoryManagement),
    ])
    func intentClassification(input: String, expected: AgentTaskIntent) {
        #expect(AgentIntentClassifier.classify(input) == expected)
    }

    @Test func conversationPolicyAuthorizesEveryRegisteredTool() {
        // Intent 不再是能力边界：conversation 也能调用全部已注册工具。
        let policy = AgentTaskPolicy.policy(for: .conversation)
        for tool in AgentToolRegistry.all {
            #expect(policy.authorizes(tool), "conversation 应允许 \(tool.name)")
        }
    }

    @Test func playbackCanCallServerMutationUnderPermissivePolicy() {
        let policy = AgentTaskPolicy.policy(for: .playbackControl)
        let remove = AgentToolRegistry.descriptor(for: "removeServer")!
        #expect(policy.authorizes(remove))
    }

    @Test func serverManagementCanReadAndMutateServer() {
        let policy = AgentTaskPolicy.policy(for: .serverManagement)
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "server_get_current")!))
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "removeServer")!))
    }

    @Test func appreciationCanAlsoWriteQueue() {
        let policy = AgentTaskPolicy.policy(for: .musicAppreciation)
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "music_appreciate")!))
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "queue_replace")!))
        #expect(policy.budget.maxOutputTokens == AgentTaskBudget.followProvider)
    }

    @Test func runtimeAllowsRegisteredToolForAnyPolicy() async throws {
        let runtime = AgentRuntime()
        // 已注册工具不再因 policy 被拒。
        let descriptor = try await runtime.authorize(tool: "removeServer", policy: .policy(for: .playbackControl))
        #expect(descriptor.name == "removeServer")
    }

    @Test func grantedScopeIsDiagnosticsOnlyNotAnAuthorizationBoundary() {
        let conversation = AgentTaskPolicy.policy(for: .conversation)
        let appreciation = AgentTaskPolicy.policy(for: .musicAppreciation)
        let tool = AgentToolRegistry.descriptor(for: "music_appreciate")!
        #expect(tool.requiredScopes == [.catalogRead, .externalRead])
        // scope 只做日志/诊断：conversation 与 appreciation 都能调用该工具。
        #expect(conversation.authorizes(tool))
        #expect(appreciation.authorizes(tool))
    }

    @Test func discoveryIntentGrantsQueueAndPlaybackTools() {
        let discovery = AgentTaskPolicy.policy(for: .musicDiscovery)
        let queueAppend = AgentToolRegistry.descriptor(for: "queue_append")!
        let playSong = AgentToolRegistry.descriptor(for: "playback_play_song")!
        #expect(discovery.authorizes(queueAppend))
        #expect(discovery.authorizes(playSong))
    }

    @Test func unknownToolIsRejected() async {
        let runtime = AgentRuntime()
        await #expect(throws: AgentRuntimeError.toolOutsidePolicy("not_real")) {
            _ = try await runtime.authorize(tool: "not_real", policy: .policy(for: .conversation))
        }
    }

    @Test func toolSelectionIsNotPolicyFiltered() {
        let policy = AgentTaskPolicy.policy(for: .musicAppreciation)
        let tools = ToolSelector.select(for: "鉴赏并删除服务器", intent: .musicAppreciation, policy: policy, all: AgentToolRegistry.all)
        #expect(tools.contains { $0.name == "music_appreciate" })
        // 关键词命中服务器工具时，不再被 policy 过滤掉；只暴露 canonical 名（server_remove）。
        #expect(tools.contains { $0.name == "server_remove" })
        #expect(!tools.contains { $0.name == "removeServer" })
        #expect(tools.allSatisfy(policy.authorizes))
    }

    @Test func modelRoundBudgetStopsAtLimit() {
        var state = AgentTaskState(intent: .conversation, goal: "test")
        let policy = AgentTaskPolicy(intent: .conversation, scopes: [], allowedToolGroups: [], budget: .init(maxModelRounds: 2))
        state.progress.modelRounds = 2
        #expect(state.budgetViolation(policy: policy) == .modelRoundBudgetExceeded)
    }

    @Test func noProgressNeverTerminates() {
        var state = AgentTaskState(intent: .conversation, goal: "test")
        let policy = AgentTaskPolicy(intent: .conversation, scopes: [], allowedToolGroups: [], budget: .init(maxNoProgressRounds: 2))
        for _ in 0..<10 { state.recordNoProgress() }
        #expect(state.budgetViolation(policy: policy) == nil)
    }

    @Test func progressResetsNoProgressCount() {
        var state = AgentTaskState(intent: .conversation, goal: "test")
        state.recordNoProgress()
        state.recordProgress(action: "read local catalog")
        #expect(state.progress.noProgressRounds == 0)
        #expect(state.completedActions == ["read local catalog"])
    }

    @Test func wallClockBudgetIsDeterministic() {
        let start = Date(timeIntervalSince1970: 100)
        let state = AgentTaskState(intent: .conversation, goal: "test", startedAt: start)
        let policy = AgentTaskPolicy(intent: .conversation, scopes: [], allowedToolGroups: [], budget: .init(wallClockSeconds: 5))
        #expect(state.budgetViolation(policy: policy, now: start.addingTimeInterval(6)) == .wallClockBudgetExceeded)
    }

    @Test func evidenceClampsConfidence() {
        let high = AgentEvidence(source: .server, provenance: "server", confidence: 2, claim: "exists")
        let low = AgentEvidence(source: .modelInference, provenance: "model", confidence: -1, claim: "guess")
        #expect(high.confidence == 1)
        #expect(low.confidence == 0)
    }

    @Test func configuredCapabilitiesUse256KContextAnd16KOutput() {
        let capabilities = ModelCapabilities.conservative
        #expect(capabilities.maxContextTokens == 256_000)
        #expect(capabilities.maxOutputTokens == 16_000)
        #expect(capabilities.maxContextTokens > capabilities.maxOutputTokens)
    }

    @Test func contextBudgetReservesOutputAndProtocolSpace() {
        let capabilities = ModelCapabilities(maxContextTokens: 256_000, maxOutputTokens: 16_000)
        let budget = ContextManager.inputBudget(capabilities: capabilities, requestedInputBudget: 256_000, reservedOutputTokens: 16_000)
        #expect(budget == 238_976)
    }

    @Test func smallProviderWindowNeverProducesAnOversizedInputBudget() {
        let capabilities = ModelCapabilities(maxContextTokens: 4_096, maxOutputTokens: 2_048)
        let budget = ContextManager.inputBudget(
            capabilities: capabilities,
            requestedInputBudget: 256_000,
            reservedOutputTokens: capabilities.maxOutputTokens
        )
        #expect(budget == 1_024)
        #expect(budget + capabilities.maxOutputTokens + ContextManager.protocolReserveTokens <= capabilities.maxContextTokens)
    }

    @Test func tokenTrimmingCountsSystemPromptAndNativeToolCalls() {
        let system = AIMessage(role: .system, content: String(repeating: "系", count: 120))
        let older = AIMessage(role: .user, content: String(repeating: "旧", count: 80))
        let call = AIToolCall(id: "call-1", name: "library_search", arguments: String(repeating: "x", count: 160))
        let newest = AIMessage(role: .assistant, content: "", toolCalls: [call])
        let budget = ContextManager.estimatedTokens(system) + ContextManager.estimatedTokens(newest)

        let trimmed = ContextManager.trimByTokens([system, older, newest], maxTokens: budget)

        #expect(trimmed == [system, newest])
        #expect(trimmed.reduce(0) { $0 + ContextManager.estimatedTokens($1) } <= budget)
    }

    @Test func cumulativeUsageDoesNotTripPerRequestTokenLimits() {
        var state = AgentTaskState(intent: .conversation, goal: "long task")
        state.progress.inputTokens = 900_000
        state.progress.outputTokens = 80_000
        #expect(state.budgetViolation(policy: .policy(for: .conversation)) == nil)
    }

    @Test func credentialsNeverEnterContext() {
        let state = AgentTaskState(intent: .conversation, goal: "hello")
        let messages = AgentContextBuilder.build(
            systemPrompt: "system",
            task: state,
            facts: [
                .init(kind: .publicAppState, label: "page", value: "home"),
                .init(kind: .credential, label: "token", value: "SUPER-SECRET"),
            ],
            history: [],
            permissions: AIPrivacyPermissions(),
            capabilities: .conservative,
            inputBudget: 8_000
        )
        #expect(messages.map(\.content).joined().contains("page=home"))
        #expect(!messages.map(\.content).joined().contains("SUPER-SECRET"))
    }

    @Test func privacyGatesLyricsAndHistory() {
        var permissions = AIPrivacyPermissions()
        permissions.allowsLyrics = false
        permissions.allowsPlaybackHistory = false
        let state = AgentTaskState(intent: .conversation, goal: "hello")
        let messages = AgentContextBuilder.build(
            systemPrompt: "system",
            task: state,
            facts: [
                .init(kind: .lyrics, label: "lyrics", value: "hidden lyrics"),
                .init(kind: .playbackHistory, label: "history", value: "hidden history"),
            ],
            history: [],
            permissions: permissions,
            capabilities: .conservative,
            inputBudget: 8_000
        )
        let text = messages.map(\.content).joined()
        #expect(!text.contains("hidden lyrics"))
        #expect(!text.contains("hidden history"))
    }

    @Test func legalToolPairsArePreserved() {
        let call = AIToolCall(id: "call-1", name: "library_search", arguments: "{}")
        let assistant = AIMessage(role: .assistant, content: "", toolCalls: [call])
        let tool = AIMessage(role: .tool, content: "ok", toolCallID: "call-1")
        let result = AgentContextBuilder.legalToolTranscript([assistant, tool])
        #expect(result == [assistant, tool])
    }

    @Test func orphanToolResultIsDropped() {
        let tool = AIMessage(role: .tool, content: "orphan", toolCallID: "missing")
        #expect(AgentContextBuilder.legalToolTranscript([tool]).isEmpty)
    }

    @Test func incompleteToolCallGroupIsDropped() {
        let calls = [
            AIToolCall(id: "a", name: "one", arguments: "{}"),
            AIToolCall(id: "b", name: "two", arguments: "{}"),
        ]
        let assistant = AIMessage(role: .assistant, content: "", toolCalls: calls)
        let oneResult = AIMessage(role: .tool, content: "ok", toolCallID: "a")
        #expect(AgentContextBuilder.legalToolTranscript([assistant, oneResult]).isEmpty)
    }

    @Test func taskSummaryContainsIntentAndCounts() {
        var state = AgentTaskState(intent: .diagnostics, goal: "why")
        state.recordProgress(action: "read log")
        state.evidence.append(.init(source: .localCatalog, provenance: "db", confidence: 1, claim: "track exists"))
        let summary = AgentContextBuilder.taskSummary(state)
        #expect(summary.contains("intent=diagnostics"))
        #expect(summary.contains("actions=1"))
        #expect(summary.contains("evidence=1"))
    }

    @Test func repeatedToolPatternNeverTerminates() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        let policy = AgentTaskPolicy(
            intent: .librarySearch,
            scopes: [],
            allowedToolGroups: [],
            budget: .init(maxRepeatedToolPattern: 2)
        )
        for _ in 0..<6 { state.recordToolCall(name: "library_search", arguments: ["query": "same"]) }
        #expect(state.repeatedToolPatternCount > 2)
        #expect(state.budgetViolation(policy: policy) == nil)
    }

    @Test func changingArgumentsBreaksRepeatedPattern() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        state.recordToolCall(name: "library_search", arguments: ["query": "one"])
        state.recordToolCall(name: "library_search", arguments: ["query": "two"])
        #expect(state.repeatedToolPatternCount == 1)
    }

    @Test(arguments: [
        (AIProviderError.httpStatus(429), AgentFailureKind.rateLimited),
        (AIProviderError.httpStatus(503), AgentFailureKind.serverUnavailable),
        (AIProviderError.httpStatus(401), AgentFailureKind.authentication),
        (AIProviderError.invalidEndpoint, AgentFailureKind.invalidConfiguration),
        (AIProviderError.malformedResponse(detail: "bad", retryable: false), AgentFailureKind.incompatibleResponse),
    ])
    func providerFailureClassification(error: AIProviderError, expected: AgentFailureKind) {
        #expect(AgentFailureClassifier.classify(error) == expected)
    }

    @Test func timeoutIsNotRetryable() {
        #expect(AgentFailureClassifier.classify(AgentRunnerError.timeout) == .timeout)
        #expect(!AgentFailureKind.timeout.isRetryable)
    }

    @Test func redactorRemovesCredentialsAndURLs() {
        let redacted = AgentSensitiveDataRedactor.arguments([
            "token": "secret-token",
            "baseURL": "https://private.example",
            "query": "music",
        ])
        #expect(redacted["token"] == "<redacted>")
        #expect(redacted["baseURL"] == "<redacted>")
        #expect(redacted["query"] == "music")
    }

    @Test func explicitIntentOverridesTextClassifier() {
        let policy = AgentTaskPolicyResolver.resolve(
            text: "播放并删除服务器",
            explicitIntent: .musicAppreciation
        )
        #expect(policy.intent == .musicAppreciation)
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "removeServer")!))
    }

    @Test func fullIndexRequestUsesDeterministicCompletion() {
        let policy = AgentTaskPolicyResolver.resolve(text: "一次性完成全部推荐索引 V2")
        #expect(policy.intent == .libraryManagement)
        #expect(policy.completion == .indexPendingCountIsZero)
    }

    @Test func continuationAfterErrorRestoresIndexPolicyAndTools() {
        let policy = AgentTaskPolicyResolver.resolve(
            text: "继续",
            historyText: "开始并一次性完成推荐索引 V2"
        )
        #expect(policy.intent == .libraryManagement)
        #expect(policy.completion == .indexPendingCountIsZero)

        let selected = ToolSelector.select(
            for: "继续",
            intent: policy.intent,
            policy: policy,
            all: AgentToolRegistry.all
        )
        let names = Set(selected.map(\.name))
        #expect(names.contains("library_index_v2_status"))
        #expect(names.contains("library_index_v2_next_batch"))
        #expect(names.contains("library_index_v2_write_batch"))
    }

    @Test func indexStatusQuestionDoesNotStartFullBuild() {
        let policy = AgentTaskPolicyResolver.resolve(text: "查看推荐索引 V2 状态")
        #expect(policy.completion == .successfulToolResult)
    }

    @Test func descriptorDeclaresCacheAndEvidencePolicy() {
        let descriptor = AgentToolRegistry.descriptor(for: "library_search")!
        #expect(descriptor.cachePolicy == .task)
        #expect(descriptor.evidencePolicy == .localCatalog)
        #expect(descriptor.sideEffectPolicy == .none)
    }

    @Test func queueDescriptorDeclaresQueueSideEffect() {
        let descriptor = AgentToolRegistry.descriptor(for: "queue_replace")!
        #expect(descriptor.cachePolicy == .none)
        #expect(descriptor.sideEffectPolicy == .queue)
    }

    @Test func taskReducerMergesFactsAndEvidence() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        let descriptor = AgentToolRegistry.descriptor(for: "library_index_v2_status")!
        let call = ToolCall(name: descriptor.name)
        let result = ToolResult(
            call: call,
            permission: .readOnly,
            success: true,
            summary: "pending 4",
            facts: ["recommendation.index.pending": "4"]
        )
        let changed = AgentTaskReducer.apply(result: result, descriptor: descriptor, to: &state)
        #expect(changed)
        #expect(state.facts["recommendation.index.pending"] == "4")
        #expect(state.evidence.count == 1)
        #expect(state.evidence[0].source == .localCatalog)
    }

    @Test func failedToolRecordsErrorFactAsProgress() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        let descriptor = AgentToolRegistry.descriptor(for: "library_search")!
        let result = ToolResult(call: .init(name: descriptor.name), permission: .readOnly, success: false, summary: "offline")
        let changed = AgentTaskReducer.apply(result: result, descriptor: descriptor, to: &state)
        // 失败本身是新信息（错误事实）：换策略的依据，不当作停滞。
        #expect(!changed)
        #expect(state.evidence.isEmpty)
        #expect(state.errors.contains("offline"))
        #expect(state.progress.noProgressRounds == 0)
    }

    @Test func queueCompletionRequiresRealMutationFact() {
        var state = AgentTaskState(intent: .queueManagement, goal: "replace")
        let policy = AgentTaskPolicy.policy(for: .queueManagement)
        let first = AgentCompletionEvaluator.evaluateModelAnswer("已经替换", state: &state, policy: policy, repairAttempts: 0)
        #expect(first != .accept)
        state.facts["sideEffect.queue"] = "success"
        let second = AgentCompletionEvaluator.evaluateModelAnswer("已经替换", state: &state, policy: policy, repairAttempts: 0)
        #expect(second == .accept)
    }

    @Test func indexCompletionRequiresBothFixedAndSemanticPendingZero() {
        var state = AgentTaskState(intent: .libraryManagement, goal: "index")
        let policy = AgentTaskPolicy(
            intent: .libraryManagement,
            scopes: [.catalogRead, .annotationWrite],
            allowedToolGroups: [.catalog, .annotation],
            allowedPermissions: [.readOnly, .reversible],
            completion: .indexPendingCountIsZero
        )
        // 固定分类完成但开放标签待处理 4000 → 不能宣布完成。
        state.facts["recommendation.index.pending"] = "0"
        state.facts["recommendation.index.pendingSemantic"] = "4000"
        let incomplete = AgentCompletionEvaluator.evaluateModelAnswer("完成", state: &state, policy: policy, repairAttempts: 0)
        #expect(incomplete != .accept)

        // 开放标签也归零 → 完成。
        state.facts["recommendation.index.pendingSemantic"] = "0"
        let complete = AgentCompletionEvaluator.evaluateModelAnswer("完成", state: &state, policy: policy, repairAttempts: 0)
        #expect(complete == .accept)
        #expect(state.completionState == .satisfied)
    }

    @Test func indexCompletionReadsStructuredPendingFact() {
        var state = AgentTaskState(intent: .libraryManagement, goal: "index")
        let policy = AgentTaskPolicy(
            intent: .libraryManagement,
            scopes: [.catalogRead, .annotationWrite],
            allowedToolGroups: [.catalog, .annotation],
            allowedPermissions: [.readOnly, .reversible],
            completion: .indexPendingCountIsZero
        )
        state.facts["recommendation.index.pending"] = "0"
        let decision = AgentCompletionEvaluator.evaluateModelAnswer("完成", state: &state, policy: policy, repairAttempts: 0)
        #expect(decision == .accept)
        #expect(state.completionState == .satisfied)
    }

    @Test func appreciationRequiresResolvedEvidenceBoundaries() {
        var state = AgentTaskState(intent: .musicAppreciation, goal: "appreciate")
        let policy = AgentTaskPolicy.policy(for: .musicAppreciation)
        state.facts["appreciation.metadata"] = "available"
        let incomplete = AgentCompletionEvaluator.evaluateModelAnswer("answer", state: &state, policy: policy, repairAttempts: 0)
        #expect(incomplete != .accept)
        state.facts["appreciation.lyrics"] = "unavailable"
        state.facts["appreciation.community"] = "unavailable"
        let complete = AgentCompletionEvaluator.evaluateModelAnswer(
            """
            ## 《Song》鉴赏
            ### 【已核验事实】
            metadata
            ### 【模型分析】
            listening analysis
            ### 【我的私人数据】
            1 play
            ### 【大众评价】
            暂无可核验的大众评价数据。
            """,
            state: &state,
            policy: policy,
            repairAttempts: 0
        )
        #expect(complete == .accept)
    }

    @Test func appreciationRejectsUnsupportedCommunityConsensus() {
        var state = AgentTaskState(intent: .musicAppreciation, goal: "appreciate")
        state.facts["appreciation.metadata"] = "available"
        state.facts["appreciation.lyrics"] = "unavailable"
        state.facts["appreciation.community"] = "unavailable"
        let decision = AgentCompletionEvaluator.evaluateModelAnswer(
            "【已核验事实】x【模型分析】x【我的私人数据】x【大众评价】大众普遍认为它广受好评。",
            state: &state,
            policy: .policy(for: .musicAppreciation),
            repairAttempts: 0
        )
        #expect(decision != .accept)
    }

    @Test func modelInferenceAloneCannotSatisfySuccessfulToolResult() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        state.evidence = [.init(source: .modelInference, provenance: "model", confidence: 0.5, claim: "maybe")]
        let decision = AgentCompletionEvaluator.evaluateModelAnswer(
            "found",
            state: &state,
            policy: .policy(for: .librarySearch),
            repairAttempts: 0
        )
        // 只有 Evidence 而没有真实成功 ToolResult → 不满足。
        #expect(decision != .accept)
    }

    @Test func memoryListSuccessSatisfiesWithoutEvidence() {
        // 截图回归：memory_list 成功但没有任何 AgentEvidence 时，任务必须通过完成条件。
        var state = AgentTaskState(intent: .memoryManagement, goal: "你能记得什么")
        let descriptor = AgentToolRegistry.descriptor(for: "memory_list")!
        let result = ToolResult(call: .init(name: "memory_list"), permission: .readOnly, success: true, summary: "记忆 2 条")
        _ = AgentTaskReducer.apply(result: result, descriptor: descriptor, to: &state)
        #expect(state.successfulToolCount == 1)
        #expect(state.evidence.isEmpty)
        let decision = AgentCompletionEvaluator.evaluateModelAnswer(
            "我记得：名字 = 小明；喜欢的歌手 = 王菲。",
            state: &state,
            policy: .policy(for: .memoryManagement),
            repairAttempts: 0
        )
        #expect(decision == .accept)
    }

    @Test func explicitQueueCountIsInferred() {
        #expect(AgentTaskWorkingSet.inferredTargetQueueCount(from: "找 22 首适合通勤的歌") == 22)
    }

    @Test(arguments: [
        ("推荐12首歌", 12),
        ("推荐十二首歌", 12),
        ("给我十首", 10),
        ("来二十首", 20),
        ("来二十三首歌曲", 23),
        ("推荐一百首", 100),
        ("来一百二十三首", 123),
        ("来两百首", 200),
        ("来一百零二首", 102),
    ])
    func chineseQueueCounts(_ text: String, _ expected: Int) {
        #expect(AgentTaskWorkingSet.inferredTargetQueueCount(from: text) == expected)
    }

    @Test(arguments: [
        "来两百零一首",
        "2020年的歌",
        "给我一些歌",
        "晚上十点提醒我",
    ])
    func invalidQueueCountsAreNil(_ text: String) {
        #expect(AgentTaskWorkingSet.inferredTargetQueueCount(from: text) == nil)
    }

    @Test func unspecifiedQueueCountIsNotInvented() {
        #expect(AgentTaskWorkingSet.inferredTargetQueueCount(from: "推荐几首适合通勤的歌") == nil)
    }

    @Test func workingSetTracksQueuedCountDiagnostically() {
        var state = AgentTaskWorkingSet(targetQueueCount: 2)
        state.noteQueued([
            .init(serverID: .init(rawValue: "s"), remoteID: "1"),
            .init(serverID: .init(rawValue: "s"), remoteID: "2"),
        ])
        #expect(state.queuedSongIDs.count == 2)
    }

    @Test func workingSetWithoutTargetDoesNotInventCounts() {
        var state = AgentTaskWorkingSet()
        let ids = (0..<30).map { GlobalID(serverID: .init(rawValue: "s"), remoteID: "\($0)") }
        state.noteQueued(ids)
        #expect(state.queuedSongIDs.count == 30)
    }

    @Test func redactorHandlesAuthorizationAndCookieVariants() {
        let redacted = AgentSensitiveDataRedactor.arguments([
            "Authorization": "Bearer abc",
            "session_cookie": "secret",
            "kind": "album",
        ])
        #expect(redacted["Authorization"] == "<redacted>")
        #expect(redacted["session_cookie"] == "<redacted>")
        #expect(redacted["kind"] == "album")
    }
}
