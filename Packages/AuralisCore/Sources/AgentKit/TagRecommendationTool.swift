// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AIKit
import Domain
import Foundation
import LocalCatalog

enum TagRecommendationTool {
    static let parameters: [ToolParameter] = [
        .init(name: "includeTags", required: false, description: "必须同时满足的稳定 TagID（AND）；绝不自动放宽。", schemaJSON: tagArraySchema),
        .init(name: "preferTags", required: false, description: "意图偏好 TagID；同维度为备选，跨维度平衡评分。只有偏好、没有硬性正向条件时至少命中一项。", schemaJSON: tagArraySchema),
        .init(name: "excludeTags", required: false, description: "排除任一标签命中的歌曲。", schemaJSON: tagArraySchema),
        .init(name: "numericRanges", required: false, description: "固定数值维度到 [最小,最大] 的硬范围。energy=1...10；tempo/acousticness/danceability/instrumentalness/liveness/speechiness/valence/complexity=1...5，非 BPM。", schemaJSON: #"{"type":"object","additionalProperties":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2}}"#),
        .init(name: "excludeTrackIDs", required: false, description: "已展示/已选择的 GlobalTrackID 字符串，防止重复补足。", schemaJSON: tagArraySchema),
        .init(name: "minimumConfidence", required: false, description: "标签最低分类置信度，默认 0.35；不是音频实测概率。", schemaJSON: #"{"type":"number","minimum":0,"maximum":1}"#),
        .init(name: "maxPerAlbum", required: false, description: "最终同专辑上限，默认 2。", schemaJSON: #"{"type":"integer","minimum":1,"maximum":10}"#),
    ]
    private static let tagArraySchema = #"{"type":"array","items":{"type":"string"},"maxItems":200}"#

    static func query(_ call: ToolCall, limit: Int) throws -> TagRecommendationQuery {
        var ranges = [String: ClosedRange<Int>]()
        if let raw = call.arguments["numericRanges"], raw != .null {
            guard case let .object(object) = raw else { throw ToolArgumentError.invalid("numericRanges", expected: "object") }
            for (dimension, value) in object {
                guard let upper = TagRecommendationQuery.numericUpperBounds[dimension],
                      case let .array(bounds) = value, bounds.count == 2,
                      case let .number(lower) = bounds[0], case let .number(higher) = bounds[1],
                      lower.isFinite, higher.isFinite, lower.rounded() == lower, higher.rounded() == higher,
                      lower >= 1, higher <= Double(upper), lower <= higher else {
                    throw TagRecommendationError.invalidRange(dimension)
                }
                ranges[dimension] = Int(lower)...Int(higher)
            }
        }
        let confidence: Double
        if let value = call.arguments["minimumConfidence"], value != .null {
            confidence = try call.double("minimumConfidence")
        } else { confidence = 0.35 }
        return TagRecommendationQuery(
            includeTags: try strings(call, "includeTags"), preferTags: try strings(call, "preferTags"),
            excludeTags: try strings(call, "excludeTags"), numericRanges: ranges,
            excludedTrackIDs: Set(try strings(call, "excludeTrackIDs")),
            minimumConfidence: confidence,
            maxPerArtist: (try? call.int("maxPerArtist")) ?? 2,
            maxPerAlbum: (try? call.int("maxPerAlbum")) ?? 2, limit: limit
        )
    }

    static func hasIntent(_ query: TagRecommendationQuery) -> Bool {
        !query.includeTags.isEmpty || !query.preferTags.isEmpty || !query.numericRanges.isEmpty
    }

    static func execute(_ call: ToolCall, descriptor: ToolDescriptor, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> ToolResult {
        let limit = (try? call.int("limit")) ?? 20
        let query = try query(call, limit: limit)
        let servers = [serverID, LocalCatalogOverlay.localServerID].compactMap { $0 }
        let picks = try await catalog.recommendByTags(serverIDs: servers, query: query)
        let reasons = Dictionary(uniqueKeysWithValues: picks.map {
            (GlobalID(serverID: $0.track.serverID, remoteID: $0.track.id.rawValue).description, $0.matchedTags)
        })
        return ToolResult(
            call: call, permission: descriptor.permission, success: true,
            summary: "本地标签推荐 \(picks.count)/\(query.limit) 首；严格保留标签/排除/数值范围与艺人、专辑上限，未随机补足。",
            payload: .trackCards(picks.map { TrackCard.from($0.track) }),
            facts: [
                "recommendation.source": "tag_index",
                "recommendation.tags.shortfall": String(max(0, query.limit - picks.count)),
                "recommendation.tags.matches": String(decoding: try JSONEncoder().encode(reasons), as: UTF8.self),
            ], presentationRole: .candidate
        )
    }

    private static func strings(_ call: ToolCall, _ name: String) throws -> [String] {
        guard let raw = call.arguments[name], raw != .null else { return [] }
        guard case let .array(values) = raw, values.count <= 200 else { throw ToolArgumentError.invalid(name, expected: "string array (max 200)") }
        return try values.map { value in
            guard case let .string(text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError.invalid(name, expected: "non-empty strings")
            }
            return text
        }
    }
}
