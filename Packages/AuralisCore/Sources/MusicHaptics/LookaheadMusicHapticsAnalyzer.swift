import AVFoundation
import AudioToolbox
import CoreMedia
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
    public let analysisStreamBitrate: Int?
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
        sourceMode: MusicHapticsAnalysisMode = .remoteLookahead,
        analysisStreamBitrate: Int? = nil,
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
        self.analysisStreamBitrate = analysisStreamBitrate.map { max(1, $0) }
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

    /// Returns only the commit slice that is safe to hand to Core Haptics.
    /// Continuous events are clipped and their curve offsets are rebased so a
    /// scheduler can commit a bounded horizon without changing global time.
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
                analysisStreamBitrate: analysisStreamBitrate,
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
            analysisStreamBitrate: analysisStreamBitrate,
            eventCount: eventCount,
            transientCount: clipped.filter { $0.kind == .transient }.count,
            continuousCount: clipped.filter { $0.kind == .continuous }.count,
            mixerDiagnostics: mixerDiagnostics
        )
    }
}

/// Reads the upper-layer supplied low-bitrate/local sidecar as quickly as the
/// decoder and network permit.  It is deliberately independent of AVPlayer:
/// no second original-quality stream is opened and no render-thread callback
/// participates in lookahead analysis.
public final class LookaheadMusicHapticsAnalyzer: @unchecked Sendable {
    public typealias WindowHandler = @Sendable (MusicHapticsAnalysisWindow) -> Void
    public typealias SnapshotHandler = @Sendable (MusicHapticsAnalysisSnapshot) -> Void
    public typealias ResultHandler = @Sendable (MusicHapticsAnalysisResult) -> Void
    public typealias FailureHandler = @Sendable () -> Void

    private let lock = NSLock()
    private let identity: MusicHapticsIdentity
    private let duration: TimeInterval
    private let partial: MusicHapticsPartialCheckpoint?
    private let onWindow: WindowHandler
    private let onProgress: SnapshotHandler
    private let onResult: ResultHandler
    private let onFailure: FailureHandler
    private let state: State
    private var task: Task<Void, Never>?
    private var didStart = false
    private var didFinish = false
    private var requestedFinishReason: MusicHapticsAnalysisFinishReason?
    private var sourceMode: MusicHapticsAnalysisMode = .remoteLookahead

    public init(
        identity: MusicHapticsIdentity,
        duration: TimeInterval,
        partial: MusicHapticsPartialCheckpoint? = nil,
        onWindow: @escaping WindowHandler,
        onResult: @escaping ResultHandler,
        onProgress: @escaping SnapshotHandler = { _ in },
        onFailure: @escaping FailureHandler = {}
    ) {
        self.identity = identity
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        self.duration = safeDuration
        self.partial = partial.flatMap {
            $0.isCurrentAlgorithm
                && $0.identity.matchConfidence(with: identity) >= 0.82
                && $0.duration.isFinite
                && $0.duration > 0
                && abs($0.duration - safeDuration) <= max(2, safeDuration * 0.01)
                ? $0
                : nil
        }
        self.onWindow = onWindow
        self.onResult = onResult
        self.onProgress = onProgress
        self.onFailure = onFailure
        self.state = State(identity: identity, duration: safeDuration, partial: self.partial)
    }

    public func start(source: MusicHapticsAnalysisSource) {
        let newTask = Task.detached(priority: .utility) { [weak self] in
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

    /// Stops the sidecar but still emits the accumulated real ranges/events so
    /// a track switch cannot erase work already decoded.
    public func finishPartial(reason: MusicHapticsAnalysisFinishReason) {
        let action = lock.withLock { () -> (task: Task<Void, Never>?, emitImmediately: Bool, sourceMode: MusicHapticsAnalysisMode) in
            guard !didFinish else { return (nil, false, self.sourceMode) }
            requestedFinishReason = reason
            // Mark an analyzer that has not started as started as well. This
            // closes the prepare/cancel race where a late `start()` could
            // resurrect a sidecar after a track switch.
            if !didStart {
                didStart = true
                return (nil, true, sourceMode)
            }
            return (self.task, false, sourceMode)
        }
        action.task?.cancel()
        if action.emitImmediately {
            Task.detached(priority: .utility) { [weak self] in
                await self?.emitResult(reason: reason, sourceMode: action.sourceMode)
            }
        }
    }

    public func cancel() {
        lock.withLock {
            didFinish = true
            task?.cancel()
            task = nil
        }
    }

    private func run(source: MusicHapticsAnalysisSource) async {
        var nextWindowStart = partial?.firstUnanalyzedPosition ?? 0
        let sourceMode = source.mode
        // Windows are intentionally contiguous and non-overlapping.  The
        // scheduler can queue them ahead without double-playing overlap.
        let windowLength: TimeInterval = 6
        do {
            switch source {
            case let .localFile(url):
                try await read(url: url, sourceMode: .local, nextWindowStart: &nextWindowStart, windowLength: windowLength, bitrate: nil)
            case let .remoteLookahead(remote):
                try await read(url: remote.url, sourceMode: .remoteLookahead, nextWindowStart: &nextWindowStart, windowLength: windowLength, bitrate: remote.bitrate)
            case .realtimeTap:
                throw MusicHapticsAnalyzerError.cannotDecode
            }
            let reason = lock.withLock { requestedFinishReason ?? .naturalEnd }
            await emitResult(reason: reason, sourceMode: sourceMode)
        } catch is CancellationError {
            let reason = lock.withLock { requestedFinishReason ?? .trackSwitch }
            await emitResult(reason: reason, sourceMode: sourceMode)
        } catch {
            let state = lock.withLock {
                (
                    finishRequested: requestedFinishReason != nil,
                    cancelled: didFinish
                )
            }
            // AVAssetReader may surface cancellation as a reader error rather
            // than Swift CancellationError. A deliberate track switch or
            // preparation replacement must not be mistaken for a sidecar
            // failure and activate the realtime tap on the next item.
            if !state.finishRequested, !state.cancelled {
                onFailure()
            }
            let reason = lock.withLock { requestedFinishReason ?? .playbackFailure }
            // Preserve any bytes decoded before a network/transcode failure.
            await emitResult(reason: reason, sourceMode: sourceMode)
        }
    }

    private func read(
        url: URL,
        sourceMode: MusicHapticsAnalysisMode,
        nextWindowStart: inout TimeInterval,
        windowLength: TimeInterval,
        bitrate: Int? = nil
    ) async throws {
        let startedAt = ContinuousClock.now
        await state.setAnalysisStreamBitrate(bitrate)
        let asset = AVURLAsset(url: url)
        // Do not wait for remote duration metadata before decoding. The
        // catalog duration is already part of the request, and HTTP/MP3
        // sidecars may expose an indefinite duration until substantial data
        // has arrived. This keeps the first lookahead window on the decode
        // path instead of on a metadata round trip.
        let sourceDuration = duration
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw MusicHapticsAnalyzerError.noAudioTrack }
        let sampleRate = 22_050.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicHapticsAnalyzerError.cannotDecode }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MusicHapticsAnalyzerError.cannotDecode }

        let format = MusicHapticsPCMFormat(
            sampleRate: sampleRate,
            channels: 1,
            sampleType: .int16,
            interleaved: true,
            bytesPerFrame: 2,
            bytesPerSample: 2
        )!
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frameCount = CMSampleBufferGetNumSamples(sample)
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard length >= 2, frameCount > 0, time.isFinite else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: destination.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr,
                  let mono = MusicHapticsPCMDecoder.decodeMono(bytes: bytes, format: format, frameCount: frameCount)
            else { continue }
            let sampleDuration = CMSampleBufferGetDuration(sample).seconds
            let sampleLength = sampleDuration.isFinite && sampleDuration > 0
                ? sampleDuration
                : Double(frameCount) / sampleRate
            if await state.isAlreadyAnalyzed(lowerBound: time, upperBound: time + sampleLength) {
                await state.recordSkippedRange(lowerBound: time, upperBound: time + sampleLength)
            } else {
                await state.append(
                    monoSamples: mono,
                    time: time,
                    sampleRate: sampleRate,
                    duration: sampleLength
                )
            }
            let progress = await state.progress(
                sourceMode: sourceMode,
                startedAt: startedAt,
                sourceDuration: sourceDuration
            )
            onProgress(progress.snapshot)
            while progress.analysisPosition >= nextWindowStart + windowLength {
                let end = min(duration, nextWindowStart + windowLength)
                let window = await state.window(
                    startTime: nextWindowStart,
                    endTime: end,
                    sourceMode: sourceMode,
                    startedAt: startedAt,
                    sourceDuration: sourceDuration
                )
                if !window.events.isEmpty { onWindow(window) }
                nextWindowStart = end
                if nextWindowStart >= duration { break }
            }
        }
        if reader.status == .failed { throw reader.error ?? MusicHapticsAnalyzerError.cannotDecode }
        let progress = await state.progress(
            sourceMode: sourceMode,
            startedAt: startedAt,
            sourceDuration: sourceDuration
        )
        if progress.analysisPosition > nextWindowStart {
            let window = await state.window(
                startTime: nextWindowStart,
                endTime: min(duration, max(nextWindowStart, progress.analysisPosition)),
                sourceMode: sourceMode,
                startedAt: startedAt,
                sourceDuration: sourceDuration
            )
            if !window.events.isEmpty { onWindow(window) }
        }
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

    private actor State {
        private let identity: MusicHapticsIdentity
        private let duration: TimeInterval
        private var processor = MusicHapticsDSPProcessor()
        private var mixer = MusicHapticsPerceptualMixer()
        private var events: [MusicHapticsEvent]
        private var newlyAnalyzedEvents: [MusicHapticsEvent] = []
        private var ranges: [MusicHapticsTimeRange]
        private var analysisPosition: TimeInterval = 0
        private var lastProcessedEnd: TimeInterval = -.infinity
        private var needsProcessorReset = false
        private var sessionAnalyzedDuration: TimeInterval = 0
        private var analysisStreamBitrate: Int?

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
            self.events = compatiblePartial?.events ?? []
            self.ranges = compatiblePartial?.analyzedRanges ?? []
            self.analysisPosition = compatiblePartial?.firstUnanalyzedPosition ?? 0
        }

        func setAnalysisStreamBitrate(_ bitrate: Int?) {
            analysisStreamBitrate = bitrate.map { max(1, $0) }
        }

        func append(monoSamples: [Float], time: TimeInterval, sampleRate: Double, duration frameDuration: TimeInterval) {
            let end = time + max(0, frameDuration)
            if needsProcessorReset || (lastProcessedEnd.isFinite && abs(time - lastProcessedEnd) > 0.5) {
                processor = MusicHapticsDSPProcessor()
                mixer.reset()
            }
            needsProcessorReset = false
            let produced = mixer.mix(frames: processor.processCandidates(
                monoSamples: monoSamples,
                startTime: time,
                sampleRate: sampleRate
            )).events
            events.append(contentsOf: produced)
            newlyAnalyzedEvents.append(contentsOf: produced)
            insertRange(MusicHapticsTimeRange(lowerBound: time, upperBound: end))
            lastProcessedEnd = end
            sessionAnalyzedDuration += max(0, frameDuration)
            analysisPosition = max(analysisPosition, end)
        }

        func isAlreadyAnalyzed(lowerBound: TimeInterval, upperBound: TimeInterval) -> Bool {
            ranges.contains {
                lowerBound >= $0.lowerBound - 0.001
                    && upperBound <= $0.upperBound + 0.001
            }
        }

        func recordSkippedRange(lowerBound: TimeInterval, upperBound: TimeInterval) {
            guard upperBound > lowerBound else { return }
            needsProcessorReset = true
            analysisPosition = max(analysisPosition, upperBound)
        }

        func flush() {
            let produced = mixer.mix(frames: processor.finishCandidates()).events
                + mixer.finish().events
            events.append(contentsOf: produced)
            newlyAnalyzedEvents.append(contentsOf: produced)
        }

        func progress(
            sourceMode: MusicHapticsAnalysisMode,
            startedAt: ContinuousClock.Instant,
            sourceDuration: TimeInterval
        ) -> (snapshot: MusicHapticsAnalysisSnapshot, analysisPosition: TimeInterval) {
            let checkpoint = checkpoint()
            let wall = durationSeconds(startedAt.duration(to: .now))
            let speed = wall > 0 ? sessionAnalyzedDuration / wall : 0
            let diagnostics = processor.diagnostics
            return (
                MusicHapticsAnalysisSnapshot(
                    analyzedRanges: checkpoint.analyzedRanges,
                    coverage: checkpoint.coverage,
                    eventCount: checkpoint.events.count,
                    analysisMode: sourceMode,
                    analysisStreamBitrate: analysisStreamBitrate,
                    analysisPosition: max(analysisPosition, diagnostics.analysisPosition),
                    analysisSpeedX: speed,
                    tempoBPM: diagnostics.tempoBPM,
                    beatConfidence: diagnostics.beatConfidence,
                    transientCount: checkpoint.events.filter { $0.kind == .transient }.count,
                    continuousCount: checkpoint.events.filter { $0.kind == .continuous }.count,
                    mixerDiagnostics: mixer.diagnostics
                ),
                max(analysisPosition, min(sourceDuration, diagnostics.analysisPosition))
            )
        }

        func window(
            startTime: TimeInterval,
            endTime: TimeInterval,
            sourceMode: MusicHapticsAnalysisMode,
            startedAt: ContinuousClock.Instant,
            sourceDuration: TimeInterval
        ) -> MusicHapticsAnalysisWindow {
            let checkpoint = checkpoint()
            let wall = durationSeconds(startedAt.duration(to: .now))
            let speed = wall > 0 ? sessionAnalyzedDuration / wall : 0
            let diagnostics = processor.diagnostics
            let windowEnd = max(startTime, endTime)
            // A section event is emitted when its end is known, which may be
            // after the six-second bucket containing its start. Send that
            // late event in a correction window beginning at its real start;
            // the scheduler preserves its already-committed cursor when it
            // replaces the older bucket.
            let pendingBeforeEnd = newlyAnalyzedEvents.filter { $0.time < windowEnd }
            let windowStart = min(
                startTime,
                pendingBeforeEnd.map(\.time).min() ?? startTime
            )
            let windowEvents = pendingBeforeEnd.filter { event in
                if event.kind == .transient {
                    return event.time >= windowStart
                }
                return event.time + (event.duration ?? 0) > windowStart
            }
            newlyAnalyzedEvents.removeAll { windowEvents.contains($0) }
            return MusicHapticsAnalysisWindow(
                startTime: windowStart,
                endTime: windowEnd,
                analysisPosition: max(analysisPosition, diagnostics.analysisPosition),
                // Existing partial events are deliberately excluded. A
                // partial checkpoint is recovery data, not a formal playback
                // timeline; only newly decoded windows may be scheduled.
                events: windowEvents,
                coverage: checkpoint.coverage,
                analysisSpeedX: speed,
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                sourceMode: sourceMode,
                analysisStreamBitrate: analysisStreamBitrate,
                eventCount: checkpoint.events.count,
                transientCount: checkpoint.events.filter { $0.kind == .transient }.count,
                continuousCount: checkpoint.events.filter { $0.kind == .continuous }.count,
                mixerDiagnostics: mixer.diagnostics
            )
        }

        func result(
            reason: MusicHapticsAnalysisFinishReason,
            sourceMode: MusicHapticsAnalysisMode
        ) -> MusicHapticsAnalysisResult {
            let checkpoint = checkpoint()
            let diagnostics = processor.diagnostics
            let snapshot = MusicHapticsAnalysisSnapshot(
                analyzedRanges: checkpoint.analyzedRanges,
                coverage: checkpoint.coverage,
                eventCount: checkpoint.events.count,
                finishReason: reason,
                analysisMode: sourceMode,
                analysisStreamBitrate: analysisStreamBitrate,
                analysisPosition: max(analysisPosition, diagnostics.analysisPosition),
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                transientCount: checkpoint.events.filter { $0.kind == .transient }.count,
                continuousCount: checkpoint.events.filter { $0.kind == .continuous }.count,
                mixerDiagnostics: mixer.diagnostics
            )
            return MusicHapticsAnalysisResult(
                checkpoint: checkpoint,
                timeline: checkpoint.isComplete ? checkpoint.timeline() : nil,
                snapshot: snapshot,
                finishReason: reason
            )
        }

        private func checkpoint() -> MusicHapticsPartialCheckpoint {
            let diagnostics = processor.diagnostics
            return MusicHapticsPartialCheckpoint(
                identity: identity,
                duration: duration,
                analyzedRanges: ranges,
                events: MusicHapticsEventDeduplicator.merge(events),
                mixMode: .fullMix,
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                beatPhase: diagnostics.beatPhase
            )
        }

        private func insertRange(_ range: MusicHapticsTimeRange) {
            guard range.duration > 0 else { return }
            var merged = range
            var result: [MusicHapticsTimeRange] = []
            for existing in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if existing.upperBound < merged.lowerBound || merged.upperBound < existing.lowerBound {
                    result.append(existing)
                } else {
                    merged = MusicHapticsTimeRange(
                        lowerBound: min(existing.lowerBound, merged.lowerBound),
                        upperBound: max(existing.upperBound, merged.upperBound)
                    )
                }
            }
            result.append(merged)
            ranges = result.sorted { $0.lowerBound < $1.lowerBound }
        }

        private func durationSeconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }
    }
}
