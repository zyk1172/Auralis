import AIKit
import Domain
import Foundation
import LocalCatalog

/// A batch owned by one Recommendation Index Runtime generation.  The model
/// receives this identity as data and must echo it; only the Runtime can turn
/// a matching envelope into a catalog commit.
public struct RecommendationIndexPreparedBatch: Sendable, Equatable {
    public let batchID: UUID
    public let revision: UInt64
    public let checkpointGeneration: UInt64
    public let tracks: [CatalogTrackLine]
    public let pendingFixed: Int

    public init(
        batchID: UUID,
        revision: UInt64,
        checkpointGeneration: UInt64,
        tracks: [CatalogTrackLine],
        pendingFixed: Int
    ) {
        self.batchID = batchID
        self.revision = revision
        self.checkpointGeneration = checkpointGeneration
        self.tracks = tracks
        self.pendingFixed = pendingFixed
    }
}

/// Sanitized, run-scoped evidence attached to one track before the closed
/// classifier runs.  It is never persisted and never carries raw web pages or
/// full lyrics.
public struct RecommendationIndexEvidenceRecord: Codable, Sendable, Equatable {
    public let toolName: String
    public let targetTrackID: String?
    public let kind: String
    public let summaryForModel: String
    /// Compact structured projection of the tool payload. Kept bounded and
    /// never persisted; it gives the closed classifier more than a summary.
    public let payloadProjection: String?

    public init(
        toolName: String,
        targetTrackID: String?,
        kind: String,
        summaryForModel: String,
        payloadProjection: String? = nil
    ) {
        self.toolName = toolName
        self.targetTrackID = targetTrackID
        self.kind = kind
        self.summaryForModel = summaryForModel
        self.payloadProjection = payloadProjection
    }
}

public struct RecommendationIndexTrackEvidence: Codable, Sendable, Equatable {
    public let track: CatalogTrackLine
    public let evidence: [RecommendationIndexEvidenceRecord]
}

/// The sole model-produced value in the closed Recommendation Index chain.
/// It is data, not a request to execute a tool.
public struct RecommendationIndexClassificationEnvelope: Codable, Sendable, Equatable {
    public let batchID: UUID
    public let revision: UInt64
    public let items: [RecommendationIndexClassification]

    public init(
        batchID: UUID,
        revision: UInt64,
        items: [RecommendationIndexClassification]
    ) {
        self.batchID = batchID
        self.revision = revision
        self.items = items
    }
}

public enum RecommendationIndexValidationError: Error, LocalizedError, Equatable, Sendable {
    case staleBatch
    case duplicateIDs
    case incompleteCoverage

    public var errorDescription: String? {
        switch self {
        case .staleBatch: "分类结果不属于当前批次"
        case .duplicateIDs: "分类结果包含重复歌曲 ID"
        case .incompleteCoverage: "分类结果没有恰好覆盖当前批次"
        }
    }
}

public enum RecommendationIndexClassificationFailureStage: String, Codable, Sendable {
    case providerOutput
    case jsonExtraction
    case codableDecode
    case contextBudget
    case batchIdentity
    case revision
    case trackCoverage
    case taxonomy
    case commit
    case verify
    case noProgress
}

/// Redacted, structured diagnostics for a failed closed classification turn.
/// Raw model output is intentionally not persisted or shown in the chat UI.
public struct RecommendationIndexClassificationDiagnostics: Error, LocalizedError, Codable, Sendable, Equatable {
    public let stage: RecommendationIndexClassificationFailureStage
    public let batchSize: Int
    public let rawLength: Int
    public let jsonFound: Bool
    public let message: String
    public let expectedBatchID: UUID?
    public let receivedBatchID: UUID?
    public let expectedRevision: UInt64?
    public let receivedRevision: UInt64?
    public let missingIDs: [String]
    public let extraIDs: [String]
    public let duplicateIDs: [String]
    public let pendingBefore: Int?
    public let pendingAfter: Int?
    public let pendingDelta: Int?
    public let fieldPath: String?
    public let expectedType: String?
    public let actualType: String?

    public init(
        stage: RecommendationIndexClassificationFailureStage,
        batchSize: Int,
        rawLength: Int,
        jsonFound: Bool,
        message: String,
        expectedBatchID: UUID? = nil,
        receivedBatchID: UUID? = nil,
        expectedRevision: UInt64? = nil,
        receivedRevision: UInt64? = nil,
        missingIDs: [String] = [],
        extraIDs: [String] = [],
        duplicateIDs: [String] = [],
        pendingBefore: Int? = nil,
        pendingAfter: Int? = nil,
        pendingDelta: Int? = nil,
        fieldPath: String? = nil,
        expectedType: String? = nil,
        actualType: String? = nil
    ) {
        self.stage = stage
        self.batchSize = batchSize
        self.rawLength = rawLength
        self.jsonFound = jsonFound
        self.message = message
        self.expectedBatchID = expectedBatchID
        self.receivedBatchID = receivedBatchID
        self.expectedRevision = expectedRevision
        self.receivedRevision = receivedRevision
        self.missingIDs = Array(missingIDs.prefix(20))
        self.extraIDs = Array(extraIDs.prefix(20))
        self.duplicateIDs = Array(duplicateIDs.prefix(20))
        self.pendingBefore = pendingBefore
        self.pendingAfter = pendingAfter
        self.pendingDelta = pendingDelta
        self.fieldPath = fieldPath
        self.expectedType = expectedType
        self.actualType = actualType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(RecommendationIndexClassificationFailureStage.self, forKey: .stage)
        batchSize = try container.decode(Int.self, forKey: .batchSize)
        rawLength = try container.decode(Int.self, forKey: .rawLength)
        jsonFound = try container.decode(Bool.self, forKey: .jsonFound)
        message = try container.decode(String.self, forKey: .message)
        expectedBatchID = try container.decodeIfPresent(UUID.self, forKey: .expectedBatchID)
        receivedBatchID = try container.decodeIfPresent(UUID.self, forKey: .receivedBatchID)
        expectedRevision = try container.decodeIfPresent(UInt64.self, forKey: .expectedRevision)
        receivedRevision = try container.decodeIfPresent(UInt64.self, forKey: .receivedRevision)
        missingIDs = try container.decodeIfPresent([String].self, forKey: .missingIDs) ?? []
        extraIDs = try container.decodeIfPresent([String].self, forKey: .extraIDs) ?? []
        duplicateIDs = try container.decodeIfPresent([String].self, forKey: .duplicateIDs) ?? []
        pendingBefore = try container.decodeIfPresent(Int.self, forKey: .pendingBefore)
        pendingAfter = try container.decodeIfPresent(Int.self, forKey: .pendingAfter)
        pendingDelta = try container.decodeIfPresent(Int.self, forKey: .pendingDelta)
        fieldPath = try container.decodeIfPresent(String.self, forKey: .fieldPath)
        expectedType = try container.decodeIfPresent(String.self, forKey: .expectedType)
        actualType = try container.decodeIfPresent(String.self, forKey: .actualType)
    }

    public var errorDescription: String? {
        "\(stage.rawValue): \(message)"
    }

    public var compactSummary: String {
        var parts = [
            "stage=\(stage.rawValue)",
            "batch_size=\(batchSize)",
            "raw_length=\(rawLength)",
            "json_found=\(jsonFound)",
            "error=\(message)",
        ]
        if let expectedBatchID, let receivedBatchID {
            parts.append("expected_batch_id=\(expectedBatchID.uuidString), received_batch_id=\(receivedBatchID.uuidString)")
        }
        if let expectedRevision, let receivedRevision {
            parts.append("expected_revision=\(expectedRevision), received_revision=\(receivedRevision)")
        }
        if let fieldPath { parts.append("field=\(fieldPath)") }
        if let expectedType, let actualType {
            parts.append("expected=\(expectedType), actual=\(actualType)")
        }
        if !missingIDs.isEmpty { parts.append("missing_ids=\(missingIDs.joined(separator: ","))") }
        if !extraIDs.isEmpty { parts.append("extra_ids=\(extraIDs.joined(separator: ","))") }
        if !duplicateIDs.isEmpty { parts.append("duplicate_ids=\(duplicateIDs.joined(separator: ","))") }
        if let pendingBefore { parts.append("pending_before=\(pendingBefore)") }
        if let pendingAfter { parts.append("pending_after=\(pendingAfter)") }
        if let pendingDelta { parts.append("pending_delta=\(pendingDelta)") }
        return parts.joined(separator: ", ")
    }
}

/// Provider-neutral parser for the only model-produced value in the index
/// workflow. Keeping this separate makes wire incompatibilities diagnosable
/// without coupling the Runtime to a provider's response type.
public enum RecommendationIndexClassificationParser {
    public static func parse(
        _ text: String,
        for batch: RecommendationIndexPreparedBatch
    ) -> Result<RecommendationIndexClassificationEnvelope, RecommendationIndexClassificationDiagnostics> {
        let rawLength = text.utf8.count
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.init(
                stage: .providerOutput,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: false,
                message: "模型返回空内容"
            ))
        }
        guard let json = extractJSONObject(from: text) else {
            return .failure(.init(
                stage: .jsonExtraction,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: false,
                message: "未找到完整 JSON 对象"
            ))
        }
        guard let data = json.data(using: .utf8) else {
            return .failure(.init(
                stage: .jsonExtraction,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "JSON 文本无法编码"
            ))
        }
        guard let parsedJSON = try? AIJSONValue(jsonData: data) else {
            return .failure(.init(
                stage: .jsonExtraction,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "JSON 语法无效"
            ))
        }
        // Only identity/coverage keys are fatal at the wire boundary. Missing
        // categorical/numeric/confidence values are handled by the v3 DTO's
        // safe defaults below.
        if let violation = requiredKeyViolation(in: parsedJSON) {
            return .failure(.init(
                stage: .codableDecode,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: violation.message,
                fieldPath: violation.fieldPath,
                expectedType: violation.expectedType,
                actualType: violation.actualType
            ))
        }
        let envelope: RecommendationIndexClassificationEnvelope
        do {
            envelope = try JSONDecoder().decode(RecommendationIndexClassificationEnvelope.self, from: data)
        } catch {
            let shape = decodingShape(error, in: parsedJSON)
            return .failure(.init(
                stage: .codableDecode,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: decodingMessage(error),
                fieldPath: shape.fieldPath,
                expectedType: shape.expectedType,
                actualType: shape.actualType
            ))
        }

        if envelope.batchID != batch.batchID {
            return .failure(.init(
                stage: .batchIdentity,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "batchID 不属于当前批次",
                expectedBatchID: batch.batchID,
                receivedBatchID: envelope.batchID,
                expectedRevision: batch.revision,
                receivedRevision: envelope.revision,
                fieldPath: "batchID",
                expectedType: "当前批次 UUID",
                actualType: envelope.batchID.uuidString
            ))
        }
        if envelope.revision != batch.revision {
            return .failure(.init(
                stage: .revision,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "revision 不属于当前批次",
                expectedBatchID: batch.batchID,
                receivedBatchID: envelope.batchID,
                expectedRevision: batch.revision,
                receivedRevision: envelope.revision,
                fieldPath: "revision",
                expectedType: "当前批次 revision",
                actualType: String(envelope.revision)
            ))
        }
        let actualIDs = envelope.items.map(\.id)
        let expectedIDs = batch.tracks.map(\.id)
        let duplicateIDs = Dictionary(grouping: actualIDs, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        let expectedSet = Set(expectedIDs)
        let actualSet = Set(actualIDs)
        let missingIDs = expectedSet.subtracting(actualSet).sorted()
        let extraIDs = actualSet.subtracting(expectedSet).sorted()
        if !duplicateIDs.isEmpty || actualIDs.count != expectedIDs.count || !missingIDs.isEmpty || !extraIDs.isEmpty {
            return .failure(.init(
                stage: .trackCoverage,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "items 没有恰好覆盖当前批次的每个 ID",
                missingIDs: missingIDs,
                extraIDs: extraIDs,
                duplicateIDs: duplicateIDs,
                fieldPath: "items",
                expectedType: "object[]（每个 prepared track ID 恰好一次）",
                actualType: "ids=\(actualIDs.count), missing=\(missingIDs.count), extra=\(extraIDs.count), duplicate=\(duplicateIDs.count)"
            ))
        }
        return .success(sanitizedEnvelope(envelope))
    }

    private struct RequiredKeyViolation {
        let fieldPath: String
        let expectedType: String
        let actualType: String
        let message: String
    }

    private static func requiredKeyViolation(
        in json: AIJSONValue
    ) -> RequiredKeyViolation? {
        guard case let .object(root) = json else {
            return .init(
                fieldPath: "root",
                expectedType: "object",
                actualType: typeName(json),
                message: "根输出必须是 object"
            )
        }

        for key in ["batchID", "revision", "items"] {
            guard let value = root[key], value != .null else {
                return .init(
                    fieldPath: key,
                    expectedType: "required",
                    actualType: "missing",
                    message: "缺少必填字段 \(key)"
                )
            }
        }
        guard case let .array(items) = root["items"] else {
            return .init(
                fieldPath: "items",
                expectedType: "array",
                actualType: root["items"].map(typeName) ?? "missing",
                message: "字段 items 必须是 array"
            )
        }
        for (index, item) in items.enumerated() {
            guard case let .object(fields) = item else {
                return .init(
                    fieldPath: "items[\(index)]",
                    expectedType: "object",
                    actualType: typeName(item),
                    message: "items[\(index)] 必须是 object"
                )
            }
            guard let id = fields["id"], id != .null else {
                return .init(
                    fieldPath: "items[\(index)].id",
                    expectedType: "required",
                    actualType: "missing",
                    message: "缺少必填字段 items[\(index)].id"
                )
            }
        }
        return nil
    }

    /// Canonicalize display names/aliases, reroute cross-dimension tags, and
    /// drop unknown values. Unknown extras are never batch-fatal because the
    /// fixed taxonomy is the only legal target space.
    private static func sanitizedEnvelope(
        _ envelope: RecommendationIndexClassificationEnvelope
    ) -> RecommendationIndexClassificationEnvelope {
        let items = envelope.items.map { item -> RecommendationIndexClassification in
            var moods: [String] = []
            var scenes: [String] = []
            var themes: [String] = []
            var genres: [String] = []
            var styles: [String] = []
            var vocals: [String] = []
            var instruments: [String] = []
            var textures: [String] = []
            var rhythms: [String] = []
            func route(_ raw: String, to expected: TagDimension) {
                guard let definition = RecommendationIndexTaxonomy.resolve(raw, expectedDimension: expected).definition else { return }
                switch definition.dimension {
                case .mood:
                    moods.append(definition.id.rawValue)
                case .scene:
                    scenes.append(definition.id.rawValue)
                case .theme:
                    themes.append(definition.id.rawValue)
                case .genre:
                    genres.append(definition.id.rawValue)
                case .style:
                    styles.append(definition.id.rawValue)
                case .vocal:
                    vocals.append(definition.id.rawValue)
                case .instrument:
                    instruments.append(definition.id.rawValue)
                case .texture:
                    textures.append(definition.id.rawValue)
                case .rhythm:
                    rhythms.append(definition.id.rawValue)
                }
            }
            item.moods.forEach { route($0, to: .mood) }
            item.scenes.forEach { route($0, to: .scene) }
            item.themes.forEach { route($0, to: .theme) }
            item.genres.forEach { route($0, to: .genre) }
            item.styles.forEach { route($0, to: .style) }
            item.vocals.forEach { route($0, to: .vocal) }
            item.instruments.forEach { route($0, to: .instrument) }
            item.textures.forEach { route($0, to: .texture) }
            item.rhythms.forEach { route($0, to: .rhythm) }
            let sortedMoods = Array(Set(moods)).sorted()
            let sortedScenes = Array(Set(scenes)).sorted()
            let sortedThemes = Array(Set(themes)).sorted()
            let sortedGenres = Array(Set(genres)).sorted()
            let sortedStyles = Array(Set(styles)).sorted()
            let sortedVocals = Array(Set(vocals)).sorted()
            let sortedInstruments = Array(Set(instruments)).sorted()
            let sortedTextures = Array(Set(textures)).sorted()
            let sortedRhythms = Array(Set(rhythms)).sorted()
            return RecommendationIndexClassification(
                id: item.id,
                moods: sortedMoods,
                scenes: sortedScenes,
                energy: normalizedNumeric(item.energy, upperBound: 10),
                tempo: normalizedNumeric(item.tempo, upperBound: 5),
                acousticness: normalizedNumeric(item.acousticness, upperBound: 5),
                danceability: normalizedNumeric(item.danceability, upperBound: 5),
                vocals: sortedVocals,
                textures: sortedTextures,
                styles: sortedStyles,
                confidence: item.confidence,
                themes: sortedThemes,
                genres: sortedGenres,
                instruments: sortedInstruments,
                rhythms: sortedRhythms,
                instrumentalness: normalizedNumeric(item.instrumentalness, upperBound: 5),
                liveness: normalizedNumeric(item.liveness, upperBound: 5),
                speechiness: normalizedNumeric(item.speechiness, upperBound: 5),
                valence: normalizedNumeric(item.valence, upperBound: 5),
                complexity: normalizedNumeric(item.complexity, upperBound: 5)
            )
        }
        return RecommendationIndexClassificationEnvelope(
            batchID: envelope.batchID,
            revision: envelope.revision,
            items: items
        )
    }

    /// Out-of-range numeric classifications are not identity or coverage
    /// failures. Drop only the unverifiable value; a valid item still carries
    /// its categorical classification through the same batch.
    private static func normalizedNumeric(_ value: Int?, upperBound: Int) -> Int? {
        guard let value, (1...upperBound).contains(value) else { return nil }
        return value
    }

    private static func extractJSONObject(from text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = source.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in source[start...].indices {
            let character = source[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[start...index])
                }
            }
        }
        return nil
    }

    private static func decodingMessage(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "缺少字段 \"\(codingPath(context.codingPath + [key]))\""
        case let DecodingError.typeMismatch(_, context): return "字段类型不匹配：\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.valueNotFound(_, context): return "字段为空：\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.dataCorrupted(context): return "字段数据损坏：\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: return "Codable 解码失败"
        }
    }

    private static func decodingShape(
        _ error: Error,
        in json: AIJSONValue
    ) -> (fieldPath: String?, expectedType: String?, actualType: String?) {
        guard case let DecodingError.typeMismatch(_, context) = error,
              !context.codingPath.isEmpty
        else { return (nil, nil, nil) }

        let path = codingPath(context.codingPath)
        let key = context.codingPath.last?.stringValue
        let expected = expectedType(forKey: key)
        return (path, expected, actualType(at: context.codingPath, in: json))
    }

    private static func expectedType(forKey key: String?) -> String? {
        switch key {
        case "moods", "scenes", "themes", "genres", "styles", "vocals",
             "instruments", "textures", "rhythms":
            return "string[]"
        case "items":
            return "object[]"
        case "energy", "tempo", "acousticness", "danceability", "instrumentalness",
             "liveness", "speechiness", "valence", "complexity", "revision":
            return "integer"
        case "confidence":
            return "number"
        case "id", "batchID":
            return "string"
        default:
            return nil
        }
    }

    private static func actualType(
        at path: [any CodingKey],
        in json: AIJSONValue
    ) -> String? {
        var value = json
        for key in path.dropLast() {
            switch (key.intValue, value) {
            case let (.some(index), .array(items)) where items.indices.contains(index):
                value = items[index]
            case let (.none, .object(fields)) where fields[key.stringValue] != nil:
                value = fields[key.stringValue]!
            default:
                return nil
            }
        }
        guard let last = path.last else { return nil }
        if last.intValue == nil, case let .object(fields) = value, let target = fields[last.stringValue] {
            return typeName(target)
        }
        return typeName(value)
    }

    private static func typeName(_ value: AIJSONValue) -> String {
        switch value {
        case .string: "string"
        case .number: "number"
        case .bool: "bool"
        case .array: "array"
        case .object: "object"
        case .null: "null"
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        path.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else if result.isEmpty {
                result = key.stringValue
            } else {
                result += ".\(key.stringValue)"
            }
        }
    }
}

/// Runtime-owned deterministic chain:
/// status -> prepare(batch + tag snapshot) -> closed model transform ->
/// validate identity/coverage -> ToolRuntime commit -> verify.
public enum RecommendationIndexSkillRuntime {
    public static let skillID = "recommendation-index"

    private struct ClassificationInput: Codable, Sendable {
        let batchID: UUID
        let revision: UInt64
        let tracks: [RecommendationIndexTrackEvidence]
    }

    private struct ClassificationRequestParts {
        let request: AICompletionRequest
        let budget: RecommendationIndexBatchPolicy.RequestBudget
    }

    private static let maximumEvidenceRecordsPerTrack = 4
    private static let maximumEvidenceTextCharacters = 720

    public static func outputSchema() -> AIJSONValue {
        // Strict structured-output dialects commonly require every declared
        // property to be required. Numeric values remain nullable so strict
        // providers return null, while tolerant decoding accepts omission.
        let itemRequired = #"["id", "moods", "scenes", "themes", "genres", "styles", "vocals", "instruments", "textures", "rhythms", "energy", "tempo", "acousticness", "danceability", "instrumentalness", "liveness", "speechiness", "valence", "complexity", "confidence"]"#
        let enumJSON: (TagDimension, Int) -> String = { dimension, maxItems in
            let ids = RecommendationIndexTaxonomy.ids(for: dimension).map(\.rawValue)
            let enumBody = ids.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"type":"array","maxItems":\#(maxItems),"items":{"type":"string","enum":[\#(enumBody)]}}"#
        }
        let numericJSON: (String, Int) -> String = { name, maximum in
            #""\#(name)":{"anyOf":[{"type":"integer","minimum":1,"maximum":\#(maximum)},{"type":"null"}]}"#
        }
        return try! AIJSONValue(jsonString: #"""
    {
      "type": "object",
      "additionalProperties": false,
        "properties": {
          "batchID": {"type": "string"},
          "revision": {"type": "integer", "minimum": 1},
          "items": {
          "type": "array",
          "minItems": 1,
          "maxItems": 100,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "id": {"type": "string"},
              "moods": \#(enumJSON(.mood, 5)),
              "scenes": \#(enumJSON(.scene, 6)),
              "themes": \#(enumJSON(.theme, 5)),
              "genres": \#(enumJSON(.genre, 3)),
              "styles": \#(enumJSON(.style, 5)),
              "vocals": \#(enumJSON(.vocal, 4)),
              "instruments": \#(enumJSON(.instrument, 8)),
              "textures": \#(enumJSON(.texture, 6)),
              "rhythms": \#(enumJSON(.rhythm, 4)),
              \#(numericJSON("energy", 10)),
              \#(numericJSON("tempo", 5)),
              \#(numericJSON("acousticness", 5)),
              \#(numericJSON("danceability", 5)),
              \#(numericJSON("instrumentalness", 5)),
              \#(numericJSON("liveness", 5)),
              \#(numericJSON("speechiness", 5)),
              \#(numericJSON("valence", 5)),
              \#(numericJSON("complexity", 5)),
              "confidence": {"type": "number", "minimum": 0, "maximum": 1}
            },
            "required": \#(itemRequired)
          }
        }
      },
      "required": ["batchID", "revision", "items"]
    }
    """#)
    }

    public static func shouldActivate(
        semantics: AgentRequestSemantics,
        userText: String,
        initialTaskState: AgentTaskState?,
        executionLineage: ExecutionLineage?
    ) -> Bool {
        if semantics.isRecommendationIndexBuild { return true }
        if RecommendationIndexTaskRules.requiresCompleteBuild(text: userText) { return true }
        if executionLineage?.activeSkillID == skillID { return true }
        guard let initialTaskState else { return false }
        return initialTaskState.intent == .libraryManagement
            && RecommendationIndexTaskRules.requiresCompleteBuild(text: initialTaskState.goal)
    }

    public static func validate(
        _ envelope: RecommendationIndexClassificationEnvelope,
        for batch: RecommendationIndexPreparedBatch
    ) throws {
        guard envelope.batchID == batch.batchID,
              envelope.revision == batch.revision else {
            throw RecommendationIndexValidationError.staleBatch
        }
        let ids = envelope.items.map(\.id)
        guard ids.count == Set(ids).count else {
            throw RecommendationIndexValidationError.duplicateIDs
        }
        let expected = batch.tracks.map(\.id)
        guard ids.count == expected.count, Set(ids) == Set(expected) else {
            throw RecommendationIndexValidationError.incompleteCoverage
        }
    }

    public static func run(
        userText: String,
        provider: any AIProvider,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        webService: (any AgentWebService)? = nil,
        allowsLyrics: Bool = false,
        availableToolDescriptors: [ToolDescriptor] = AgentToolRegistry.all,
        policy: AgentTaskPolicy,
        initialTaskState: AgentTaskState?,
        authorizationContext: SideEffectAuthorizationContext,
        lineageID: UUID,
        executionLease: ToolExecutionLease,
        requestTimeout: TimeInterval,
        resourceLeaseRegistry: MutationResourceLeaseRegistry,
        executionStateRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry(),
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void,
        progress: @escaping @Sendable (ToolLoop.AgentProgress) async -> Void,
        state: @escaping @Sendable (AgentTaskState) async -> Void,
        observe: @escaping @Sendable (RecommendationIndexExecutionEvent) async -> Void = { _ in },
        providerName: String? = nil,
        modelName: String? = nil
    ) async {
        var taskState = initialTaskState ?? AgentTaskState(intent: .libraryManagement, goal: userText)
        let restored = decodeCheckpoint(taskState.facts["recommendation.index.checkpoint"])
        let generation = (restored?.checkpointGeneration ?? 0) &+ 1
        var revision = restored?.currentBatchRevision ?? 0
        var preferredBatchSize = RecommendationIndexBatchPolicy.recommendedLimit(
            maxOutputTokens: provider.capabilities.maxOutputTokens
        )
        if let restored {
            preferredBatchSize = min(preferredBatchSize, max(1, restored.preferredBatchSize))
        }
        var totalWrittenThisRun = 0
        var latestStatus: RecommendationIndexStatus?
        let authority = ToolExecutionAuthority(
            skillID: skillID,
            lineageID: lineageID,
            generation: generation
        )
        let runID = executionLease.runID
        let sessionID = executionLease.sessionID
        var classificationAttempt = 0
        var transientClassificationRetries = 0
        var noProgressCommitCount = 0

        func emitObservation(
            _ kind: RecommendationIndexExecutionEvent.Kind,
            phase: RecommendationIndexWorkflow.State,
            batch: RecommendationIndexPreparedBatch? = nil,
            attempt: Int = classificationAttempt,
            durationSince: Date? = nil,
            requestPayloadBytes: Int? = nil,
            outputBytes: Int? = nil,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            message: String? = nil
        ) async {
            await observe(RecommendationIndexExecutionEvent(
                kind: kind,
                runID: runID,
                sessionID: sessionID,
                serverID: serverID,
                phase: phase,
                batchID: batch?.batchID,
                batchRevision: batch?.revision,
                batchSize: batch?.tracks.count ?? 0,
                attempt: attempt,
                totalTracks: latestStatus?.totalTracks,
                indexedTracks: latestStatus?.indexedTracks,
                pendingTracks: latestStatus?.pendingTracks,
                durationMilliseconds: durationSince.map { max(0, Int(Date().timeIntervalSince($0) * 1_000)) },
                requestPayloadBytes: requestPayloadBytes,
                outputBytes: outputBytes,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                provider: providerName,
                model: modelName,
                message: message
            ))
        }

        guard await executionStateRegistry.begin(
            serverID: serverID,
            runID: runID,
            sessionID: sessionID
        ) else {
            let message = "推荐索引启动失败（stage=readingStatus）：已在另一个运行中；当前没有启动新的索引任务。"
            await emitObservation(.failed, phase: .readingStatus, message: message)
            taskState.status = .failed
            taskState.completionState = .failed
            taskState.errorState = message
            taskState.errors.append(message)
            taskState.pendingActions = []
            await state(taskState)
            await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
            return
        }
        var executionStateFinished = false
        defer {
            if !executionStateFinished {
                Task {
                    await executionStateRegistry.stop(serverID: serverID, runID: runID)
                }
            }
        }

        func phaseDetail(
            _ phase: RecommendationIndexWorkflow.State,
            status: RecommendationIndexStatus?,
            currentBatch: RecommendationIndexPreparedBatch?
        ) -> String {
            switch phase {
            case .readingStatus:
                return "正在读取推荐索引状态"
            case .fetchingBatch:
                return "正在准备推荐索引批次"
            case .loadingCanonicalTags:
                return "推荐索引：正在检查已有标签"
            case .gatheringEvidence:
                if let currentBatch {
                    return "推荐索引：正在补充歌曲证据（\(currentBatch.tracks.count) 首）"
                }
                return "推荐索引：正在补充歌曲证据"
            case .classifyingBatch:
                if let status, let currentBatch {
                    return "推荐索引：已完成 \(status.indexedTracks) / \(status.totalTracks)，正在分类当前批次 \(currentBatch.tracks.count) 首"
                }
                return "正在分类推荐索引批次"
            case .retrying:
                return "推荐索引正在重试当前批次…"
            case .writingBatch:
                return "正在保存推荐索引分类"
            case .verifying:
                return "正在核验推荐索引写入结果"
            case .completed:
                if let status {
                    return "推荐索引已完成 \(status.indexedTracks) / \(status.totalTracks)"
                }
                return "推荐索引已完成"
            }
        }

        func publish(
            phase: RecommendationIndexWorkflow.State,
            currentBatch: RecommendationIndexPreparedBatch? = nil,
            stoppedReason: String? = nil,
            terminal: Bool = false,
            attempt: Int = classificationAttempt
        ) async {
            if let status = latestStatus {
                taskState.facts["recommendation.index.total"] = "\(status.totalTracks)"
                taskState.facts["recommendation.index.indexed"] = "\(status.indexedTracks)"
                taskState.facts["recommendation.index.pending"] = "\(status.pendingTracks)"
            }
            taskState.facts["recommendation.index.skillID"] = skillID
            taskState.facts["recommendation.index.currentBatchIDs"] = currentBatch?.tracks.map(\.id).joined(separator: ",") ?? ""
            let checkpoint = RecommendationIndexCheckpoint(
                checkpointGeneration: generation,
                currentBatchID: currentBatch?.batchID,
                currentBatchRevision: currentBatch?.revision ?? revision,
                total: latestStatus?.totalTracks ?? restored?.total ?? 0,
                indexed: latestStatus?.indexedTracks ?? restored?.indexed ?? 0,
                pending: latestStatus?.pendingTracks ?? restored?.pending ?? 0,
                totalWrittenThisRun: totalWrittenThisRun,
                lastSuccessfulBatchCount: taskState.completedActions.last.flatMap(Self.trailingCount) ?? 0,
                currentBatchIDs: currentBatch?.tracks.map(\.id) ?? [],
                preferredBatchSize: preferredBatchSize,
                status: phase,
                stoppedReason: stoppedReason,
                updatedAt: .now
            )
            if let data = try? JSONEncoder().encode(checkpoint) {
                taskState.facts["recommendation.index.checkpoint"] = String(decoding: data, as: UTF8.self)
            }
            taskState.updatedAt = .now
            let detail = phaseDetail(phase, status: latestStatus, currentBatch: currentBatch)
            if phase == .completed, let status = latestStatus {
                await executionStateRegistry.complete(
                    serverID: serverID,
                    runID: runID,
                    totalTracks: status.totalTracks,
                    indexedTracks: status.indexedTracks
                )
                executionStateFinished = true
            } else if terminal, let stoppedReason {
                if stoppedReason == "运行已取消" || stoppedReason.contains("运行已失效") {
                    await executionStateRegistry.stop(serverID: serverID, runID: runID)
                } else {
                    await executionStateRegistry.fail(serverID: serverID, runID: runID, message: stoppedReason)
                }
                executionStateFinished = true
            } else {
                await executionStateRegistry.update(
                    serverID: serverID,
                    runID: runID,
                    sessionID: sessionID,
                    phase: phase,
                    batchID: currentBatch?.batchID,
                    batchRevision: currentBatch?.revision,
                    batchTrackIDs: currentBatch?.tracks.map(\.id) ?? [],
                    attempt: attempt,
                    totalTracks: latestStatus?.totalTracks ?? 0,
                    indexedTracks: latestStatus?.indexedTracks ?? 0,
                    pendingTracks: latestStatus?.pendingTracks ?? 0,
                    currentBatchSize: currentBatch?.tracks.count ?? 0,
                    processedThisRun: totalWrittenThisRun,
                    message: stoppedReason ?? detail
                )
            }
            let eventKind: RecommendationIndexExecutionEvent.Kind
            if phase == .completed {
                eventKind = .completed
            } else if stoppedReason == "运行已取消" || stoppedReason?.contains("运行已失效") == true {
                eventKind = .cancelled
            } else if phase == .retrying {
                eventKind = .retrying
            } else if terminal {
                eventKind = .failed
            } else {
                eventKind = .phaseChanged
            }
            await emitObservation(
                eventKind,
                phase: phase,
                batch: currentBatch,
                attempt: attempt,
                message: stoppedReason ?? detail
            )
            await state(taskState)
            await progress(ToolLoop.AgentProgress(
                toolSteps: taskState.progress.toolCalls,
                currentStep: detail,
                inputTokens: taskState.progress.inputTokens,
                outputTokens: taskState.progress.outputTokens,
                activity: .workflow(
                    skillID: skillID,
                    phase: phase.rawValue,
                    detail: detail
                )
            ))
        }

        // Keep failure-state mutation in the same local scope as `publish`.
        // Passing `&taskState` to a helper while that helper also invokes the
        // closure which captures `taskState` creates an async exclusivity
        // overlap on the Provider-error path.
        func recordDiagnostic(_ diagnostic: RecommendationIndexClassificationDiagnostics) async {
            if let data = try? JSONEncoder().encode(diagnostic) {
                taskState.facts["recommendation.index.diagnostics"] = String(decoding: data, as: UTF8.self)
            }
            await log(AgentActionRecord(
                toolName: "recommendation_index_diagnostics",
                permission: .readOnly,
                summary: diagnostic.compactSummary
            ))
        }

        func fail(
            _ message: String,
            phase: RecommendationIndexWorkflow.State,
            currentBatch: RecommendationIndexPreparedBatch? = nil,
            attempt: Int = classificationAttempt,
            diagnostic: RecommendationIndexClassificationDiagnostics? = nil
        ) async {
            // Every terminal Runtime failure must retain the deterministic
            // stage in the user-visible task/error path. Classification
            // diagnostics carry the stricter providerOutput/json/identity/
            // coverage/commit/verify/noProgress stage; status and batch
            // preparation use their workflow phase as the stage.
            let qualifiedMessage = message.contains("stage=")
                ? message
                : "\(message)（stage=\(diagnostic?.stage.rawValue ?? phase.rawValue)）"
            taskState.status = .failed
            taskState.completionState = .failed
            taskState.errorState = qualifiedMessage
            taskState.errors.append(qualifiedMessage)
            taskState.pendingActions = []
            if let diagnostic {
                await recordDiagnostic(diagnostic)
            }
            await publish(
                phase: phase,
                currentBatch: currentBatch,
                stoppedReason: qualifiedMessage,
                terminal: true,
                attempt: attempt
            )
            await emit(AgentChatMessage(role: .assistant, messages: [.error(qualifiedMessage)]))
        }

        taskState.status = .running
        taskState.pendingActions = ["正在读取推荐索引状态"]
        await emitObservation(.started, phase: .readingStatus, message: skillID)
        await publish(phase: .readingStatus)

        while true {
            let leaseValid = await executionLease.isValid()
            if Task.isCancelled || !leaseValid {
                taskState.status = .cancelled
                taskState.pendingActions = []
                await publish(phase: .readingStatus, stoppedReason: "运行已取消", terminal: true)
                return
            }
            if let violation = taskState.budgetViolation(policy: policy) {
                await fail(
                    violation.localizedDescription,
                    phase: .readingStatus
                )
                return
            }

            do {
                latestStatus = try await catalog.recommendationIndexStatus(serverID: serverID)
            } catch {
                await fail(
                    "无法读取推荐索引状态：\(error.localizedDescription)",
                    phase: .readingStatus
                )
                return
            }
            guard let status = latestStatus else {
                let message = "无法读取推荐索引状态（stage=readingStatus）：目录尚未提供当前服务器的索引状态。"
                taskState.status = .failed
                taskState.completionState = .failed
                taskState.errorState = message
                taskState.errors.append(message)
                taskState.pendingActions = []
                await publish(
                    phase: .readingStatus,
                    stoppedReason: message,
                    terminal: true
                )
                await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
                return
            }
            await emitObservation(
                .statusLoaded,
                phase: .readingStatus,
                message: "pending=\(status.pendingUniqueTracks)"
            )
            if status.pendingUniqueTracks == 0 {
                taskState.status = .completed
                taskState.completed = true
                taskState.completionState = .satisfied
                taskState.pendingActions = []
                taskState.errorState = nil
                taskState.recordProgress(action: "推荐索引已完成")
                await publish(phase: .completed)
                await progress(ToolLoop.AgentProgress(
                    toolSteps: taskState.progress.toolCalls,
                    currentStep: "推荐索引已完成 \(status.indexedTracks) / \(status.totalTracks)",
                    inputTokens: taskState.progress.inputTokens,
                    outputTokens: taskState.progress.outputTokens
                ))
                await emit(AgentChatMessage(
                    role: .assistant,
                    messages: [.text("推荐索引已完成，共处理 \(status.indexedTracks) / \(status.totalTracks) 首歌曲。")]
                ))
                return
            }

            let prepared: RecommendationIndexPreparedBatch
            do {
                prepared = try await prepareBatch(
                    catalog: catalog,
                    serverID: serverID,
                    limit: preferredBatchSize,
                    generation: generation,
                    provider: provider,
                    model: model,
                    revision: &revision
                )
            } catch let diagnostic as RecommendationIndexClassificationDiagnostics {
                await fail(
                    "无法准备推荐索引批次：\(diagnostic.message)",
                    phase: .fetchingBatch,
                    diagnostic: diagnostic
                )
                return
            } catch {
                await fail(
                    "无法准备推荐索引批次：\(error.localizedDescription)",
                    phase: .fetchingBatch
                )
                return
            }
            if prepared.tracks.isEmpty {
                // Status and next-batch are separate snapshots. Re-read the
                // authoritative status instead of letting the model infer
                // completion from an empty payload.
                taskState.pendingActions = ["正在核验推荐索引状态"]
                await publish(phase: .verifying)
                continue
            }

            await emitObservation(
                .batchPrepared,
                phase: .fetchingBatch,
                batch: prepared,
                message: "fixed_taxonomy_v3"
            )

            taskState.status = .waitingForModel
            taskState.pendingActions = ["推荐索引：正在补充歌曲证据"]
            await publish(phase: .gatheringEvidence, currentBatch: prepared)
            await emitObservation(.evidenceStarted, phase: .gatheringEvidence, batch: prepared)
            let evidence = await gatherEvidence(
                userText: userText,
                provider: provider,
                model: model,
                batch: prepared,
                bridge: bridge,
                catalog: catalog,
                serverID: serverID,
                systemService: systemService,
                externalMusicService: externalMusicService,
                webService: webService,
                allowsLyrics: allowsLyrics,
                availableToolDescriptors: availableToolDescriptors,
                executionLease: executionLease,
                resourceLeaseRegistry: resourceLeaseRegistry,
                executionStateRegistry: executionStateRegistry,
                observe: observe,
                providerName: providerName,
                modelName: modelName,
                runID: runID,
                sessionID: sessionID
            )
            await emitObservation(
                .evidenceCompleted,
                phase: .gatheringEvidence,
                batch: prepared,
                message: "records=\(evidence.reduce(0) { $0 + $1.evidence.count })"
            )

            taskState.status = .waitingForModel
            taskState.pendingActions = ["推荐索引：已完成 \(status.indexedTracks) / \(status.totalTracks)，正在分类当前批次 \(prepared.tracks.count) 首"]
            await publish(phase: .classifyingBatch, currentBatch: prepared)
            await progress(ToolLoop.AgentProgress(
                toolSteps: taskState.progress.toolCalls,
                currentStep: taskState.pendingActions[0],
                inputTokens: taskState.progress.inputTokens,
                outputTokens: taskState.progress.outputTokens
            ))

            let envelope: RecommendationIndexClassificationEnvelope
            var classificationDiagnostics: RecommendationIndexClassificationDiagnostics?
            classificationAttempt += 1
            let classificationStartedAt = Date()
            await emitObservation(.canonicalTagsLoadStarted, phase: .loadingCanonicalTags, batch: prepared)
            await emitObservation(
                .classificationStarted,
                phase: .classifyingBatch,
                batch: prepared,
                attempt: classificationAttempt
            )
            var contractRepairAttempt = 0
            var repairDiagnostic: RecommendationIndexClassificationDiagnostics?
            do {
                while true {
                // A repair attempt gets a fresh diagnostic scope. If the
                // Provider fails after the repair prompt, the error path must
                // describe that new failure instead of the previous shape.
                classificationDiagnostics = nil
                let request = try await classificationRequest(
                    provider: provider,
                    model: model,
                    batch: prepared,
                    evidence: evidence,
                    repairDiagnostic: repairDiagnostic
                )
                await emitObservation(.canonicalTagsLoadCompleted, phase: .loadingCanonicalTags, batch: prepared)
                // Hard invariant: this model turn is a closed transform.
                precondition(request.tools?.isEmpty == true)
                precondition(request.hostedTools?.isEmpty == true)
                precondition(request.toolChoice == nil)
                await emitObservation(
                    .providerRequestStarted,
                    phase: .classifyingBatch,
                    batch: prepared,
                    attempt: classificationAttempt,
                    requestPayloadBytes: Self.requestPayloadBytes(request),
                    message: "output=\(Self.outputFormatName(request.outputFormat))"
                )
                let response = try await complete(provider, request: request, timeout: requestTimeout)
                await emitObservation(
                    .providerRequestCompleted,
                    phase: .classifyingBatch,
                    batch: prepared,
                    attempt: classificationAttempt,
                    outputBytes: response.content.utf8.count,
                    inputTokens: response.inputTokens,
                    outputTokens: response.outputTokens
                )
                taskState.progress.modelRounds += 1
                taskState.progress.inputTokens += response.inputTokens ?? 0
                taskState.progress.outputTokens += response.outputTokens ?? 0
                guard response.toolCalls?.isEmpty != false else {
                    let diagnostic = RecommendationIndexClassificationDiagnostics(
                        stage: .providerOutput,
                        batchSize: prepared.tracks.count,
                        rawLength: response.content.utf8.count,
                        jsonFound: false,
                        message: "封闭分类阶段返回了工具调用"
                    )
                    classificationDiagnostics = diagnostic
                    throw diagnostic
                }
                switch RecommendationIndexClassificationParser.parse(response.content, for: prepared) {
                case let .success(decoded):
                    envelope = decoded
                    repairDiagnostic = nil
                    transientClassificationRetries = 0
                    await emitObservation(
                        .classificationCompleted,
                        phase: .classifyingBatch,
                        batch: prepared,
                        attempt: classificationAttempt,
                        durationSince: classificationStartedAt
                    )
                case let .failure(diagnostic):
                    classificationDiagnostics = diagnostic

                    // Contract repairs always replay against the exact prepared
                    // identity; a fresh batch would hide the mismatch instead of
                    // repairing the model's echo.
                    if case .retrySameBatch = Self.disposition(for: diagnostic),
                       contractRepairAttempt < 1 {
                        contractRepairAttempt += 1
                        repairDiagnostic = diagnostic
                        await recordDiagnostic(diagnostic)
                        await publish(
                            phase: .retrying,
                            currentBatch: prepared,
                            stoppedReason: "分类契约校验失败，正在使用同一批次重试",
                            terminal: false,
                            attempt: classificationAttempt
                        )
                        continue
                    }
                    throw diagnostic
                }
                break
                }
            } catch is CancellationError {
                taskState.status = .cancelled
                taskState.pendingActions = []
                await publish(phase: .classifyingBatch, currentBatch: prepared, stoppedReason: "运行已取消", terminal: true)
                return
            } catch {
                let failureDiagnostic = classificationDiagnostics
                    ?? (error as? RecommendationIndexClassificationDiagnostics)
                    ?? RecommendationIndexClassificationDiagnostics(
                        stage: .providerOutput,
                        batchSize: prepared.tracks.count,
                        rawLength: 0,
                        jsonFound: false,
                        message: "AI Provider 请求失败：\(error.localizedDescription)",
                        expectedBatchID: prepared.batchID,
                        expectedRevision: prepared.revision,
                        pendingBefore: status.pendingUniqueTracks
                    )
                if failureDiagnostic.stage != .contextBudget {
                    await emitObservation(
                        .providerRequestFailed,
                        phase: .classifyingBatch,
                        batch: prepared,
                        attempt: classificationAttempt,
                        durationSince: classificationStartedAt,
                        message: error.localizedDescription
                    )
                }
                await emitObservation(
                    .classificationFailed,
                    phase: .classifyingBatch,
                    batch: prepared,
                    attempt: classificationAttempt,
                    durationSince: classificationStartedAt,
                    message: failureDiagnostic.compactSummary
                )
                if isTransientClassificationFailure(error), transientClassificationRetries < 2 {
                    transientClassificationRetries += 1
                    taskState.status = .waitingForModel
                    taskState.pendingActions = ["推荐索引正在重试模型请求…"]
                    let retryMessage = "分类请求暂时失败（stage=\(failureDiagnostic.stage.rawValue)），正在重试（第 \(transientClassificationRetries) 次）"
                    await publish(
                        phase: .retrying,
                        currentBatch: prepared,
                        stoppedReason: retryMessage,
                        terminal: false,
                        attempt: classificationAttempt
                    )
                    do {
                        let delay = UInt64(800 * (1 << (transientClassificationRetries - 1))) * 1_000_000
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        taskState.status = .cancelled
                        taskState.pendingActions = []
                        await publish(
                            phase: .classifyingBatch,
                            currentBatch: prepared,
                            stoppedReason: "运行已取消",
                            terminal: true,
                            attempt: classificationAttempt
                        )
                        return
                    }
                    // A transport retry may replay the request, but it does not
                    // discard the still-unwritten prepared batch identity.
                    continue
                }
                switch Self.disposition(for: error) {
                case .shrinkBatch:
                    if prepared.tracks.count <= RecommendationIndexBatchPolicy.minimumTracksPerBatch {
                        let failureMessage = "推荐索引当前批次即使缩小到 1 首仍无法通过结构化校验；未写入该批次。（\(failureDiagnostic.compactSummary)）"
                        await fail(
                            failureMessage,
                            phase: .classifyingBatch,
                            currentBatch: prepared,
                            attempt: classificationAttempt,
                            diagnostic: failureDiagnostic
                        )
                        return
                    }
                    preferredBatchSize = RecommendationIndexBatchPolicy.reducedLimit(from: prepared.tracks.count)
                    taskState.status = .waitingForModel
                    taskState.pendingActions = ["推荐索引正在重试当前批次…"]
                    if let data = try? JSONEncoder().encode(failureDiagnostic) {
                        taskState.facts["recommendation.index.classification.failure"] = String(decoding: data, as: UTF8.self)
                    }
                    await log(AgentActionRecord(
                        toolName: "recommendation_index_classification",
                        permission: .readOnly,
                        summary: failureDiagnostic.compactSummary
                    ))
                    let retryReason = failureDiagnostic.stage == .contextBudget
                        ? "分类请求超过上下文预算"
                        : "分类输出校验失败"
                    // Never persist the old batch as writable after a failed
                    // transform. The next prepare creates a new ID/revision.
                    await publish(
                        phase: .retrying,
                        stoppedReason: "\(retryReason)（\(failureDiagnostic.stage.rawValue)），正在缩小批次重试",
                        terminal: false,
                        attempt: classificationAttempt
                    )
                    await progress(ToolLoop.AgentProgress(
                        toolSteps: taskState.progress.toolCalls,
                        currentStep: "推荐索引正在重试当前批次…",
                        inputTokens: taskState.progress.inputTokens,
                        outputTokens: taskState.progress.outputTokens
                    ))
                    await publish(
                        phase: .fetchingBatch,
                        stoppedReason: "重新准备当前批次",
                        terminal: false,
                        attempt: classificationAttempt
                    )
                    continue
                case .retrySameBatch, .fail:
                    let message: String
                    if contractRepairAttempt > 0 {
                        message = "推荐索引当前输出无法解析；同一批次契约修复后仍失败，未写入该批次。"
                    } else if failureDiagnostic.stage == .codableDecode {
                        message = "推荐索引当前输出无法解析，未写入该批次。"
                    } else {
                        message = "推荐索引分类请求失败，未写入该批次。"
                    }
                    await fail(
                        "\(message)（\(failureDiagnostic.compactSummary)）",
                        phase: .classifyingBatch,
                        currentBatch: prepared,
                        attempt: classificationAttempt,
                        diagnostic: failureDiagnostic
                    )
                    return
                }
            }

            let leaseStillValid = await executionLease.isValid()
            if Task.isCancelled || !leaseStillValid {
                taskState.status = .cancelled
                taskState.pendingActions = []
                await publish(phase: .writingBatch, currentBatch: prepared, stoppedReason: "写入前运行已失效", terminal: true)
                return
            }

            let arguments: AIJSONValue
            do {
                arguments = try AIJSONValue(jsonData: JSONEncoder().encode(envelope.items))
            } catch {
                // This can only indicate an internal encoding defect; it must
                // never reach the catalog as a partial write.
                let diagnostic = RecommendationIndexClassificationDiagnostics(
                    stage: .commit,
                    batchSize: prepared.tracks.count,
                    rawLength: 0,
                    jsonFound: true,
                    message: "分类结果编码失败：\(error.localizedDescription)",
                    expectedBatchID: prepared.batchID,
                    expectedRevision: prepared.revision,
                    pendingBefore: status.pendingUniqueTracks
                )
                await fail(
                    "推荐索引分类结果无法编码，未写入任何数据。",
                    phase: .writingBatch,
                    currentBatch: prepared,
                    attempt: classificationAttempt,
                    diagnostic: diagnostic
                )
                return
            }
            let commitCall = ToolCall(name: "recommendation_index_commit", arguments: [
                "batchID": .string(prepared.batchID.uuidString),
                "revision": .number(Double(prepared.revision)),
                "items": arguments,
            ])
            taskState.status = .waitingForTool
            taskState.pendingActions = ["正在保存推荐索引分类"]
            await publish(phase: .writingBatch, currentBatch: prepared, attempt: classificationAttempt)
            let commitStartedAt = Date()
            await emitObservation(
                .commitStarted,
                phase: .writingBatch,
                batch: prepared,
                attempt: classificationAttempt
            )
            let result = await ToolRuntime.execute(
                commitCall,
                bridge: bridge,
                catalog: catalog,
                serverID: serverID,
                systemService: nil,
                providerCapabilities: provider.capabilities,
                authorizationContext: authorizationContext,
                activeSkillID: skillID,
                executionAuthority: authority,
                executionLease: executionLease,
                resourceLeaseRegistry: resourceLeaseRegistry,
                recommendationIndexExecutionRegistry: executionStateRegistry
            )
            taskState.progress.toolCalls += 1
            guard result.success else {
                let diagnostic = RecommendationIndexClassificationDiagnostics(
                    stage: .commit,
                    batchSize: prepared.tracks.count,
                    rawLength: 0,
                    jsonFound: true,
                    message: result.summary,
                    expectedBatchID: prepared.batchID,
                    expectedRevision: prepared.revision,
                    pendingBefore: status.pendingUniqueTracks
                )
                await fail(
                    "推荐索引写入失败：\(result.summary)",
                    phase: .writingBatch,
                    currentBatch: prepared,
                    attempt: classificationAttempt,
                    diagnostic: diagnostic
                )
                return
            }
            await emitObservation(
                .commitCompleted,
                phase: .writingBatch,
                batch: prepared,
                attempt: classificationAttempt,
                durationSince: commitStartedAt,
                message: result.summary
            )
            totalWrittenThisRun += prepared.tracks.count
            taskState.successfulToolNames.append(commitCall.name)
            taskState.successfulToolCount += 1
            taskState.pendingActions = ["正在核验推荐索引写入结果"]
            taskState.recordProgress(action: "推荐索引写入 \(prepared.tracks.count) 首")
            await log(AgentActionRecord(
                toolName: commitCall.name,
                permission: .reversible,
                summary: result.summary
            ))
            await emitObservation(
                .verifyStarted,
                phase: .verifying,
                batch: prepared,
                attempt: classificationAttempt,
                message: "重新读取提交后的真实 pending 数量"
            )
            let verifiedStatus: RecommendationIndexStatus
            do {
                verifiedStatus = try await catalog.recommendationIndexStatus(serverID: serverID)
            } catch {
                let diagnostic = RecommendationIndexClassificationDiagnostics(
                    stage: .verify,
                    batchSize: prepared.tracks.count,
                    rawLength: 0,
                    jsonFound: true,
                    message: error.localizedDescription,
                    expectedBatchID: prepared.batchID,
                    expectedRevision: prepared.revision,
                    pendingBefore: status.pendingUniqueTracks
                )
                await fail(
                    "推荐索引写入后无法核验真实状态：\(error.localizedDescription)",
                    phase: .verifying,
                    currentBatch: prepared,
                    attempt: classificationAttempt,
                    diagnostic: diagnostic
                )
                return
            }
            latestStatus = verifiedStatus
            let pendingDelta = status.pendingUniqueTracks - verifiedStatus.pendingUniqueTracks
            await emitObservation(
                .verifyCompleted,
                phase: .verifying,
                batch: prepared,
                attempt: classificationAttempt,
                message: "pending_before=\(status.pendingUniqueTracks), pending_after=\(verifiedStatus.pendingUniqueTracks), pending_delta=\(pendingDelta)"
            )
            if pendingDelta <= 0 {
                noProgressCommitCount += 1
                let diagnostic = RecommendationIndexClassificationDiagnostics(
                    stage: .noProgress,
                    batchSize: prepared.tracks.count,
                    rawLength: 0,
                    jsonFound: true,
                    message: "提交成功但待处理数量没有下降（连续 \(noProgressCommitCount) 次）",
                    expectedBatchID: prepared.batchID,
                    expectedRevision: prepared.revision,
                    pendingBefore: status.pendingUniqueTracks,
                    pendingAfter: verifiedStatus.pendingUniqueTracks,
                    pendingDelta: pendingDelta
                )
                await emitObservation(
                    .noProgress,
                    phase: .verifying,
                    batch: prepared,
                    attempt: classificationAttempt,
                    message: diagnostic.compactSummary
                )
                if noProgressCommitCount >= 2 {
                    await fail(
                        "推荐索引连续两次提交后待处理数量没有下降，已停止以避免重复提交。（\(diagnostic.compactSummary)）",
                        phase: .verifying,
                        currentBatch: prepared,
                        attempt: classificationAttempt,
                        diagnostic: diagnostic
                    )
                    return
                }
                await recordDiagnostic(diagnostic)
            } else {
                noProgressCommitCount = 0
            }
            await publish(phase: .verifying)
        }
    }

    private enum RecommendationIndexRuntimeError: Error, LocalizedError {
        case malformedClassification
        case emptyBatch

        var errorDescription: String? {
            switch self {
            case .malformedClassification: "模型未返回完整分类对象"
            case .emptyBatch: "当前索引批次为空"
            }
        }
    }

    private static func prepareBatch(
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        limit: Int,
        generation: UInt64,
        provider: any AIProvider,
        model: String,
        revision: inout UInt64
    ) async throws -> RecommendationIndexPreparedBatch {
        let batch = try await catalog.nextRecommendationIndexBatch(serverID: serverID, limit: limit)
        revision &+= 1
        let batchID = UUID()
        let tracks = try fitBatchToRequestBudget(
            batch.tracks,
            batchID: batchID,
            revision: revision,
            provider: provider,
            model: model
        )
        return RecommendationIndexPreparedBatch(
            batchID: batchID,
            revision: revision,
            checkpointGeneration: generation,
            tracks: tracks,
            pendingFixed: batch.pendingFixedTracks
        )
    }

    /// Internal evidence loop for one prepared batch.  It may execute only
    /// model-visible read-only descriptors.  The following classification
    /// request remains a separate, tool-free deterministic transform.
    private static func gatherEvidence(
        userText: String,
        provider: any AIProvider,
        model: String,
        batch: RecommendationIndexPreparedBatch,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)?,
        webService: (any AgentWebService)?,
        allowsLyrics: Bool,
        availableToolDescriptors: [ToolDescriptor],
        executionLease: ToolExecutionLease,
        resourceLeaseRegistry: MutationResourceLeaseRegistry,
        executionStateRegistry: RecommendationIndexExecutionRegistry,
        observe: @escaping @Sendable (RecommendationIndexExecutionEvent) async -> Void,
        providerName: String?,
        modelName: String?,
        runID: UUID,
        sessionID: UUID
    ) async -> [RecommendationIndexTrackEvidence] {
        let environment = AgentCapabilityEnvironment(
            providerAvailable: true,
            activeServer: (await bridge.getActiveServer()) != nil,
            webSearchAvailable: webService != nil || provider.capabilities.supportsHostedWebSearch,
            webFetchAvailable: webService != nil || provider.capabilities.supportsHostedWebFetch,
            downloadServiceAvailable: systemService != nil,
            systemServiceAvailable: systemService != nil
        )
        let allReadOnly = availableToolDescriptors.filter {
            $0.visibility == .model && $0.permission == .readOnly
        }
        var selected = ToolSelector.select(for: userText, all: availableToolDescriptors)
            .filter { $0.visibility == .model && $0.permission == .readOnly }
        if let search = allReadOnly.first(where: { $0.name == "tool_search" }),
           !selected.contains(where: { $0.name == search.name }) {
            selected.append(search)
        }
        let nativeMode = provider.supportsToolCalling
            && provider.capabilities.toolMode != .none
            && provider.capabilities.toolMode != .textualToolProtocol
        guard nativeMode else {
            // Textual ACTION providers cannot participate in the native
            // evidence loop. Skipping avoids a guaranteed zero-tool request
            // that costs one model round per batch without adding evidence.
            return batch.tracks.map { .init(track: $0, evidence: []) }
        }
        let hasTrackAttributableTool = allReadOnly.contains { descriptor in
            descriptor.name != "tool_search"
                && descriptor.parameters.contains { $0.name == "trackID" || $0.name == "id" }
        }
        guard hasTrackAttributableTool else {
            return batch.tracks.map { .init(track: $0, evidence: []) }
        }
        var conversation: [AIMessage] = [
            .init(
                role: .system,
                content: "你是 Recommendation Index 的内部证据阶段。只可调用只读 Auralis 工具；不要输出分类 JSON，不要写入、修改播放、歌单、收藏、评分、服务器、下载或记忆。\n\n\(ToolCatalog(descriptors: availableToolDescriptors).awarenessEntries(environment: environment).map(\.renderedLine).joined(separator: "\\n"))\n\n\(ToolCompositionExamples.promptSection(examples: ToolCompositionExamples.readOnlyExamples))\n\n当前直接可调用的 schema 是 Runtime 已加载的只读工具；可用 tool_search 发现其它只读工具。若批次元数据已经足够或证据已补齐，直接停止调用工具。"
            ),
            .init(role: .user, content: "为以下批次决定是否需要只读补证；不需要时不要调用工具。\n\(String(decoding: (try? JSONEncoder().encode(batch.tracks)) ?? Data(), as: UTF8.self))"),
        ]
        var records: [String: [RecommendationIndexEvidenceRecord]] = [:]
        var seenCalls = Set<String>()
        var discovered = Set<String>()
        var totalCalls = 0
        for round in 0..<3 {
            let definitions = nativeMode
                ? ToolSelector.toolDefinitions(from: selected, strict: provider.capabilities.supportsStrictSchema)
                : []
            let request = AICompletionRequest(
                model: model,
                transcript: AITranscript(messages: conversation),
                temperature: 0,
                maxTokens: min(provider.capabilities.maxOutputTokens, 1_024),
                tools: nativeMode ? definitions : nil,
                toolChoice: nil,
                hostedTools: nil
            )
            await observe(.init(
                kind: .providerRequestStarted, runID: runID, sessionID: sessionID, serverID: serverID,
                phase: .gatheringEvidence, batchID: batch.batchID, batchRevision: batch.revision,
                batchSize: batch.tracks.count, attempt: round + 1, provider: providerName, model: modelName,
                message: "output=plainJSON payload_bytes=\(request.messages.last?.content.utf8.count ?? 0)"
            ))
            guard let response = try? await complete(provider, request: request, timeout: 30) else { break }
            await observe(.init(
                kind: .providerRequestCompleted, runID: runID, sessionID: sessionID, serverID: serverID,
                phase: .gatheringEvidence, batchID: batch.batchID, batchRevision: batch.revision,
                batchSize: batch.tracks.count, attempt: round + 1, provider: providerName, model: modelName,
                message: "output_bytes=\(response.content.utf8.count)"
            ))
            let calls = response.toolCalls ?? []
            guard !calls.isEmpty else { break }
            conversation.append(.init(role: .assistant, content: response.content, toolCalls: calls))
            var results: [AIMessage] = []
            for raw in calls where totalCalls < 12 {
                guard case let .object(arguments) = raw.arguments,
                      let descriptor = selected.first(where: { $0.name == raw.name }),
                      descriptor.permission == .readOnly
                else {
                    results.append(.init(role: .tool, content: "工具未装载或不是证据阶段允许的只读工具。", toolCallID: raw.id))
                    continue
                }
                let signature = "\(raw.name):\(raw.arguments.jsonString)"
                guard seenCalls.insert(signature).inserted else {
                    results.append(.init(role: .tool, content: "相同证据查询已执行；请使用现有结果。", toolCallID: raw.id))
                    continue
                }
                totalCalls += 1
                await observe(.init(kind: .evidenceToolStarted, runID: runID, sessionID: sessionID, serverID: serverID,
                    phase: .gatheringEvidence, batchID: batch.batchID, batchRevision: batch.revision, batchSize: batch.tracks.count,
                    attempt: round + 1, provider: providerName, model: modelName, message: raw.name))
                let result = await ToolRuntime.execute(
                    ToolCall(name: raw.name, arguments: arguments), bridge: bridge, catalog: catalog, serverID: serverID,
                    systemService: systemService, externalMusicService: externalMusicService, allowsLyrics: allowsLyrics,
                    providerCapabilities: provider.capabilities, webService: webService, authorizationContext: nil,
                    executionLease: executionLease, resourceLeaseRegistry: resourceLeaseRegistry,
                    recommendationIndexExecutionRegistry: executionStateRegistry,
                    availableToolDescriptors: availableToolDescriptors, capabilityEnvironment: environment
                )
                let summary = String(result.summary.prefix(1_200))
                let target = stringArgument(arguments["trackID"]) ?? stringArgument(arguments["id"])
                if let target, batch.tracks.contains(where: { $0.id == target }) {
                    records[target, default: []].append(.init(
                        toolName: raw.name,
                        targetTrackID: target,
                        kind: descriptor.namespace,
                        summaryForModel: summary,
                        payloadProjection: evidencePayloadProjection(result.payload)
                    ))
                }
                if raw.name == "tool_search", result.success {
                    let query = stringArgument(arguments["query"]) ?? ""
                    for entry in ToolCatalog(descriptors: allReadOnly).search(query: query, limit: 8) {
                        guard let found = allReadOnly.first(where: { $0.name == entry.name }), discovered.insert(found.name).inserted,
                              !selected.contains(where: { $0.name == found.name }) else { continue }
                        selected.append(found)
                    }
                }
                results.append(.init(role: .tool, content: "\(raw.name)：\(summary)", toolCallID: raw.id))
                await observe(.init(kind: .evidenceToolCompleted, runID: runID, sessionID: sessionID, serverID: serverID,
                    phase: .gatheringEvidence, batchID: batch.batchID, batchRevision: batch.revision, batchSize: batch.tracks.count,
                    attempt: round + 1, provider: providerName, model: modelName, message: "\(raw.name) success=\(result.success)"))
            }
            conversation.append(contentsOf: results)
        }
        return batch.tracks.map { .init(track: $0, evidence: records[$0.id] ?? []) }
    }

    private static func evidencePayloadProjection(_ payload: AgentMessage?) -> String? {
        guard let payload else { return nil }
        let projection: String
        switch payload {
        case let .text(value), let .streaming(value):
            projection = value
        case let .trackCards(cards):
            projection = cards.prefix(20).map { "《\($0.title)》-\($0.artistName)" }.joined(separator: "、")
        case let .albumCards(cards):
            projection = cards.prefix(20).map { "《\($0.title)》-\($0.artistName)" }.joined(separator: "、")
        case let .playlistCards(cards):
            projection = cards.prefix(20).map { "\($0.name)（\($0.trackCount) 首）" }.joined(separator: "、")
        case let .artistCards(cards):
            projection = cards.prefix(20).map { "\($0.name)（\($0.albumCount) 张专辑）" }.joined(separator: "、")
        default:
            return nil
        }
        let trimmed = projection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumEvidenceTextCharacters))
    }

    private static func stringArgument(_ value: AIJSONValue?) -> String? {
        guard case let .some(.string(value)) = value else { return nil }
        return value
    }

    private static func classificationRequest(
        provider: any AIProvider,
        model: String,
        batch: RecommendationIndexPreparedBatch,
        evidence: [RecommendationIndexTrackEvidence],
        repairDiagnostic: RecommendationIndexClassificationDiagnostics? = nil
    ) async throws -> AICompletionRequest {
        let parts = try classificationRequestParts(
            provider: provider,
            model: model,
            batch: batch,
            evidence: evidence,
            repairDiagnostic: repairDiagnostic
        )
        guard parts.budget.fits else {
            throw RecommendationIndexClassificationDiagnostics(
                stage: .contextBudget,
                batchSize: batch.tracks.count,
                rawLength: 0,
                jsonFound: false,
                message: "分类请求超过安全上下文预算（\(parts.budget.summary)）",
                expectedBatchID: batch.batchID,
                expectedRevision: batch.revision,
                fieldPath: "request",
                expectedType: parts.budget.maxContextTokens == nil
                    ? "request bytes <= safe fallback"
                    : "estimated total tokens <= max context tokens",
                actualType: parts.budget.summary
            )
        }
        return parts.request
    }

    private static func classificationRequestParts(
        provider: any AIProvider,
        model: String,
        batch: RecommendationIndexPreparedBatch,
        evidence: [RecommendationIndexTrackEvidence],
        repairDiagnostic: RecommendationIndexClassificationDiagnostics?
    ) throws -> ClassificationRequestParts {
        let boundedEvidence = boundedEvidence(evidence)
        let input = ClassificationInput(
            batchID: batch.batchID,
            revision: batch.revision,
            tracks: boundedEvidence
        )
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let system = classificationSystemPrompt(repairDiagnostic: repairDiagnostic)
        let outputFormat = classificationOutputFormat(for: provider.capabilities)
        let request = AICompletionRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: system),
                AIMessage(role: .user, content: payload),
            ],
            temperature: 0.1,
            maxTokens: provider.capabilities.maxOutputTokens,
            tools: [],
            toolChoice: nil,
            hostedTools: [],
            outputFormat: outputFormat
        )
        let outputFormatBytes = outputFormat.flatMap {
            try? JSONEncoder().encode($0).count
        } ?? 0
        let budget = RecommendationIndexBatchPolicy.requestBudget(
            systemPromptBytes: system.utf8.count,
            payloadBytes: payload.utf8.count,
            outputSchemaBytes: outputFormatBytes,
            requestWrapperBytes: requestWrapperBytes(
                model: model,
                maxTokens: request.maxTokens
            ),
            maxContextTokens: provider.capabilities.hasKnownContextWindow
                ? provider.capabilities.maxContextTokens
                : nil,
            reservedOutputTokens: request.maxTokens
        )
        return ClassificationRequestParts(request: request, budget: budget)
    }

    private static func classificationSystemPrompt(
        repairDiagnostic: RecommendationIndexClassificationDiagnostics?
    ) -> String {
        let repairInstruction: String
        if let repairDiagnostic {
            let field = repairDiagnostic.fieldPath ?? "结构化输出"
            let expected = repairDiagnostic.expectedType ?? "当前 v3 契约"
            let actual = repairDiagnostic.actualType ?? "缺失或无效"
            repairInstruction = """
            上一轮同一批次只发现一个结构性契约问题，请修复后重新输出：
            field=\(field); expected=\(expected); received=\(actual)。
            只修复该结构，不要更换 batchID、revision 或 tracks 中的 id；不要输出原始上一轮内容。
            """
        } else {
            repairInstruction = ""
        }
        return """
        你是 Auralis FIXED TAXONOMY CLASSIFIER。你只能从 Auralis 已定义的固定 taxonomy 中选择标签，不能发明新标签、不能创建自由文本标签。
        返回且只返回一个 JSON 对象，必须原样回传 batchID、revision，并让 items 恰好覆盖输入 tracks 的每个 id 一次且不得重复。
        固定维度为 moods/scenes/themes/genres/styles/vocals/instruments/textures/rhythms；数值为 energy(1-10)、tempo/acousticness/danceability/instrumentalness/liveness/speechiness/valence/complexity(1-5)。
        数组中的每一项必须使用下面完整 catalog 中存在的固定 taxonomy ID。没有足够证据时 categorical 返回 []，numeric 返回 null，不要伪造中间值。
        genre 与 style 分开，mood 与 scene/theme 分开，instrument 与 texture 分开。不要为了完整而强行选择标签。
        JSON 类型必须严格遵守：categorical 都是 string[]；数值是 integer 或 null；batchID/id 是 string；revision/confidence 是 number。不要输出 semanticTags 或 mode。

        完整固定 taxonomy catalog（只允许使用这些 TagID；等号右侧是显示语义）：
        \(RecommendationIndexTaxonomy.compactClassifierCatalog)

        \(repairInstruction)
        """
    }

    private static func classificationOutputFormat(
        for capabilities: ModelCapabilities
    ) -> AIOutputFormat? {
        if capabilities.supportsJSONSchema {
            return .jsonSchema(
                name: "recommendation_index_classification",
                schema: outputSchema(),
                strict: true
            )
        }
        if capabilities.supportsJSONMode {
            return .jsonObject
        }
        return nil
    }

    private static func boundedEvidence(
        _ evidence: [RecommendationIndexTrackEvidence]
    ) -> [RecommendationIndexTrackEvidence] {
        evidence.map { trackEvidence in
            RecommendationIndexTrackEvidence(
                track: trackEvidence.track,
                evidence: Array(trackEvidence.evidence.prefix(maximumEvidenceRecordsPerTrack)).map { record in
                    RecommendationIndexEvidenceRecord(
                        toolName: record.toolName,
                        targetTrackID: record.targetTrackID,
                        kind: record.kind,
                        summaryForModel: boundedEvidenceText(record.summaryForModel),
                        payloadProjection: record.payloadProjection.map(boundedEvidenceText)
                    )
                }
            )
        }
    }

    private static func boundedEvidenceText(_ value: String) -> String {
        guard value.count > maximumEvidenceTextCharacters else { return value }
        return String(value.prefix(maximumEvidenceTextCharacters - 1)) + "…"
    }

    private static func requestWrapperBytes(model: String, maxTokens: Int) -> Int {
        let skeleton = AICompletionRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: ""),
                AIMessage(role: .user, content: ""),
            ],
            temperature: 0.1,
            maxTokens: maxTokens,
            tools: [],
            toolChoice: nil,
            hostedTools: [],
            outputFormat: nil
        )
        return (try? JSONEncoder().encode(skeleton).count) ?? 0
    }

    private static func requestPayloadBytes(_ request: AICompletionRequest) -> Int {
        if let data = try? JSONEncoder().encode(request) {
            return data.count
        }
        return request.messages.reduce(0) { $0 + $1.content.utf8.count }
    }

    private static func outputFormatName(_ format: AIOutputFormat?) -> String {
        switch format {
        case nil, .text:
            return "text"
        case .jsonObject:
            return "jsonObject"
        case .jsonSchema:
            return "jsonSchema"
        }
    }

    private static func complete(
        _ provider: any AIProvider,
        request: AICompletionRequest,
        timeout: TimeInterval
    ) async throws -> AICompletionResponse {
        try await withThrowingTaskGroup(of: AICompletionResponse.self) { group in
            group.addTask { try await provider.complete(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AIProviderError.transport("请求超时")
            }
            guard let value = try await group.next() else {
                throw AIProviderError.transport("请求未返回结果")
            }
            group.cancelAll()
            return value
        }
    }

    private static func decodeCheckpoint(_ raw: String?) -> RecommendationIndexCheckpoint? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RecommendationIndexCheckpoint.self, from: data)
    }

    private enum ClassificationFailureDisposition {
        case shrinkBatch
        case retrySameBatch
        case fail
    }

    private static func disposition(for error: Error) -> ClassificationFailureDisposition {
        if let diagnostic = error as? RecommendationIndexClassificationDiagnostics {
            switch diagnostic.stage {
            case .codableDecode, .batchIdentity, .revision, .trackCoverage:
                return .retrySameBatch
            case .taxonomy, .commit, .verify, .noProgress:
                return .fail
            case .providerOutput:
                return .retrySameBatch
            case .jsonExtraction:
                return .shrinkBatch
            case .contextBudget:
                return .shrinkBatch
            }
        }
        if case .outputTruncated = error as? AIProviderError { return .shrinkBatch }
        return .fail
    }

    private static func isTransientClassificationFailure(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else { return false }
        return providerError.isTransient
    }

    private static func fitBatchToRequestBudget(
        _ tracks: [CatalogTrackLine],
        batchID: UUID,
        revision: UInt64,
        provider: any AIProvider,
        model: String
    ) throws -> [CatalogTrackLine] {
        guard !tracks.isEmpty else { return [] }
        var low = 1
        var high = tracks.count
        var best = 0
        while low <= high {
            let middle = (low + high) / 2
            let candidateTracks = Array(tracks.prefix(middle))
            let candidate = RecommendationIndexPreparedBatch(
                batchID: batchID,
                revision: revision,
                checkpointGeneration: 0,
                tracks: candidateTracks,
                pendingFixed: 0
            )
            let candidateEvidence = candidateTracks.map {
                RecommendationIndexTrackEvidence(track: $0, evidence: [])
            }
            let budget = try classificationRequestParts(
                provider: provider,
                model: model,
                batch: candidate,
                evidence: candidateEvidence,
                repairDiagnostic: nil
            ).budget
            if budget.fits {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard best > 0 else {
            let singleTrack = Array(tracks.prefix(1))
            let candidate = RecommendationIndexPreparedBatch(
                batchID: batchID,
                revision: revision,
                checkpointGeneration: 0,
                tracks: singleTrack,
                pendingFixed: 0
            )
            let candidateEvidence = singleTrack.map {
                RecommendationIndexTrackEvidence(track: $0, evidence: [])
            }
            let budget = try classificationRequestParts(
                provider: provider,
                model: model,
                batch: candidate,
                evidence: candidateEvidence,
                repairDiagnostic: nil
            ).budget
            throw RecommendationIndexClassificationDiagnostics(
                stage: .contextBudget,
                batchSize: 1,
                rawLength: 0,
                jsonFound: false,
                message: "单首歌曲也超过分类请求上下文预算（\(budget.summary)）",
                expectedBatchID: batchID,
                expectedRevision: revision,
                fieldPath: "request",
                expectedType: budget.maxContextTokens == nil
                    ? "request bytes <= safe fallback"
                    : "estimated total tokens <= max context tokens",
                actualType: budget.summary
            )
        }
        return Array(tracks.prefix(best))
    }

    private static func trailingCount(_ action: String) -> Int? {
        action.split(separator: " ").compactMap { Int($0) }.last
    }
}
