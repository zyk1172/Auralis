import Accelerate
import Foundation

public struct MusicHapticsAnalysisPerformancePolicy: Hashable, Sendable {
    public let fftFrameStride: Int
    public let targetLead: TimeInterval
    public let schedulingHorizon: TimeInterval
    public let isLowPowerMode: Bool

    public init(
        fftFrameStride: Int = 1,
        targetLead: TimeInterval = 8,
        schedulingHorizon: TimeInterval = 18,
        isLowPowerMode: Bool = false
    ) {
        self.fftFrameStride = max(1, fftFrameStride)
        self.targetLead = max(0.5, targetLead)
        self.schedulingHorizon = max(self.targetLead, schedulingHorizon)
        self.isLowPowerMode = isLowPowerMode
    }

    public static var current: Self {
        #if os(iOS) || os(macOS)
        let process = ProcessInfo.processInfo
        let thermal = process.thermalState
        let lowPower = process.isLowPowerModeEnabled
        if thermal == .critical {
            return Self(fftFrameStride: 4, targetLead: 3, schedulingHorizon: 8, isLowPowerMode: lowPower)
        }
        if thermal == .serious || lowPower {
            return Self(fftFrameStride: 2, targetLead: 5, schedulingHorizon: 12, isLowPowerMode: lowPower)
        }
        #endif
        return Self()
    }
}

/// Lightweight v2 DSP configuration.  Real audio is normalized by the
/// decoders to mono Float32 at 22.05 kHz; the small-rate branch exists only so
/// deterministic unit tests can use tiny synthetic buffers.
public struct MusicHapticsDSPConfiguration: Hashable, Sendable {
    public var targetSampleRate: Double
    public var fftSize: Int
    public var hopSize: Int
    public var adaptiveWindowSeconds: TimeInterval
    public var fftFrameStride: Int

    public init(
        targetSampleRate: Double = 22_050,
        fftSize: Int = 1_024,
        hopSize: Int = 256,
        adaptiveWindowSeconds: TimeInterval = 3,
        fftFrameStride: Int = MusicHapticsAnalysisPerformancePolicy.current.fftFrameStride
    ) {
        self.targetSampleRate = targetSampleRate
        self.fftSize = max(16, fftSize)
        self.hopSize = max(1, min(hopSize, self.fftSize))
        self.adaptiveWindowSeconds = min(max(adaptiveWindowSeconds, 2), 4)
        self.fftFrameStride = max(1, fftFrameStride)
    }
}

public struct MusicHapticsDSPDiagnostics: Hashable, Sendable {
    public var beatConfidence: Double
    public var tempoBPM: Double?
    public var beatPhase: Double?
    public var analysisPosition: TimeInterval
    public var eventCount: Int
    public var transientCount: Int
    public var continuousCount: Int

    public init(
        beatConfidence: Double = 0,
        tempoBPM: Double? = nil,
        beatPhase: Double? = nil,
        analysisPosition: TimeInterval = 0,
        eventCount: Int = 0,
        transientCount: Int = 0,
        continuousCount: Int = 0
    ) {
        self.beatConfidence = min(max(beatConfidence, 0), 1)
        self.tempoBPM = tempoBPM
        self.beatPhase = beatPhase
        self.analysisPosition = max(0, analysisPosition)
        self.eventCount = max(0, eventCount)
        self.transientCount = max(0, transientCount)
        self.continuousCount = max(0, continuousCount)
    }
}

/// One processor is shared by offline files, remote lookahead and the tap
/// fallback.  It owns only bounded rolling DSP state and is never called from
/// the audio render callback.
public struct MusicHapticsDSPProcessor: @unchecked Sendable {
    public let configuration: MusicHapticsDSPConfiguration

    private var sampleRate: Double?
    private var frameSize = 1_024
    private var hopSize = 256
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private var pending: [Float] = []
    private var pendingStart: TimeInterval?
    private var analysisFrameIndex = 0
    private var window: [Float] = []
    private var previousSpectrum: [Float] = []
    private var previousBandEnergies: [Float] = []
    private var previousFrameTime: TimeInterval = -.infinity
    private var previousFastEnvelope: Float = 0
    private var slowEnvelope: Float = 0
    private var previousLogEnergy: Float?
    private var lastSustainedBassTime: TimeInterval = -.infinity
    private var rmsHistory: [Float] = []
    private var onsetHistory: [Float] = []
    private var beatTimes: [TimeInterval] = []
    private var beatIntervals: [TimeInterval] = []
    private var lastBeatTime: TimeInterval = -.infinity
    private var totalEventCount = 0
    private var totalTransientCount = 0
    private var totalContinuousCount = 0
    private var lastDiagnostics = MusicHapticsDSPDiagnostics()

    public init(configuration: MusicHapticsDSPConfiguration = .init()) {
        self.configuration = configuration
    }

    public var diagnostics: MusicHapticsDSPDiagnostics { lastDiagnostics }
    public var analysisPosition: TimeInterval { lastDiagnostics.analysisPosition }

    /// Appends decoded mono PCM and returns only events produced by complete
    /// analysis frames.  Timestamp discontinuities reset rolling state instead
    /// of inventing a bridge across a seek or a coverage hole.
    public mutating func process(
        monoSamples: [Float],
        startTime: TimeInterval,
        sampleRate: Double
    ) -> [MusicHapticsEvent] {
        guard !monoSamples.isEmpty,
              startTime.isFinite,
              startTime >= 0,
              sampleRate.isFinite,
              sampleRate > 0
        else { return [] }
        configureIfNeeded(sampleRate: sampleRate)
        if let pendingStart,
           previousFrameTime.isFinite,
           abs(startTime - (pendingStart + Double(pending.count) / sampleRate)) > 0.5 {
            resetRollingState()
            self.pendingStart = startTime
        } else if pending.isEmpty {
            self.pendingStart = startTime
        }
        pending.append(contentsOf: monoSamples.map { min(max($0.isFinite ? $0 : 0, -1), 1) })

        var events: [MusicHapticsEvent] = []
        while pending.count >= frameSize, let frameStart = pendingStart {
            let frame = Array(pending.prefix(frameSize))
            if analysisFrameIndex % configuration.fftFrameStride == 0 {
                events.append(contentsOf: analyze(frame: frame, time: frameStart))
            } else {
                lastDiagnostics = MusicHapticsDSPDiagnostics(
                    beatConfidence: lastDiagnostics.beatConfidence,
                    tempoBPM: lastDiagnostics.tempoBPM,
                    beatPhase: lastDiagnostics.beatPhase,
                    analysisPosition: frameStart + Double(frameSize) / sampleRate,
                    eventCount: totalEventCount,
                    transientCount: totalTransientCount,
                    continuousCount: totalContinuousCount
                )
            }
            analysisFrameIndex += 1
            pending.removeFirst(min(hopSize, pending.count))
            pendingStart = frameStart + Double(hopSize) / sampleRate
        }
        return MusicHapticsEventDeduplicator.merge(events)
    }

    /// Flushes a final short buffer with zero padding.  It makes small local
    /// files and tap segments observable without weakening the real FFT frame
    /// size used by normal 22.05 kHz analysis.
    public mutating func finish() -> [MusicHapticsEvent] {
        guard !pending.isEmpty, let frameStart = pendingStart else { return [] }
        var frame = pending
        frame.append(contentsOf: repeatElement(0, count: max(0, frameSize - frame.count)))
        let events = analyze(frame: Array(frame.prefix(frameSize)), time: frameStart)
        pending.removeAll(keepingCapacity: false)
        pendingStart = nil
        return MusicHapticsEventDeduplicator.merge(events)
    }

    private mutating func configureIfNeeded(sampleRate: Double) {
        guard self.sampleRate != sampleRate else { return }
        self.sampleRate = sampleRate
        // The production path is exactly 1024/256.  Keep a small synthetic
        // frame for tests using 8–48 Hz PCM so flush/process can still prove
        // event synthesis without changing production DSP parameters.
        if sampleRate < 1_000 {
            let requested = max(16, Int((sampleRate * 0.1).rounded()))
            frameSize = min(configuration.fftSize, Self.powerOfTwo(atLeast: requested))
            hopSize = max(1, min(configuration.hopSize, frameSize / 4))
        } else {
            frameSize = configuration.fftSize
            hopSize = min(configuration.hopSize, frameSize)
        }
        window = Self.hannWindow(count: frameSize)
        let log2n = Int(log2(Double(frameSize)))
        fft = vDSP.FFT(
            log2n: vDSP_Length(log2n),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        )
        previousSpectrum.removeAll(keepingCapacity: true)
        previousBandEnergies.removeAll(keepingCapacity: true)
        analysisFrameIndex = 0
        resetRollingState(keepSampleRate: true)
    }

    private mutating func resetRollingState(keepSampleRate: Bool = true) {
        pending.removeAll(keepingCapacity: true)
        pendingStart = nil
        previousSpectrum.removeAll(keepingCapacity: true)
        previousFrameTime = -.infinity
        previousFastEnvelope = 0
        slowEnvelope = 0
        previousLogEnergy = nil
        lastSustainedBassTime = -.infinity
        rmsHistory.removeAll(keepingCapacity: true)
        onsetHistory.removeAll(keepingCapacity: true)
        beatTimes.removeAll(keepingCapacity: true)
        beatIntervals.removeAll(keepingCapacity: true)
        lastBeatTime = -.infinity
        if !keepSampleRate { sampleRate = nil }
    }

    private mutating func analyze(frame: [Float], time: TimeInterval) -> [MusicHapticsEvent] {
        guard let sampleRate, frame.count == frameSize else { return [] }
        let rms = vDSP.rootMeanSquare(frame)
        let safeRMS = max(rms, 0)
        let logEnergy = log(max(safeRMS, 0.00001))
        let logOnset = previousLogEnergy.map { max(0, logEnergy - $0) } ?? 0
        previousLogEnergy = logEnergy
        let spectrum = makeSpectrum(frame)
        let bands = bandEnergies(spectrum: spectrum, sampleRate: sampleRate)
        let bandOnset = multiBandOnset(bands)
        let flux = spectralFlux(spectrum)
        let centroid = spectralCentroid(spectrum: spectrum, sampleRate: sampleRate)
        let flatness = spectralFlatness(spectrum)

        let fastAlpha = Float(1 - exp(-Double(hopSize) / max(1, sampleRate * 0.18)))
        let slowAlpha = Float(1 - exp(-Double(hopSize) / max(1, sampleRate * 3.0)))
        previousFastEnvelope += fastAlpha * (safeRMS - previousFastEnvelope)
        slowEnvelope += slowAlpha * (safeRMS - slowEnvelope)

        let previousRMS = rmsHistory.last ?? safeRMS
        let onset = max(0, safeRMS - previousRMS)
            + logOnset * 0.02
            + flux * 0.35
        appendRolling(&rmsHistory, value: safeRMS, limit: historyLimit(sampleRate: sampleRate))
        appendRolling(&onsetHistory, value: onset, limit: historyLimit(sampleRate: sampleRate))

        let onsetThreshold = adaptiveThreshold(onsetHistory, multiplier: 2.8, floor: 0.0005)
        let rmsThreshold = adaptiveThreshold(rmsHistory, multiplier: 2.2, floor: 0.004)
        let isTransient = onset >= onsetThreshold && safeRMS >= rmsThreshold && safeRMS > 0.004
        let beat = updateBeatTracking(time: time, onset: onset, threshold: onsetThreshold, energy: safeRMS)
        let classAndShape = classify(
            bands: bands,
            onset: onset,
            bandOnset: bandOnset,
            flux: flux,
            flatness: flatness,
            centroid: centroid,
            beat: beat
        )

        var events: [MusicHapticsEvent] = []
        if isTransient || beat.isBeat {
            let eventClass = classAndShape.eventClass
            let energyPart = min(1, safeRMS / max(rmsThreshold, 0.004))
            let onsetPart = min(1, onset / max(onsetThreshold, 0.0005))
            let beatPart: Float = beat.isBeat ? 0.18 : 0
            let intensity = min(0.92, 0.25 + energyPart * 0.25 + onsetPart * 0.37 + beatPart)
            let duration: TimeInterval = eventClass == .highPercussion ? 0.045 : 0.085
            events.append(MusicHapticsEvent(
                time: time,
                duration: duration,
                intensity: intensity,
                sharpness: classAndShape.sharpness,
                kind: .transient,
                classification: eventClass
            ))
        }

        let lowEnergy = bands[0] + bands[1]
        let sustainedBass = lowEnergy > max(0.0001, slowEnvelope * slowEnvelope * 0.14)
            && safeRMS > rmsThreshold * 0.72
            && !isTransient
        if sustainedBass, time - lastSustainedBassTime >= 0.18 {
            let bassIntensity = min(0.62, 0.18 + min(1, lowEnergy * 16) * 0.32)
            events.append(MusicHapticsEvent(
                time: time,
                duration: 0.28,
                intensity: bassIntensity,
                sharpness: 0.16,
                kind: .continuous,
                classification: .sustainedBass,
                curve: [
                    MusicHapticsCurvePoint(timeOffset: 0, intensity: bassIntensity * 0.72, sharpness: 0.14),
                    MusicHapticsCurvePoint(timeOffset: 0.14, intensity: bassIntensity, sharpness: 0.16),
                    MusicHapticsCurvePoint(timeOffset: 0.28, intensity: bassIntensity * 0.76, sharpness: 0.14),
                ]
            ))
            lastSustainedBassTime = time
        }

        let rising = previousFastEnvelope > slowEnvelope * 1.10 && flux > 0.002
        if rising && !isTransient && safeRMS > rmsThreshold * 0.85 {
            let buildIntensity = min(0.68, 0.22 + min(1, previousFastEnvelope * 7) * 0.38)
            events.append(MusicHapticsEvent(
                time: time,
                duration: 0.36,
                intensity: buildIntensity,
                sharpness: 0.42,
                kind: .continuous,
                classification: .buildTexture,
                curve: [
                    MusicHapticsCurvePoint(timeOffset: 0, intensity: buildIntensity * 0.45, sharpness: 0.34),
                    MusicHapticsCurvePoint(timeOffset: 0.36, intensity: buildIntensity, sharpness: 0.48),
                ]
            ))
        }

        let climax = safeRMS > percentile(rmsHistory, percentile: 0.90)
            && beat.isBeat
            && beat.confidence >= 0.45
        if climax {
            events.append(MusicHapticsEvent(
                time: time,
                duration: 0.11,
                intensity: 0.82,
                sharpness: min(0.78, classAndShape.sharpness + 0.10),
                kind: .transient,
                classification: .climax
            ))
        }

        previousSpectrum = spectrum
        previousFrameTime = time
        lastDiagnostics = MusicHapticsDSPDiagnostics(
            beatConfidence: beat.confidence,
            tempoBPM: beat.tempoBPM,
            beatPhase: beat.phase,
            analysisPosition: time + Double(frameSize) / sampleRate,
            eventCount: totalEventCount + events.count,
            transientCount: totalTransientCount + events.filter { $0.kind == .transient }.count,
            continuousCount: totalContinuousCount + events.filter { $0.kind == .continuous }.count
        )
        totalEventCount += events.count
        totalTransientCount += events.filter { $0.kind == .transient }.count
        totalContinuousCount += events.filter { $0.kind == .continuous }.count
        return events
    }

    private mutating func makeSpectrum(_ frame: [Float]) -> [Float] {
        let count = frame.count
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)
        var outputReal = [Float](repeating: 0, count: count)
        var outputImag = [Float](repeating: 0, count: count)
        var windowed = [Float](repeating: 0, count: count)
        vDSP.multiply(frame, window, result: &windowed)
        real = windowed
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                outputReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                    outputImag.withUnsafeMutableBufferPointer { outputImagBuffer in
                        let input = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                        var output = DSPSplitComplex(realp: outputRealBuffer.baseAddress!, imagp: outputImagBuffer.baseAddress!)
                        // The complex input is real PCM plus a zero imaginary
                        // plane.  vDSP performs the FFT off the render thread.
                        fft?.forward(input: input, output: &output)
                    }
                }
            }
        }
        let magnitudeCount = count / 2
        var magnitudes = [Float](repeating: 0, count: magnitudeCount)
        let realHalf = outputReal
        let imagHalf = outputImag
        realHalf.withUnsafeBufferPointer { realBuffer in
            imagHalf.withUnsafeBufferPointer { imagBuffer in
                magnitudes.withUnsafeMutableBufferPointer { magnitudeBuffer in
                    vDSP.hypot(
                        UnsafeBufferPointer(start: realBuffer.baseAddress, count: magnitudeCount),
                        UnsafeBufferPointer(start: imagBuffer.baseAddress, count: magnitudeCount),
                        result: &magnitudeBuffer
                    )
                }
            }
        }
        var normalized = [Float](repeating: 0, count: magnitudes.count)
        vDSP.divide(magnitudes, Float(count), result: &normalized)
        return normalized
    }

    private func bandEnergies(spectrum: [Float], sampleRate: Double) -> [Float] {
        let limits: [(Double, Double)] = [
            (30, 90), (90, 180), (180, 500), (500, 2_000), (2_000, 5_000), (5_000, 10_000)
        ]
        let binWidth = sampleRate / Double(frameSize)
        return limits.map { lower, upper in
            let lowerBin = min(spectrum.count - 1, max(0, Int((lower / binWidth).rounded(.down))))
            let upperBin = min(spectrum.count, max(lowerBin + 1, Int((upper / binWidth).rounded(.up))))
            guard upperBin > lowerBin else { return 0 }
            var squares = [Float](repeating: 0, count: upperBin - lowerBin)
            spectrum[lowerBin..<upperBin].withUnsafeBufferPointer { source in
                vDSP.square(source, result: &squares)
            }
            var sum: Float = 0
            vDSP_sve(squares, 1, &sum, vDSP_Length(squares.count))
            return sum / Float(max(1, squares.count))
        }
    }

    private mutating func spectralFlux(_ spectrum: [Float]) -> Float {
        guard !previousSpectrum.isEmpty else { return 0 }
        let count = min(spectrum.count, previousSpectrum.count)
        var differences = [Float](repeating: 0, count: count)
        for index in 0..<count {
            differences[index] = max(0, spectrum[index] - previousSpectrum[index])
        }
        var sum: Float = 0
        vDSP_sve(differences, 1, &sum, vDSP_Length(differences.count))
        return sum / Float(max(1, count))
    }

    private func spectralCentroid(spectrum: [Float], sampleRate: Double) -> Float {
        guard !spectrum.isEmpty else { return 0 }
        let binWidth = Float(sampleRate / Double(frameSize))
        var weighted: Float = 0
        var total: Float = 0
        for (index, value) in spectrum.enumerated() {
            weighted += value * Float(index) * binWidth
            total += value
        }
        return total > 0 ? weighted / total : 0
    }

    private func spectralFlatness(_ spectrum: [Float]) -> Float {
        guard !spectrum.isEmpty else { return 0 }
        let values = spectrum.map { max($0, 0.0000001) }
        let geometric = exp(values.reduce(0) { $0 + log($1) } / Float(values.count))
        let arithmetic = values.reduce(0, +) / Float(values.count)
        return arithmetic > 0 ? min(1, geometric / arithmetic) : 0
    }

    private func classify(
        bands: [Float],
        onset: Float,
        bandOnset: [Float],
        flux: Float,
        flatness: Float,
        centroid: Float,
        beat: BeatResult
    ) -> (eventClass: MusicHapticsEventClass, sharpness: Float) {
        let low = bands[0] + bands[1]
        let mid = bands[2] + bands[3]
        let high = bands[4] + bands[5]
        let lowAttack = bandOnset[0] + bandOnset[1]
        let highAttack = bandOnset[4] + bandOnset[5]
        if low >= mid * 0.82 && low >= high * 0.72 && lowAttack >= highAttack * 0.72 {
            return (beat.isBeat ? .kick : .bassAttack, 0.16)
        }
        if high > low * 1.15 && highAttack >= lowAttack * 0.65
            && (flatness > 0.12 || centroid > 4_500) {
            return (.highPercussion, min(0.92, 0.58 + flux * 2.2))
        }
        if mid >= low * 0.72 {
            return (.snareClap, min(0.82, 0.46 + onset * 4.0))
        }
        return (.snareClap, 0.42)
    }

    /// Positive per-band energy deltas are normalized against the previous
    /// local energy so a quiet piano attack and a loud kick both contribute
    /// without reintroducing a fixed absolute onset threshold.
    private mutating func multiBandOnset(_ bands: [Float]) -> [Float] {
        defer { previousBandEnergies = bands }
        guard previousBandEnergies.count == bands.count else {
            return Array(repeating: 0, count: bands.count)
        }
        return zip(bands, previousBandEnergies).map { current, previous in
            let delta = max(0, current - previous)
            return min(1, delta / max(0.0001, previous * 0.5 + 0.00005))
        }
    }

    private mutating func updateBeatTracking(
        time: TimeInterval,
        onset: Float,
        threshold: Float,
        energy: Float
    ) -> BeatResult {
        let rawCandidate = onset >= threshold && energy > 0.004
        // An onset spans several overlapping FFT frames. Without a short
        // refractory period every frame of one kick becomes a new "beat",
        // which prevents tempo estimation and makes the haptic texture busy.
        let candidate = rawCandidate
            && (!lastBeatTime.isFinite || time - lastBeatTime >= 0.25)
        if candidate {
            if lastBeatTime.isFinite {
                let interval = time - lastBeatTime
                if interval >= 0.25, interval <= 1.50 {
                    beatIntervals.append(interval)
                    if beatIntervals.count > 12 { beatIntervals.removeFirst() }
                }
            }
            lastBeatTime = time
            beatTimes.append(time)
            if beatTimes.count > 24 { beatTimes.removeFirst() }
        }
        let interval = beatIntervals.isEmpty ? nil : median(beatIntervals)
        let tempo = interval.map { 60 / $0 }
        let confidence: Double
        if beatIntervals.count < 2 {
            confidence = candidate ? 0.30 : 0
        } else {
            let medianInterval = median(beatIntervals)
            let deviation = beatIntervals.reduce(0) { $0 + abs($1 - medianInterval) } / Double(beatIntervals.count)
            confidence = min(1, max(0, 1 - deviation / max(0.001, medianInterval * 0.35)))
        }
        let phase = interval.map { (time.truncatingRemainder(dividingBy: $0)) / $0 }
        return BeatResult(isBeat: candidate, confidence: confidence, tempoBPM: tempo, phase: phase)
    }

    private func adaptiveThreshold(_ values: [Float], multiplier: Float, floor: Float) -> Float {
        guard !values.isEmpty else { return floor }
        let middle = median(values)
        let deviations = values.map { abs($0 - middle) }
        let mad = median(deviations)
        return max(floor, middle + multiplier * max(mad, 0.000001))
    }

    private func percentile(_ values: [Float], percentile: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        return sorted[index]
    }

    private func historyLimit(sampleRate: Double) -> Int {
        max(32, Int(sampleRate / Double(max(1, hopSize)) * configuration.adaptiveWindowSeconds))
    }

    private func appendRolling(_ values: inout [Float], value: Float, limit: Int) {
        values.append(value)
        if values.count > limit { values.removeFirst(values.count - limit) }
    }

    private func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func hannWindow(count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        vDSP_hann_window(&result, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        return result
    }

    private static func powerOfTwo(atLeast value: Int) -> Int {
        var result = 1
        while result < value { result *= 2 }
        return result
    }

    private struct BeatResult {
        let isBeat: Bool
        let confidence: Double
        let tempoBPM: Double?
        let phase: Double?
    }
}

/// Event thinning is deliberately class-aware.  A kick and a hi-hat at the
/// same time are allowed to coexist, while duplicate detections of one class
/// are collapsed only within that class's short refractory window.
public enum MusicHapticsEventDeduplicator {
    public static func merge(_ input: [MusicHapticsEvent]) -> [MusicHapticsEvent] {
        var result: [MusicHapticsEvent] = []
        for event in input.sorted(by: { $0.time < $1.time }) {
            guard let index = result.lastIndex(where: { $0.classification == event.classification }),
                  event.time - result[index].time < event.classification.deduplicationWindow
            else {
                result.append(event)
                continue
            }
            let existing = result[index]
            if existing.kind == .continuous || event.kind == .continuous {
                let end = max(existing.time + (existing.duration ?? 0), event.time + (event.duration ?? 0))
                let start = min(existing.time, event.time)
                let existingCurve = existing.curve.map {
                    MusicHapticsCurvePoint(
                        timeOffset: existing.time - start + $0.timeOffset,
                        intensity: $0.intensity,
                        sharpness: $0.sharpness
                    )
                }
                let eventCurve = event.curve.map {
                    MusicHapticsCurvePoint(
                        timeOffset: event.time - start + $0.timeOffset,
                        intensity: $0.intensity,
                        sharpness: $0.sharpness
                    )
                }
                result[index] = MusicHapticsEvent(
                    time: start,
                    duration: max(0.02, end - start),
                    intensity: max(existing.intensity, event.intensity),
                    sharpness: max(existing.sharpness, event.sharpness),
                    kind: .continuous,
                    classification: event.classification,
                    curve: (existingCurve + eventCurve).sorted { $0.timeOffset < $1.timeOffset }
                )
            } else if event.intensity > existing.intensity {
                result[index] = event
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}
