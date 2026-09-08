// SPDX-License-Identifier: GPL-3.0-only
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
    public let hapticCommitHorizon: TimeInterval
    public private(set) var playbackPosition: TimeInterval = 0
    public private(set) var scheduledUntil: TimeInterval = 0
    public private(set) var rollingWindowCount: Int = 0
    public private(set) var isPlaying = false
    public private(set) var hapticDriftSeconds: TimeInterval = 0
    public private(set) var driftGuardBand: MusicHapticsDriftGuardBand = .stable
    public private(set) var currentEventSource: MusicHapticsEventSource = .none

    private var windows: [MusicHapticsAnalysisWindow] = []
    private var scheduledKeys: Set<String> = []
    private var sliceCursors: [String: TimeInterval] = [:]
    private let commitSlices: Bool
    private var lastClockPosition: TimeInterval?
    private var lastClockUptime: TimeInterval?
    private var lastClockRate: Double = 1
    private var hapticFlushRequested = false

    public init(
        hapticCommitHorizon: TimeInterval = 3
    ) {
        self.hapticCommitHorizon = min(max(hapticCommitHorizon, 2.5), 4)
        self.commitSlices = true
    }

    @discardableResult
    public func ingest(_ window: MusicHapticsAnalysisWindow) -> [MusicHapticsAnalysisWindow] {
        guard window.endTime > window.startTime else { return [] }
        // Realtime tap and original-stream lookahead intentionally overlap.
        // Keep one merged range for every overlap so a late lookahead window
        // upgrades the source without replaying already committed realtime
        // events. The slice cursor is carried to the merged key.
        var mergedWindow = window
        var replacementCursor: TimeInterval?
        var replacementWasScheduled = false
        var mergedKeys: Set<String> = []
        for existing in windows where rangesOverlap(existing, window) {
            let existingKey = key(for: existing)
            mergedKeys.insert(existingKey)
            if let cursor = sliceCursors[existingKey] {
                replacementCursor = max(replacementCursor ?? existing.startTime, cursor)
            }
            replacementWasScheduled = replacementWasScheduled || scheduledKeys.contains(existingKey)
            scheduledKeys.remove(existingKey)
            sliceCursors.removeValue(forKey: existingKey)
            mergedWindow = merge(existing, mergedWindow)
        }
        windows.removeAll { mergedKeys.contains(key(for: $0)) }
        windows.append(mergedWindow)
        windows.sort { $0.startTime < $1.startTime }
        if commitSlices, let replacementCursor {
            sliceCursors[key(for: mergedWindow)] = min(
                mergedWindow.endTime,
                max(mergedWindow.startTime, replacementCursor)
            )
        } else if !commitSlices, replacementWasScheduled {
            // Legacy whole-window callers have already received this range;
            // retain that fact after changing its source/range key.
            scheduledKeys.insert(key(for: mergedWindow))
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
        currentEventSource = .none
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
        let commitUpperBound = playbackPosition + hapticCommitHorizon
        var scheduled: [MusicHapticsAnalysisWindow] = []
        for window in windows where window.endTime > playbackPosition
            && (!commitSlices || window.startTime < commitUpperBound) {
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
            // `scheduledUntil` describes haptic output handed to the output
            // engine, not an analysis interval that happened to contain no
            // events.  Keep advancing the cursor through quiet material, but
            // do not claim a silent slice was committed.
            if !slice.events.isEmpty {
                scheduledUntil = max(scheduledUntil, sliceEnd)
                scheduled.append(slice)
            }
        }
        updateCurrentEventSource(from: scheduled)
        return scheduled
    }

    private func purgePastWindows() {
        windows.removeAll { $0.endTime <= playbackPosition }
        rollingWindowCount = windows.count
        let liveKeys = Set(windows.map { key(for: $0) })
        scheduledKeys = scheduledKeys.filter { liveKeys.contains($0) }
        sliceCursors = sliceCursors.filter { liveKeys.contains($0.key) }
        if scheduledUntil < playbackPosition { scheduledUntil = playbackPosition }
        if windows.isEmpty { currentEventSource = .none }
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

    private func rangesOverlap(
        _ lhs: MusicHapticsAnalysisWindow,
        _ rhs: MusicHapticsAnalysisWindow
    ) -> Bool {
        lhs.startTime < rhs.endTime - 0.001
            && rhs.startTime < lhs.endTime - 0.001
    }

    private func merge(
        _ lhs: MusicHapticsAnalysisWindow,
        _ rhs: MusicHapticsAnalysisWindow
    ) -> MusicHapticsAnalysisWindow {
        let sourceMode: MusicHapticsAnalysisMode = if lhs.sourceMode == .remoteOriginal || rhs.sourceMode == .remoteOriginal {
            .remoteOriginal
        } else if lhs.sourceMode == .realtimeTap || rhs.sourceMode == .realtimeTap {
            .realtimeTap
        } else {
            .local
        }
        let lhsIsRemote = lhs.sourceMode == .remoteOriginal
        let rhsIsRemote = rhs.sourceMode == .remoteOriginal
        let events: [MusicHapticsEvent]
        if lhsIsRemote && !rhsIsRemote {
            // A realtime event that overlaps a reliable original-stream
            // window is a backup copy, not a second pulse. Keep realtime only
            // outside the remote-covered interval.
            events = MusicHapticsEventDeduplicator.merge(
                lhs.events + rhs.events.filter { !overlaps($0, lhs.startTime..<lhs.endTime) }
            )
        } else if rhsIsRemote && !lhsIsRemote {
            events = MusicHapticsEventDeduplicator.merge(
                rhs.events + lhs.events.filter { !overlaps($0, rhs.startTime..<rhs.endTime) }
            )
        } else {
            events = MusicHapticsEventDeduplicator.merge(lhs.events + rhs.events)
        }
        return MusicHapticsAnalysisWindow(
            startTime: min(lhs.startTime, rhs.startTime),
            endTime: max(lhs.endTime, rhs.endTime),
            analysisPosition: max(lhs.analysisPosition, rhs.analysisPosition),
            events: events,
            coverage: max(lhs.coverage, rhs.coverage),
            analysisSpeedX: max(lhs.analysisSpeedX, rhs.analysisSpeedX),
            tempoBPM: rhs.tempoBPM ?? lhs.tempoBPM,
            beatConfidence: max(lhs.beatConfidence, rhs.beatConfidence),
            sourceMode: sourceMode,
            eventCount: max(lhs.eventCount, rhs.eventCount),
            transientCount: max(lhs.transientCount, rhs.transientCount),
            continuousCount: max(lhs.continuousCount, rhs.continuousCount),
            mixerDiagnostics: rhs.mixerDiagnostics
        )
    }

    private func overlaps(
        _ event: MusicHapticsEvent,
        _ range: Range<TimeInterval>
    ) -> Bool {
        let eventEnd = event.time + (event.duration ?? 0)
        if event.kind == .transient {
            return event.time >= range.lowerBound && event.time < range.upperBound
        }
        return eventEnd > range.lowerBound && event.time < range.upperBound
    }

    private func updateCurrentEventSource(from scheduled: [MusicHapticsAnalysisWindow]) {
        let sources = Set(scheduled.map { window -> MusicHapticsEventSource in
            switch window.sourceMode {
            case .remoteOriginal: return .remoteOriginal
            case .realtimeTap: return .realtimeTap
            case .local: return .none
            }
        }.filter { $0 != .none })
        switch sources.count {
        case 0: break
        case 1: currentEventSource = sources.first ?? .none
        default: currentEventSource = .mixed
        }
    }
}
