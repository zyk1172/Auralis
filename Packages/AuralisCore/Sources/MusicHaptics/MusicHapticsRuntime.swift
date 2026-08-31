import Foundation
import OSLog

#if os(iOS)
import CoreHaptics
import MediaAccessibility
import UIKit
#endif

private let musicHapticsLogger = Logger(subsystem: "com.auralis.player", category: "Playback")

/// Delivers only the newest analysis progress snapshot while keeping at most
/// one MainActor delivery task alive. Lookahead decoding can be much faster
/// than playback, so creating one unstructured MainActor task per callback
/// would turn progress reporting into an avoidable background workload.
private final class MusicHapticsProgressDelivery: @unchecked Sendable {
    private typealias Handler = @MainActor @Sendable (UUID, MusicHapticsAnalysisSnapshot) -> Void

    private struct Pending: @unchecked Sendable {
        let preparationID: UUID
        let snapshot: MusicHapticsAnalysisSnapshot
        let handler: Handler
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var deliveryScheduled = false

    func submit(
        _ snapshot: MusicHapticsAnalysisSnapshot,
        preparationID: UUID,
        handler: @escaping @MainActor @Sendable (UUID, MusicHapticsAnalysisSnapshot) -> Void
    ) {
        let shouldSchedule = lock.withLock { () -> Bool in
            pending = Pending(
                preparationID: preparationID,
                snapshot: snapshot,
                handler: handler
            )
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.deliver()
        }
    }

    @MainActor
    private func deliver() {
        let item = lock.withLock { () -> Pending? in
            let item = pending
            pending = nil
            if item == nil { deliveryScheduled = false }
            return item
        }
        guard let item else { return }
        item.handler(item.preparationID, item.snapshot)

        let shouldScheduleNext = lock.withLock { () -> Bool in
            guard pending != nil else {
                deliveryScheduled = false
                return false
            }
            return true
        }
        if shouldScheduleNext {
            Task { @MainActor [weak self] in
                self?.deliver()
            }
        }
    }
}

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
    public var analysisFailureReason: String?
    /// Stable decoder stage plus sanitized NSError domain/code, when a remote
    /// analysis source failed. It never contains a URL or localized error text.
    public var analysisFailureDetail: String?
    public var decoderFailureStage: String?
    public var decoderFailureDomain: String?
    public var decoderFailureCode: Int?
    public var systemTimelineAvailable: Bool
    public var fullTimelineExists: Bool
    public var partialExists: Bool
    public var tapAttached: Bool
    public var pcmFormat: MusicHapticsPCMFormat?
    public var analyzedRanges: [MusicHapticsTimeRange]
    public var eventCount: Int
    public var eventDensity: Double?
    public var droppedFrames: Int
    public var droppedAudioDuration: TimeInterval
    public var finishReason: MusicHapticsAnalysisFinishReason?
    public var timelineSuspiciouslySparse: Bool
    public var analysisMode: MusicHapticsAnalysisMode
    public var playbackPosition: TimeInterval
    public var analysisPosition: TimeInterval
    public var analysisLeadSeconds: TimeInterval
    public var analysisSpeedX: Double
    public var remoteAnalysisPosition: TimeInterval
    public var realtimeAnalysisPosition: TimeInterval
    public var remoteAnalysisSpeedX: Double
    public var realtimeAnalysisSpeedX: Double
    public var remoteDecoderState: MusicHapticsRemoteDecoderState
    public var currentEventSource: MusicHapticsEventSource
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
        analysisFailureReason: String? = nil,
        analysisFailureDetail: String? = nil,
        decoderFailureStage: String? = nil,
        decoderFailureDomain: String? = nil,
        decoderFailureCode: Int? = nil,
        systemTimelineAvailable: Bool = false,
        fullTimelineExists: Bool = false,
        partialExists: Bool = false,
        tapAttached: Bool = false,
        pcmFormat: MusicHapticsPCMFormat? = nil,
        analyzedRanges: [MusicHapticsTimeRange] = [],
        eventCount: Int = 0,
        eventDensity: Double? = nil,
        droppedFrames: Int = 0,
        droppedAudioDuration: TimeInterval = 0,
        finishReason: MusicHapticsAnalysisFinishReason? = nil,
        timelineSuspiciouslySparse: Bool = false,
        analysisMode: MusicHapticsAnalysisMode = .realtimeTap,
        playbackPosition: TimeInterval = 0,
        analysisPosition: TimeInterval = 0,
        analysisLeadSeconds: TimeInterval = 0,
        analysisSpeedX: Double = 0,
        remoteAnalysisPosition: TimeInterval = 0,
        realtimeAnalysisPosition: TimeInterval = 0,
        remoteAnalysisSpeedX: Double = 0,
        realtimeAnalysisSpeedX: Double = 0,
        remoteDecoderState: MusicHapticsRemoteDecoderState = .idle,
        currentEventSource: MusicHapticsEventSource = .none,
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
        self.analysisFailureReason = analysisFailureReason
        self.analysisFailureDetail = analysisFailureDetail
        self.decoderFailureStage = decoderFailureStage
        self.decoderFailureDomain = decoderFailureDomain
        self.decoderFailureCode = decoderFailureCode
        self.systemTimelineAvailable = systemTimelineAvailable
        self.fullTimelineExists = fullTimelineExists || timelineExists
        self.partialExists = partialExists
        self.tapAttached = tapAttached
        self.pcmFormat = pcmFormat
        self.analyzedRanges = analyzedRanges
        self.eventCount = max(0, eventCount)
        self.eventDensity = eventDensity
        self.droppedFrames = max(0, droppedFrames)
        self.droppedAudioDuration = max(0, droppedAudioDuration.isFinite ? droppedAudioDuration : 0)
        self.finishReason = finishReason
        self.timelineSuspiciouslySparse = timelineSuspiciouslySparse
        self.analysisMode = analysisMode
        self.playbackPosition = max(0, playbackPosition)
        self.analysisPosition = max(0, analysisPosition)
        self.analysisLeadSeconds = analysisLeadSeconds
        self.analysisSpeedX = max(0, analysisSpeedX)
        self.remoteAnalysisPosition = max(0, remoteAnalysisPosition)
        self.realtimeAnalysisPosition = max(0, realtimeAnalysisPosition)
        self.remoteAnalysisSpeedX = max(0, remoteAnalysisSpeedX)
        self.realtimeAnalysisSpeedX = max(0, realtimeAnalysisSpeedX)
        self.remoteDecoderState = remoteDecoderState
        self.currentEventSource = currentEventSource
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
        case .localFile, .remoteOriginal:
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

/// Output seam for the coordinator. The production implementation below is
/// the Core Haptics engine; the seam lets an integration test observe the
/// exact windows handed off after scheduler decisions without requiring a
/// physical Taptic Engine.
@MainActor
protocol MusicHapticsOutputEngine: AnyObject {
    var state: MusicHapticsEngineState { get }
    var applicationSuspended: Bool { get }
    var lastStopReason: String? { get }
    var supportsHaptics: Bool { get }
    var canProduceOutput: Bool { get }

    func setActualSuspensionHandler(_ handler: (() -> Void)?)
    func warmUp()
    func play(
        _ timeline: MusicHapticsTimeline,
        offset: TimeInterval,
        playbackRate: Double
    ) throws
    func play(
        _ window: MusicHapticsAnalysisWindow,
        from currentPosition: TimeInterval,
        intensity: MusicHapticsIntensity,
        playbackRate: Double
    )
    func pause()
    func resume(at offset: TimeInterval, playbackRate: Double)
    func seek(to offset: TimeInterval, playing: Bool, playbackRate: Double)
    func stop()
    func applicationDidEnterBackground()
    func restartIfNeeded()
}

@MainActor
final class CustomMusicHapticsEngine: MusicHapticsOutputEngine {
    private(set) var state: MusicHapticsEngineState = .notCreated
    private(set) var applicationSuspended = false
    private(set) var lastStopReason: String?
    private(set) var isInBackground = false
    private var actualSuspensionHandler: (() -> Void)?

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

    /// A background scene transition does not prove that Core Haptics has
    /// been suspended. Only an already-running engine is allowed to produce
    /// output while backgrounded; this prevents a new engine from being
    /// created after the system has stopped haptics.
    var canProduceOutput: Bool {
        !isInBackground || state == .running
    }

    func setActualSuspensionHandler(_ handler: (() -> Void)?) {
        actualSuspensionHandler = handler
    }

    /// Starts Core Haptics during app launch so the first playback event does
    /// not pay engine construction/startup latency. No pattern is created and
    /// no output is emitted here.
    func warmUp() {
        #if os(iOS)
        guard supportsHaptics, canProduceOutput else { return }
        do {
            _ = try prepareEngine()
        } catch {
            state = .stopped
            lastStopReason = String(describing: error)
        }
        #endif
    }

    func play(
        _ timeline: MusicHapticsTimeline,
        offset: TimeInterval,
        playbackRate: Double = 1
    ) throws {
        #if os(iOS)
        guard supportsHaptics, canProduceOutput else { return }
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
              canProduceOutput,
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
            scaled = event.intensity * intensity.masterIntensity
        }
        let textureScale = event.kind == .continuous ? intensity.continuousTextureScale : 1
        let effective = min(1, max(0, scaled * textureScale))
        return [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: effective),
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
                    value: min(1, max(0, $0.intensity * intensity.masterIntensity * intensity.continuousTextureScale))
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
        engine.playsHapticsOnly = true
        engine.stoppedHandler = { [weak self] reasonValue in
            let reason = String(describing: reasonValue)
            let wasApplicationSuspended: Bool
            switch reasonValue {
            case .applicationSuspended:
                wasApplicationSuspended = true
            default:
                wasApplicationSuspended = false
            }
            Task { @MainActor in
                guard let self else { return }
                self.players.removeAll()
                self.lastStopReason = reason
                self.applicationSuspended = wasApplicationSuspended
                self.state = wasApplicationSuspended ? .needsRestart : .stopped
                if wasApplicationSuspended {
                    self.actualSuspensionHandler?()
                }
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
    /// The persisted three-state override used to resolve this sidecar.  The
    /// captured effective value is only a preparation-time observation; the
    /// runtime must recompute it when the global default changes.
    public let preference: TrackHapticsPreference
    /// The effective per-track setting observed when this sidecar was
    /// prepared.  This is separate from the resolved plan: a track may be
    /// enabled while no system/custom asset is currently available.
    public let effectiveEnabled: Bool
    public let analysisSink: (any MusicHapticsAnalysisSink)?
    /// A realtime PCM safety source for remote original-stream analysis. It is
    /// attached to the current AVPlayerItem before playback starts and runs in
    /// parallel with the independent decoder. The scheduler chooses it for a
    /// gap before a remote decoder terminal error is available.
    public let realtimeTapSink: (any MusicHapticsAnalysisSink)?
    /// Source-compatible spelling for integrations compiled against the
    /// earlier PR. The value is no longer failure-only: it is attached and
    /// consumed in parallel with the original-stream analyzer.
    @available(*, deprecated, renamed: "realtimeTapSink")
    public var realtimeFallbackSink: (any MusicHapticsAnalysisSink)? {
        realtimeTapSink
    }
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
        preference: TrackHapticsPreference = .inherit,
        effectiveEnabled: Bool = false,
        analysisSink: (any MusicHapticsAnalysisSink)?,
        realtimeTapSink: (any MusicHapticsAnalysisSink)? = nil,
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
        self.preference = preference
        self.effectiveEnabled = effectiveEnabled
        self.analysisSink = analysisSink
        self.realtimeTapSink = realtimeTapSink
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
    private let custom: any MusicHapticsOutputEngine
    private let rollingScheduler: RollingMusicHapticsScheduler
    private let defaults: UserDefaults
    private let isFeatureAvailable: Bool
    private var analysisSourceProvider: (any MusicHapticsAnalysisSourceProvider)?
    private var failedLookaheadPreparationIDs: Set<UUID> = []
    private var lookaheadDiagnosticReasons: [UUID: MusicHapticsAnalysisDiagnostic] = [:]
    private var lookaheadDecoderFailures: [UUID: MusicHapticsDecoderFailure] = [:]
    private var activeRealtimeTapPreparationIDs: Set<UUID> = []
    private var preparedLookaheadPreparationIDs: Set<UUID> = []
    private var preparedLookaheadWindows: [UUID: [MusicHapticsAnalysisWindow]] = [:]
    private var preparedLookaheadAnalyzers: [UUID: LookaheadMusicHapticsAnalyzer] = [:]
    private var preparedLookaheadTapSinks: [UUID: any MusicHapticsAnalysisSink] = [:]
    /// A background transition may happen while AVQueuePlayer prepares the
    /// next item. Retain only the source description and defer opening its
    /// decoder until foreground; this keeps prepared-next analysis from
    /// creating background network/PCM work solely for haptics.
    private var deferredPreparedLookaheadSources: [UUID: MusicHapticsAnalysisSource] = [:]
    private let maximumPreparedLookaheadWindows = 64
    private var currentIdentity: MusicHapticsIdentity?
    private var currentTimeline: MusicHapticsTimeline?
    private var currentPreparation: MusicHapticsPlaybackPreparation?
    private var activeAnalysisSink: (any MusicHapticsAnalysisSink)?
    private var analysisFailureReason: MusicHapticsAnalysisDiagnostic?
    private var analysisFailureDetail: String?
    private var currentFavorite = false
    private var currentPosition: TimeInterval = 0
    private var playbackRate: Double = 1
    private var playbackIsPlaying = false
    /// Runtime-only gate used by the per-track playback toggle.  It never
    /// touches AVPlayer; it only prevents the Haptics sidecar from producing
    /// new output while retaining the current preparation/checkpoint.
    private var runtimeOutputEnabled = false
    private var isInBackground = false
    private var hapticsSuspended = false
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
    private var suspensionCheckpointTask: Task<Void, Never>?
    private var checkpointPersistenceTask: Task<Void, Never>?
    private var checkpointPersistedCoverage: [UUID: Double] = [:]
    /// Keeps a just-finished checkpoint visible while its actor-owned store
    /// write is in flight. This closes the rapid A→B→A race without making
    /// playback wait for disk I/O.
    private var inMemoryPartials: [String: MusicHapticsPartialCheckpoint] = [:]

    public convenience init(
        store: MusicHapticsStore = MusicHapticsStore(),
        defaults: UserDefaults = .standard,
        analysisSourceProvider: (any MusicHapticsAnalysisSourceProvider)? = nil
    ) {
        self.init(
            store: store,
            defaults: defaults,
            analysisSourceProvider: analysisSourceProvider,
            outputEngine: CustomMusicHapticsEngine(),
            isFeatureAvailable: MusicHapticsPlatformPolicy.isFeatureAvailable
        )
    }

    /// Internal injection seam for coordinator integration tests. Production
    /// callers use the Core Haptics implementation selected by the public
    /// initializer above.
    init(
        store: MusicHapticsStore = MusicHapticsStore(),
        defaults: UserDefaults = .standard,
        analysisSourceProvider: (any MusicHapticsAnalysisSourceProvider)? = nil,
        outputEngine: any MusicHapticsOutputEngine,
        isFeatureAvailable: Bool = MusicHapticsPlatformPolicy.isFeatureAvailable
    ) {
        self.store = store
        self.defaults = defaults
        self.analysisSourceProvider = analysisSourceProvider
        self.custom = outputEngine
        self.isFeatureAvailable = isFeatureAvailable
        let policy = MusicHapticsAnalysisPerformancePolicy.current
        self.rollingScheduler = RollingMusicHapticsScheduler(
            hapticCommitHorizon: policy.hapticCommitHorizon
        )
        custom.setActualSuspensionHandler { [weak self] in
            self?.handleActualHapticsSuspension()
        }
    }

    /// Installed by AppShell after its connector is constructed.  Keeping the
    /// provider at this boundary prevents MusicHaptics from importing or
    /// retaining OpenSubsonic credentials.
    public func setAnalysisSourceProvider(_ provider: (any MusicHapticsAnalysisSourceProvider)?) {
        analysisSourceProvider = provider
    }

    /// Warm Core Haptics before the first user interaction. This is deliberately
    /// independent from playback and remains a no-op on unsupported platforms.
    public func warmUpIfNeeded() {
        custom.warmUp()
    }

    public var supportsHaptics: Bool {
        isFeatureAvailable && custom.supportsHaptics
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
        guard isFeatureAvailable else {
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
                preference: .inherit,
                effectiveEnabled: false,
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
        let preparationReason: String = {
            guard featureEnabled,
                  fullTimeline == nil,
                  !systemAvailability.canUseTimeline
            else { return decision.reason }
            switch analysisSource {
            case .remoteOriginal:
                return decision.reason
            case .realtimeTap where playbackURL?.isFileURL != true:
                return MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue
            case .localFile, .realtimeTap:
                return decision.reason
            }
        }()
        let preparationID = UUID()
        // Each preparation owns its coalescer. A single coordinator-wide
        // mailbox could let a late callback from track A replace the newest
        // progress for track B before the preparation-ID guard runs.
        let progressDelivery = MusicHapticsProgressDelivery()
        let analysisSink: (any MusicHapticsAnalysisSink)?
        let realtimeTapSink: (any MusicHapticsAnalysisSink)?
        let lookaheadAnalyzer: LookaheadMusicHapticsAnalyzer?
        let sourceProvider = analysisSourceProvider
        let fallbackSourceProvider: LookaheadMusicHapticsAnalyzer.FallbackSourceProvider = {
            [sourceProvider, identity, playbackURL] failedSource in
            guard let sourceProvider else { return [] }
            return await sourceProvider.fallbackSources(
                for: identity,
                playbackURL: playbackURL,
                after: failedSource
            )
        }
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
                onProgress: { [weak self, progressDelivery] snapshot in
                    progressDelivery.submit(snapshot, preparationID: preparationID) { [weak self] id, snapshot in
                        guard let self,
                              self.currentPreparation?.id == id
                        else { return }
                        self.acceptAnalysisSnapshot(snapshot)
                        self.scheduleCheckpointPersistence(
                            preparationID: id,
                            snapshot: snapshot,
                            favorite: analysisRequest.favorite
                        )
                    }
                },
                onWindow: { [weak self] window in
                    Task { @MainActor [weak self] in
                        self?.acceptRealtimeWindow(window, preparationID: preparationID)
                    }
                }
            )
            realtimeTapSink = nil
            lookaheadAnalyzer = nil
        case let .analyzeLookahead(analysisRequest):
            analysisSink = nil
            let needsRealtimeTap: Bool
            switch analysisRequest.analysisSource {
            case .remoteOriginal:
                needsRealtimeTap = true
            case .localFile, .realtimeTap:
                needsRealtimeTap = false
            }
            if needsRealtimeTap {
                // The realtime tap is deliberately created during preparation
                // and attached before AVPlayer starts. It receives PCM in
                // parallel; the scheduler prefers original-stream windows in
                // covered ranges and uses tap windows for slow or missing gaps.
                realtimeTapSink = StreamingMusicHapticsAnalyzer(
                    identity: analysisRequest.identity,
                    duration: analysisRequest.duration,
                    partial: analysisRequest.partial,
                    onResult: { [weak self] result in
                        Task { @MainActor [weak self] in
                            await self?.handleRealtimeTapResult(
                                result,
                                preparationID: preparationID,
                                favorite: analysisRequest.favorite
                            )
                        }
                    },
                    onProgress: { [weak self, progressDelivery] snapshot in
                        progressDelivery.submit(snapshot, preparationID: preparationID) { [weak self] id, snapshot in
                            self?.acceptRealtimeTapSnapshot(snapshot, preparationID: id)
                            self?.scheduleCheckpointPersistence(
                                preparationID: id,
                                snapshot: snapshot,
                                favorite: analysisRequest.favorite
                            )
                        }
                    },
                    onWindow: { [weak self] window in
                        Task { @MainActor [weak self] in
                            self?.acceptRealtimeTapWindow(window, preparationID: preparationID)
                        }
                    }
                )
            } else {
                realtimeTapSink = nil
            }
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
                onProgress: { [weak self, progressDelivery] snapshot in
                    progressDelivery.submit(snapshot, preparationID: preparationID) { [weak self] id, snapshot in
                        guard let self,
                              self.currentPreparation?.id == id
                        else { return }
                        self.acceptAnalysisSnapshot(snapshot)
                        self.scheduleCheckpointPersistence(
                            preparationID: id,
                            snapshot: snapshot,
                            favorite: analysisRequest.favorite
                        )
                    }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleLookaheadFailure(preparationID: preparationID, identity: identity)
                    }
                },
                onDiagnostic: { [weak self] diagnostic in
                    Task { @MainActor [weak self] in
                        self?.handleLookaheadDiagnostic(
                            diagnostic,
                            preparationID: preparationID,
                            identity: identity
                        )
                    }
                },
                onDecoderFailure: { [weak self] failure in
                    Task { @MainActor [weak self] in
                        self?.handleLookaheadDecoderFailure(
                            failure,
                            preparationID: preparationID,
                            identity: identity
                        )
                    }
                },
                fallbackSourceProvider: fallbackSourceProvider
            )
        case .disabled, .system, .custom:
            analysisSink = nil
            realtimeTapSink = nil
            lookaheadAnalyzer = nil
        }

        let preparation = MusicHapticsPlaybackPreparation(
            id: preparationID,
            identity: identity,
            favorite: favorite,
            plan: decision.plan,
            reason: preparationReason,
            systemAvailability: systemAvailability,
            fullTimelineExists: fullTimeline != nil,
            partialExists: partial != nil,
            preference: preference,
            effectiveEnabled: featureEnabled,
            analysisSink: analysisSink,
            realtimeTapSink: realtimeTapSink,
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
            reason: preparationReason,
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
        rate: Double = 1,
        isPlaying: Bool = true
    ) {
        let globalEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        let effectiveEnabled = preparation.preference.effective(
            globalEnabled: globalEnabled
        )
        guard isFeatureAvailable,
              effectiveEnabled else {
            runtimeOutputEnabled = false
            source = .none
            return
        }
        if currentPreparation?.id != preparation.id {
            checkpointPersistenceTask?.cancel()
            checkpointPersistenceTask = nil
            activeAnalysisSink?.finishPartial(reason: .trackSwitch)
            currentPreparation?.lookaheadAnalyzer?.finishPartial(reason: .trackSwitch)
            currentPreparation?.realtimeTapSink?.finishPartial(reason: .trackSwitch)
            if let oldID = currentPreparation?.id {
                activeRealtimeTapPreparationIDs.remove(oldID)
                preparedLookaheadAnalyzers.removeValue(forKey: oldID)
                failedLookaheadPreparationIDs.remove(oldID)
                lookaheadDiagnosticReasons.removeValue(forKey: oldID)
                lookaheadDecoderFailures.removeValue(forKey: oldID)
            }
        }
        warmupTask?.cancel()
        warmupTask = nil
        custom.stop()
        rollingScheduler.stop()
        currentPreparation = preparation
        preparedLookaheadPreparationIDs.remove(preparation.id)
        preparedLookaheadAnalyzers.removeValue(forKey: preparation.id)
        preparedLookaheadTapSinks.removeValue(forKey: preparation.id)
        deferredPreparedLookaheadSources.removeValue(forKey: preparation.id)
        currentIdentity = preparation.identity
        currentFavorite = preparation.favorite
        currentPosition = max(0, position)
        playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        runtimeOutputEnabled = preparation.plan.kind != .disabled
        playbackIsPlaying = isPlaying
        audioBuffering = false
        currentPlan = preparation.plan
        currentSystemAvailability = preparation.systemAvailability
        fullTimelineExists = preparation.fullTimelineExists
        partialExists = preparation.partialExists
        currentPlanReason = preparation.reason
        analysisFailureReason = MusicHapticsAnalysisDiagnostic(rawValue: preparation.reason)
        analysisFailureDetail = lookaheadDecoderFailures[preparation.id]?.summary
        activeAnalysisSink = preparation.analysisSink
        currentTimeline = nil
        checkpointPersistedCoverage[preparation.id] = {
            switch preparation.plan {
            case let .analyze(request), let .analyzeLookahead(request):
                request.partial?.coverage ?? 0
            case .disabled, .system, .custom:
                0
            }
        }()
        analysisSnapshot = initialSnapshot(for: preparation)
        let bufferedWindows = preparedLookaheadWindows.removeValue(forKey: preparation.id) ?? []
        preparation.lookaheadAnalyzer?.updatePlaybackPosition(
            currentPosition,
            isPlaying: playbackIsPlaying && runtimeOutputEnabled && !hapticsSuspended && !isInBackground,
            rate: playbackRate
        )
        if hapticsSuspended || isInBackground || audioBuffering || !runtimeOutputEnabled || !playbackIsPlaying {
            preparation.lookaheadAnalyzer?.pause()
        } else {
            preparation.lookaheadAnalyzer?.resume()
        }

        switch preparation.plan {
        case .disabled:
            source = .none
        case .system:
            source = .system
        case let .custom(timeline):
            do {
                if isPlaying, runtimeOutputEnabled, custom.canProduceOutput, !hapticsSuspended, !isInBackground {
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
            preparedLookaheadAnalyzers.removeValue(forKey: preparation.id)
            preparedLookaheadTapSinks.removeValue(forKey: preparation.id)
            // The PCM source is a continuity base, not a failure-only
            // fallback. It must be ready before the first AVPlayer frames and
            // remains active while the original-stream decoder catches up.
            _ = activateRealtimeTapIfAvailable(
                preparation,
                identity: preparation.identity
            )
            failedLookaheadPreparationIDs.remove(preparation.id)
            if !runtimeOutputEnabled || !isPlaying || isInBackground {
                preparation.lookaheadAnalyzer?.pause()
                preparation.realtimeTapSink?.pause()
            } else {
                for window in bufferedWindows {
                    _ = rollingScheduler.ingest(window)
                }
                if let partial = request.partial {
                    let firstMissing = partial.uncoveredRanges.first?.lowerBound
                    musicHapticsLogger.debug(
                        "HAPTICS_CHECKPOINT_RESUME track=\(self.diagnosticTrack(preparation.identity), privacy: .public) coverage=\(partial.coverage, privacy: .public) ranges=\(self.rangeDescription(partial.analyzedRanges), privacy: .public) first_missing=\(firstMissing ?? -1, privacy: .public) anchors=\(partial.decoderResumePoints.count, privacy: .public)"
                    )
                    for window in partial.analysisWindows(sourceMode: request.analysisSource.mode) {
                        _ = rollingScheduler.ingest(window)
                    }
                }
                preparation.realtimeTapSink?.resume()
                preparation.lookaheadAnalyzer?.start(source: request.analysisSource)
                startWarmupDeadline(preparation: preparation)
                pumpScheduler(position: position, isPlaying: isPlaying)
            }
        case .analyze:
            source = .analyzing
        }

        // A next-item preparation can finish before this current preparation
        // is activated. `startPreparedAnalysis` deliberately defers it while
        // the coordinator has no authoritative playing state yet; drain that
        // deferred source at the same activation boundary once audio is known
        // to be running.
        if isPlaying,
           runtimeOutputEnabled,
           !hapticsSuspended,
           !isInBackground,
           !audioBuffering {
            let deferredPreparedSources = deferredPreparedLookaheadSources
            deferredPreparedLookaheadSources.removeAll()
            for (preparationID, source) in deferredPreparedSources {
                preparedLookaheadAnalyzers[preparationID]?.start(source: source)
            }
        }
    }

    /// Prepared next items may start decoding before they become current.  It
    /// is idempotent, so the active transition can call it again safely.
    public func startPreparedAnalysis(_ preparation: MusicHapticsPlaybackPreparation) {
        guard case let .analyzeLookahead(request) = preparation.plan else { return }
        guard let analyzer = preparation.lookaheadAnalyzer else { return }
        preparedLookaheadAnalyzers[preparation.id] = analyzer
        if let fallback = preparation.realtimeTapSink {
            preparedLookaheadTapSinks[preparation.id] = fallback
        }
        let canStart = playbackIsPlaying
            && !audioBuffering
            && runtimeOutputEnabled
            && !hapticsSuspended
            && !isInBackground
        analyzer.updatePlaybackPosition(0, isPlaying: canStart, rate: 1)
        if !canStart {
            analyzer.pause()
            deferredPreparedLookaheadSources[preparation.id] = request.analysisSource
            return
        }
        deferredPreparedLookaheadSources.removeValue(forKey: preparation.id)
        analyzer.resume()
        analyzer.start(source: request.analysisSource)
    }

    /// Drops a prepared (not-current) analysis session when queue policy or a
    /// newer preparation replaces it. The engine owns item cleanup; this
    /// method only releases the sidecar's buffered windows/state.
    public func discardPreparedAnalysis(_ preparation: MusicHapticsPlaybackPreparation) {
        guard currentPreparation?.id != preparation.id else { return }
        preparedLookaheadAnalyzers.removeValue(forKey: preparation.id)
            preparedLookaheadTapSinks.removeValue(forKey: preparation.id)
        preparedLookaheadPreparationIDs.remove(preparation.id)
        preparedLookaheadWindows.removeValue(forKey: preparation.id)
        deferredPreparedLookaheadSources.removeValue(forKey: preparation.id)
        failedLookaheadPreparationIDs.remove(preparation.id)
        lookaheadDiagnosticReasons.removeValue(forKey: preparation.id)
        lookaheadDecoderFailures.removeValue(forKey: preparation.id)
        checkpointPersistedCoverage.removeValue(forKey: preparation.id)
        activeRealtimeTapPreparationIDs.remove(preparation.id)
        // A prepared item may already have decoded useful PCM/lookahead. It
        // is being replaced, not invalidated; finish its sidecar so the
        // checkpoint is merged and persisted asynchronously.
        preparation.analysisSink?.finishPartial(reason: .preparationReplaced)
        preparation.realtimeTapSink?.finishPartial(reason: .preparationReplaced)
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
        currentPreparation?.lookaheadAnalyzer?.pause()
        currentPreparation?.realtimeTapSink?.pause()
        preparedLookaheadAnalyzers.values.forEach { $0.pause() }
        preparedLookaheadTapSinks.values.forEach { $0.pause() }
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
        currentPreparation?.lookaheadAnalyzer?.updatePlaybackPosition(
            currentPosition,
            isPlaying: runtimeOutputEnabled && !hapticsSuspended && !isInBackground,
            rate: playbackRate
        )
        if isInBackground {
            // Do not restart decoders or create a new Core Haptics player in
            // the background. Existing scheduled output is left untouched.
            activeAnalysisSink?.pause()
            currentPreparation?.lookaheadAnalyzer?.pause()
            currentPreparation?.realtimeTapSink?.pause()
            preparedLookaheadAnalyzers.values.forEach { $0.pause() }
            preparedLookaheadTapSinks.values.forEach { $0.pause() }
            rollingScheduler.pause()
            return
        }
        if hapticsSuspended || !runtimeOutputEnabled {
            activeAnalysisSink?.pause()
            currentPreparation?.lookaheadAnalyzer?.pause()
            currentPreparation?.realtimeTapSink?.pause()
            preparedLookaheadAnalyzers.values.forEach { $0.pause() }
            preparedLookaheadTapSinks.values.forEach { $0.pause() }
            rollingScheduler.pause()
            custom.stop()
            return
        }
        activeAnalysisSink?.resume()
        currentPreparation?.realtimeTapSink?.resume()
        // A prepared-next request can finish while AVPlayer is buffering or
        // paused. Drain it only after playback resumes; otherwise the async
        // completion would open an optional decoder while audio is not moving.
        let deferredPreparedSources = deferredPreparedLookaheadSources
        deferredPreparedLookaheadSources.removeAll()
        for (preparationID, source) in deferredPreparedSources {
            preparedLookaheadAnalyzers[preparationID]?.start(source: source)
        }
        if case let .analyzeLookahead(request) = currentPlan {
            // A preparation activated while paused deliberately has not
            // opened its decoder.  Resume must therefore ensure the current
            // analyzer is started before merely releasing its pause gate.
            currentPreparation?.lookaheadAnalyzer?.start(source: request.analysisSource)
        }
        currentPreparation?.lookaheadAnalyzer?.resume()
        preparedLookaheadAnalyzers.values.forEach { $0.resume() }
        preparedLookaheadTapSinks.values.forEach { $0.resume() }
        if source == .custom, let timeline = currentTimeline {
            custom.stop()
            do {
                try custom.play(
                    timeline,
                    offset: currentPosition,
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
        currentPreparation?.lookaheadAnalyzer?.updatePlaybackPosition(
            currentPosition,
            isPlaying: playing && runtimeOutputEnabled && !hapticsSuspended && !isInBackground,
            rate: playbackRate
        )
        if playing && runtimeOutputEnabled && !hapticsSuspended && !isInBackground {
            currentPreparation?.lookaheadAnalyzer?.resume()
            currentPreparation?.realtimeTapSink?.resume()
        } else {
            currentPreparation?.lookaheadAnalyzer?.pause()
            currentPreparation?.realtimeTapSink?.pause()
        }
        guard !hapticsSuspended, !isInBackground, runtimeOutputEnabled else { return }
        activeAnalysisSink?.seek(to: currentPosition)
        currentPreparation?.realtimeTapSink?.seek(to: currentPosition)
        if source == .custom {
            custom.seek(
                to: currentPosition,
                playing: playing,
                playbackRate: playbackRate
            )
        } else if case .analyzeLookahead = currentPlan {
            custom.stop()
            let windows = rollingScheduler.seek(to: position, playing: playing, rate: playbackRate)
            playScheduledWindows(windows, position: position)
        } else if case .analyze = currentPlan {
            custom.stop()
        }
    }

    public func updatePlaybackPosition(
        _ position: TimeInterval,
        isPlaying: Bool,
        rate: Double = 1
    ) {
        // This callback is driven by the UI/progress display and may arrive
        // after the scene has already entered the background.  Background
        // playback keeps AVPlayer as the clock source; accepting a late UI
        // tick here would overwrite that clock and make the foreground
        // rebase start from stale data.  The next active transition supplies
        // the authoritative AVPlayer position explicitly.
        guard !isInBackground else { return }
        let previousPosition = currentPosition
        currentPosition = max(0, position)
        let safeRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        let rateChanged = abs(safeRate - playbackRate) > 0.02
        playbackRate = safeRate
        playbackIsPlaying = isPlaying
        if isPlaying { audioBuffering = false }
        let analysisCanRun = isPlaying && !audioBuffering && runtimeOutputEnabled && !hapticsSuspended && !isInBackground
        currentPreparation?.lookaheadAnalyzer?.updatePlaybackPosition(
            currentPosition,
            isPlaying: analysisCanRun,
            rate: playbackRate
        )
        if analysisCanRun {
            currentPreparation?.lookaheadAnalyzer?.resume()
            currentPreparation?.realtimeTapSink?.resume()
            activeAnalysisSink?.resume()
        } else {
            currentPreparation?.lookaheadAnalyzer?.pause()
            currentPreparation?.realtimeTapSink?.pause()
            activeAnalysisSink?.pause()
        }
        if currentPosition + 0.15 < previousPosition {
            custom.stop()
            activeAnalysisSink?.seek(to: currentPosition)
            currentPreparation?.realtimeTapSink?.seek(to: currentPosition)
        }
        if rateChanged, runtimeOutputEnabled, !hapticsSuspended, !isInBackground, !audioBuffering {
            rebaseForPlaybackRateChange(position: currentPosition, isPlaying: isPlaying)
        }
        guard case .analyzeLookahead = currentPlan,
              runtimeOutputEnabled,
              !hapticsSuspended,
              !isInBackground else { return }
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

    /// Core Haptics' typed stopped reason is the authority for an actual
    /// application suspension. At that point stop feeding the scheduler and
    /// sidecars, then preserve the in-memory analysis checkpoint for the next
    /// foreground recovery or an unexpected process termination.
    private func handleActualHapticsSuspension() {
        hapticsSuspended = true
        rollingScheduler.pause()
        activeAnalysisSink?.pause()
        currentPreparation?.lookaheadAnalyzer?.pause()
        preparedLookaheadAnalyzers.values.forEach { $0.pause() }

        scheduleCurrentCheckpoint()
    }

    private func scheduleCurrentCheckpoint() {
        suspensionCheckpointTask?.cancel()
        guard let preparation = currentPreparation else { return }
        let preparationID = preparation.id
        suspensionCheckpointTask = Task { @MainActor [weak self] in
            guard let self,
                  let current = self.currentPreparation,
                  current.id == preparationID,
                  let checkpoint = await self.currentCheckpoint(for: current),
                  !Task.isCancelled
            else { return }
            await self.persistCheckpoint(
                checkpoint,
                identity: current.identity,
                favorite: current.favorite,
                reason: "suspension"
            )
        }
    }

    /// Persist useful progress while a long remote decoder is still running.
    /// Track switches and suspension remain hard boundaries, but a process
    /// termination between those boundaries must not throw away minutes of
    /// analysis that have already been completed.
    private func scheduleCheckpointPersistence(
        preparationID: UUID,
        snapshot: MusicHapticsAnalysisSnapshot,
        favorite: Bool
    ) {
        guard currentPreparation?.id == preparationID,
              snapshot.coverage > 0
        else { return }
        let lastPersistedCoverage = checkpointPersistedCoverage[preparationID] ?? 0
        guard snapshot.coverage >= lastPersistedCoverage + 0.05,
              checkpointPersistenceTask == nil
        else { return }

        checkpointPersistenceTask = Task { @MainActor [weak self] in
            defer { self?.checkpointPersistenceTask = nil }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  let preparation = self.currentPreparation,
                  preparation.id == preparationID
            else { return }
            guard let checkpoint = await self.currentCheckpoint(for: preparation) else { return }
            guard !Task.isCancelled,
                  self.currentPreparation?.id == preparationID
            else { return }
            self.checkpointPersistedCoverage[preparationID] = max(
                self.checkpointPersistedCoverage[preparationID] ?? 0,
                checkpoint.coverage
            )
            await self.persistCheckpoint(
                checkpoint,
                identity: preparation.identity,
                favorite: favorite,
                reason: "periodic"
            )
        }
    }

    private func currentCheckpoint(
        for preparation: MusicHapticsPlaybackPreparation
    ) async -> MusicHapticsPartialCheckpoint? {
        var checkpoints: [MusicHapticsPartialCheckpoint] = []
        if let lookahead = preparation.lookaheadAnalyzer {
            checkpoints.append(await lookahead.partialCheckpoint())
        }
        if let realtime = preparation.realtimeTapSink
            as? any MusicHapticsPartialCheckpointProvider {
            checkpoints.append(await realtime.partialCheckpoint())
        }
        if let analysis = preparation.analysisSink
            as? any MusicHapticsPartialCheckpointProvider {
            checkpoints.append(await analysis.partialCheckpoint())
        }
        return checkpoints.reduce(into: nil) { result, checkpoint in
            result = result?.merged(with: checkpoint) ?? checkpoint
        }
    }

    private func persistCheckpoint(
        _ checkpoint: MusicHapticsPartialCheckpoint,
        identity: MusicHapticsIdentity,
        favorite: Bool,
        reason: String
    ) async {
        guard checkpoint.coverage > 0,
              checkpoint.identity.matchConfidence(with: identity) >= 0.82
        else { return }
        let key = checkpoint.identity.stableKey
        let merged: MusicHapticsPartialCheckpoint
        if let existing = inMemoryPartials[key],
           existing.identity.matchConfidence(with: checkpoint.identity) >= 0.82 {
            merged = existing.merged(with: checkpoint)
        } else {
            merged = checkpoint
        }
        inMemoryPartials[key] = merged
        do {
            if merged.isComplete {
                try await store.store(merged.timeline(), favorite: favorite)
                if inMemoryPartials[key] == merged {
                    inMemoryPartials.removeValue(forKey: key)
                }
                fullTimelineExists = true
                partialExists = false
            } else {
                try await store.storePartial(merged)
                if inMemoryPartials[key] == merged {
                    inMemoryPartials.removeValue(forKey: key)
                }
                partialExists = true
            }
            musicHapticsLogger.debug(
                "HAPTICS_CHECKPOINT_SAVED track=\(self.diagnosticTrack(identity), privacy: .public) reason=\(reason, privacy: .public) coverage=\(merged.coverage, privacy: .public) ranges=\(self.rangeDescription(merged.analyzedRanges), privacy: .public) events=\(merged.events.count, privacy: .public)"
            )
        } catch {
            musicHapticsLogger.error(
                "HAPTICS_CHECKPOINT_SAVE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    /// A background scene transition alone does not prove that Core Haptics
    /// has been suspended. Keep already-created output alive, but pause all
    /// decoder/DSP sidecars and stop scheduling new future windows. Audio has
    /// priority over optional haptic analysis while the app is backgrounded.
    public func applicationDidEnterBackground() {
        isInBackground = true
        custom.applicationDidEnterBackground()
        rollingScheduler.pause()
        activeAnalysisSink?.pause()
        currentPreparation?.lookaheadAnalyzer?.pause()
        currentPreparation?.realtimeTapSink?.pause()
        preparedLookaheadAnalyzers.values.forEach { $0.pause() }
        preparedLookaheadTapSinks.values.forEach { $0.pause() }
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
        hapticsSuspended = false
        currentPosition = max(0, position)
        playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        playbackIsPlaying = isPlaying
        audioBuffering = false
        foregroundRecoveryCount += 1
        if runtimeOutputEnabled {
            custom.restartIfNeeded()
        }
        // Any lookahead decoder withheld while backgrounded starts only after
        // the authoritative AVPlayer position has been rebased, and only when
        // audio is actually playing. A paused foreground scene must not open
        // an optional decoder just because it became active.
        if isPlaying, runtimeOutputEnabled {
            if case let .analyzeLookahead(request) = currentPlan {
                currentPreparation?.lookaheadAnalyzer?.start(source: request.analysisSource)
            }
            let deferredPreparedSources = deferredPreparedLookaheadSources
            deferredPreparedLookaheadSources.removeAll()
            for (preparationID, source) in deferredPreparedSources {
                preparedLookaheadAnalyzers[preparationID]?.start(source: source)
            }
        }
        currentPreparation?.lookaheadAnalyzer?.updatePlaybackPosition(
            currentPosition,
            isPlaying: isPlaying && runtimeOutputEnabled && !audioBuffering,
            rate: playbackRate
        )
        if isPlaying && runtimeOutputEnabled && !audioBuffering {
            activeAnalysisSink?.resume()
            currentPreparation?.lookaheadAnalyzer?.resume()
            currentPreparation?.realtimeTapSink?.resume()
            preparedLookaheadAnalyzers.values.forEach { $0.resume() }
            preparedLookaheadTapSinks.values.forEach { $0.resume() }
        } else {
            activeAnalysisSink?.pause()
            currentPreparation?.lookaheadAnalyzer?.pause()
            currentPreparation?.realtimeTapSink?.pause()
            preparedLookaheadAnalyzers.values.forEach { $0.pause() }
            preparedLookaheadTapSinks.values.forEach { $0.pause() }
        }
        guard isPlaying, runtimeOutputEnabled else {
            custom.stop()
            rollingScheduler.updateClock(position: currentPosition, isPlaying: false)
            if !runtimeOutputEnabled { source = .none }
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
            currentPreparation?.realtimeTapSink?.seek(to: currentPosition)
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
        suspensionCheckpointTask?.cancel()
        suspensionCheckpointTask = nil
        checkpointPersistenceTask?.cancel()
        checkpointPersistenceTask = nil
        activeAnalysisSink?.finishPartial(reason: reason)
        currentPreparation?.lookaheadAnalyzer?.finishPartial(reason: reason)
        // The realtime tap is a first-class analysis source, not a disposable
        // failure fallback. Finish it through the checkpoint path so PCM
        // already processed before a track switch, stall, or suspension is
        // persisted instead of being dropped by an unconditional cancel.
        if let realtimeTap = currentPreparation?.realtimeTapSink {
            if reason == .naturalEnd {
                realtimeTap.finish()
            } else {
                realtimeTap.finishPartial(reason: reason)
            }
        }
        activeAnalysisSink = nil
        if let currentID = currentPreparation?.id {
            activeRealtimeTapPreparationIDs.remove(currentID)
        }
        playbackIsPlaying = false
        failedLookaheadPreparationIDs.removeAll()
        lookaheadDiagnosticReasons.removeAll()
        checkpointPersistedCoverage.removeAll()
        if let currentID = currentPreparation?.id {
            preparedLookaheadPreparationIDs.remove(currentID)
            preparedLookaheadWindows.removeValue(forKey: currentID)
            deferredPreparedLookaheadSources.removeValue(forKey: currentID)
        }
        warmupTask?.cancel()
        warmupTask = nil
        rollingScheduler.stop()
        custom.stop()
        runtimeOutputEnabled = false
        currentTimeline = nil
        source = .none
    }

    public func stop() {
        finishPartial(reason: .stopped)
        // A full playback stop invalidates prepared-next sidecars as well as
        // the current one. Otherwise a decoder that was opened for the next
        // item can keep reading after the player has stopped, with callbacks
        // retained by the coordinator even though no item can become current.
        preparedLookaheadAnalyzers.values.forEach { $0.finishPartial(reason: .stopped) }
        preparedLookaheadAnalyzers.removeAll()
        preparedLookaheadPreparationIDs.removeAll()
        preparedLookaheadWindows.removeAll()
        deferredPreparedLookaheadSources.removeAll()
        lookaheadDiagnosticReasons.removeAll()
        lookaheadDecoderFailures.removeAll()
        preparedLookaheadTapSinks.removeAll()
        activeRealtimeTapPreparationIDs.removeAll()
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
        setPreference(preference, for: identity)
    }

    public func setPreference(
        _ preference: TrackHapticsPreference,
        for identity: MusicHapticsIdentity
    ) {
        Task { [weak self] in
            try? await self?.store.setPreference(preference, for: identity)
        }
    }

    /// Awaitable form used when a runtime re-prepare must observe the newly
    /// persisted per-track override before resolving its plan.
    public func persistPreference(
        _ preference: TrackHapticsPreference,
        for identity: MusicHapticsIdentity
    ) async {
        try? await store.setPreference(preference, for: identity)
    }

    /// Reads the effective setting for a recording without changing the
    /// current runtime plan.  AppShell uses this for the playback-page toggle
    /// so its value reflects the user's setting while a sidecar is still
    /// preparing, rather than waiting for a plan to exist.
    public func effectiveEnabled(for identity: MusicHapticsIdentity) async -> Bool {
        guard isFeatureAvailable else { return false }
        let globalEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        return preference.effective(globalEnabled: globalEnabled)
    }

    /// Re-evaluates a prepared sidecar against the current global default.
    /// This intentionally does not check platform support: callers use it to
    /// preserve the three-state setting even when deciding whether a sidecar
    /// should be retained or discarded.
    public func effectiveEnabled(for preparation: MusicHapticsPlaybackPreparation) -> Bool {
        let globalEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        return preparation.preference.effective(globalEnabled: globalEnabled)
    }

    /// Returns the current track's effective preference without consulting
    /// the hardware.  A caller can use the platform policy separately while
    /// keeping `.enabled` as a real override of the global default.
    public func currentEffectiveEnabled() -> Bool {
        guard let currentPreparation else { return false }
        return effectiveEnabled(for: currentPreparation)
    }

    /// Immediately disables Haptics output for the current track while
    /// leaving the AVPlayer item, position and audio route untouched.  The
    /// active analyzer is paused and its partial checkpoint is retained so a
    /// later re-enable can resume from the current position.
    public func disableCurrentOutput() {
        runtimeOutputEnabled = false
        playbackIsPlaying = false
        rollingScheduler.pause()
        activeAnalysisSink?.pause()
        currentPreparation?.lookaheadAnalyzer?.pause()
        preparedLookaheadAnalyzers.values.forEach { $0.pause() }
        custom.stop()
        source = .none
        scheduleCurrentCheckpoint()
    }

    public func setGlobalEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        guard !enabled else { return }

        // The global value is the default for `.inherit`, not a hard power
        // switch.  An explicit `.enabled` preparation must remain valid even
        // after the global default is turned off.
        let preference = currentPreparation?.preference ?? .inherit
        guard !preference.effective(globalEnabled: enabled) else { return }

        // The preparation is being invalidated because its effective setting
        // is now off. Stop the actual sidecar output before clearing the
        // preparation; otherwise a running custom scheduler could outlive
        // the state reset and continue emitting haptics.
        disableCurrentOutput()
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
        guard isFeatureAvailable else { return }
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
        guard isFeatureAvailable else { return }
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
        // The sink is the authoritative ownership signal. A terminal result
        // from the realtime tap can race a progress snapshot, so do not let a late
        // snapshot report `tapAttached=false` after the playback engine has
        // already installed the pre-play mix.
        let tapAttached = analysisSnapshot.tapAttached
            || currentPreparation?.analysisSink?.tapIsAttached == true
            || currentPreparation?.realtimeTapSink?.tapIsAttached == true
        let decoderFailure = currentPreparation.flatMap {
            lookaheadDecoderFailures[$0.id]
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
            analysisFailureReason: analysisFailureReason?.rawValue,
            analysisFailureDetail: analysisFailureDetail,
            decoderFailureStage: decoderFailure?.diagnostic.rawValue,
            decoderFailureDomain: decoderFailure?.errorDomain,
            decoderFailureCode: decoderFailure?.errorCode,
            systemTimelineAvailable: currentSystemAvailability.timelineAvailable,
            fullTimelineExists: fullTimelineExists,
            partialExists: partialExists,
            tapAttached: tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat,
            analyzedRanges: analysisSnapshot.analyzedRanges,
            eventCount: eventCount == 0 ? analysisSnapshot.eventCount : eventCount,
            eventDensity: eventDensity,
            droppedFrames: analysisSnapshot.droppedFrames,
            droppedAudioDuration: analysisSnapshot.droppedAudioDuration,
            finishReason: analysisSnapshot.finishReason,
            timelineSuspiciouslySparse: sparse,
            analysisMode: analysisSnapshot.analysisMode,
            playbackPosition: currentPosition,
            analysisPosition: analysisSnapshot.analysisPosition,
            analysisLeadSeconds: analysisSnapshot.analysisPosition - currentPosition,
            analysisSpeedX: analysisSnapshot.analysisSpeedX,
            remoteAnalysisPosition: analysisSnapshot.remoteAnalysisPosition,
            realtimeAnalysisPosition: analysisSnapshot.realtimeAnalysisPosition,
            remoteAnalysisSpeedX: analysisSnapshot.remoteAnalysisSpeedX,
            realtimeAnalysisSpeedX: analysisSnapshot.realtimeAnalysisSpeedX,
            remoteDecoderState: analysisSnapshot.remoteDecoderState,
            currentEventSource: rollingScheduler.currentEventSource == .none
                ? analysisSnapshot.currentEventSource
                : rollingScheduler.currentEventSource,
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

    /// Returns the provenance of the plan actually selected for the current
    /// track.  Product/UI code should use this typed result instead of
    /// interpreting `planReason` strings or treating an ISRC as proof of a
    /// system Music Haptics match.
    public func currentAssetInfo() async -> MusicHapticsAssetInfo {
        guard let identity = currentIdentity else {
            return MusicHapticsAssetInfo(
                origin: .none,
                state: .unavailable
            )
        }
        let globalEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        guard preference.effective(globalEnabled: globalEnabled), runtimeOutputEnabled else {
            return MusicHapticsAssetInfo(
                origin: .none,
                state: .disabled
            )
        }

        switch currentPlan {
        case .system:
            guard currentSystemAvailability.canUseTimeline else {
                return MusicHapticsAssetInfo(
                    origin: .none,
                    state: .unavailable,
                    isrc: identity.isrc
                )
            }
            return MusicHapticsAssetInfo(
                origin: .systemISRC,
                state: .available,
                isrc: identity.isrc,
                isCurrentlyUsed: source == .system
            )
        case let .custom(timeline):
            return MusicHapticsAssetInfo(
                origin: .algorithmGenerated,
                state: .available,
                isrc: identity.isrc,
                algorithmVersion: timeline.algorithmVersion,
                coverage: timeline.analysisCoverage,
                isCurrentlyUsed: source == .custom
            )
        case .analyze, .analyzeLookahead:
            return MusicHapticsAssetInfo(
                origin: .algorithmGenerated,
                state: .generating,
                isrc: identity.isrc,
                algorithmVersion: MusicHapticsTimeline.algorithmVersion,
                coverage: analysisSnapshot.coverage,
                isCurrentlyUsed: source == .analyzing && !hapticsSuspended
            )
        case .disabled:
            return MusicHapticsAssetInfo(
                origin: .none,
                state: .unavailable,
                isrc: identity.isrc
            )
        }
    }

    /// Returns runtime provenance only when it belongs to the requested
    /// server-scoped recording. An information sheet may outlive a track
    /// switch, so callers must not treat the coordinator's latest snapshot as
    /// belonging to an arbitrary `Track`.
    public func currentAssetInfo(
        for identity: MusicHapticsIdentity
    ) async -> MusicHapticsAssetInfo? {
        guard isCurrentIdentity(identity) else { return nil }
        let info = await currentAssetInfo()
        guard isCurrentIdentity(identity) else { return nil }
        return info
    }

    /// Resolves persisted provenance for a non-current track.  It never
    /// exposes the runtime state of another track, so an open information
    /// sheet cannot accidentally display the currently playing song's plan.
    public func assetInfo(for identity: MusicHapticsIdentity) async -> MusicHapticsAssetInfo {
        guard isFeatureAvailable else {
            return MusicHapticsAssetInfo(origin: .none, state: .unavailable)
        }
        let globalEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        guard preference.effective(globalEnabled: globalEnabled) else {
            return MusicHapticsAssetInfo(origin: .none, state: .disabled)
        }

        let availability = await system.availability(isrc: identity.isrc)
        if availability.canUseTimeline {
            return MusicHapticsAssetInfo(
                origin: .systemISRC,
                state: .available,
                isrc: identity.isrc
            )
        }
        if let timeline = try? await store.timeline(for: identity) {
            return MusicHapticsAssetInfo(
                origin: .algorithmGenerated,
                state: .available,
                isrc: identity.isrc,
                algorithmVersion: timeline.algorithmVersion,
                coverage: timeline.analysisCoverage
            )
        }
        if let partial = inMemoryPartial(for: identity) {
            return MusicHapticsAssetInfo(
                origin: .algorithmGenerated,
                state: .generating,
                isrc: identity.isrc,
                algorithmVersion: MusicHapticsTimeline.algorithmVersion,
                coverage: partial.coverage
            )
        }
        if let partial = try? await store.partial(for: identity) {
            return MusicHapticsAssetInfo(
                origin: .algorithmGenerated,
                state: .generating,
                isrc: identity.isrc,
                algorithmVersion: MusicHapticsTimeline.algorithmVersion,
                coverage: partial.coverage
            )
        }
        // Capability alone is not evidence that this non-current track has an
        // analyzer running. Without a persisted timeline or partial checkpoint
        // the truthful state is unavailable, rather than a fabricated
        // "generating" state.
        return MusicHapticsAssetInfo(
            origin: .none,
            state: .unavailable,
            isrc: identity.isrc
        )
    }

    private func isCurrentIdentity(_ identity: MusicHapticsIdentity) -> Bool {
        guard let currentIdentity else { return false }
        if let currentGlobalID = currentIdentity.globalID,
           let requestedGlobalID = identity.globalID {
            return currentGlobalID == requestedGlobalID
        }
        guard let currentServerID = currentIdentity.serverID,
              let currentRemoteID = currentIdentity.remoteID,
              let requestedServerID = identity.serverID,
              let requestedRemoteID = identity.remoteID
        else { return false }
        return currentServerID == requestedServerID && currentRemoteID == requestedRemoteID
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
        if storedFull || storedPartial,
           currentPreparation?.id == preparationID {
            checkpointPersistedCoverage[preparationID] = checkpointToPersist.coverage
        }

        let eventDensity = checkpointToPersist.duration > 0
            ? Double(checkpointToPersist.events.count) / checkpointToPersist.duration
            : 0
        let suspiciouslySparse = completeTimeline?.timelineSuspiciouslySparse
            ?? (checkpointToPersist.duration > 120
                && checkpointToPersist.events.count < max(8, Int(checkpointToPersist.duration / 30)))
        musicHapticsLogger.debug(
            "HAPTICS_ANALYSIS track=\(self.diagnosticTrack(identity), privacy: .public) mode=\(result.snapshot.analysisMode.rawValue, privacy: .public) coverage=\(result.snapshot.coverage, privacy: .public) events=\(result.snapshot.eventCount, privacy: .public) transient_count=\(result.snapshot.transientCount, privacy: .public) continuous_count=\(result.snapshot.continuousCount, privacy: .public) event_density=\(eventDensity, privacy: .public) dropped_frames=\(result.snapshot.droppedFrames, privacy: .public) dropped_audio_duration=\(result.snapshot.droppedAudioDuration, privacy: .public) finish_reason=\(result.finishReason.rawValue, privacy: .public) tap_attached=\(result.snapshot.tapAttached, privacy: .public) pcm_format=\(self.formatDescription(result.snapshot.pcmFormat), privacy: .public) analysis_position=\(result.snapshot.analysisPosition, privacy: .public) remote_analysis_position=\(result.snapshot.remoteAnalysisPosition, privacy: .public) realtime_analysis_position=\(result.snapshot.realtimeAnalysisPosition, privacy: .public) analysis_lead=\(result.snapshot.analysisPosition - self.currentPosition, privacy: .public) remote_speed=\(result.snapshot.remoteAnalysisSpeedX, privacy: .public)x realtime_speed=\(result.snapshot.realtimeAnalysisSpeedX, privacy: .public)x analysis_speed=\(result.snapshot.analysisSpeedX, privacy: .public)x remote_decoder_state=\(result.snapshot.remoteDecoderState.rawValue, privacy: .public) scheduled_until=\(self.rollingScheduler.scheduledUntil, privacy: .public) current_event_source=\(result.snapshot.currentEventSource.rawValue, privacy: .public) tempo=\(result.snapshot.tempoBPM ?? -1, privacy: .public) beat_confidence=\(result.snapshot.beatConfidence, privacy: .public) analyzed_ranges=\(self.rangeDescription(result.snapshot.analyzedRanges), privacy: .public) timeline_suspiciously_sparse=\(suspiciouslySparse, privacy: .public)"
        )
        if storedFull {
            musicHapticsLogger.debug(
                "HAPTICS_TIMELINE_COMPLETE track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(checkpointToPersist.coverage, privacy: .public) events=\(checkpointToPersist.events.count, privacy: .public) analysis_position=\(result.snapshot.analysisPosition, privacy: .public) remote_speed=\(result.snapshot.remoteAnalysisSpeedX, privacy: .public)x"
            )
        }
        if let timeline = completeTimeline, timeline.timelineSuspiciouslySparse {
            musicHapticsLogger.debug(
                "HAPTICS_ANALYSIS timeline_suspiciously_sparse=true track=\(self.diagnosticTrack(identity), privacy: .public) duration=\(timeline.duration, privacy: .public) events=\(timeline.events.count, privacy: .public) density=\(timeline.eventDensity, privacy: .public)"
            )
        }

        guard currentPreparation?.id == preparationID else { return }
        // A sidecar failure result can arrive after the pre-play realtime
        // fallback has already produced useful windows. Do not replace those
        // live diagnostics with the sidecar's zero-coverage terminal result.
        if result.finishReason == .playbackFailure,
           activeRealtimeTapPreparationIDs.contains(preparationID),
           result.snapshot.analysisMode != .realtimeTap {
            return
        }
        // The original-stream and realtime tap callbacks are independent.
        // Merge the terminal snapshot with the live source instead of
        // replacing it, otherwise a fast remote EOF would erase tap
        // throughput/drop counters (or a tap result would erase a remote
        // decoder failure detail).
        acceptAnalysisSnapshot(result.snapshot)
        let remoteFailureIsActive = analysisSnapshot.remoteDecoderState == .failed
        if result.finishReason != .playbackFailure,
           !remoteFailureIsActive {
            if result.snapshot.analysisMode == .remoteOriginal {
                currentPlanReason = "analysis_rolling_active"
            }
            analysisFailureReason = nil
        }
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
        // Progress callbacks and the terminal result are delivered by separate
        // utility tasks. Do not let a late startup snapshot regress the final
        // coverage/event count shown to the user.
        guard snapshot.finishReason != nil || analysisSnapshot.finishReason == nil else { return }
        guard snapshot.coverage >= analysisSnapshot.coverage
                || snapshot.finishReason != nil
        else { return }
        let previous = analysisSnapshot
        analysisSnapshot = snapshot
        // Remote and realtime snapshots arrive on independent utility tasks.
        // Preserve the other source's counters when one callback is newer;
        // otherwise a fast remote progress update could make a live tap look
        // detached or reset its throughput to zero.
        analysisSnapshot.tapAttached = snapshot.tapAttached || previous.tapAttached
        analysisSnapshot.droppedFrames = max(snapshot.droppedFrames, previous.droppedFrames)
        analysisSnapshot.droppedAudioDuration = max(
            snapshot.droppedAudioDuration,
            previous.droppedAudioDuration
        )
        analysisSnapshot.analyzedRanges = mergeAnalysisRanges(
            previous.analyzedRanges + snapshot.analyzedRanges
        )
        analysisSnapshot.analysisPosition = max(snapshot.analysisPosition, previous.analysisPosition)
        analysisSnapshot.analysisSpeedX = max(snapshot.analysisSpeedX, previous.analysisSpeedX)
        analysisSnapshot.remoteAnalysisPosition = max(
            snapshot.remoteAnalysisPosition,
            previous.remoteAnalysisPosition
        )
        analysisSnapshot.remoteAnalysisSpeedX = max(
            snapshot.remoteAnalysisSpeedX,
            previous.remoteAnalysisSpeedX
        )
        analysisSnapshot.realtimeAnalysisPosition = max(
            snapshot.realtimeAnalysisPosition,
            previous.realtimeAnalysisPosition
        )
        analysisSnapshot.realtimeAnalysisSpeedX = max(
            snapshot.realtimeAnalysisSpeedX,
            previous.realtimeAnalysisSpeedX
        )
        if analysisSnapshot.pcmFormat == nil {
            analysisSnapshot.pcmFormat = previous.pcmFormat
        }
        if snapshot.remoteDecoderState == .idle,
           previous.remoteDecoderState != .idle {
            analysisSnapshot.remoteDecoderState = previous.remoteDecoderState
        }
        if rollingScheduler.currentEventSource != .none {
            analysisSnapshot.currentEventSource = rollingScheduler.currentEventSource
        }
        if snapshot.droppedFrames > previous.droppedFrames {
            musicHapticsLogger.debug(
                "HAPTICS_PCM_STARVATION track=\(self.diagnosticTrack(self.currentIdentity), privacy: .public) dropped_frames=\(snapshot.droppedFrames, privacy: .public) dropped_audio_duration=\(snapshot.droppedAudioDuration, privacy: .public)"
            )
        }
    }

    private func handleLookaheadFailure(
        preparationID: UUID,
        identity: MusicHapticsIdentity
    ) {
        failedLookaheadPreparationIDs.insert(preparationID)
        let decoderReason = lookaheadDiagnosticReasons[preparationID] ?? .remoteDecoderFailed
        lookaheadDiagnosticReasons[preparationID] = decoderReason
        musicHapticsLogger.debug(
            "HAPTICS_LOOKAHEAD_FAILED track=\(self.diagnosticTrack(identity), privacy: .public) reason=\(decoderReason.rawValue, privacy: .public)"
        )
        guard let preparation = currentPreparation,
              preparation.id == preparationID else { return }
        if activateRealtimeTapIfAvailable(
            preparation,
            identity: identity
        ) {
            // Keep the already scheduled lookahead and the realtime tap alive.
            // A remote decoder failure is a source switch, never a reason to
            // stop Core Haptics output or the authoritative AVPlayer.
            currentPlanReason = "remote_decoder_failed_realtime_continuity"
            analysisFailureReason = decoderReason
        } else {
            failClosedLookahead(preparationID: preparationID, identity: identity)
        }
    }

    private func handleLookaheadDecoderFailure(
        _ failure: MusicHapticsDecoderFailure,
        preparationID: UUID,
        identity: MusicHapticsIdentity
    ) {
        guard currentPreparation?.id == preparationID
                || preparedLookaheadPreparationIDs.contains(preparationID)
        else { return }
        lookaheadDecoderFailures[preparationID] = failure
        lookaheadDiagnosticReasons[preparationID] = failure.diagnostic
        if currentPreparation?.id == preparationID {
            analysisFailureDetail = failure.summary
            analysisFailureReason = failure.diagnostic
        }
        musicHapticsLogger.debug(
            "HAPTICS_REMOTE_DECODER_FAILURE track=\(self.diagnosticTrack(identity), privacy: .public) stage=\(failure.diagnostic.rawValue, privacy: .public) domain=\(failure.errorDomain, privacy: .public) code=\(failure.errorCode, privacy: .public)"
        )
    }

    private func activateRealtimeTapIfAvailable(
        _ preparation: MusicHapticsPlaybackPreparation,
        identity: MusicHapticsIdentity
    ) -> Bool {
        guard let fallback = preparation.realtimeTapSink,
              fallback.tapIsAttached else {
            return false
        }
        activeRealtimeTapPreparationIDs.insert(preparation.id)
        if playbackIsPlaying,
           runtimeOutputEnabled,
           !hapticsSuspended,
           !isInBackground,
           !audioBuffering {
            fallback.resume()
        } else {
            fallback.pause()
        }
        source = .analyzing
        currentPlanReason = "realtime_tap_ready"
        analysisFailureDetail = lookaheadDecoderFailures[preparation.id]?.summary
        analysisSnapshot.tapAttached = true
        musicHapticsLogger.debug(
            "HAPTICS_SOURCE_SWITCH track=\(self.diagnosticTrack(identity), privacy: .public) source=realtime_tap reason=preplay_ready"
        )
        return true
    }

    private func failClosedLookahead(
        preparationID: UUID,
        identity: MusicHapticsIdentity
    ) {
        failedLookaheadPreparationIDs.insert(preparationID)
        activeRealtimeTapPreparationIDs.remove(preparationID)
        lookaheadDiagnosticReasons[preparationID] = .realtimeFallbackForbidden
        musicHapticsLogger.debug(
            "HAPTICS_REALTIME_TAP_UNAVAILABLE track=\(self.diagnosticTrack(identity), privacy: .public) reason=\(MusicHapticsAnalysisDiagnostic.realtimeFallbackForbidden.rawValue, privacy: .public)"
        )
        guard currentPreparation?.id == preparationID else { return }
        source = .none
        currentPlanReason = MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue
        analysisFailureReason = .noHapticEventSource
        // Do not stop an already-running scheduler/player here. If a decoder
        // fails after a future slice has been committed, that output remains
        // valid until the AVPlayer clock rebases it. There is simply no new
        // source after the committed horizon when no tap was attached.
    }

    private func handleLookaheadDiagnostic(
        _ diagnostic: MusicHapticsAnalysisDiagnostic,
        preparationID: UUID,
        identity: MusicHapticsIdentity
    ) {
        guard currentPreparation?.id == preparationID
                || preparedLookaheadPreparationIDs.contains(preparationID)
        else { return }
        lookaheadDiagnosticReasons[preparationID] = diagnostic
        if currentPreparation?.id == preparationID {
            if diagnostic == .remoteOriginalRefresh {
                currentPlanReason = diagnostic.rawValue
            } else {
                analysisFailureReason = diagnostic
                currentPlanReason = diagnostic.rawValue
            }
        }
        musicHapticsLogger.debug(
            "HAPTICS_ANALYSIS_DIAGNOSTIC track=\(self.diagnosticTrack(identity), privacy: .public) reason=\(diagnostic.rawValue, privacy: .public)"
        )
    }

    private func acceptRealtimeWindow(
        _ window: MusicHapticsAnalysisWindow,
        preparationID: UUID,
        expectedPlan: MusicHapticsPlanKind = .analyze
    ) {
        guard currentPreparation?.id == preparationID,
              playbackIsPlaying,
              runtimeOutputEnabled,
              !hapticsSuspended,
              !isInBackground,
              !audioBuffering,
              currentPlan.kind == expectedPlan
        else { return }

        if expectedPlan == .analyzeLookahead {
            // Realtime PCM and the original-stream analyzer share one output
            // arbiter. The tap never plays directly here: an overlapping
            // remote window wins, while realtime coverage fills a slow or
            // temporarily unavailable lookahead gap.
            let previousEventSource = rollingScheduler.currentEventSource
            let scheduled = rollingScheduler.ingest(window)
            mergeRealtimeSnapshot(window)
            playScheduledWindows(scheduled, position: currentPosition)
            logEventSourceChange(
                from: previousEventSource,
                to: rollingScheduler.currentEventSource,
                identity: currentIdentity,
                reason: "realtime_gap"
            )
            musicHapticsLogger.debug(
                "HAPTICS_REALTIME_ANALYSIS playback=\(self.currentPosition, privacy: .public) analysis=\(window.analysisPosition, privacy: .public) lead=\(window.analysisPosition - self.currentPosition, privacy: .public) speed=\(window.analysisSpeedX, privacy: .public)x scheduled_until=\(self.rollingScheduler.scheduledUntil, privacy: .public) source=\(self.rollingScheduler.currentEventSource.rawValue, privacy: .public)"
            )
            return
        }

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
            analyzedRanges: mergeAnalysisRanges(
                analysisSnapshot.analyzedRanges + windowRange(window)
            ),
            coverage: max(analysisSnapshot.coverage, window.coverage),
            eventCount: max(analysisSnapshot.eventCount, window.eventCount),
            droppedFrames: analysisSnapshot.droppedFrames,
            droppedAudioDuration: analysisSnapshot.droppedAudioDuration,
            finishReason: analysisSnapshot.finishReason,
            analysisMode: .realtimeTap,
            analysisPosition: max(analysisSnapshot.analysisPosition, window.analysisPosition),
            analysisSpeedX: window.analysisSpeedX,
            remoteAnalysisPosition: analysisSnapshot.remoteAnalysisPosition,
            realtimeAnalysisPosition: max(analysisSnapshot.realtimeAnalysisPosition, window.analysisPosition),
            remoteAnalysisSpeedX: analysisSnapshot.remoteAnalysisSpeedX,
            realtimeAnalysisSpeedX: max(analysisSnapshot.realtimeAnalysisSpeedX, window.analysisSpeedX),
            remoteDecoderState: analysisSnapshot.remoteDecoderState,
            currentEventSource: .realtimeTap,
            tempoBPM: window.tempoBPM ?? analysisSnapshot.tempoBPM,
            beatConfidence: max(analysisSnapshot.beatConfidence, window.beatConfidence),
            transientCount: max(analysisSnapshot.transientCount, max(window.transientCount, transientCount)),
            continuousCount: max(analysisSnapshot.continuousCount, max(window.continuousCount, continuousCount)),
            mixerDiagnostics: window.mixerDiagnostics
        )
        musicHapticsLogger.debug(
            "HAPTICS_REALTIME_ANALYSIS playback=\(self.currentPosition, privacy: .public) analysis=\(window.analysisPosition, privacy: .public) lead=\(window.analysisPosition - self.currentPosition, privacy: .public) speed=\(window.analysisSpeedX, privacy: .public)x events=\(window.events.count, privacy: .public) source=realtime_tap"
        )
    }

    private func mergeRealtimeSnapshot(_ window: MusicHapticsAnalysisWindow) {
        let source = rollingScheduler.currentEventSource == .none
            ? MusicHapticsEventSource.realtimeTap
            : rollingScheduler.currentEventSource
        analysisSnapshot = MusicHapticsAnalysisSnapshot(
            tapAttached: analysisSnapshot.tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat,
            analyzedRanges: mergeAnalysisRanges(
                analysisSnapshot.analyzedRanges + windowRange(window)
            ),
            coverage: max(analysisSnapshot.coverage, window.coverage),
            eventCount: max(analysisSnapshot.eventCount, window.eventCount),
            droppedFrames: analysisSnapshot.droppedFrames,
            droppedAudioDuration: analysisSnapshot.droppedAudioDuration,
            finishReason: analysisSnapshot.finishReason,
            analysisMode: analysisSnapshot.analysisMode == .remoteOriginal ? .remoteOriginal : .realtimeTap,
            analysisPosition: max(analysisSnapshot.analysisPosition, window.analysisPosition),
            analysisSpeedX: max(analysisSnapshot.analysisSpeedX, window.analysisSpeedX),
            remoteAnalysisPosition: analysisSnapshot.remoteAnalysisPosition,
            realtimeAnalysisPosition: max(analysisSnapshot.realtimeAnalysisPosition, window.analysisPosition),
            remoteAnalysisSpeedX: analysisSnapshot.remoteAnalysisSpeedX,
            realtimeAnalysisSpeedX: max(analysisSnapshot.realtimeAnalysisSpeedX, window.analysisSpeedX),
            remoteDecoderState: analysisSnapshot.remoteDecoderState,
            currentEventSource: source,
            tempoBPM: window.tempoBPM ?? analysisSnapshot.tempoBPM,
            beatConfidence: max(analysisSnapshot.beatConfidence, window.beatConfidence),
            transientCount: max(analysisSnapshot.transientCount, window.transientCount),
            continuousCount: max(analysisSnapshot.continuousCount, window.continuousCount),
            mixerDiagnostics: window.mixerDiagnostics
        )
    }

    private func acceptRealtimeTapWindow(
        _ window: MusicHapticsAnalysisWindow,
        preparationID: UUID
    ) {
        guard activeRealtimeTapPreparationIDs.contains(preparationID) else { return }
        acceptRealtimeWindow(
            window,
            preparationID: preparationID,
            expectedPlan: .analyzeLookahead
        )
    }

    private func acceptRealtimeTapSnapshot(
        _ snapshot: MusicHapticsAnalysisSnapshot,
        preparationID: UUID
    ) {
        guard currentPreparation?.id == preparationID
                || preparedLookaheadPreparationIDs.contains(preparationID)
        else { return }
        guard currentPreparation?.id == preparationID else { return }
        guard activeRealtimeTapPreparationIDs.contains(preparationID) else { return }
        let previous = analysisSnapshot
        analysisSnapshot = MusicHapticsAnalysisSnapshot(
            tapAttached: analysisSnapshot.tapAttached || snapshot.tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat ?? snapshot.pcmFormat,
            analyzedRanges: mergeAnalysisRanges(
                analysisSnapshot.analyzedRanges + snapshot.analyzedRanges
            ),
            coverage: max(analysisSnapshot.coverage, snapshot.coverage),
            eventCount: max(analysisSnapshot.eventCount, snapshot.eventCount),
            droppedFrames: max(analysisSnapshot.droppedFrames, snapshot.droppedFrames),
            droppedAudioDuration: max(analysisSnapshot.droppedAudioDuration, snapshot.droppedAudioDuration),
            finishReason: analysisSnapshot.finishReason,
            analysisMode: analysisSnapshot.analysisMode == .remoteOriginal ? .remoteOriginal : .realtimeTap,
            analysisPosition: max(analysisSnapshot.analysisPosition, snapshot.analysisPosition),
            analysisSpeedX: max(analysisSnapshot.analysisSpeedX, snapshot.analysisSpeedX),
            remoteAnalysisPosition: analysisSnapshot.remoteAnalysisPosition,
            realtimeAnalysisPosition: max(analysisSnapshot.realtimeAnalysisPosition, snapshot.realtimeAnalysisPosition),
            remoteAnalysisSpeedX: analysisSnapshot.remoteAnalysisSpeedX,
            realtimeAnalysisSpeedX: max(analysisSnapshot.realtimeAnalysisSpeedX, snapshot.realtimeAnalysisSpeedX),
            remoteDecoderState: analysisSnapshot.remoteDecoderState,
            currentEventSource: rollingScheduler.currentEventSource == .none
                ? .realtimeTap
                : rollingScheduler.currentEventSource,
            tempoBPM: snapshot.tempoBPM ?? analysisSnapshot.tempoBPM,
            beatConfidence: max(analysisSnapshot.beatConfidence, snapshot.beatConfidence),
            transientCount: max(analysisSnapshot.transientCount, snapshot.transientCount),
            continuousCount: max(analysisSnapshot.continuousCount, snapshot.continuousCount),
            mixerDiagnostics: snapshot.mixerDiagnostics
        )
        if snapshot.droppedFrames > previous.droppedFrames {
            musicHapticsLogger.debug(
                "HAPTICS_PCM_STARVATION track=\(self.diagnosticTrack(self.currentIdentity), privacy: .public) dropped_frames=\(snapshot.droppedFrames, privacy: .public) dropped_audio_duration=\(snapshot.droppedAudioDuration, privacy: .public)"
            )
        }
    }

    private func handleRealtimeTapResult(
        _ result: MusicHapticsAnalysisResult,
        preparationID: UUID,
        favorite: Bool
    ) async {
        // The realtime tap is attached up front and may run for the whole
        // track. It must not replace a complete original-stream timeline that
        // has already been persisted; it remains a continuity source, not a
        // second competing cache writer.
        guard activeRealtimeTapPreparationIDs.contains(preparationID) else { return }
        if result.snapshot.analysisMode == .realtimeTap,
           fullTimelineExists,
           analysisSnapshot.remoteDecoderState == .complete {
            return
        }
        await handleAnalysisResult(
            result,
            preparationID: preparationID,
            favorite: favorite
        )
    }

    private func acceptLookaheadWindow(
        _ window: MusicHapticsAnalysisWindow,
        preparationID: UUID
    ) {
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
        let previousEventSource = rollingScheduler.currentEventSource
        let scheduled = rollingScheduler.ingest(window)
        analysisSnapshot = MusicHapticsAnalysisSnapshot(
            tapAttached: analysisSnapshot.tapAttached,
            pcmFormat: analysisSnapshot.pcmFormat,
            analyzedRanges: mergeAnalysisRanges(
                analysisSnapshot.analyzedRanges + windowRange(window)
            ),
            coverage: max(analysisSnapshot.coverage, window.coverage),
            eventCount: max(analysisSnapshot.eventCount, window.eventCount),
            droppedFrames: analysisSnapshot.droppedFrames,
            droppedAudioDuration: analysisSnapshot.droppedAudioDuration,
            finishReason: analysisSnapshot.finishReason,
            analysisMode: .remoteOriginal,
            analysisPosition: max(analysisSnapshot.analysisPosition, window.analysisPosition),
            analysisSpeedX: max(analysisSnapshot.analysisSpeedX, window.analysisSpeedX),
            remoteAnalysisPosition: max(analysisSnapshot.remoteAnalysisPosition, window.analysisPosition),
            realtimeAnalysisPosition: analysisSnapshot.realtimeAnalysisPosition,
            remoteAnalysisSpeedX: max(analysisSnapshot.remoteAnalysisSpeedX, window.analysisSpeedX),
            realtimeAnalysisSpeedX: analysisSnapshot.realtimeAnalysisSpeedX,
            remoteDecoderState: analysisSnapshot.remoteDecoderState,
            currentEventSource: rollingScheduler.currentEventSource,
            tempoBPM: window.tempoBPM ?? analysisSnapshot.tempoBPM,
            beatConfidence: max(analysisSnapshot.beatConfidence, window.beatConfidence),
            transientCount: max(analysisSnapshot.transientCount, window.transientCount),
            continuousCount: max(analysisSnapshot.continuousCount, window.continuousCount),
            mixerDiagnostics: window.mixerDiagnostics
        )
        if runtimeOutputEnabled,
           !hapticsSuspended,
           !isInBackground,
           !audioBuffering {
            playScheduledWindows(scheduled, position: currentPosition)
        }
        logEventSourceChange(
            from: previousEventSource,
            to: rollingScheduler.currentEventSource,
            identity: currentIdentity,
            reason: "original_stream_ready"
        )
        musicHapticsLogger.debug(
            "HAPTICS_REMOTE_ANALYSIS playback=\(self.currentPosition, privacy: .public) analysis=\(window.analysisPosition, privacy: .public) lead=\(window.analysisPosition - self.currentPosition, privacy: .public) speed=\(window.analysisSpeedX, privacy: .public)x scheduled_until=\(self.rollingScheduler.scheduledUntil, privacy: .public) rolling_windows=\(self.rollingScheduler.rollingWindowCount, privacy: .public) source=\(self.rollingScheduler.currentEventSource.rawValue, privacy: .public)"
        )
    }

    private func logEventSourceChange(
        from previous: MusicHapticsEventSource,
        to current: MusicHapticsEventSource,
        identity: MusicHapticsIdentity?,
        reason: String
    ) {
        guard previous != current, current != .none else { return }
        musicHapticsLogger.debug(
            "HAPTICS_SOURCE_SWITCH track=\(self.diagnosticTrack(identity), privacy: .public) source=\(current.rawValue, privacy: .public) previous=\(previous.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
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
        guard runtimeOutputEnabled, !hapticsSuspended, !audioBuffering else { return }
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
        guard runtimeOutputEnabled,
              !hapticsSuspended,
              !audioBuffering,
              custom.canProduceOutput else { return }
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
        let tapAttached = preparation.analysisSink?.tapIsAttached == true
            || preparation.realtimeTapSink?.tapIsAttached == true
        guard let partial = request.partial
        else {
            return MusicHapticsAnalysisSnapshot(
                tapAttached: tapAttached,
                analysisMode: request.analysisSource.mode,
            )
        }
        return MusicHapticsAnalysisSnapshot(
            tapAttached: tapAttached,
            analyzedRanges: partial.analyzedRanges,
            coverage: partial.coverage,
            eventCount: partial.events.count,
            analysisMode: request.analysisSource.mode,
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
        switch plan {
        case let .custom(timeline):
            coverage = timeline.analysisCoverage
            eventCount = timeline.events.count
            eventDensity = timeline.eventDensity
            sparse = timeline.timelineSuspiciouslySparse
        case let .analyze(request), let .analyzeLookahead(request):
            coverage = request.partial?.coverage
            eventCount = request.partial?.events.count ?? 0
            eventDensity = request.partial.map { $0.duration > 0 ? Double($0.events.count) / $0.duration : 0 }
            sparse = request.partial.map {
                $0.duration > 120 && $0.events.count < max(8, Int($0.duration / 30))
            } ?? false
        case .disabled, .system:
            coverage = nil
            eventCount = 0
            eventDensity = nil
            sparse = false
        }
        musicHapticsLogger.debug(
            "HAPTICS_PLAN track=\(self.diagnosticTrack(identity), privacy: .public) plan=\(plan.kind.rawValue, privacy: .public) reason=\(reason, privacy: .public) hasISRC=\(systemAvailability.hasISRC, privacy: .public) systemActive=\(systemAvailability.active, privacy: .public) systemTimelineAvailable=\(systemAvailability.timelineAvailable, privacy: .public) fullTimelineExists=\(fullTimelineExists, privacy: .public) partialExists=\(partialExists, privacy: .public) coverage=\(coverage ?? -1, privacy: .public) events=\(eventCount, privacy: .public) event_density=\(eventDensity ?? -1, privacy: .public) timeline_suspiciously_sparse=\(sparse, privacy: .public)"
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

    private func diagnosticTrack(_ identity: MusicHapticsIdentity?) -> String {
        guard let identity else { return "unknown" }
        return diagnosticTrack(identity)
    }

    private func formatDescription(_ format: MusicHapticsPCMFormat?) -> String {
        guard let format else { return "none" }
        return "\(format.sampleRate)Hz/\(format.channels)ch/\(format.sampleType.rawValue)/\(format.interleaved ? "interleaved" : "planar")"
    }

    private func windowRange(_ window: MusicHapticsAnalysisWindow) -> [MusicHapticsTimeRange] {
        guard window.endTime > window.startTime else { return [] }
        return [MusicHapticsTimeRange(lowerBound: window.startTime, upperBound: window.endTime)]
    }

    private func mergeAnalysisRanges(
        _ input: [MusicHapticsTimeRange]
    ) -> [MusicHapticsTimeRange] {
        var result: [MusicHapticsTimeRange] = []
        for range in input.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.upperBound > range.lowerBound else { continue }
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound + MusicHapticsTimeRange.adjacencyTolerance {
                result[result.count - 1] = MusicHapticsTimeRange(
                    lowerBound: last.lowerBound,
                    upperBound: max(last.upperBound, range.upperBound)
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func rangeDescription(_ ranges: [MusicHapticsTimeRange]) -> String {
        ranges.prefix(32)
            .map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) }
            .joined(separator: ",")
    }
}
