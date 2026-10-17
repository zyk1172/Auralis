// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AIKit
import Domain
import Foundation
import LocalCatalog

/// The user's job lasts until the pending set is empty or explicitly stopped. A request deadline
/// bounds one attempt; it does not discard the job when a network/model service is temporarily slow.
public struct TagClassificationJob: Sendable {
    public let runner: TagClassificationRunner
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(runner: TagClassificationRunner,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner; self.sleep = sleep
    }

    public func run(serverID: ServerID,
                    authorize: @escaping @Sendable () async throws -> Void = {},
                    onProgress: @escaping @Sendable (TagClassificationProgress) async -> Void = { _ in }) async throws {
        var failures = 0
        var lastIndexed = -1
        var batchSize = 8
        while true {
            try Task.checkCancellation()
            try await authorize()
            do {
                try await runner.run(serverID: serverID, batchSize: batchSize, authorize: authorize, onProgress: onProgress)
                return
            } catch {
                try Task.checkCancellation()
                guard Self.canRetry(error) else { throw error }
                try await authorize()
                let status = try await runner.catalog.recommendationIndexStatus(serverID: serverID)
                if status.pendingTracks == 0 { return }
                if status.indexedTracks > lastIndexed { failures = 0 }
                lastIndexed = status.indexedTracks
                failures += 1
                if error is TagClassificationTimeout || error is TagClassificationEmptyResponse {
                    batchSize = max(1, batchSize / 2)
                }
                let seconds = min(300, 15 * (1 << min(failures - 1, 5)))
                await onProgress(.init(status: status, batchNumber: 0, phase: .retrying, batchSize: batchSize,
                    requestTimeoutSeconds: max(1, runner.requestTimeout.components.seconds),
                    retryAt: Date().addingTimeInterval(Double(seconds)), retryReason: error.localizedDescription))
                try await sleep(.seconds(seconds))
            }
        }
    }

    public static func canRetry(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if error is TagClassificationTimeout || error is TagClassificationEmptyResponse { return true }
        if error is RecommendationIndexClassificationDiagnostics { return true }
        if let provider = error as? AIProviderError { return provider.isTransient }
        if let failure = error as? TagClassificationFailure { return failure.isRetryable }
        if let url = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                    .callIsActive, .dataNotAllowed, .resourceUnavailable].contains(url.code)
        }
        return (error as? RecommendationIndexWriteError) == .invalidBatch
    }
}
