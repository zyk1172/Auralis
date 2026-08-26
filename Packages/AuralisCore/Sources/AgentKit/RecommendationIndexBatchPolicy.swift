import Foundation

/// Recommendation Index 的单次传输分片策略。
///
/// 这里只控制单次 function call 的规模，不限制整个索引规模。
/// 全量任务的真实完成条件始终是 pending == 0。
enum RecommendationIndexBatchPolicy {
    /// A malformed response must be recoverable down to one track. If a
    /// single-track transform still fails, the Runtime terminates that batch
    /// instead of looping forever.
    static let minimumTracksPerBatch = 1
    static let fallbackTracksPerBatch = 16

    /// 原生 schema 已允许 maxItems=100，因此运行时上限与 schema 对齐。
    static let maximumTracksPerBatch = 100

    /// Tool Result 本身允许约 60K 字符。
    /// 这里保留额外包装、中文说明及 JSON 开销，不能直接顶到 60K。
    static let safePayloadBytes = 48_000

    static func recommendedLimit(
        maxOutputTokens: Int,
        mode: String? = nil
    ) -> Int {
        _ = mode
        let base: Int

        switch maxOutputTokens {
        case ..<8_000:
            base = 8

        case ..<16_000:
            base = 16

        case ..<32_000:
            base = 32

        case ..<64_000:
            base = 64

        default:
            base = 100
        }

        return min(
            max(base, minimumTracksPerBatch),
            maximumTracksPerBatch
        )
    }

    /// 输出被截断时按完整批次缩小。
    /// 永远不能把 JSON 字符串直接截断。
    static func reducedLimit(from current: Int) -> Int {
        max(
            minimumTracksPerBatch,
            current / 2
        )
    }
}
