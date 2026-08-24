import Foundation

/// The only home for pre-release Recommendation Index identifiers. They are
/// accepted while loading saved conversations/checkpoints, but never exposed
/// through a provider schema, `tool_search`, system prompt or new UI.
public enum RecommendationIndexCompatibility {
    public static let legacySkillID = "recommendation-index-v2"
    public static let legacyStatusTool = "library_index_v2_status"
    public static let legacyReadTool = "library_index_v2_read"
    public static let retiredControlTools: Set<String> = [
        "library_index_v2_next_batch",
        "library_index_v2_write_batch",
        "library_index_v2_tag_catalog",
    ]

    public static func canonicalSkillID(_ value: String?) -> String? {
        value == legacySkillID ? RecommendationIndexSkill.id : value
    }

    public static func isLegacyBuildMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("索引 v2") || lower.contains("索引v2")
            || lower.contains("index v2") || lower.contains("library_index_v2")
    }
}
