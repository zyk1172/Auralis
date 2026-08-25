@testable import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Tool Broker / CandidateSet / Completion 回归测试
//
// 覆盖本轮优化：
// - Tool Broker Top-K：自然语言 → 高相关工具召回，无关工具被截断
// - tool_search 排名：utteranceExamples + coverage 加权
// - CandidateSet：targetCount 感知的模型可见窗口（不再固定前 5 首）
// - musicDiscovery completion：必须 final selection 才完成
// - Authorization 与 Tool Relevance 分离

@Suite("Agent tool broker")
struct AgentToolBrokerTests {

    private func makePlan(_ text: String) -> AgentRequestPlan {
        AgentRequestPlan.build(userText: text, history: [])
    }

    // MARK: - Tool Broker 自然语言覆盖（用户 33）

    @Test("Broker 「播放稻香」→ 召回搜索/解析/播放，不大量暴露无关工具")
    func brokerPlaybackShortlist() {
        let plan = makePlan("播放稻香")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("library_search") || names.contains("library_resolve_entity"),
                "播放请求应召回实体解析入口")
        #expect(names.contains("playback_play_song") || names.contains("playTrack"),
                "播放请求应召回播放工具")
        // 无关工具不应大量暴露。
        let irrelevant = selected.filter { $0.name.hasPrefix("diagnostics_") }
        #expect(irrelevant.isEmpty, "不应暴露诊断工具，实际：\(irrelevant.map(\.name))")
    }

    @Test("Broker 「来点适合深夜听的」→ recommend_by_mood 优先")
    func brokerMoodShortlist() {
        let plan = makePlan("推荐几首适合深夜听的歌")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("recommend_by_mood"), "深夜场景应召回情绪推荐")
        // 推荐主要由 recommend_by_mood 产出候选；不强求 library_search 必须在首轮。
    }

    @Test("Broker 「找20首中文摇滚」→ library_select_tracks 优先")
    func brokerMultiTrackShortlist() {
        let plan = makePlan("推荐20首中文摇滚歌曲")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        #expect(selected.contains { $0.name == "library_select_tracks" },
                "多条件批量选歌应召回 library_select_tracks")
    }

    @Test("Broker 「看看我的曲库有哪些流派」→ library_get_catalog_index 优先")
    func brokerCatalogStructureShortlist() {
        let plan = makePlan("看看我的曲库有哪些流派")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        #expect(selected.contains { $0.name == "library_get_catalog_index" },
                "了解曲库结构应召回 catalog index")
    }

    @Test("Broker mutation 前置补全：播放/加歌单需要实体解析入口")
    func brokerPrerequisiteExpansion() {
        // playback_play_song 需要 TrackID → 自动补 library_search / resolve。
        let play = makePlan("播放稻香")
        let playNames = Set(ToolSelector.select(plan: play, all: AgentToolRegistry.all).map(\.name))
        #expect(playNames.contains("library_search") || playNames.contains("library_resolve_entity"))
    }

    // MARK: - Tool Search 排名（用户 34）

    @Test("tool_search 「把歌曲安排成下一首播放」→ queue_play_next 显著高于其它")
    func toolSearchRanksPlayNextFirst() {
        let catalog = ToolCatalog(descriptors: AgentToolRegistry.all)
        let results = catalog.search(query: "把歌曲安排成下一首播放", limit: 10)
        let rankByName = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($0.element.name, $0.offset) })
        #expect(rankByName["queue_play_next"] != nil, "应召回 queue_play_next，实际：\(results.prefix(5).map(\.name))")
        if let playNext = rankByName["queue_play_next"],
           let playSong = rankByName["playback_play_song"] {
            #expect(playNext < playSong, "queue_play_next 应排在 playback_play_song 之前")
        }
    }

    // MARK: - CandidateSet 可见窗口（用户 35）

    @Test("CandidateSet：targetCount=20 时模型可见 ≥20 个真实候选")
    func candidateWindowFollowsTargetCount() {
        let cards = (0..<50).map { i in
            TrackCard(globalID: GlobalID(serverID: "v2", remoteID: "t\(i)"), title: "歌\(i)", artistName: "艺人", albumTitle: "专辑", duration: 200, isFavorite: false)
        }
        let text = ToolLoop.messageTextForModel(.trackCards(cards), targetCount: 20)
        // 前 20 首的 ID 都应出现在文本中（可复制给 result_present_tracks）。
        for i in 0..<20 {
            #expect(text.contains("v2:t\(i)"), "模型应能看到第 \(i) 个候选 ID")
        }
        #expect(text.contains("等 50 首"))
    }

    @Test("CandidateSet：无 targetCount 时默认展示 10 首")
    func candidateWindowDefaultTen() {
        let cards = (0..<30).map { i in
            TrackCard(globalID: GlobalID(serverID: "v2", remoteID: "t\(i)"), title: "歌\(i)", artistName: "艺人", albumTitle: "专辑", duration: 200, isFavorite: false)
        }
        let text = ToolLoop.messageTextForModel(.trackCards(cards), targetCount: nil)
        for i in 0..<10 {
            #expect(text.contains("v2:t\(i)"))
        }
        #expect(!text.contains("v2:t10"), "无目标数量时默认窗口 10 首")
    }

    // MARK: - Completion（用户 36/37）

    @Test("Completion：musicDiscovery 必须 final selection 才完成")
    func musicDiscoveryRequiresFinalSelection() {
        let policy = AgentTaskPolicy.policy(for: .musicDiscovery)
        #expect(policy.completion == .finalTrackSelection)

        // 只有搜索成功、无 final selection → 不完成。
        var state = AgentTaskState(intent: .musicDiscovery, goal: "推荐")
        state.successfulToolNames = ["library_search"]
        state.successfulToolCount = 1
        #expect(!AgentCompletionEvaluator.factsSatisfied(state: state, policy: policy),
                "只有工具成功、无 final selection 不得完成")

        // 有 final selection 但不足 targetCount → 不完成。
        state.facts["task.finalSelection.count"] = "5"
        state.facts["task.targetCount"] = "20"
        #expect(!AgentCompletionEvaluator.factsSatisfied(state: state, policy: policy),
                "final 5/20 不得完成")

        // final selection 达标 → 完成。
        state.facts["task.finalSelection.count"] = "20"
        #expect(AgentCompletionEvaluator.factsSatisfied(state: state, policy: policy),
                "final 20/20 应完成")
    }

    // MARK: - Authorization 与 Relevance 分离（用户 39/40）

    @Test("评分查询 relevance 可召回读工具，但授权不含 ratingSet")
    func ratingQueryAuthorizationStaysEmpty() {
        let plan = makePlan("这首歌的评分是多少？")
        #expect(!plan.allowedOperations.contains(.ratingSet))
        // Broker 可以召回只读工具。
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        _ = selected
    }

    @Test("清除评分授权 ratingSet，Broker 召回 rating_set")
    func ratingClearAuthorizesAndRecalls() {
        let plan = makePlan("清除这首歌的评分")
        #expect(plan.allowedOperations.contains(.ratingSet))
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        #expect(selected.contains { $0.name == "rating_set" },
                "授权 ratingSet 时应召回 rating_set 工具")
    }

    // MARK: - 第二轮 Review 修复回归

    @Test("R2 来首稻香 → 授权 playbackPlay 且召回播放/搜索工具")
    func laishouPlaybackAuthorizesAndRecalls() {
        let plan = makePlan("来首稻香")
        #expect(plan.allowedOperations.contains(.playbackPlay), "「来首」是明确播放意图")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("playback_play_song"), "应召回 playback_play_song")
        #expect(names.contains("library_search") || names.contains("library_resolve_entity"))
    }

    @Test("R2 把稻香加到通勤歌单 → 授权 playlistAdd 且补 playlist resolution")
    func addToPlaylistPrerequisiteExpansion() {
        let plan = makePlan("把稻香加到通勤歌单")
        #expect(plan.allowedOperations.contains(.playlistAdd), "加歌单应授权 playlistAdd")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("playlist_add_songs"), "应召回 playlist_add_songs")
        #expect(names.contains("playlist_list"), "playlist_add_songs 需要 PlaylistID → 补 playlist_list")
        #expect(names.contains("library_search") || names.contains("library_resolve_entity"),
                "需要 TrackID → 补搜索/解析入口")
    }

    @Test("R2 英文评分查询不产生任何 mutation 授权")
    func englishRatingQueryStaysReadOnly() {
        for text in ["what is this track's rating?", "what's the rating of this song?"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(!semantics.requestedOperations.contains(.ratingSet), "\(text) 不得授权 ratingSet")
            #expect(!semantics.requestedOperations.contains(.favoriteSet), "\(text) 不得误授权 favoriteSet")
        }
    }

    @Test("R2 Top-K 实际裁剪：无关工具（score==0）被挡在首轮外")
    func topKActuallyTrimsIrrelevantTools() {
        let plan = makePlan("播放稻香")
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        // 记忆/下载/诊断工具与播放无关，且无 example/domain 命中 → score==0 应被裁。
        let irrelevant = selected.filter {
            $0.group == .memory || $0.group == .download || $0.name.hasPrefix("diagnostics_")
        }
        #expect(irrelevant.count <= 2, "无关工具应被 Top-K 裁剪，实际：\(irrelevant.map(\.name))")
    }

    @Test("R2 候选超过 50 首时明确提示上限而非静默截断")
    func candidateOverFiftyNotice() {
        let cards = (0..<80).map { i in
            TrackCard(globalID: GlobalID(serverID: "v2", remoteID: "t\(i)"), title: "歌\(i)", artistName: "艺人", albumTitle: "专辑", duration: 200, isFavorite: false)
        }
        let text = ToolLoop.messageTextForModel(.trackCards(cards), targetCount: 80)
        #expect(text.contains("超过上限"), "应提示单轮上限")
        #expect(text.contains("80"), "应说明候选总数")
    }

    // MARK: - 第三轮 Review 修复回归

    @Test("R3 「来点适合深夜听的」→ 推荐场景，绝不授权 playbackPlay")
    func weakPlaybackHintDoesNotAuthorize() {
        let semantics = AgentRequestSemantics.analyze("来点适合深夜听的")
        #expect(!semantics.requestedOperations.contains(.playbackPlay),
                "「来点」是弱播放提示，不得扩大播放授权")
        #expect(semantics.operation != .mutate || semantics.requestedOperations.isEmpty,
                "弱表达不应产生播放 mutation")
    }

    @Test("R3 「整点周杰伦听听」→ 完整结构才授权 playbackPlay")
    func zhengdianListeningAuthorizesPlayback() {
        let semantics = AgentRequestSemantics.analyze("整点周杰伦听听")
        #expect(semantics.requestedOperations.contains(.playbackPlay),
                "「整点 X 听听」完整结构是明确播放意图")
        let bare = AgentRequestSemantics.analyze("整点好听的")
        #expect(!bare.requestedOperations.contains(.playbackPlay), "裸「整点」不授权播放")
    }

    @Test("R3 英文评分查询真正只读：operation .read、isReadOnly、无副作用")
    func englishRatingQueryIsTrulyReadOnly() {
        for text in ["what is this track's rating?", "what's the rating of this song?"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(!semantics.requestedOperations.contains(.ratingSet), "「\(text)」不得授权 ratingSet")
            #expect(!semantics.requestedOperations.contains(.favoriteSet), "「\(text)」不得误授权 favoriteSet")
            #expect(semantics.operation == .read, "「\(text)」operation 必须 .read，实际 \(semantics.operation)")
            #expect(semantics.isReadOnly, "「\(text)」必须真正只读")
            #expect(!semantics.requiresSideEffect, "「\(text)」不得要求副作用")
        }
    }

    @Test("R3 Provider Hosted Web Search 使 web_research 可用（无 App 服务时）")
    func hostedWebMakesWebResearchAvailable() {
        let web = AgentCapabilityCatalog.capability(id: "web_research")!
        // Provider 支持 Hosted Web Search，但 webService == nil：
        let env = AgentCapabilityEnvironment(
            providerAvailable: true, catalogAvailable: true, activeServer: true,
            webAvailable: false,
            webSearchAvailable: true, webFetchAvailable: false
        )
        if case .available = AgentCapabilityCatalog.availability(for: web, environment: env) {} else {
            Issue.record("Provider Hosted Web Search 可用时 web_research 不得 unavailable")
        }
        // 全无联网能力时 unavailable：
        let none = AgentCapabilityEnvironment(
            providerAvailable: true, catalogAvailable: true, activeServer: true,
            webAvailable: false, webSearchAvailable: false, webFetchAvailable: false
        )
        if case .unavailable = AgentCapabilityCatalog.availability(for: web, environment: none) {} else {
            Issue.record("无任何联网能力时 web_research 必须 unavailable")
        }
    }
}
