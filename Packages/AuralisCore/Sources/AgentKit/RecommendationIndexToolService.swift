import Foundation
import Domain
import LocalCatalog

/// 推荐索引是一个普通的 Catalog 工具服务。批次协议、标签写回与结构化进度事实
/// 封装在这里，不进入 AgentRunner 的通用模型循环。
enum RecommendationIndexToolService {
    static let toolNames: Set<String> = [
        "library_index_v2_status",
        "library_index_v2_read",
        "library_index_v2_next_batch",
        "library_index_v2_write_batch",
    ]

    static func handles(_ name: String) -> Bool { toolNames.contains(name) }

    static func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        catalog: LocalCatalogStore,
        serverID: ServerID?
    ) async throws -> ToolResult {
        switch call.name {
        case "library_index_v2_status":
            let status = try await catalog.recommendationIndexV2Status(serverID: serverID)
            let text = "推荐索引 V2：共 \(status.totalTracks) 首；已完成 \(status.indexedTracks) 首；待分类 \(status.pendingTracks) 首；规则版本 \(status.rulesVersion)。"
            return .ok(call, descriptor, text, .text(text), facts: statusFacts(status, nextBatchAvailable: false))

        case "library_index_v2_read":
            let limit = min(max(int(call, "limit") ?? 50, 1), 100)
            let dimension = normalized(call.arguments["dimension"])
            let value = normalized(call.arguments["value"])
            let entries = try await catalog.readRecommendationIndexV2(
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
            return .ok(call, descriptor, "已读取 \(entries.count) 条 V2 索引记录", .text("以下是已完成的 V2 索引记录（含完整分类标签）：\n\(payload)"))

        case "library_index_v2_next_batch":
            let limit = min(max(int(call, "limit") ?? 80, 1), 100)
            let batch = try await catalog.nextRecommendationIndexV2Batch(serverID: serverID, limit: limit)
            guard !batch.tracks.isEmpty else {
                return .ok(
                    call,
                    descriptor,
                    "推荐索引 V2 已完成，无待分类歌曲",
                    .text("pending=0"),
                    facts: [
                        "recommendation.index.pending": "0",
                        "recommendation.index.nextBatchAvailable": "false",
                    ]
                )
            }
            let payload = String(decoding: try JSONEncoder().encode(batch.tracks), as: UTF8.self)
            let text = "待分类总数 \(batch.pendingTracks)，本批 \(batch.tracks.count) 首。仅根据以下元数据分类；不要解释、不要补充歌曲。完成后立刻调用 library_index_v2_write_batch，并把 itemsJSON 传为严格 JSON 数组字符串，数组必须恰好覆盖本批每个 id 一次：\n\(payload)"
            return .ok(
                call,
                descriptor,
                "V2 待分类 \(batch.pendingTracks)，已提供本批 \(batch.tracks.count) 首",
                .text(text),
                facts: [
                    "recommendation.index.pending": "\(batch.pendingTracks)",
                    "recommendation.index.nextBatchAvailable": "true",
                ]
            )

        case "library_index_v2_write_batch":
            guard let raw = call.arguments["itemsJSON"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw AgentToolError.missingParameter("itemsJSON")
            }
            let cleaned = raw
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8),
                  let items = try? JSONDecoder().decode([RecommendationIndexV2Classification].self, from: data)
            else {
                throw AgentToolError.invalidParameter("itemsJSON", "必须是 JSON 数组，且每项包含 id/moods/scenes/energy/tempo/acousticness/danceability/vocals/textures/styles/confidence")
            }
            let written = try await catalog.writeRecommendationIndexV2(items, serverID: serverID)
            let status = try await catalog.recommendationIndexV2Status(serverID: serverID)
            guard written > 0 else {
                return .fail(call, descriptor, "没有可写入的分类：请只提交上一批真实 ID、规范标签；energy 为 1-10，其余数值维度为 1-5")
            }

            let text: String
            var nextBatchAvailable = false
            if status.pendingTracks > 0 {
                let nextBatch = try await catalog.nextRecommendationIndexV2Batch(serverID: serverID, limit: 80)
                nextBatchAvailable = !nextBatch.tracks.isEmpty
                let payload = String(decoding: try JSONEncoder().encode(nextBatch.tracks), as: UTF8.self)
                text = "已写入 \(written) 首。尚待分类 \(status.pendingTracks) 首。下一批 \(nextBatch.tracks.count) 首已直接提供；不要调用 library_index_v2_next_batch，也不要输出自然语言。请立刻只根据下列元数据生成严格 JSON 数组，并调用 library_index_v2_write_batch(itemsJSON=该数组)：\n\(payload)"
            } else {
                text = "已写入 \(written) 首。尚待分类 0 首。索引 V2 已完成。"
            }
            return .ok(
                call,
                descriptor,
                "V2 已写入 \(written) 首，待分类 \(status.pendingTracks) 首",
                .text(text),
                facts: statusFacts(status, nextBatchAvailable: nextBatchAvailable)
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

    private static func int(_ call: ToolCall, _ key: String) -> Int? {
        guard let raw = normalized(call.arguments[key]) else { return nil }
        return Int(raw)
    }

    private static func statusFacts(
        _ status: RecommendationIndexV2Status,
        nextBatchAvailable: Bool
    ) -> [String: String] {
        [
            "recommendation.index.total": "\(status.totalTracks)",
            "recommendation.index.indexed": "\(status.indexedTracks)",
            "recommendation.index.pending": "\(status.pendingTracks)",
            "recommendation.index.nextBatchAvailable": nextBatchAvailable ? "true" : "false",
        ]
    }
}
