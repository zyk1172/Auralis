import Foundation

/// Recommendation Index V2 的传输分片策略。它只限制单次 function call 的曲目数，
/// 不限制整个索引规模，也不限制开放语义标签词库。
enum RecommendationIndexV2BatchPolicy {
    static let minimumTracksPerBatch = 8
    static let fallbackTracksPerBatch = 16
    static let maximumTracksPerBatch = 32
    /// 留给 ToolResult 包装文案的余量，避免通用截断器切开 JSON。
    static let safePayloadBytes = 18_000

    static func recommendedLimit(maxOutputTokens: Int, mode: String? = nil) -> Int {
        let base: Int
        switch maxOutputTokens {
        case ..<8_000: base = minimumTracksPerBatch
        case ..<16_000: base = fallbackTracksPerBatch
        case 32_000...: base = maximumTracksPerBatch
        default: base = 24
        }
        let adjusted = mode == "semanticTagsOnly" ? base + 4 : base
        return min(max(adjusted, minimumTracksPerBatch), maximumTracksPerBatch)
    }

    static func reducedLimit(from current: Int) -> Int {
        max(minimumTracksPerBatch, current / 2)
    }
}
