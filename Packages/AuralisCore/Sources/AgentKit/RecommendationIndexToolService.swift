import AIKit
import Domain
import Foundation
import LocalCatalog

/// Model-visible Recommendation Index reads plus the single Runtime-only
/// commit boundary. Batch preparation and tag snapshots are ordinary Runtime
/// functions and never appear in a Provider tool schema.
enum RecommendationIndexToolService {
    static let toolNames: Set<String> = [
        "library_index_status",
        "library_index_read",
        "recommendation_index_commit",
    ]

    static func handles(_ name: String) -> Bool { toolNames.contains(name) }

    static func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        catalog: LocalCatalogStore,
        serverID: ServerID?
    ) async throws -> ToolResult {
        switch call.name {
        case "library_index_status":
            let status = try await catalog.recommendationIndexStatus(serverID: serverID)
            let text = "推荐索引：共 \(status.totalTracks) 首；已完成固定分类 \(status.indexedTracks) 首；固定分类待处理 \(status.pendingTracks) 首；已处理语义标签 \(status.semanticProcessedTracks) 首；语义标签待处理 \(status.pendingSemanticTagTracks) 首。"
            return .ok(call, descriptor, text, .text(text), facts: statusFacts(status))

        case "library_index_read":
            let limit = min(max((try? call.int("limit")) ?? 50, 1), 100)
            let dimension = normalized(call.optionalString("dimension"))
            let value = normalized(call.optionalString("value"))
            let entries = try await catalog.readRecommendationIndex(
                serverID: serverID,
                dimension: dimension,
                value: value,
                limit: limit
            )
            guard !entries.isEmpty else {
                let filter = [dimension, value].compactMap { $0 }.joined(separator: " / ")
                return .ok(
                    call,
                    descriptor,
                    "没有符合条件的已索引条目",
                    .text(filter.isEmpty ? "当前没有可读取的已索引条目。" : "没有匹配「\(filter)」的已索引条目。")
                )
            }
            let payload = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
            return .ok(
                call,
                descriptor,
                "已读取 \(entries.count) 条索引记录",
                .text("以下是已完成的推荐索引记录（含分类标签）：\n\(payload)")
            )

        case "recommendation_index_commit":
            guard let items = decodeClassifications(call.arguments["items"]) else {
                throw AgentToolError.invalidParameter("items", "items 必须是结构化分类数组")
            }
            // ToolRuntime checked lineage authorization, trusted Skill
            // authority and the lease. Check again at the last catalog commit
            // boundary to close the await/revocation race.
            guard ToolExecutionContext.permitsMutationCommit else {
                return .fail(call, descriptor, "所属 AI 运行已取消，未写入推荐索引")
            }
            let written = try await catalog.writeRecommendationIndex(items, serverID: serverID)
            guard written == items.count else {
                return .fail(call, descriptor, "分类未完整写入，已停止当前索引运行")
            }
            let status = try await catalog.recommendationIndexStatus(serverID: serverID)
            return .ok(
                call,
                descriptor,
                "已写入 \(written) 首，仍待处理 \(status.pendingUniqueTracks) 首",
                .text("推荐索引已写入 \(written) 首。"),
                facts: statusFacts(status)
            )

        default:
            return .fail(call, descriptor, "推荐索引工具不受支持：\(call.name)")
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeClassifications(_ value: AIJSONValue?) -> [RecommendationIndexClassification]? {
        guard let value else { return nil }
        return try? JSONDecoder().decode([RecommendationIndexClassification].self, from: value.jsonData)
    }

    private static func statusFacts(_ status: RecommendationIndexStatus) -> [String: String] {
        [
            "recommendation.index.total": "\(status.totalTracks)",
            "recommendation.index.indexed": "\(status.indexedTracks)",
            "recommendation.index.pending": "\(status.pendingTracks)",
            "recommendation.index.pendingSemantic": "\(status.pendingSemanticTagTracks)",
            "recommendation.index.pendingUnique": "\(status.pendingUniqueTracks)",
            "recommendation.index.nextBatchAvailable": status.pendingUniqueTracks > 0 ? "true" : "false",
        ]
    }
}
