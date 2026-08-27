import Foundation

/// PCM hand-off point used by the playback engine.  Implementations must be
/// real-time safe: `consumePCM` is called from AVFoundation's audio processing
/// thread and may only make a bounded copy/enqueue operation.
public protocol MusicHapticsAnalysisSink: AnyObject, Sendable {
    func begin(sampleRate: Double, channels: Int)
    func consumePCM(_ bytes: Data, time: TimeInterval, sampleRate: Double, channels: Int)
    func pause()
    func seek(to position: TimeInterval)
    func finish()
    func cancel()
}

/// A bounded PCM sidecar for a single playback.  It intentionally owns neither
/// the player nor the network connection; it receives decoded frames already
/// fetched by AVPlayer and analyzes them on a utility task.
public final class StreamingMusicHapticsAnalyzer: MusicHapticsAnalysisSink, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(Data, TimeInterval, Double, Int)] = []
    private var draining = false
    private var cancelled = false
    private var finished = false
    private let identity: MusicHapticsIdentity
    private let duration: TimeInterval
    private let completion: @Sendable (MusicHapticsTimeline) -> Void
    private let maximumPendingFrames = 24

    private actor Accumulator {
        var events: [MusicHapticsEvent] = []
        var ranges: [Range<TimeInterval>] = []
        var lastRMS: Float = 0
        var lastEventTime: TimeInterval = -.infinity

        func append(bytes: Data, time: TimeInterval, sampleRate: Double, channels: Int) {
            guard sampleRate > 0, bytes.count >= 2 else { return }
            let values = bytes.withUnsafeBytes { raw -> UnsafeBufferPointer<Int16> in
                UnsafeBufferPointer(start: raw.bindMemory(to: Int16.self).baseAddress, count: bytes.count / MemoryLayout<Int16>.size)
            }
            guard !values.isEmpty else { return }
            var sum = 0.0
            for value in values {
                let normalized = Double(value) / Double(Int16.max)
                sum += normalized * normalized
            }
            let rms = Float(sqrt(sum / Double(values.count)))
            let onset = max(0, rms - lastRMS)
            if time - lastEventTime >= 0.09, rms > 0.035, onset > 0.018 {
                events.append(MusicHapticsEvent(
                    time: time,
                    intensity: min(0.88, 0.28 + rms * 1.4 + onset * 2.2),
                    sharpness: min(0.80, 0.15 + onset * 6),
                    kind: .transient
                ))
                lastEventTime = time
            }
            lastRMS = lastRMS * 0.7 + rms * 0.3
            let frameDuration = Double(values.count) / (sampleRate * Double(max(1, channels)))
            insertRange(time..<max(time, time + frameDuration))
        }

        private func insertRange(_ range: Range<TimeInterval>) {
            guard !range.isEmpty else { return }
            var merged = range
            var result: [Range<TimeInterval>] = []
            for existing in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if existing.upperBound < merged.lowerBound || merged.upperBound < existing.lowerBound {
                    result.append(existing)
                } else {
                    merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
                }
            }
            result.append(merged)
            ranges = result.sorted(by: { $0.lowerBound < $1.lowerBound })
        }

        func timeline(identity: MusicHapticsIdentity, duration: TimeInterval) -> MusicHapticsTimeline {
            let covered = ranges.reduce(0) { $0 + max(0, $1.upperBound - $1.lowerBound) }
            let coverage = duration > 0 ? min(1, covered / duration) : 0
            var thinned: [MusicHapticsEvent] = []
            for event in events.sorted(by: { $0.time < $1.time }) {
                guard let previous = thinned.last, event.time - previous.time < 0.16 else { thinned.append(event); continue }
                if event.intensity > previous.intensity { thinned[thinned.count - 1] = event }
            }
            return MusicHapticsTimeline(identity: identity, duration: duration, analyzedDuration: covered, analysisCoverage: coverage, events: thinned)
        }
    }

    private let accumulator = Accumulator()

    public init(identity: MusicHapticsIdentity, duration: TimeInterval, completion: @escaping @Sendable (MusicHapticsTimeline) -> Void) {
        self.identity = identity
        self.duration = duration
        self.completion = completion
    }

    public func begin(sampleRate: Double, channels: Int) {}

    public func consumePCM(_ bytes: Data, time: TimeInterval, sampleRate: Double, channels: Int) {
        guard !bytes.isEmpty, time.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !finished else { return }
        if pending.count == maximumPendingFrames { pending.removeFirst() }
        pending.append((bytes, time, sampleRate, max(1, channels)))
        guard !draining else { return }
        draining = true
        Task.detached(priority: .utility) { [weak self] in await self?.drain() }
    }

    public func pause() {}
    public func seek(to position: TimeInterval) {}

    public func finish() {
        lock.lock()
        guard !cancelled, !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in await self?.finishAfterDraining() }
    }

    public func cancel() {
        lock.lock(); cancelled = true; pending.removeAll(); lock.unlock()
    }

    private func drain() async {
        while true {
            let (frame, shouldStop): ((Data, TimeInterval, Double, Int)?, Bool) = lock.withLock {
                let frame = pending.isEmpty ? nil : pending.removeFirst()
                if frame == nil { draining = false }
                return (frame, cancelled)
            }
            guard !shouldStop, let frame else { return }
            await accumulator.append(bytes: frame.0, time: frame.1, sampleRate: frame.2, channels: frame.3)
        }
    }

    private func finishAfterDraining() async {
        while lock.withLock({ draining }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let timeline = await accumulator.timeline(identity: identity, duration: duration)
        guard timeline.isComplete else { return }
        completion(timeline)
    }
}
