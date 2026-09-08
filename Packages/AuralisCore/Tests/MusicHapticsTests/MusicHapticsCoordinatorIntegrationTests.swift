// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AudioToolbox
import Testing
@testable import MusicHaptics

/// These tests cross the real coordinator boundary. The remote source is an
/// original FLAC response; no URL is relabeled as MP3 and no complete
/// download/temporary-file helper is involved.
@Suite("Music Haptics coordinator original stream", .serialized)
struct MusicHapticsCoordinatorIntegrationTests {
    @Test("original remote FLAC reaches the rolling output engine")
    @MainActor
    func originalRemoteFLACReachesHapticOutput() async throws {
        let suiteName = "music-haptics-coordinator-original-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-haptics-coordinator-original-\(UUID().uuidString)", isDirectory: true)
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 1_024,
            responseChunkDelay: 0.01
        )
        try await server.start()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: root) }

        let output = RecordingMusicHapticsOutputEngine()
        let coordinator = MusicHapticsCoordinator(
            store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
            defaults: defaults,
            analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
                primary: .remoteOriginal(server.url)
            ),
            outputEngine: output,
            isFeatureAvailable: true
        )
        defer { coordinator.stop() }

        let identity = MusicHapticsIdentity(
            serverID: "integration-server",
            remoteID: "original-flac",
            title: "Original FLAC",
            artist: "Auralis",
            durationMilliseconds: 750
        )
        let preparation = await coordinator.preparePlayback(
            identity: identity,
            favorite: false,
            duration: 0.75,
            playbackURL: server.url
        )
        #expect(preparation.plan.kind == .analyzeLookahead)
        #expect(preparation.realtimeTapSink != nil)

        coordinator.activate(preparation, position: 0, isPlaying: true)
        // This 0.75-second fixture is already in the production gate's
        // "nearly finished" exception at 0.5 seconds. Advance the
        // authoritative playback clock so the test exercises the decoder
        // without weakening the audio-first policy.
        coordinator.updatePlaybackPosition(
            0.5,
            isPlaying: true,
            source: .playbackEngine
        )

        for _ in 0..<60 {
            if output.playedWindows.contains(where: { !$0.events.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let diagnostics = await coordinator.diagnostics()
        #expect(output.playedWindows.contains { !$0.events.isEmpty })
        #expect(diagnostics.source == .analyzing)
        #expect(diagnostics.eventCount > 0)
        #expect(diagnostics.analysisMode == .remoteOriginal)
        #expect(diagnostics.remoteAnalysisPosition > 0)
        #expect(diagnostics.scheduledUntil > 0)
        #expect(server.requestCount == 1)
    }

    @Test("remote decoder failure does not stop an attached pre-play realtime tap")
    @MainActor
    func remoteFailureKeepsRealtimeContinuity() async throws {
        let suiteName = "music-haptics-coordinator-realtime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-haptics-coordinator-realtime-\(UUID().uuidString)", isDirectory: true)
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: Data("not an encoded audio stream".utf8),
            contentType: "audio/flac"
        )
        try await server.start()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: root) }

        let output = RecordingMusicHapticsOutputEngine()
        let coordinator = MusicHapticsCoordinator(
            store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
            defaults: defaults,
            analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
                primary: .remoteOriginal(server.url)
            ),
            outputEngine: output,
            isFeatureAvailable: true
        )
        defer { coordinator.stop() }

        let identity = MusicHapticsIdentity(
            serverID: "integration-server",
            remoteID: "remote-failure",
            title: "Remote Failure",
            artist: "Auralis",
            durationMilliseconds: 4_000
        )
        let preparation = await coordinator.preparePlayback(
            identity: identity,
            favorite: false,
            duration: 4,
            playbackURL: server.url
        )
        guard let realtime = preparation.realtimeTapSink else {
            Issue.record("The remote plan must install a realtime tap sink before playback")
            return
        }
        let format = MusicHapticsPCMFormat(
            sampleRate: 22_050,
            channels: 1,
            sampleType: .int16,
            interleaved: true,
            bytesPerFrame: 2,
            bytesPerSample: 2
        )!
        realtime.tapAttached()
        realtime.configurePCMStorage(format: format, maxFrames: 2_205)
        realtime.begin(format: format)

        coordinator.activate(preparation, position: 0, isPlaying: true)
        coordinator.updatePlaybackPosition(
            1.5,
            isPlaying: true,
            source: .playbackEngine
        )
        let pcm = makeCoordinatorPCM(duration: 4)
        let framesPerChunk = 2_205
        for chunkIndex in 0..<40 {
            let start = chunkIndex * framesPerChunk * 2
            let end = min(pcm.count, start + framesPerChunk * 2)
            guard start < end else { break }
            realtime.consumePCM(
                pcm.subdata(in: start..<end),
                time: Double(chunkIndex) * 0.1,
                format: format,
                frameCount: (end - start) / 2
            )
            try await Task.sleep(for: .milliseconds(5))
        }

        var diagnostics = await coordinator.diagnostics()
        for _ in 0..<80 {
            if diagnostics.eventCount > 0,
               diagnostics.analysisFailureDetail != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
            diagnostics = await coordinator.diagnostics()
        }

        #expect(diagnostics.source == .analyzing)
        #expect(diagnostics.planReason == "remote_decoder_failed_realtime_continuity")
        #expect(diagnostics.analysisFailureReason == MusicHapticsAnalysisDiagnostic.noAudioPacket.rawValue)
        #expect(diagnostics.analysisFailureDetail?.contains("domain=") == true)
        #expect(diagnostics.decoderFailureStage == MusicHapticsAnalysisDiagnostic.noAudioPacket.rawValue)
        #expect(diagnostics.decoderFailureDomain == "AudioFileStream")
        #expect(diagnostics.decoderFailureCode == 0)
        // `analysisMode` describes the prepared primary plan. The live source
        // selected by the arbiter is reported separately, and must switch to
        // the tap when the independent original-stream decoder fails.
        #expect(diagnostics.analysisMode == .remoteOriginal)
        #expect(diagnostics.currentEventSource == .realtimeTap)
        #expect(diagnostics.realtimeAnalysisPosition > 0)
        #expect(diagnostics.eventCount > 0)
        #expect(output.playedWindows.contains { !$0.events.isEmpty })
        #expect(server.requestCount == 1)
    }

    @Test("an unsupported remote format keeps the pre-play realtime tap alive")
    @MainActor
    func unsupportedRemoteFormatKeepsRealtimeContinuity() async throws {
        let suiteName = "music-haptics-coordinator-unsupported-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-haptics-coordinator-unsupported-\(UUID().uuidString)", isDirectory: true)
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: makeWAVData(duration: 0.75, audioFormat: 7, bitsPerSample: 8),
            contentType: "audio/basic",
            responseChunkSize: 512
        )
        try await server.start()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: root) }

        let output = RecordingMusicHapticsOutputEngine()
        let coordinator = MusicHapticsCoordinator(
            store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
            defaults: defaults,
            analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
                primary: .remoteOriginal(server.url)
            ),
            outputEngine: output,
            isFeatureAvailable: true
        )
        defer { coordinator.stop() }

        let identity = MusicHapticsIdentity(
            serverID: "integration-server",
            remoteID: "unsupported-format",
            title: "Unsupported Format",
            artist: "Auralis",
            durationMilliseconds: 750
        )
        let preparation = await coordinator.preparePlayback(
            identity: identity,
            favorite: false,
            duration: 0.75,
            playbackURL: server.url
        )
        guard let realtime = preparation.realtimeTapSink else {
            Issue.record("The remote plan must install a realtime tap sink before playback")
            return
        }
        let format = MusicHapticsPCMFormat(
            sampleRate: 22_050,
            channels: 1,
            sampleType: .int16,
            interleaved: true,
            bytesPerFrame: 2,
            bytesPerSample: 2
        )!
        realtime.tapAttached()
        realtime.configurePCMStorage(format: format, maxFrames: 2_205)
        realtime.begin(format: format)

        coordinator.activate(preparation, position: 0, isPlaying: true)
        coordinator.updatePlaybackPosition(
            0.5,
            isPlaying: true,
            source: .playbackEngine
        )
        let pcm = makeCoordinatorPCM(duration: 0.75)
        realtime.consumePCM(pcm, time: 0, format: format, frameCount: pcm.count / 2)

        var diagnostics = await coordinator.diagnostics()
        for _ in 0..<60 {
            if diagnostics.decoderFailureStage == MusicHapticsAnalysisDiagnostic.unsupportedInputFormat.rawValue,
               diagnostics.currentEventSource == .realtimeTap,
               diagnostics.eventCount > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
            diagnostics = await coordinator.diagnostics()
        }

        #expect(diagnostics.source == .analyzing)
        #expect(diagnostics.planReason == "remote_decoder_failed_realtime_continuity")
        #expect(diagnostics.analysisFailureReason == MusicHapticsAnalysisDiagnostic.unsupportedInputFormat.rawValue)
        #expect(diagnostics.decoderFailureStage == MusicHapticsAnalysisDiagnostic.unsupportedInputFormat.rawValue)
        #expect(diagnostics.decoderFailureDomain == "AudioFileStream")
        #expect(diagnostics.decoderFailureCode == Int(kAudioFormatULaw))
        #expect(diagnostics.currentEventSource == .realtimeTap)
        #expect(diagnostics.realtimeAnalysisPosition > 0)
        #expect(diagnostics.eventCount > 0)
        #expect(output.playedWindows.contains { !$0.events.isEmpty })
    }

    @Test("without the pre-play tap, failure is explicit rather than silently reported as healthy")
    @MainActor
    func remoteFailureReportsMissingEventSourceWhenTapUnavailable() async throws {
        let suiteName = "music-haptics-coordinator-no-tap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-haptics-coordinator-no-tap-\(UUID().uuidString)", isDirectory: true)
        let server = try LocalHTTPAudioServer(statusCode: 200, body: Data("invalid".utf8))
        try await server.start()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: root) }

        let output = RecordingMusicHapticsOutputEngine()
        let coordinator = MusicHapticsCoordinator(
            store: MusicHapticsStore(root: root.appendingPathComponent("store", isDirectory: true)),
            defaults: defaults,
            analysisSourceProvider: InjectedRemoteAnalysisSourceProvider(
                primary: .remoteOriginal(server.url)
            ),
            outputEngine: output,
            isFeatureAvailable: true
        )
        defer { coordinator.stop() }

        let identity = MusicHapticsIdentity(
            serverID: "integration-server",
            remoteID: "no-tap",
            title: "No Tap",
            artist: "Auralis",
            durationMilliseconds: 750
        )
        let preparation = await coordinator.preparePlayback(
            identity: identity,
            favorite: false,
            duration: 0.75,
            playbackURL: server.url
        )
        coordinator.activate(preparation, position: 0, isPlaying: true)
        coordinator.updatePlaybackPosition(
            1.5,
            isPlaying: true,
            source: .playbackEngine
        )

        var diagnostics = await coordinator.diagnostics()
        for _ in 0..<60 {
            if diagnostics.planReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
            diagnostics = await coordinator.diagnostics()
        }

        #expect(diagnostics.source == .none)
        #expect(diagnostics.planReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue)
        #expect(diagnostics.analysisFailureReason == MusicHapticsAnalysisDiagnostic.noHapticEventSource.rawValue)
        #expect(diagnostics.analysisFailureDetail?.contains("domain=") == true)
        #expect(diagnostics.decoderFailureStage == MusicHapticsAnalysisDiagnostic.noAudioPacket.rawValue)
        #expect(diagnostics.decoderFailureDomain == "AudioFileStream")
        #expect(output.playedWindows.isEmpty)
    }

    @Test("Scene background does not suspend haptics, while actual suspension does")
    @MainActor
    func sceneBackgroundAndActualSuspensionHaveSeparateState() async {
        let suiteName = "music-haptics-coordinator-lifecycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let identity = MusicHapticsIdentity(
            serverID: "integration-server",
            remoteID: "lifecycle",
            title: "Lifecycle",
            artist: "Auralis",
            durationMilliseconds: 10_000
        )
        let timeline = MusicHapticsTimeline(
            identity: identity,
            duration: 10,
            analyzedDuration: 10,
            analysisCoverage: 1,
            events: []
        )
        let preparation = MusicHapticsPlaybackPreparation(
            identity: identity,
            favorite: false,
            plan: .custom(timeline),
            reason: "timeline_available",
            systemAvailability: MusicHapticsSystemAvailability(
                hasISRC: false,
                active: false,
                timelineAvailable: false
            ),
            fullTimelineExists: true,
            partialExists: false,
            effectiveEnabled: true,
            analysisSink: nil
        )
        let output = RecordingMusicHapticsOutputEngine()
        let coordinator = MusicHapticsCoordinator(
            defaults: defaults,
            outputEngine: output,
            isFeatureAvailable: true
        )
        defer { coordinator.stop() }

        coordinator.activate(preparation, position: 0, isPlaying: true)
        coordinator.applicationDidEnterBackground()

        #expect(output.backgroundTransitionCount == 1)
        #expect(output.pauseCount == 0)
        var background = await coordinator.diagnostics()
        #expect(background.isInBackground)
        #expect(!background.hapticsSuspended)

        coordinator.updatePlaybackPosition(
            3,
            isPlaying: true,
            source: .playbackEngine
        )
        background = await coordinator.diagnostics()
        #expect(background.playbackPosition == 3)

        output.triggerActualSuspension()
        let suspended = await coordinator.diagnostics()
        #expect(suspended.hapticsSuspended)
        #expect(suspended.applicationSuspended)

        coordinator.applicationDidBecomeActive(position: 7, isPlaying: true)
        let recovered = await coordinator.diagnostics()
        #expect(!recovered.isInBackground)
        #expect(!recovered.hapticsSuspended)
        #expect(recovered.playbackPosition == 7)
        #expect(recovered.foregroundRecoveryCount == 1)
        #expect(output.restartCount == 1)
    }
}

private struct InjectedRemoteAnalysisSourceProvider: MusicHapticsAnalysisSourceProvider {
    let primary: MusicHapticsAnalysisSource

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
        []
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
    private(set) var pauseCount = 0
    private(set) var backgroundTransitionCount = 0
    private(set) var restartCount = 0
    private var actualSuspensionHandler: (() -> Void)?

    func setActualSuspensionHandler(_ handler: (() -> Void)?) {
        actualSuspensionHandler = handler
    }

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

    func pause() { pauseCount += 1 }
    func resume(at offset: TimeInterval, playbackRate: Double) { state = .running }
    func seek(to offset: TimeInterval, playing: Bool, playbackRate: Double) {
        if playing { state = .running }
    }
    func stop() {}

    func applicationDidEnterBackground() {
        backgroundTransitionCount += 1
    }

    func restartIfNeeded() {
        restartCount += 1
        applicationSuspended = false
        state = .running
    }

    func triggerActualSuspension() {
        applicationSuspended = true
        state = .needsRestart
        actualSuspensionHandler?()
    }
}

private func makeCoordinatorPCM(duration: TimeInterval) -> Data {
    let sampleRate = 22_050
    let frameCount = Int(duration * Double(sampleRate))
    var data = Data(capacity: frameCount * 2)
    for frame in 0..<frameCount {
        let time = Double(frame) / Double(sampleRate)
        let beatPhase = time.truncatingRemainder(dividingBy: 0.5)
        let kick = 0.82 * Float(exp(-beatPhase * 40)) * Float(sin(2 * .pi * 62 * time))
        let snarePhase = (time + 0.25).truncatingRemainder(dividingBy: 0.5)
        let snare = 0.40 * Float(exp(-snarePhase * 52)) * Float(sin(2 * .pi * 2_800 * time))
        let bass = 0.18 * Float(sin(2 * .pi * 55 * time))
        var sample = Int16((max(-1, min(1, kick + snare + bass)) * Float(Int16.max)).rounded()).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}
