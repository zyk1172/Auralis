import Foundation

#if os(iOS)
import CoreHaptics
import MediaAccessibility
#endif

public enum MusicHapticsSource: Sendable, Equatable { case none, system, custom, analyzing }

/// Values exposed by the in-app diagnostic screen.  Deliberately excludes URLs,
/// server names and any authentication material.
public struct MusicHapticsDiagnostics: Sendable, Equatable {
    public var supportsCustomHaptics: Bool
    public var systemMusicHapticsActive: Bool
    public var globalEnabled: Bool
    public var trackPreference: TrackHapticsPreference
    public var effectiveEnabled: Bool
    public var source: MusicHapticsSource
    public var hasReliableISRC: Bool

    public init(supportsCustomHaptics: Bool, systemMusicHapticsActive: Bool, globalEnabled: Bool, trackPreference: TrackHapticsPreference, effectiveEnabled: Bool, source: MusicHapticsSource, hasReliableISRC: Bool) {
        self.supportsCustomHaptics = supportsCustomHaptics
        self.systemMusicHapticsActive = systemMusicHapticsActive
        self.globalEnabled = globalEnabled
        self.trackPreference = trackPreference
        self.effectiveEnabled = effectiveEnabled
        self.source = source
        self.hasReliableISRC = hasReliableISRC
    }
}

@MainActor
public final class SystemMusicHapticsAdapter {
    public init() {}

    public func canUseSystemTimeline(isrc: String?) async -> Bool {
        #if os(iOS)
        guard let isrc, !isrc.isEmpty else { return false }
        let manager = MAMusicHapticsManager.shared
        guard manager.isActive else { return false }
        return await manager.isHapticTrackAvailable(forMediaMatching: isrc)
        #else
        return false
        #endif
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
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters(for: event), relativeTime: event.time)
            case .continuous:
                return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters(for: event), relativeTime: event.time, duration: event.duration ?? 0.1)
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
        do { try player?.seek(toOffset: max(0, offset)); try player?.resume(atTime: CHHapticTimeImmediate) } catch { stop() }
        #endif
    }

    func seek(to offset: TimeInterval, playing: Bool) {
        #if os(iOS)
        do {
            try player?.seek(toOffset: max(0, offset))
            if playing { try player?.resume(atTime: CHHapticTimeImmediate) }
        } catch { stop() }
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
        [CHHapticEventParameter(parameterID: .hapticIntensity, value: min(event.intensity, 0.88)), CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness)]
    }
    private func prepareEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.player = nil } }
        engine.resetHandler = { [weak self] in Task { @MainActor in try? self?.engine?.start() } }
        try engine.start()
        self.engine = engine
        return engine
    }
    #endif
}

/// Owns exactly one haptic source for the current track. Failures stay inside this component.
@MainActor
public final class MusicHapticsCoordinator {
    public static let enabledDefaultsKey = "auralis.playback.musicHaptics.enabled"
    public private(set) var source: MusicHapticsSource = .none

    private struct CurrentContext {
        var identity: MusicHapticsIdentity
        var sourceURL: URL?
        var favorite: Bool
        var position: TimeInterval
    }

    private let store: MusicHapticsStore
    private let system = SystemMusicHapticsAdapter()
    private let custom = CustomMusicHapticsEngine()
    private var currentIdentity: MusicHapticsIdentity?
    private var currentTimeline: MusicHapticsTimeline?
    private var analysisTask: Task<Void, Never>?
    private var currentFavorite = false
    private var currentContext: CurrentContext?

    public init(store: MusicHapticsStore = MusicHapticsStore()) { self.store = store }
    public var supportsHaptics: Bool { custom.supportsHaptics }

    public func begin(identity: MusicHapticsIdentity, sourceURL: URL?, favorite: Bool, position: TimeInterval) {
        stop()
        currentIdentity = identity; currentFavorite = favorite
        currentContext = CurrentContext(identity: identity, sourceURL: sourceURL, favorite: favorite, position: position)
        Task { [weak self] in await self?.resolve(identity: identity, sourceURL: sourceURL, favorite: favorite, position: position) }
    }

    public func pause() { guard source == .custom else { return }; custom.pause() }
    public func resume(position: TimeInterval) { guard source == .custom else { return }; custom.resume(at: position) }
    public func seek(position: TimeInterval, playing: Bool) { guard source == .custom else { return }; custom.seek(to: position, playing: playing) }
    public func buffering() { pause() }
    public func playbackFailed() { stop() }

    public func stop() {
        analysisTask?.cancel(); analysisTask = nil; custom.stop(); currentTimeline = nil; currentIdentity = nil; currentContext = nil; source = .none
    }

    public func setPreference(_ preference: TrackHapticsPreference) {
        guard let identity = currentIdentity else { return }
        Task { [weak self] in
            try? await self?.store.setPreference(preference, for: identity)
            await self?.resolveCurrentTrack()
        }
    }

    /// The settings switch takes effect for the current item immediately.  A
    /// per-track override still has precedence over this value.
    public func setGlobalEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        Task { [weak self] in await self?.resolveCurrentTrack() }
    }

    public func favoriteChanged(_ favorite: Bool, identity: MusicHapticsIdentity) {
        currentFavorite = favorite
        if currentIdentity == identity { currentContext?.favorite = favorite }
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
        let globalEnabled = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        return MusicHapticsDiagnostics(
            supportsCustomHaptics: custom.supportsHaptics,
            systemMusicHapticsActive: system.isActive,
            globalEnabled: globalEnabled,
            trackPreference: preference,
            effectiveEnabled: preference.effective(globalEnabled: globalEnabled),
            source: source,
            hasReliableISRC: currentIdentity?.isrc != nil
        )
    }

    /// Creates the optional analysis sidecar before AVPlayer starts an item.
    /// The returned object receives only decoded PCM from that item's existing
    /// playback pipeline; it never owns a URLSession or a stream URL.
    public func makeStreamingAnalysisSink(identity: MusicHapticsIdentity, favorite: Bool, duration: TimeInterval) async -> (any MusicHapticsAnalysisSink)? {
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        let globalEnabled = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
        guard preference.effective(globalEnabled: globalEnabled), custom.supportsHaptics, duration > 0 else { return nil }
        source = .analyzing
        return StreamingMusicHapticsAnalyzer(identity: identity, duration: duration) { [store] timeline in
            Task.detached(priority: .utility) {
                try? await store.store(timeline, favorite: favorite)
            }
        }
    }

    private func resolveCurrentTrack() async {
        guard let context = currentContext else { return }
        custom.stop()
        currentTimeline = nil
        source = .none
        await resolve(identity: context.identity, sourceURL: context.sourceURL, favorite: context.favorite, position: context.position)
    }

    private func resolve(identity: MusicHapticsIdentity, sourceURL: URL?, favorite: Bool, position: TimeInterval) async {
        guard currentIdentity == identity else { return }
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        guard preference.effective(globalEnabled: UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false) else { return }
        // System Music Haptics does not depend on custom Core Haptics support.
        // An iPhone can have the system path available even when app-generated
        // patterns are unavailable or intentionally disabled.
        if await system.canUseSystemTimeline(isrc: identity.isrc) {
            guard currentIdentity == identity else { return }
            source = .system
            return
        }
        guard custom.supportsHaptics else { return }
        if let timeline = try? await store.timeline(for: identity) {
            guard currentIdentity == identity else { return }
            do { try custom.play(timeline, offset: position); currentTimeline = timeline; source = .custom } catch { source = .none }
            return
        }
        // HTTP streams are fed by the PlaybackEngine sidecar.  The old
        // isFileURL guard made this branch permanently unreachable for
        // Navidrome/OpenSubsonic playback.
        guard let sourceURL else { source = .none; return }
        guard sourceURL.isFileURL else { source = .analyzing; return }
        source = .analyzing
        analysisTask = Task.detached(priority: .utility) { [store] in
            do {
                let timeline = try await MusicHapticsAnalyzer().analyze(url: sourceURL, identity: identity)
                try await store.store(timeline, favorite: favorite)
            } catch is CancellationError { } catch { }
        }
    }
}
