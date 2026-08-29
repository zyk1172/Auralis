import Foundation
import OSLog

#if os(iOS)
import CoreHaptics
import MediaAccessibility
import UIKit
#endif

private let musicHapticsLogger = Logger(subsystem: "com.auralis.player", category: "Playback")

/// Values exposed by the in-app diagnostic screen. Deliberately excludes
/// URLs, server names and any authentication material.
public struct MusicHapticsDiagnostics: Sendable, Equatable {
    public var supportsCustomHaptics: Bool
    public var systemMusicHapticsActive: Bool
    public var globalEnabled: Bool
    public var trackPreference: TrackHapticsPreference
    public var effectiveEnabled: Bool
    public var source: MusicHapticsSource
    public var hasReliableISRC: Bool
    public var analysisState: String
    public var coverage: Double?
    public var timelineExists: Bool
    public var playbackPlan: MusicHapticsPlanKind
    public var planReason: String
    public var systemTimelineAvailable: Bool
    public var fullTimelineExists: Bool
    public var partialExists: Bool
    public var tapAttached: Bool
    public var pcmFormat: MusicHapticsPCMFormat?
    public var analyzedRanges: [MusicHapticsTimeRange]
    public var eventCount: Int
    public var eventDensity: Double?
    public var droppedFrames: Int
    public var finishReason: MusicHapticsAnalysisFinishReason?
    public var timelineSuspiciouslySparse: Bool
    public var analysisMode: MusicHapticsAnalysisMode
    public var analysisStreamBitrate: Int?
    public var playbackPosition: TimeInterval
    public var analysisPosition: TimeInterval
    public var analysisLeadSeconds: TimeInterval
    public var analysisSpeedX: Double
    public var lookaheadTarget: TimeInterval
    public var scheduledUntil: TimeInterval
    public var rollingWindowCount: Int
    public var beatConfidence: Double
    public var tempoBPM: Double?
    public var transientCount: Int
    public var continuousCount: Int
    public var dominantTransientCount: Int
    public var suppressedTransientCount: Int
    public var suppressedHighPercussionCount: Int
    public var mergedCollisionCount: Int
    public var activeTextureType: MusicHapticsEventClass?
    public var continuousDutyCycle: Double
    public var perceptualEventsPerSecond: Double
    public var fatigueGain: Double
    public var beatGridConfidence: Double
    public var beatGridBPM: Double?
    public var beatPhaseError: Double
    public var hapticCommitHorizon: TimeInterval
    public var hapticDriftSeconds: TimeInterval
    public var driftGuardBand: MusicHapticsDriftGuardBand
    public var audioBuffering: Bool
    public var hapticEngineState: MusicHapticsEngineState
    public var applicationSuspended: Bool
    public var lastHapticStopReason: String?
    public var foregroundRecoveryCount: Int

    public init(
        supportsCustomHaptics: Bool,
        systemMusicHapticsActive: Bool,
        globalEnabled: Bool,
        trackPreference: TrackHapticsPreference,
        effectiveEnabled: Bool,
        source: MusicHapticsSource,
        hasReliableISRC: Bool,
        analysisState: String = "unknown",
        coverage: Double? = nil,
        timelineExists: Bool = false,
        playbackPlan: MusicHapticsPlanKind = .disabled,
        planReason: String = "unknown",
        systemTimelineAvailable: Bool = false,
        fullTimelineExists: Bool = false,
        partialExists: Bool = false,
        tapAttached: Bool = false,
        pcmFormat: MusicHapticsPCMFormat? = nil,
        analyzedRanges: [MusicHapticsTimeRange] = [],
        eventCount: Int = 0,
        eventDensity: Double? = nil,
        droppedFrames: Int = 0,
        finishReason: MusicHapticsAnalysisFinishReason? = nil,
        timelineSuspiciouslySparse: Bool = false,
        analysisMode: MusicHapticsAnalysisMode = .realtimeTap,
        analysisStreamBitrate: Int? = nil,
        playbackPosition: TimeInterval = 0,
        analysisPosition: TimeInterval = 0,
        analysisLeadSeconds: TimeInterval = 0,
        analysisSpeedX: Double = 0,
        lookaheadTarget: TimeInterval = 8,
        scheduledUntil: TimeInterval = 0,
        rollingWindowCount: Int = 0,
        beatConfidence: Double = 0,
        tempoBPM: Double? = nil,
        transientCount: Int = 0,
        continuousCount: Int = 0,
        dominantTransientCount: Int = 0,
        suppressedTransientCount: Int = 0,
        suppressedHighPercussionCount: Int = 0,
        mergedCollisionCount: Int = 0,
        activeTextureType: MusicHapticsEventClass? = nil,
        continuousDutyCycle: Double = 0,
        perceptualEventsPerSecond: Double = 0,
        fatigueGain: Double = 1,
        beatGridConfidence: Double = 0,
        beatGridBPM: Double? = nil,
        beatPhaseError: Double = 1,
        hapticCommitHorizon: TimeInterval = 3,
        hapticDriftSeconds: TimeInterval = 0,
        driftGuardBand: MusicHapticsDriftGuardBand = .stable,
        audioBuffering: Bool = false,
        hapticEngineState: MusicHapticsEngineState = .notCreated,
        applicationSuspended: Bool = false,
        lastHapticStopReason: String? = nil,
        foregroundRecoveryCount: Int = 0
    ) {
        self.supportsCustomHaptics = supportsCustomHaptics
        self.systemMusicHapticsActive = systemMusicHapticsActive
        self.globalEnabled = globalEnabled
        self.trackPreference = trackPreference
        self.effectiveEnabled = effectiveEnabled
        self.source = source
        self.hasReliableISRC = hasReliableISRC
        self.analysisState = analysisState
        self.coverage = coverage
        self.timelineExists = timelineExists || fullTimelineExists
        self.playbackPlan = playbackPlan
        self.planReason = planReason
        self.systemTimelineAvailable = systemTimelineAvailable
        self.fullTimelineExists = fullTimelineExists || timelineExists
        self.partialExists = partialExists
        self.tapAttached = tapAttached
        self.pcmFormat = pcmFormat
        self.analyzedRanges = analyzedRanges
        self.eventCount = max(0, eventCount)
        self.eventDensity = eventDensity
        self.droppedFrames = max(0, droppedFrames)
        self.finishReason = finishReason
        self.timelineSuspiciouslySparse = timelineSuspiciouslySparse
        self.analysisMode = analysisMode
        self.analysisStreamBitrate = analysisStreamBitrate.map { max(1, $0) }
        self.playbackPosition = max(0, playbackPosition)
        self.analysisPosition = max(0, analysisPosition)
        self.analysisLeadSeconds = analysisLeadSeconds
        self.analysisSpeedX = max(0, analysisSpeedX)
        self.lookaheadTarget = max(0, lookaheadTarget)
        self.scheduledUntil = max(0, scheduledUntil)
        self.rollingWindowCount = max(0, rollingWindowCount)
        self.beatConfidence = min(max(beatConfidence, 0), 1)
        self.tempoBPM = tempoBPM
        self.transientCount = max(0, transientCount)
        self.continuousCount = max(0, continuousCount)
        self.dominantTransientCount = max(0, dominantTransientCount)
        self.suppressedTransientCount = max(0, suppressedTransientCount)
        self.suppressedHighPercussionCount = max(0, suppressedHighPercussionCount)
        self.mergedCollisionCount = max(0, mergedCollisionCount)
        self.activeTextureType = activeTextureType
        self.continuousDutyCycle = min(max(continuousDutyCycle, 0), 1)
        self.perceptualEventsPerSecond = max(0, perceptualEventsPerSecond)
        self.fatigueGain = min(max(fatigueGain, 0), 1)
        self.beatGridConfidence = min(max(beatGridConfidence, 0), 1)
        self.beatGridBPM = beatGridBPM
        self.beatPhaseError = min(max(beatPhaseError, 0), 1)
        self.hapticCommitHorizon = max(0, hapticCommitHorizon)
        self.hapticDriftSeconds = max(0, hapticDriftSeconds)
        self.driftGuardBand = driftGuardBand
        self.audioBuffering = audioBuffering
        self.hapticEngineState = hapticEngineState
        self.applicationSuspended = applicationSuspended
        self.lastHapticStopReason = lastHapticStopReason
        self.foregroundRecoveryCount = max(0, foregroundRecoveryCount)
    }
}

public enum MusicHapticsEngineState: String, Sendable, Equatable {
    case notCreated
    case running
    case stopped
    case needsRestart
}

/// Maps absolute track time into the real-time domain used by Core Haptics.
/// Keeping this arithmetic in one pure type prevents a playback-rate change
/// from being handled only by scheduler drift prediction while pattern event
/// times remain at 1.0x.
public enum MusicHapticsPlaybackTimeMapping {
    public static func relativeTime(
        trackTime: TimeInterval,
        playbackPosition: TimeInterval,
        playbackRate: Double
    ) -> TimeInterval {
        max(0, trackTime - playbackPosition) / safeRate(playbackRate)
    }

    public static func scaledDuration(
        _ trackDuration: TimeInterval,
        playbackRate: Double
    ) -> TimeInterval {
        max(0, trackDuration) / safeRate(playbackRate)
    }

    private static func safeRate(_ rate: Double) -> Double {
        min(max(rate.isFinite ? rate : 1, 0.5), 2)
    }
}

/// Product capability policy for Auralis Music Haptics.
///
/// Core Haptics may report a capability on more than one iOS form factor, but
/// the product feature is intentionally iPhone-only. Keeping this decision in
/// the MusicHaptics module makes the runtime, analysis sources and UI share
/// the same rule instead of each checking `os(iOS)` independently.
@MainActor
public enum MusicHapticsPlatformPolicy {
    public static var isFeatureAvailable: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

/// Pure ordering rule for the one authoritative playback plan. The resolver
/// has no AVFoundation dependency, so all branches can be regression
/// tested without a device or a haptics engine.
public enum MusicHapticsPlaybackPlanResolver {
    public static func resolve(
        featureEnabled: Bool,
        customHapticsSupported: Bool,
        systemTimelineAvailable: Bool,
        fullTimeline: MusicHapticsTimeline?,
        partial: MusicHapticsPartialCheckpoint?,
        request: MusicHapticsAnalysisRequest
    ) -> (plan: MusicHapticsPlaybackPlan, reason: String) {
        guard featureEnabled else { return (.disabled, "feature_disabled") }
        if systemTimelineAvailable { return (.system, "system_available") }
        guard customHapticsSupported else { return (.disabled, "custom_haptics_unavailable") }
        if let fullTimeline,
           fullTimeline.isComplete,
           fullTimeline.algorithmVersion == MusicHapticsTimeline.algorithmVersion,
           fullTimeline.duration.isFinite,
           fullTimeline.duration > 0,
           fullTimeline.identity.matchConfidence(with: request.identity) >= 0.82 {
            return (.custom(fullTimeline), "timeline_available")
        }
        guard request.duration > 0 else { return (.disabled, "invalid_duration") }
        let resolvedRequest = MusicHapticsAnalysisRequest(
            identity: request.identity,
            favorite: request.favorite,
            duration: request.duration,
            partial: partial,
            analysisSource: request.analysisSource,
            warmupDeadline: request.warmupDeadline
        )
        switch request.analysisSource {
        case .localFile, .remoteLookahead:
            return (.analyzeLookahead(resolvedRequest), partial == nil ? "no_timeline" : "resume_partial")
        case .realtimeTap:
            return (.analyze(resolvedRequest), partial == nil ? "no_timeline" : "resume_partial")
        }
    }
}

@MainActor
public final class SystemMusicHapticsAdapter {
    public init() {}

    public func availability(isrc: String?) async -> MusicHapticsSystemAvailability {
        let hasISRC = !(isrc?.isEmpty ?? true)
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else {
            return MusicHapticsSystemAvailability(
                hasISRC: hasISRC,
                active: false,
                timelineAvailable: false
            )
        }
        #if os(iOS)
        let manager = MAMusicHapticsManager.shared
        let active = manager.isActive
        guard hasISRC, active, let isrc else {
            return MusicHapticsSystemAvailability(
                hasISRC: hasISRC,
                active: active,
                timelineAvailable: false
            )
        }
        let available = await manager.isHapticTrackAvailable(forMediaMatching: isrc)
        return MusicHapticsSystemAvailability(
            hasISRC: true,
            active: active,
            timelineAvailable: available
        )
        #else
        return MusicHapticsSystemAvailability(
            hasISRC: hasISRC,
            active: false,
            timelineAvailable: false
        )
        #endif
    }

    public func canUseSystemTimeline(isrc: String?) async -> Bool {
        await availability(isrc: isrc).canUseTimeline
    }

    public var isActive: Bool {
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else { return false }
        #if os(iOS)
        return MAMusicHapticsManager.shared.isActive
        #else
        return false
        #endif
    }
}

@MainActor
final class CustomMusicHapticsEngine {
    private(set) var state: MusicHapticsEngineState = .notCreated
    private(set) var applicationSuspended = false
    private(set) var lastStopReason: String?
    private(set) var isInBackground = false

    #if os(iOS)
    private var engine: CHHapticEngine?
    private var players: [CHHapticAdvancedPatternPlayer] = []
    #endif

    var supportsHaptics: Bool {
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else { return false }
        #if os(iOS)
        return CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        return false
        #endif
    }

    func play(
        _ timeline: MusicHapticsTimeline,
        offset: TimeInterval,
        playbackRate: Double = 1
    ) throws {
        #if os(iOS)
        guard supportsHaptics else { return }
        let safeRate = min(max(playbackRate.isFinite ? playbackRate : 1, 0.5), 2)
        let engine = try prepareEngine()
        stop()
        let pattern = try makePattern(
            events: timeline.events,
            timeShift: 0,
            offset: 0,
            intensity: .medium,
            playbackRate: safeRate
        )
        let player = try engine.makeAdvancedPlayer(with: pattern)
        players = [player]
        try player.seek(toOffset: MusicHapticsPlaybackTimeMapping.relativeTime(
            trackTime: max(0, offset),
            playbackPosition: 0,
            playbackRate: safeRate
        ))
        try player.start(atTime: CHHapticTimeImmediate)
        #endif
    }

    /// Starts one non-overlapping future window.  The window is shifted by
    /// global event timestamps are translated once against `currentPosition`,
    /// so Core Haptics receives one future-relative pattern rather than a
    /// Timer per event.
    func play(
        _ window: MusicHapticsAnalysisWindow,
        from currentPosition: TimeInterval,
        intensity: MusicHapticsIntensity = .medium,
        playbackRate: Double = 1
    ) {
        #if os(iOS)
        guard supportsHaptics,
              !window.events.filter({ shouldKeep($0, intensity: intensity) }).isEmpty
        else { return }
        do {
            let safeRate = min(max(playbackRate.isFinite ? playbackRate : 1, 0.5), 2)
            let engine = try prepareEngine()
            let pattern = try makePattern(
                events: window.events,
                // Event timestamps are global track time. Translate them once
                // against the authoritative AVPlayer position; the window's
                // own start must not be added a second time.
                timeShift: 0,
                offset: max(0, currentPosition),
                intensity: intensity,
                playbackRate: safeRate
            )
            let player = try engine.makeAdvancedPlayer(with: pattern)
            if players.count >= 8 {
                let old = players.removeFirst()
                try? old.stop(atTime: CHHapticTimeImmediate)
            }
            players.append(player)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            stop()
            state = .stopped
            lastStopReason = String(describing: error)
        }
        #endif
    }

    func pause() {
        #if os(iOS)
        players.forEach { try? $0.pause(atTime: CHHapticTimeImmediate) }
        #endif
    }

    func resume(at offset: TimeInterval, playbackRate: Double = 1) {
        #if os(iOS)
        do {
            guard let player = players.last else { return }
            let safeRate = min(max(playbackRate.isFinite ? playbackRate : 1, 0.5), 2)
            try player.seek(toOffset: MusicHapticsPlaybackTimeMapping.relativeTime(
                trackTime: max(0, offset),
                playbackPosition: 0,
                playbackRate: safeRate
            ))
            try player.resume(atTime: CHHapticTimeImmediate)
        } catch {
            stop()
            state = .stopped
            lastStopReason = String(describing: error)
        }
        #endif
    }

    func seek(to offset: TimeInterval, playing: Bool, playbackRate: Double = 1) {
        #if os(iOS)
        do {
            guard let player = players.last else { return }
            let safeRate = min(max(playbackRate.isFinite ? playbackRate : 1, 0.5), 2)
            try player.seek(toOffset: MusicHapticsPlaybackTimeMapping.relativeTime(
                trackTime: max(0, offset),
                playbackPosition: 0,
                playbackRate: safeRate
            ))
            if playing { try player.resume(atTime: CHHapticTimeImmediate) }
        } catch {
            stop()
            state = .stopped
            lastStopReason = String(describing: error)
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        players.forEach { try? $0.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()
        #endif
    }

    /// Mark the lifecycle transition without preemptively stopping a running
    /// engine/player. iOS may suspend Core Haptics later; its stoppedHandler is
    /// the authority that records an actual suspension and requests recovery.
    func applicationDidEnterBackground() {
        isInBackground = true
    }

    /// iOS may suspend a custom haptic engine while audio continues. Recovery
    /// is deliberately foreground-only and uses the coordinator's current
    /// AVPlayer position to rebuild future output; it never starts haptics in
    /// the background or relies on private lifecycle workarounds.
    func restartIfNeeded() {
        isInBackground = false
        #if os(iOS)
        guard applicationSuspended || state == .needsRestart || state == .stopped else { return }
        guard engine != nil else {
            applicationSuspended = false
            return
        }
        do {
            _ = try prepareEngine()
            applicationSuspended = false
        } catch {
            state = .stopped
            lastStopReason = String(describing: error)
        }
        #else
        applicationSuspended = false
        #endif
    }

    #if os(iOS)
    private func parameters(
        for event: MusicHapticsEvent,
        intensity: MusicHapticsIntensity
    ) -> [CHHapticEventParameter] {
        let scaled: Float
        switch intensity {
        case .light:
            scaled = event.intensity * intensity.masterIntensity
        case .medium:
            scaled = event.intensity
        case .strong:
            scaled = min(0.92, 1 - (1 - event.intensity) / intensity.masterIntensity)
        }
        let textureScale = event.kind == .continuous ? intensity.continuousTextureScale : 1
        let effective = min(0.92, scaled * textureScale)
        return [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(effective, 0.88)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness),
        ]
    }

    private func shouldKeep(
        _ event: MusicHapticsEvent,
        intensity: MusicHapticsIntensity
    ) -> Bool {
        let floor = intensity.weakEventFloor
        switch event.classification {
        case .kick, .bassAttack, .snareClap, .climax:
            return event.intensity >= floor * 0.65
        case .highPercussion:
            return event.intensity >= (intensity == .light ? 0.48 : floor)
        case .sustainedBass, .buildTexture:
            return event.intensity >= (intensity == .light ? 0.30 : floor)
        case .unknown:
            return event.intensity >= floor
        }
    }

    private func makePattern(
        events: [MusicHapticsEvent],
        timeShift: TimeInterval,
        offset: TimeInterval,
        intensity: MusicHapticsIntensity,
        playbackRate: Double
    ) throws -> CHHapticPattern {
        let safeRate = min(max(playbackRate.isFinite ? playbackRate : 1, 0.5), 2)
        let selectedEvents = events.filter { shouldKeep($0, intensity: intensity) }
        let hapticEvents = selectedEvents.compactMap { event -> CHHapticEvent? in
            let eventEnd = event.time + (event.duration ?? 0)
            switch event.kind {
            case .transient:
                guard event.time >= offset else { return nil }
                let relativeTime = timeShift + MusicHapticsPlaybackTimeMapping.relativeTime(
                    trackTime: event.time,
                    playbackPosition: offset,
                    playbackRate: safeRate
                )
                guard relativeTime >= 0 else { return nil }
                return CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: parameters(for: event, intensity: intensity),
                    relativeTime: relativeTime
                )
            case .continuous:
                guard eventEnd > offset else { return nil }
                let segmentStart = max(offset, event.time)
                let relativeTime = timeShift + MusicHapticsPlaybackTimeMapping.relativeTime(
                    trackTime: segmentStart,
                    playbackPosition: offset,
                    playbackRate: safeRate
                )
                let duration = max(
                    0.02,
                    MusicHapticsPlaybackTimeMapping.scaledDuration(
                        eventEnd - segmentStart,
                        playbackRate: safeRate
                    )
                )
                guard relativeTime >= 0 else { return nil }
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: parameters(for: event, intensity: intensity),
                    relativeTime: relativeTime,
                    duration: duration
                )
            }
        }
        let curves = selectedEvents.flatMap { event -> [CHHapticParameterCurve] in
            guard event.kind == .continuous, event.curve.count >= 2 else { return [] }
            let eventEnd = event.time + (event.duration ?? 0)
            guard eventEnd > offset else { return [] }
            let segmentStart = max(offset, event.time)
            let trackDuration = max(0.02, eventEnd - segmentStart)
            let start = timeShift + MusicHapticsPlaybackTimeMapping.relativeTime(
                trackTime: segmentStart,
                playbackPosition: offset,
                playbackRate: safeRate
            )
            guard start >= 0 else { return [] }
            let curve = scaledCurve(
                for: event,
                trimOffset: max(0, segmentStart - event.time),
                duration: trackDuration
            )
            let intensityPoints = curve.map {
                CHHapticParameterCurve.ControlPoint(
                    relativeTime: MusicHapticsPlaybackTimeMapping.scaledDuration(
                        $0.timeOffset,
                        playbackRate: safeRate
                    ),
                    value: min(0.92, $0.intensity * intensity.masterIntensity * intensity.continuousTextureScale)
                )
            }
            let sharpnessPoints = curve.map {
                CHHapticParameterCurve.ControlPoint(
                    relativeTime: MusicHapticsPlaybackTimeMapping.scaledDuration(
                        $0.timeOffset,
                        playbackRate: safeRate
                    ),
                    value: $0.sharpness
                )
            }
            return [
                CHHapticParameterCurve(
                    parameterID: .hapticIntensityControl,
                    controlPoints: intensityPoints,
                    relativeTime: start
                ),
                CHHapticParameterCurve(
                    parameterID: .hapticSharpnessControl,
                    controlPoints: sharpnessPoints,
                    relativeTime: start
                ),
            ]
        }
        return try CHHapticPattern(events: hapticEvents, parameterCurves: curves)
    }

    private func scaledCurve(
        for event: MusicHapticsEvent,
        trimOffset: TimeInterval,
        duration: TimeInterval
    ) -> [MusicHapticsCurvePoint] {
        let source = event.curve.sorted { $0.timeOffset < $1.timeOffset }
        guard !source.isEmpty else {
            return [
                MusicHapticsCurvePoint(timeOffset: 0, intensity: event.intensity, sharpness: event.sharpness),
                MusicHapticsCurvePoint(timeOffset: duration, intensity: event.intensity, sharpness: event.sharpness),
            ]
        }
        let upperOffset = trimOffset + duration
        let start = interpolatedCurvePoint(source, at: trimOffset)
        let end = interpolatedCurvePoint(source, at: upperOffset)
        let interior = source.filter {
            $0.timeOffset > trimOffset + 0.0005
                && $0.timeOffset < upperOffset - 0.0005
        }
        var result = ([start] + interior + [end]).map {
            MusicHapticsCurvePoint(
                timeOffset: min(duration, max(0, $0.timeOffset - trimOffset)),
                intensity: $0.intensity,
                sharpness: $0.sharpness
            )
        }
        result.sort { $0.timeOffset < $1.timeOffset }
        var unique: [MusicHapticsCurvePoint] = []
        for point in result {
            if let last = unique.last,
               abs(last.timeOffset - point.timeOffset) <= 0.0005 {
                unique[unique.count - 1] = point
            } else {
                unique.append(point)
            }
        }
        return unique
    }

    private func interpolatedCurvePoint(
        _ points: [MusicHapticsCurvePoint],
        at offset: TimeInterval
    ) -> MusicHapticsCurvePoint {
        if offset <= points[0].timeOffset {
            return MusicHapticsCurvePoint(
                timeOffset: offset,
                intensity: points[0].intensity,
                sharpness: points[0].sharpness
            )
        }
        for pair in zip(points, points.dropFirst()) {
            let (lower, upper) = pair
            guard offset <= upper.timeOffset else { continue }
            let span = max(0.0001, upper.timeOffset - lower.timeOffset)
            let fraction = Float(min(1, max(0, (offset - lower.timeOffset) / span)))
            return MusicHapticsCurvePoint(
                timeOffset: offset,
                intensity: lower.intensity + (upper.intensity - lower.intensity) * fraction,
                sharpness: lower.sharpness + (upper.sharpness - lower.sharpness) * fraction
            )
        }
        let last = points[points.count - 1]
        return MusicHapticsCurvePoint(
            timeOffset: offset,
            intensity: last.intensity,
            sharpness: last.sharpness
        )
    }

    private func prepareEngine() throws -> CHHapticEngine {
        if let engine {
            if state != .running || applicationSuspended {
                try engine.start()
                state = .running
                applicationSuspended = false
            }
            return engine
        }
        let engine = try CHHapticEngine()
        engine.stoppedHandler = { [weak self] reasonValue in
            let reason = String(describing: reasonValue)
            Task { @MainActor in
                self?.players.removeAll()
                self?.lastStopReason = reason
                let normalized = reason.lowercased()
                self?.applicationSuspended = normalized.contains("suspend")
                self?.state = self?.applicationSuspended == true ? .needsRestart : .stopped
            }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in
                self?.lastStopReason = "reset"
                self?.state = .needsRestart
            }
        }
        try engine.start()
        self.engine = engine
        state = .running
        applicationSuspended = false
        isInBackground = false
        return engine
    }
    #endif
}

/// Preparation is created once before a player item is made. The engine only
/// consumes the already-resolved plan and sink; it never re-runs the decision.
@MainActor
public final class MusicHapticsPlaybackPreparation {
    public let id: UUID
    public let identity: MusicHapticsIdentity
    public let favorite: Bool
    public let plan: MusicHapticsPlaybackPlan
    public let reason: String
    public let systemAvailability: MusicHapticsSystemAvailability
    public let fullTimelineExists: Bool
    public let partialExists: Bool
    public let analysisSink: (any MusicHapticsAnalysisSink)?
    /// Created for lookahead plans but attached only after the sidecar fails.
    /// Keeping it separate prevents a successful lookahead path from paying
    /// for an AVAudioMix tap at all.
    public let realtimeFallbackSink: (any MusicHapticsAnalysisSink)?
    public let lookaheadAnalyzer: LookaheadMusicHapticsAnalyzer?

    public init(
        id: UUID = UUID(),
        identity: MusicHapticsIdentity,
        favorite: Bool,
        plan: MusicHapticsPlaybackPlan,
        reason: String,
        systemAvailability: MusicHapticsSystemAvailability,
        fullTimelineExists: Bool,
        partialExists: Bool,
        analysisSink: (any MusicHapticsAnalysisSink)?,
        realtimeFallbackSink: (any MusicHapticsAnalysisSink)? = nil,
        lookaheadAnalyzer: LookaheadMusicHapticsAnalyzer? = nil
    ) {
        self.id = id
        self.identity = identity
        self.favorite = favorite
        self.plan = plan
        self.reason = reason
        self.systemAvailability = systemAvailability
        self.fullTimelineExists = fullTimelineExists
        self.partialExists = partialExists
        self.analysisSink = analysisSink
        self.realtimeFallbackSink = realtimeFallbackSink
        self.lookaheadAnalyzer = lookaheadAnalyzer
    }
}

/// Owns exactly one haptic source for the current track. Failures stay inside
/// this component, while the PlaybackEngine remains the owner of audio.
@MainActor
public final class MusicHapticsCoordinator {
    public static let enabledDefaultsKey = "auralis.playback.musicHaptics.enabled"
    public private(set) var source: MusicHapticsSource = .none

    private let store: MusicHapticsStore
    private let system = SystemMusicHapticsAdapter()
    private let custom = CustomMusicHapticsEngine()
    private let rollingScheduler: RollingMusicHapticsScheduler
    private let defaults: UserDefaults
    private var analysisSourceProvider: (any MusicHapticsAnalysisSourceProvider)?
    private var realtimeFallbackHandler: ((UUID, any MusicHapticsAnalysisSink) -> Void)?
    private var realtimeFallbackPreparationID: UUID?
    private var failedLookaheadPreparationIDs: Set<UUID> = []
    private var preparedLookaheadPreparationIDs: Set<UUID> = []
    private var preparedLookaheadWindows: [UUID: [MusicHapticsAnalysisWindow]] = [:]
    private let maximumPreparedLookaheadWindows = 64
    private var currentIdentity: MusicHapticsIdentity?
    private var currentTimeline: MusicHapticsTimeline?
    private var currentPreparation: MusicHapticsPlaybackPreparation?
    private var activeAnalysisSink: (any MusicHapticsAnalysisSink)?
    private var currentFavorite = false
    private var currentPosition: TimeInterval = 0
    private var playbackRate: Double = 1
    private var playbackIsPlaying = false
    private var isInBackground = false
    private var audioBuffering = false
    private var foregroundRecoveryCount = 0
    private var currentPlan: MusicHapticsPlaybackPlan = .disabled
    private var currentPlanReason = "idle"
    private var currentSystemAvailability = MusicHapticsSystemAvailability(
        hasISRC: false,
        active: false,
        timelineAvailable: false
    )
    private var fullTimelineExists = false
    private var partialExists = false
    private var analysisSnapshot = MusicHapticsAnalysisSnapshot()
    private var warmupTask: Task<Void, Never>?
    /// Keeps a just-finished checkpoint visible while its actor-owned store
    /// write is in flight. This closes the rapid A→B→A race without making
    /// playback wait for disk I/O.
    private var inMemoryPartials: [String: MusicHapticsPartialCheckpoint] = [:]

    public init(
        store: MusicHapticsStore = MusicHapticsStore(),
        defaults: UserDefaults = .standard,
        analysisSourceProvider: (any MusicHapticsAnalysisSourceProvider)? = nil
    ) {
        self.store = store
        self.defaults = defaults
        self.analysisSourceProvider = analysisSourceProvider
        let policy = MusicHapticsAnalysisPerformancePolicy.current
        self.rollingScheduler = RollingMusicHapticsScheduler(
            analysisLeadTarget: policy.analysisLeadTarget,
            hapticCommitHorizon: policy.hapticCommitHorizon
        )
    }

    /// Installed by AppShell after its connector is constructed.  Keeping the
    /// provider at this boundary prevents MusicHaptics from importing or
    /// retaining OpenSubsonic credentials.
    public func setAnalysisSourceProvider(_ provider: (any MusicHapticsAnalysisSourceProvider)?) {
        analysisSourceProvider = provider
    }

    /// AppShell wires this to AVFoundationPlaybackEngine. The callback stays
    /// on MainActor and receives only an opaque sink, never a URL or token.
    public func setRealtimeFallbackHandler(
        _ handler: ((UUID, any MusicHapticsAnalysisSink) -> Void)?
    ) {
        realtimeFallbackHandler = handler
    }

    public var supportsHaptics: Bool {
        MusicHapticsPlatformPolicy.isFeatureAvailable && custom.supportsHaptics
    }

    /// Resolves system/custom/analyze exactly once and creates only the
    /// lightweight PCM sink for the analyze branch. It never opens a URL or
    /// waits for AVAsset metadata.
    public func preparePlayback(
        identity: MusicHapticsIdentity,
        favorite: Bool,
        duration: TimeInterval,
        playbackURL: URL? = nil
    ) async -> MusicHapticsPlaybackPreparation {
        let startedAt = ContinuousClock.now
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else {
            let systemAvailability = MusicHapticsSystemAvailability(
                hasISRC: identity.isrc != nil,
                active: false,
                timelineAvailable: false
            )
            let preparation = MusicHapticsPlaybackPreparation(
                identity: identity,
                favorite: favorite,
                plan: .disabled,
                reason: "platform_unsupported",
                systemAvailability: systemAvailability,
                fullTimelineExists: false,
                partialExists: false,
                analysisSink: nil
            )
            logPlan(
                identity: identity,
                plan: .disabled,
                reason: "platform_unsupported",
                systemAvailability: systemAvailability,
                fullTimelineExists: false,
                partialExists: false
            )
            return preparation
        }
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        let featureEnabled = preference.effective(
            globalEnabled: defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        )
        var systemAvailability = MusicHapticsSystemAvailability(
            hasISRC: identity.isrc != nil,
            active: false,
            timelineAvailable: false
        )
        var fullTimeline: MusicHapticsTimeline?
        var partial: MusicHapticsPartialCheckpoint?
        var analysisSource: MusicHapticsAnalysisSource = .realtimeTap

        if featureEnabled {
            systemAvailability = await system.availability(isrc: identity.isrc)
            if !systemAvailability.canUseTimeline {
                fullTimeline = try? await store.timeline(for: identity)
                if fullTimeline == nil {
                    partial = inMemoryPartial(for: identity)
                    if partial == nil {
                        partial = try? await store.partial(for: identity)
                    }
                    if let loadedPartial = partial, loadedPartial.isComplete {
                        let promoted = loadedPartial.timeline()
                        do {
                            try await store.store(promoted, favorite: favorite)
                            fullTimeline = promoted
                            if self.inMemoryPartials[loadedPartial.identity.stableKey] == loadedPartial {
                                self.inMemoryPartials.removeValue(forKey: loadedPartial.identity.stableKey)
                            }
                            partial = nil
                        } catch {
                            musicHapticsLogger.error(
                                "HAPTICS_PARTIAL_PROMOTE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
                            )
                        }
                    }
                }
            }
        }

        if featureEnabled,
           fullTimeline == nil,
           !systemAvailability.canUseTimeline,
           custom.supportsHaptics {
            analysisSource = await analysisSourceProvider?.source(
                for: identity,
                playbackURL: playbackURL
            ) ?? .realtimeTap
        }

        let request = MusicHapticsAnalysisRequest(
            identity: identity,
            favorite: favorite,
            duration: duration,
            partial: partial,
            analysisSource: analysisSource
        )
        let decision = MusicHapticsPlaybackPlanResolver.resolve(
            featureEnabled: featureEnabled,
            customHapticsSupported: custom.supportsHaptics,
            systemTimelineAvailable: systemAvailability.canUseTimeline,
            fullTimeline: fullTimeline,
            partial: partial,
            request: request
        )
        let preparationID = UUID()
        let analysisSink: (any MusicHapticsAnalysisSink)?
        let realtimeFallbackSink: (any MusicHapticsAnalysisSink)?
        let lookaheadAnalyzer: LookaheadMusicHapticsAnalyzer?
        switch decision.plan {
        case let .analyze(analysisRequest):
            analysisSink = StreamingMusicHapticsAnalyzer(
                identity: analysisRequest.identity,
                duration: analysisRequest.duration,
                partial: analysisRequest.partial,
                onResult: { [weak self] result in
                    Task { @MainActor [weak self] in
                        await self?.handleAnalysisResult(
                            result,
                            preparationID: preparationID,
                            favorite: analysisRequest.favorite
                        )
                    }
                },
                onProgress: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.currentPreparation?.id == preparationID
                        else { return }
                        self.acceptAnalysisSnapshot(snapshot)
                    }
                },
                onWindow: { [weak self] window in
                    Task { @MainActor [weak self] in
                        self?.acceptRealtimeWindow(window, preparationID: preparationID)
                    }
                }
            )
            realtimeFallbackSink = nil
            lookaheadAnalyzer = nil
        case let .analyzeLookahead(analysisRequest):
            analysisSink = nil
            realtimeFallbackSink = StreamingMusicHapticsAnalyzer(
                identity: analysisRequest.identity,
                duration: analysisRequest.duration,
                partial: analysisRequest.partial,
                onResult: { [weak self] result in
                    Task { @MainActor [weak self] in
                        await self?.handleAnalysisResult(
                            result,
                            preparationID: preparationID,
                            favorite: analysisRequest.favorite
                        )
                    }
                },
                onProgress: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.currentPreparation?.id == preparationID,
                              self.realtimeFallbackPreparationID == preparationID
                        else { return }
                        self.acceptAnalysisSnapshot(snapshot)
                    }
                },
                onWindow: { [weak self] window in
                    Task { @MainActor [weak self] in
                        self?.acceptRealtimeWindow(window, preparationID: preparationID)
                    }
                }
            )
            lookaheadAnalyzer = LookaheadMusicHapticsAnalyzer(
                identity: analysisRequest.identity,
                duration: analysisRequest.duration,
                partial: analysisRequest.partial,
                onWindow: { [weak self] window in
                    Task { @MainActor [weak self] in
                        self?.acceptLookaheadWindow(window, preparationID: preparationID)
                    }
                },
                onResult: { [weak self] result in
                    Task { @MainActor [weak self] in
                        await self?.handleAnalysisResult(
                            result,
                            preparationID: preparationID,
                            favorite: analysisRequest.favorite
                        )
                    }
                },
                onProgress: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.currentPreparation?.id == preparationID
                        else { return }
                        self.acceptAnalysisSnapshot(snapshot)
                    }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleLookaheadFailure(preparationID: preparationID, identity: identity)
                    }
                }
            )
        case .disabled, .system, .custom:
            analysisSink = nil
            realtimeFallbackSink = nil
            lookaheadAnalyzer = nil
        }

        let preparation = MusicHapticsPlaybackPreparation(
            id: preparationID,
            identity: identity,
            favorite: favorite,
            plan: decision.plan,
            reason: decision.reason,
            systemAvailability: systemAvailability,
            fullTimelineExists: fullTimeline != nil,
            partialExists: partial != nil,
            analysisSink: analysisSink,
            realtimeFallbackSink: realtimeFallbackSink,
            lookaheadAnalyzer: lookaheadAnalyzer
        )
        if decision.plan.kind == .analyzeLookahead {
            preparedLookaheadPreparationIDs.insert(preparationID)
        }
        let planMs = durationMs(startedAt.duration(to: .now))
        musicHapticsLogger.debug(
            "HAPTICS_PLAN_MS duration_ms=\(planMs, privacy: .public) track=\(self.diagnosticTrack(identity), privacy: .public)"
        )
        logPlan(
            identity: identity,
            plan: decision.plan,
            reason: decision.reason,
            systemAvailability: systemAvailability,
            fullTimelineExists: fullTimeline != nil,
            partialExists: partial != nil
        )
        return preparation
    }

    /// Starts the selected source after the audio player is already running.
    /// Interactive AVFoundation playback installs the preparation at this same
    /// boundary; prepared gapless items may already have their source running.
    /// This method never creates a second analyzer or changes the resolved plan.
    public func activate(
        _ preparation: MusicHapticsPlaybackPreparation,
        position: TimeInterval,
        rate: Double = 1
    ) {
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else {
            source = .none
            return
        }
        if currentPreparation?.id != preparation.id {
            activeAnalysisSink?.finishPartial(reason: .trackSwitch)
            currentPreparation?.lookaheadAnalyzer?.finishPartial(reason: .trackSwitch)
            if let oldID = currentPreparation?.id {
                if realtimeFallbackPreparationID != oldID {
                    currentPreparation?.realtimeFallbackSink?.cancel()
                }
                failedLookaheadPreparationIDs.remove(oldID)
            }
        }
        warmupTask?.cancel()
        warmupTask = nil
        custom.stop()
        rollingScheduler.stop()
        currentPreparation = preparation
        preparedLookaheadPreparationIDs.remove(preparation.id)
        currentIdentity = preparation.identity
        currentFavorite = preparation.favorite
        currentPosition = max(0, position)
        playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        playbackIsPlaying = true
        audioBuffering = false
        currentPlan = preparation.plan
        currentSystemAvailability = preparation.systemAvailability
        fullTimelineExists = preparation.fullTimelineExists
        partialExists = preparation.partialExists
        currentPlanReason = preparation.reason
        activeAnalysisSink = preparation.analysisSink
        realtimeFallbackPreparationID = nil
        currentTimeline = nil
        analysisSnapshot = initialSnapshot(for: preparation)
        let bufferedWindows = preparedLookaheadWindows.removeValue(forKey: preparation.id) ?? []

        switch preparation.plan {
        case .disabled:
            source = .none
        case .system:
            source = .system
        case let .custom(timeline):
            do {
                if !isInBackground {
                    try custom.play(
                        timeline,
                        offset: position,
                        playbackRate: playbackRate
                    )
                }
                currentTimeline = timeline
                source = .custom
            } catch {
                source = .none
                currentPlanReason = "custom_play_failed"
            }
        case let .analyzeLookahead(request):
            source = .analyzing
            if failedLookaheadPreparationIDs.remove(preparation.id) != nil {
                activateRealtimeFallback(preparation)
            } else {
                for window in bufferedWindows {
                    _ = rollingScheduler.ingest(window)
                }
                preparation.lookaheadAnalyzer?.start(source: request.analysisSource)
                startWarmupDeadline(preparation: preparation)
                pumpScheduler(position: position, isPlaying: true)
            }
        case .analyze:
            source = .analyzing
        }
    }

    /// Prepared next items may start decoding before they become current.  It
    /// is idempotent, so the active transition can call it again safely.
    public func startPreparedAnalysis(_ preparation: MusicHapticsPlaybackPreparation) {
        guard case let .analyzeLookahead(request) = preparation.plan else { return }
        preparation.lookaheadAnalyzer?.start(source: request.analysisSource)
    }

    /// Drops a prepared (not-current) analysis session when queue policy or a
    /// newer preparation replaces it. The engine owns item cleanup; this
    /// method only releases the sidecar's buffered windows/state.
    public func discardPreparedAnalysis(_ preparation: MusicHapticsPlaybackPreparation) {
        guard currentPreparation?.id != preparation.id else { return }
        preparedLookaheadPreparationIDs.remove(preparation.id)
        preparedLookaheadWindows.removeValue(forKey: preparation.id)
        failedLookaheadPreparationIDs.remove(preparation.id)
        // A prepared item may already have decoded useful PCM/lookahead. It
        // is being replaced, not invalidated; finish its sidecar so the
        // checkpoint is merged and persisted asynchronously.
        preparation.analysisSink?.finishPartial(reason: .preparationReplaced)
        preparation.realtimeFallbackSink?.cancel()
        preparation.lookaheadAnalyzer?.finishPartial(reason: .preparationReplaced)
    }

    /// Compatibility entry point for non-AV callers. The real AppModel uses
    /// `preparePlayback` + `activate` so the plan is installed before play.
    @available(*, deprecated, message: "Use preparePlayback(identity:favorite:duration:) and activate(_:position:)")
    public func begin(identity: MusicHapticsIdentity, sourceURL: URL?, favorite: Bool, position: TimeInterval) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preparation = await self.preparePlayback(
                identity: identity,
                favorite: favorite,
                duration: max(Double(identity.durationMilliseconds) / 1_000, 0)
            )
            self.activate(preparation, position: position)
        }
    }

    /// Compatibility helper retained for callers that only need a sink. The
    /// AppModel does not use it because it would hide the resolved plan.
    @available(*, deprecated, message: "Use preparePlayback(identity:favorite:duration:)")
    public func makeStreamingAnalysisSink(
        identity: MusicHapticsIdentity,
        favorite: Bool,
        duration: TimeInterval
    ) async -> (any MusicHapticsAnalysisSink)? {
        await preparePlayback(identity: identity, favorite: favorite, duration: duration).analysisSink
    }

    public func pause() {
        playbackIsPlaying = false
        if source == .custom || source == .analyzing { custom.pause() }
        activeAnalysisSink?.pause()
        if case .analyzeLookahead = currentPlan {
            rollingScheduler.pause()
            custom.stop()
        }
    }

    public func resume(position: TimeInterval, rate: Double = 1) {
        currentPosition = max(0, position)
        playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        playbackIsPlaying = true
        audioBuffering = false
        guard !isInBackground else { return }
        if source == .custom, let timeline = currentTimeline {
            custom.stop()
            do {
                try custom.play(
                    timeline,
                    offset: position,
                    playbackRate: playbackRate
                )
            } catch {
                source = .none
                currentPlanReason = "custom_resume_failed"
            }
        } else if source == .custom {
            custom.resume(at: position, playbackRate: playbackRate)
        } else if case .analyzeLookahead = currentPlan {
            let windows = rollingScheduler.resume(position: position, rate: playbackRate)
            if rollingScheduler.consumeHapticFlushRequest() { custom.stop() }
            playScheduledWindows(windows, position: position)
        } else if case .analyze = currentPlan {
            // Realtime tap events are timestamped against the player. Drop
            // any pattern built before the pause and let the next PCM window
            // repopulate future output.
            custom.stop()
        }
    }

    public func seek(position: TimeInterval, playing: Bool, rate: Double = 1) {
        currentPosition = max(0, position)
        playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        playbackIsPlaying = playing
        guard !isInBackground else { return }
        if source == .custom {
            custom.seek(
                to: position,
                playing: playing,
                playbackRate: playbackRate
            )
        } else if case .analyzeLookahead = currentPlan {
            custom.stop()
            let windows = rollingScheduler.seek(to: position, playing: playing, rate: playbackRate)
            playScheduledWindows(windows, position: position)
        } else if case .analyze = currentPlan {
            custom.stop()
            activeAnalysisSink?.seek(to: position)
        }
    }

    public func updatePlaybackPosition(
        _ position: TimeInterval,
        isPlaying: Bool,
        rate: Double = 1
    ) {
        let previousPosition = currentPosition
        currentPosition = max(0, position)
        let safeRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        let rateChanged = abs(safeRate - playbackRate) > 0.02
        playbackRate = safeRate
        playbackIsPlaying = isPlaying
        if isPlaying { audioBuffering = false }
        if currentPosition + 0.15 < previousPosition {
            custom.stop()
            activeAnalysisSink?.seek(to: currentPosition)
        }
        if rateChanged, !isInBackground, !audioBuffering {
            rebaseForPlaybackRateChange(position: currentPosition, isPlaying: isPlaying)
        }
        guard case .analyzeLookahead = currentPlan, !isInBackground else { return }
        pumpScheduler(position: currentPosition, isPlaying: isPlaying)
    }

    /// AVPlayer's waiting/stalled state is authoritative. Stop future custom
    /// output now; resume will rebase from the next AVPlayer position.
    public func buffering() {
        audioBuffering = true
        pause()
    }

    public func audioResumed(position: TimeInterval, rate: Double = 1) {
        audioBuffering = false
        resume(position: position, rate: rate)
    }

    /// Background suspension is an expected iOS lifecycle outcome for custom
    /// haptics. Preserve analysis/checkpoint state and stop handing out future
    /// scheduler windows, but leave an already-running Core Haptics player to
    /// the system instead of preemptively stopping it.
    public func applicationDidEnterBackground() {
        isInBackground = true
        custom.applicationDidEnterBackground()
        rollingScheduler.pause()
        activeAnalysisSink?.pause()
    }

    /// Rebase all future output from the authoritative AVPlayer position after
    /// the scene becomes active. A stopped custom engine is recreated only on
    /// this foreground path.
    public func applicationDidBecomeActive(
        position: TimeInterval,
        isPlaying: Bool,
        rate: Double = 1
    ) {
        isInBackground = false
        currentPosition = max(0, position)
        playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        playbackIsPlaying = isPlaying
        audioBuffering = false
        foregroundRecoveryCount += 1
        custom.restartIfNeeded()
        guard isPlaying else {
            custom.stop()
            rollingScheduler.updateClock(position: currentPosition, isPlaying: false)
            return
        }
        switch currentPlan {
        case let .custom(timeline):
            custom.stop()
            do {
                try custom.play(
                    timeline,
                    offset: currentPosition,
                    playbackRate: playbackRate
                )
                currentTimeline = timeline
                source = .custom
            } catch {
                currentTimeline = nil
                source = .none
                currentPlanReason = "foreground_custom_haptics_restart_failed"
            }
        case .analyzeLookahead:
            custom.stop()
            let windows = rollingScheduler.seek(to: currentPosition, playing: true, rate: playbackRate)
            playScheduledWindows(windows, position: currentPosition)
        case .analyze:
            custom.stop()
            activeAnalysisSink?.seek(to: currentPosition)
        case .disabled, .system:
            break
        }
    }

    public func playbackFailed() {
        finishPartial(reason: .playbackFailure)
    }

    /// Finishes the current sidecar without discarding incomplete work. A
    /// complete result is promoted; otherwise the checkpoint is persisted.
    public func finishPartial(reason: MusicHapticsAnalysisFinishReason) {
        activeAnalysisSink?.finishPartial(reason: reason)
        currentPreparation?.lookaheadAnalyzer?.finishPartial(reason: reason)
        if realtimeFallbackPreparationID == nil {
            currentPreparation?.realtimeFallbackSink?.cancel()
        }
        activeAnalysisSink = nil
        realtimeFallbackPreparationID = nil
        playbackIsPlaying = false
        failedLookaheadPreparationIDs.removeAll()
        if let currentID = currentPreparation?.id {
            preparedLookaheadPreparationIDs.remove(currentID)
            preparedLookaheadWindows.removeValue(forKey: currentID)
        }
        warmupTask?.cancel()
        warmupTask = nil
        rollingScheduler.stop()
        custom.stop()
        currentTimeline = nil
        source = .none
    }

    public func stop() {
        finishPartial(reason: .stopped)
        currentPreparation = nil
        currentTimeline = nil
        currentIdentity = nil
        currentPlan = .disabled
        currentPlanReason = "stopped"
        currentSystemAvailability = MusicHapticsSystemAvailability(
            hasISRC: false,
            active: false,
            timelineAvailable: false
        )
        fullTimelineExists = false
        partialExists = false
        analysisSnapshot = MusicHapticsAnalysisSnapshot()
    }

    public func setPreference(_ preference: TrackHapticsPreference) {
        guard let identity = currentIdentity else { return }
        Task { [weak self] in
            try? await self?.store.setPreference(preference, for: identity)
        }
    }

    public func setGlobalEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        guard !enabled else { return }
        finishPartial(reason: .stopped)
        currentPreparation = nil
        currentPlan = .disabled
        currentPlanReason = "feature_disabled"
        currentSystemAvailability = MusicHapticsSystemAvailability(
            hasISRC: currentIdentity?.isrc != nil,
            active: false,
            timelineAvailable: false
        )
        fullTimelineExists = false
        partialExists = false
        analysisSnapshot = MusicHapticsAnalysisSnapshot()
    }

    public func favoriteChanged(_ favorite: Bool, identity: MusicHapticsIdentity) {
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else { return }
        currentFavorite = favorite
        Task { try? await store.updateFavorite(favorite, for: identity) }
    }

    public func currentTrackFavoriteChanged(_ favorite: Bool) {
        guard let currentIdentity else { return }
        favoriteChanged(favorite, identity: currentIdentity)
    }

    public func clearTransientCache() async { try? await store.clearTransient() }
    public func usage() async -> MusicHapticsUsage { (try? await store.usage()) ?? MusicHapticsUsage() }

    public func reconcile(_ tracks: [MusicHapticsIdentity], authoritative: Bool) async {
        guard MusicHapticsPlatformPolicy.isFeatureAvailable else { return }
        try? await store.reconcile(with: tracks, authoritative: authoritative)
    }

    public func diagnostics() async -> MusicHapticsDiagnostics {
        let preference: TrackHapticsPreference
        if let currentIdentity {
            preference = (try? await store.preference(for: currentIdentity)) ?? .inherit
        } else {
            preference = .inherit
        }
        let globalEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        let currentCoverage: Double?
        let eventCount: Int
        let eventDensity: Double?
        let sparse: Bool
        let transientCount: Int
        let continuousCount: Int
        if let currentTimeline {
            currentCoverage = currentTimeline.analysisCoverage
            eventCount = currentTimeline.events.count
            eventDensity = currentTimeline.eventDensity
            sparse = currentTimeline.timelineSuspiciouslySparse
            transientCount = currentTimeline.events.filter { $0.kind == .transient }.count
            continuousCount = currentTimeline.events.filter { $0.kind == .continuous }.count
        } else if currentPlan.kind == .analyze || currentPlan.kind == .analyzeLookahead {
            currentCoverage = analysisSnapshot.coverage
            eventCount = analysisSnapshot.eventCount
            let duration = currentIdentity.map { Double($0.durationMilliseconds) / 1_000 } ?? 0
            eventDensity = duration > 0 ? Double(eventCount) / duration : nil
            sparse = duration > 120 && eventCount < max(8, Int(duration / 30))
            transientCount = analysisSnapshot.transientCount
            continuousCount = analysisSnapshot.continuousCount
        } else {
            currentCoverage = nil
            eventCount = 0
            eventDensity = nil
            sparse = false
            transientCount = 0
            continuousCount = 0
        }
        return MusicHapticsDiagnostics(
            supportsCustomHaptics: custom.supportsHaptics,
            systemMusicHapticsActive: currentSystemAvailability.active || system.isActive,
            globalEnabled: globalEnabled,
            trackPreference: preference,
            effectiveEnabled: preference.effective(globalEnabled: globalEnabled),
            source: source,
            hasReliableISRC: currentIdentity?.isrc != nil,
            analysisState: analysisState,
            coverage: currentCoverage,
            timelineExists: fullTimelineExists,
            playbackPlan: currentPlan.kind,
            planReason: currentPlanReason,
            systemTimelineAvailable: currentSystemAvailability.timelineAvailable,
            fullTimelineExists: fullTimelineExists,
            partialExists: partialExists,
            tapAttached: analysisSnapshot.tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat,
            analyzedRanges: analysisSnapshot.analyzedRanges,
            eventCount: eventCount == 0 ? analysisSnapshot.eventCount : eventCount,
            eventDensity: eventDensity,
            droppedFrames: analysisSnapshot.droppedFrames,
            finishReason: analysisSnapshot.finishReason,
            timelineSuspiciouslySparse: sparse,
            analysisMode: analysisSnapshot.analysisMode,
            analysisStreamBitrate: analysisSnapshot.analysisStreamBitrate,
            playbackPosition: currentPosition,
            analysisPosition: analysisSnapshot.analysisPosition,
            analysisLeadSeconds: analysisSnapshot.analysisPosition - currentPosition,
            analysisSpeedX: analysisSnapshot.analysisSpeedX,
            lookaheadTarget: rollingScheduler.analysisLeadTarget,
            scheduledUntil: rollingScheduler.scheduledUntil,
            rollingWindowCount: rollingScheduler.rollingWindowCount,
            beatConfidence: analysisSnapshot.beatConfidence,
            tempoBPM: analysisSnapshot.tempoBPM,
            transientCount: transientCount,
            continuousCount: continuousCount,
            dominantTransientCount: analysisSnapshot.mixerDiagnostics.dominantTransientCount,
            suppressedTransientCount: analysisSnapshot.mixerDiagnostics.suppressedTransientCount,
            suppressedHighPercussionCount: analysisSnapshot.mixerDiagnostics.suppressedHighPercussionCount,
            mergedCollisionCount: analysisSnapshot.mixerDiagnostics.mergedCollisionCount,
            activeTextureType: analysisSnapshot.mixerDiagnostics.activeTextureType,
            continuousDutyCycle: analysisSnapshot.mixerDiagnostics.continuousDutyCycle,
            perceptualEventsPerSecond: analysisSnapshot.mixerDiagnostics.perceptualEventsPerSecond,
            fatigueGain: analysisSnapshot.mixerDiagnostics.fatigueGain,
            beatGridConfidence: analysisSnapshot.mixerDiagnostics.beatGridConfidence,
            beatGridBPM: analysisSnapshot.mixerDiagnostics.beatGridBPM,
            beatPhaseError: analysisSnapshot.mixerDiagnostics.beatPhaseError,
            hapticCommitHorizon: rollingScheduler.hapticCommitHorizon,
            hapticDriftSeconds: rollingScheduler.hapticDriftSeconds,
            driftGuardBand: rollingScheduler.driftGuardBand,
            audioBuffering: audioBuffering,
            hapticEngineState: custom.state,
            applicationSuspended: custom.applicationSuspended,
            lastHapticStopReason: custom.lastStopReason,
            foregroundRecoveryCount: foregroundRecoveryCount
        )
    }

    private var analysisState: String {
        switch source {
        case .analyzing: "analyzing"
        case .custom, .system: "complete"
        case .none: custom.supportsHaptics ? "idle" : "unavailable"
        }
    }

    private func handleAnalysisResult(
        _ result: MusicHapticsAnalysisResult,
        preparationID: UUID,
        favorite: Bool
    ) async {
        // A failed lookahead emits one terminal remote result so already
        // decoded ranges can be checkpointed. Once the realtime fallback is
        // active, that stale remote result must not overwrite its diagnostics
        // or race the fallback checkpoint.
        if realtimeFallbackPreparationID == preparationID,
           result.snapshot.analysisMode == .remoteLookahead {
            return
        }
        let identity = result.checkpoint.identity
        let checkpointToPersist: MusicHapticsPartialCheckpoint
        if let existing = inMemoryPartials[identity.stableKey],
           existing.identity.matchConfidence(with: identity) >= 0.82 {
            checkpointToPersist = existing.merged(with: result.checkpoint)
        } else {
            checkpointToPersist = result.checkpoint
        }
        inMemoryPartials[identity.stableKey] = checkpointToPersist
        let completeTimeline = checkpointToPersist.isComplete ? checkpointToPersist.timeline() : nil
        var storedFull = false
        var storedPartial = false
        if let timeline = completeTimeline {
            do {
                try await store.store(timeline, favorite: favorite)
                if inMemoryPartials[identity.stableKey] == checkpointToPersist {
                    inMemoryPartials.removeValue(forKey: identity.stableKey)
                }
                storedFull = true
                musicHapticsLogger.debug(
                    "HAPTICS_TIMELINE_SAVED track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(timeline.analysisCoverage, privacy: .public) events=\(timeline.events.count, privacy: .public)"
                )
            } catch {
                musicHapticsLogger.error(
                    "HAPTICS_TIMELINE_SAVE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
                )
                // A complete promotion is still a checkpoint boundary. Keep
                // the result recoverable if the final timeline write fails.
                do {
                    try await store.storePartial(checkpointToPersist)
                    storedPartial = true
                    musicHapticsLogger.debug(
                        "HAPTICS_PARTIAL_SAVED track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(checkpointToPersist.coverage, privacy: .public) ranges=\(self.rangeDescription(checkpointToPersist.analyzedRanges), privacy: .public)"
                    )
                } catch {
                    musicHapticsLogger.error(
                        "HAPTICS_PARTIAL_SAVE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
                    )
                }
            }
        } else {
            do {
                try await store.storePartial(checkpointToPersist)
                if inMemoryPartials[identity.stableKey] == checkpointToPersist {
                    inMemoryPartials.removeValue(forKey: identity.stableKey)
                }
                storedPartial = true
                musicHapticsLogger.debug(
                    "HAPTICS_PARTIAL_SAVED track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(checkpointToPersist.coverage, privacy: .public) ranges=\(self.rangeDescription(checkpointToPersist.analyzedRanges), privacy: .public)"
                )
            } catch {
                musicHapticsLogger.error(
                    "HAPTICS_PARTIAL_SAVE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
                )
            }
        }

        let eventDensity = checkpointToPersist.duration > 0
            ? Double(checkpointToPersist.events.count) / checkpointToPersist.duration
            : 0
        let suspiciouslySparse = completeTimeline?.timelineSuspiciouslySparse
            ?? (checkpointToPersist.duration > 120
                && checkpointToPersist.events.count < max(8, Int(checkpointToPersist.duration / 30)))
        musicHapticsLogger.debug(
            "HAPTICS_ANALYSIS track=\(self.diagnosticTrack(identity), privacy: .public) mode=\(result.snapshot.analysisMode.rawValue, privacy: .public) coverage=\(result.snapshot.coverage, privacy: .public) events=\(result.snapshot.eventCount, privacy: .public) transient_count=\(result.snapshot.transientCount, privacy: .public) continuous_count=\(result.snapshot.continuousCount, privacy: .public) event_density=\(eventDensity, privacy: .public) dropped_frames=\(result.snapshot.droppedFrames, privacy: .public) finish_reason=\(result.finishReason.rawValue, privacy: .public) tap_attached=\(result.snapshot.tapAttached, privacy: .public) pcm_format=\(self.formatDescription(result.snapshot.pcmFormat), privacy: .public) analysis_position=\(result.snapshot.analysisPosition, privacy: .public) speed=\(result.snapshot.analysisSpeedX, privacy: .public)x bitrate=\(result.snapshot.analysisStreamBitrate ?? -1, privacy: .public) tempo=\(result.snapshot.tempoBPM ?? -1, privacy: .public) beat_confidence=\(result.snapshot.beatConfidence, privacy: .public) analyzed_ranges=\(self.rangeDescription(result.snapshot.analyzedRanges), privacy: .public) timeline_suspiciously_sparse=\(suspiciouslySparse, privacy: .public)"
        )
        if let timeline = completeTimeline, timeline.timelineSuspiciouslySparse {
            musicHapticsLogger.debug(
                "HAPTICS_ANALYSIS timeline_suspiciously_sparse=true track=\(self.diagnosticTrack(identity), privacy: .public) duration=\(timeline.duration, privacy: .public) events=\(timeline.events.count, privacy: .public) density=\(timeline.eventDensity, privacy: .public)"
            )
        }

        guard currentPreparation?.id == preparationID else { return }
        analysisSnapshot = result.snapshot
        if storedFull {
            fullTimelineExists = true
            partialExists = false
            // Rolling windows have already been scheduled during this first
            // play. The completed v2 timeline is therefore immediately useful
            // without restarting the player; future plays resolve .custom.
            currentTimeline = completeTimeline
            currentPlanReason = "analysis_complete_rolling_active"
        } else if storedPartial {
            partialExists = true
        }
    }

    private func acceptAnalysisSnapshot(_ snapshot: MusicHapticsAnalysisSnapshot) {
        if snapshot.analysisMode == .remoteLookahead,
           realtimeFallbackPreparationID != nil {
            return
        }
        // Progress callbacks and the terminal result are delivered by separate
        // utility tasks. Do not let a late startup snapshot regress the final
        // coverage/event count shown to the user.
        guard snapshot.coverage >= analysisSnapshot.coverage
                || snapshot.finishReason != nil
        else { return }
        analysisSnapshot = snapshot
    }

    private func handleLookaheadFailure(
        preparationID: UUID,
        identity: MusicHapticsIdentity
    ) {
        failedLookaheadPreparationIDs.insert(preparationID)
        musicHapticsLogger.debug(
            "HAPTICS_LOOKAHEAD_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
        )
        guard currentPreparation?.id == preparationID,
              let preparation = currentPreparation
        else { return }
        currentPlanReason = "lookahead_failed_realtime_fallback"
        activateRealtimeFallback(preparation)
    }

    private func activateRealtimeFallback(_ preparation: MusicHapticsPlaybackPreparation) {
        guard currentPreparation?.id == preparation.id,
              case .analyzeLookahead = preparation.plan,
              let sink = preparation.realtimeFallbackSink
        else {
            currentPlanReason = "lookahead_failed_no_realtime_fallback"
            return
        }
        guard realtimeFallbackPreparationID != preparation.id else { return }
        realtimeFallbackPreparationID = preparation.id
        activeAnalysisSink = sink
        analysisSnapshot = MusicHapticsAnalysisSnapshot(
            tapAttached: analysisSnapshot.tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat,
            analyzedRanges: analysisSnapshot.analyzedRanges,
            coverage: analysisSnapshot.coverage,
            eventCount: analysisSnapshot.eventCount,
            droppedFrames: analysisSnapshot.droppedFrames,
            finishReason: nil,
            analysisMode: .realtimeTap,
            analysisStreamBitrate: analysisSnapshot.analysisStreamBitrate,
            analysisPosition: analysisSnapshot.analysisPosition,
            analysisSpeedX: 1,
            tempoBPM: analysisSnapshot.tempoBPM,
            beatConfidence: analysisSnapshot.beatConfidence,
            transientCount: analysisSnapshot.transientCount,
            continuousCount: analysisSnapshot.continuousCount,
            mixerDiagnostics: analysisSnapshot.mixerDiagnostics
        )
        realtimeFallbackHandler?(preparation.id, sink)
        musicHapticsLogger.debug(
            "HAPTICS_FALLBACK track=\(self.diagnosticTrack(preparation.identity), privacy: .public) analysis_mode=realtime_fallback lookahead=false"
        )
    }

    private func acceptRealtimeWindow(
        _ window: MusicHapticsAnalysisWindow,
        preparationID: UUID
    ) {
        guard currentPreparation?.id == preparationID,
              playbackIsPlaying,
              !isInBackground,
              !audioBuffering,
              currentPlan.kind == .analyze || realtimeFallbackPreparationID == preparationID
        else { return }
        custom.play(
            window,
            from: currentPosition,
            intensity: .medium,
            playbackRate: playbackRate
        )
        let transientCount = window.events.filter { $0.kind == .transient }.count
        let continuousCount = window.events.filter { $0.kind == .continuous }.count
        analysisSnapshot = MusicHapticsAnalysisSnapshot(
            tapAttached: analysisSnapshot.tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat,
            analyzedRanges: analysisSnapshot.analyzedRanges,
            coverage: analysisSnapshot.coverage,
            eventCount: max(analysisSnapshot.eventCount, window.eventCount),
            droppedFrames: analysisSnapshot.droppedFrames,
            finishReason: analysisSnapshot.finishReason,
            analysisMode: .realtimeTap,
            analysisStreamBitrate: analysisSnapshot.analysisStreamBitrate,
            analysisPosition: max(analysisSnapshot.analysisPosition, window.analysisPosition),
            analysisSpeedX: max(1, window.analysisSpeedX),
            tempoBPM: window.tempoBPM ?? analysisSnapshot.tempoBPM,
            beatConfidence: max(analysisSnapshot.beatConfidence, window.beatConfidence),
            transientCount: max(analysisSnapshot.transientCount, max(window.transientCount, transientCount)),
            continuousCount: max(analysisSnapshot.continuousCount, max(window.continuousCount, continuousCount)),
            mixerDiagnostics: window.mixerDiagnostics
        )
        musicHapticsLogger.debug(
            "HAPTICS_REALTIME_FALLBACK playback=\(self.currentPosition, privacy: .public) analysis=\(window.analysisPosition, privacy: .public) lead=\(window.analysisPosition - self.currentPosition, privacy: .public) lookahead=false events=\(window.events.count, privacy: .public)"
        )
    }

    private func acceptLookaheadWindow(
        _ window: MusicHapticsAnalysisWindow,
        preparationID: UUID
    ) {
        guard realtimeFallbackPreparationID != preparationID else { return }
        guard currentPreparation?.id == preparationID else {
            guard preparedLookaheadPreparationIDs.contains(preparationID) else { return }
            var windows = preparedLookaheadWindows[preparationID, default: []]
            windows.append(window)
            if windows.count > maximumPreparedLookaheadWindows {
                windows.removeFirst(windows.count - maximumPreparedLookaheadWindows)
            }
            preparedLookaheadWindows[preparationID] = windows
            return
        }
        guard case .analyzeLookahead = currentPlan else { return }
        let scheduled = rollingScheduler.ingest(window)
        analysisSnapshot = MusicHapticsAnalysisSnapshot(
            analyzedRanges: analysisSnapshot.analyzedRanges,
            coverage: max(analysisSnapshot.coverage, window.coverage),
            eventCount: max(analysisSnapshot.eventCount, window.eventCount),
            droppedFrames: analysisSnapshot.droppedFrames,
            finishReason: analysisSnapshot.finishReason,
            analysisMode: window.sourceMode,
            analysisStreamBitrate: window.analysisStreamBitrate,
            analysisPosition: max(analysisSnapshot.analysisPosition, window.analysisPosition),
            analysisSpeedX: max(analysisSnapshot.analysisSpeedX, window.analysisSpeedX),
            tempoBPM: window.tempoBPM ?? analysisSnapshot.tempoBPM,
            beatConfidence: max(analysisSnapshot.beatConfidence, window.beatConfidence),
            transientCount: max(analysisSnapshot.transientCount, window.transientCount),
            continuousCount: max(analysisSnapshot.continuousCount, window.continuousCount),
            mixerDiagnostics: window.mixerDiagnostics
        )
        playScheduledWindows(scheduled, position: currentPosition)
        musicHapticsLogger.debug(
            "HAPTICS_LOOKAHEAD playback=\(self.currentPosition, privacy: .public) analysis=\(window.analysisPosition, privacy: .public) lead=\(window.analysisPosition - self.currentPosition, privacy: .public) speed=\(window.analysisSpeedX, privacy: .public)x bitrate=\(window.analysisStreamBitrate ?? -1, privacy: .public) scheduled_until=\(self.rollingScheduler.scheduledUntil, privacy: .public) rolling_windows=\(self.rollingScheduler.rollingWindowCount, privacy: .public)"
        )
    }

    private func rebaseForPlaybackRateChange(
        position: TimeInterval,
        isPlaying: Bool
    ) {
        switch currentPlan {
        case let .custom(timeline):
            custom.stop()
            guard isPlaying else { return }
            do {
                try custom.play(
                    timeline,
                    offset: position,
                    playbackRate: playbackRate
                )
                currentTimeline = timeline
                source = .custom
            } catch {
                currentTimeline = nil
                source = .none
                currentPlanReason = "custom_rate_rebase_failed"
            }
        case .analyzeLookahead:
            custom.stop()
            guard realtimeFallbackPreparationID == nil else { return }
            let windows = rollingScheduler.seek(
                to: position,
                playing: isPlaying,
                rate: playbackRate
            )
            if rollingScheduler.consumeHapticFlushRequest() { custom.stop() }
            playScheduledWindows(windows, position: position)
        case .analyze:
            // Realtime fallback windows are timestamped in track time. Drop
            // the old pattern; the next PCM window is built at the new rate.
            custom.stop()
        case .disabled, .system:
            break
        }
    }

    private func pumpScheduler(position: TimeInterval, isPlaying: Bool) {
        guard !isInBackground, !audioBuffering else { return }
        if position + 0.15 < currentPosition { custom.stop() }
        let windows = rollingScheduler.updateClock(
            position: position,
            isPlaying: isPlaying,
            rate: playbackRate
        )
        if rollingScheduler.consumeHapticFlushRequest() {
            custom.stop()
        }
        playScheduledWindows(windows, position: position)
    }

    private func playScheduledWindows(
        _ windows: [MusicHapticsAnalysisWindow],
        position: TimeInterval
    ) {
        guard !isInBackground, !audioBuffering else { return }
        for window in windows {
            custom.play(
                window,
                from: position,
                intensity: .medium,
                playbackRate: playbackRate
            )
        }
    }

    private func startWarmupDeadline(preparation: MusicHapticsPlaybackPreparation) {
        guard case let .analyzeLookahead(request) = preparation.plan else { return }
        let deadline = request.warmupDeadline
        warmupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self,
                  !Task.isCancelled,
                  self.currentPreparation?.id == preparation.id
            else { return }
            let ready = self.rollingScheduler.scheduledUntil > self.currentPosition
            musicHapticsLogger.debug(
                "HAPTICS_WARMUP deadline_ms=\(self.durationMs(deadline), privacy: .public) ready=\(ready, privacy: .public) playback=\(self.currentPosition, privacy: .public) analysis=\(self.analysisSnapshot.analysisPosition, privacy: .public)"
            )
        }
    }

    private func inMemoryPartial(for identity: MusicHapticsIdentity) -> MusicHapticsPartialCheckpoint? {
        inMemoryPartials.values
            .filter { $0.identity.matchConfidence(with: identity) >= 0.82 }
            .max { $0.identity.matchConfidence(with: identity) < $1.identity.matchConfidence(with: identity) }
    }

    private func initialSnapshot(for preparation: MusicHapticsPlaybackPreparation) -> MusicHapticsAnalysisSnapshot {
        let request: MusicHapticsAnalysisRequest
        switch preparation.plan {
        case let .analyze(value), let .analyzeLookahead(value): request = value
        case .disabled, .system, .custom: return MusicHapticsAnalysisSnapshot()
        }
        let bitrate: Int? = switch request.analysisSource {
        case let .remoteLookahead(source): source.bitrate
        case .localFile, .realtimeTap: nil
        }
        guard let partial = request.partial
        else {
            return MusicHapticsAnalysisSnapshot(
                analysisMode: request.analysisSource.mode,
                analysisStreamBitrate: bitrate
            )
        }
        return MusicHapticsAnalysisSnapshot(
            analyzedRanges: partial.analyzedRanges,
            coverage: partial.coverage,
            eventCount: partial.events.count,
            analysisMode: request.analysisSource.mode,
            analysisStreamBitrate: bitrate,
            tempoBPM: partial.tempoBPM,
            beatConfidence: partial.beatConfidence ?? 0,
            transientCount: partial.events.filter { $0.kind == .transient }.count,
            continuousCount: partial.events.filter { $0.kind == .continuous }.count
        )
    }

    private func logPlan(
        identity: MusicHapticsIdentity,
        plan: MusicHapticsPlaybackPlan,
        reason: String,
        systemAvailability: MusicHapticsSystemAvailability,
        fullTimelineExists: Bool,
        partialExists: Bool
    ) {
        let coverage: Double?
        let eventCount: Int
        let eventDensity: Double?
        let sparse: Bool
        let analysisStreamBitrate: Int?
        switch plan {
        case let .custom(timeline):
            coverage = timeline.analysisCoverage
            eventCount = timeline.events.count
            eventDensity = timeline.eventDensity
            sparse = timeline.timelineSuspiciouslySparse
            analysisStreamBitrate = nil
        case let .analyze(request), let .analyzeLookahead(request):
            coverage = request.partial?.coverage
            eventCount = request.partial?.events.count ?? 0
            eventDensity = request.partial.map { $0.duration > 0 ? Double($0.events.count) / $0.duration : 0 }
            sparse = request.partial.map {
                $0.duration > 120 && $0.events.count < max(8, Int($0.duration / 30))
            } ?? false
            if case let .remoteLookahead(source) = request.analysisSource {
                analysisStreamBitrate = source.bitrate
            } else {
                analysisStreamBitrate = nil
            }
        case .disabled, .system:
            coverage = nil
            eventCount = 0
            eventDensity = nil
            sparse = false
            analysisStreamBitrate = nil
        }
        musicHapticsLogger.debug(
            "HAPTICS_PLAN track=\(self.diagnosticTrack(identity), privacy: .public) plan=\(plan.kind.rawValue, privacy: .public) reason=\(reason, privacy: .public) hasISRC=\(systemAvailability.hasISRC, privacy: .public) systemActive=\(systemAvailability.active, privacy: .public) systemTimelineAvailable=\(systemAvailability.timelineAvailable, privacy: .public) fullTimelineExists=\(fullTimelineExists, privacy: .public) partialExists=\(partialExists, privacy: .public) coverage=\(coverage ?? -1, privacy: .public) events=\(eventCount, privacy: .public) event_density=\(eventDensity ?? -1, privacy: .public) analysis_stream_bitrate=\(analysisStreamBitrate ?? -1, privacy: .public) timeline_suspiciously_sparse=\(sparse, privacy: .public)"
        )
    }

    private func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func diagnosticTrack(_ identity: MusicHapticsIdentity) -> String {
        let input = identity.globalID ?? identity.stableKey
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16).prefix(12).description
    }

    private func formatDescription(_ format: MusicHapticsPCMFormat?) -> String {
        guard let format else { return "none" }
        return "\(format.sampleRate)Hz/\(format.channels)ch/\(format.sampleType.rawValue)/\(format.interleaved ? "interleaved" : "planar")"
    }

    private func rangeDescription(_ ranges: [MusicHapticsTimeRange]) -> String {
        ranges.prefix(32)
            .map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) }
            .joined(separator: ",")
    }
}
