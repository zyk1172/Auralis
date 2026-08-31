import Foundation
import Dispatch
import Synchronization

/// PCM hand-off point used by the playback engine. Implementations must be
/// real-time safe: `consumePCM` is called from AVFoundation's audio processing
/// thread and may only make a bounded copy/enqueue operation.
public protocol MusicHapticsAnalysisSink: AnyObject, Sendable {
    /// Called after the PlaybackEngine successfully installs the audio mix.
    /// `begin(format:)` is invoked later when AVFoundation prepares the tap.
    func tapAttached()
    /// True only after the PlaybackEngine has successfully installed the tap.
    /// A remote lookahead failure may use this value to decide whether the
    /// pre-play realtime fallback is actually available.
    var tapIsAttached: Bool { get }
    func begin(format: MusicHapticsPCMFormat)
    func consumePCM(_ bytes: Data, time: TimeInterval, format: MusicHapticsPCMFormat, frameCount: Int)
    /// Reserves a preallocated PCM slot for the audio render callback. The
    /// callback must only copy into the returned buffer and then commit it.
    /// Returning nil drops the disposable haptics frame without affecting
    /// authoritative audio playback.
    func beginPCMFrame(
        time: TimeInterval,
        format: MusicHapticsPCMFormat,
        frameCount: Int
    ) -> UnsafeMutableRawBufferPointer?
    func commitPCMFrame()
    func abortPCMFrame()
    func pause()
    func resume()
    func seek(to position: TimeInterval)
    func finish()
    func finishPartial(reason: MusicHapticsAnalysisFinishReason)
    func cancel()
}

public extension MusicHapticsAnalysisSink {
    var tapIsAttached: Bool { false }

    func beginPCMFrame(
        time: TimeInterval,
        format: MusicHapticsPCMFormat,
        frameCount: Int
    ) -> UnsafeMutableRawBufferPointer? { nil }

    func commitPCMFrame() {}
    func abortPCMFrame() {}
}

/// Optional checkpoint access for analyzers that can preserve work without
/// terminating the current analysis session.
public protocol MusicHapticsPartialCheckpointProvider: AnyObject, Sendable {
    func partialCheckpoint() async -> MusicHapticsPartialCheckpoint
}

/// A bounded single-producer/single-consumer PCM ring. The producer is the
/// AVFoundation audio callback; the consumer is the utility analysis task.
/// All storage and metadata are allocated before playback starts. Publishing a
/// slot uses release/acquire atomics, so the callback never allocates, locks or
/// creates a task.
private final class MusicHapticsPCMFrameRing: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let bytes: Data
        let time: TimeInterval
        let format: MusicHapticsPCMFormat
        let frameCount: Int
        let generation: UInt64
    }

    private final class Slot: @unchecked Sendable {
        let storage: UnsafeMutableRawPointer
        var byteCount = 0
        var time: TimeInterval = 0
        var format: MusicHapticsPCMFormat?
        var frameCount = 0
        var generation: UInt64 = 0

        init(byteCapacity: Int) {
            storage = .allocate(
                byteCount: byteCapacity,
                alignment: MemoryLayout<UInt64>.alignment
            )
        }

        deinit { storage.deallocate() }
    }

    private let slots: [Slot]
    private let slotCount: UInt64
    private let slotByteCapacity: Int
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let producerInFlight = Atomic<UInt8>(0)
    /// Pre-created wakeup used by the utility consumer. The render callback
    /// only signals after publishing a slot; it never creates a task or
    /// allocates storage.
    private let dataAvailable = DispatchSemaphore(value: 0)
    /// Only the single audio producer touches this value.
    private var reservedIndex: UInt64?

    init(slotCount: Int = 16, slotByteCapacity: Int = 256 * 1024) {
        let safeSlotCount = max(2, slotCount)
        let safeByteCapacity = max(1, slotByteCapacity)
        self.slots = (0..<safeSlotCount).map { _ in Slot(byteCapacity: safeByteCapacity) }
        self.slotCount = UInt64(safeSlotCount)
        self.slotByteCapacity = safeByteCapacity
    }

    func begin(
        time: TimeInterval,
        format: MusicHapticsPCMFormat,
        frameCount: Int,
        generation: UInt64
    ) -> UnsafeMutableRawBufferPointer? {
        guard reservedIndex == nil,
              time.isFinite,
              time >= 0,
              format.isValid,
              frameCount > 0,
              let byteCount = Self.byteCount(format: format, frameCount: frameCount),
              byteCount <= slotByteCapacity
        else { return nil }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard write &- read < slotCount else { return nil }

        producerInFlight.store(1, ordering: .releasing)
        let slot = slots[Int(write % slotCount)]
        slot.byteCount = byteCount
        slot.time = time
        slot.format = format
        slot.frameCount = frameCount
        slot.generation = generation
        reservedIndex = write
        return UnsafeMutableRawBufferPointer(start: slot.storage, count: byteCount)
    }

    func commit() {
        guard let reservedIndex else { return }
        writeIndex.store(reservedIndex &+ 1, ordering: .releasing)
        self.reservedIndex = nil
        producerInFlight.store(0, ordering: .releasing)
        dataAvailable.signal()
    }

    func abort() {
        guard reservedIndex != nil else { return }
        reservedIndex = nil
        producerInFlight.store(0, ordering: .releasing)
    }

    func wakeConsumer() {
        dataAvailable.signal()
    }

    func waitForData(timeout: DispatchTimeInterval) {
        _ = dataAvailable.wait(timeout: .now() + timeout)
    }

    func dequeue() -> Frame? {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        guard read < write else { return nil }
        let slot = slots[Int(read % slotCount)]
        guard let format = slot.format, slot.byteCount > 0, slot.frameCount > 0 else {
            readIndex.store(read &+ 1, ordering: .releasing)
            return nil
        }
        let frame = Frame(
            bytes: Data(bytes: slot.storage, count: slot.byteCount),
            time: slot.time,
            format: format,
            frameCount: slot.frameCount,
            generation: slot.generation
        )
        readIndex.store(read &+ 1, ordering: .releasing)
        return frame
    }

    var isEmpty: Bool {
        readIndex.load(ordering: .relaxed) >= writeIndex.load(ordering: .acquiring)
    }

    var isProducerIdle: Bool {
        producerInFlight.load(ordering: .acquiring) == 0
    }

    private static func byteCount(format: MusicHapticsPCMFormat, frameCount: Int) -> Int? {
        guard frameCount > 0, format.isValid else { return nil }
        if format.interleaved {
            let result = frameCount.multipliedReportingOverflow(by: format.bytesPerFrame)
            return result.overflow ? nil : result.partialValue
        }
        let sampleCount = frameCount.multipliedReportingOverflow(by: format.channels)
        guard !sampleCount.overflow else { return nil }
        let result = sampleCount.partialValue.multipliedReportingOverflow(by: format.bytesPerSample)
        return result.overflow ? nil : result.partialValue
    }
}

/// A bounded PCM sidecar for a single playback. It intentionally owns neither
/// the player nor the network connection; it receives decoded frames already
/// fetched by AVPlayer and analyzes them on a utility task.
public final class StreamingMusicHapticsAnalyzer: MusicHapticsAnalysisSink, MusicHapticsPartialCheckpointProvider, @unchecked Sendable {
    private enum Lifecycle {
        static let active: UInt8 = 1
        static let paused: UInt8 = 2
        static let finishing: UInt8 = 3
        static let cancelled: UInt8 = 4
    }

    private let pcmRing = MusicHapticsPCMFrameRing()
    private let lifecycle = Atomic<UInt8>(Lifecycle.active)
    private let generation = Atomic<UInt64>(0)
    private let droppedFrameCount = Atomic<UInt64>(0)
    /// Control/progress state only. The audio callback uses the ring and
    /// atomics exclusively and never takes this lock.
    private let stateLock = NSLock()
    private var pendingSeek: TimeInterval?
    private var drainTask: Task<Void, Never>?
    private var tapWasAttached = false
    private var pcmFormat: MusicHapticsPCMFormat?
    private let identity: MusicHapticsIdentity
    private let duration: TimeInterval
    private let onResult: @Sendable (MusicHapticsAnalysisResult) -> Void
    private let onProgress: @Sendable (MusicHapticsAnalysisSnapshot) -> Void
    private let onWindow: @Sendable (MusicHapticsAnalysisWindow) -> Void
    private var finishReason: MusicHapticsAnalysisFinishReason?
    private var finishDelivered = false

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
        private let progressiveWindowAdvance: TimeInterval = 0.25
        var eventCount = 0
        var transientCount = 0
        var continuousCount = 0

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
            eventCount = events.count
            transientCount = events.filter { $0.kind == .transient }.count
            continuousCount = events.filter { $0.kind == .continuous }.count
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
                eventCount += produced.count
                transientCount += produced.filter { $0.kind == .transient }.count
                continuousCount += produced.filter { $0.kind == .continuous }.count
            }
            lastFrameTime = time
            analysisPosition = max(analysisPosition, time + frameDuration)
            insertRange(MusicHapticsTimeRange(
                lowerBound: time,
                upperBound: max(time, time + frameDuration)
            ))
            // Realtime tap output cannot wait for a two-second analysis
            // batch: by then a just-closed texture has already passed the
            // player. Progressive mixer segments are therefore published at
            // the same bounded cadence as their materialization.
            guard !timeWasAlreadyAnalyzed,
                  analysisPosition >= lastWindowEnd + progressiveWindowAdvance
            else { return nil }
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
                eventCount: eventCount,
                transientCount: transientCount,
                continuousCount: continuousCount,
                mixerDiagnostics: mixer.diagnostics
            )
            lastWindowEnd = windowEnd
            return window.events.isEmpty ? nil : window
        }

        private func insertRange(_ range: MusicHapticsTimeRange) {
            guard range.duration > 0 else { return }
            var merged = range
            let tolerance = MusicHapticsTimeRange.adjacencyTolerance
            var firstOverlappingIndex = 0
            while firstOverlappingIndex < ranges.count,
                  ranges[firstOverlappingIndex].upperBound + tolerance < merged.lowerBound {
                firstOverlappingIndex += 1
            }
            var endIndex = firstOverlappingIndex
            while endIndex < ranges.count,
                  ranges[endIndex].lowerBound <= merged.upperBound + tolerance {
                let existing = ranges[endIndex]
                merged = MusicHapticsTimeRange(
                    lowerBound: min(existing.lowerBound, merged.lowerBound),
                    upperBound: max(existing.upperBound, merged.upperBound)
                )
                endIndex += 1
            }
            ranges.replaceSubrange(
                firstOverlappingIndex..<endIndex,
                with: CollectionOfOne(merged)
            )
        }

        func flush() {
            let produced = mixer.mix(frames: processor.finishCandidates()).events
                + mixer.finish().events
            events.append(contentsOf: produced)
            newlyAnalyzedEvents.append(contentsOf: produced)
            eventCount += produced.count
            transientCount += produced.filter { $0.kind == .transient }.count
            continuousCount += produced.filter { $0.kind == .continuous }.count
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
            let diagnostics = processor.diagnostics
            return MusicHapticsAnalysisSnapshot(
                tapAttached: tapAttached,
                pcmFormat: pcmFormat,
                analyzedRanges: ranges,
                coverage: coverage,
                eventCount: eventCount,
                droppedFrames: droppedFrames,
                finishReason: finishReason,
                analysisMode: .realtimeTap,
                analysisPosition: max(analysisPosition, diagnostics.analysisPosition),
                analysisSpeedX: 1,
                tempoBPM: diagnostics.tempoBPM,
                beatConfidence: diagnostics.beatConfidence,
                transientCount: transientCount,
                continuousCount: continuousCount,
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
        stateLock.withLock { tapWasAttached = true }
        publishProgress()
    }

    public var tapIsAttached: Bool {
        stateLock.withLock { tapWasAttached }
    }

    public func begin(format: MusicHapticsPCMFormat) {
        stateLock.withLock {
            guard lifecycle.load(ordering: .acquiring) != Lifecycle.cancelled else { return }
            pcmFormat = format
        }
        ensureDrainTask()
        publishProgress()
    }

    /// Compatibility entry point for non-render callers and existing tests.
    /// The realtime tap uses beginPCMFrame/commitPCMFrame below so it never
    /// constructs Data on the audio thread.
    public func consumePCM(_ bytes: Data, time: TimeInterval, format: MusicHapticsPCMFormat, frameCount: Int) {
        guard !bytes.isEmpty, time.isFinite, time >= 0, format.isValid, frameCount > 0 else { return }
        guard let destination = beginPCMFrame(time: time, format: format, frameCount: frameCount),
              destination.count == bytes.count
        else {
            abortPCMFrame()
            return
        }
        bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
            destinationBase.copyMemory(from: sourceBase, byteCount: source.count)
        }
        commitPCMFrame()
        ensureDrainTask()
    }

    public func beginPCMFrame(
        time: TimeInterval,
        format: MusicHapticsPCMFormat,
        frameCount: Int
    ) -> UnsafeMutableRawBufferPointer? {
        guard lifecycle.load(ordering: .acquiring) == Lifecycle.active else { return nil }
        let currentGeneration = generation.load(ordering: .acquiring)
        guard let destination = pcmRing.begin(
            time: time,
            format: format,
            frameCount: frameCount,
            generation: currentGeneration
        ) else {
            droppedFrameCount.wrappingAdd(UInt64(max(0, frameCount)), ordering: .relaxed)
            return nil
        }
        // A control transition may have happened between the first lifecycle
        // check and the reservation. Abort such a slot before it is published.
        guard lifecycle.load(ordering: .acquiring) == Lifecycle.active else {
            pcmRing.abort()
            return nil
        }
        return destination
    }

    public func commitPCMFrame() {
        pcmRing.commit()
    }

    public func abortPCMFrame() {
        pcmRing.abort()
    }

    public func pause() {
        stateLock.withLock {
            let state = lifecycle.load(ordering: .acquiring)
            guard state != Lifecycle.cancelled, state != Lifecycle.finishing else { return }
            lifecycle.store(Lifecycle.paused, ordering: .releasing)
            generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
            pendingSeek = nil
        }
        pcmRing.wakeConsumer()
    }

    public func resume() {
        let shouldResume = stateLock.withLock { () -> Bool in
            let state = lifecycle.load(ordering: .acquiring)
            guard state != Lifecycle.cancelled, state != Lifecycle.finishing else { return false }
            lifecycle.store(Lifecycle.active, ordering: .releasing)
            return true
        }
        if shouldResume {
            ensureDrainTask()
            pcmRing.wakeConsumer()
        }
    }

    public func seek(to position: TimeInterval) {
        let safePosition = max(0, position.isFinite ? position : 0)
        let shouldStartDrain = stateLock.withLock { () -> Bool in
            let state = lifecycle.load(ordering: .acquiring)
            guard state != Lifecycle.cancelled, state != Lifecycle.finishing else { return false }
            pendingSeek = safePosition
            generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
            return true
        }
        if shouldStartDrain {
            ensureDrainTask()
            pcmRing.wakeConsumer()
        }
    }

    public func finish() {
        finish(reason: .naturalEnd)
    }

    public func finishPartial(reason: MusicHapticsAnalysisFinishReason) {
        finish(reason: reason)
    }

    public func cancel() {
        stateLock.withLock {
            lifecycle.store(Lifecycle.cancelled, ordering: .releasing)
            pendingSeek = nil
            drainTask?.cancel()
            drainTask = nil
        }
        pcmRing.wakeConsumer()
    }

    public func partialCheckpoint() async -> MusicHapticsPartialCheckpoint {
        await accumulator.checkpoint(identity: identity, duration: duration)
    }

    private func finish(reason: MusicHapticsAnalysisFinishReason) {
        let shouldStartDrain = stateLock.withLock { () -> Bool in
            let state = lifecycle.load(ordering: .acquiring)
            guard state != Lifecycle.cancelled, state != Lifecycle.finishing else { return false }
            finishReason = reason
            lifecycle.store(Lifecycle.finishing, ordering: .releasing)
            return true
        }
        if shouldStartDrain {
            ensureDrainTask()
            pcmRing.wakeConsumer()
        }
    }

    private func ensureDrainTask() {
        stateLock.withLock {
            guard drainTask == nil,
                  lifecycle.load(ordering: .acquiring) != Lifecycle.cancelled
            else { return }
            drainTask = Task.detached(priority: .utility) { [weak self] in
                await self?.drainLoop()
            }
        }
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            let state = lifecycle.load(ordering: .acquiring)
            guard state != Lifecycle.cancelled else { return }

            if let position = takePendingSeek() {
                await accumulator.seek(to: position)
                continue
            }

            if let frame = pcmRing.dequeue() {
                // Pauses/seeks invalidate queued PCM by generation. The audio
                // path stays authoritative; stale haptics work is disposable.
                guard (state == Lifecycle.active || state == Lifecycle.finishing),
                      frame.generation == generation.load(ordering: .acquiring)
                else { continue }
                let window = await accumulator.append(
                    bytes: frame.bytes,
                    time: frame.time,
                    format: frame.format,
                    frameCount: frame.frameCount
                )
                guard frame.generation == generation.load(ordering: .acquiring) else { continue }
                if let window { onWindow(window) }
                continue
            }

            if state == Lifecycle.finishing,
               pcmRing.isEmpty,
               pcmRing.isProducerIdle {
                await finishAfterDraining()
                return
            }

            if state == Lifecycle.paused {
                // Discard pre-pause slots while paused so resume never holds
                // a stale backlog. No frame is accepted by beginPCMFrame.
                while pcmRing.dequeue() != nil {}
            }
            // PCM windows are consumed as soon as a slot is published. The
            // timeout is only a bounded safety net for producer/finish races;
            // it reduces idle wakeups from ~500/s to at most ~50/s.
            pcmRing.waitForData(timeout: .milliseconds(20))
        }
    }

    private func takePendingSeek() -> TimeInterval? {
        stateLock.withLock {
            defer { pendingSeek = nil }
            return pendingSeek
        }
    }

    private func finishAfterDraining() async {
        // A callback that reserved a slot before finish() must either commit
        // or abort before the terminal result is materialized.
        while !pcmRing.isEmpty || !pcmRing.isProducerIdle {
            pcmRing.waitForData(timeout: .milliseconds(20))
        }
        await accumulator.flush()
        let checkpoint = await accumulator.checkpoint(identity: identity, duration: duration)
        let state = stateLock.withLock {
            (
                cancelled: lifecycle.load(ordering: .acquiring) == Lifecycle.cancelled,
                tapAttached: tapWasAttached,
                pcmFormat: pcmFormat,
                reason: finishReason,
                shouldDeliver: !finishDelivered
            )
        }
        guard !state.cancelled, state.shouldDeliver, let reason = state.reason else { return }
        stateLock.withLock { finishDelivered = true }
        let snapshot = await accumulator.snapshot(
            tapAttached: state.tapAttached,
            pcmFormat: state.pcmFormat,
            droppedFrames: droppedFrameCountValue,
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
            let state = self.stateLock.withLock {
                (
                    tapAttached: self.tapWasAttached,
                    pcmFormat: self.pcmFormat
                )
            }
            self.onProgress(await self.accumulator.snapshot(
                tapAttached: state.tapAttached,
                pcmFormat: state.pcmFormat,
                droppedFrames: self.droppedFrameCountValue
            ))
        }
    }

    private var droppedFrameCountValue: Int {
        Int(clamping: droppedFrameCount.load(ordering: .acquiring))
    }
}
