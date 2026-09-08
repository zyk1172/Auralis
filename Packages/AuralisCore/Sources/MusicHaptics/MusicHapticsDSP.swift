import Accelerate
import Foundation

public struct MusicHapticsAnalysisPerformancePolicy: Hashable, Sendable {
    public let fftFrameStride: Int
    public let hapticCommitHorizon: TimeInterval
    public let isLowPowerMode: Bool

    public init(
        fftFrameStride: Int = 1,
        hapticCommitHorizon: TimeInterval = 3,
        isLowPowerMode: Bool = false
    ) {
        self.fftFrameStride = max(1, fftFrameStride)
        self.hapticCommitHorizon = min(max(hapticCommitHorizon, 2.5), 4)
        self.isLowPowerMode = isLowPowerMode
    }

    public static var current: Self {
        #if os(iOS) || os(macOS)
        let process = ProcessInfo.processInfo
        let thermal = process.thermalState
        let lowPower = process.isLowPowerModeEnabled
        if thermal == .critical {
            return Self(fftFrameStride: 4, hapticCommitHorizon: 2.5, isLowPowerMode: lowPower)
        }
        if thermal == .serious || lowPower {
            return Self(fftFrameStride: 2, hapticCommitHorizon: 2.5, isLowPowerMode: lowPower)
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
    public var beatPhaseError: Double
    public var beatPhaseAnchor: TimeInterval?
    public var nextBeatTime: TimeInterval?
    public var analysisPosition: TimeInterval
    public var eventCount: Int
    public var transientCount: Int
    public var continuousCount: Int

    public init(
        beatConfidence: Double = 0,
        tempoBPM: Double? = nil,
        beatPhase: Double? = nil,
        beatPhaseError: Double = 1,
        beatPhaseAnchor: TimeInterval? = nil,
        nextBeatTime: TimeInterval? = nil,
        analysisPosition: TimeInterval = 0,
        eventCount: Int = 0,
        transientCount: Int = 0,
        continuousCount: Int = 0
    ) {
        self.beatConfidence = min(max(beatConfidence, 0), 1)
        self.tempoBPM = tempoBPM
        self.beatPhase = beatPhase
        self.beatPhaseError = min(max(beatPhaseError.isFinite ? beatPhaseError : 1, 0), 1)
        self.beatPhaseAnchor = beatPhaseAnchor?.isFinite == true ? beatPhaseAnchor : nil
        self.nextBeatTime = nextBeatTime?.isFinite == true ? nextBeatTime : nil
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
    /// Logical read cursor for the pending PCM. `removeFirst` on every hop
    /// copies the remaining audio and can make the utility consumer fall
    /// behind a real-time tap. Compact this bounded buffer periodically
    /// instead of paying that cost for each FFT hop.
    private var pendingReadOffset = 0
    private var pendingStart: TimeInterval?
    private var analysisFrameIndex = 0
    private var window: [Float] = []
    private var previousSpectrum: [Float] = []
    private var previousBandEnergies: [Float] = []
    private var previousFrameTime: TimeInterval = -.infinity
    private var previousFastEnvelope: Float = 0
    private var slowEnvelope: Float = 0
    private var previousLogEnergy: Float?
    private var activeTextureStart: TimeInterval?
    private var activeTextureLastTime: TimeInterval?
    private var activeTextureClass: MusicHapticsEventClass?
    private var activeTexturePeak: Float = 0
    private var activeTextureSharpness: Float = 0
    private var activeTexturePoints: [MusicHapticsCurvePoint] = []
    private var activeTextureLastSnapshotTime: TimeInterval?
    private var rmsHistory: [Float] = []
    private var onsetHistory: [Float] = []
    private var energyDBHistory: [Float] = []
    private var beatTracker = MusicHapticsBeatTracker()
    private var totalEventCount = 0
    private var totalTransientCount = 0
    private var totalContinuousCount = 0
    private var lastDiagnostics = MusicHapticsDSPDiagnostics()
    private let maximumTextureSegmentDuration: TimeInterval = 8

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
        processCandidates(monoSamples: monoSamples, startTime: startTime, sampleRate: sampleRate)
            .flatMap(\.events)
    }

    /// Returns DSP candidates with beat and energy context. The perceptual
    /// mixer consumes this path; `process` remains as a compatibility API for
    /// callers that only need raw events.
    public mutating func processCandidates(
        monoSamples: [Float],
        startTime: TimeInterval,
        sampleRate: Double
    ) -> [MusicHapticsCandidateFrame] {
        guard !monoSamples.isEmpty,
              startTime.isFinite,
              startTime >= 0,
              sampleRate.isFinite,
              sampleRate > 0
        else { return [] }
        configureIfNeeded(sampleRate: sampleRate)
        let bufferedCount = pending.count - pendingReadOffset
        if let pendingStart,
           previousFrameTime.isFinite,
           abs(startTime - (pendingStart + Double(bufferedCount) / sampleRate)) > 0.5 {
            resetRollingState()
            self.pendingStart = startTime
        } else if bufferedCount == 0 {
            self.pendingStart = startTime
        }
        pending.append(contentsOf: monoSamples.map { min(max($0.isFinite ? $0 : 0, -1), 1) })

        var frames: [MusicHapticsCandidateFrame] = []
        while pending.count - pendingReadOffset >= frameSize, let frameStart = pendingStart {
            let frameEnd = pendingReadOffset + frameSize
            let frame = Array(pending[pendingReadOffset..<frameEnd])
            if analysisFrameIndex % configuration.fftFrameStride == 0 {
                frames.append(analyze(frame: frame, time: frameStart))
            } else {
                lastDiagnostics = MusicHapticsDSPDiagnostics(
                    beatConfidence: lastDiagnostics.beatConfidence,
                    tempoBPM: lastDiagnostics.tempoBPM,
                    beatPhase: lastDiagnostics.beatPhase,
                    beatPhaseError: lastDiagnostics.beatPhaseError,
                    beatPhaseAnchor: lastDiagnostics.beatPhaseAnchor,
                    nextBeatTime: lastDiagnostics.nextBeatTime,
                    analysisPosition: frameStart + Double(frameSize) / sampleRate,
                    eventCount: totalEventCount,
                    transientCount: totalTransientCount,
                    continuousCount: totalContinuousCount
                )
            }
            analysisFrameIndex += 1
            pendingReadOffset += min(hopSize, frameSize)
            pendingStart = frameStart + Double(hopSize) / sampleRate
            compactPendingIfNeeded()
        }
        return frames
    }

    /// Flushes a final short buffer with zero padding.  It makes small local
    /// files and tap segments observable without weakening the real FFT frame
    /// size used by normal 22.05 kHz analysis.
    public mutating func finish() -> [MusicHapticsEvent] {
        finishCandidates().flatMap(\.events)
    }

    public mutating func finishCandidates() -> [MusicHapticsCandidateFrame] {
        guard pending.count - pendingReadOffset > 0, let frameStart = pendingStart else {
            guard let texture = finishTexture() else { return [] }
            recordFinalizedEvent(texture)
            return [MusicHapticsCandidateFrame(time: texture.time, events: [texture])]
        }
        var frame = Array(pending[pendingReadOffset...])
        frame.append(contentsOf: repeatElement(0, count: max(0, frameSize - frame.count)))
        var result = analyze(frame: Array(frame.prefix(frameSize)), time: frameStart)
        if let texture = finishTexture() {
            recordFinalizedEvent(texture)
            result = MusicHapticsCandidateFrame(
                time: result.time,
                events: result.events + [texture],
                energyLevel: result.energyLevel,
                slowEnergy: result.slowEnergy,
                onsetActivity: result.onsetActivity,
                beat: result.beat,
                isQuiet: result.isQuiet
            )
        }
        pending.removeAll(keepingCapacity: false)
        pendingReadOffset = 0
        pendingStart = nil
        return [result]
    }

    private mutating func recordFinalizedEvent(_ event: MusicHapticsEvent) {
        totalEventCount += 1
        if event.kind == .transient { totalTransientCount += 1 }
        if event.kind == .continuous { totalContinuousCount += 1 }
        let beat = beatTracker.currentEstimate
        lastDiagnostics = MusicHapticsDSPDiagnostics(
            beatConfidence: beat.confidence,
            tempoBPM: beat.tempoBPM,
            beatPhase: beat.phase,
            beatPhaseError: beat.phaseError,
            beatPhaseAnchor: beat.phaseAnchor,
            nextBeatTime: beat.nextBeatTime,
            analysisPosition: lastDiagnostics.analysisPosition,
            eventCount: totalEventCount,
            transientCount: totalTransientCount,
            continuousCount: totalContinuousCount
        )
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
        pendingReadOffset = 0
        pendingStart = nil
        previousSpectrum.removeAll(keepingCapacity: true)
        previousFrameTime = -.infinity
        previousFastEnvelope = 0
        slowEnvelope = 0
        previousLogEnergy = nil
        activeTextureStart = nil
        activeTextureLastTime = nil
        activeTextureClass = nil
        activeTexturePeak = 0
        activeTextureSharpness = 0
        activeTexturePoints.removeAll(keepingCapacity: true)
        activeTextureLastSnapshotTime = nil
        rmsHistory.removeAll(keepingCapacity: true)
        onsetHistory.removeAll(keepingCapacity: true)
        energyDBHistory.removeAll(keepingCapacity: true)
        beatTracker.reset()
        if !keepSampleRate { sampleRate = nil }
    }

    private mutating func compactPendingIfNeeded() {
        guard pendingReadOffset > 0,
              pendingReadOffset >= 8_192 || pendingReadOffset * 2 >= pending.count
        else { return }
        pending.removeFirst(pendingReadOffset)
        pendingReadOffset = 0
    }

    private mutating func analyze(frame: [Float], time: TimeInterval) -> MusicHapticsCandidateFrame {
        guard let sampleRate, frame.count == frameSize else {
            return MusicHapticsCandidateFrame(time: time, events: [], isQuiet: true)
        }
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

        // Striding FFT work must not stretch a 3 s envelope/history into
        // 6–12 s in low-power mode. Track elapsed audio time, not call count.
        let elapsed = previousFrameTime.isFinite
            ? max(0, time - previousFrameTime)
            : Double(hopSize) * Double(configuration.fftFrameStride) / sampleRate
        let fastAlpha = Float(1 - exp(-elapsed / 0.18))
        let slowAlpha = Float(1 - exp(-elapsed / 3.0))
        previousFastEnvelope += fastAlpha * (safeRMS - previousFastEnvelope)
        slowEnvelope += slowAlpha * (safeRMS - slowEnvelope)

        let previousRMS = rmsHistory.last ?? safeRMS
        let onset = max(0, safeRMS - previousRMS)
            + logOnset * 0.02
            + flux * 0.35
        let rollingLimit = historyLimit(sampleRate: sampleRate)
        appendRolling(&rmsHistory, value: safeRMS, limit: rollingLimit)
        appendRolling(&onsetHistory, value: onset, limit: rollingLimit)
        let energyDB = 20 * log10(max(safeRMS, 0.00001))
        appendRolling(&energyDBHistory, value: energyDB, limit: rollingLimit)

        // Reuse one ordering for all perceptual percentile queries in this
        // frame instead of sorting the same rolling history six times.
        let sortedEnergyDB = energyDBHistory.sorted()
        let energyFloor = percentileOfSorted(sortedEnergyDB, percentile: 0.20)
        let energyCeiling = percentileOfSorted(sortedEnergyDB, percentile: 0.95)
        let onsetThreshold = adaptiveThreshold(onsetHistory, multiplier: 2.8, floor: 0.0005)
        let rmsThreshold = adaptiveThreshold(rmsHistory, multiplier: 2.2, floor: 0.004)
        let isTransient = onset >= onsetThreshold && safeRMS >= rmsThreshold && safeRMS > 0.004
        let beat = beatTracker.update(time: time, onset: onset, threshold: onsetThreshold, energy: safeRMS)
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
            // Thresholds decide whether an event is emitted; they must not
            // also pin its loudness to the same value.  Map energy against
            // the track's recent dB distribution and map the attack against
            // the amount by which it clears the onset threshold.
            let energyPosition = smoothstep(
                edge0: energyFloor,
                edge1: energyCeiling,
                value: energyDB
            )
            let onsetRatio = onset / max(onsetThreshold, 0.0005)
            let attackStrength = 1 - exp(-0.85 * max(0, onsetRatio - 1))
            let beatAccent: Float
            if beat.isBeat {
                beatAccent = switch beat.strength {
                case .strongBeat: 0.16
                case .normalBeat: 0.07
                case .subBeat: 0.02
                }
            } else {
                beatAccent = 0
            }
            let perceptualBase = min(
                1,
                max(0, 0.10 + energyPosition * 0.42 + attackStrength * 0.34 + beatAccent)
            )
            let intensity = Float(pow(Double(perceptualBase), 0.85))
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
            && safeRMS > max(0.004, rmsThreshold * 0.72)
        let rising = previousFastEnvelope > slowEnvelope * 1.10 && flux > 0.002
        let buildTexture = rising && safeRMS > rmsThreshold * 0.85
        if sustainedBass || buildTexture {
            // Keep an open section bounded for realtime/tap consumers. This
            // is a section rollover, not a fixed-rate vibration: adjacent
            // segments touch without overlapping and each retains a curve.
            if let activeStart = activeTextureStart,
               time - activeStart >= maximumTextureSegmentDuration,
               let texture = finishTexture() {
                events.append(texture)
            }
            if let lastTextureTime = activeTextureLastTime,
               time - lastTextureTime > 0.18,
               let texture = finishTexture() {
                events.append(texture)
            }
            let textureClass: MusicHapticsEventClass = buildTexture && !sustainedBass ? .buildTexture : .sustainedBass
            let baseIntensity = textureClass == .buildTexture
                ? min(0.68, 0.22 + min(1, previousFastEnvelope * 7) * 0.38)
                : min(0.62, 0.18 + min(1, lowEnergy * 16) * 0.32)
            appendTextureSample(
                time: time,
                eventClass: textureClass,
                intensity: baseIntensity,
                sharpness: textureClass == .buildTexture ? 0.42 : 0.16
            )
            if shouldEmitTextureSnapshot(at: time),
               let texture = textureSnapshot() {
                events.append(texture)
                activeTextureLastSnapshotTime = time
            }
        } else if let lastTextureTime = activeTextureLastTime,
                  time - lastTextureTime > 0.18,
                  let texture = finishTexture() {
            events.append(texture)
        }

        let climax = safeRMS > percentile(rmsHistory, percentile: 0.90)
            && beat.isBeat
            && beat.confidence >= 0.45
        if climax {
            events.append(MusicHapticsEvent(
                time: time,
                duration: 0.11,
                intensity: 0.60,
                sharpness: min(0.78, classAndShape.sharpness + 0.06),
                kind: .transient,
                classification: .climax,
                climaxAmount: 0.60
            ))
        }

        previousSpectrum = spectrum
        previousFrameTime = time
        lastDiagnostics = MusicHapticsDSPDiagnostics(
            beatConfidence: beat.confidence,
            tempoBPM: beat.tempoBPM,
            beatPhase: beat.phase,
            beatPhaseError: beat.phaseError,
            beatPhaseAnchor: beat.phaseAnchor,
            nextBeatTime: beat.nextBeatTime,
            analysisPosition: time + Double(frameSize) / sampleRate,
            eventCount: totalEventCount + events.count,
            transientCount: totalTransientCount + events.filter { $0.kind == .transient }.count,
            continuousCount: totalContinuousCount + events.filter { $0.kind == .continuous }.count
        )
        totalEventCount += events.count
        totalTransientCount += events.filter { $0.kind == .transient }.count
        totalContinuousCount += events.filter { $0.kind == .continuous }.count
        let energyLevel = smoothstep(
            edge0: energyFloor,
            edge1: energyCeiling,
            value: energyDB
        )
        let slowEnergyDB = 20 * log10(max(slowEnvelope, 0.00001))
        let slowEnergy = smoothstep(
            edge0: energyFloor,
            edge1: energyCeiling,
            value: slowEnergyDB
        )
        let isQuiet = safeRMS < max(0.003, rmsThreshold * 0.95)
            && onset < onsetThreshold * 1.20
        return MusicHapticsCandidateFrame(
            time: time,
            events: events,
            energyLevel: energyLevel,
            slowEnergy: slowEnergy,
            onsetActivity: min(1, onset / max(onsetThreshold, 0.0005)),
            beat: beat,
            isQuiet: isQuiet
        )
    }

    private mutating func appendTextureSample(
        time: TimeInterval,
        eventClass: MusicHapticsEventClass,
        intensity: Float,
        sharpness: Float
    ) {
        if activeTextureStart == nil {
            activeTextureStart = time
            activeTextureClass = eventClass
        }
        if activeTextureClass == nil {
            self.activeTextureClass = eventClass
        }
        activeTextureLastTime = time
        activeTexturePeak = max(activeTexturePeak, intensity)
        activeTextureSharpness = max(activeTextureSharpness, sharpness)
        let offset = max(0, time - (activeTextureStart ?? time))
        activeTexturePoints.append(MusicHapticsCurvePoint(
            timeOffset: offset,
            intensity: intensity,
            sharpness: sharpness
        ))
        if activeTexturePoints.count > 96 {
            activeTexturePoints = downsampleCurve(activeTexturePoints, limit: 96)
        }
    }

    private func downsampleCurve(
        _ points: [MusicHapticsCurvePoint],
        limit: Int
    ) -> [MusicHapticsCurvePoint] {
        guard points.count > limit, limit > 1 else { return points }
        return (0..<limit).map { index in
            let sourceIndex = Int((Double(index) * Double(points.count - 1) / Double(limit - 1)).rounded())
            return points[min(points.count - 1, max(0, sourceIndex))]
        }
    }

    private func shouldEmitTextureSnapshot(at time: TimeInterval) -> Bool {
        guard let last = activeTextureLastSnapshotTime else { return true }
        return time - last >= 0.25
    }

    private func textureSnapshot() -> MusicHapticsEvent? {
        guard let start = activeTextureStart,
              let last = activeTextureLastTime,
              let eventClass = activeTextureClass
        else { return nil }
        let duration = max(0.16, last - start + Double(hopSize) / max(sampleRate ?? 1, 1))
        var curve = activeTexturePoints
            .map {
                MusicHapticsCurvePoint(
                    timeOffset: min(duration, max(0, $0.timeOffset)),
                    intensity: $0.intensity,
                    sharpness: $0.sharpness
                )
            }
            .sorted { $0.timeOffset < $1.timeOffset }
        if curve.first?.timeOffset != 0 {
            curve.insert(MusicHapticsCurvePoint(timeOffset: 0, intensity: activeTexturePeak * 0.72, sharpness: activeTextureSharpness), at: 0)
        }
        if curve.last?.timeOffset != duration {
            curve.append(MusicHapticsCurvePoint(timeOffset: duration, intensity: activeTexturePeak * 0.76, sharpness: activeTextureSharpness))
        }
        return MusicHapticsEvent(
            time: start,
            duration: duration,
            intensity: activeTexturePeak,
            sharpness: activeTextureSharpness,
            kind: .continuous,
            classification: eventClass,
            curve: curve
        )
    }

    private mutating func finishTexture() -> MusicHapticsEvent? {
        let event = textureSnapshot()
        activeTextureStart = nil
        activeTextureLastTime = nil
        activeTextureClass = nil
        activeTexturePeak = 0
        activeTextureSharpness = 0
        activeTexturePoints.removeAll(keepingCapacity: true)
        activeTextureLastSnapshotTime = nil
        return event
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
        beat: MusicHapticsBeatEstimate
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

    private func adaptiveThreshold(_ values: [Float], multiplier: Float, floor: Float) -> Float {
        guard !values.isEmpty else { return floor }
        let middle = median(values)
        let deviations = values.map { abs($0 - middle) }
        let mad = median(deviations)
        return max(floor, middle + multiplier * max(mad, 0.000001))
    }

    private func percentile(_ values: [Float], percentile: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        return percentileOfSorted(values.sorted(), percentile: percentile)
    }

    private func percentileOfSorted(_ sorted: [Float], percentile: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        return sorted[index]
    }

    private func smoothstep(edge0: Float, edge1: Float, value: Float) -> Float {
        guard edge1 > edge0 + 0.0001 else { return 0.5 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    func historyLimit(sampleRate: Double) -> Int {
        let analyzedHop = Double(hopSize) * Double(configuration.fftFrameStride)
        return max(32, Int(sampleRate / max(1, analyzedHop) * configuration.adaptiveWindowSeconds))
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

}

/// Event thinning keeps continuous texture curves class-aware, but transient
/// collisions are always collapsed across classes. The final timeline must
/// preserve the same one-transient voice budget as the streaming mixer.
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
        return collapseTransientCollisions(result)
    }

    private static func collapseTransientCollisions(
        _ input: [MusicHapticsEvent]
    ) -> [MusicHapticsEvent] {
        let sorted = input.sorted { $0.time < $1.time }
        var result: [MusicHapticsEvent] = []
        var cluster: [MusicHapticsEvent] = []

        func flushCluster() {
            guard !cluster.isEmpty else { return }
            if let fused = fusedTransientEventForDeduplication(cluster) {
                result.append(fused)
            }
            cluster.removeAll(keepingCapacity: true)
        }

        for event in sorted {
            guard event.kind == .transient else {
                result.append(event)
                continue
            }
            if let first = cluster.first,
               event.time - first.time <= 0.070 {
                cluster.append(event)
            } else {
                flushCluster()
                cluster = [event]
            }
        }
        flushCluster()
        return result.sorted { $0.time < $1.time }
    }

    private static func fusedTransientEventForDeduplication(
        _ cluster: [MusicHapticsEvent]
    ) -> MusicHapticsEvent? {
        let realCandidates = cluster.filter { $0.classification != .climax }
        guard let dominant = realCandidates.max(by: {
            deduplicationScore($0) < deduplicationScore($1)
        }) else { return nil }
        let supports = realCandidates.filter { $0 != dominant }
        let modifiers = cluster.filter { $0.classification == .climax }
        return fusedTransientEvent(
            dominant: dominant,
            supports: supports,
            climaxModifiers: modifiers
        )
    }

    private static func deduplicationScore(_ event: MusicHapticsEvent) -> Float {
        transientScore(event)
    }
}
