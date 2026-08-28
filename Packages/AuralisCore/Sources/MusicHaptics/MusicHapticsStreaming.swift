import Foundation

/// PCM hand-off point used by the playback engine. Implementations must be
/// real-time safe: `consumePCM` is called from AVFoundation's audio processing
/// thread and may only make a bounded copy/enqueue operation.
public protocol MusicHapticsAnalysisSink: AnyObject, Sendable {
    /// Called after the PlaybackEngine successfully installs the audio mix.
    /// `begin(format:)` is invoked later when AVFoundation prepares the tap.
    func tapAttached()
    func begin(format: MusicHapticsPCMFormat)
    func consumePCM(_ bytes: Data, time: TimeInterval, format: MusicHapticsPCMFormat, frameCount: Int)
    func pause()
    func seek(to position: TimeInterval)
    func finish()
    func finishPartial(reason: MusicHapticsAnalysisFinishReason)
    func cancel()
}

/// A bounded PCM sidecar for a single playback. It intentionally owns neither
/// the player nor the network connection; it receives decoded frames already
/// fetched by AVPlayer and analyzes them on a utility task.
public final class StreamingMusicHapticsAnalyzer: MusicHapticsAnalysisSink, @unchecked Sendable {
    private let lock = NSLock()
    private struct PendingFrame {
        let bytes: Data
        let time: TimeInterval
        let format: MusicHapticsPCMFormat
        let frameCount: Int
    }

    private enum PendingOperation {
        case seek(TimeInterval)
        case frame(PendingFrame)
    }

    private var pending: [PendingFrame] = []
    /// A seek is a control barrier. It is kept ahead of all PCM enqueued after
    /// the seek, even if the utility drain is still finishing one old frame.
    private var pendingSeek: TimeInterval?
    private var draining = false
    private var cancelled = false
    private var finished = false
    private var tapWasAttached = false
    private var pcmFormat: MusicHapticsPCMFormat?
    private var droppedFrames = 0
    private var finishReason: MusicHapticsAnalysisFinishReason?
    private let identity: MusicHapticsIdentity
    private let duration: TimeInterval
    private let onResult: @Sendable (MusicHapticsAnalysisResult) -> Void
    private let onProgress: @Sendable (MusicHapticsAnalysisSnapshot) -> Void
    private let onWindow: @Sendable (MusicHapticsAnalysisWindow) -> Void
    // 64 audio callbacks is a bounded queue of roughly several seconds for
    // normal AVAudio PCM buffers. It absorbs short utility-task scheduling
    // bursts without allowing an unbounded sidecar to affect playback.
    private let maximumPendingFrames = 64

    private actor Accumulator {
        let identity: MusicHapticsIdentity
        var events: [MusicHapticsEvent] = []
        var newlyAnalyzedEvents: [MusicHapticsEvent] = []
        var ranges: [MusicHapticsTimeRange] = []
        var lastFrameTime: TimeInterval = -.infinity
        var analysisPosition: TimeInterval = 0
        var lastWindowEnd: TimeInterval = 0
        var processor = MusicHapticsDSPProcessor()
        var mixer = MusicHapticsPerceptualMixer()
        let duration: TimeInterval

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
            events = compatiblePartial?.events ?? []
            ranges = compatiblePartial?.analyzedRanges ?? []
            analysisPosition = compatiblePartial?.firstUnanalyzedPosition ?? 0
            lastWindowEnd = analysisPosition
        }

        func append(
            bytes: Data,
            time: TimeInterval,
            format: MusicHapticsPCMFormat,
            frameCount: Int
        ) -> MusicHapticsAnalysisWindow? {
            guard format.isValid, frameCount > 0,
                  let mono = MusicHapticsPCMDecoder.decodeMono(
                      bytes: bytes,
                      format: format,
                      frameCount: frameCount
                  )
            else { return nil }
            let frameDuration = Double(frameCount) / format.sampleRate
            // A seek or a real coverage hole starts a new local analysis run.
            // The checkpoint may contain an event later in the song; using
            // that global timestamp as the debounce anchor would suppress all
            // events in an earlier hole when playback resumes there.
            if lastFrameTime.isFinite,
               abs(time - lastFrameTime) > max(0.5, frameDuration * 2) {
                processor = MusicHapticsDSPProcessor()
                mixer.reset()
            }
            // A replayed range is still added to the union, but must not
            // duplicate events already present in a checkpoint. This lets a
            // resumed session safely start at 0 or overlap a buffered window.
            let timeWasAlreadyAnalyzed = ranges.contains {
                time >= $0.lowerBound && time + frameDuration <= $0.upperBound
            }
            if timeWasAlreadyAnalyzed {
                // A resumed sidecar may replay bytes that are already in the
                // checkpoint. Do not let their state bridge into the first
                // newly analyzed hole.
                processor = MusicHapticsDSPProcessor()
                mixer.reset()
            } else {
                let candidates = processor.processCandidates(
                    monoSamples: mono,
                    startTime: time,
                    sampleRate: format.sampleRate
                )
                let produced = mixer.mix(frames: candidates).events
                events.append(contentsOf: produced)
                newlyAnalyzedEvents.append(contentsOf: produced)
            }
            lastFrameTime = time
            analysisPosition = max(analysisPosition, time + frameDuration)
            insertRange(MusicHapticsTimeRange(
                lowerBound: time,
                upperBound: max(time, time + frameDuration)
            ))
            guard !timeWasAlreadyAnalyzed,
                  analysisPosition >= lastWindowEnd + 2 else { return nil }
            let windowEnd = min(duration, analysisPosition)
            let pendingBeforeEnd = newlyAnalyzedEvents.filter { $0.time < windowEnd }
            let windowStart = min(
                lastWindowEnd,
                pendingBeforeEnd.map(\.time).min() ?? lastWindowEnd
            )
            let windowEvents = pendingBeforeEnd.filter { event in
                if event.kind == .transient {
                    return event.time >= windowStart
                }
                return event.time + (event.duration ?? 0) > windowStart
            }
            newlyAnalyzedEvents.removeAll { windowEvents.contains($0) }
            let window = MusicHapticsAnalysisWindow(
                startTime: windowStart,
                endTime: windowEnd,
                analysisPosition: analysisPosition,
                events: windowEvents,
                coverage: coverage,
                analysisSpeedX: 1,
                tempoBPM: processor.diagnostics.tempoBPM,
                beatConfidence: processor.diagnostics.beatConfidence,
                sourceMode: .realtimeTap,
                analysisStreamBitrate: nil,
                eventCount: events.count,
                transientCount: events.filter { $0.kind == .transient }.count,
                continuousCount: events.filter { $0.kind == .continuous }.count,
                mixerDiagnostics: mixer.diagnostics
            )
            lastWindowEnd = windowEnd
            return window.events.isEmpty ? nil : window
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
            ranges = result.sorted(by: { $0.lowerBound < $1.lowerBound })
        }

        func flush() {
            let produced = mixer.mix(frames: processor.finishCandidates()).events
                + mixer.finish().events
            events.append(contentsOf: produced)
            newlyAnalyzedEvents.append(contentsOf: produced)
        }

        func seek(to position: TimeInterval) {
            processor = MusicHapticsDSPProcessor()
            mixer.reset()
            newlyAnalyzedEvents.removeAll(keepingCapacity: true)
            lastFrameTime = -.infinity
            analysisPosition = min(duration, max(0, position))
            lastWindowEnd = analysisPosition
        }

        func checkpoint(identity: MusicHapticsIdentity, duration: TimeInterval) -> MusicHapticsPartialCheckpoint {
            return MusicHapticsPartialCheckpoint(
                identity: identity,
                duration: duration,
                analyzedRanges: ranges,
                events: MusicHapticsEventDeduplicator.merge(events),
                tempoBPM: processor.diagnostics.tempoBPM,
                beatConfidence: processor.diagnostics.beatConfidence,
                beatPhase: processor.diagnostics.beatPhase
            )
        }

        func snapshot(
            tapAttached: Bool,
            pcmFormat: MusicHapticsPCMFormat?,
            droppedFrames: Int,
            finishReason: MusicHapticsAnalysisFinishReason? = nil
        ) -> MusicHapticsAnalysisSnapshot {
            let checkpoint = checkpoint(identity: identity, duration: duration)
            let diagnostics = processor.diagnostics
            return MusicHapticsAnalysisSnapshot(
                tapAttached: tapAttached,
                pcmFormat: pcmFormat,
                analyzedRanges: checkpoint.analyzedRanges,
                coverage: checkpoint.coverage,
                eventCount: checkpoint.events.count,
                droppedFrames: droppedFrames,
                finishReason: finishReason,
                analysisMode: .realtimeTap,
                analysisPosition: max(analysisPosition, diagnostics.analysisPosition),
                analysisSpeedX: 1,
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                transientCount: checkpoint.events.filter { $0.kind == .transient }.count,
                continuousCount: checkpoint.events.filter { $0.kind == .continuous }.count,
                mixerDiagnostics: mixer.diagnostics
            )
        }

        var coverage: Double {
            guard duration > 0 else { return 0 }
            return min(1, ranges.reduce(0) { $0 + $1.duration } / duration)
        }
    }

    private let accumulator: Accumulator

    /// Compatibility initializer for callers that only need a completed
    /// timeline. New playback code uses the result initializer below so
    /// incomplete coverage is persisted instead of silently discarded.
    public convenience init(
        identity: MusicHapticsIdentity,
        duration: TimeInterval,
        completion: @escaping @Sendable (MusicHapticsTimeline) -> Void
    ) {
        self.init(identity: identity, duration: duration, onResult: { result in
            if let timeline = result.timeline {
                completion(timeline)
            }
        })
    }

    public init(
        identity: MusicHapticsIdentity,
        duration: TimeInterval,
        partial: MusicHapticsPartialCheckpoint? = nil,
        onResult: @escaping @Sendable (MusicHapticsAnalysisResult) -> Void,
        onProgress: @escaping @Sendable (MusicHapticsAnalysisSnapshot) -> Void = { _ in },
        onWindow: @escaping @Sendable (MusicHapticsAnalysisWindow) -> Void = { _ in }
    ) {
        self.identity = identity
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        self.duration = safeDuration
        self.onResult = onResult
        self.onProgress = onProgress
        self.onWindow = onWindow
        let compatiblePartial = partial.flatMap {
            $0.identity.matchConfidence(with: identity) >= 0.82
                && $0.duration.isFinite
                && $0.duration > 0
                && abs($0.duration - safeDuration) <= max(2, safeDuration * 0.01)
                ? $0
                : nil
        }
        self.accumulator = Accumulator(identity: identity, duration: safeDuration, partial: compatiblePartial)
    }

    public func tapAttached() {
        lock.withLock { tapWasAttached = true }
        publishProgress()
    }

    public func begin(format: MusicHapticsPCMFormat) {
        lock.withLock { pcmFormat = format }
        publishProgress()
    }

    public func consumePCM(_ bytes: Data, time: TimeInterval, format: MusicHapticsPCMFormat, frameCount: Int) {
        guard !bytes.isEmpty, time.isFinite, time >= 0, format.isValid, frameCount > 0 else { return }
        let shouldStartDrain = lock.withLock { () -> Bool in
            guard !cancelled, !finished else { return false }
            if pending.count >= maximumPendingFrames, let dropped = pending.first {
                pending.removeFirst()
                droppedFrames += max(0, dropped.frameCount)
            }
            pending.append(PendingFrame(bytes: bytes, time: time, format: format, frameCount: frameCount))
            guard !draining else { return false }
            draining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in await self?.drain() }
        }
    }

    public func pause() {}

    public func seek(to position: TimeInterval) {
        let safePosition = max(0, position.isFinite ? position : 0)
        let shouldStartDrain = lock.withLock { () -> Bool in
            guard !cancelled, !finished else { return false }
            // PCM already queued before a seek belongs to the old playback
            // segment. Drop it before the next tap callback can enqueue more.
            pending.removeAll()
            pendingSeek = safePosition
            guard !draining else { return false }
            draining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in await self?.drain() }
        }
    }

    public func finish() {
        finish(reason: .naturalEnd)
    }

    public func finishPartial(reason: MusicHapticsAnalysisFinishReason) {
        finish(reason: reason)
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            pending.removeAll()
            draining = false
        }
    }

    private func finish(reason: MusicHapticsAnalysisFinishReason) {
        let shouldStartDrain = lock.withLock { () -> Bool in
            guard !cancelled, !finished else { return false }
            finished = true
            finishReason = reason
            guard !draining, pendingSeek != nil || !pending.isEmpty else { return false }
            draining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in await self?.drain() }
        }
        Task.detached(priority: .utility) { [weak self] in await self?.finishAfterDraining() }
    }

    private func drain() async {
        while true {
            let operation: PendingOperation? = lock.withLock {
                guard !cancelled else {
                    pending.removeAll()
                    pendingSeek = nil
                    draining = false
                    return nil
                }
                if let pendingSeek {
                    self.pendingSeek = nil
                    return .seek(pendingSeek)
                }
                guard !pending.isEmpty else {
                    draining = false
                    return nil
                }
                return .frame(pending.removeFirst())
            }
            guard let operation else { return }
            switch operation {
            case let .seek(position):
                await accumulator.seek(to: position)
            case let .frame(frame):
                if let window = await accumulator.append(
                    bytes: frame.bytes,
                    time: frame.time,
                    format: frame.format,
                    frameCount: frame.frameCount
                ) {
                    onWindow(window)
                }
            }
        }
    }

    private func finishAfterDraining() async {
        while lock.withLock({ draining || !pending.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await accumulator.flush()
        let checkpoint = await accumulator.checkpoint(identity: identity, duration: duration)
        let state = lock.withLock {
            (
                cancelled: cancelled,
                tapAttached: tapWasAttached,
                pcmFormat: pcmFormat,
                droppedFrames: droppedFrames,
                reason: finishReason
            )
        }
        guard !state.cancelled, let reason = state.reason else { return }
        let snapshot = await accumulator.snapshot(
            tapAttached: state.tapAttached,
            pcmFormat: state.pcmFormat,
            droppedFrames: state.droppedFrames,
            finishReason: reason
        )
        onResult(MusicHapticsAnalysisResult(
            checkpoint: checkpoint,
            timeline: checkpoint.isComplete ? checkpoint.timeline() : nil,
            snapshot: snapshot,
            finishReason: reason
        ))
    }

    private func publishProgress() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let state = self.lock.withLock {
                (
                    tapAttached: self.tapWasAttached,
                    pcmFormat: self.pcmFormat,
                    droppedFrames: self.droppedFrames
                )
            }
            self.onProgress(await self.accumulator.snapshot(
                tapAttached: state.tapAttached,
                pcmFormat: state.pcmFormat,
                droppedFrames: state.droppedFrames
            ))
        }
    }
}
