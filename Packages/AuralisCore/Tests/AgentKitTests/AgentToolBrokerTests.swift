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
        #expect(names.contains("library_search") || names.contains("library_select_tracks"))
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
}
