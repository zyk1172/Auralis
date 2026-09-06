import Foundation
import AudioToolbox
import Testing
@testable import MusicHaptics

@Suite("Music Haptics original-stream analysis", .serialized)
struct MusicHapticsOriginalStreamTests {
    @Test("the original FLAC decoder emits PCM before the HTTP body reaches EOF")
    func progressiveDecoderEmitsPCMBeforeResponseFinishes() async throws {
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 512,
            responseChunkDelay: 0.05
        )
        try await server.start()
        defer { server.stop() }

        let capture = DecoderCapture()
        let decoder = MusicHapticsProgressiveAudioDecoder(chunkByteCapacity: 512)
        try await decoder.decode(
            url: server.url,
            onPCM: { chunk in
                capture.append(chunk, responseFinished: server.bodyFinished)
            }
        )

        #expect(capture.firstPCMBeforeResponseFinished == true)
        #expect(capture.chunkCount > 0)
        #expect(capture.lastPosition > 0)
    }

    @Test("a progressive original WAV uses the PCM decoder path without a compressed buffer")
    func progressiveDecoderAcceptsLinearPCM() async throws {
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: makeWAVData(duration: 0.75),
            contentType: "audio/wav",
            responseChunkSize: 512,
            responseChunkDelay: 0.01
        )
        try await server.start()
        defer { server.stop() }

        let capture = DecoderCapture()
        let formats = DecoderFormatCapture()
        let decoder = MusicHapticsProgressiveAudioDecoder(chunkByteCapacity: 512)
        try await decoder.decode(
            url: server.url,
            onPCM: { chunk in
                capture.append(chunk, responseFinished: server.bodyFinished)
            },
            onFormat: { formats.append($0) }
        )

        let format = try #require(formats.first)
        #expect(format.formatID == UInt32(kAudioFormatLinearPCM))
        #expect(format.decoderPath == .pcm)
        #expect(format.channels == 1)
        #expect(format.bitsPerChannel == 16)
        #expect(capture.firstPCMBeforeResponseFinished == true)
        #expect(capture.chunkCount > 0)
        #expect(capture.lastPosition > 0)
    }

    @Test("an unsupported original stream fails safely without constructing a compressed buffer")
    func progressiveDecoderRejectsUnsupportedInputFormatSafely() async throws {
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: makeWAVData(duration: 0.5, audioFormat: 7, bitsPerSample: 8),
            contentType: "audio/basic",
            responseChunkSize: 512
        )
        try await server.start()
        defer { server.stop() }

        let capture = DecoderCapture()
        let formats = DecoderFormatCapture()
        let decoder = MusicHapticsProgressiveAudioDecoder(chunkByteCapacity: 512)
        do {
            try await decoder.decode(
                url: server.url,
                onPCM: { chunk in
                    capture.append(chunk, responseFinished: server.bodyFinished)
                },
                onFormat: { formats.append($0) }
            )
            Issue.record("The unsupported μ-law stream unexpectedly decoded successfully")
        } catch let error as MusicHapticsProgressiveDecoderError {
            #expect(error == .unsupportedInputFormat(UInt32(kAudioFormatULaw)))
        } catch {
            Issue.record("Unexpected decoder error: \(error)")
        }

        let format = try #require(formats.first)
        #expect(format.formatID == UInt32(kAudioFormatULaw))
        #expect(format.decoderPath == .unsupported)
        #expect(capture.chunkCount == 0)
    }

    @Test("v2.4 cache miss uses the original remote FLAC and produces analysis before EOF")
    func originalFLACCacheMissUsesIncrementalAnalyzer() async throws {
        let identity = testIdentity(duration: 0.75)
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 512,
            responseChunkDelay: 0.05
        )
        try await server.start()
        defer { server.stop() }

        let capture = AnalysisCapture()
        let run = await runAnalyzer(
            identity: identity,
            duration: 0.75,
            source: .remoteOriginal(server.url),
            capture: capture,
            responseFinished: { server.bodyFinished }
        )

        #expect(run.result.finishReason == .naturalEnd)
        #expect(run.result.snapshot.analysisMode == .remoteOriginal)
        #expect(run.result.snapshot.remoteDecoderState == .complete)
        #expect(run.result.snapshot.coverage >= 0.95)
        #expect(run.result.checkpoint.isCurrentAlgorithm)
        #expect(run.result.timeline?.algorithmVersion == MusicHapticsTimeline.algorithmVersion)
        #expect(capture.firstWindowBeforeResponseFinished == true)
        #expect(capture.windows.contains { !$0.events.isEmpty })
        #expect(server.requestCount == 1)
    }

    @Test("a stale v2.3 timeline is a cache miss and the original FLAC path still completes")
    func staleTimelineDoesNotReuseOldAlgorithmCache() async throws {
        let identity = testIdentity(duration: 0.75)
        let staleTimeline = MusicHapticsTimeline(
            identity: identity,
            duration: 0.75,
            analyzedDuration: 0.75,
            analysisCoverage: 1,
            events: [],
            algorithmVersion: "auralis-haptics-v2.3"
        )
        let request = MusicHapticsAnalysisRequest(
            identity: identity,
            favorite: false,
            duration: 0.75,
            analysisSource: .remoteOriginal(URL(string: "https://example.invalid/original.flac")!)
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

        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 8 * 1024
        )
        try await server.start()
        defer { server.stop() }

        let run = await runAnalyzer(
            identity: identity,
            duration: 0.75,
            source: .remoteOriginal(server.url),
            capture: AnalysisCapture()
        )
        #expect(run.result.timeline != nil)
        #expect(run.result.snapshot.analysisMode == .remoteOriginal)
    }

    @Test("refresh retries the same original stream without creating a sidecar")
    func originalStreamRefreshIsBoundedAndKeepsEncoding() async throws {
        let identity = testIdentity(duration: 0.75)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-missing-original-\(UUID().uuidString).flac")
        let server = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac"
        )
        try await server.start()
        defer { server.stop() }

        let diagnostics = DiagnosticCapture()
        let run = await runAnalyzer(
            identity: identity,
            duration: 0.75,
            source: .remoteOriginal(missingURL),
            fallbackSources: [.remoteOriginal(server.url)],
            capture: AnalysisCapture(),
            diagnostics: diagnostics
        )

        #expect(run.result.finishReason == .naturalEnd)
        #expect(run.result.snapshot.analysisMode == .remoteOriginal)
        #expect(diagnostics.values.contains(.remoteDecoderFailed))
        #expect(diagnostics.values.contains(.remoteOriginalRefresh))
        #expect(server.requestCount == 1)
    }

    @Test("the scheduler accepts a complete timeline far beyond the old twenty-second lead")
    @MainActor
    func schedulerDoesNotThrottleAnalysisLead() {
        let scheduler = RollingMusicHapticsScheduler(hapticCommitHorizon: 3)
        _ = scheduler.updateClock(position: 0, isPlaying: true)
        let window = MusicHapticsAnalysisWindow(
            startTime: 0,
            endTime: 40,
            analysisPosition: 40,
            events: [
                MusicHapticsEvent(
                    time: 1,
                    intensity: 0.8,
                    sharpness: 0.3,
                    kind: .transient,
                    classification: .kick
                ),
                MusicHapticsEvent(
                    time: 31,
                    intensity: 0.8,
                    sharpness: 0.3,
                    kind: .transient,
                    classification: .kick
                )
            ],
            coverage: 1,
            analysisSpeedX: 8,
            tempoBPM: 120,
            beatConfidence: 0.8,
            sourceMode: .remoteOriginal
        )

        let first = scheduler.ingest(window)
        #expect(scheduler.hapticCommitHorizon == 3)
        #expect(first.contains { $0.endTime <= 3.001 })
        #expect(scheduler.scheduledUntil >= 3)
        let later = scheduler.updateClock(position: 30, isPlaying: true)
        #expect(later.contains { $0.events.contains { $0.time == 31 } })
        #expect(scheduler.scheduledUntil >= 33)
    }

    @Test("realtime tap fills a slow lookahead gap and a later remote window upgrades it without duplicate events")
    @MainActor
    func realtimeTapArbitratesWithOriginalStream() {
        let scheduler = RollingMusicHapticsScheduler(hapticCommitHorizon: 3)
        _ = scheduler.updateClock(position: 0, isPlaying: true)

        let realtime = MusicHapticsAnalysisWindow(
            startTime: 0,
            endTime: 4,
            analysisPosition: 4,
            events: [
                MusicHapticsEvent(time: 0.5, intensity: 0.7, sharpness: 0.2, kind: .transient, classification: .kick),
                MusicHapticsEvent(time: 1.5, intensity: 0.7, sharpness: 0.2, kind: .transient, classification: .kick),
                MusicHapticsEvent(time: 2.5, intensity: 0.7, sharpness: 0.2, kind: .transient, classification: .kick),
                MusicHapticsEvent(time: 3.5, intensity: 0.7, sharpness: 0.2, kind: .transient, classification: .kick)
            ],
            coverage: 0.1,
            analysisSpeedX: 0.72,
            tempoBPM: 120,
            beatConfidence: 0.7,
            sourceMode: .realtimeTap
        )
        let first = scheduler.ingest(realtime)
        #expect(first.contains { $0.events.contains { $0.time == 0.5 } })
        #expect(scheduler.currentEventSource == .realtimeTap)

        _ = scheduler.updateClock(position: 1, isPlaying: true)
        _ = scheduler.updateClock(position: 2, isPlaying: true)

        let remote = MusicHapticsAnalysisWindow(
            startTime: 1.5,
            endTime: 4.5,
            analysisPosition: 4.5,
            events: [
                MusicHapticsEvent(time: 1.5, intensity: 0.8, sharpness: 0.3, kind: .transient, classification: .kick),
                MusicHapticsEvent(time: 2.5, intensity: 0.8, sharpness: 0.3, kind: .transient, classification: .kick),
                MusicHapticsEvent(time: 3.5, intensity: 0.8, sharpness: 0.3, kind: .transient, classification: .kick),
                MusicHapticsEvent(time: 4.25, intensity: 0.8, sharpness: 0.3, kind: .transient, classification: .snareClap)
            ],
            coverage: 0.2,
            analysisSpeedX: 5.7,
            tempoBPM: 120,
            beatConfidence: 0.9,
            sourceMode: .remoteOriginal
        )
        let upgraded = scheduler.ingest(remote)
        let emitted = first + upgraded
        let eventTimes = emitted.flatMap(\.events).map(\.time)

        #expect(emitted.contains { window in
            window.sourceMode == .remoteOriginal
                && window.events.contains { $0.time == 4.25 }
        })
        #expect(Set(eventTimes).count == eventTimes.count)
        #expect(scheduler.currentEventSource == .remoteOriginal)
        #expect(scheduler.scheduledUntil >= 4.5)
    }

    @Test("partial checkpoints preserve interior holes and resume anchors")
    func checkpointResumesTheActualMissingRange() {
        let identity = testIdentity(duration: 60)
        let firstEvent = MusicHapticsEvent(
            time: 4,
            intensity: 0.7,
            sharpness: 0.2,
            kind: .transient,
            classification: .kick
        )
        let secondEvent = MusicHapticsEvent(
            time: 24,
            intensity: 0.8,
            sharpness: 0.2,
            kind: .transient,
            classification: .snareClap
        )
        let checkpoint = MusicHapticsPartialCheckpoint(
            identity: identity,
            duration: 60,
            analyzedRanges: [
                MusicHapticsTimeRange(lowerBound: 0, upperBound: 10),
                MusicHapticsTimeRange(lowerBound: 20, upperBound: 30)
            ],
            events: [firstEvent, secondEvent],
            decoderResumePoints: [
                MusicHapticsDecoderResumePoint(position: 10, byteOffset: 10_000, packetIndex: 100),
                MusicHapticsDecoderResumePoint(position: 30, byteOffset: 30_000, packetIndex: 300)
            ]
        )

        #expect(checkpoint.uncoveredRanges == [
            MusicHapticsTimeRange(lowerBound: 10, upperBound: 20),
            MusicHapticsTimeRange(lowerBound: 30, upperBound: 60)
        ])
        #expect(checkpoint.firstUnanalyzedPosition == 10)
        #expect(checkpoint.resumePoint(for: checkpoint.uncoveredRanges[0])?.position == 10)

        let resumed = MusicHapticsPartialCheckpoint(
            identity: identity,
            duration: 60,
            analyzedRanges: [MusicHapticsTimeRange(lowerBound: 30, upperBound: 60)],
            events: [secondEvent]
        )
        let merged = checkpoint.merged(with: resumed)
        #expect(merged.uncoveredRanges == [
            MusicHapticsTimeRange(lowerBound: 10, upperBound: 20)
        ])
        #expect(merged.events.count == 2)
        #expect(merged.analyzedRanges.contains {
            abs($0.lowerBound - 20) < 0.001 && abs($0.upperBound - 60) < 0.001
        })
    }

    @Test("an analyzer checkpoint resumes an original stream at a byte anchor and completes without duplicate events")
    func analyzerResumesFromCheckpoint() async throws {
        let duration: TimeInterval = 0.75
        let identity = testIdentity(duration: duration)
        let firstServer = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 512,
            responseChunkDelay: 0.02
        )
        try await firstServer.start()
        defer { firstServer.stop() }

        let holder = LookaheadHolder()
        let stopOnce = StopOnce()
        let firstResult = await withCheckedContinuation {
            (continuation: CheckedContinuation<MusicHapticsAnalysisResult, Never>) in
            let analyzer = LookaheadMusicHapticsAnalyzer(
                identity: identity,
                duration: duration,
                onWindow: { _ in
                    guard stopOnce.take() else { return }
                    holder.analyzer?.finishPartial(reason: .trackSwitch)
                },
                onResult: { result in continuation.resume(returning: result) }
            )
            holder.analyzer = analyzer
            // This fixture tests decoder/checkpoint behavior, not startup throttling.
            // Simulate an already-running playback clock so the audio-first gate
            // grants the disposable analyzer a budget.
            analyzer.updatePlaybackPosition(duration, isPlaying: true)
            analyzer.start(source: .remoteOriginal(firstServer.url))
        }
        holder.analyzer = nil

        #expect(firstResult.finishReason == .trackSwitch)
        #expect(firstResult.checkpoint.coverage > 0.05)
        #expect(firstResult.checkpoint.coverage < 0.999)
        #expect(!firstResult.checkpoint.decoderResumePoints.isEmpty)

        let resumeServer = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 512
        )
        try await resumeServer.start()
        defer { resumeServer.stop() }

        let resumed = await runAnalyzer(
            identity: identity,
            duration: duration,
            source: .remoteOriginal(resumeServer.url),
            partial: firstResult.checkpoint,
            capture: AnalysisCapture()
        )

        #expect(resumed.result.finishReason == .naturalEnd)
        #expect(resumed.result.checkpoint.isComplete)
        #expect(resumed.result.timeline != nil)
        #expect(resumeServer.rangeRequests.count >= 2)
        #expect(resumeServer.rangeRequests.contains { $0.hasSuffix("-") })

        let deduplicatedEvents = MusicHapticsEventDeduplicator.merge(
            resumed.result.checkpoint.events
        )
        #expect(deduplicatedEvents == resumed.result.checkpoint.events)
        let firstCoveredEnd = firstResult.checkpoint.analyzedRanges.first?.upperBound ?? 0
        let firstEvents = firstResult.checkpoint.events.filter { $0.time < firstCoveredEnd }
        let resumedEventsInCoveredPrefix = resumed.result.checkpoint.events.filter { $0.time < firstCoveredEnd }
        #expect(resumedEventsInCoveredPrefix == firstEvents)
    }

    @Test("an analyzer resumes an interior missing range without replaying covered ranges")
    func analyzerResumesInteriorHole() async throws {
        let duration: TimeInterval = 0.75
        let identity = testIdentity(duration: duration)
        let initialServer = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 8 * 1024
        )
        try await initialServer.start()
        defer { initialServer.stop() }

        let complete = await runAnalyzer(
            identity: identity,
            duration: duration,
            source: .remoteOriginal(initialServer.url),
            capture: AnalysisCapture()
        )
        #expect(complete.result.checkpoint.isComplete)

        let partial = MusicHapticsPartialCheckpoint(
            identity: identity,
            duration: duration,
            analyzedRanges: [
                MusicHapticsTimeRange(lowerBound: 0, upperBound: 0.25),
                MusicHapticsTimeRange(lowerBound: 0.5, upperBound: duration)
            ],
            events: complete.result.checkpoint.events.filter {
                $0.time < 0.25 || $0.time >= 0.5
            },
            decoderResumePoints: complete.result.checkpoint.decoderResumePoints
        )
        #expect(partial.uncoveredRanges == [
            MusicHapticsTimeRange(lowerBound: 0.25, upperBound: 0.5)
        ])

        let resumeServer = try LocalHTTPAudioServer(
            statusCode: 200,
            body: RemoteFLACFixture.data,
            contentType: "audio/flac",
            responseChunkSize: 512
        )
        try await resumeServer.start()
        defer { resumeServer.stop() }

        let resumed = await runAnalyzer(
            identity: identity,
            duration: duration,
            source: .remoteOriginal(resumeServer.url),
            partial: partial,
            capture: AnalysisCapture()
        )

        #expect(resumed.result.finishReason == .naturalEnd)
        #expect(resumed.result.checkpoint.isComplete)
        #expect(resumed.result.checkpoint.uncoveredRanges.isEmpty)
        #expect(resumeServer.rangeRequests.count >= 2)
        #expect(resumeServer.rangeRequests.contains { $0.hasSuffix("-") })
        #expect(
            MusicHapticsEventDeduplicator.merge(resumed.result.checkpoint.events)
                == resumed.result.checkpoint.events
        )
    }

    @Test("a forty-second simulated playback produces measured realtime throughput and continuous output")
    @MainActor
    func longRealtimeRunReportsActualMetrics() async throws {
        let duration: TimeInterval = 40
        let identity = testIdentity(duration: duration)
        let capture = AnalysisCapture()
        let holder = ResultHolder()
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<MusicHapticsAnalysisResult, Never>) in
            let analyzer = StreamingMusicHapticsAnalyzer(
                identity: identity,
                duration: duration,
                onResult: { result in continuation.resume(returning: result) },
                onProgress: { capture.append(snapshot: $0) },
                onWindow: { capture.append(window: $0) }
            )
            holder.analyzer = analyzer
            Task { @MainActor in
                let format = int16MonoFormat(sampleRate: 22_050)
                analyzer.tapAttached()
                analyzer.configurePCMStorage(format: format, maxFrames: 2_205)
                analyzer.begin(format: format)
                let pcm = makeSyntheticPCM(duration: duration, sampleRate: 22_050)
                let bytesPerFrame = 2
                let framesPerChunk = 2_205
                for chunkIndex in 0..<Int(duration * 10) {
                    let start = chunkIndex * framesPerChunk * bytesPerFrame
                    let end = min(pcm.count, start + framesPerChunk * bytesPerFrame)
                    guard start < end else { break }
                    analyzer.consumePCM(
                        pcm.subdata(in: start..<end),
                        time: Double(chunkIndex) * 0.1,
                        format: format,
                        frameCount: (end - start) / bytesPerFrame
                    )
                    // Keep the injected realtime source just below the utility
                    // consumer's Debug-build throughput. The render callback is
                    // never allowed to wait in production; this pacing only keeps
                    // this 40-second continuity test from deliberately filling a
                    // bounded ring and turning expected disposable drops into a
                    // flaky failure.
                    try? await Task.sleep(for: .milliseconds(125))
                }
                analyzer.finishPartial(reason: .naturalEnd)
            }
        }
        holder.analyzer = nil

        #expect(result.snapshot.analysisPosition >= 39)
        #expect(result.snapshot.analysisPosition > 30)
        #expect(result.snapshot.realtimeAnalysisPosition >= 39)
        #expect(result.snapshot.realtimeAnalysisSpeedX > 0)
        #expect(result.snapshot.realtimeAnalysisSpeedX.isFinite)
        #expect(result.snapshot.droppedFrames == 0)
        #expect(capture.windows.contains { $0.events.contains { $0.time >= 10 && $0.time < 20 } })
        #expect(capture.windows.contains { $0.events.contains { $0.time >= 20 && $0.time < 30 } })
        #expect(capture.windows.contains { $0.events.contains { $0.time >= 30 && $0.time < 40 } })

        let scheduler = RollingMusicHapticsScheduler(hapticCommitHorizon: 3)
        _ = scheduler.updateClock(position: 0, isPlaying: true)
        for window in capture.windows {
            _ = scheduler.ingest(window)
        }
        for position in stride(from: 1.0, through: 30.0, by: 1.0) {
            _ = scheduler.updateClock(position: position, isPlaying: true)
        }
        let playbackPosition = 30.0
        let lead = result.snapshot.analysisPosition - playbackPosition
        let analysisPosition = result.snapshot.analysisPosition
        let analysisSpeedX = result.snapshot.realtimeAnalysisSpeedX
        let droppedFrames = result.snapshot.droppedFrames
        print(
            "HAPTICS_TEST_METRICS playbackPosition=\(playbackPosition) " +
            "analysisPosition=\(analysisPosition) " +
            "analysisLeadSeconds=\(lead) " +
            "analysisSpeedX=\(analysisSpeedX) " +
            "scheduledUntil=\(scheduler.scheduledUntil) " +
            "droppedFrames=\(droppedFrames)"
        )
        #expect(scheduler.scheduledUntil >= playbackPosition)
    }

    @Test("a 96 kHz stereo Float32 tap sizes storage from its real callback format")
    func highSpecificationPCMDoesNotStarveRing() async throws {
        let identity = testIdentity(duration: 1)
        let holder = ResultHolder()
        let format = try #require(MusicHapticsPCMFormat(
            sampleRate: 96_000,
            channels: 2,
            sampleType: .float32,
            interleaved: true,
            bytesPerFrame: 8,
            bytesPerSample: 4
        ))
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<MusicHapticsAnalysisResult, Never>) in
            let analyzer = StreamingMusicHapticsAnalyzer(
                identity: identity,
                duration: 1,
                onResult: { result in continuation.resume(returning: result) }
            )
            holder.analyzer = analyzer
            analyzer.tapAttached()
            analyzer.configurePCMStorage(format: format, maxFrames: 9_600)
            analyzer.begin(format: format)
            let framesPerChunk = 9_600
            var data = Data(count: framesPerChunk * format.bytesPerFrame)
            data.withUnsafeMutableBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Float32.self)
                for index in stride(from: 0, to: samples.count, by: 2) {
                    let phase = Double(index / 2) / format.sampleRate
                    let value = Float(sin(phase * 2 * .pi * 65))
                    samples[index] = value
                    samples[index + 1] = value
                }
            }
            analyzer.consumePCM(
                data,
                time: 0,
                format: format,
                frameCount: framesPerChunk
            )
            analyzer.finishPartial(reason: .naturalEnd)
        }
        holder.analyzer = nil

        #expect(result.snapshot.pcmFormat == format)
        #expect(result.snapshot.droppedFrames == 0)
        #expect(result.snapshot.droppedAudioDuration == 0)
    }

    @Test("a 96 kHz stereo packed 24-bit tap is accepted without ring starvation")
    func highSpecificationPacked24PCMDoesNotStarveRing() async throws {
        let identity = testIdentity(duration: 1)
        let holder = ResultHolder()
        let format = try #require(MusicHapticsPCMFormat(
            sampleRate: 96_000,
            channels: 2,
            sampleType: .int24,
            interleaved: true,
            bytesPerFrame: 6,
            bytesPerSample: 3
        ))
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<MusicHapticsAnalysisResult, Never>) in
            let analyzer = StreamingMusicHapticsAnalyzer(
                identity: identity,
                duration: 1,
                onResult: { result in continuation.resume(returning: result) }
            )
            holder.analyzer = analyzer
            analyzer.tapAttached()
            analyzer.configurePCMStorage(format: format, maxFrames: 9_600)
            analyzer.begin(format: format)
            let frames = 9_600
            var data = Data(count: frames * format.bytesPerFrame)
            data.withUnsafeMutableBytes { rawBuffer in
                for frame in 0..<frames {
                    let time = Double(frame) / format.sampleRate
                    let value = Int32((sin(time * 2 * .pi * 65) * 0x7F_FFFF).rounded())
                    let unsigned = UInt32(bitPattern: value)
                    for channel in 0..<format.channels {
                        let offset = frame * format.bytesPerFrame + channel * 3
                        rawBuffer[offset] = UInt8(truncatingIfNeeded: unsigned)
                        rawBuffer[offset + 1] = UInt8(truncatingIfNeeded: unsigned >> 8)
                        rawBuffer[offset + 2] = UInt8(truncatingIfNeeded: unsigned >> 16)
                    }
                }
            }
            analyzer.consumePCM(
                data,
                time: 0,
                format: format,
                frameCount: frames
            )
            analyzer.finishPartial(reason: .naturalEnd)
        }
        holder.analyzer = nil

        #expect(result.snapshot.pcmFormat == format)
        #expect(result.snapshot.droppedFrames == 0)
        #expect(result.snapshot.droppedAudioDuration == 0)
    }

    private func testIdentity(duration: TimeInterval) -> MusicHapticsIdentity {
        MusicHapticsIdentity(
            globalID: "server:original-stream",
            serverID: "server",
            remoteID: "original-stream-\(duration)",
            title: "Original Stream",
            artist: "Auralis Test",
            durationMilliseconds: Int((duration * 1_000).rounded())
        )
    }

    private func runAnalyzer(
        identity: MusicHapticsIdentity,
        duration: TimeInterval,
        source: MusicHapticsAnalysisSource,
        fallbackSources: [MusicHapticsAnalysisSource] = [],
        partial: MusicHapticsPartialCheckpoint? = nil,
        capture: AnalysisCapture,
        diagnostics: DiagnosticCapture? = nil,
        responseFinished: @escaping @Sendable () -> Bool = { false }
    ) async -> AnalysisRun {
        let holder = ResultHolder()
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<MusicHapticsAnalysisResult, Never>) in
            let analyzer = LookaheadMusicHapticsAnalyzer(
                identity: identity,
                duration: duration,
                partial: partial,
                onWindow: { window in
                    capture.append(window: window, responseFinished: responseFinished())
                },
                onResult: { result in continuation.resume(returning: result) },
                onProgress: { capture.append(snapshot: $0) },
                onFailure: { capture.incrementFailure() },
                onDiagnostic: { diagnostics?.append($0) },
                onDecoderFailure: { diagnostics?.append($0.diagnostic) },
                fallbackSourceProvider: { _ in fallbackSources }
            )
            holder.analyzer = analyzer
            // These fixtures isolate decoder/DSP behavior. Advance the synthetic
            // playback clock so the production audio-first budget is explicitly
            // granted instead of bypassing the gate.
            analyzer.updatePlaybackPosition(duration, isPlaying: true)
            analyzer.start(source: source)
        }
        holder.analyzer = nil
        return AnalysisRun(result: result, windows: capture.windows)
    }
}

private struct AnalysisRun: Sendable {
    let result: MusicHapticsAnalysisResult
    let windows: [MusicHapticsAnalysisWindow]
}

private final class ResultHolder: @unchecked Sendable {
    var analyzer: AnyObject?
}

private final class LookaheadHolder: @unchecked Sendable {
    var analyzer: LookaheadMusicHapticsAnalyzer?
}

private final class StopOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func take() -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
    }
}

private final class DecoderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFirstPCMBeforeResponseFinished = false
    private var storedSawPCM = false
    private var storedChunkCount = 0
    private var storedLastPosition: TimeInterval = 0

    var firstPCMBeforeResponseFinished: Bool {
        lock.withLock { storedFirstPCMBeforeResponseFinished }
    }

    var chunkCount: Int {
        lock.withLock { storedChunkCount }
    }

    var lastPosition: TimeInterval {
        lock.withLock { storedLastPosition }
    }

    func append(_ chunk: MusicHapticsDecodedPCMChunk, responseFinished: Bool) {
        lock.withLock {
            if !storedSawPCM {
                storedFirstPCMBeforeResponseFinished = !responseFinished
            }
            storedSawPCM = true
            storedChunkCount += 1
            storedLastPosition = max(
                storedLastPosition,
                chunk.time + Double(chunk.frameCount) / chunk.format.sampleRate
            )
        }
    }
}

private final class DecoderFormatCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFormats: [MusicHapticsProgressiveDecoderFormatInfo] = []

    var first: MusicHapticsProgressiveDecoderFormatInfo? {
        lock.withLock { storedFormats.first }
    }

    func append(_ format: MusicHapticsProgressiveDecoderFormatInfo) {
        lock.withLock { storedFormats.append(format) }
    }
}

private final class AnalysisCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWindows: [MusicHapticsAnalysisWindow] = []
    private var storedSnapshots: [MusicHapticsAnalysisSnapshot] = []
    private var storedFailureCount = 0
    private var firstWindowBeforeResponseFinishedValue: Bool?

    var windows: [MusicHapticsAnalysisWindow] {
        lock.withLock { storedWindows }
    }

    var firstWindowBeforeResponseFinished: Bool? {
        lock.withLock { firstWindowBeforeResponseFinishedValue }
    }

    func append(window: MusicHapticsAnalysisWindow, responseFinished: Bool = false) {
        lock.withLock {
            storedWindows.append(window)
            if firstWindowBeforeResponseFinishedValue == nil {
                firstWindowBeforeResponseFinishedValue = !responseFinished
            }
        }
    }

    func append(snapshot: MusicHapticsAnalysisSnapshot) {
        lock.withLock { storedSnapshots.append(snapshot) }
    }

    func incrementFailure() {
        lock.withLock { storedFailureCount += 1 }
    }
}

private final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [MusicHapticsAnalysisDiagnostic] = []

    var values: [MusicHapticsAnalysisDiagnostic] {
        lock.withLock { storedValues }
    }

    func append(_ value: MusicHapticsAnalysisDiagnostic) {
        lock.withLock { storedValues.append(value) }
    }
}

private func int16MonoFormat(sampleRate: Double) -> MusicHapticsPCMFormat {
    MusicHapticsPCMFormat(
        sampleRate: sampleRate,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
}

private func makeSyntheticPCM(duration: TimeInterval, sampleRate: Double) -> Data {
    let frameCount = Int(duration * sampleRate)
    var data = Data(capacity: frameCount * 2)
    for frame in 0..<frameCount {
        let time = Double(frame) / sampleRate
        let beatPhase = time.truncatingRemainder(dividingBy: 0.5)
        let kick = 0.85 * Float(exp(-beatPhase * 42)) * Float(sin(2 * .pi * 62 * time))
        let snarePhase = (time + 0.25).truncatingRemainder(dividingBy: 0.5)
        let snare = 0.42 * Float(exp(-snarePhase * 55)) * Float(sin(2 * .pi * 2_800 * time))
        let bass = 0.18 * Float(sin(2 * .pi * 55 * time))
        let value = max(-1, min(1, kick + snare + bass))
        var sample = Int16((value * Float(Int16.max)).rounded()).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}

func makeWAVData(
    duration: TimeInterval,
    sampleRate: Int = 44_100,
    audioFormat: UInt16 = 1,
    bitsPerSample: Int = 16
) -> Data {
    let channels = 1
    let safeDuration = max(0, duration)
    let frameCount = max(1, Int((safeDuration * Double(sampleRate)).rounded()))
    let bytesPerSample = max(1, (bitsPerSample + 7) / 8)
    let blockAlign = channels * bytesPerSample
    let dataSize = frameCount * blockAlign
    var data = Data()
    data.append(contentsOf: Data("RIFF".utf8))
    data.appendLittleEndian(UInt32(36 + dataSize))
    data.append(contentsOf: Data("WAVE".utf8))
    data.append(contentsOf: Data("fmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(audioFormat)
    data.appendLittleEndian(UInt16(channels))
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(UInt32(sampleRate * blockAlign))
    data.appendLittleEndian(UInt16(blockAlign))
    data.appendLittleEndian(UInt16(bitsPerSample))
    data.append(contentsOf: Data("data".utf8))
    data.appendLittleEndian(UInt32(dataSize))

    if audioFormat == 7 || audioFormat == 6 {
        data.append(contentsOf: Data(repeating: 0xff, count: dataSize))
    } else {
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let sample = Int16((sin(time * 2 * .pi * 220) * 0.25 * Double(Int16.max)).rounded())
            data.appendLittleEndian(sample)
        }
    }
    return data
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}