import Foundation
import OSLog

#if os(iOS)
import CoreHaptics
import MediaAccessibility
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
        timelineSuspiciouslySparse: Bool = false
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
    }
}

/// Pure ordering rule for the one authoritative playback plan. The resolver
/// has no AVFoundation dependency, so all four branches can be regression
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
        if let fullTimeline,
           fullTimeline.isComplete,
           fullTimeline.algorithmVersion == MusicHapticsTimeline.algorithmVersion,
           fullTimeline.duration.isFinite,
           fullTimeline.duration > 0,
           fullTimeline.identity.matchConfidence(with: request.identity) >= 0.82 {
            return (.custom(fullTimeline), "timeline_available")
        }
        guard customHapticsSupported else { return (.disabled, "custom_haptics_unavailable") }
        guard request.duration > 0 else { return (.disabled, "invalid_duration") }
        return (.analyze(
            MusicHapticsAnalysisRequest(
                identity: request.identity,
                favorite: request.favorite,
                duration: request.duration,
                partial: partial
            )
        ), partial == nil ? "no_timeline" : "resume_partial")
    }
}

@MainActor
public final class SystemMusicHapticsAdapter {
    public init() {}

    public func availability(isrc: String?) async -> MusicHapticsSystemAvailability {
        let hasISRC = !(isrc?.isEmpty ?? true)
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
        #if os(iOS)
        MAMusicHapticsManager.shared.isActive
        #else
        false
        #endif
    }
}

@MainActor
final class CustomMusicHapticsEngine {
    #if os(iOS)
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    #endif

    var supportsHaptics: Bool {
        #if os(iOS)
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        false
        #endif
    }

    func play(_ timeline: MusicHapticsTimeline, offset: TimeInterval) throws {
        #if os(iOS)
        guard supportsHaptics else { return }
        let engine = try prepareEngine()
        let events = timeline.events.compactMap { event -> CHHapticEvent? in
            switch event.kind {
            case .transient:
                return CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: parameters(for: event),
                    relativeTime: event.time
                )
            case .continuous:
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: parameters(for: event),
                    relativeTime: event.time,
                    duration: event.duration ?? 0.1
                )
            }
        }
        let pattern = try CHHapticPattern(events: events, parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        self.player = player
        try player.seek(toOffset: max(0, offset))
        try player.start(atTime: CHHapticTimeImmediate)
        #endif
    }

    func pause() {
        #if os(iOS)
        try? player?.pause(atTime: CHHapticTimeImmediate)
        #endif
    }

    func resume(at offset: TimeInterval) {
        #if os(iOS)
        do {
            try player?.seek(toOffset: max(0, offset))
            try player?.resume(atTime: CHHapticTimeImmediate)
        } catch {
            stop()
        }
        #endif
    }

    func seek(to offset: TimeInterval, playing: Bool) {
        #if os(iOS)
        do {
            try player?.seek(toOffset: max(0, offset))
            if playing { try player?.resume(atTime: CHHapticTimeImmediate) }
        } catch {
            stop()
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        #endif
    }

    #if os(iOS)
    private func parameters(for event: MusicHapticsEvent) -> [CHHapticEventParameter] {
        [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(event.intensity, 0.88)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness),
        ]
    }

    private func prepareEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.player = nil }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in try? self?.engine?.start() }
        }
        try engine.start()
        self.engine = engine
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

    public init(
        id: UUID = UUID(),
        identity: MusicHapticsIdentity,
        favorite: Bool,
        plan: MusicHapticsPlaybackPlan,
        reason: String,
        systemAvailability: MusicHapticsSystemAvailability,
        fullTimelineExists: Bool,
        partialExists: Bool,
        analysisSink: (any MusicHapticsAnalysisSink)?
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
    private let defaults: UserDefaults
    private var currentIdentity: MusicHapticsIdentity?
    private var currentTimeline: MusicHapticsTimeline?
    private var currentPreparation: MusicHapticsPlaybackPreparation?
    private var activeAnalysisSink: (any MusicHapticsAnalysisSink)?
    private var currentFavorite = false
    private var currentPosition: TimeInterval = 0
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
    /// Keeps a just-finished checkpoint visible while its actor-owned store
    /// write is in flight. This closes the rapid A→B→A race without making
    /// playback wait for disk I/O.
    private var inMemoryPartials: [String: MusicHapticsPartialCheckpoint] = [:]

    public init(
        store: MusicHapticsStore = MusicHapticsStore(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
    }

    public var supportsHaptics: Bool { custom.supportsHaptics }

    /// Resolves system/custom/analyze exactly once and creates only the
    /// lightweight PCM sink for the analyze branch. It never opens a URL or
    /// waits for AVAsset metadata.
    public func preparePlayback(
        identity: MusicHapticsIdentity,
        favorite: Bool,
        duration: TimeInterval
    ) async -> MusicHapticsPlaybackPreparation {
        let startedAt = ContinuousClock.now
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

        let request = MusicHapticsAnalysisRequest(
            identity: identity,
            favorite: favorite,
            duration: duration,
            partial: partial
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
                }
            )
        case .disabled, .system, .custom:
            analysisSink = nil
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
            analysisSink: analysisSink
        )
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
    /// For `.analyze`, the sink has already been handed to the engine before
    /// `play()`, so this method never creates another analyzer.
    public func activate(
        _ preparation: MusicHapticsPlaybackPreparation,
        position: TimeInterval
    ) {
        if currentPreparation?.id != preparation.id {
            activeAnalysisSink?.finishPartial(reason: .trackSwitch)
        }
        custom.stop()
        currentPreparation = preparation
        currentIdentity = preparation.identity
        currentFavorite = preparation.favorite
        currentPosition = max(0, position)
        currentPlan = preparation.plan
        currentSystemAvailability = preparation.systemAvailability
        fullTimelineExists = preparation.fullTimelineExists
        partialExists = preparation.partialExists
        currentPlanReason = preparation.reason
        activeAnalysisSink = preparation.analysisSink
        currentTimeline = nil
        analysisSnapshot = initialSnapshot(for: preparation)

        switch preparation.plan {
        case .disabled:
            source = .none
        case .system:
            source = .system
        case let .custom(timeline):
            do {
                try custom.play(timeline, offset: position)
                currentTimeline = timeline
                source = .custom
            } catch {
                source = .none
                currentPlanReason = "custom_play_failed"
            }
        case .analyze:
            source = .analyzing
        }
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
        guard source == .custom else { return }
        custom.pause()
    }

    public func resume(position: TimeInterval) {
        guard source == .custom else { return }
        currentPosition = max(0, position)
        custom.resume(at: position)
    }

    public func seek(position: TimeInterval, playing: Bool) {
        currentPosition = max(0, position)
        guard source == .custom else { return }
        custom.seek(to: position, playing: playing)
    }

    public func buffering() { pause() }

    public func playbackFailed() {
        finishPartial(reason: .playbackFailure)
    }

    /// Finishes the current sidecar without discarding incomplete work. A
    /// complete result is promoted; otherwise the checkpoint is persisted.
    public func finishPartial(reason: MusicHapticsAnalysisFinishReason) {
        activeAnalysisSink?.finishPartial(reason: reason)
        activeAnalysisSink = nil
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
        if let currentTimeline {
            currentCoverage = currentTimeline.analysisCoverage
            eventCount = currentTimeline.events.count
            eventDensity = currentTimeline.eventDensity
            sparse = currentTimeline.timelineSuspiciouslySparse
        } else if currentPlan.kind == .analyze {
            currentCoverage = analysisSnapshot.coverage
            eventCount = analysisSnapshot.eventCount
            let duration = currentIdentity.map { Double($0.durationMilliseconds) / 1_000 } ?? 0
            eventDensity = duration > 0 ? Double(eventCount) / duration : nil
            sparse = duration > 120 && eventCount < max(8, Int(duration / 30))
        } else {
            currentCoverage = nil
            eventCount = 0
            eventDensity = nil
            sparse = false
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
            timelineSuspiciouslySparse: sparse
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
        let identity = result.checkpoint.identity
        if let existing = inMemoryPartials[identity.stableKey],
           existing.identity.matchConfidence(with: identity) >= 0.82 {
            inMemoryPartials[identity.stableKey] = existing.merged(with: result.checkpoint)
        } else {
            inMemoryPartials[identity.stableKey] = result.checkpoint
        }
        var storedFull = false
        var storedPartial = false
        if let timeline = result.timeline {
            do {
                try await store.store(timeline, favorite: favorite)
                if inMemoryPartials[identity.stableKey] == result.checkpoint {
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
                    try await store.storePartial(result.checkpoint)
                    storedPartial = true
                    musicHapticsLogger.debug(
                        "HAPTICS_PARTIAL_SAVED track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(result.checkpoint.coverage, privacy: .public) ranges=\(self.rangeDescription(result.checkpoint.analyzedRanges), privacy: .public)"
                    )
                } catch {
                    musicHapticsLogger.error(
                        "HAPTICS_PARTIAL_SAVE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
                    )
                }
            }
        } else {
            do {
                try await store.storePartial(result.checkpoint)
                if inMemoryPartials[identity.stableKey] == result.checkpoint {
                    inMemoryPartials.removeValue(forKey: identity.stableKey)
                }
                storedPartial = true
                musicHapticsLogger.debug(
                    "HAPTICS_PARTIAL_SAVED track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(result.checkpoint.coverage, privacy: .public) ranges=\(self.rangeDescription(result.checkpoint.analyzedRanges), privacy: .public)"
                )
            } catch {
                musicHapticsLogger.error(
                    "HAPTICS_PARTIAL_SAVE_FAILED track=\(self.diagnosticTrack(identity), privacy: .public)"
                )
            }
        }

        let eventDensity = result.checkpoint.duration > 0
            ? Double(result.snapshot.eventCount) / result.checkpoint.duration
            : 0
        let suspiciouslySparse = result.timeline?.timelineSuspiciouslySparse
            ?? (result.checkpoint.duration > 120
                && result.snapshot.eventCount < max(8, Int(result.checkpoint.duration / 30)))
        musicHapticsLogger.debug(
            "HAPTICS_ANALYSIS track=\(self.diagnosticTrack(identity), privacy: .public) coverage=\(result.snapshot.coverage, privacy: .public) events=\(result.snapshot.eventCount, privacy: .public) event_density=\(eventDensity, privacy: .public) dropped_frames=\(result.snapshot.droppedFrames, privacy: .public) finish_reason=\(result.finishReason.rawValue, privacy: .public) tap_attached=\(result.snapshot.tapAttached, privacy: .public) pcm_format=\(self.formatDescription(result.snapshot.pcmFormat), privacy: .public) analyzed_ranges=\(self.rangeDescription(result.snapshot.analyzedRanges), privacy: .public) timeline_suspiciously_sparse=\(suspiciouslySparse, privacy: .public)"
        )
        if let timeline = result.timeline, timeline.timelineSuspiciouslySparse {
            musicHapticsLogger.debug(
                "HAPTICS_ANALYSIS timeline_suspiciously_sparse=true track=\(self.diagnosticTrack(identity), privacy: .public) duration=\(timeline.duration, privacy: .public) events=\(timeline.events.count, privacy: .public) density=\(timeline.eventDensity, privacy: .public)"
            )
        }

        guard currentPreparation?.id == preparationID else { return }
        analysisSnapshot = result.snapshot
        if storedFull {
            fullTimelineExists = true
            partialExists = false
            // This first playback has already started as an analyze plan. The
            // newly promoted timeline is intentionally used on the next play,
            // not hot-swapped into a running track.
            currentPlanReason = "analysis_complete_next_play"
        } else if storedPartial {
            partialExists = true
        }
    }

    private func acceptAnalysisSnapshot(_ snapshot: MusicHapticsAnalysisSnapshot) {
        // Progress callbacks and the terminal result are delivered by separate
        // utility tasks. Do not let a late startup snapshot regress the final
        // coverage/event count shown to the user.
        guard snapshot.coverage >= analysisSnapshot.coverage
                || snapshot.finishReason != nil
        else { return }
        analysisSnapshot = snapshot
    }

    private func inMemoryPartial(for identity: MusicHapticsIdentity) -> MusicHapticsPartialCheckpoint? {
        inMemoryPartials.values
            .filter { $0.identity.matchConfidence(with: identity) >= 0.82 }
            .max { $0.identity.matchConfidence(with: identity) < $1.identity.matchConfidence(with: identity) }
    }

    private func initialSnapshot(for preparation: MusicHapticsPlaybackPreparation) -> MusicHapticsAnalysisSnapshot {
        guard case let .analyze(request) = preparation.plan,
              let partial = request.partial
        else { return MusicHapticsAnalysisSnapshot() }
        return MusicHapticsAnalysisSnapshot(
            analyzedRanges: partial.analyzedRanges,
            coverage: partial.coverage,
            eventCount: partial.events.count
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
        case let .analyze(request):
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
