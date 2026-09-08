// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import AudioToolbox
import Foundation

public struct MusicHapticsAnalysisWindow: Hashable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let analysisPosition: TimeInterval
    public let events: [MusicHapticsEvent]
    public let coverage: Double
    public let analysisSpeedX: Double
    public let tempoBPM: Double?
    public let beatConfidence: Double
    public let sourceMode: MusicHapticsAnalysisMode
    public let eventCount: Int
    public let transientCount: Int
    public let continuousCount: Int
    public let mixerDiagnostics: MusicHapticsMixerDiagnostics

    public init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        analysisPosition: TimeInterval,
        events: [MusicHapticsEvent],
        coverage: Double,
        analysisSpeedX: Double,
        tempoBPM: Double?,
        beatConfidence: Double,
        sourceMode: MusicHapticsAnalysisMode = .remoteOriginal,
        eventCount: Int? = nil,
        transientCount: Int? = nil,
        continuousCount: Int? = nil,
        mixerDiagnostics: MusicHapticsMixerDiagnostics = .init()
    ) {
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.analysisPosition = max(0, analysisPosition)
        self.events = MusicHapticsEventDeduplicator.merge(events)
        self.coverage = min(max(coverage, 0), 1)
        self.analysisSpeedX = max(0, analysisSpeedX)
        self.tempoBPM = tempoBPM
        self.beatConfidence = min(max(beatConfidence, 0), 1)
        self.sourceMode = sourceMode
        self.eventCount = max(events.count, eventCount ?? events.count)
        self.transientCount = max(
            events.filter { $0.kind == .transient }.count,
            transientCount ?? events.filter { $0.kind == .transient }.count
        )
        self.continuousCount = max(
            events.filter { $0.kind == .continuous }.count,
            continuousCount ?? events.filter { $0.kind == .continuous }.count
        )
        self.mixerDiagnostics = mixerDiagnostics
    }

    /// Returns only the short commit slice that is safe to hand to Core
    /// Haptics. Analysis windows themselves may be arbitrarily far ahead.
    public func sliced(from lowerBound: TimeInterval, to upperBound: TimeInterval) -> Self {
        let lower = max(startTime, lowerBound)
        let upper = min(endTime, max(lower, upperBound))
        guard upper > lower else {
            return Self(
                startTime: lower,
                endTime: lower,
                analysisPosition: analysisPosition,
                events: [],
                coverage: coverage,
                analysisSpeedX: analysisSpeedX,
                tempoBPM: tempoBPM,
                beatConfidence: beatConfidence,
                sourceMode: sourceMode,
                eventCount: eventCount,
                transientCount: 0,
                continuousCount: 0,
                mixerDiagnostics: mixerDiagnostics
            )
        }
        let clipped = events.compactMap { event -> MusicHapticsEvent? in
            if event.kind == .transient {
                guard event.time >= lower, event.time < upper else { return nil }
                return event
            }
            let eventEnd = event.time + (event.duration ?? 0)
            guard eventEnd > lower, event.time < upper else { return nil }
            let segmentStart = max(lower, event.time)
            let segmentEnd = min(upper, eventEnd)
            let duration = segmentEnd - segmentStart
            guard duration >= 0.02 else { return nil }
            let offset = segmentStart - event.time
            var curve = event.curve.map {
                MusicHapticsCurvePoint(
                    timeOffset: min(duration, max(0, $0.timeOffset - offset)),
                    intensity: $0.intensity,
                    sharpness: $0.sharpness
                )
            }
            if curve.isEmpty {
                curve = [MusicHapticsCurvePoint(timeOffset: 0, intensity: event.intensity, sharpness: event.sharpness)]
            }
            return MusicHapticsEvent(
                time: segmentStart,
                duration: duration,
                intensity: event.intensity,
                sharpness: event.sharpness,
                kind: .continuous,
                classification: event.classification,
                climaxAmount: event.climaxAmount,
                curve: curve
            )
        }
        return Self(
            startTime: lower,
            endTime: upper,
            analysisPosition: analysisPosition,
            events: clipped,
            coverage: coverage,
            analysisSpeedX: analysisSpeedX,
            tempoBPM: tempoBPM,
            beatConfidence: beatConfidence,
            sourceMode: sourceMode,
            eventCount: eventCount,
            transientCount: clipped.filter { $0.kind == .transient }.count,
            continuousCount: clipped.filter { $0.kind == .continuous }.count,
            mixerDiagnostics: mixerDiagnostics
        )
    }
}

/// An independent original-stream decoder. It never creates a sidecar
/// transcode, never waits for a complete response, and never touches an
/// AVPlayerItem. The decoder emits canonical PCM as HTTP bytes arrive; this
/// type turns those chunks into persisted timeline ranges and short windows.
public final class LookaheadMusicHapticsAnalyzer: MusicHapticsPartialCheckpointProvider, @unchecked Sendable {
    public typealias WindowHandler = @Sendable (MusicHapticsAnalysisWindow) -> Void
    public typealias SnapshotHandler = @Sendable (MusicHapticsAnalysisSnapshot) -> Void
    public typealias ResultHandler = @Sendable (MusicHapticsAnalysisResult) -> Void
    public typealias FailureHandler = @Sendable () -> Void
    public typealias DiagnosticHandler = @Sendable (MusicHapticsAnalysisDiagnostic) -> Void
    public typealias DecoderFailureHandler = @Sendable (MusicHapticsDecoderFailure) -> Void
    public typealias DecoderFormatHandler = @Sendable (MusicHapticsProgressiveDecoderFormatInfo) -> Void
    public typealias FallbackSourceProvider = @Sendable (MusicHapticsAnalysisSource) async -> [MusicHapticsAnalysisSource]

    private let lock = NSLock()
    private let identity: MusicHapticsIdentity
    private let duration: TimeInterval
    private let onWindow: WindowHandler
    private let onProgress: SnapshotHandler
    private let onResult: ResultHandler
    private let onFailure: FailureHandler
    private let onDiagnostic: DiagnosticHandler
    private let onDecoderFailure: DecoderFailureHandler
    private let onDecoderFormat: DecoderFormatHandler
    private let fallbackSourceProvider: FallbackSourceProvider
    private let state: State
    private var task: Task<Void, Never>?
    private var didStart = false
    private var didFinish = false
    private var requestedFinishReason: MusicHapticsAnalysisFinishReason?
    private var sourceMode: MusicHapticsAnalysisMode = .remoteOriginal
    private let control = MusicHapticsAnalysisControl()

    public init(
        identity: MusicHapticsIdentity,
        duration: TimeInterval,
        partial: MusicHapticsPartialCheckpoint? = nil,
        onWindow: @escaping WindowHandler,
        onResult: @escaping ResultHandler,
        onProgress: @escaping SnapshotHandler = { _ in },
        onFailure: @escaping FailureHandler = {},
        onDiagnostic: @escaping DiagnosticHandler = { _ in },
        onDecoderFailure: @escaping DecoderFailureHandler = { _ in },
        onDecoderFormat: @escaping DecoderFormatHandler = { _ in },
        fallbackSourceProvider: @escaping FallbackSourceProvider = { _ in [] }
    ) {
        self.identity = identity
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        self.duration = safeDuration
        self.onWindow = onWindow
        self.onResult = onResult
        self.onProgress = onProgress
        self.onFailure = onFailure
        self.onDiagnostic = onDiagnostic
        self.onDecoderFailure = onDecoderFailure
        self.onDecoderFormat = onDecoderFormat
        self.fallbackSourceProvider = fallbackSourceProvider
        let compatiblePartial = partial.flatMap {
            $0.isCurrentAlgorithm
                && $0.identity.matchConfidence(with: identity) >= 0.82
                && $0.duration.isFinite
                && $0.duration > 0
                && abs($0.duration - safeDuration) <= max(2, safeDuration * 0.01)
                ? $0
                : nil
        }
        self.state = State(identity: identity, duration: safeDuration, partial: compatiblePartial)
    }

    public func start(source: MusicHapticsAnalysisSource) {
        let newTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.run(source: source)
        }
        let accepted = lock.withLock { () -> Bool in
            guard !didStart, !didFinish, requestedFinishReason == nil else { return false }
            didStart = true
            sourceMode = source.mode
            task = newTask
            return true
        }
        if !accepted { newTask.cancel() }
    }

    public func finishPartial(reason: MusicHapticsAnalysisFinishReason) {
        let action = lock.withLock { () -> (Task<Void, Never>?, Bool, MusicHapticsAnalysisMode) in
            guard !didFinish else { return (nil, false, sourceMode) }
            requestedFinishReason = reason
            if !didStart {
                didStart = true
                return (nil, true, sourceMode)
            }
            return (task, false, sourceMode)
        }
        control.cancel()
        action.0?.cancel()
        if action.1 {
            Task.detached(priority: .utility) { [weak self] in
                await self?.emitResult(reason: reason, sourceMode: action.2)
            }
        }
    }

    public func cancel() {
        control.cancel()
        lock.withLock {
            didFinish = true
            task?.cancel()
            task = nil
        }
    }

    public func pause() { control.pause() }
    public func resume() { control.resume() }

    public func updatePlaybackPosition(
        _ position: TimeInterval,
        isPlaying: Bool,
        rate: Double = 1
    ) {
        control.updatePlaybackPosition(position, isPlaying: isPlaying, rate: rate)
    }

    public func partialCheckpoint() async -> MusicHapticsPartialCheckpoint {
        await state.checkpoint()
    }

    private func run(source: MusicHapticsAnalysisSource) async {
        var currentSource = source
        var attemptedSources: Set<MusicHapticsAnalysisSource> = [source]
        let maximumRemoteRefreshAttempts = 2
        var remoteRefreshAttempts = 0
        // Persistence/DSP windows are small, while the analysis controller
        // separately limits how far this disposable sidecar may lead playback.
        let windowLength: TimeInterval = 0.5

        while true {
            do {
                switch currentSource {
                case let .localFile(url):
                    try await readOriginalStream(url: url, sourceMode: .local, windowLength: windowLength)
                case let .remoteOriginal(url):
                    try await readOriginalStream(url: url, sourceMode: .remoteOriginal, windowLength: windowLength)
                case .realtimeTap:
                    throw MusicHapticsAnalyzerError.cannotDecode
                }
                let reason = lock.withLock { requestedFinishReason ?? .naturalEnd }
                await emitResult(reason: reason, sourceMode: currentSource.mode)
                return
            } catch is CancellationError {
                let reason = lock.withLock { requestedFinishReason ?? .trackSwitch }
                await emitResult(reason: reason, sourceMode: currentSource.mode)
                return
            } catch {
                let state = lock.withLock { (requestedFinishReason != nil, didFinish) }
                guard !state.0, !state.1 else {
                    let reason = lock.withLock { requestedFinishReason ?? .trackSwitch }
                    await emitResult(reason: reason, sourceMode: currentSource.mode)
                    return
                }

                guard currentSource.mode == .remoteOriginal else {
                    onFailure()
                    let reason = lock.withLock { requestedFinishReason ?? .playbackFailure }
                    await emitResult(reason: reason, sourceMode: currentSource.mode)
                    return
                }

                guard remoteRefreshAttempts < maximumRemoteRefreshAttempts else {
                    onFailure()
                    let reason = lock.withLock { requestedFinishReason ?? .playbackFailure }
                    await emitResult(reason: reason, sourceMode: currentSource.mode)
                    return
                }
                remoteRefreshAttempts += 1
                let candidates = await fallbackSourceProvider(currentSource)
                guard let nextSource = candidates.first(where: {
                    !attemptedSources.contains($0) && $0.mode == .remoteOriginal
                }) else {
                    // The realtime tap is owned by PlaybackEngine and runs in
                    // parallel. This result only reports the independent
                    // decoder failure; the coordinator decides whether a tap
                    // is available before declaring no event source.
                    onFailure()
                    let reason = lock.withLock { requestedFinishReason ?? .playbackFailure }
                    await emitResult(reason: reason, sourceMode: currentSource.mode)
                    return
                }
                attemptedSources.insert(nextSource)
                onDiagnostic(.remoteOriginalRefresh)
                currentSource = nextSource
                lock.withLock { sourceMode = nextSource.mode }
            }
        }
    }

    private func readOriginalStream(
        url: URL,
        sourceMode: MusicHapticsAnalysisMode,
        windowLength: TimeInterval
    ) async throws {
        let startedAt = ContinuousClock.now
        let ranges = await state.uncoveredRanges()
        guard !ranges.isEmpty else {
            await state.markDecoderComplete(sourceMode: sourceMode)
            onProgress(await state.snapshot(sourceMode: sourceMode))
            return
        }

        for range in ranges {
            guard await control.waitUntilReady(
                analysisPosition: range.lowerBound,
                sourceDuration: duration
            ) else { throw CancellationError() }
            try Task.checkCancellation()

            let resumePoint = await state.resumePoint(for: range)
            await state.markDecoderOpening(sourceMode: sourceMode)
            onProgress(await state.snapshot(sourceMode: sourceMode))
            await state.beginSegment(
                start: range.lowerBound,
                sourceMode: sourceMode,
                startedAt: startedAt,
                windowLength: windowLength
            )
            let metricsBox = DecoderMetricsBox()
            let decoder = MusicHapticsProgressiveAudioDecoder()

            do {
                try await decoder.decode(
                    url: url,
                    startPosition: range.lowerBound,
                    resumePoint: resumePoint,
                    stopAtPosition: range.upperBound,
                    onPCM: { [weak self, state, metricsBox] chunk in
                        guard let self else { return }
                        // decode() awaits this callback, so this gate applies
                        // real back-pressure to URLSession consumption, PCM
                        // decode and DSP whenever playback owns the resources.
                        guard await self.control.waitUntilReady(
                            analysisPosition: chunk.time,
                            sourceDuration: self.duration
                        ) else { return }
                        let result = await state.append(
                            chunk: chunk,
                            within: range,
                            sourceMode: sourceMode,
                            decoderMetrics: metricsBox.value,
                            startedAt: startedAt,
                            windowLength: windowLength
                        )
                        result.windows.forEach(self.onWindow)
                        self.onProgress(result.snapshot)
                    },
                    onMetrics: { metricsBox.update($0) },
                    onFormat: onDecoderFormat,
                    onResumePoint: { [state] point in
                        await state.recordResumePoint(point)
                    }
                )
            } catch {
                await state.markDecoderFailed()
                reportDecoderFailure(error, sourceMode: sourceMode)
                throw error
            }

            if let metrics = metricsBox.value {
                await state.updateDecoderMetrics(metrics)
            }
            let final = await state.finishSegment(
                sourceMode: sourceMode,
                startedAt: startedAt,
                windowLength: windowLength
            )
            final.windows.forEach(onWindow)
            onProgress(final.snapshot)
        }

        if await state.uncoveredRanges().isEmpty {
            await state.markDecoderComplete(sourceMode: sourceMode)
        }
        let complete = await state.snapshot(sourceMode: sourceMode)
        onProgress(complete)
    }

    private func emitResult(
        reason: MusicHapticsAnalysisFinishReason,
        sourceMode: MusicHapticsAnalysisMode
    ) async {
        let shouldEmit = lock.withLock { () -> Bool in
            guard !didFinish else { return false }
            didFinish = true
            task = nil
            return true
        }
        guard shouldEmit else { return }
        await state.flush()
        let result = await state.result(reason: reason, sourceMode: sourceMode)
        onProgress(result.snapshot)
        onResult(result)
    }

    private func reportDecoderFailure(_ error: Error, sourceMode: MusicHapticsAnalysisMode) {
        guard sourceMode == .remoteOriginal else { return }
        let (diagnostic, domain, code) = Self.decoderFailureDetails(error)
        onDiagnostic(diagnostic)
        onDecoderFailure(MusicHapticsDecoderFailure(
            diagnostic: diagnostic,
            errorDomain: domain,
            errorCode: code
        ))
    }

    private static func decoderFailureDetails(
        _ error: Error
    ) -> (MusicHapticsAnalysisDiagnostic, String, Int) {
        if let error = error as? MusicHapticsProgressiveDecoderError {
            switch error {
            case .invalidURL: return (.remoteOriginalURLUnavailable, "AuralisMusicHaptics", 1)
            case .nonHTTPResponse: return (.remoteHTTPResponseFailed, "HTTP", 0)
            case let .httpStatus(status): return (.remoteHTTPResponseFailed, "HTTP", status)
            case .rangeNotHonored: return (.remoteHTTPResponseFailed, "HTTPRange", 1)
            case let .streamOpen(status): return (.streamOpenFailed, "AudioFileStream", Int(status))
            case let .streamParse(status): return (.streamParseFailed, "AudioFileStream", Int(status))
            case let .streamProperty(status): return (.streamPropertyFailed, "AudioFileStream", Int(status))
            case .noAudioFormat: return (.noAudioFormat, "AuralisMusicHaptics", 0)
            case .converterUnavailable: return (.converterInitFailed, "AVAudioConverter", 0)
            case let .converter(status): return (.converterFailed, "AVAudioConverter", Int(status))
            case let .converterNSError(domain, code): return (.converterFailed, domain, code)
            case let .unsupportedInputFormat(formatID): return (.unsupportedInputFormat, "AudioFileStream", Int(formatID))
            case .sampleDataUnavailable: return (.sampleDataUnavailable, "AudioFileStream", 0)
            case .noAudioPacket: return (.noAudioPacket, "AudioFileStream", 0)
            }
        }
        let nsError = error as NSError
        return (.remoteDecoderFailed, nsError.domain, nsError.code)
    }

    private final class DecoderMetricsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: MusicHapticsProgressiveDecoderMetrics?

        var value: MusicHapticsProgressiveDecoderMetrics? {
            lock.withLock { latest }
        }

        func update(_ metrics: MusicHapticsProgressiveDecoderMetrics) {
            lock.withLock { latest = metrics }
        }
    }

    private actor State {
        private let identity: MusicHapticsIdentity
        private let duration: TimeInterval
        private var processor = MusicHapticsDSPProcessor()
        private var mixer = MusicHapticsPerceptualMixer()
        private var events: [MusicHapticsEvent]
        private var newlyAnalyzedEvents: [MusicHapticsEvent] = []
        private var ranges: [MusicHapticsTimeRange]
        private var decoderResumePoints: [MusicHapticsDecoderResumePoint]
        private var analysisPosition: TimeInterval = 0
        private var remoteAnalysisPosition: TimeInterval = 0
        private var remoteAnalysisSpeedX: Double = 0
        private var remoteDecoderState: MusicHapticsRemoteDecoderState = .idle
        private var currentEventSource: MusicHapticsEventSource = .none
        private var lastProcessedEnd: TimeInterval = -Double.infinity
        private var sessionAnalyzedDuration: TimeInterval = 0
        private var sessionWallDuration: TimeInterval = 0
        private var segmentCursor: TimeInterval = 0
        private var segmentWindowLength: TimeInterval = 0.5
        private var eventCount = 0
        private var transientCount = 0
        private var continuousCount = 0

        init(identity: MusicHapticsIdentity, duration: TimeInterval, partial: MusicHapticsPartialCheckpoint?) {
            self.identity = identity
            let safeDuration = max(0, duration.isFinite ? duration : 0)
            self.duration = safeDuration
            let compatiblePartial = partial.flatMap {
                $0.isCurrentAlgorithm
                    && $0.identity.matchConfidence(with: identity) >= 0.82
                    && $0.duration.isFinite
                    && $0.duration > 0
                    && abs($0.duration - safeDuration) <= max(2, safeDuration * 0.01)
                    ? $0
                    : nil
            }
            let initialEvents = MusicHapticsEventDeduplicator.merge(compatiblePartial?.events ?? [])
            let initialRanges = compatiblePartial?.analyzedRanges ?? []
            self.events = initialEvents
            self.ranges = initialRanges
            self.decoderResumePoints = compatiblePartial?.decoderResumePoints ?? []
            self.eventCount = initialEvents.count
            self.transientCount = initialEvents.filter { $0.kind == .transient }.count
            self.continuousCount = initialEvents.filter { $0.kind == .continuous }.count
            // `analysisPosition` is the decoder's current session cursor, not
            // the furthest persisted range. Interior checkpoint ranges may
            // already extend far ahead; reporting their maximum here would
            // make a newly resumed decoder look faster than it is.
            self.analysisPosition = compatiblePartial?.firstUnanalyzedPosition ?? 0
        }

        func uncoveredRanges() -> [MusicHapticsTimeRange] {
            guard duration > 0 else { return [] }
            var cursor: TimeInterval = 0
            var result: [MusicHapticsTimeRange] = []
            for range in ranges {
                if range.lowerBound > cursor + MusicHapticsTimeRange.adjacencyTolerance {
                    result.append(MusicHapticsTimeRange(lowerBound: cursor, upperBound: range.lowerBound))
                }
                cursor = max(cursor, range.upperBound)
            }
            if cursor < duration - MusicHapticsTimeRange.completionTolerance {
                result.append(MusicHapticsTimeRange(lowerBound: cursor, upperBound: duration))
            }
            return result
        }

        func resumePoint(for range: MusicHapticsTimeRange) -> MusicHapticsDecoderResumePoint? {
            decoderResumePoints
                .filter { $0.position <= range.lowerBound + MusicHapticsTimeRange.adjacencyTolerance }
                .max { $0.position < $1.position }
        }

        func recordResumePoint(_ point: MusicHapticsDecoderResumePoint) {
            guard point.position.isFinite, point.position >= 0, point.position <= duration else { return }
            decoderResumePoints.append(point)
            var byPosition: [Int64: MusicHapticsDecoderResumePoint] = [:]
            for value in decoderResumePoints {
                let key = Int64((value.position * 1_000).rounded())
                if let old = byPosition[key], old.byteOffset >= value.byteOffset { continue }
                byPosition[key] = value
            }
            decoderResumePoints = byPosition.values.sorted { $0.position < $1.position }
        }

        func beginSegment(
            start: TimeInterval,
            sourceMode: MusicHapticsAnalysisMode,
            startedAt: ContinuousClock.Instant,
            windowLength: TimeInterval
        ) {
            processor = MusicHapticsDSPProcessor()
            mixer.reset()
            newlyAnalyzedEvents.removeAll(keepingCapacity: true)
            lastProcessedEnd = -Double.infinity
            segmentCursor = max(0, start)
            segmentWindowLength = max(0.05, windowLength)
            sessionWallDuration = max(sessionWallDuration, durationSeconds(startedAt.duration(to: .now)))
            if sourceMode == .remoteOriginal {
                remoteDecoderState = .streaming
                currentEventSource = .remoteOriginal
            }
        }

        func markDecoderOpening(sourceMode: MusicHapticsAnalysisMode) {
            guard sourceMode == .remoteOriginal else { return }
            remoteDecoderState = .opening
        }

        func updateDecoderMetrics(_ metrics: MusicHapticsProgressiveDecoderMetrics) {
            remoteAnalysisPosition = max(remoteAnalysisPosition, metrics.position)
            remoteAnalysisSpeedX = metrics.speedX
            remoteDecoderState = metrics.state
            analysisPosition = max(analysisPosition, metrics.position)
        }

        func append(
            chunk: MusicHapticsDecodedPCMChunk,
            within target: MusicHapticsTimeRange,
            sourceMode: MusicHapticsAnalysisMode,
            decoderMetrics: MusicHapticsProgressiveDecoderMetrics?,
            startedAt: ContinuousClock.Instant,
            windowLength: TimeInterval
        ) -> (windows: [MusicHapticsAnalysisWindow], snapshot: MusicHapticsAnalysisSnapshot) {
            if let decoderMetrics { updateDecoderMetrics(decoderMetrics) }
            let chunkDuration = Double(chunk.frameCount) / max(chunk.format.sampleRate, 1)
            let chunkEnd = chunk.time + chunkDuration
            analysisPosition = max(analysisPosition, min(duration, chunkEnd))
            if sourceMode == .remoteOriginal {
                remoteAnalysisPosition = max(remoteAnalysisPosition, min(duration, chunkEnd))
            }
            guard let mono = MusicHapticsPCMDecoder.decodeMono(
                bytes: chunk.data,
                format: chunk.format,
                frameCount: chunk.frameCount
            ) else {
                return ([], makeSnapshot(sourceMode: sourceMode))
            }

            let lower = max(target.lowerBound, chunk.time)
            let upper = min(target.upperBound, chunkEnd, duration)
            guard upper > lower else {
                return ([], makeSnapshot(sourceMode: sourceMode))
            }
            let segments = uncoveredSegments(lowerBound: lower, upperBound: upper)
            for (segmentIndex, segment) in segments.enumerated() {
                let startFrame = max(0, min(chunk.frameCount, Int(((segment.0 - chunk.time) * chunk.format.sampleRate).rounded())))
                let endFrame = max(startFrame, min(chunk.frameCount, Int(((segment.1 - chunk.time) * chunk.format.sampleRate).rounded())))
                guard endFrame > startFrame else { continue }
                let values = Array(mono[startFrame..<endFrame])
                let actualStart = chunk.time + Double(startFrame) / chunk.format.sampleRate
                let actualDuration = Double(values.count) / chunk.format.sampleRate
                if segmentIndex > 0 || (lastProcessedEnd.isFinite && abs(actualStart - lastProcessedEnd) > 0.05) {
                    processor = MusicHapticsDSPProcessor()
                    mixer.reset()
                }
                let candidates = processor.processCandidates(
                    monoSamples: values,
                    startTime: actualStart,
                    sampleRate: chunk.format.sampleRate
                )
                let produced = mixer.mix(frames: candidates).events
                appendEvents(produced)
                insertRange(MusicHapticsTimeRange(
                    lowerBound: actualStart,
                    upperBound: min(duration, actualStart + actualDuration)
                ))
                lastProcessedEnd = actualStart + actualDuration
                sessionAnalyzedDuration += actualDuration
            }
            sessionWallDuration = max(sessionWallDuration, durationSeconds(startedAt.duration(to: .now)))
            let windows = makeWindows(
                through: min(duration, max(segmentCursor, upper)),
                sourceMode: sourceMode,
                startedAt: startedAt,
                windowLength: windowLength
            )
            return (windows, makeSnapshot(sourceMode: sourceMode))
        }

        func finishSegment(
            sourceMode: MusicHapticsAnalysisMode,
            startedAt: ContinuousClock.Instant,
            windowLength: TimeInterval
        ) -> (windows: [MusicHapticsAnalysisWindow], snapshot: MusicHapticsAnalysisSnapshot) {
            let produced = mixer.mix(frames: processor.finishCandidates()).events
                + mixer.finish().events
            appendEvents(produced)
            let windows = makeWindows(
                through: min(duration, max(segmentCursor, analysisPosition)),
                sourceMode: sourceMode,
                startedAt: startedAt,
                windowLength: windowLength,
                forceFinal: true
            )
            processor = MusicHapticsDSPProcessor()
            mixer.reset()
            lastProcessedEnd = -.infinity
            return (windows, makeSnapshot(sourceMode: sourceMode))
        }

        func flush() {
            let produced = mixer.mix(frames: processor.finishCandidates()).events
                + mixer.finish().events
            appendEvents(produced)
        }

        func markDecoderComplete(sourceMode: MusicHapticsAnalysisMode) {
            if sourceMode == .remoteOriginal {
                remoteDecoderState = .complete
                remoteAnalysisPosition = max(remoteAnalysisPosition, analysisPosition)
                currentEventSource = .remoteOriginal
            }
        }

        func markDecoderFailed() {
            remoteDecoderState = .failed
        }

        func snapshot(sourceMode: MusicHapticsAnalysisMode) -> MusicHapticsAnalysisSnapshot {
            makeSnapshot(sourceMode: sourceMode)
        }

        func result(
            reason: MusicHapticsAnalysisFinishReason,
            sourceMode: MusicHapticsAnalysisMode
        ) -> MusicHapticsAnalysisResult {
            let checkpoint = checkpoint()
            return MusicHapticsAnalysisResult(
                checkpoint: checkpoint,
                timeline: checkpoint.isComplete ? checkpoint.timeline() : nil,
                snapshot: makeSnapshot(sourceMode: sourceMode, finishReason: reason),
                finishReason: reason
            )
        }

        func checkpoint() -> MusicHapticsPartialCheckpoint {
            let diagnostics = processor.diagnostics
            return MusicHapticsPartialCheckpoint(
                identity: identity,
                duration: duration,
                analyzedRanges: ranges,
                events: MusicHapticsEventDeduplicator.merge(events),
                mixMode: .fullMix,
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                beatPhase: diagnostics.beatPhase,
                decoderResumePoints: decoderResumePoints
            )
        }

        private func makeWindows(
            through position: TimeInterval,
            sourceMode: MusicHapticsAnalysisMode,
            startedAt: ContinuousClock.Instant,
            windowLength: TimeInterval,
            forceFinal: Bool = false
        ) -> [MusicHapticsAnalysisWindow] {
            let upper = min(duration, max(segmentCursor, position))
            var result: [MusicHapticsAnalysisWindow] = []
            let length = max(0.05, windowLength)
            while segmentCursor + length <= upper + 0.0001 {
                let end = min(duration, segmentCursor + length)
                let window = makeWindow(start: segmentCursor, end: end, sourceMode: sourceMode, startedAt: startedAt)
                if !window.events.isEmpty { result.append(window) }
                segmentCursor = end
                if end >= duration { break }
            }
            if forceFinal, upper > segmentCursor + 0.02 {
                let window = makeWindow(start: segmentCursor, end: upper, sourceMode: sourceMode, startedAt: startedAt)
                if !window.events.isEmpty { result.append(window) }
                segmentCursor = upper
            }
            return result
        }

        private func makeWindow(
            start: TimeInterval,
            end: TimeInterval,
            sourceMode: MusicHapticsAnalysisMode,
            startedAt: ContinuousClock.Instant
        ) -> MusicHapticsAnalysisWindow {
            let pending = newlyAnalyzedEvents.filter { event in
                guard event.time < end else { return false }
                if event.kind == .transient { return event.time >= start }
                return event.time + (event.duration ?? 0) > start
            }
            newlyAnalyzedEvents.removeAll { pending.contains($0) }
            let wall = durationSeconds(startedAt.duration(to: .now))
            let speed = wall > 0 ? sessionAnalyzedDuration / wall : 0
            let diagnostics = processor.diagnostics
            return MusicHapticsAnalysisWindow(
                startTime: start,
                endTime: end,
                analysisPosition: analysisPosition,
                events: pending,
                coverage: coverage,
                analysisSpeedX: max(speed, remoteAnalysisSpeedX),
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                sourceMode: sourceMode,
                eventCount: eventCount,
                transientCount: transientCount,
                continuousCount: continuousCount,
                mixerDiagnostics: mixer.diagnostics
            )
        }

        private func makeSnapshot(
            sourceMode: MusicHapticsAnalysisMode,
            finishReason: MusicHapticsAnalysisFinishReason? = nil
        ) -> MusicHapticsAnalysisSnapshot {
            let diagnostics = processor.diagnostics
            return MusicHapticsAnalysisSnapshot(
                analyzedRanges: ranges,
                coverage: coverage,
                eventCount: eventCount,
                finishReason: finishReason,
                analysisMode: sourceMode,
                analysisPosition: max(analysisPosition, diagnostics.analysisPosition),
                analysisSpeedX: measuredSpeed,
                remoteAnalysisPosition: remoteAnalysisPosition,
                remoteAnalysisSpeedX: remoteAnalysisSpeedX,
                remoteDecoderState: remoteDecoderState,
                currentEventSource: currentEventSource,
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                transientCount: transientCount,
                continuousCount: continuousCount,
                mixerDiagnostics: mixer.diagnostics
            )
        }

        private func appendEvents(_ produced: [MusicHapticsEvent]) {
            guard !produced.isEmpty else { return }
            events.append(contentsOf: produced)
            newlyAnalyzedEvents.append(contentsOf: produced)
            eventCount += produced.count
            transientCount += produced.filter { $0.kind == .transient }.count
            continuousCount += produced.filter { $0.kind == .continuous }.count
        }

        private var measuredSpeed: Double {
            guard sessionWallDuration > 0 else { return 0 }
            return sessionAnalyzedDuration / sessionWallDuration
        }

        private func uncoveredSegments(
            lowerBound: TimeInterval,
            upperBound: TimeInterval
        ) -> [(TimeInterval, TimeInterval)] {
            guard upperBound > lowerBound else { return [] }
            var cursor = lowerBound
            var result: [(TimeInterval, TimeInterval)] = []
            for range in ranges {
                guard range.upperBound > cursor else { continue }
                if range.lowerBound > cursor {
                    result.append((cursor, min(range.lowerBound, upperBound)))
                }
                cursor = max(cursor, range.upperBound)
                if cursor >= upperBound { break }
            }
            if cursor < upperBound { result.append((cursor, upperBound)) }
            return result.filter { $0.1 - $0.0 > 0.001 }
        }

        private func insertRange(_ range: MusicHapticsTimeRange) {
            guard range.duration > 0 else { return }
            var merged = range
            let tolerance = MusicHapticsTimeRange.adjacencyTolerance
            var first = 0
            while first < ranges.count,
                  ranges[first].upperBound + tolerance < merged.lowerBound {
                first += 1
            }
            var end = first
            while end < ranges.count,
                  ranges[end].lowerBound <= merged.upperBound + tolerance {
                let existing = ranges[end]
                merged = MusicHapticsTimeRange(
                    lowerBound: min(existing.lowerBound, merged.lowerBound),
                    upperBound: max(existing.upperBound, merged.upperBound)
                )
                end += 1
            }
            ranges.replaceSubrange(first..<end, with: CollectionOfOne(merged))
        }

        private var coverage: Double {
            guard duration > 0 else { return 0 }
            return min(1, ranges.reduce(0) { $0 + $1.duration } / duration)
        }

        private func durationSeconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }
    }
}
