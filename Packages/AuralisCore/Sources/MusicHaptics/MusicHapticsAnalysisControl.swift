import Foundation

/// Coordinates pause/resume for an independent decoder without coupling its
/// throughput to the authoritative playback clock. Analysis is deliberately
/// allowed to run to EOF as fast as the network/decoder/CPU permit; the
/// scheduler owns the short Core Haptics commit horizon separately.
final class MusicHapticsAnalysisControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var playbackPosition: TimeInterval = 0
    private var playbackRate: Double = 1
    private var isPlaying = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

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
            let result = waiters
            waiters.removeAll(keepingCapacity: true)
            return result
        }
        continuations.forEach { $0.resume() }
    }

    func cancel() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancelled = true
            paused = false
            let result = waiters
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
            guard !waiters.isEmpty else { return [] }
            let result = waiters
            waiters.removeAll(keepingCapacity: true)
            return result
        }
        continuations.forEach { $0.resume() }
    }

    /// Wait until analysis is allowed to continue. The position arguments are
    /// retained for source compatibility with the decoder loop, but are not a
    /// high-watermark gate: a lookahead decoder may be arbitrarily ahead of
    /// playback.
    func waitUntilReady(
        analysisPosition _: TimeInterval,
        sourceDuration _: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if cancelled { return true }
                if !paused, isPlaying {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
        return lock.withLock { !cancelled }
    }

    var diagnostics: (playbackPosition: TimeInterval, playbackRate: Double) {
        lock.withLock {
            (playbackPosition, playbackRate)
        }
    }
}
