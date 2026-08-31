import AVFoundation
import Foundation
import MusicHaptics
import Testing

@Suite("Music Haptics remote source recovery", .serialized)
struct MusicHapticsRemoteFallbackTests {
    @Test("v2.3 cache miss keeps an independent remote lookahead source alive")
    func v23CacheMissRemoteLookaheadSuccess() async throws {
        let identity = testIdentity()
        let audioURL = try makeWAV(duration: 1, name: "remote-lookahead-success")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let source = MusicHapticsAnalysisSource.remoteLookahead(
            .init(url: audioURL, bitrate: 96, format: "mp3")
        )
        let request = MusicHapticsAnalysisRequest(
            identity: identity,
            favorite: false,
            duration: 1,
            analysisSource: source
        )
        let staleTimeline = MusicHapticsTimeline(
            identity: identity,
            duration: 1,
            analyzedDuration: 1,
            analysisCoverage: 1,
            events: [],
            algorithmVersion: "auralis-haptics-v2.2"
        )
        let decision = MusicHapticsPlaybackPlanResolver.resolve(
            featureEnabled: true,
            customHapticsSupported: true,
            systemTimelineAvailable: false,
            fullTimeline: staleTimeline,
            partial: nil,
            request: request
        )
        #expect(decision.plan.kind == .analyzeLookahead)

        let provider = InjectedSourceProvider(primary: source, fallbacks: [])
        let run = await runAnalyzer(
            provider: provider,
            identity: identity,
            duration: 1
        )
        #expect(run.failureCount == 0)
        #expect(run.result.finishReason == .naturalEnd)
        #expect(run.result.snapshot.analysisMode == .remoteLookahead)
        #expect(run.result.snapshot.analysisStreamBitrate == 96)
        #expect(run.result.snapshot.coverage >= 0.95)
    }

    @Test("remote decoder failure retries a refreshed sidecar before using progressive fallback")
    func remoteLookaheadFailureRetriesIndependentSources() async throws {
        let identity = testIdentity()
        let audioURL = try makeWAV(duration: 1, name: "remote-lookahead-refresh")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-missing-sidecar-\(UUID().uuidString).mp3")
        let primary = MusicHapticsAnalysisSource.remoteLookahead(
            .init(url: missingURL, bitrate: 96, format: "mp3")
        )
        let refreshed = MusicHapticsAnalysisSource.remoteLookahead(
            .init(url: audioURL, bitrate: 96, format: "mp3")
        )
        let progressive = MusicHapticsAnalysisSource.remoteProgressive(audioURL)
        let provider = InjectedSourceProvider(primary: primary, fallbacks: [refreshed, progressive])

        let run = await runAnalyzer(
            provider: provider,
            identity: identity,
            duration: 1
        )
        #expect(run.failureCount == 0)
        #expect(run.result.finishReason == .naturalEnd)
        #expect(run.result.snapshot.analysisMode == .remoteLookahead)
        #expect(run.diagnostics == [.remoteDecoderFailed])
    }

    @Test("remote lookahead falls back to an independent progressive source")
    func remoteLookaheadFailureUsesProgressiveSource() async throws {
        let identity = testIdentity()
        let audioURL = try makeWAV(duration: 1, name: "remote-progressive-fallback")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let missingSidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-missing-refresh-\(UUID().uuidString).mp3")
        let primary = MusicHapticsAnalysisSource.remoteLookahead(
            .init(url: missingSidecar, bitrate: 96, format: "mp3")
        )
        let refreshedSidecar = MusicHapticsAnalysisSource.remoteLookahead(
            .init(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("auralis-missing-second-\(UUID().uuidString).mp3"), bitrate: 96)
        )
        let provider = InjectedSourceProvider(
            primary: primary,
            fallbacks: [refreshedSidecar, .remoteProgressive(audioURL)]
        )

        let run = await runAnalyzer(
            provider: provider,
            identity: identity,
            duration: 1
        )
        #expect(run.failureCount == 0)
        #expect(run.result.finishReason == .naturalEnd)
        #expect(run.result.snapshot.analysisMode == .remoteProgressive)
        #expect(run.result.snapshot.analysisStreamBitrate == nil)
        #expect(run.diagnostics == [
            .remoteDecoderFailed,
            .remoteDecoderFailed,
            .remoteProgressiveFallback,
        ])
    }

    @Test("rotating sidecar refreshes still reach progressive fallback")
    func remoteLookaheadRefreshIsBounded() async throws {
        let identity = testIdentity()
        let audioURL = try makeWAV(duration: 1, name: "bounded-refresh")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let primary = MusicHapticsAnalysisSource.remoteLookahead(
            .init(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("auralis-missing-primary-\(UUID().uuidString).mp3"),
                bitrate: 96
            )
        )
        let provider = RotatingSidecarProvider(primary: primary, progressive: audioURL)

        let run = await runAnalyzer(
            provider: provider,
            identity: identity,
            duration: 1
        )
        let refreshCount = await provider.refreshCount
        #expect(refreshCount == 2)
        #expect(run.failureCount == 0)
        #expect(run.result.finishReason == .naturalEnd)
        #expect(run.result.snapshot.analysisMode == .remoteProgressive)
        #expect(run.diagnostics == [
            .remoteDecoderFailed,
            .remoteDecoderFailed,
            .remoteProgressiveFallback,
        ])
    }

    @Test("remote decoder failure never falls back to a current-item realtime tap")
    func remoteLookaheadFailureReportsNoIndependentSource() async throws {
        let identity = testIdentity()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-missing-sidecar-\(UUID().uuidString).mp3")
        let source = MusicHapticsAnalysisSource.remoteLookahead(
            .init(url: missingURL, bitrate: 96, format: "mp3")
        )
        let provider = InjectedSourceProvider(primary: source, fallbacks: [])

        let run = await runAnalyzer(
            provider: provider,
            identity: identity,
            duration: 1
        )
        #expect(run.failureCount == 1)
        #expect(run.result.finishReason == .playbackFailure)
        #expect(run.result.snapshot.analysisMode == .remoteLookahead)
        #expect(run.diagnostics == [
            .remoteDecoderFailed,
            .realtimeFallbackForbidden,
            .noHapticEventSource,
        ])
    }

    private func testIdentity() -> MusicHapticsIdentity {
        MusicHapticsIdentity(
            globalID: "server:remote-fallback",
            serverID: "server",
            remoteID: "remote-fallback",
            title: "Remote fallback",
            artist: "Auralis test",
            durationMilliseconds: 1_000
        )
    }

    private func runAnalyzer(
        provider: some MusicHapticsAnalysisSourceProvider,
        identity: MusicHapticsIdentity,
        duration: TimeInterval
    ) async -> AnalysisRun {
        let diagnostics = DiagnosticBox()
        let failureCount = FailureBox()
        let source = await provider.source(for: identity, playbackURL: nil) ?? .realtimeTap
        let analyzerHolder = AnalyzerHolder()
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<MusicHapticsAnalysisResult, Never>) in
            let analyzer = LookaheadMusicHapticsAnalyzer(
                identity: identity,
                duration: duration,
                onWindow: { _ in },
                onResult: { result in continuation.resume(returning: result) },
                onFailure: { failureCount.increment() },
                onDiagnostic: { diagnostics.append($0) },
                fallbackSourceProvider: { failedSource in
                    await provider.fallbackSources(
                        for: identity,
                        playbackURL: nil,
                        after: failedSource
                    )
                }
            )
            analyzerHolder.analyzer = analyzer
            analyzer.start(source: source)
        }
        analyzerHolder.analyzer = nil
        return AnalysisRun(
            result: result,
            diagnostics: diagnostics.values,
            failureCount: failureCount.value
        )
    }

    private func makeWAV(duration: TimeInterval, name: String) throws -> URL {
        let sampleRate = 44_100
        let frames = Int(duration * Double(sampleRate))
        let bytesPerSample = 2
        let dataSize = frames * bytesPerSample
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-haptics-\(name)-\(UUID().uuidString).wav")

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * bytesPerSample), to: &data)
        appendLittleEndian(UInt16(bytesPerSample), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(dataSize), to: &data)

        var samples = Data(count: dataSize)
        samples.withUnsafeMutableBytes { buffer in
            for frame in 0..<frames {
                let phase = Double(frame) / Double(sampleRate)
                let value = Int16(sin(phase * .pi * 2 * 220) * 12_000).littleEndian
                buffer.storeBytes(of: value, toByteOffset: frame * bytesPerSample, as: Int16.self)
            }
        }
        data.append(samples)
        try data.write(to: url)
        return url
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private struct AnalysisRun: Sendable {
    let result: MusicHapticsAnalysisResult
    let diagnostics: [MusicHapticsAnalysisDiagnostic]
    let failureCount: Int
}

private struct InjectedSourceProvider: MusicHapticsAnalysisSourceProvider {
    let primary: MusicHapticsAnalysisSource
    let fallbacks: [MusicHapticsAnalysisSource]

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

private actor RotatingSidecarProvider: MusicHapticsAnalysisSourceProvider {
    let primary: MusicHapticsAnalysisSource
    let progressive: URL
    private(set) var refreshCount = 0

    init(primary: MusicHapticsAnalysisSource, progressive: URL) {
        self.primary = primary
        self.progressive = progressive
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
        refreshCount += 1
        let refreshed = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-missing-refresh-\(UUID().uuidString).mp3")
        return [
            .remoteLookahead(.init(url: refreshed, bitrate: 96)),
            .remoteProgressive(progressive),
        ]
    }
}

private final class DiagnosticBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MusicHapticsAnalysisDiagnostic] = []

    var values: [MusicHapticsAnalysisDiagnostic] {
        lock.withLock { storage }
    }

    func append(_ value: MusicHapticsAnalysisDiagnostic) {
        lock.withLock { storage.append(value) }
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class AnalyzerHolder: @unchecked Sendable {
    var analyzer: LookaheadMusicHapticsAnalyzer?
}
