import Foundation

/// Schedules bounded future slices against the AVPlayer clock supplied by
/// AppShell. Analysis can run ahead, but production commits only a small
/// horizon to Core Haptics so pause/seek/buffering can rebase cleanly.
public enum MusicHapticsDriftGuardBand: String, Sendable, Equatable {
    case stable
    case rebase
    case flush
}

@MainActor
public final class RollingMusicHapticsScheduler {
    public let analysisLeadTarget: TimeInterval
    public let hapticCommitHorizon: TimeInterval
    public var targetLead: TimeInterval { analysisLeadTarget }
    public var schedulingHorizon: TimeInterval { analysisLeadTarget }
    public private(set) var playbackPosition: TimeInterval = 0
    public private(set) var scheduledUntil: TimeInterval = 0
    public private(set) var rollingWindowCount: Int = 0
    public private(set) var isPlaying = false
    public private(set) var hapticDriftSeconds: TimeInterval = 0
    public private(set) var driftGuardBand: MusicHapticsDriftGuardBand = .stable

    private var windows: [MusicHapticsAnalysisWindow] = []
    private var scheduledKeys: Set<String> = []
    private var sliceCursors: [String: TimeInterval] = [:]
    private let commitSlices: Bool
    private var lastClockPosition: TimeInterval?
    private var lastClockUptime: TimeInterval?
    private var lastClockRate: Double = 1
    private var hapticFlushRequested = false

    public init(
        targetLead: TimeInterval = 8,
        schedulingHorizon: TimeInterval = 18
    ) {
        self.analysisLeadTarget = max(0.5, targetLead)
        self.hapticCommitHorizon = max(0.5, schedulingHorizon)
        self.commitSlices = false
    }

    public init(
        analysisLeadTarget: TimeInterval = 10,
        hapticCommitHorizon: TimeInterval = 3
    ) {
        self.analysisLeadTarget = min(max(analysisLeadTarget, 8), 20)
        self.hapticCommitHorizon = min(max(hapticCommitHorizon, 2.5), 4)
        self.commitSlices = true
    }

    @discardableResult
    public func ingest(_ window: MusicHapticsAnalysisWindow) -> [MusicHapticsAnalysisWindow] {
        guard window.endTime > window.startTime else { return [] }
        // A late progress callback may replace a window with the same start
        // time but a longer end time.  Its old key must be released or the
        // corrected window would remain permanently marked as scheduled.
        var replacementCursor: TimeInterval?
        for existing in windows where abs(existing.startTime - window.startTime) < 0.001 {
            let existingKey = key(for: existing)
            if let cursor = sliceCursors[existingKey] {
                replacementCursor = max(replacementCursor ?? existing.startTime, cursor)
            }
            scheduledKeys.remove(existingKey)
            sliceCursors.removeValue(forKey: existingKey)
        }
        windows.removeAll { abs($0.startTime - window.startTime) < 0.001 }
        windows.append(window)
        windows.sort { $0.startTime < $1.startTime }
        if commitSlices, let replacementCursor {
            sliceCursors[key(for: window)] = min(window.endTime, max(window.startTime, replacementCursor))
        }
        rollingWindowCount = windows.count
        return pump()
    }

    @discardableResult
    public func updateClock(
        position: TimeInterval,
        isPlaying: Bool,
        rate: Double = 1
    ) -> [MusicHapticsAnalysisWindow] {
        let safePosition = max(0, position.isFinite ? position : playbackPosition)
        let safeRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        if safePosition + 0.15 < playbackPosition {
            // A seek/backward discontinuity invalidates all output already
            // handed to Core Haptics.  Keep decoded windows, but reschedule
            // only their future portion from the new player position.
            scheduledKeys.removeAll()
            sliceCursors.removeAll()
            scheduledUntil = safePosition
            hapticFlushRequested = true
            resetTimingAnchor()
            driftGuardBand = .flush
        } else if isPlaying {
            updateDrift(position: safePosition, rate: safeRate)
        } else {
            resetTimingAnchor()
            if self.isPlaying {
                // A direct paused/buffering clock update must invalidate the
                // already committed cursor as well; resume will rebase from
                // the next authoritative AVPlayer position.
                scheduledKeys.removeAll()
                sliceCursors.removeAll()
                scheduledUntil = safePosition
            }
        }
        playbackPosition = safePosition
        self.isPlaying = isPlaying
        purgePastWindows()
        return isPlaying ? pump() : []
    }

    public func pause() {
        isPlaying = false
        scheduledKeys.removeAll()
        sliceCursors.removeAll()
        scheduledUntil = playbackPosition
        resetTimingAnchor()
    }

    @discardableResult
    public func resume(position: TimeInterval, rate: Double = 1) -> [MusicHapticsAnalysisWindow] {
        resetTimingAnchor()
        playbackPosition = max(0, position)
        isPlaying = true
        lastClockPosition = playbackPosition
        lastClockUptime = ProcessInfo.processInfo.systemUptime
        lastClockRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        return pump()
    }

    @discardableResult
    public func seek(to position: TimeInterval, playing: Bool, rate: Double = 1) -> [MusicHapticsAnalysisWindow] {
        scheduledKeys.removeAll()
        sliceCursors.removeAll()
        scheduledUntil = max(0, position)
        playbackPosition = max(0, position)
        isPlaying = playing
        resetTimingAnchor()
        if playing {
            lastClockPosition = playbackPosition
            lastClockUptime = ProcessInfo.processInfo.systemUptime
            lastClockRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        }
        purgePastWindows()
        return playing ? pump() : []
    }

    public func stop() {
        isPlaying = false
        windows.removeAll()
        scheduledKeys.removeAll()
        sliceCursors.removeAll()
        scheduledUntil = 0
        rollingWindowCount = 0
        playbackPosition = 0
        resetTimingAnchor()
    }

    /// Test/diagnostic view of starts already handed to the output.  It does
    /// not expose URLs or any server-side information.
    public var scheduledWindowStarts: [TimeInterval] {
        windows.compactMap { window in
            let windowKey = key(for: window)
            if commitSlices {
                return (sliceCursors[windowKey] ?? window.startTime) > window.startTime
                    ? window.startTime
                    : nil
            }
            return scheduledKeys.contains(windowKey) ? window.startTime : nil
        }
    }

    /// Returns and clears the one-shot request to stop already-created Core
    /// Haptics players. A large clock error cannot be fixed by merely changing
    /// the next pattern's base; the coordinator must flush future players and
    /// then schedule from the current AVPlayer position.
    public func consumeHapticFlushRequest() -> Bool {
        defer { hapticFlushRequested = false }
        return hapticFlushRequested
    }

    private func pump() -> [MusicHapticsAnalysisWindow] {
        guard isPlaying else { return [] }
        let upperBound = playbackPosition + analysisLeadTarget
        var scheduled: [MusicHapticsAnalysisWindow] = []
        for window in windows where window.endTime > playbackPosition
            && window.startTime <= upperBound
            && window.analysisPosition > playbackPosition {
            let windowKey = key(for: window)
            if !commitSlices {
                guard scheduledKeys.insert(windowKey).inserted else { continue }
                scheduledUntil = max(scheduledUntil, window.endTime)
                scheduled.append(window)
                continue
            }
            let cursor = max(window.startTime, sliceCursors[windowKey] ?? window.startTime)
            let sliceStart = max(playbackPosition, cursor)
            let sliceEnd = min(window.endTime, playbackPosition + hapticCommitHorizon)
            guard sliceEnd > sliceStart else { continue }
            let slice = window.sliced(from: sliceStart, to: sliceEnd)
            sliceCursors[windowKey] = sliceEnd
            scheduledUntil = max(scheduledUntil, sliceEnd)
            if !slice.events.isEmpty { scheduled.append(slice) }
        }
        return scheduled
    }

    private func purgePastWindows() {
        windows.removeAll { $0.endTime <= playbackPosition }
        rollingWindowCount = windows.count
        let liveKeys = Set(windows.map { key(for: $0) })
        scheduledKeys = scheduledKeys.filter { liveKeys.contains($0) }
        sliceCursors = sliceCursors.filter { liveKeys.contains($0.key) }
        if scheduledUntil < playbackPosition { scheduledUntil = playbackPosition }
    }

    private func updateDrift(position: TimeInterval, rate: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        if let lastClockPosition,
           let lastClockUptime,
           uptime >= lastClockUptime,
           abs(rate - lastClockRate) <= 0.02 {
            let expected = lastClockPosition + (uptime - lastClockUptime) * lastClockRate
            let error = position - expected
            hapticDriftSeconds = abs(error)
            if hapticDriftSeconds > 0.080 {
                driftGuardBand = .flush
                scheduledKeys.removeAll()
                sliceCursors.removeAll()
                scheduledUntil = position
                hapticFlushRequested = true
            } else if hapticDriftSeconds > 0.030 {
                driftGuardBand = .rebase
            } else {
                driftGuardBand = .stable
            }
        } else {
            hapticDriftSeconds = 0
            driftGuardBand = .stable
        }
        lastClockPosition = position
        lastClockUptime = uptime
        lastClockRate = rate
    }

    private func resetTimingAnchor() {
        lastClockPosition = nil
        lastClockUptime = nil
        lastClockRate = 1
        hapticDriftSeconds = 0
        driftGuardBand = .stable
    }

    private func key(for window: MusicHapticsAnalysisWindow) -> String {
        String(format: "%.3f-%.3f", window.startTime, window.endTime)
    }
}
