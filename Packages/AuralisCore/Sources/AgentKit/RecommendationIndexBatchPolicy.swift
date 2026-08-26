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
    /// 未声明上下文窗口时，完整分类请求仍使用这个保守上限。
    static let safePayloadBytes = 48_000

    /// UTF-8 bytes / 3 is intentionally conservative for mixed Chinese and
    /// JSON input. This is a budget guard, not a tokenizer replacement.
    static let estimatedBytesPerToken = 3
    /// Leaves room for roles, request wrappers, provider-specific fields and
    /// small tokenization differences beyond the measured request bodies.
    static let contextSafetyMarginTokens = 512

    /// `ModelCapabilities.maxOutputTokens` is a provider ceiling, not a
    /// reservation that every small classification batch must consume. Keep
    /// enough room for the response envelope and a compact v3 item while
    /// scaling the requested ceiling with the number of tracks in this batch.
    static let classificationEnvelopeReserveTokens = 128
    static let minimumClassificationOutputTokens = 512
    static let estimatedClassificationOutputTokensPerTrack = 256
    /// Evidence is optional, but a native tool-call envelope still needs a
    /// meaningful response budget. Below this threshold skip evidence rather
    /// than paying for a request that can only be truncated.
    static let minimumEvidenceOutputTokens = 512

    static func minimumRequiredClassificationOutputTokens(batchSize: Int) -> Int {
        let normalizedBatchSize = max(1, batchSize)
        return max(
            minimumClassificationOutputTokens,
            classificationEnvelopeReserveTokens
                + normalizedBatchSize * estimatedClassificationOutputTokensPerTrack
        )
    }

    static func effectiveClassificationOutputTokens(
        providerMaxOutputTokens: Int,
        batchSize: Int
    ) -> Int {
        let providerLimit = max(1, providerMaxOutputTokens)
        let estimatedNeeded = minimumRequiredClassificationOutputTokens(batchSize: batchSize)
        return min(providerLimit, estimatedNeeded)
    }

    /// Returns a sendable output budget only when it can form the complete
    /// classification envelope. A short context remainder is not converted
    /// into a technically valid but business-useless one-token request.
    static func viableClassificationOutputTokens(
        providerMaxOutputTokens: Int,
        batchSize: Int,
        availableOutputTokens: Int?
    ) -> Int? {
        let minimumRequired = minimumRequiredClassificationOutputTokens(batchSize: batchSize)
        guard providerMaxOutputTokens >= minimumRequired else { return nil }
        if let availableOutputTokens, availableOutputTokens < minimumRequired {
            return nil
        }
        return min(providerMaxOutputTokens, availableOutputTokens ?? minimumRequired)
    }

    struct RequestBudget: Equatable, Sendable {
        let requestBytes: Int
        let estimatedInputTokens: Int
        let reservedOutputTokens: Int
        let maxContextTokens: Int?

        var estimatedTotalTokens: Int {
            estimatedInputTokens + reservedOutputTokens + contextSafetyMarginTokens
        }

        var estimatedTotalBytes: Int {
            requestBytes
                + (reservedOutputTokens + contextSafetyMarginTokens) * estimatedBytesPerToken
        }

        var fits: Bool {
            if let maxContextTokens {
                return estimatedTotalTokens <= maxContextTokens
            }
            // There is no trustworthy token-window fact to compare against
            // for an unrecognised endpoint. Keep the serialized input under
            // the conservative transport envelope; the output reserve remains
            // visible in estimatedTotalTokens/estimatedTotalBytes and is
            // enforced whenever a real context window is declared.
            return requestBytes <= safePayloadBytes
        }

        var summary: String {
            if let maxContextTokens {
                return "estimated_input_tokens=\(estimatedInputTokens), reserved_output_tokens=\(reservedOutputTokens), safety_margin_tokens=\(contextSafetyMarginTokens), max_context_tokens=\(maxContextTokens)"
            }
            return "estimated_request_bytes=\(requestBytes), estimated_total_with_reserve_bytes=\(estimatedTotalBytes), fallback_safe_bytes=\(safePayloadBytes)"
        }
    }

    /// Measure the complete classification request, including system prompt,
    /// taxonomy/evidence payload, and a strict output schema when present.
    /// `maxContextTokens == nil` deliberately selects the legacy conservative
    /// byte fallback for providers that do not declare a context window.
    static func requestBudget(
        systemPromptBytes: Int,
        payloadBytes: Int,
        outputSchemaBytes: Int,
        requestWrapperBytes: Int = 0,
        maxContextTokens: Int?,
        reservedOutputTokens: Int
    ) -> RequestBudget {
        let requestBytes = max(0, systemPromptBytes)
            + max(0, payloadBytes)
            + max(0, outputSchemaBytes)
            + max(0, requestWrapperBytes)
        let estimatedInputTokens = requestBytes == 0
            ? 0
            : (requestBytes + estimatedBytesPerToken - 1) / estimatedBytesPerToken
        return RequestBudget(
            requestBytes: requestBytes,
            estimatedInputTokens: estimatedInputTokens,
            reservedOutputTokens: max(0, reservedOutputTokens),
            maxContextTokens: maxContextTokens
        )
    }

    static func recommendedLimit(
        maxOutputTokens: Int
    ) -> Int {
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
