import Domain
import TestSupport
import MetadataKit
import Testing

@Test("Overlay changes only explicit fields")
func explicitOverlayMerge() {
    let track = TestCatalogFactory.make().tracks[0]
    let overlay = MetadataOverlay(
        trackID: track.id,
        correctedTitle: "  远航 001  ",
        genres: [],
        confidence: 0.87,
        provenance: [.artificialIntelligence]
    )
    let resolved = MetadataMerge.resolve(original: track, overlay: overlay)
    #expect(resolved.title == "远航 001")
    #expect(resolved.artist == track.artistName)
    #expect(resolved.genres == track.genres)
}

@Test("Overlay can be undone without mutating the original track")
func undoOverlay() async {
    let track = TestCatalogFactory.make().tracks[0]
    let store = MetadataOverlayStore()
    await store.apply(.init(trackID: track.id, correctedTitle: "Corrected", confidence: 0.9, provenance: [.user]))
    #expect(await store.overlay(for: track.id)?.correctedTitle == "Corrected")
    await store.undo()
    #expect(await store.overlay(for: track.id) == nil)
    #expect(track.title != "Corrected")
}
