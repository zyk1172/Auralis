@testable import AgentKit
import Foundation
import Testing

@Test func chineseRecallFindsEntitiesInsideUnspacedRequests() {
    let query = AgentRecallQuery("帮我找适合夜跑的周杰伦歌曲")
    #expect(query.score("歌手偏好：周杰伦") > 0)
    #expect(query.score("运动：夜跑时喜欢稳定节奏") > 0)
    #expect(query.score("午餐：面条") == 0)
}

@Test func recallPreservesWordBoundariesAndNormalizesLatinText() {
    #expect(AgentRecallQuery("ＣＡＦÉ Jazz").score("cafe jazz") > 0)
    #expect(AgentRecallQuery("rap").score("trap") == 0)
    #expect(AgentRecallQuery("李").score("李荣浩") > 0)
    #expect(AgentRecallQuery("x").score("x") > 0)
    #expect(AgentRecallQuery("夜，跑").score("夜跑") == 0)
    #expect(AgentRecallQuery("，！？").score("夜跑") == 0)
    #expect(AgentRecallQuery("please").score("please play jazz") == 0)
}

@Test func relatedOldMemoriesAndSkillsSurviveMoreRecentUnrelatedEntries() {
    let old = Date(timeIntervalSince1970: 1)
    let memories = [AgentMemoryEntry(key: "运动习惯", value: "夜跑时听周杰伦", updatedAt: old)]
        + (0..<30).map { AgentMemoryEntry(key: "备忘\($0)", value: "午餐面条", updatedAt: .now) }
    let skills = [AgentSkillEntry(name: "运动选曲", instructions: "夜跑时查询节奏并筛选周杰伦歌曲", createdAt: old)]
        + (0..<15).map { AgentSkillEntry(name: "清理\($0)", instructions: "整理缓存", createdAt: .now) }
    let prompt = SystemPromptBuilder.build(
        context: .init(memories: memories, skills: skills), tools: [], nativeToolCalling: true,
        goal: "帮我找适合夜跑的周杰伦歌曲"
    )
    #expect(prompt.contains("运动习惯：夜跑时听周杰伦"))
    #expect(prompt.contains("「运动选曲」"))
    #expect(prompt.contains("另有 15 条记忆未注入"))
    #expect(prompt.contains("另有 8 个技能未注入"))
}

@Test(arguments: ["continue!", "Please continue", "go on", "keep going", "继续执行", "接着做", "繼續"])
func repeatedNaturalLanguageContinuationsKeepOriginalTask(text: String) {
    let task = "找五十一首歌并创建夜跑歌单"
    let history = [
        AgentChatMessage(role: .user, messages: [.text(task)]),
        AgentChatMessage(role: .assistant, messages: [.text("已找到一部分")]),
        AgentChatMessage(role: .user, messages: [.text("continue")]),
        AgentChatMessage(role: .user, messages: [.text("继续执行")]),
    ]
    #expect(AgentHistoryPolicy.relevantHistoryText(for: text, in: history) == task)
    #expect(AgentHistoryPolicy.relevantHistoryText(for: "播放另一首歌", in: history).isEmpty)
}

@Test func entityPrerequisitesSurviveAFullyOccupiedShortlist() {
    let original = AgentRequestPlan.build(userText: "把这些歌曲加入歌单", history: [])
    // Simulate a pronoun-only current phrase after task semantics are known.
    // Neither resolver has a lexical match, and 12 playlist tools fill Top-K.
    let plan = AgentRequestPlan(
        currentUserText: "zz", relevantHistoryText: "", semantics: original.semantics,
        intent: original.intent, policy: original.policy, authorization: original.authorization
    )
    let fillers = (0..<12).map {
        ToolDescriptor(name: "playlist_inspect_\($0)", group: .playlist, permission: .readOnly, summary: "inspect")
    }
    let mutation = ToolDescriptor(
        name: "playlist_add_songs", group: .playlist, permission: .reversible, summary: "append",
        semanticInputs: ["TrackIDs", "PlaylistID"]
    )
    let resolvers = [
        ToolDescriptor(name: "library_search", group: .catalog, permission: .readOnly, summary: "resolve"),
        ToolDescriptor(name: "library_resolve_entity", group: .catalog, permission: .readOnly, summary: "resolve"),
        ToolDescriptor(name: "playlist_list", group: .catalog, permission: .readOnly, summary: "resolve"),
    ]
    let selected = ToolSelector.select(plan: plan, all: fillers + [mutation] + resolvers)
    let names = Set(selected.map(\.name))
    #expect(names.contains("playlist_add_songs"))
    #expect(names.contains("library_search"))
    #expect(names.contains("library_resolve_entity"))
    #expect(names.contains("playlist_list"))
    #expect(names.count == selected.count)
}
