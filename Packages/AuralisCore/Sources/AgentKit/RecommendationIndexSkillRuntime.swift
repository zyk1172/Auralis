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
    case mode
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
        duplicateIDs: [String] = []
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
        if !missingIDs.isEmpty { parts.append("missing_ids=\(missingIDs.joined(separator: ","))") }
        if !extraIDs.isEmpty { parts.append("extra_ids=\(extraIDs.joined(separator: ","))") }
        if !duplicateIDs.isEmpty { parts.append("duplicate_ids=\(duplicateIDs.joined(separator: ","))") }
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
        guard (try? AIJSONValue(jsonData: data)) != nil else {
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
            return .failure(.init(
                stage: .codableDecode,
                batchSize: batch.tracks.count,
                rawLength: rawLength,
                jsonFound: true,
                message: decodingMessage(error)
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
        return .success(envelope)
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
        let tracks: [CatalogTrackLine]
        let canonicalTags: [TagSnapshot]
    }

    private static let outputSchema = try! AIJSONValue(jsonString: #"""
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
              "moods": {"type": "array", "items": {"type": "string"}},
              "scenes": {"type": "array", "items": {"type": "string"}},
              "energy": {"type": "integer", "minimum": 1, "maximum": 10},
              "tempo": {"type": "integer", "minimum": 1, "maximum": 5},
              "acousticness": {"type": "integer", "minimum": 1, "maximum": 5},
              "danceability": {"type": "integer", "minimum": 1, "maximum": 5},
              "vocals": {"type": "array", "items": {"type": "string"}},
              "textures": {"type": "array", "items": {"type": "string"}},
              "styles": {"type": "array", "items": {"type": "string"}},
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
            "required": ["id", "mode"]
          }
        }
      },
      "required": ["batchID", "revision", "mode", "items"]
    }
    """#)

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
        state: @escaping @Sendable (AgentTaskState) async -> Void
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
        guard await executionStateRegistry.begin(
            serverID: serverID,
            runID: runID,
            sessionID: sessionID
        ) else {
            let message = "推荐索引已在另一个运行中；当前没有启动新的索引任务。"
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
            case .classifyingBatch:
                if let status, let currentBatch {
                    return "推荐索引：已完成 \(status.indexedTracks) / \(status.totalTracks)，正在分类当前批次 \(currentBatch.tracks.count) 首"
                }
                return "正在分类推荐索引批次"
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
            terminal: Bool = false
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
                    totalTracks: latestStatus?.totalTracks ?? 0,
                    indexedTracks: latestStatus?.indexedTracks ?? 0,
                    pendingTracks: latestStatus?.pendingTracks ?? 0,
                    pendingSemanticTagTracks: latestStatus?.pendingSemanticTagTracks ?? 0,
                    currentBatchSize: currentBatch?.tracks.count ?? 0,
                    processedThisRun: totalWrittenThisRun
                )
            }
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
        func fail(
            _ message: String,
            phase: RecommendationIndexWorkflow.State
        ) async {
            taskState.status = .failed
            taskState.completionState = .failed
            taskState.errorState = message
            taskState.errors.append(message)
            taskState.pendingActions = []
            await publish(phase: phase, stoppedReason: message, terminal: true)
            await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
        }

        taskState.status = .running
        taskState.pendingActions = ["正在读取推荐索引状态"]
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
                let message = violation.localizedDescription
                taskState.status = .failed
                taskState.completionState = .failed
                taskState.errorState = message
                taskState.errors.append(message)
                taskState.pendingActions = []
                await publish(phase: .readingStatus, stoppedReason: message, terminal: true)
                await emit(AgentChatMessage(role: .assistant, messages: [.error(message)]))
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
                let message = "无法读取推荐索引状态：目录尚未提供当前服务器的索引状态。"
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
            do {
                let request = try await classificationRequest(
                    provider: provider,
                    model: model,
                    batch: prepared,
                    catalog: catalog,
                    serverID: serverID
                )
                // Hard invariant: this model turn is a closed transform.
                precondition(request.tools?.isEmpty == true)
                precondition(request.hostedTools?.isEmpty == true)
                precondition(request.toolChoice == nil)
                let response = try await complete(provider, request: request, timeout: requestTimeout)
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
                case let .failure(diagnostic):
                    classificationDiagnostics = diagnostic
                    throw diagnostic
                }
            } catch is CancellationError {
                taskState.status = .cancelled
                taskState.pendingActions = []
                await publish(phase: .classifyingBatch, currentBatch: prepared, stoppedReason: "运行已取消", terminal: true)
                return
            } catch {
                if isMalformedOrTruncated(error) {
                    preferredBatchSize = RecommendationIndexBatchPolicy.reducedLimit(from: prepared.tracks.count)
                    taskState.status = .waitingForModel
                    taskState.pendingActions = ["推荐索引正在重试当前批次…"]
                    if let diagnostic = classificationDiagnostics ?? (error as? RecommendationIndexClassificationDiagnostics) {
                        if let data = try? JSONEncoder().encode(diagnostic) {
                            taskState.facts["recommendation.index.classification.failure"] = String(decoding: data, as: UTF8.self)
                        }
                        await log(AgentActionRecord(
                            toolName: "recommendation_index_classification",
                            permission: .readOnly,
                            summary: diagnostic.compactSummary
                        ))
                    }
                    // Never persist the old batch as writable after a failed
                    // transform. The next prepare creates a new ID/revision.
                    await publish(
                        phase: .fetchingBatch,
                        stoppedReason: classificationDiagnostics.map { "分类输出校验失败（\($0.stage.rawValue)），正在重试" }
                            ?? "分类输出校验失败，正在重试",
                        terminal: false
                    )
                    await progress(ToolLoop.AgentProgress(
                        toolSteps: taskState.progress.toolCalls,
                        currentStep: "推荐索引正在重试当前批次…",
                        inputTokens: taskState.progress.inputTokens,
                        outputTokens: taskState.progress.outputTokens
                    ))
                    continue
                }
                await fail(
                    "推荐索引暂时无法继续：AI Provider 请求失败。\(error.localizedDescription)",
                    phase: .classifyingBatch
                )
                return
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
                await fail(
                    "推荐索引分类结果无法编码，未写入任何数据。",
                    phase: .writingBatch
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
            await publish(phase: .writingBatch, currentBatch: prepared)
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
                await fail(
                    "推荐索引写入失败：\(result.summary)",
                    phase: .writingBatch
                )
                return
            }
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

    private static func classificationRequest(
        provider: any AIProvider,
        model: String,
        batch: RecommendationIndexPreparedBatch,
        catalog: LocalCatalogStore,
        serverID: ServerID?
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
            tracks: batch.tracks,
            canonicalTags: page.items.map { TagSnapshot(value: $0.value, trackCount: $0.trackCount) }
        )
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let modeInstruction = batch.mode == "semanticTagsOnly"
            ? "本批仅补充开放 semanticTags；每项 mode 必须为 semanticTagsOnly。"
            : "本批执行完整音乐属性分类；每项 mode 必须为 full。"
        let system = """
        你是推荐索引的封闭式分类转换器。只根据输入的歌曲元数据分类，不调用工具，不执行写入，不补充输入中不存在的歌曲。
        返回且只返回一个 JSON 对象，必须原样回传 batchID、revision、mode，并让 items 恰好覆盖输入 tracks 的每个 id 一次且不得重复。
        固定维度为 moods、scenes、energy(1-10)、tempo/acousticness/danceability(1-5)、vocals、textures、styles；semanticTags 使用有音乐意义且有区分度的规范标签，优先复用 canonicalTags，不使用歌曲名、艺术家名、专辑名或 ID 作为标签。
        \(modeInstruction)
        """
        let outputFormat: AIOutputFormat?
        if provider.capabilities.supportsJSONSchema {
            outputFormat = .jsonSchema(
                name: "recommendation_index_classification",
                schema: outputSchema,
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

    private static func isMalformedOrTruncated(_ error: Error) -> Bool {
        if error is RecommendationIndexValidationError
            || error is RecommendationIndexClassificationDiagnostics
            || error is RecommendationIndexRuntimeError {
            return true
        }
        guard let providerError = error as? AIProviderError else { return false }
        if case .outputTruncated = providerError { return true }
        return false
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
