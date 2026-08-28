import Foundation

/// Schedules complete future windows against the AVPlayer clock supplied by
/// AppShell.  It never creates a per-event timer: one clock update pumps a
/// bounded set of non-overlapping windows, and the haptics output schedules the
/// events inside each window relative to the same authoritative position.
@MainActor
public final class RollingMusicHapticsScheduler {
    public let targetLead: TimeInterval
    public let schedulingHorizon: TimeInterval
    public private(set) var playbackPosition: TimeInterval = 0
    public private(set) var scheduledUntil: TimeInterval = 0
    public private(set) var rollingWindowCount: Int = 0
    public private(set) var isPlaying = false

    private var windows: [MusicHapticsAnalysisWindow] = []
    private var scheduledKeys: Set<String> = []

    public init(
        targetLead: TimeInterval = 8,
        schedulingHorizon: TimeInterval = 18
    ) {
        self.targetLead = max(0.5, targetLead)
        self.schedulingHorizon = max(self.targetLead, schedulingHorizon)
    }

    @discardableResult
    public func ingest(_ window: MusicHapticsAnalysisWindow) -> [MusicHapticsAnalysisWindow] {
        guard window.endTime > window.startTime else { return [] }
        // A late progress callback may replace a window with the same start
        // time but a longer end time.  Its old key must be released or the
        // corrected window would remain permanently marked as scheduled.
        for existing in windows where abs(existing.startTime - window.startTime) < 0.001 {
            scheduledKeys.remove(key(for: existing))
        }
        windows.removeAll { abs($0.startTime - window.startTime) < 0.001 }
        windows.append(window)
        windows.sort { $0.startTime < $1.startTime }
        rollingWindowCount = windows.count
        return pump()
    }

    @discardableResult
    public func updateClock(position: TimeInterval, isPlaying: Bool) -> [MusicHapticsAnalysisWindow] {
        let safePosition = max(0, position.isFinite ? position : playbackPosition)
        if safePosition + 0.15 < playbackPosition {
            // A seek/backward discontinuity invalidates all output already
            // handed to Core Haptics.  Keep decoded windows, but reschedule
            // only their future portion from the new player position.
            scheduledKeys.removeAll()
            scheduledUntil = safePosition
        }
        playbackPosition = safePosition
        self.isPlaying = isPlaying
        purgePastWindows()
        return isPlaying ? pump() : []
    }

    public func pause() {
        isPlaying = false
        scheduledKeys.removeAll()
        scheduledUntil = playbackPosition
    }

    @discardableResult
    public func resume(position: TimeInterval) -> [MusicHapticsAnalysisWindow] {
        playbackPosition = max(0, position)
        isPlaying = true
        return pump()
    }

    @discardableResult
    public func seek(to position: TimeInterval, playing: Bool) -> [MusicHapticsAnalysisWindow] {
        scheduledKeys.removeAll()
        scheduledUntil = max(0, position)
        playbackPosition = max(0, position)
        isPlaying = playing
        purgePastWindows()
        return playing ? pump() : []
    }

    public func stop() {
        isPlaying = false
        windows.removeAll()
        scheduledKeys.removeAll()
        scheduledUntil = 0
        rollingWindowCount = 0
        playbackPosition = 0
    }

    /// Test/diagnostic view of starts already handed to the output.  It does
    /// not expose URLs or any server-side information.
    public var scheduledWindowStarts: [TimeInterval] {
        windows.filter { scheduledKeys.contains(key(for: $0)) }.map(\.startTime)
    }

    private func pump() -> [MusicHapticsAnalysisWindow] {
        guard isPlaying else { return [] }
        let upperBound = playbackPosition + schedulingHorizon
        var scheduled: [MusicHapticsAnalysisWindow] = []
        for window in windows where window.endTime > playbackPosition
            && window.startTime <= upperBound
            && window.analysisPosition > playbackPosition {
            let key = key(for: window)
            guard scheduledKeys.insert(key).inserted else { continue }
            scheduledUntil = max(scheduledUntil, window.endTime)
            scheduled.append(window)
        }
        return scheduled
    }

    private func purgePastWindows() {
        windows.removeAll { $0.endTime <= playbackPosition }
        rollingWindowCount = windows.count
        scheduledKeys = scheduledKeys.filter { key in
            windows.contains { self.key(for: $0) == key }
        }
        if scheduledUntil < playbackPosition { scheduledUntil = playbackPosition }
    }

    private func key(for window: MusicHapticsAnalysisWindow) -> String {
        String(format: "%.3f-%.3f", window.startTime, window.endTime)
    }
}
