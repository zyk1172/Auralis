// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Coordinates pause/resume and resource budgeting for an independent decoder.
/// Music playback is authoritative: analysis waits through the startup buffer,
/// stays within a small lookahead window, and immediately yields while playback
/// is paused or buffering. The haptics sidecar may be late or incomplete; audio
/// must never be late because of haptics.
final class MusicHapticsAnalysisControl: @unchecked Sendable {
    private struct Waiter {
        let analysisPosition: TimeInterval
        let sourceDuration: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Give AVPlayer exclusive access to startup CPU/network bandwidth first.
    static let startupGraceSeconds: TimeInterval = 1.5
    /// The scheduler only commits a few seconds ahead. Eight seconds gives the
    /// haptic renderer margin without allowing a second decoder to race to EOF.
    static let maximumLeadSeconds: TimeInterval = 8

    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var playbackPosition: TimeInterval = 0
    private var playbackRate: Double = 1
    private var isPlaying = true
    private var waiters: [Waiter] = []

    init() {}

    func pause() {
        lock.withLock {
            paused = true
        }
    }

    func resume() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !cancelled else { return [] }
            paused = false
            isPlaying = true
            return takeReadyWaitersLocked()
        }
        continuations.forEach { $0.resume() }
    }

    func cancel() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancelled = true
            paused = false
            let result = waiters.map(\.continuation)
            waiters.removeAll(keepingCapacity: false)
            return result
        }
        continuations.forEach { $0.resume() }
    }

    func updatePlaybackPosition(
        _ position: TimeInterval,
        isPlaying: Bool,
        rate: Double
    ) {
        let safePosition = max(0, position.isFinite ? position : 0)
        let safeRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            playbackPosition = safePosition
            playbackRate = safeRate
            self.isPlaying = isPlaying
            guard !cancelled, !paused, isPlaying else { return [] }
            return takeReadyWaitersLocked()
        }
        continuations.forEach { $0.resume() }
    }

    /// Wait until secondary analysis fits inside the current audio-first budget.
    /// Callers should invoke this before opening a source and again while PCM is
    /// consumed so waiting naturally back-pressures networking, decode and DSP.
    func waitUntilReady(
        analysisPosition: TimeInterval,
        sourceDuration: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if cancelled { return true }
                if canRunLocked(
                    analysisPosition: analysisPosition,
                    sourceDuration: sourceDuration
                ) {
                    return true
                }
                waiters.append(Waiter(
                    analysisPosition: analysisPosition,
                    sourceDuration: sourceDuration,
                    continuation: continuation
                ))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
        return lock.withLock { !cancelled }
    }

    /// Pure policy seam shared with unit tests.
    static func analysisMayRun(
        playbackPosition: TimeInterval,
        analysisPosition: TimeInterval,
        sourceDuration: TimeInterval,
        playbackRate: Double
    ) -> Bool {
        let safePlayback = max(0, playbackPosition.isFinite ? playbackPosition : 0)
        let safeAnalysis = max(0, analysisPosition.isFinite ? analysisPosition : 0)
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        let safeRate = min(max(playbackRate.isFinite ? playbackRate : 1, 0.5), 2)

        let trackNearlyFinished = safeDuration > 0
            && safePlayback >= max(0, safeDuration - 0.25)
        guard safePlayback >= startupGraceSeconds || trackNearlyFinished else {
            return false
        }

        let leadBudget = maximumLeadSeconds * max(1, safeRate)
        let analysisLimit = safePlayback + leadBudget
        let boundedLimit = safeDuration > 0 ? min(safeDuration, analysisLimit) : analysisLimit
        return safeAnalysis <= boundedLimit + 0.001
    }

    private func canRunLocked(
        analysisPosition: TimeInterval,
        sourceDuration: TimeInterval
    ) -> Bool {
        guard !cancelled, !paused, isPlaying else { return false }
        return Self.analysisMayRun(
            playbackPosition: playbackPosition,
            analysisPosition: analysisPosition,
            sourceDuration: sourceDuration,
            playbackRate: playbackRate
        )
    }

    private func takeReadyWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        guard !waiters.isEmpty else { return [] }
        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [Waiter] = []
        pending.reserveCapacity(waiters.count)
        for waiter in waiters {
            if canRunLocked(
                analysisPosition: waiter.analysisPosition,
                sourceDuration: waiter.sourceDuration
            ) {
                ready.append(waiter.continuation)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
        return ready
    }

    var diagnostics: (playbackPosition: TimeInterval, playbackRate: Double) {
        lock.withLock {
            (playbackPosition, playbackRate)
        }
    }
}
