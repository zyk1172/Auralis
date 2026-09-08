// SPDX-License-Identifier: GPL-3.0-only
@testable import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

@Test("完整工具认知目录包含全部 model-visible descriptor 的用途")
func toolAwarenessDirectoryUsesCanonicalDescriptors() {
    let prompt = SystemPromptBuilder.build(
        context: .init(),
        tools: [AgentToolRegistry.descriptor(for: "tool_search")!],
        nativeToolCalling: true,
        awarenessTools: AgentToolRegistry.all,
        authorizedOperations: []
    )
    for descriptor in AgentToolRegistry.all where descriptor.visibility == .model {
        #expect(prompt.contains(descriptor.name))
        #expect(prompt.contains(descriptor.summary))
    }
    #expect(!prompt.contains("recommendation_index_commit："))
}

@Test("model-visible descriptor 都有真实的 canonical purpose")
func modelToolSummariesAreMeaningful() {
    for descriptor in AgentToolRegistry.all where descriptor.visibility == .model {
        #expect(!descriptor.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(descriptor.summary != descriptor.name)
    }
}

@Test("高价值工具 summary 说明真实用途、目标实体与使用场景")
func keyToolSummariesExplainPurposeAndContext() throws {
    let checks: [(tool: String, required: [String])] = [
        ("library_get_album", ["本地音乐资料库", "专辑分析", "实体确认"]),
        ("library_get_artist", ["真实本地资料", "专辑概况", "实体确认"]),
        ("library_get_song", ["真实元数据", "实体确认", "播放"]),
        ("library_get_playlist", ["真实名称", "歌单确认", "修改前核对"]),
        ("library_get_similar_songs", ["真实内容", "相似歌曲"]),
        ("playback_get_state", ["当前播放器状态", "规划播放操作"]),
        ("queue_get", ["真实歌曲与顺序", "队列修改"]),
        ("playlist_add_songs", ["已解析的真实歌曲", "准确的 PlaylistID", "TrackID"]),
        ("music_appreciate", ["分层鉴赏证据", "外部大众评价"]),
        ("music_get_public_evidence", ["真实公开音乐资料证据", "不得编造"]),
    ]
    for check in checks {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: check.tool))
        for fragment in check.required {
            #expect(descriptor.summary.contains(fragment), "\(check.tool) 的 summary 缺少「\(fragment)」")
        }
    }
}

@Test("普通 reversible mutation 保留在目录且不受 exact operation 阻塞")
func reversibleMutationIsAwareAndExecutable() {
    let mutation = AgentToolRegistry.descriptor(for: "playlist_add_songs")!
    let entry = ToolCatalog(descriptors: [mutation]).awarenessEntries(
        environment: .init(),
        authorizedOperations: []
    ).first!
    #expect(entry.authorized == nil)
    #expect(!entry.renderedLine.contains("未授权"))
    #expect(mutation.isAuthorizedForModelExposure(allowedOperations: []))
}

// MARK: - Tool Broker / CandidateSet / Completion 回归测试
//
// 覆盖本轮优化：
// - Tool Broker Top-K：自然语言 → 高相关工具召回，无关工具被截断
// - tool_search 排名：utteranceExamples + coverage 加权
// - CandidateSet：targetCount 感知的模型可见窗口（不再固定前 5 首）
// - musicDiscovery completion：普通推荐由模型回答决定，不强制 final selection
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

    @Test("Broker 「鉴赏这首歌」→ music_appreciate 位于最前")
    func musicAppreciationShortlistIsDeterministic() throws {
        let plan = makePlan("鉴赏这首歌")
        #expect(plan.semantics.isMusicAppreciation)
        #expect(plan.semantics.isReadOnly)
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        let primary = try #require(selected.first { !$0.isCoreInfrastructure && $0.name != "result_present_tracks" })
        #expect(primary.name == "music_appreciate")
        #expect(selected.contains { ["library_search", "library_resolve_entity"].contains($0.name) })
    }

    @Test("Intent 歌单名中的实体内容不污染命令路由")
    func playlistEntityNamesDoNotContaminateIntent() {
        let commands = [
            "删除歌单 暂停",
            "帮我删除一下歌单 暂停",
            "删除这个歌单 暂停",
            "删除歌单暂停",
            "删除歌单下一首",
            "删掉歌单删除服务器",
            "删除歌单播放",
            "把名叫“暂停”的歌单删除",
            "把歌单“下一首”删除",
        ]
        for command in commands {
            let plan = makePlan(command)
            #expect(plan.semantics.domain == .playlist)
            #expect(plan.authorization.allowedOperations == [.playlistDelete], "\(command) 实际：\(plan.authorization.allowedOperations)")
        }

        // Post-position verb order must not regress (P1 from review round 3).
        let postPosition = [
            "把歌单 通勤 删除",
            "把通勤这个歌单删除",
            "把通勤歌单删掉",
        ]
        for command in postPosition {
            let plan = makePlan(command)
            #expect(plan.semantics.domain == .playlist, "\(command) 应识别为 playlist 域")
            #expect(plan.authorization.allowedOperations.contains(.playlistDelete), "\(command) 应授权 playlistDelete，实际：\(plan.authorization.allowedOperations)")
        }

        for command in ["删除歌单怎么操作？", "删除歌单是什么意思？", "删除歌单要怎么弄？"] {
            let plan = makePlan(command)
            #expect(plan.authorization.allowedOperations.isEmpty)
            #expect(!plan.authorization.allowedOperations.contains(.playlistDelete))
        }

        // Spaced variants must not have their instructional signal consumed by
        // entity masking (P0 regression from review round 3).
        let spacedInstructional = [
            "删除歌单 怎么操作？",
            "删除歌单 如何操作？",
            "删除歌单 是什么意思？",
            "删除歌单 要怎么弄？",
            "删除歌单 应该怎么删除？",
            "删除这个歌单 怎么操作？",
        ]
        for command in spacedInstructional {
            let plan = makePlan(command)
            #expect(plan.authorization.allowedOperations.isEmpty, "\(command) 不应产生任何授权，实际：\(plan.authorization.allowedOperations)")
            #expect(!plan.authorization.allowedOperations.contains(.playlistDelete), "\(command) 不得授权 playlistDelete")
        }

        // Masking must preserve an explicit second command after the entity.
        let compound = makePlan("删除歌单 通勤，然后暂停播放")
        #expect(compound.authorization.allowedOperations == [.playlistDelete, .playbackPause])

        for name in ["我叫大傻蛋", "请记住我", "下一首", "删除服务器", "暂停", "收藏"] {
            let plan = makePlan("删除歌单 \(name)")
            #expect(plan.semantics.domain == .playlist)
            #expect(plan.authorization.allowedOperations == [.playlistDelete])
            #expect(!plan.authorization.allowedOperations.contains(.memorySave))
            #expect(!plan.authorization.allowedOperations.contains(.serverRemove))
        }
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
        #expect(text.contains("本批工具结果共 50 首"))
        #expect(text.contains("不是任务数量上限"))
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

    @Test("Completion：普通 musicDiscovery 由模型回答决定，不强制 final selection")
    func musicDiscoveryUsesModelAnswerCompletion() {
        let policy = AgentTaskPolicy.policy(for: .musicDiscovery)
        #expect(policy.completion == .modelAnswer)
        #expect(AgentCompletionPredicate.finalTrackSelection.predicateName == "finalTrackSelection")
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

    @Test("R2 单批候选超过上下文窗口时说明分页，而不是限制任务数量")
    func candidateOverFiftyExplainsPaging() {
        let cards = (0..<80).map { i in
            TrackCard(globalID: GlobalID(serverID: "v2", remoteID: "t\(i)"), title: "歌\(i)", artistName: "艺人", albumTitle: "专辑", duration: 200, isFavorite: false)
        }
        let text = ToolLoop.messageTextForModel(.trackCards(cards), targetCount: 80)
        #expect(text.contains("单批上下文窗口"), "应说明这是单批上下文窗口")
        #expect(text.contains("不是任务数量上限"), "不得把单批窗口描述成任务上限")
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

    @Test("R3/R4 Hosted Web 三态：都有→available，只有其一→degraded，全无→unavailable")
    func hostedWebTriStateAvailability() {
        let web = AgentCapabilityCatalog.capability(id: "web_research")!
        // Search + Fetch 都有 → available：
        let both = AgentCapabilityEnvironment(
            providerAvailable: true, catalogAvailable: true, activeServer: true,
            webAvailable: false, webSearchAvailable: true, webFetchAvailable: true
        )
        if case .available = AgentCapabilityCatalog.availability(for: web, environment: both) {} else {
            Issue.record("Search+Fetch 都有时 web_research 必须 available")
        }
        // 只有 Search → degraded（缺少网页读取）：
        let searchOnly = AgentCapabilityEnvironment(
            providerAvailable: true, catalogAvailable: true, activeServer: true,
            webAvailable: false, webSearchAvailable: true, webFetchAvailable: false
        )
        if case let .degraded(reason) = AgentCapabilityCatalog.availability(for: web, environment: searchOnly) {
            #expect(reason.contains("网页读取"), "degraded 必须说明缺什么，实际：\(reason)")
        } else {
            Issue.record("只有 Search 时 web_research 应为 degraded")
        }
        // 只有 Fetch → degraded：
        let fetchOnly = AgentCapabilityEnvironment(
            providerAvailable: true, catalogAvailable: true, activeServer: true,
            webAvailable: false, webSearchAvailable: false, webFetchAvailable: true
        )
        if case let .degraded(reason) = AgentCapabilityCatalog.availability(for: web, environment: fetchOnly) {
            #expect(reason.contains("联网搜索"), "degraded 必须说明缺什么，实际：\(reason)")
        } else {
            Issue.record("只有 Fetch 时 web_research 应为 degraded")
        }
        // 全无 → unavailable：
        let none = AgentCapabilityEnvironment(
            providerAvailable: true, catalogAvailable: true, activeServer: true,
            webAvailable: false, webSearchAvailable: false, webFetchAvailable: false
        )
        if case .unavailable = AgentCapabilityCatalog.availability(for: web, environment: none) {} else {
            Issue.record("无任何联网能力时 web_research 必须 unavailable")
        }
    }


    @Test("R4 「暂停是什么功能？」→ 不授权 playbackPause")
    func instructionalPauseNoMutation() {
        let semantics = AgentRequestSemantics.analyze("暂停是什么功能？")
        #expect(!semantics.requestedOperations.contains(.playbackPause))
        #expect(semantics.isReadOnly)
    }

    @Test("R4 教学问句不产生歌单/队列/收藏 mutation 授权")
    func instructionalQueriesDoNotMutate() {
        let cases: [(String, ToolAuthorizationOperation)] = [
            ("怎么创建歌单？", .playlistCreate),
            ("如何删除歌单？", .playlistDelete),
            ("怎么清空队列？", .queueClear),
            ("怎样取消收藏？", .favoriteSet),
        ]
        for (text, op) in cases {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(!semantics.requestedOperations.contains(op), "「\(text)」是教学问句，不得授权 \(op.rawValue)")
            #expect(semantics.isReadOnly, "「\(text)」必须只读")
        }
    }

    @Test("R4 「可以帮我创建一个叫通勤的歌单吗？」→ 执行请求，授权 playlistCreate")
    func executionRequestStillAuthorizes() {
        let semantics = AgentRequestSemantics.analyze("可以帮我创建一个叫通勤的歌单吗？")
        #expect(semantics.requestedOperations.contains(.playlistCreate),
                "「可以帮我」是明确执行请求，教学问句抑制不适用")
        // 纯教学问句不授权：
        let how = AgentRequestSemantics.analyze("怎么创建一个歌单？")
        #expect(!how.requestedOperations.contains(.playlistCreate))
    }
}
