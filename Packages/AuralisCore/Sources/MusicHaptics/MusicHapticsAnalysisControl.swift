import Foundation

/// Coordinates pause/resume and bounded lookahead without blocking a worker
/// thread. A sidecar may decode ahead, but it must stop once it reaches a
/// bounded distance from the authoritative playback clock.
final class MusicHapticsAnalysisControl: @unchecked Sendable {
    private let lock = NSLock()
    private let highWatermark: TimeInterval
    private var paused = false
    private var cancelled = false
    private var playbackPosition: TimeInterval = 0
    private var playbackRate: Double = 1
    private var isPlaying = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(highWatermark: TimeInterval = 20) {
        self.highWatermark = max(1, highWatermark)
    }

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

    /// Wait until analysis is allowed to continue. The source duration makes
    /// the final tail exempt from the high-watermark gate.
    func waitUntilReady(
        analysisPosition: TimeInterval,
        sourceDuration: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if cancelled { return true }
                let reachedEnd = analysisPosition >= sourceDuration - 0.001
                let withinWatermark = analysisPosition <= playbackPosition + highWatermark
                if !paused, isPlaying, (reachedEnd || withinWatermark) {
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

    var diagnostics: (playbackPosition: TimeInterval, playbackRate: Double, highWatermark: TimeInterval) {
        lock.withLock {
            (playbackPosition, playbackRate, highWatermark)
        }
    }
}
