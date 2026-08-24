import AgentKit
import Foundation
import Testing

@Test("Natural-language confirmation is not an execution continuation")
func naturalLanguageConfirmationDoesNotAuthorizeRuntime() {
    #expect(!AgentHistoryPolicy.isExplicitContinuation("确认"))
    #expect(!AgentHistoryPolicy.isExplicitContinuation("确定"))
    #expect(AgentHistoryPolicy.isExplicitContinuation("继续"))
}

@Test("Mutation resources serialize conflicts but allow unrelated work")
func mutationResourceLeasesAreScoped() async {
    let registry = MutationResourceLeaseRegistry()
    let first = UUID()
    let second = UUID()

    #expect(await registry.tryAcquire([.recommendationIndex], owner: first))
    #expect(!(await registry.tryAcquire([.recommendationIndex], owner: second)))
    #expect(await registry.tryAcquire([.playback], owner: second))
    #expect(await registry.owner(of: .recommendationIndex) == first)

    await registry.release([.recommendationIndex], owner: first)
    #expect(await registry.tryAcquire([.recommendationIndex], owner: second))
    await registry.release([.recommendationIndex, .playback], owner: second)
    #expect(await registry.owner(of: .recommendationIndex) == nil)
    #expect(await registry.owner(of: .playback) == nil)
}

@Test("Nested acquisition by one run is reference counted")
func nestedMutationResourceLeasesDoNotReleaseParent() async {
    let registry = MutationResourceLeaseRegistry()
    let owner = UUID()

    #expect(await registry.tryAcquire([.playlist], owner: owner))
    #expect(await registry.tryAcquire([.playlist], owner: owner))
    #expect(await registry.holdCount(of: .playlist, by: owner) == 2)

    await registry.release([.playlist], owner: owner)
    #expect(await registry.owner(of: .playlist) == owner)
    #expect(await registry.holdCount(of: .playlist, by: owner) == 1)

    await registry.release([.playlist], owner: owner)
    #expect(await registry.owner(of: .playlist) == nil)
}

@Test("Canonical descriptors map to least-privilege mutation resources")
func descriptorMutationResourcesMatchOperations() {
    #expect(AgentToolRegistry.descriptor(for: "playlist_add_songs")?.mutationResources == [.playlist])
    #expect(AgentToolRegistry.descriptor(for: "playback_play_song")?.mutationResources == [.playback])
    #expect(AgentToolRegistry.descriptor(for: "queue_replace")?.mutationResources == [.queue])
    #expect(AgentToolRegistry.descriptor(for: "recommendation_index_commit")?.mutationResources == [.recommendationIndex])
}

@Test("Playlist list is a read-only canonical model entry point")
func playlistListIsCanonicalAndReadOnly() {
    let descriptor = AgentToolRegistry.descriptor(for: "playlist_list")
    #expect(descriptor?.permission == .readOnly)
    #expect(descriptor?.confirmationPolicy == Optional(ToolConfirmationPolicy.none))
    #expect(descriptor?.visibility == .model)
    let selected = ToolSelector.select(for: "列出我的歌单", all: AgentToolRegistry.all).map(\.name)
    #expect(selected.contains("playlist_list"))
    #expect(!selected.contains("library_get_playlist"))
    #expect(AgentToolRegistry.descriptor(for: "listPlaylists")?.name == "playlist_list")
    #expect(AgentToolRegistry.all.first(where: { $0.name == "listPlaylists" })?.visibility == .legacyOnly)
}

@Test("Only irreversible deletion descriptors require confirmation")
func confirmationIsLimitedToIrreversibleDeletion() {
    for name in [
        "music_download_history_remove",
        "music_download_history_clean",
        "server_remove",
        "queue_clear",
        "playlist_add_songs",
        "playlist_remove_songs",
    ] {
        #expect(AgentToolRegistry.descriptor(for: name)?.confirmationPolicy == Optional(ToolConfirmationPolicy.none), "\(name) should not require confirmation")
    }
    for name in ["playlist_delete", "memory_delete", "memory_clear", "skill_delete"] {
        let descriptor = AgentToolRegistry.descriptor(for: name)
        #expect(descriptor?.permission == .destructive, "\(name) should be destructive")
        #expect(descriptor?.confirmationPolicy.requiresExplicitUserApproval == true, "\(name) should require confirmation")
    }
}

@Test("High-confidence local reads select one canonical tool without discovery")
func highConfidenceReadsUseDirectCanonicalTools() {
    let cases: [(String, String)] = [
        ("有多少歌手", "library_get_summary"),
        ("列出歌手", "library_get_artists"),
        ("列出专辑", "library_get_albums"),
        ("查看曲库统计", "library_get_summary"),
        ("当前正在播放什么", "playback_get_state"),
        ("我的播放队列里现在有哪些歌", "queue_get"),
        ("我的收藏有哪些", "library_get_starred"),
        ("列出服务器", "server_list"),
    ]

    for (text, expectedTool) in cases {
        let semantics = AgentRequestSemantics.analyze(text)
        #expect(semantics.directReadCapability?.toolName == expectedTool)
        let selected = ToolSelector.select(for: text, all: AgentToolRegistry.all).map { $0.name }
        #expect(selected == [expectedTool])
        #expect(!selected.contains("tool_search"))
        #expect(!selected.contains("library_search"))
    }
}

@Test("Direct-read semantics retain explicit list limits")
func directReadSemanticsCarryRequestedLimits() {
    let cases: [(String, String, Int)] = [
        ("列出前 10 个歌单", "playlist_list", 10),
        ("列出 20 位艺术家", "library_get_artists", 20),
        ("显示前 30 张专辑", "library_get_albums", 30),
        ("列出最近播放的 5 首", "library_get_recently_played", 5),
    ]

    for (text, toolName, limit) in cases {
        let capability = AgentRequestSemantics.analyze(text).directReadCapability
        #expect(capability?.toolName == toolName)
        #expect(capability?.arguments == ["limit": .number(Double(limit))])
    }
}
