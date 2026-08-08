import Domain
import TestSupport
import Testing

@Test("Test catalog has stable, complete fixture data")
func testCatalogShape() {
    let catalog = TestCatalogFactory.make()
    #expect(catalog.artists.count == 20)
    #expect(catalog.albums.count == 30)
    #expect(catalog.tracks.count == 200)
    #expect(Set(catalog.tracks.map(\.id)).count == 200)
    #expect(catalog.tracks.allSatisfy { $0.serverID == catalog.account.id })
    #expect(catalog.recommendations.allSatisfy { recommendation in
        let known = Set(catalog.tracks.map(\.id))
        return recommendation.trackIDs.allSatisfy(known.contains)
    })
}

@Test("Playback state exposes explicit failure instead of unknown strings")
func playbackStateFailure() {
    let state = PlaybackState.failed(.unsupportedFormat("ape"))
    #expect(state == .failed(.unsupportedFormat("ape")))
}
