// SPDX-License-Identifier: GPL-3.0-only
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
        "recommendation_taxonomy_list",
        "recommendation_taxonomy_search",
        "recommendation_index_commit",
    ]

    static func handles(_ name: String) -> Bool { toolNames.contains(name) }

    static func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        executionRegistry: RecommendationIndexExecutionRegistry
    ) async throws -> ToolResult {
        switch call.name {
        case "library_index_status":
            let status = try await catalog.recommendationIndexStatus(serverID: serverID)
            let executionState = await executionRegistry.snapshot(serverID: serverID)
            let text = "推荐索引数据：共 \(status.totalTracks) 首；已完成固定分类 \(status.indexedTracks) 首；固定分类待处理 \(status.pendingTracks) 首。\n执行状态：\(executionState.userFacingSummary)。"
            return .ok(call, descriptor, text, .text(text), facts: statusFacts(status, executionState: executionState))

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

        case "recommendation_taxonomy_list":
            let dimension = normalized(call.optionalString("dimension"))
            let limit = min(max((try? call.int("limit")) ?? 200, 1), 500)
            let definitions: [TagDefinition]
            if let dimension, let tagDimension = TagDimension(rawValue: dimension) {
                definitions = Array(RecommendationIndexTaxonomy.definitions(for: tagDimension).prefix(limit))
            } else {
                definitions = Array(RecommendationIndexTaxonomy.all.prefix(limit))
            }
            let payload = String(decoding: try JSONEncoder().encode(definitions), as: UTF8.self)
            return .ok(
                call,
                descriptor,
                "已返回 \(definitions.count) 个固定 taxonomy 标签",
                .text(payload)
            )

        case "recommendation_taxonomy_search":
            let query = normalized(call.optionalString("query")) ?? ""
            let limit = min(max((try? call.int("limit")) ?? 12, 1), 50)
            let definitions = RecommendationIndexTaxonomy.search(query, limit: limit)
            let payload = String(decoding: try JSONEncoder().encode(definitions), as: UTF8.self)
            return .ok(
                call,
                descriptor,
                "已匹配 \(definitions.count) 个固定 taxonomy 标签",
                .text(payload)
            )

        case "recommendation_index_commit":
            guard let items = decodeClassifications(call.arguments["items"]) else {
                throw AgentToolError.invalidParameter("items", "items 必须是结构化分类数组")
            }
            guard let batchIDText = call.optionalString("batchID"),
                  let batchID = UUID(uuidString: batchIDText),
                  let revisionValue = try? call.int("revision"),
                  revisionValue > 0 else {
                throw AgentToolError.invalidParameter("batchID/revision", "缺少有效的当前批次身份")
            }
            // ToolRuntime checked lineage authorization, trusted Skill
            // authority and the lease. Check again at the last catalog commit
            // boundary to close the await/revocation race.
            guard ToolExecutionContext.permitsMutationCommit else {
                return .fail(call, descriptor, "所属 AI 运行已取消，未写入推荐索引")
            }
            let executionState = await executionRegistry.snapshot(serverID: serverID)
            guard case let .running(running) = executionState,
                  running.runID == ToolExecutionContext.lease?.runID,
                  running.batchID == batchID,
                  running.batchRevision == UInt64(revisionValue),
                  !running.batchTrackIDs.isEmpty else {
                return .fail(call, descriptor, "推荐索引提交已过期或不属于当前运行，未写入任何数据")
            }
            let actualIDs = items.map(\.id)
            let expectedIDs = running.batchTrackIDs
            guard !actualIDs.isEmpty,
                  Set(actualIDs).count == actualIDs.count,
                  Set(actualIDs).isSubset(of: Set(expectedIDs)) else {
                return .fail(call, descriptor, "推荐索引提交包含重复或不属于当前批次的 ID，未写入任何数据")
            }
            let written = try await catalog.writeRecommendationIndex(
                items,
                serverID: serverID,
                requireExact: true
            )
            guard written == items.count else {
                return .fail(call, descriptor, "分类未完整写入，已停止当前索引运行")
            }
            let status = try await catalog.recommendationIndexStatus(serverID: serverID)
            let verifiedExecutionState = await executionRegistry.snapshot(serverID: serverID)
            return .ok(
                call,
                descriptor,
                "已写入 \(written) 首（当前批次允许部分成功），仍待处理 \(status.pendingUniqueTracks) 首",
                .text("推荐索引已写入 \(written) 首。"),
                facts: statusFacts(status, executionState: verifiedExecutionState)
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

    private static func statusFacts(
        _ status: RecommendationIndexStatus,
        executionState: RecommendationIndexExecutionState = .idle
    ) -> [String: String] {
        var facts = [
            "recommendation.index.total": "\(status.totalTracks)",
            "recommendation.index.indexed": "\(status.indexedTracks)",
            "recommendation.index.pending": "\(status.pendingTracks)",
            "recommendation.index.pendingUnique": "\(status.pendingUniqueTracks)",
            "recommendation.index.nextBatchAvailable": status.pendingUniqueTracks > 0 ? "true" : "false",
        ]
        facts["recommendation.index.executionState"] = executionState.isRunning ? "running" : "idle"
        facts["recommendation.index.executionSummary"] = executionState.userFacingSummary
        return facts
    }
}
