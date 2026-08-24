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

@Test("Canonical descriptors map to least-privilege mutation resources")
func descriptorMutationResourcesMatchOperations() {
    #expect(AgentToolRegistry.descriptor(for: "playlist_add_songs")?.mutationResources == [.playlist])
    #expect(AgentToolRegistry.descriptor(for: "playback_play_song")?.mutationResources == [.playback])
    #expect(AgentToolRegistry.descriptor(for: "queue_replace")?.mutationResources == [.queue])
    #expect(AgentToolRegistry.descriptor(for: "recommendation_index_commit")?.mutationResources == [.recommendationIndex])
}
