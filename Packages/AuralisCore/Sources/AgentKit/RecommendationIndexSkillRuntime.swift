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
    public let mode: String
    public let tracks: [CatalogTrackLine]
    public let pendingFixed: Int
    public let pendingSemantic: Int

    public init(
        batchID: UUID,
        revision: UInt64,
        checkpointGeneration: UInt64,
        mode: String,
        tracks: [CatalogTrackLine],
        pendingFixed: Int,
        pendingSemantic: Int
    ) {
        self.batchID = batchID
        self.revision = revision
        self.checkpointGeneration = checkpointGeneration
        self.mode = mode
        self.tracks = tracks
        self.pendingFixed = pendingFixed
        self.pendingSemantic = pendingSemantic
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
    public let mode: String
    public let items: [RecommendationIndexClassification]

    public init(
        batchID: UUID,
        revision: UInt64,
        mode: String,
        items: [RecommendationIndexClassification]
    ) {
        self.batchID = batchID
        self.revision = revision
        self.mode = mode
        self.items = items
    }
}

public enum RecommendationIndexValidationError: Error, LocalizedError, Equatable, Sendable {
    case staleBatch
    case wrongMode(expected: String, actual: String)
    case duplicateIDs
    case incompleteCoverage

    public var errorDescription: String? {
        switch self {
        case .staleBatch: "分类结果不属于当前批次"
        case let .wrongMode(expected, actual): "分类模式不匹配：需要 \(expected)，得到 \(actual)"
        case .duplicateIDs: "分类结果包含重复歌曲 ID"
        case .incompleteCoverage: "分类结果没有恰好覆盖当前批次"
        }
    }
}

public enum RecommendationIndexClassificationFailureStage: String, Codable, Sendable {
    case providerOutput
    case jsonExtraction
    case codableDecode
    case batchIdentity
    case revision
    case trackCoverage
    case taxonomy
    case mode
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
                receivedRevision: envelope.revision
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
                receivedRevision: envelope.revision
            ))
        }
        if envelope.mode != batch.mode || envelope.items.contains(where: { $0.mode != batch.mode }) {
            return .failure(.init(
                stage: .mode,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "分类 mode 与当前批次不一致"
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
                duplicateIDs: duplicateIDs
            ))
        }
        // Fixed taxonomy pre-validation: reject before commit so invalid values
        // never enter the SQLite transaction or get silently filtered away.
        if batch.mode != "semanticTagsOnly",
           let taxonomyFailure = taxonomyViolation(envelope.items) {
            return .failure(.init(
                stage: .taxonomy,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: "固定维度包含非 canonical 值：\(taxonomyFailure.values.sorted().joined(separator: "、"))",
                fieldPath: taxonomyFailure.fieldPath
            ))
        }
        return .success(envelope)
    }

    /// Returns the first fixed-dimension violation (field path + offending
    /// values), or nil when every categorical array is within its canonical set.
    static func taxonomyViolation(
        _ items: [RecommendationIndexClassification]
    ) -> (fieldPath: String, values: Set<String>)? {
        for (itemIndex, item) in items.enumerated() {
            let perItem: [(field: String, values: [String], allowed: Set<String>)] = [
                ("moods", item.moods, RecommendationIndex.moods),
                ("scenes", item.scenes, RecommendationIndex.scenes),
                ("vocals", item.vocals, RecommendationIndex.vocals),
                ("textures", item.textures, RecommendationIndex.textures),
                ("styles", item.styles, RecommendationIndex.styles),
            ]
            for dimension in perItem {
                let trimmed = dimension.values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let invalid = Set(trimmed).subtracting(dimension.allowed)
                if !invalid.isEmpty {
                    return ("items[\(itemIndex)].\(dimension.field)", invalid)
                }
            }
        }
        return nil
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
        case "moods", "scenes", "vocals", "textures", "styles":
            return "string[]"
        case "semanticTags":
            return "object[]"
        case "items":
            return "object[]"
        case "energy", "tempo", "acousticness", "danceability", "revision":
            return "integer"
        case "confidence":
            return "number"
        case "id", "batchID", "mode", "value":
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

    private struct TagSnapshot: Codable, Sendable {
        let value: String
        let trackCount: Int
    }

    private struct ClassificationInput: Codable, Sendable {
        let batchID: UUID
        let revision: UInt64
        let mode: String
        let tracks: [RecommendationIndexTrackEvidence]
        let canonicalTags: [TagSnapshot]
    }

    private static func outputSchema(for mode: String) -> AIJSONValue {
        let itemRequired: String
        if mode == "semanticTagsOnly" {
            itemRequired = #"["id", "semanticTags", "mode", "confidence"]"#
        } else {
            itemRequired = #"""
              ["id", "moods", "scenes", "energy", "tempo", "acousticness", "danceability",
               "vocals", "textures", "styles", "semanticTags", "mode", "confidence"]
            """#
        }
        let enumJSON: (Set<String>) -> String = { values in
            let sorted = values.sorted()
            return "[" + sorted.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }
        return try! AIJSONValue(jsonString: #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "batchID": {"type": "string"},
        "revision": {"type": "integer", "minimum": 1},
        "mode": {"type": "string", "enum": ["full", "semanticTagsOnly"]},
        "items": {
          "type": "array",
          "minItems": 1,
          "maxItems": 100,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "id": {"type": "string"},
              "moods": {"type": "array", "items": {"type": "string", "enum": \#(enumJSON(RecommendationIndex.moods))}},
              "scenes": {"type": "array", "items": {"type": "string", "enum": \#(enumJSON(RecommendationIndex.scenes))}},
              "energy": {"type": "integer", "minimum": 1, "maximum": 10},
              "tempo": {"type": "integer", "minimum": 1, "maximum": 5},
              "acousticness": {"type": "integer", "minimum": 1, "maximum": 5},
              "danceability": {"type": "integer", "minimum": 1, "maximum": 5},
              "vocals": {"type": "array", "items": {"type": "string", "enum": \#(enumJSON(RecommendationIndex.vocals))}},
              "textures": {"type": "array", "items": {"type": "string", "enum": \#(enumJSON(RecommendationIndex.textures))}},
              "styles": {"type": "array", "items": {"type": "string", "enum": \#(enumJSON(RecommendationIndex.styles))}},
              "semanticTags": {
                "type": "array",
                "items": {
                  "type": "object",
                  "additionalProperties": false,
                  "properties": {
                    "value": {"type": "string"},
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1}
                  },
                  "required": ["value", "confidence"]
                }
              },
              "mode": {"type": "string", "enum": ["full", "semanticTagsOnly"]},
              "confidence": {"type": "number", "minimum": 0, "maximum": 1}
            },
            "required": \#(itemRequired)
          }
        }
      },
      "required": ["batchID", "revision", "mode", "items"]
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
        guard envelope.mode == batch.mode else {
            throw RecommendationIndexValidationError.wrongMode(expected: batch.mode, actual: envelope.mode)
        }
        let ids = envelope.items.map(\.id)
        guard ids.count == Set(ids).count else {
            throw RecommendationIndexValidationError.duplicateIDs
        }
        let expected = batch.tracks.map(\.id)
        guard ids.count == expected.count, Set(ids) == Set(expected) else {
            throw RecommendationIndexValidationError.incompleteCoverage
        }
        guard envelope.items.allSatisfy({ $0.mode == batch.mode }) else {
            throw RecommendationIndexValidationError.wrongMode(
                expected: batch.mode,
                actual: envelope.items.first(where: { $0.mode != batch.mode })?.mode ?? ""
            )
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
                pendingSemanticTracks: latestStatus?.pendingSemanticTagTracks,
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
                taskState.facts["recommendation.index.pendingSemantic"] = "\(status.pendingSemanticTagTracks)"
            }
            taskState.facts["recommendation.index.skillID"] = skillID
            taskState.facts["recommendation.index.currentBatchIDs"] = currentBatch?.tracks.map(\.id).joined(separator: ",") ?? ""
            taskState.facts["recommendation.index.currentBatchMode"] = currentBatch?.mode ?? ""
            let checkpoint = RecommendationIndexCheckpoint(
                checkpointGeneration: generation,
                currentBatchID: currentBatch?.batchID,
                currentBatchRevision: currentBatch?.revision ?? revision,
                total: latestStatus?.totalTracks ?? restored?.total ?? 0,
                indexed: latestStatus?.indexedTracks ?? restored?.indexed ?? 0,
                pending: latestStatus?.pendingTracks ?? restored?.pending ?? 0,
                pendingSemantic: latestStatus?.pendingSemanticTagTracks ?? restored?.pendingSemantic ?? 0,
                totalWrittenThisRun: totalWrittenThisRun,
                lastSuccessfulBatchCount: taskState.completedActions.last.flatMap(Self.trailingCount) ?? 0,
                currentBatchIDs: currentBatch?.tracks.map(\.id) ?? [],
                currentBatchMode: currentBatch?.mode,
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
                    batchMode: currentBatch?.mode,
                    batchTrackIDs: currentBatch?.tracks.map(\.id) ?? [],
                    attempt: attempt,
                    totalTracks: latestStatus?.totalTracks ?? 0,
                    indexedTracks: latestStatus?.indexedTracks ?? 0,
                    pendingTracks: latestStatus?.pendingTracks ?? 0,
                    pendingSemanticTagTracks: latestStatus?.pendingSemanticTagTracks ?? 0,
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
            // coverage/mode/commit/verify/noProgress stage; status and batch
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
                message: "pending=\(status.pendingTracks), pendingSemantic=\(status.pendingSemanticTagTracks)"
            )
            if status.pendingTracks == 0, status.pendingSemanticTagTracks == 0 {
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
                    revision: &revision
                )
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
                message: "mode=\(prepared.mode)"
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
            do {
                var contractRepairAttempt = 0
                while true {
                let request = try await classificationRequest(
                    provider: provider,
                    model: model,
                    batch: prepared,
                    catalog: catalog,
                    serverID: serverID,
                    evidence: evidence
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
                    requestPayloadBytes: request.messages.last?.content.utf8.count,
                    message: "output=jsonSchema"
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
                await emitObservation(
                    .providerRequestFailed,
                    phase: .classifyingBatch,
                    batch: prepared,
                    attempt: classificationAttempt,
                    durationSince: classificationStartedAt,
                    message: error.localizedDescription
                )
                await emitObservation(
                    .classificationFailed,
                    phase: .classifyingBatch,
                    batch: prepared,
                    attempt: classificationAttempt,
                    durationSince: classificationStartedAt,
                    message: (classificationDiagnostics ?? (error as? RecommendationIndexClassificationDiagnostics))?.compactSummary
                        ?? error.localizedDescription
                )
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
                    // Never persist the old batch as writable after a failed
                    // transform. The next prepare creates a new ID/revision.
                    await publish(
                        phase: .retrying,
                        stoppedReason: "分类输出校验失败（\(failureDiagnostic.stage.rawValue)），正在重试",
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
                    await fail(
                        "推荐索引结构化输出不符合当前批次契约，重试同一批次也无法恢复；未写入该批次。（\(failureDiagnostic.compactSummary)）",
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
        revision: inout UInt64
    ) async throws -> RecommendationIndexPreparedBatch {
        let batch = try await catalog.nextRecommendationIndexBatch(serverID: serverID, limit: limit)
        let tracks = try fitBatchToPayloadBudget(batch.tracks)
        revision &+= 1
        return RecommendationIndexPreparedBatch(
            batchID: UUID(),
            revision: revision,
            checkpointGeneration: generation,
            mode: batch.mode,
            tracks: tracks,
            pendingFixed: batch.pendingFixedTracks,
            pendingSemantic: batch.pendingSemanticTagTracks
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
        var conversation: [AIMessage] = [
            .init(
                role: .system,
                content: "你是 Recommendation Index 的内部证据阶段。只可调用只读 Auralis 工具；不要输出分类 JSON，不要写入、修改播放、歌单、收藏、评分、服务器、下载或记忆。\n\n\(ToolCatalog(descriptors: availableToolDescriptors).awarenessEntries(environment: environment).map(\.renderedLine).joined(separator: "\\n"))\n\n当前直接可调用的 schema 是 Runtime 已加载的只读工具；可用 tool_search 发现其它只读工具。若批次元数据已经足够或证据已补齐，直接停止调用工具。"
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
                    records[target, default: []].append(.init(toolName: raw.name, targetTrackID: target, kind: descriptor.namespace, summaryForModel: summary))
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

    private static func stringArgument(_ value: AIJSONValue?) -> String? {
        guard case let .some(.string(value)) = value else { return nil }
        return value
    }

    private static func classificationRequest(
        provider: any AIProvider,
        model: String,
        batch: RecommendationIndexPreparedBatch,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        evidence: [RecommendationIndexTrackEvidence]
    ) async throws -> AICompletionRequest {
        let page = try await catalog.recommendationIndexTagCatalog(
            serverID: serverID,
            limit: 100,
            offset: 0
        )
        let input = ClassificationInput(
            batchID: batch.batchID,
            revision: batch.revision,
            mode: batch.mode,
            tracks: evidence,
            canonicalTags: page.items.map { TagSnapshot(value: $0.value, trackCount: $0.trackCount) }
        )
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let modeInstruction = batch.mode == "semanticTagsOnly"
            ? "本批仅补充开放 semanticTags；每项 mode 必须为 semanticTagsOnly。"
            : "本批执行完整音乐属性分类；每项 mode 必须为 full。"
        let taxonomyInstruction: String
        if batch.mode == "semanticTagsOnly" {
            taxonomyInstruction = ""
        } else {
            let list: (String, Set<String>) -> String = { name, values in
                "\(name)（只能从以下值中选择，不允许发明同义词）：\(values.sorted().joined(separator: "、"))"
            }
            taxonomyInstruction = """

        固定维度 canonical 值：
        \(list("moods", RecommendationIndex.moods))
        \(list("scenes", RecommendationIndex.scenes))
        \(list("vocals", RecommendationIndex.vocals))
        \(list("textures", RecommendationIndex.textures))
        \(list("styles", RecommendationIndex.styles))
        注意：不要用"伤感"替代"忧郁"、"夜晚"替代"深夜"、"流行音乐"替代"流行"。更细的自由语义放到 semanticTags。
        """
        }
        let system = """
        你是推荐索引的封闭式分类转换器。只根据输入的歌曲元数据分类，不调用工具，不执行写入，不补充输入中不存在的歌曲。
        返回且只返回一个 JSON 对象，必须原样回传 batchID、revision、mode，并让 items 恰好覆盖输入 tracks 的每个 id 一次且不得重复。
        固定维度为 moods、scenes、energy(1-10)、tempo/acousticness/danceability(1-5)、vocals、textures、styles；semanticTags 使用有音乐意义且有区分度的规范标签，优先复用 canonicalTags，不使用歌曲名、艺术家名、专辑名或 ID 作为标签。
        JSON 类型必须严格遵守：moods/scenes/vocals/textures/styles 都是 string[]（单个值也要写成数组）；semanticTags 是 object[]，每项为 {"value":string,"confidence":number}；energy/tempo/acousticness/danceability 是 integer；batchID/mode/id/value 是 string；revision/confidence 是 number。
        \(taxonomyInstruction)
        \(modeInstruction)
        """
        let outputFormat: AIOutputFormat?
        if provider.capabilities.supportsJSONSchema {
            outputFormat = .jsonSchema(
                name: "recommendation_index_classification",
                schema: outputSchema(for: batch.mode),
                strict: true
            )
        } else if provider.capabilities.supportsJSONMode {
            outputFormat = .jsonObject
        } else {
            outputFormat = nil
        }
        return AICompletionRequest(
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
            case .codableDecode, .commit, .verify, .noProgress:
                return .fail
            case .taxonomy, .batchIdentity, .revision, .trackCoverage, .mode:
                return .retrySameBatch
            case .providerOutput, .jsonExtraction:
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

    private static func fitBatchToPayloadBudget(_ tracks: [CatalogTrackLine]) throws -> [CatalogTrackLine] {
        guard !tracks.isEmpty else { return [] }
        let encoder = JSONEncoder()
        var low = 1
        var high = tracks.count
        var best = 0
        while low <= high {
            let middle = (low + high) / 2
            if try encoder.encode(Array(tracks.prefix(middle))).count <= RecommendationIndexBatchPolicy.safePayloadBytes {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard best > 0 else { throw RecommendationIndexRuntimeError.emptyBatch }
        return Array(tracks.prefix(best))
    }

    private static func trailingCount(_ action: String) -> Int? {
        action.split(separator: " ").compactMap { Int($0) }.last
    }
}
