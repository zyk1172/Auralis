import Foundation
import Testing
@testable import MusicHaptics

/// Exercises the real remote lookahead handoff:
/// localhost HTTP -> independent download -> AVAssetReader -> coordinator
/// -> rolling scheduler -> injected output seam. The response is actual MP3
/// data, so this test covers the network decoder path rather than only tagging
/// a local WAV as a remote source.
@Test("v2.3 cache miss remote lookahead reaches haptic output")
@MainActor
func coordinatorRemoteLookaheadWindowReachesHapticOutputEngine() async throws {
    let suiteName = "music-haptics-coordinator-integration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-haptics-integration-\(UUID().uuidString)", isDirectory: true)
    let server = try LocalHTTPAudioServer(statusCode: 200, body: RemoteMP3Fixture.data)
    try await server.start()
    defer { server.stop() }
    defer { try? FileManager.default.removeItem(at: root) }
    let (wireData, wireResponse) = try await URLSession.shared.data(from: server.url)
    #expect((wireResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(wireData == RemoteMP3Fixture.data)

    let output = RecordingMusicHapticsOutputEngine()
    let coordinator = MusicHapticsCoordinator(
        store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
        defaults: defaults,
        analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
            primary: .remoteLookahead(.init(url: server.url, bitrate: 96, format: "mp3"))
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
    #expect(preparation.realtimeFallbackSink != nil)

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
    #expect(server.requestCount > 0)
}

/// Verifies the terminal remote failure path at the coordinator boundary. A
/// pre-play tap is not attached in this test, so the coordinator must fail
/// closed and expose the decoder stage/domain/code instead of pretending that
/// a realtime source exists.
@Test("remote lookahead failure reports no event source")
@MainActor
func coordinatorRemoteLookaheadFailureFailsClosed() async throws {
    let suiteName = "music-haptics-coordinator-failure-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-haptics-coordinator-failure-\(UUID().uuidString)", isDirectory: true)
    let server = try LocalHTTPAudioServer(
        statusCode: 200,
        body: Data("not an MP3".utf8)
    )
    try await server.start()
    defer { server.stop() }
    defer { try? FileManager.default.removeItem(at: root) }

    let output = RecordingMusicHapticsOutputEngine()
    let coordinator = MusicHapticsCoordinator(
        store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
        defaults: defaults,
        analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
            primary: .remoteLookahead(.init(url: server.url, bitrate: 96, format: "mp3"))
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
    #expect(preparation.realtimeFallbackSink != nil)

    coordinator.activate(preparation, position: 0, isPlaying: true)

    var diagnostics = await coordinator.diagnostics()
    for _ in 0..<50 {
        if diagnostics.source == .none,
           diagnostics.planReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue,
           diagnostics.analysisFailureDetail != nil {
            break
        }
        try await Task.sleep(for: .milliseconds(100))
        diagnostics = await coordinator.diagnostics()
    }

    #expect(diagnostics.source == .none)
    #expect(diagnostics.playbackPlan == .analyzeLookahead)
    #expect(diagnostics.planReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue)
    #expect(diagnostics.analysisFailureReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue)
    #expect(diagnostics.analysisFailureDetail?.contains("domain=") == true)
    #expect(diagnostics.analysisFailureDetail?.contains("code=") == true)
    #expect(diagnostics.eventCount == 0)
    #expect(output.playedWindows.isEmpty)
    #expect(server.requestCount > 0)
}

/// Verifies the pre-play realtime fallback seam. The invalid sidecar forces a
/// terminal remote decoder failure, while the injected tap is marked attached
/// before activation, matching the AVFoundation engine's pre-insertion setup.
@Test("remote lookahead failure activates pre-play realtime fallback")
@MainActor
func coordinatorRemoteLookaheadFailureActivatesPrePlayRealtimeFallback() async throws {
    let suiteName = "music-haptics-coordinator-fallback-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-haptics-coordinator-fallback-\(UUID().uuidString)", isDirectory: true)
    let server = try LocalHTTPAudioServer(
        statusCode: 200,
        body: Data("not an MP3".utf8)
    )
    try await server.start()
    defer { server.stop() }
    defer { try? FileManager.default.removeItem(at: root) }

    let output = RecordingMusicHapticsOutputEngine()
    let coordinator = MusicHapticsCoordinator(
        store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
        defaults: defaults,
        analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
            primary: .remoteLookahead(.init(url: server.url, bitrate: 96, format: "mp3"))
        ),
        outputEngine: output,
        isFeatureAvailable: true
    )
    defer { coordinator.stop() }

    let identity = MusicHapticsIdentity(
        serverID: "integration-server",
        remoteID: "fallback-track",
        title: "Fallback Track",
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
    guard let fallback = preparation.realtimeFallbackSink else {
        Issue.record("remote lookahead preparation did not create a realtime fallback sink")
        return
    }
    let format = try #require(MusicHapticsPCMFormat(
        sampleRate: 22_050,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    ))
    fallback.tapAttached()
    fallback.begin(format: format)

    coordinator.activate(preparation, position: 0, isPlaying: true)

    let pcm = makeIntegrationPCM(duration: 4)
    let framesPerChunk = 2_205
    let bytesPerFrame = 2
    for chunkIndex in 0..<40 {
        let start = chunkIndex * framesPerChunk * bytesPerFrame
        let end = min(start + framesPerChunk * bytesPerFrame, pcm.count)
        guard start < end else { break }
        fallback.consumePCM(
            pcm.subdata(in: start..<end),
            time: Double(chunkIndex) * 0.1,
            format: format,
            frameCount: (end - start) / bytesPerFrame
        )
        try await Task.sleep(for: .milliseconds(10))
    }

    var diagnostics = await coordinator.diagnostics()
    for _ in 0..<60 {
        if diagnostics.planReason == "realtime_fallback_active",
           diagnostics.eventCount > 0 {
            break
        }
        try await Task.sleep(for: .milliseconds(50))
        diagnostics = await coordinator.diagnostics()
    }

    #expect(diagnostics.source == .analyzing)
    #expect(diagnostics.planReason == "realtime_fallback_active")
    #expect(diagnostics.analysisMode == .realtimeTap)
    #expect(diagnostics.analysisFailureReason == MusicHapticsAnalysisDiagnostic.remoteDecoderFailed.rawValue)
    #expect(diagnostics.analysisFailureDetail?.contains("domain=") == true)
    #expect(diagnostics.eventCount > 0)
    #expect(diagnostics.analysisPosition > 0)
    #expect(diagnostics.tapAttached)
    #expect(output.playedWindows.contains { !$0.events.isEmpty })
    #expect(server.requestCount > 0)
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

private func makeIntegrationPCM(duration: TimeInterval) -> Data {
    let sampleRate = 22_050
    let seconds = max(1, Int(duration.rounded(.up)))
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

    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        appendLittleEndian(sample, to: &data)
    }
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
