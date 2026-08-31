import Foundation
import Testing
@testable import MusicHaptics

/// Exercises the real remote lookahead handoff:
/// Coordinator -> lookahead analyzer -> rolling scheduler -> injected output
/// seam. The sidecar payload is a deterministic local WAV, but it is exposed
/// to the runtime as a 96 kbps remote lookahead source so the network plan is
/// covered without making the test depend on a live server.
@Test("v2.3 cache miss remote lookahead reaches haptic output")
@MainActor
func coordinatorRemoteLookaheadWindowReachesHapticOutputEngine() async throws {
    let suiteName = "music-haptics-coordinator-integration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-haptics-integration-\(UUID().uuidString)", isDirectory: true)
    let audioURL = try makeIntegrationWAV(at: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let output = RecordingMusicHapticsOutputEngine()
    let coordinator = MusicHapticsCoordinator(
        store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
        defaults: defaults,
        analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
            primary: .remoteLookahead(.init(url: audioURL, bitrate: 96, format: "mp3"))
        ),
        outputEngine: output,
        isFeatureAvailable: true
    )
    defer { coordinator.stop() }

    let identity = MusicHapticsIdentity(
        serverID: "integration-server",
        remoteID: "integration-track",
        title: "Integration Track",
        artist: "Auralis",
        durationMilliseconds: 4_000
    )
    let preparation = await coordinator.preparePlayback(
        identity: identity,
        favorite: false,
        duration: 4,
        playbackURL: URL(string: "https://example.invalid/audio.mp3")!
    )
    #expect(preparation.plan.kind == .analyzeLookahead)
    #expect(preparation.fullTimelineExists == false)
    #expect(preparation.realtimeFallbackSink == nil)

    coordinator.activate(preparation, position: 0, isPlaying: true)

    var receivedEvents = false
    for _ in 0..<50 {
        if output.playedWindows.contains(where: { !$0.events.isEmpty }) {
            receivedEvents = true
            break
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    let diagnostics = await coordinator.diagnostics()
    #expect(receivedEvents)
    #expect(output.state == .running)
    #expect(output.playedWindows.contains { !$0.events.isEmpty })
    #expect(diagnostics.source == .analyzing)
    #expect(diagnostics.eventCount > 0)
    #expect(diagnostics.analysisPosition > 0)
    #expect(diagnostics.scheduledUntil > 0)
    #expect(diagnostics.hapticEngineState == .running)
    #expect(diagnostics.analysisMode == .remoteLookahead)
    #expect(diagnostics.analysisStreamBitrate == 96)
}

/// Verifies the terminal remote failure path at the coordinator boundary.
/// There is deliberately no realtime fallback sink: a failed independent
/// source must be observable as a fail-closed haptics state without mutating
/// the currently playing AVPlayer item.
@Test("remote lookahead failure reports no event source")
@MainActor
func coordinatorRemoteLookaheadFailureFailsClosed() async throws {
    let suiteName = "music-haptics-coordinator-failure-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-haptics-coordinator-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let missingURL = root.appendingPathComponent("missing-sidecar.mp3")
    let output = RecordingMusicHapticsOutputEngine()
    let coordinator = MusicHapticsCoordinator(
        store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
        defaults: defaults,
        analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
            primary: .remoteLookahead(.init(url: missingURL, bitrate: 96, format: "mp3"))
        ),
        outputEngine: output,
        isFeatureAvailable: true
    )
    defer { coordinator.stop() }

    let identity = MusicHapticsIdentity(
        serverID: "integration-server",
        remoteID: "failed-track",
        title: "Failed Track",
        artist: "Auralis",
        durationMilliseconds: 4_000
    )
    let preparation = await coordinator.preparePlayback(
        identity: identity,
        favorite: false,
        duration: 4,
        playbackURL: URL(string: "https://example.invalid/audio.mp3")!
    )
    #expect(preparation.plan.kind == .analyzeLookahead)
    #expect(preparation.realtimeFallbackSink == nil)

    coordinator.activate(preparation, position: 0, isPlaying: true)

    var diagnostics = await coordinator.diagnostics()
    for _ in 0..<50 {
        if diagnostics.source == .none,
           diagnostics.planReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue {
            break
        }
        try await Task.sleep(for: .milliseconds(100))
        diagnostics = await coordinator.diagnostics()
    }

    #expect(diagnostics.source == .none)
    #expect(diagnostics.playbackPlan == .analyzeLookahead)
    #expect(diagnostics.planReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue)
    #expect(diagnostics.analysisFailureReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue)
    #expect(diagnostics.eventCount == 0)
    #expect(output.playedWindows.isEmpty)
}

private struct InjectedRemoteAnalysisSourceProvider: MusicHapticsAnalysisSourceProvider {
    let primary: MusicHapticsAnalysisSource
    let fallbacks: [MusicHapticsAnalysisSource]

    init(
        primary: MusicHapticsAnalysisSource,
        fallbacks: [MusicHapticsAnalysisSource] = []
    ) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    func source(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?
    ) async -> MusicHapticsAnalysisSource? {
        primary
    }

    func fallbackSources(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?,
        after failedSource: MusicHapticsAnalysisSource
    ) async -> [MusicHapticsAnalysisSource] {
        fallbacks
    }
}

@MainActor
private final class RecordingMusicHapticsOutputEngine: MusicHapticsOutputEngine {
    private(set) var state: MusicHapticsEngineState = .notCreated
    private(set) var applicationSuspended = false
    private(set) var lastStopReason: String?
    let supportsHaptics = true
    var canProduceOutput: Bool { !applicationSuspended }
    private(set) var playedWindows: [MusicHapticsAnalysisWindow] = []

    func setActualSuspensionHandler(_ handler: (() -> Void)?) {}

    func warmUp() {
        state = .running
    }

    func play(
        _ timeline: MusicHapticsTimeline,
        offset: TimeInterval,
        playbackRate: Double
    ) throws {
        state = .running
    }

    func play(
        _ window: MusicHapticsAnalysisWindow,
        from currentPosition: TimeInterval,
        intensity: MusicHapticsIntensity,
        playbackRate: Double
    ) {
        state = .running
        playedWindows.append(window)
    }

    func pause() {}

    func resume(at offset: TimeInterval, playbackRate: Double) {
        state = .running
    }

    func seek(to offset: TimeInterval, playing: Bool, playbackRate: Double) {
        if playing { state = .running }
    }

    func stop() {}

    func applicationDidEnterBackground() {
        applicationSuspended = true
    }

    func restartIfNeeded() {
        applicationSuspended = false
        state = .running
    }
}

private func makeIntegrationWAV(at root: URL) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sampleRate = 22_050
    let seconds = 4
    let samples = (0..<(sampleRate * seconds)).map { index -> Int16 in
        let time = Double(index) / Double(sampleRate)
        let beatPhase = time.truncatingRemainder(dividingBy: 0.5)
        let kickEnvelope = Float(exp(-beatPhase * 34))
        let kickOscillation = Float(sin(2 * Double.pi * 62 * time))
        let kick = 0.72 * kickEnvelope * kickOscillation
        let snarePhase = (time + 0.25).truncatingRemainder(dividingBy: 0.5)
        let snareEnvelope = Float(exp(-snarePhase * 45))
        let snareOscillation = Float(sin(2 * Double.pi * 2_800 * time))
        let snare = 0.35 * snareEnvelope * snareOscillation
        let sustained = 0.22 * Float(sin(2 * Double.pi * 58 * time))
        let value = max(-1, min(1, kick + snare + sustained))
        return Int16((value * Float(Int16.max)).rounded())
    }

    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    appendLittleEndian(UInt32(36 + samples.count * 2), to: &data)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt32(sampleRate), to: &data)
    appendLittleEndian(UInt32(sampleRate * 2), to: &data)
    appendLittleEndian(UInt16(2), to: &data)
    appendLittleEndian(UInt16(16), to: &data)
    data.append(contentsOf: Array("data".utf8))
    appendLittleEndian(UInt32(samples.count * 2), to: &data)
    for sample in samples {
        appendLittleEndian(sample, to: &data)
    }

    let url = root.appendingPathComponent("integration.wav")
    try data.write(to: url, options: .atomic)
    return url
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
