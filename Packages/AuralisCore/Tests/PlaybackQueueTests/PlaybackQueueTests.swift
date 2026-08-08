import Domain
import TestSupport
import Foundation
import PlaybackQueue
import Testing

@Test("Queue preserves current track when items move")
func moveQueueItems() async {
    let tracks = Array(TestCatalogFactory.make().tracks.prefix(4))
    let queue = PlaybackQueueStore(snapshot: .init(tracks: tracks, currentIndex: 1))
    await queue.move(from: IndexSet(integer: 0), to: 4)
    let snapshot = await queue.value()
    #expect(snapshot.current?.id == tracks[1].id)
    #expect(snapshot.tracks.last?.id == tracks[0].id)
}

@Test("Removing current item advances to a valid item")
func removeCurrentItem() async {
    let tracks = Array(TestCatalogFactory.make().tracks.prefix(3))
    let queue = PlaybackQueueStore(snapshot: .init(tracks: tracks, currentIndex: 1))
    #expect(await queue.remove(id: tracks[1].id))
    let snapshot = await queue.value()
    #expect(snapshot.current?.id == tracks[2].id)
}
