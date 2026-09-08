// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LocalCatalog
import Testing

@Suite("Legacy Recommendation Index v2 compatibility")
struct LegacyRecommendationIndexClassificationDecodeTests {
    @Test("Legacy semanticTags object payload decodes outside the live v3 DTO")
    func legacySemanticTagsDecodeAndProject() throws {
        let json = #"""
        {
          "id": "server:track-1",
          "moods": ["神圣"],
          "semanticTags": [
            {"value": "夜行感", "confidence": 0.8}
          ],
          "mode": "full",
          "confidence": 0.9
        }
        """#

        let legacy = try JSONDecoder().decode(
            LegacyRecommendationIndexClassificationV2.self,
            from: Data(json.utf8)
        )

        #expect(legacy.semanticTags.map(\.value) == ["夜行感"])
        #expect(legacy.semanticTags.first?.confidence == 0.8)
        #expect(legacy.mode == "full")
        #expect(legacy.fixedTaxonomyClassification.id == "server:track-1")
        #expect(legacy.fixedTaxonomyClassification.moods == ["神圣"])
    }
}
