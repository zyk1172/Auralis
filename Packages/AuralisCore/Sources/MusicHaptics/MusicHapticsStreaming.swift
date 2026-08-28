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
    private var pending: [(Data, TimeInterval, MusicHapticsPCMFormat, Int)] = []
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
    // 64 audio callbacks is a bounded queue of roughly several seconds for
    // normal AVAudio PCM buffers. It absorbs short utility-task scheduling
    // bursts without allowing an unbounded sidecar to affect playback.
    private let maximumPendingFrames = 64

    private actor Accumulator {
        var events: [MusicHapticsEvent] = []
        var ranges: [MusicHapticsTimeRange] = []
        var lastRMS: Float = 0
        var lastEventTime: TimeInterval = -.infinity
        var lastFrameTime: TimeInterval = -.infinity

        init(partial: MusicHapticsPartialCheckpoint?) {
            if let partial {
                events = partial.events
                ranges = partial.analyzedRanges
            }
        }

        func append(bytes: Data, time: TimeInterval, format: MusicHapticsPCMFormat, frameCount: Int) {
            guard format.isValid, frameCount > 0,
                  let rms = MusicHapticsPCMDecoder.rms(bytes: bytes, format: format, frameCount: frameCount)
            else { return }
            let frameDuration = Double(frameCount) / format.sampleRate
            // A seek or a real coverage hole starts a new local analysis run.
            // The checkpoint may contain an event later in the song; using
            // that global timestamp as the debounce anchor would suppress all
            // events in an earlier hole when playback resumes there.
            if lastFrameTime.isFinite,
               abs(time - lastFrameTime) > max(0.5, frameDuration * 2) {
                lastRMS = 0
                lastEventTime = -.infinity
            }
            let onset = max(0, rms - lastRMS)
            // A replayed range is still added to the union, but must not
            // duplicate events already present in a checkpoint. This lets a
            // resumed session safely start at 0 or overlap a buffered window.
            let timeWasAlreadyAnalyzed = ranges.contains {
                time >= $0.lowerBound && time + frameDuration <= $0.upperBound
            }
            if !timeWasAlreadyAnalyzed,
               time - lastEventTime >= 0.09, rms > 0.035, onset > 0.018 {
                events.append(MusicHapticsEvent(
                    time: time,
                    intensity: min(0.88, 0.28 + rms * 1.4 + onset * 2.2),
                    sharpness: min(0.80, 0.15 + onset * 6),
                    kind: .transient
                ))
                lastEventTime = time
            }
            lastRMS = lastRMS * 0.7 + rms * 0.3
            lastFrameTime = time
            insertRange(MusicHapticsTimeRange(
                lowerBound: time,
                upperBound: max(time, time + frameDuration)
            ))
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

        func checkpoint(identity: MusicHapticsIdentity, duration: TimeInterval) -> MusicHapticsPartialCheckpoint {
            var thinned: [MusicHapticsEvent] = []
            for event in events.sorted(by: { $0.time < $1.time }) {
                guard let previous = thinned.last, event.time - previous.time < 0.16 else {
                    thinned.append(event)
                    continue
                }
                if event.intensity > previous.intensity {
                    thinned[thinned.count - 1] = event
                }
            }
            return MusicHapticsPartialCheckpoint(
                identity: identity,
                duration: duration,
                analyzedRanges: ranges,
                events: thinned
            )
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
        onProgress: @escaping @Sendable (MusicHapticsAnalysisSnapshot) -> Void = { _ in }
    ) {
        self.identity = identity
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.onResult = onResult
        self.onProgress = onProgress
        let compatiblePartial = partial.flatMap {
            $0.identity.matchConfidence(with: identity) >= 0.82
                && $0.duration.isFinite
                && $0.duration > 0
                ? $0
                : nil
        }
        self.accumulator = Accumulator(partial: compatiblePartial)
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
                droppedFrames += max(0, dropped.3)
            }
            pending.append((bytes, time, format, frameCount))
            guard !draining else { return false }
            draining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in await self?.drain() }
        }
    }

    public func pause() {}
    public func seek(to position: TimeInterval) {}

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
            guard !draining, !pending.isEmpty else { return false }
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
            let frame: (Data, TimeInterval, MusicHapticsPCMFormat, Int)? = lock.withLock {
                guard !cancelled, !pending.isEmpty else {
                    pending.removeAll()
                    draining = false
                    return nil
                }
                return pending.removeFirst()
            }
            guard let frame else { return }
            await accumulator.append(bytes: frame.0, time: frame.1, format: frame.2, frameCount: frame.3)
        }
    }

    private func finishAfterDraining() async {
        while lock.withLock({ draining || !pending.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
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
        let snapshot = MusicHapticsAnalysisSnapshot(
            tapAttached: state.tapAttached,
            pcmFormat: state.pcmFormat,
            analyzedRanges: checkpoint.analyzedRanges,
            coverage: checkpoint.coverage,
            eventCount: checkpoint.events.count,
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
            let checkpoint = await self.accumulator.checkpoint(
                identity: self.identity,
                duration: self.duration
            )
            let state = self.lock.withLock {
                (
                    tapAttached: self.tapWasAttached,
                    pcmFormat: self.pcmFormat,
                    droppedFrames: self.droppedFrames
                )
            }
            self.onProgress(MusicHapticsAnalysisSnapshot(
                tapAttached: state.tapAttached,
                pcmFormat: state.pcmFormat,
                analyzedRanges: checkpoint.analyzedRanges,
                coverage: checkpoint.coverage,
                eventCount: checkpoint.events.count,
                droppedFrames: state.droppedFrames
            ))
        }
    }
}

private enum MusicHapticsPCMDecoder {
    static func rms(bytes: Data, format: MusicHapticsPCMFormat, frameCount: Int) -> Float? {
        let channels = format.channels
        let sampleCount = frameCount.multipliedReportingOverflow(by: channels)
        guard !sampleCount.overflow, sampleCount.partialValue > 0 else { return nil }
        let expectedBytes: Int
        if format.interleaved {
            let result = frameCount.multipliedReportingOverflow(by: format.bytesPerFrame)
            guard !result.overflow else { return nil }
            expectedBytes = result.partialValue
        } else {
            let result = sampleCount.partialValue.multipliedReportingOverflow(by: format.bytesPerSample)
            guard !result.overflow else { return nil }
            expectedBytes = result.partialValue
        }
        guard bytes.count >= expectedBytes else { return nil }

        return bytes.withUnsafeBytes { raw in
            var sum = 0.0
            var validSamples = 0
            for sampleIndex in 0..<sampleCount.partialValue {
                let frame = sampleIndex / channels
                let channel = sampleIndex % channels
                let offset: Int
                if format.interleaved {
                    offset = frame * format.bytesPerFrame + channel * format.bytesPerSample
                } else {
                    offset = channel * frameCount * format.bytesPerSample + frame * format.bytesPerSample
                }
                guard let value = decode(raw, offset: offset, format: format) else { continue }
                let normalized = Double(value)
                sum += normalized * normalized
                validSamples += 1
            }
            guard validSamples > 0 else { return nil }
            return Float(sqrt(sum / Double(validSamples)))
        }
    }

    private static func decode(_ raw: UnsafeRawBufferPointer, offset: Int, format: MusicHapticsPCMFormat) -> Float? {
        guard offset >= 0, offset + format.bytesPerSample <= raw.count else { return nil }
        switch format.sampleType {
        case .float32:
            let bits: UInt32
            if format.isBigEndian {
                bits = UInt32(raw[offset]) << 24
                    | UInt32(raw[offset + 1]) << 16
                    | UInt32(raw[offset + 2]) << 8
                    | UInt32(raw[offset + 3])
            } else {
                bits = UInt32(raw[offset])
                    | UInt32(raw[offset + 1]) << 8
                    | UInt32(raw[offset + 2]) << 16
                    | UInt32(raw[offset + 3]) << 24
            }
            let value = Float32(bitPattern: bits)
            guard value.isFinite else { return nil }
            return min(max(value, -1), 1)
        case .int16:
            let bits: UInt16
            if format.isBigEndian {
                bits = UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])
            } else {
                bits = UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
            }
            return Float32(Int16(bitPattern: bits)) / 32_768
        }
    }
}
