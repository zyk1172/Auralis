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
        "library_index_v2_tag_catalog",
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
            let text = "推荐索引 V2：共 \(status.totalTracks) 首；已完成固定分类 \(status.indexedTracks) 首；待分类 \(status.pendingTracks) 首；已有开放语义标签 \(status.semanticTaggedTracks) 首；待补开放标签 \(status.pendingSemanticTagTracks) 首；规则版本 \(status.rulesVersion)；语义标签规则版本 \(status.semanticTagRulesVersion)。"
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
            let modeHint: String
            switch batch.mode {
            case "semanticTagsOnly": modeHint = "本批只需要补开放语义标签（mode=\"semanticTagsOnly\"）：不要改动固定维度，只写 semanticTags。"
            case "mixed": modeHint = "本批混合：有固定分类的歌曲只补 semanticTags（mode=\"semanticTagsOnly\"），没有固定分类的歌曲做完整分类（mode=\"full\"）。"
            default: modeHint = "本批需要完整分类（mode=\"full\"）：固定维度 + 开放语义标签。"
            }
            let tagRules = "开放语义标签规则：固定维度（moods/scenes/vocals/textures/styles 与 energy/tempo/acousticness/danceability 数值）保持规范；此外可以根据音乐属性创建开放 semantic tags（value 为规范化中文或常见英文词，如 夜行感/公路感/城市霓虹/复古合成器/电影感），标签数量没有硬上限；优先复用已有 canonical 标签（可用 library_index_v2_tag_catalog 查看）；不要用歌曲名/艺术家名/专辑名/ID 或收藏评分播放历史当标签；同一概念不要拆成多个写法。"
            let text = "待分类总数 \(batch.pendingTracks)，本批 \(batch.tracks.count) 首；本批模式：\(batch.mode)。仅根据以下元数据分类；不要解释、不要补充歌曲。完成后立刻调用 library_index_v2_write_batch，把结构化 items 数组直接传入，数组必须恰好覆盖本批每个 id 一次。\(modeHint) \(tagRules)：\n\(payload)"
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
            // `items` 是当前原生结构化参数；`itemsJSON` 继续兼容已保存的旧会话和
            // 不支持原生 tools 的 ACTION 文本协议。
            guard let rawValue = call.arguments["items"] ?? call.arguments["itemsJSON"] else {
                throw AgentToolError.missingParameter("items")
            }
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw AgentToolError.missingParameter("items") }
            let cleaned = raw
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let items = decodeClassifications(cleaned) else {
                throw AgentToolError.invalidParameter("items", "必须是结构化数组；每项至少包含 id/energy，可包含内置标签与 confidence")
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
                let modeHint = nextBatch.mode == "semanticTagsOnly"
                    ? "本批只补开放语义标签（mode=\"semanticTagsOnly\"），不要改动固定维度。"
                    : (nextBatch.mode == "mixed" ? "本批混合：无固定分类的歌曲做完整分类，其余只补 semanticTags。" : "本批完整分类（mode=\"full\"）。")
                text = "已写入 \(written) 首。尚待分类 \(status.pendingTracks) 首。下一批 \(nextBatch.tracks.count) 首已直接提供（本批模式：\(nextBatch.mode)）；不要调用 library_index_v2_next_batch，也不要输出自然语言。\(modeHint) 请立刻只根据下列元数据生成结构化 items 数组，并调用 library_index_v2_write_batch(items=该数组)：\n\(payload)"
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

        case "library_index_v2_tag_catalog":
            let limit = min(max(int(call, "limit") ?? 50, 1), 500)
            let query = normalized(call.arguments["query"])
            let tags = try await catalog.recommendationIndexV2TagCatalog(serverID: serverID, query: query, limit: limit)
            guard !tags.isEmpty else {
                return .ok(call, descriptor, "还没有开放语义标签", .text("当前没有已存在的开放语义标签；可以开始为歌曲创建规范标签。"))
            }
            let lines = tags.map { "「\($0.value)」× \($0.trackCount) 首" }.joined(separator: "、")
            let filter = query.map { "（匹配：\($0)）" } ?? ""
            return .ok(call, descriptor, "开放语义标签 \(tags.count) 个", .text("已有开放语义标签\(filter)：\(lines)"))

        default:
            return .fail(call, descriptor, "推荐索引工具不受支持：\(call.name)")
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeClassifications(_ raw: String) -> [RecommendationIndexV2Classification]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        if let direct = try? JSONDecoder().decode([RecommendationIndexV2Classification].self, from: data) {
            return direct
        }
        // 少数兼容网关会把参数再包一层 {"items":[...]}；在工具边界宽容解包，
        // 但真正的分类对象仍由 Codable 和落库校验严格验证。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"], JSONSerialization.isValidJSONObject(items),
              let nested = try? JSONSerialization.data(withJSONObject: items)
        else { return nil }
        return try? JSONDecoder().decode([RecommendationIndexV2Classification].self, from: nested)
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
