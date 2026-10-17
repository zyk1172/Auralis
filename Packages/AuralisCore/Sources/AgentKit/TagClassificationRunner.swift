// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AIKit
import Domain
import Foundation
import LocalCatalog

public struct TagClassificationProgress: Sendable {
    public let status: RecommendationIndexStatus
    public let batchNumber: Int
    public var phase: TagClassificationPhase = .preparing
    public var batchSize: Int = 0
    public var partNumber: Int = 0
    public var partCount: Int = 0
    public var requestStartedAt: Date?
}

public enum TagClassificationPhase: Sendable {
    case preparing, requesting, validating, committing
}

/// Closed metadata classification. No chat session, tools, capability probes or Agent loop.
public struct TagClassificationRunner: Sendable {
    public let catalog: LocalCatalogStore
    public let provider: any AIProvider
    public let model: String
    public let maxOutputTokens: Int
    public let requestTimeout: Duration
    public let reasoning: AIReasoningConfiguration?

    public init(catalog: LocalCatalogStore, provider: any AIProvider, model: String, maxOutputTokens: Int = 8_000,
                requestTimeout: Duration = .seconds(60), reasoning: AIReasoningConfiguration? = nil) {
        self.catalog = catalog; self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = max(512, min(maxOutputTokens, 8_000))
        self.requestTimeout = requestTimeout
        self.reasoning = reasoning
    }

    public func run(
        serverID: ServerID,
        authorize: @escaping @Sendable () async throws -> Void = {},
        onProgress: @Sendable (TagClassificationProgress) async -> Void = { _ in }
    ) async throws {
        // Save a first song promptly, especially within iOS's short foreground-to-background grace period.
        let outputTokens = min(maxOutputTokens, provider.capabilities.maxOutputTokens,
                               max(512, provider.capabilities.maxContextTokens / 4))
        let maximumSize = min(8, max(1, outputTokens / 512))
        var size = 1
        var batchNumber = 0
        var retriedSingleTrack = false
        while true {
            try Task.checkCancellation()
            try await authorize()
            let status = try await catalog.recommendationIndexStatus(serverID: serverID)
            await onProgress(.init(status: status, batchNumber: batchNumber))
            if status.pendingTracks == 0 { return }
            let batch = try await catalog.nextRecommendationIndexBatch(serverID: serverID, limit: size)
            guard !batch.tracks.isEmpty else { throw TagClassificationFailure("没有可读取的待分类曲目，请先同步音乐库。") }
            let prepared = RecommendationIndexPreparedBatch(batchID: UUID(), revision: 0, checkpointGeneration: 0,
                tracks: batch.tracks, pendingFixed: batch.pendingFixedTracks)
            let tracks = batch.tracks.map(RecommendationIndexClassifierTrack.init)
            let payload = String(decoding: try JSONEncoder().encode(tracks), as: UTF8.self)
            let items: [RecommendationIndexClassification]
            do {
                let requests = try TagClassificationRequestPlan.requests(model: model, payload: payload,
                    contextTokens: provider.capabilities.maxContextTokens, outputTokens: outputTokens, reasoning: reasoning)
                var merged = TagClassificationAccumulator()
                for (index, request) in requests.enumerated() {
                    try Task.checkCancellation()
                    try await authorize()
                    await onProgress(.init(status: status, batchNumber: batchNumber + 1, phase: .requesting,
                        batchSize: tracks.count, partNumber: index + 1, partCount: requests.count, requestStartedAt: .now))
                    let response = try await completeWithDeadline(request, authorize: authorize)
                    try Task.checkCancellation()
                    await onProgress(.init(status: status, batchNumber: batchNumber + 1, phase: .validating,
                        batchSize: tracks.count, partNumber: index + 1, partCount: requests.count))
                    guard response.toolCalls?.isEmpty != false else { throw TagClassificationFailure("分类模型返回了工具调用，需要 JSON 分类结果。") }
                    let part = try RecommendationIndexClassificationParser.parse(response.content, for: prepared).get().items
                    guard Set(part.map(\.id)) == Set(batch.tracks.map(\.id)), part.count == batch.tracks.count else {
                        throw TagClassificationFailure("模型未完整返回当前批次，尚未写入；请重试。")
                    }
                    merged.append(part, includeFeatures: index == 0)
                }
                items = try RecommendationIndexClassificationParser.parse(merged.json, for: prepared).get().items
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                // A bounded retry with a smaller batch fixes truncated/partial JSON without a loop.
                if !(error is TagClassificationTimeout), !(error is TagClassificationEmptyResponse),
                   !(error is AIProviderError) || (error as? AIProviderError) == .outputTruncated {
                    if size > 1 { size = max(1, size / 2); continue }
                    if !retriedSingleTrack { retriedSingleTrack = true; continue }
                }
                throw error
            }
            try Task.checkCancellation()
            try await authorize()
            await onProgress(.init(status: status, batchNumber: batchNumber + 1, phase: .committing, batchSize: tracks.count))
            let written = try await catalog.writeRecommendationIndex(items, serverID: serverID,
                classifier: "background-tags/\(model)", requireExact: true, expectedTracks: batch.tracks)
            guard written == batch.tracks.count else { throw TagClassificationFailure("分类未完整入库，请刷新后继续。") }
            batchNumber += 1
            retriedSingleTrack = false
            size = min(maximumSize, size * 2)
        }
    }

    private func completeWithDeadline(_ request: AICompletionRequest,
                                      authorize: @escaping @Sendable () async throws -> Void) async throws -> AICompletionResponse {
        // This deadline includes the provider's internal retries. A stalled gateway must not leave
        // the settings page claiming to work for 3 × the chat request timeout (18 minutes).
        try await withThrowingTaskGroup(of: AICompletionResponse.self) { group in
            group.addTask {
                let first = try await classificationResponse(request)
                if first.hasAnswer || first.response.toolCalls?.isEmpty == false { return first.response }
                try Task.checkCancellation()
                try await authorize()
                // Some gateways acknowledge streaming but omit every answer event. One ordinary
                // request can recover their buffered final answer; keep the same model and settings.
                let recovered = ClassificationProviderOutput(response: try await provider.complete(request))
                guard recovered.hasAnswer || recovered.response.toolCalls?.isEmpty == false else {
                    throw TagClassificationEmptyResponse(initial: first.summary, recovery: recovered.summary)
                }
                return recovered.response
            }
            group.addTask {
                try await Task.sleep(for: requestTimeout)
                throw TagClassificationTimeout(seconds: max(1, requestTimeout.components.seconds))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func classificationResponse(_ request: AICompletionRequest) async throws -> ClassificationProviderOutput {
        guard provider.capabilities.supportsStreaming else { return .init(response: try await provider.complete(request)) }
        // Use the configured provider transport, just like ordinary AI requests. Gateways that
        // support streaming must not be forced onto a separately buffered/non-streaming route.
        var content = ""
        var responseModel = request.model
        var reasoningBytes = 0
        var outputTokens: Int?
        var reasoningTokens: Int?
        func result() -> ClassificationProviderOutput {
            .init(response: .init(model: responseModel, content: content, outputTokens: outputTokens,
                reasoningTokens: reasoningTokens, finishReason: "stop"), reasoningBytes: reasoningBytes)
        }
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            switch event {
            case let .started(model, _): responseModel = model
            case let .answerDelta(delta), let .unknownDelta(delta): content += delta
            case let .reasoningDelta(delta): reasoningBytes += delta.utf8.count
            case let .usage(_, output, _, _, reasoning): outputTokens = output; reasoningTokens = reasoning
            case .toolCall:
                throw TagClassificationFailure("分类模型返回了工具调用，需要 JSON 分类结果。")
            case .completed:
                return result()
            case let .terminated(termination):
                switch termination.kind {
                case .completed: return result()
                case .truncated: throw AIProviderError.outputTruncated
                default: throw TagClassificationFailure("分类响应未完整结束，未写入本批结果；请继续重试。")
                }
            default: break // Reasoning and continuation state are never classification data.
            }
        }
        throw TagClassificationFailure("模型连接结束但未收到完成信号，未写入本批结果；请继续重试。")
    }
}

private struct ClassificationProviderOutput: Sendable {
    let response: AICompletionResponse
    let reasoningBytes: Int
    init(response: AICompletionResponse, reasoningBytes: Int? = nil) {
        self.response = response
        self.reasoningBytes = reasoningBytes ?? response.reasoning?.utf8.count ?? 0
    }
    var hasAnswer: Bool { !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var summary: String {
        "正文 \(response.content.utf8.count) 字节，推理 \(reasoningBytes) 字节，输出 tokens \(response.outputTokens.map(String.init) ?? "未知")，结束 \(response.finishReason ?? "未知")"
    }
}

public struct TagClassificationEmptyResponse: Error, LocalizedError, Sendable {
    public let initial: String
    public let recovery: String
    public var errorDescription: String? {
        "分类响应没有可用正文，自动恢复后仍为空。本批未入库。首轮：\(initial)；恢复：\(recovery)。"
    }
}

public struct TagClassificationTimeout: Error, LocalizedError, Sendable {
    public let seconds: Int64
    public var errorDescription: String? {
        "分类请求超过 \(seconds) 秒仍未完成，已停止本次任务；已保存进度不会丢失，可继续分类。"
    }
}

public struct TagClassificationFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
