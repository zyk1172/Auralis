import AgentKit
import Foundation
import Testing

@Test("Runtime confirmation accepts short approve/reject decisions only")
func confirmationDecisionNormalizationIsBounded() {
    #expect(AgentConfirmationDecision.parse("确认") == .confirm)
    #expect(AgentConfirmationDecision.parse(" OK！ ") == .confirm)
    #expect(AgentConfirmationDecision.parse("确定把 12 首歌加入歌单") == .unknown)
    #expect(AgentConfirmationDecision.parse("取消") == .reject)
    #expect(AgentConfirmationDecision.parse("不要执行") == .unknown)
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
