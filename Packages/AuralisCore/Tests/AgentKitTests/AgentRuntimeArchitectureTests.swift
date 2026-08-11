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

    @Test func conversationDefaultsToReadOnly() {
        let policy = AgentTaskPolicy.policy(for: .conversation)
        #expect(policy.allowedPermissions == [.readOnly])
        #expect(policy.maxRisk == .none)
    }

    @Test func playbackCannotCallServerMutation() {
        let policy = AgentTaskPolicy.policy(for: .playbackControl)
        let remove = AgentToolRegistry.descriptor(for: "removeServer")!
        #expect(!policy.authorizes(remove))
    }

    @Test func serverManagementCanReadAndMutateServer() {
        let policy = AgentTaskPolicy.policy(for: .serverManagement)
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "server_get_current")!))
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "removeServer")!))
    }

    @Test func appreciationCannotWriteQueue() {
        let policy = AgentTaskPolicy.policy(for: .musicAppreciation)
        #expect(policy.authorizes(AgentToolRegistry.descriptor(for: "music_appreciate")!))
        #expect(!policy.authorizes(AgentToolRegistry.descriptor(for: "queue_replace")!))
        #expect(policy.budget.maxOutputTokens == 16_000)
    }

    @Test func runtimeRejectsToolBeyondScope() async {
        let runtime = AgentRuntime()
        await #expect(throws: AgentRuntimeError.toolOutsidePolicy("removeServer")) {
            _ = try await runtime.authorize(tool: "removeServer", policy: .policy(for: .playbackControl))
        }
    }

    @Test func unknownToolIsRejected() async {
        let runtime = AgentRuntime()
        await #expect(throws: AgentRuntimeError.toolOutsidePolicy("not_real")) {
            _ = try await runtime.authorize(tool: "not_real", policy: .policy(for: .conversation))
        }
    }

    @Test func toolSelectionIsActuallyPolicyFiltered() {
        let policy = AgentTaskPolicy.policy(for: .musicAppreciation)
        let tools = ToolSelector.select(for: "鉴赏并删除服务器", intent: .musicAppreciation, policy: policy, all: AgentToolRegistry.all)
        #expect(tools.contains { $0.name == "music_appreciate" })
        #expect(!tools.contains { $0.name == "removeServer" })
        #expect(tools.allSatisfy(policy.authorizes))
    }

    @Test func modelRoundBudgetStopsAtLimit() {
        var state = AgentTaskState(intent: .conversation, goal: "test")
        let policy = AgentTaskPolicy(intent: .conversation, scopes: [], allowedToolGroups: [], budget: .init(maxModelRounds: 2))
        state.progress.modelRounds = 2
        #expect(state.budgetViolation(policy: policy) == .modelRoundBudgetExceeded)
    }

    @Test func noProgressBudgetStopsAtLimit() {
        var state = AgentTaskState(intent: .conversation, goal: "test")
        let policy = AgentTaskPolicy(intent: .conversation, scopes: [], allowedToolGroups: [], budget: .init(maxNoProgressRounds: 2))
        state.recordNoProgress()
        state.recordNoProgress()
        #expect(state.budgetViolation(policy: policy) == .noProgress)
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

    @Test func repeatedToolPatternTriggersBudget() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        let policy = AgentTaskPolicy(
            intent: .librarySearch,
            scopes: [],
            allowedToolGroups: [],
            budget: .init(maxRepeatedToolPattern: 2)
        )
        for _ in 0..<3 { state.recordToolCall(name: "library_search", arguments: ["query": "same"]) }
        #expect(state.budgetViolation(policy: policy) == .repeatedToolPattern)
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
        #expect(!policy.authorizes(AgentToolRegistry.descriptor(for: "removeServer")!))
    }

    @Test func fullIndexRequestUsesDeterministicCompletion() {
        let policy = AgentTaskPolicyResolver.resolve(text: "一次性完成全部推荐索引 V2")
        #expect(policy.intent == .libraryManagement)
        #expect(policy.completion == .indexPendingCountIsZero)
    }

    @Test func indexStatusQuestionDoesNotStartFullBuild() {
        let policy = AgentTaskPolicyResolver.resolve(text: "查看推荐索引 V2 状态")
        #expect(policy.completion == .verifiedToolResult)
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

    @Test func failedToolDoesNotCreateEvidence() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        let descriptor = AgentToolRegistry.descriptor(for: "library_search")!
        let result = ToolResult(call: .init(name: descriptor.name), permission: .readOnly, success: false, summary: "offline")
        let changed = AgentTaskReducer.apply(result: result, descriptor: descriptor, to: &state)
        #expect(!changed)
        #expect(state.evidence.isEmpty)
        #expect(state.progress.noProgressRounds == 1)
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

    @Test func modelInferenceAloneCannotSatisfyVerifiedToolResult() {
        var state = AgentTaskState(intent: .librarySearch, goal: "find")
        state.evidence = [.init(source: .modelInference, provenance: "model", confidence: 0.5, claim: "maybe")]
        let decision = AgentCompletionEvaluator.evaluateModelAnswer(
            "found",
            state: &state,
            policy: .policy(for: .librarySearch),
            repairAttempts: 0
        )
        #expect(decision != .accept)
    }

    @Test func explicitQueueCountIsInferred() {
        #expect(AgentTaskWorkingSet.inferredTargetQueueCount(from: "找 22 首适合通勤的歌") == 22)
    }

    @Test func unspecifiedQueueCountIsNotInvented() {
        #expect(AgentTaskWorkingSet.inferredTargetQueueCount(from: "推荐几首适合通勤的歌") == nil)
    }

    @Test func workingSetStopsAtRequestedCountOnly() {
        var state = AgentTaskWorkingSet(targetQueueCount: 2)
        state.noteQueued([
            .init(serverID: .init(rawValue: "s"), remoteID: "1"),
            .init(serverID: .init(rawValue: "s"), remoteID: "2"),
        ])
        #expect(state.stopSearching)
    }

    @Test func workingSetWithoutTargetDoesNotUseLegacyTwentyLimit() {
        var state = AgentTaskWorkingSet()
        let ids = (0..<30).map { GlobalID(serverID: .init(rawValue: "s"), remoteID: "\($0)") }
        state.noteQueued(ids)
        #expect(!state.stopSearching)
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
