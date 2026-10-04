// SPDX-License-Identifier: GPL-3.0-only
import AgentKit
import AIKit
import Foundation
import Testing

// MARK: - AI-10：明确搜索的对象类型槽位

@Suite("明确搜索实体槽位")
struct DirectLibrarySearchSlotTests {
    private func directReadKindAndQuery(_ text: String) -> (kind: String?, query: String?) {
        let semantics = AgentRequestSemantics.analyze(text)
        guard let capability = semantics.directReadCapability,
              capability.toolName == "library_search" else {
            return (nil, nil)
        }
        var kind: String?
        var query: String?
        if case let .string(value)? = capability.arguments["kind"] { kind = value }
        if case let .string(value)? = capability.arguments["query"] { query = value }
        return (kind, query)
    }

    @Test("实体名含「歌手」不污染歌曲对象判断")
    func songTitleContainingArtistWord() {
        let result = directReadKindAndQuery("搜索歌曲《我是歌手》")
        #expect(result.kind == "song")
        #expect(result.query == "我是歌手")
    }

    @Test("实体名含「专辑」不污染歌曲对象判断")
    func songTitleContainingAlbumWord() {
        let result = directReadKindAndQuery("搜索歌曲《专辑》")
        #expect(result.kind == "song")
        #expect(result.query == "专辑")
    }

    @Test("普通歌曲搜索保持 song")
    func plainSongSearch() {
        let result = directReadKindAndQuery("搜索歌曲《胡广生》")
        #expect(result.kind == "song")
        #expect(result.query == "胡广生")
    }

    @Test("显式专辑对象优先")
    func explicitAlbumObject() {
        let result = directReadKindAndQuery("查找专辑《叶惠美》")
        #expect(result.kind == "album")
        #expect(result.query == "叶惠美")
    }

    @Test("显式歌手对象优先")
    func explicitArtistObject() {
        let result = directReadKindAndQuery("搜索歌手周杰伦")
        #expect(result.kind == "artist")
        #expect(result.query == "周杰伦")
    }

    @Test("显式歌单对象优先")
    func explicitPlaylistObject() {
        let result = directReadKindAndQuery("搜索歌单《夜跑》")
        #expect(result.kind == "playlist")
        #expect(result.query == "夜跑")
    }

    @Test("后缀对象词同样构成显式槽位")
    func suffixObjectMarker() {
        let result = directReadKindAndQuery("搜索胡广生这首歌")
        #expect(result.kind == "song")
        #expect(result.query == "胡广生")
    }

    @Test("没有显式对象词时保持 all，不再被实体名关键词污染")
    func noObjectMarkerFallsBackToAll() {
        let result = directReadKindAndQuery("搜索《我是歌手》")
        #expect(result.kind == "all")
        #expect(result.query == "我是歌手")
    }
}

// MARK: - AI-04：历史投影按披露类别过滤

@Suite("助手正文披露类别投影")
struct AssistantDisclosureProjectionTests {
    private func projection(
        _ history: [AgentChatMessage],
        permissions: AIPrivacyPermissions
    ) -> [AIMessage] {
        AgentHistoryPolicy.modelMessages(from: history, for: nil, permissions: permissions)
    }

    @Test("默认权限下，未接触受限类别的助手正文保留（多轮对话）")
    func plainAssistantTextSurvivesDefaultPermissions() {
        let history = [
            AgentChatMessage(role: .user, messages: [.text("给我三种歌单整理方法")]),
            AgentChatMessage(
                role: .assistant,
                messages: [.text("第一种：按年代；第二种：按流派；第三种：按心情")],
                disclosureCategories: []
            ),
            AgentChatMessage(role: .user, messages: [.text("展开第二种")]),
        ]
        let projected = projection(history, permissions: AIPrivacyPermissions())
        #expect(projected.count == 3)
        #expect(projected[1].content.contains("按流派"))
    }

    @Test("撤销歌词权限后，只丢弃沾过歌词的正文，普通解释保留")
    func lyricsTaggedTextDroppedAfterRevocation() {
        var permissions = AIPrivacyPermissions()
        permissions.allowsLyrics = false
        let history = [
            AgentChatMessage(
                role: .assistant,
                messages: [.text("这首歌的歌词大意是……")],
                disclosureCategories: [.lyrics]
            ),
            AgentChatMessage(
                role: .assistant,
                messages: [.text("这首歌发行于 2003 年")],
                disclosureCategories: []
            ),
        ]
        let projected = projection(history, permissions: permissions)
        #expect(projected.count == 1)
        #expect(projected[0].content.contains("2003"))
    }

    @Test("类别仍允许时，带标记的正文可以重放")
    func taggedTextReplaysWhileCategoryAllowed() {
        var permissions = AIPrivacyPermissions()
        permissions.allowsLyrics = true
        let history = [
            AgentChatMessage(
                role: .assistant,
                messages: [.text("这首歌的歌词大意是……")],
                disclosureCategories: [.lyrics]
            ),
        ]
        let projected = projection(history, permissions: permissions)
        #expect(projected.count == 1)
    }

    @Test("旧数据（无标记）维持保守投影")
    func legacyUntaggedTextStaysConservative() {
        let history = [
            AgentChatMessage(role: .assistant, messages: [.text("旧助手回答")]),
        ]
        #expect(projection(history, permissions: AIPrivacyPermissions()).isEmpty)

        var allOpen = AIPrivacyPermissions()
        allOpen.allowsExternalDiscovery = true
        allOpen.allowsLyrics = true
        allOpen.allowsPlaybackHistory = true
        allOpen.allowsFavoritesAndRatings = true
        #expect(projection(history, permissions: allOpen).count == 1)
    }

    @Test("用户消息始终保留")
    func userTextAlwaysReplays() {
        let history = [
            AgentChatMessage(role: .user, messages: [.text("播放我喜欢的歌")]),
        ]
        #expect(projection(history, permissions: AIPrivacyPermissions()).count == 1)
    }
}

@Suite("运行披露登记")
struct AgentRunDisclosureTests {
    @Test("类别未允许时登记不计数")
    func recordIgnoredWhenCategoryDisallowed() async {
        let registry = AgentRunDisclosureRegistry()
        let runID = UUID()
        await registry.record(runID: runID, toolName: "lyrics_get", permissions: AIPrivacyPermissions())
        #expect(await registry.categories(runID: runID).isEmpty)
    }

    @Test("类别允许时登记计数，清理后清空")
    func recordAndClear() async {
        let registry = AgentRunDisclosureRegistry()
        let runID = UUID()
        var permissions = AIPrivacyPermissions()
        permissions.allowsLyrics = true
        await registry.record(runID: runID, toolName: "lyrics_get", permissions: permissions)
        await registry.record(runID: runID, toolName: "library_search", permissions: permissions)
        #expect(await registry.categories(runID: runID) == [.lyrics, .metadata])
        await registry.clear(runID: runID)
        #expect(await registry.categories(runID: runID).isEmpty)
    }
}

// MARK: - AI-13：记忆来源、类别与有效期

@Suite("记忆来源与披露类别")
struct AgentMemoryProvenanceTests {
    @Test("旧格式记忆解码回落为 userAsserted")
    func legacyMemoryDecodesWithDefaults() throws {
        let json = #"{"key":"名字","value":"小明","updatedAt":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(AgentMemoryEntry.self, from: Data(json.utf8))
        #expect(entry.source == .userAsserted)
        #expect(entry.category == nil)
        #expect(entry.createdAt == entry.updatedAt)
        #expect(entry.expiresAt == nil)
    }

    @Test("类别被撤销后派生记忆不再可披露")
    func categoryRevocationBlocksDisclosure() {
        let entry = AgentMemoryEntry(key: "常听", value: "粤语老歌", category: .playbackHistory)
        #expect(!entry.isDisclosable(under: AIPrivacyPermissions()))
        var permissions = AIPrivacyPermissions()
        permissions.allowsPlaybackHistory = true
        #expect(entry.isDisclosable(under: permissions))
    }

    @Test("普通偏好不受类别开关影响")
    func plainPreferenceAlwaysDisclosable() {
        let entry = AgentMemoryEntry(key: "名字", value: "小明")
        #expect(entry.isDisclosable(under: AIPrivacyPermissions()))
    }

    @Test("过期记忆不再召回")
    func expiredMemoryNotDisclosable() {
        let entry = AgentMemoryEntry(
            key: "临时",
            value: "本周想听爵士",
            expiresAt: Date(timeIntervalSinceNow: -3600)
        )
        #expect(!entry.isDisclosable(under: AIPrivacyPermissions()))
        #expect(entry.isExpired())
    }

    @Test("新格式记忆带完整来源元数据编解码往返")
    func provenanceRoundTrip() throws {
        let entry = AgentMemoryEntry(
            key: "偏好",
            value: "少推电子",
            updatedAt: Date(timeIntervalSince1970: 2000),
            createdAt: Date(timeIntervalSince1970: 1000),
            source: .derivedFromTools,
            category: .favoritesAndRatings,
            expiresAt: Date(timeIntervalSince1970: 999_999)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentMemoryEntry.self, from: encoder.encode(entry))
        #expect(decoded == entry)
    }
}

@Suite("Opaque continuation context budget")
struct OpaqueContinuationBudgetTests {
    @Test func nativeStateIsCountedWithItsAtomicToolGroup() {
        let user = AIMessage(role: .user, content: "q")
        let assistant = AIMessage(role: .assistant, content: "", toolCalls: [.init(id: "c", name: "read", arguments: "{}")])
        let conversation = [AIMessage(role: .system, content: "s"), user, assistant, AIMessage(role: .tool, content: "done", toolCallID: "c")]
        let kept = ContextManager.trimByTokens(conversation, maxTokens: 100, preservingUserText: "q", continuationTokenCosts: [assistant.id: 1_000])
        #expect(kept.map(\.role) == [.system, .user])
    }
}

@Test("未知类别的派生和外部来源不能通过缺省元数据绕过权限")
func unknownSourceFailsClosed() {
    let permissions = AIPrivacyPermissions()
    #expect(!AgentMemoryEntry(key: "external", value: "reference", source: .external).isDisclosable(under: permissions))
    #expect(!AgentMemoryEntry(key: "derived", value: "reference", source: .derivedFromTools).isDisclosable(under: permissions))
    #expect(!AgentSkillEntry(name: "external", instructions: "reference", source: .external).isDisclosable(under: permissions))
    #expect(AgentMemoryEntry(key: "explicit", value: "preference").isDisclosable(under: permissions))
}
