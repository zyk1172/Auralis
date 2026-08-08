import Domain
import TestSupport
import RecommendationEngine
import Testing

@Test("Recommendations stay inside the library and enforce artist diversity")
func deterministicRecommendation() {
    let catalog = TestCatalogFactory.make()
    let result = HybridRecommendationEngine.recommend(
        tracks: catalog.tracks,
        query: .init(languages: ["zh-Hans"], maximumTracksPerArtist: 1, limit: 12),
        history: catalog.history
    )
    #expect(result.allSatisfy { $0.language == "zh-Hans" })
    #expect(Set(result.map(\.artistID)).count == result.count)
    #expect(HybridRecommendationEngine.validate(trackIDs: result.map(\.id), library: catalog.tracks))
}

@Test("Invented Track IDs are rejected")
func rejectsInventedIDs() {
    let catalog = TestCatalogFactory.make()
    #expect(!HybridRecommendationEngine.validate(trackIDs: ["not-in-library"], library: catalog.tracks))
}
