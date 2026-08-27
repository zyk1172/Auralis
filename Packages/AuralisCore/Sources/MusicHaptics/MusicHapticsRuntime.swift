import Foundation

#if os(iOS)
import CoreHaptics
import MediaAccessibility
#endif

public enum MusicHapticsSource: Sendable, Equatable { case none, system, custom, analyzing }

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
    public var onReliableISRCChanged: (@MainActor @Sendable (String?) -> Void)?

    private let store: MusicHapticsStore
    private let system = SystemMusicHapticsAdapter()
    private let custom = CustomMusicHapticsEngine()
    private var currentIdentity: MusicHapticsIdentity?
    private var currentTimeline: MusicHapticsTimeline?
    private var analysisTask: Task<Void, Never>?
    private var currentFavorite = false

    public init(store: MusicHapticsStore = MusicHapticsStore()) { self.store = store }
    public var supportsHaptics: Bool { custom.supportsHaptics }

    public func begin(identity: MusicHapticsIdentity, sourceURL: URL?, favorite: Bool, position: TimeInterval) {
        stop()
        currentIdentity = identity; currentFavorite = favorite
        Task { [weak self] in await self?.resolve(identity: identity, sourceURL: sourceURL, favorite: favorite, position: position) }
    }

    public func pause() { guard source == .custom else { return }; custom.pause() }
    public func resume(position: TimeInterval) { guard source == .custom else { return }; custom.resume(at: position) }
    public func seek(position: TimeInterval, playing: Bool) { guard source == .custom else { return }; custom.seek(to: position, playing: playing) }
    public func buffering() { pause() }
    public func playbackFailed() { stop() }

    public func stop() {
        analysisTask?.cancel(); analysisTask = nil; custom.stop(); currentTimeline = nil; currentIdentity = nil; source = .none; onReliableISRCChanged?(nil)
    }

    public func setPreference(_ preference: TrackHapticsPreference) {
        guard let identity = currentIdentity else { return }
        Task { try? await store.setPreference(preference, for: identity) }
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

    private func resolve(identity: MusicHapticsIdentity, sourceURL: URL?, favorite: Bool, position: TimeInterval) async {
        guard currentIdentity == identity else { return }
        let preference = (try? await store.preference(for: identity)) ?? .inherit
        guard preference.effective(globalEnabled: UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false), custom.supportsHaptics else { return }
        onReliableISRCChanged?(identity.isrc)
        if await system.canUseSystemTimeline(isrc: identity.isrc) {
            guard currentIdentity == identity else { return }
            source = .system
            return
        }
        onReliableISRCChanged?(nil)
        if let timeline = try? await store.timeline(for: identity) {
            guard currentIdentity == identity else { return }
            do { try custom.play(timeline, offset: position); currentTimeline = timeline; source = .custom } catch { source = .none }
            return
        }
        guard let sourceURL, sourceURL.isFileURL else { source = .none; return }
        source = .analyzing
        analysisTask = Task.detached(priority: .utility) { [store] in
            do {
                let timeline = try await MusicHapticsAnalyzer().analyze(url: sourceURL, identity: identity)
                try await store.store(timeline, favorite: favorite)
            } catch is CancellationError { } catch { }
        }
    }
}
