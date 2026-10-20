// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// A beat candidate is only promoted after a stable grid has been observed.
/// This keeps a single onset, speech-like noise, or a random high hat from
/// becoming a beat by itself.
public enum MusicHapticsBeatStrength: String, Codable, Hashable, Sendable {
    case subBeat
    case normalBeat
    case strongBeat
}

public struct MusicHapticsBeatEstimate: Codable, Hashable, Sendable {
    public let isBeat: Bool
    public let strength: MusicHapticsBeatStrength
    public let confidence: Double
    public let tempoBPM: Double?
    /// Fractional phase in the current grid. Zero is the beat anchor.
    public let phase: Double?
    public let phaseAnchor: TimeInterval?
    public let nextBeatTime: TimeInterval?
    /// Normalized distance between the current observation and the nearest
    /// predicted beat. A value of zero means the observation is on-grid.
    public let phaseError: Double

    public init(
        isBeat: Bool = false,
        strength: MusicHapticsBeatStrength = .subBeat,
        confidence: Double = 0,
        tempoBPM: Double? = nil,
        phase: Double? = nil,
        phaseAnchor: TimeInterval? = nil,
        nextBeatTime: TimeInterval? = nil,
        phaseError: Double = 1
    ) {
        self.isBeat = isBeat
        self.strength = strength
        self.confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
        self.tempoBPM = tempoBPM?.isFinite == true ? tempoBPM : nil
        self.phase = phase?.isFinite == true ? phase : nil
        self.phaseAnchor = phaseAnchor?.isFinite == true ? phaseAnchor : nil
        self.nextBeatTime = nextBeatTime?.isFinite == true ? nextBeatTime : nil
        self.phaseError = min(max(phaseError.isFinite ? phaseError : 1, 0), 1)
    }
}

/// A bounded, onset-driven beat grid. Candidate periods are normalized to
/// 55...200 BPM and are held through half/double-tempo observations instead of
/// flipping between 70 and 140 BPM on every other bar.
public struct MusicHapticsBeatTracker: Sendable {
    private struct Onset: Sendable {
        let time: TimeInterval
        let energy: Float
    }

    private struct CandidateObservation: Sendable {
        let onGrid: Bool
    }

    private var onsets: [Onset] = []
    private var intervals: [TimeInterval] = []
    private var lastOnsetTime: TimeInterval = -.infinity
    private var period: TimeInterval?
    private var phaseAnchor: TimeInterval?
    private var confidence: Double = 0
    private var lastTime: TimeInterval = 0
    private var candidateHistory: [CandidateObservation] = []
    private var lowConfidenceSince: TimeInterval?
    private var lastReacquireTime: TimeInterval = -.infinity
    private var lastPromotedTime: TimeInterval = -.infinity
    private var lastHypothesisTime: TimeInterval = -.infinity
    private var multiOnsetConfidence: Double = 0

    public init() {}

    public mutating func reset() {
        onsets.removeAll(keepingCapacity: true)
        intervals.removeAll(keepingCapacity: true)
        lastOnsetTime = -.infinity
        period = nil
        phaseAnchor = nil
        confidence = 0
        lastTime = 0
        candidateHistory.removeAll(keepingCapacity: true)
        lowConfidenceSince = nil
        lastReacquireTime = -.infinity
        lastPromotedTime = -.infinity
        lastHypothesisTime = -.infinity
        multiOnsetConfidence = 0
    }

    public mutating func update(
        time: TimeInterval,
        onset: Float,
        threshold: Float,
        energy: Float
    ) -> MusicHapticsBeatEstimate {
        guard time.isFinite, time >= 0 else { return MusicHapticsBeatEstimate() }
        if time + 0.001 < lastTime || (lastOnsetTime.isFinite
            && time - lastOnsetTime > max(2, (period ?? 0.5) * 3)) {
            reset()
        }
        lastTime = time
        let safeEnergy = max(0, energy.isFinite ? energy : 0)
        let safeThreshold = max(0.0001, threshold.isFinite ? threshold : 0.0001)
        let predictedPhase = period.map { makePhaseValues(at: time, period: $0, anchor: phaseAnchor) }
        let supportedWeakBeat = confidence >= 0.65 && time - lastOnsetTime <= (period ?? 0) * 1.5
            && (predictedPhase?.error ?? 1) <= 0.10
            && onset >= safeThreshold * 0.55
        let candidate = onset.isFinite
            && (onset >= safeThreshold || supportedWeakBeat)
            && safeEnergy > 0.003
            && (!lastOnsetTime.isFinite || time - lastOnsetTime >= 0.12)

        if candidate {
            if let previous = onsets.last {
                let interval = time - previous.time
                if interval >= 0.30, interval <= 1.091 {
                    intervals.append(interval)
                    if intervals.count > 24 { intervals.removeFirst() }
                    updatePeriod(with: interval)
                } else if interval >= 0.12, interval < 0.30 {
                    // Eighth-note onsets above 200 BPM can still describe a
                    // 100 BPM grid when doubled. Do not use them as a raw beat.
                    intervals.append(interval * 2)
                    if intervals.count > 24 { intervals.removeFirst() }
                    updatePeriod(with: interval * 2)
                }
            }
            lastOnsetTime = time
            onsets.append(Onset(time: time, energy: safeEnergy))
            if onsets.count > 48 { onsets.removeFirst() }
        }

        if candidate, onsets.count >= 8, time - lastHypothesisTime >= 1,
           confidence < 0.45 || multiOnsetConfidence > 0
            || candidateHistory.suffix(8).filter({ !$0.onGrid }).count >= 3 {
            acquireFromMultipleOnsets()
            lastHypothesisTime = time
        }
        guard let period, period > 0 else {
            return MusicHapticsBeatEstimate(
                isBeat: false,
                strength: candidate ? .subBeat : .subBeat,
                confidence: 0,
                phaseError: 1
            )
        }

        let evidenceAge = max(0, time - lastOnsetTime - period * 1.25)
        let freshness = exp(-evidenceAge / max(0.15, period * 0.60))
        confidence = max(gridConfidence(for: period), multiOnsetConfidence) * freshness
        if phaseAnchor == nil, candidate, confidence >= 0.35 {
            phaseAnchor = time
        }
        var phaseValues = makePhaseValues(
            at: time,
            period: period,
            anchor: phaseAnchor
        )
        var onGrid = phaseValues.error <= 0.22
        if candidate {
            candidateHistory.append(CandidateObservation(onGrid: onGrid))
            if candidateHistory.count > 12 { candidateHistory.removeFirst() }
            if confidence < 0.30 {
                lowConfidenceSince = lowConfidenceSince ?? time
            } else {
                lowConfidenceSince = nil
            }
            if shouldReacquire(at: time), reacquirePeriod() {
                guard let reacquiredPeriod = self.period else {
                    return MusicHapticsBeatEstimate()
                }
                confidence = gridConfidence(for: reacquiredPeriod)
                phaseValues = makePhaseValues(
                    at: time,
                    period: reacquiredPeriod,
                    anchor: phaseAnchor
                )
                onGrid = phaseValues.error <= 0.22
            }
        }
        let activePeriod = self.period ?? period
        let promoted = candidate && confidence >= 0.45 && onGrid
            && time - lastPromotedTime >= activePeriod * 0.55
        if promoted, let anchor = phaseAnchor {
            lastPromotedTime = time
            // A small phase correction follows human timing/tempo drift;
            // the output event itself retains the observed attack timestamp.
            let predicted = anchor + ((time - anchor) / activePeriod).rounded() * activePeriod
            phaseAnchor = anchor + (time - predicted) * 0.12
            phaseValues = makePhaseValues(at: time, period: self.period ?? period, anchor: phaseAnchor)
        }
        let strength: MusicHapticsBeatStrength
        if promoted {
            // Compare like with like: the onset threshold includes spectral
            // flux/log attack, so comparing RMS energy to it labels nearly
            // every beat as strong. Accent relative to recent audible beats
            // instead, preserving dynamics across different mastering levels.
            let recentEnergy = onsets.dropLast().suffix(16).map(\.energy).sorted()
            let reference = recentEnergy.isEmpty ? safeEnergy : recentEnergy[recentEnergy.count / 2]
            let accented = safeEnergy > max(0.003, reference * 1.20)
            strength = accented ? .strongBeat : .normalBeat
        } else {
            strength = .subBeat
        }
        return MusicHapticsBeatEstimate(
            isBeat: promoted,
            strength: strength,
            confidence: confidence,
            tempoBPM: 60 / (self.period ?? period),
            phase: phaseValues.phase,
            phaseAnchor: phaseAnchor,
            nextBeatTime: phaseValues.next,
            phaseError: phaseValues.error
        )
    }

    /// Fallback for alternating/swing/missing-onset material. A bounded set
    /// of period/phase hypotheses votes with observed onset energy, not with
    /// a hard-coded 4/4 meter. At least five distinct supported pulses and a
    /// substantial amount of evidence are required before locking.
    private mutating func acquireFromMultipleOnsets() {
        let recent = Array(onsets.suffix(24).filter { lastTime - $0.time <= 8 })
        guard recent.count >= 8 else { return }
        var candidates: [TimeInterval] = []
        for right in recent.indices {
            for distance in 1...4 where right >= distance {
                let span = recent[right].time - recent[right - distance].time
                for count in 1...4 {
                    let value = span / Double(count)
                    if value >= 0.30, value <= 1.091,
                       !candidates.contains(where: { abs(log($0 / value)) < log(1.02) }) {
                        candidates.append(value)
                    }
                }
            }
        }
        let maxEnergy = max(0.003, recent.map(\.energy).max() ?? 0.003)
        let totalWeight = recent.reduce(0.0) { $0 + Double($1.energy / maxEnergy) }
        var best: (period: Double, anchor: Double, score: Double)?
        for candidate in candidates {
            if let current = period, confidence >= 0.65 {
                let ratio = abs(log(candidate / current))
                // Both metrical levels can fit a dense passage. Preserve a
                // confident 70 BPM interpretation when eighth notes at 140
                // arrive; extra subdivisions alone are not a tempo change.
                if abs(ratio - log(2)) < log(1.10) { continue }
            }
            for anchor in recent.suffix(8).map(\.time) {
                var weight = 0.0
                var indices: Set<Int> = []
                for onset in recent {
                    let index = ((onset.time - anchor) / candidate).rounded()
                    let error = abs(onset.time - anchor - index * candidate) / candidate
                    if error <= 0.10 {
                        weight += Double(onset.energy / maxEnergy) * (1 - error * 2)
                        indices.insert(Int(index))
                    }
                }
                guard indices.count >= 5, let first = indices.min(), let last = indices.max(),
                      last > first else { continue }
                let continuity = Double(indices.count) / Double(last - first + 1)
                let support = weight / max(0.001, totalWeight)
                guard support >= 0.62, continuity >= 0.65 else { continue }
                // Mild continuity/hysteresis avoids choosing a fast grid
                // simply because it can explain more subdivisions.
                let hysteresis = period.map { abs(log(candidate / $0)) < log(1.06) ? 0.03 : 0 } ?? 0
                let score = support * 0.8 + continuity * 0.2 + hysteresis
                if score > (best?.score ?? 0) { best = (candidate, anchor, score) }
            }
        }
        guard let best else {
            multiOnsetConfidence *= 0.65
            return
        }
        period = best.period
        phaseAnchor = best.anchor
        multiOnsetConfidence = min(0.90, best.score)
    }

    private func gridConfidence(for candidatePeriod: TimeInterval) -> Double {
        let normalizedIntervals = intervals.map {
            normalizedInterval($0, relativeTo: candidatePeriod)
        }
        let medianInterval = median(normalizedIntervals)
        let deviation = normalizedIntervals.isEmpty
            ? 1
            : normalizedIntervals.reduce(0) {
                $0 + abs($1 - medianInterval)
            } / Double(normalizedIntervals.count)
        let consistency = max(
            0,
            min(1, 1 - deviation / max(0.001, medianInterval * 0.16))
        )
        let maturity = min(1, Double(intervals.count) / 7)
        return max(0, min(1, consistency * maturity))
    }

    private func makePhaseValues(
        at time: TimeInterval,
        period: TimeInterval,
        anchor: TimeInterval?
    ) -> (phase: Double?, error: Double, next: TimeInterval?) {
        guard let anchor else { return (nil, 1, nil) }
        let relative = (time - anchor) / period
        let nearestBeatIndex = relative.rounded()
        let predicted = anchor + nearestBeatIndex * period
        let error = min(1, abs(time - predicted) / period)
        let normalized = relative - floor(relative)
        let nextIndex = max(
            nearestBeatIndex + (error < 0.005 ? 1 : 0),
            ceil(relative)
        )
        return (
            normalized >= 0 ? normalized : normalized + 1,
            error,
            anchor + nextIndex * period
        )
    }

    private func shouldReacquire(at time: TimeInterval) -> Bool {
        guard intervals.count >= 6,
              candidateHistory.count >= 6,
              time - lastReacquireTime >= 2
        else { return false }
        let offGridCount = candidateHistory.filter { !$0.onGrid }.count
        if Double(offGridCount) / Double(candidateHistory.count) >= 0.60 {
            return true
        }
        if let lowConfidenceSince,
           time - lowConfidenceSince >= 2.5 {
            return true
        }
        return false
    }

    private mutating func reacquirePeriod() -> Bool {
        let recentIntervals = Array(intervals.suffix(10))
        guard recentIntervals.count >= 6 else { return false }

        var candidates: [TimeInterval] = []
        for interval in recentIntervals {
            for value in [interval / 2, interval, interval * 2]
                where value >= 0.30 && value <= 1.091 {
                guard !candidates.contains(where: {
                    abs(log($0 / value)) < log(1.01)
                }) else { continue }
                candidates.append(value)
            }
        }
        // Pairwise spans preserve evidence when intervening hats, syncopation
        // or a missed kick make adjacent intervals misleading. Keep a bounded
        // hypothesis set; never evaluate an unbounded whole-track search.
        let times = onsets.suffix(12).map(\.time)
        for right in times.indices {
            for distance in 2...4 where right >= distance {
                let span = times[right] - times[right - distance]
                for beats in 1...4 {
                    let value = span / Double(beats)
                    if value >= 0.30, value <= 1.091,
                       !candidates.contains(where: { abs(log($0 / value)) < log(1.01) }) {
                        candidates.append(value)
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return false }

        func score(_ candidate: TimeInterval) -> (
            support: Int,
            residual: Double,
            directResidual: Double
        ) {
            let residuals = recentIntervals.map {
                intervalResidual($0, relativeTo: candidate)
            }
            let support = residuals.filter { $0 <= log(1.16) }.count
            let mean = residuals.reduce(0, +) / Double(residuals.count)
            let medianRawInterval = median(recentIntervals)
            return (
                support,
                mean,
                abs(log(medianRawInterval / candidate))
            )
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let left = score(lhs)
            let right = score(rhs)
            if left.support != right.support {
                return left.support < right.support
            }
            if abs(left.residual - right.residual) > 0.0001 {
                return left.residual > right.residual
            }
            return left.directResidual > right.directResidual
        }) else { return false }
        let bestScore = score(best)
        guard bestScore.support >= Int(ceil(Double(recentIntervals.count) * 0.60)) else {
            return false
        }
        if let current = period {
            let currentScore = score(current)
            let materiallyBetter = bestScore.support > currentScore.support
                || bestScore.residual + 0.05 < currentScore.residual
            guard abs(log(best / current)) > log(1.03), materiallyBetter else {
                return false
            }
        }

        period = best
        intervals = recentIntervals.filter {
            intervalResidual($0, relativeTo: best) <= log(1.16)
        }
        let recentOnsetTimes = onsets.suffix(12).map(\.time)
        phaseAnchor = recentOnsetTimes.min {
            phaseResidual(anchor: $0, times: recentOnsetTimes, period: best)
                < phaseResidual(anchor: $1, times: recentOnsetTimes, period: best)
        }
        confidence = gridConfidence(for: best)
        lastReacquireTime = lastTime
        candidateHistory.removeAll(keepingCapacity: true)
        lowConfidenceSince = nil
        return true
    }

    private func intervalResidual(
        _ interval: TimeInterval,
        relativeTo candidatePeriod: TimeInterval
    ) -> Double {
        let options = [interval / 2, interval, interval * 2]
            .filter { $0 >= 0.30 && $0 <= 1.091 }
        return options.map { abs(log($0 / candidatePeriod)) }.min() ?? .infinity
    }

    private func phaseResidual(
        anchor: TimeInterval,
        times: [TimeInterval],
        period: TimeInterval
    ) -> Double {
        guard !times.isEmpty else { return .infinity }
        return times.reduce(0) { partial, time in
            let relative = (time - anchor) / period
            return partial + abs(relative - relative.rounded())
        } / Double(times.count)
    }

    public var currentEstimate: MusicHapticsBeatEstimate {
        guard let period else { return MusicHapticsBeatEstimate(confidence: confidence) }
        let relative = phaseAnchor.map { (lastTime - $0) / period }
        let phase = relative.map { value in
            let normalized = value - floor(value)
            return normalized >= 0 ? normalized : normalized + 1
        }
        let next = phaseAnchor.map { anchor in
            anchor + ceil((lastTime - anchor) / period + 0.0001) * period
        }
        return MusicHapticsBeatEstimate(
            confidence: confidence,
            tempoBPM: 60 / period,
            phase: phase,
            phaseAnchor: phaseAnchor,
            nextBeatTime: next,
            phaseError: 1
        )
    }

    private mutating func updatePeriod(with rawInterval: TimeInterval) {
        let validPeriods = [rawInterval / 2, rawInterval, rawInterval * 2]
            .filter { $0 >= 0.30 && $0 <= 1.091 }
        guard !validPeriods.isEmpty else { return }

        if let current = period {
            // Prefer the existing phase grid. This is the half/double tempo
            // hysteresis that keeps a 70/140 BPM passage stable.
            let selected = validPeriods.min {
                abs(log($0 / current)) < abs(log($1 / current))
            } ?? current
            if abs(log(selected / current)) <= log(1.12) {
                period = current * 0.82 + selected * 0.18
            } else {
                period = current
            }
        } else {
            period = min(max(rawInterval, 0.30), 1.091)
        }
    }

    private func normalizedInterval(_ interval: TimeInterval, relativeTo current: TimeInterval) -> TimeInterval {
        let options = [interval / 2, interval, interval * 2]
            .filter { $0 >= 0.30 && $0 <= 1.091 }
        guard let closest = options.min(by: { abs(log($0 / current)) < abs(log($1 / current)) }) else {
            return interval
        }
        return closest
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return period ?? 0.5 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

public struct MusicHapticsCandidateFrame: Hashable, Sendable {
    public let time: TimeInterval
    public let events: [MusicHapticsEvent]
    public let energyLevel: Float
    public let slowEnergy: Float
    public let onsetActivity: Float
    public let beat: MusicHapticsBeatEstimate
    public let isQuiet: Bool

    public init(
        time: TimeInterval,
        events: [MusicHapticsEvent],
        energyLevel: Float = 0,
        slowEnergy: Float = 0,
        onsetActivity: Float = 0,
        beat: MusicHapticsBeatEstimate = .init(),
        isQuiet: Bool = false
    ) {
        self.time = max(0, time.isFinite ? time : 0)
        self.events = events
        self.energyLevel = min(max(energyLevel.isFinite ? energyLevel : 0, 0), 1)
        self.slowEnergy = min(max(slowEnergy.isFinite ? slowEnergy : 0, 0), 1)
        self.onsetActivity = min(max(onsetActivity.isFinite ? onsetActivity : 0, 0), 1)
        self.beat = beat
        self.isQuiet = isQuiet
    }
}

/// A collision has one musical-detail voice plus one observed-pulse voice,
/// alongside the independent continuous texture. Adding the pulse must not
/// replace the detail voice; duplicate observations still share one voice.
public struct HapticVoiceBudget: Hashable, Sendable {
    public let collisionWindow: TimeInterval
    public let maxTransientVoices: Int = 2
    public let maxContinuousVoices: Int

    public init(
        collisionWindow: TimeInterval = 0.070,
        maxContinuousVoices: Int = 1
    ) {
        self.collisionWindow = min(max(collisionWindow, 0.050), 0.080)
        self.maxContinuousVoices = min(1, max(0, maxContinuousVoices))
    }
}

public struct MusicHapticsMixerDiagnostics: Hashable, Sendable {
    public var pulseCandidateCount = 0
    public var pulseOutputCount = 0
    public var dominantTransientCount: Int
    public var suppressedTransientCount: Int
    public var suppressedHighPercussionCount: Int
    public var mergedCollisionCount: Int
    public var activeTextureType: MusicHapticsEventClass?
    public var continuousDutyCycle: Double
    public var perceptualEventsPerSecond: Double
    public var fatigueGain: Double
    public var beatGridConfidence: Double
    public var beatGridBPM: Double?
    public var beatPhaseError: Double

    public init(
        dominantTransientCount: Int = 0,
        suppressedTransientCount: Int = 0,
        suppressedHighPercussionCount: Int = 0,
        mergedCollisionCount: Int = 0,
        activeTextureType: MusicHapticsEventClass? = nil,
        continuousDutyCycle: Double = 0,
        perceptualEventsPerSecond: Double = 0,
        fatigueGain: Double = 1,
        beatGridConfidence: Double = 0,
        beatGridBPM: Double? = nil,
        beatPhaseError: Double = 1
    ) {
        self.dominantTransientCount = max(0, dominantTransientCount)
        self.suppressedTransientCount = max(0, suppressedTransientCount)
        self.suppressedHighPercussionCount = max(0, suppressedHighPercussionCount)
        self.mergedCollisionCount = max(0, mergedCollisionCount)
        self.activeTextureType = activeTextureType
        self.continuousDutyCycle = min(max(continuousDutyCycle, 0), 1)
        self.perceptualEventsPerSecond = max(0, perceptualEventsPerSecond)
        self.fatigueGain = min(max(fatigueGain, 0), 1)
        self.beatGridConfidence = min(max(beatGridConfidence, 0), 1)
        self.beatGridBPM = beatGridBPM
        self.beatPhaseError = min(max(beatPhaseError, 0), 1)
    }
}

public struct MusicHapticsMixerResult: Hashable, Sendable {
    public let events: [MusicHapticsEvent]
    public let diagnostics: MusicHapticsMixerDiagnostics

    public init(events: [MusicHapticsEvent], diagnostics: MusicHapticsMixerDiagnostics) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

/// Stateful perceptual mixing sits between DSP candidates and the final
/// haptic event stream. It owns bounded history, composes pulse/detail voices,
/// and keeps the continuous texture envelope independent of added pulses.
public struct MusicHapticsPerceptualMixer: Sendable {
    private struct PendingTransientCluster: Sendable {
        let firstTime: TimeInterval
        var candidates: [MusicHapticsEvent]
        var frame: MusicHapticsCandidateFrame
    }

    private struct TextureAccumulator: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var eventClass: MusicHapticsEventClass
        var peakIntensity: Float
        var sharpness: Float
        var points: [MusicHapticsCurvePoint]
        var emittedEnd: TimeInterval
        /// The last materialized point is part of the output contract. Future
        /// snapshots may refine the curve behind this boundary, but they must
        /// start from the value already handed to Core Haptics.
        var lastEmittedPoint: MusicHapticsCurvePoint?

        init(_ event: MusicHapticsEvent) {
            let eventStart = event.time
            let eventEnd = event.time + (event.duration ?? 0.20)
            let eventClass = event.classification
            let eventIntensity = event.intensity
            let eventSharpness = event.sharpness
            start = eventStart
            end = eventEnd
            self.eventClass = eventClass
            peakIntensity = eventIntensity
            sharpness = eventSharpness
            emittedEnd = eventStart
            let mappedPoints = event.curve.map {
                MusicHapticsCurvePoint(
                    timeOffset: event.time - eventStart + $0.timeOffset,
                    intensity: $0.intensity,
                    sharpness: $0.sharpness
                )
            }
            points = mappedPoints.isEmpty
                ? [MusicHapticsCurvePoint(timeOffset: 0, intensity: eventIntensity, sharpness: eventSharpness)]
                : mappedPoints
            lastEmittedPoint = nil
        }

        mutating func absorb(_ event: MusicHapticsEvent) {
            let newEnd = event.time + (event.duration ?? 0.20)
            end = max(end, newEnd)
            peakIntensity = max(peakIntensity, event.intensity)
            sharpness = max(sharpness, event.sharpness)
            if texturePriority(event.classification) > texturePriority(eventClass) {
                eventClass = event.classification
            }
            let incoming = event.curve.isEmpty
                ? [MusicHapticsCurvePoint(timeOffset: event.time - start, intensity: event.intensity, sharpness: event.sharpness)]
                : event.curve.map {
                    MusicHapticsCurvePoint(
                        timeOffset: event.time - start + $0.timeOffset,
                        intensity: $0.intensity,
                        sharpness: $0.sharpness
                    )
            }
            for point in incoming {
                if let index = points.firstIndex(where: {
                    abs($0.timeOffset - point.timeOffset) <= 0.008
                }) {
                    points[index] = point
                } else {
                    points.append(point)
                }
            }
            points.sort { $0.timeOffset < $1.timeOffset }
            if points.count > 128 {
                points = Self.downsampleCurve(points, limit: 128)
            }
        }

        mutating func materialize(
            minimumDuration: TimeInterval,
            force: Bool,
            fatigueGain: Float
        ) -> MusicHapticsEvent? {
            let available = end - emittedEnd
            guard force || available >= minimumDuration else { return nil }
            let segmentEnd = max(emittedEnd, end)
            guard segmentEnd - emittedEnd >= 0.02 else { return nil }
            let result = segment(
                from: emittedEnd,
                to: segmentEnd,
                fatigueGain: fatigueGain,
                boundary: lastEmittedPoint
            )
            emittedEnd = segmentEnd
            lastEmittedPoint = result.curve.last
            return result
        }

        private func segment(
            from lowerBound: TimeInterval,
            to upperBound: TimeInterval,
            fatigueGain: Float,
            boundary: MusicHapticsCurvePoint?
        ) -> MusicHapticsEvent {
            let segmentStart = min(max(lowerBound, start), end)
            let segmentEnd = min(max(upperBound, segmentStart), end)
            let duration = max(0.02, segmentEnd - segmentStart)
            let lowerOffset = max(0, segmentStart - start)
            let upperOffset = max(lowerOffset, segmentEnd - start)
            let startPoint = boundary.map {
                MusicHapticsCurvePoint(
                    timeOffset: lowerOffset,
                    intensity: $0.intensity,
                    sharpness: $0.sharpness
                )
            } ?? point(at: lowerOffset)
            let endPoint = point(at: upperOffset)
            let interior = points.filter {
                $0.timeOffset > lowerOffset + 0.0005
                    && $0.timeOffset < upperOffset - 0.0005
            }
            var normalized = ([startPoint] + interior + [endPoint]).map {
                MusicHapticsCurvePoint(
                    timeOffset: min(duration, max(0, $0.timeOffset - lowerOffset)),
                    intensity: min(1, max(0, $0.intensity * fatigueGain)),
                    sharpness: $0.sharpness
                )
            }
            if let boundary, !normalized.isEmpty {
                normalized[0] = MusicHapticsCurvePoint(
                    timeOffset: 0,
                    intensity: boundary.intensity,
                    sharpness: boundary.sharpness
                )
            }
            normalized.sort { $0.timeOffset < $1.timeOffset }
            var unique: [MusicHapticsCurvePoint] = []
            for point in normalized {
                if let last = unique.last,
                   abs(last.timeOffset - point.timeOffset) <= 0.0005 {
                    unique[unique.count - 1] = point
                } else {
                    unique.append(point)
                }
            }
            if unique.count >= 2 {
                let lastIndex = unique.count - 1
                unique[lastIndex] = limitedTransition(
                    from: unique[0],
                    to: unique[lastIndex],
                    timeOffset: unique[lastIndex].timeOffset
                )
            }
            let segmentIntensity = unique.map(\.intensity).max() ?? peakIntensity
            let segmentSharpness = unique.map(\.sharpness).max() ?? sharpness
            return MusicHapticsEvent(
                time: segmentStart,
                duration: duration,
                intensity: min(1, max(0, segmentIntensity)),
                sharpness: segmentSharpness,
                kind: .continuous,
                classification: eventClass,
                curve: unique,
                rhythm: .init(role: .texture, confidence: 1)
            )
        }

        private func limitedTransition(
            from start: MusicHapticsCurvePoint,
            to end: MusicHapticsCurvePoint,
            timeOffset: TimeInterval
        ) -> MusicHapticsCurvePoint {
            let maximumIntensityDelta: Float = 0.14
            let maximumSharpnessDelta: Float = 0.16
            let intensity = start.intensity + min(
                maximumIntensityDelta,
                max(-maximumIntensityDelta, end.intensity - start.intensity)
            )
            let sharpness = start.sharpness + min(
                maximumSharpnessDelta,
                max(-maximumSharpnessDelta, end.sharpness - start.sharpness)
            )
            return MusicHapticsCurvePoint(
                timeOffset: timeOffset,
                intensity: intensity,
                sharpness: sharpness
            )
        }

        private func point(at offset: TimeInterval) -> MusicHapticsCurvePoint {
            guard !points.isEmpty else {
                return MusicHapticsCurvePoint(
                    timeOffset: offset,
                    intensity: peakIntensity,
                    sharpness: sharpness
                )
            }
            let sorted = points.sorted { $0.timeOffset < $1.timeOffset }
            if offset <= sorted[0].timeOffset {
                return MusicHapticsCurvePoint(
                    timeOffset: offset,
                    intensity: sorted[0].intensity,
                    sharpness: sorted[0].sharpness
                )
            }
            for pair in zip(sorted, sorted.dropFirst()) {
                let (lower, upper) = pair
                guard offset <= upper.timeOffset else { continue }
                let span = max(0.0001, upper.timeOffset - lower.timeOffset)
                let fraction = min(1, max(0, (offset - lower.timeOffset) / span))
                return MusicHapticsCurvePoint(
                    timeOffset: offset,
                    intensity: lower.intensity + (upper.intensity - lower.intensity) * Float(fraction),
                    sharpness: lower.sharpness + (upper.sharpness - lower.sharpness) * Float(fraction)
                )
            }
            let last = sorted[sorted.count - 1]
            return MusicHapticsCurvePoint(
                timeOffset: offset,
                intensity: last.intensity,
                sharpness: last.sharpness
            )
        }

        private static func downsampleCurve(
            _ points: [MusicHapticsCurvePoint],
            limit: Int
        ) -> [MusicHapticsCurvePoint] {
            guard points.count > limit, limit > 1 else { return points }
            return (0..<limit).map { index in
                let sourceIndex = Int((Double(index) * Double(points.count - 1) / Double(limit - 1)).rounded())
                return points[min(points.count - 1, max(0, sourceIndex))]
            }
        }
    }

    public let voiceBudget: HapticVoiceBudget
    private var activeTexture: TextureAccumulator?
    private var pendingTransientCluster: PendingTransientCluster?
    private var recentOutput: [MusicHapticsEvent] = []
    private var acceptedDetailTimes: [TimeInterval] = []
    private var lastHighPercussionTime: TimeInterval = -.infinity
    private var totalDominant = 0
    private var totalPulseCandidates = 0
    private var totalPulseOutput = 0
    private var totalSuppressedTransient = 0
    private var totalSuppressedHighPercussion = 0
    private var totalMergedCollisions = 0
    private var lastBeat = MusicHapticsBeatEstimate()
    private var lastDiagnostics = MusicHapticsMixerDiagnostics()
    /// Short-term controls are intentionally separate from the 15-second
    /// fatigue history. The former follows the current musical section; the
    /// latter only prevents prolonged tactile fatigue.
    private var macroEnergy: Float = 0
    private var transientDensityRate: Double = 0.8
    private var quietGain: Float = 1
    private var quietMode = false
    private var lastControlTime: TimeInterval = -.infinity
    private let progressiveTextureCommitInterval: TimeInterval = 0.25
    private let shortDensityWindow: TimeInterval = 2

    public init(voiceBudget: HapticVoiceBudget = .init()) {
        self.voiceBudget = voiceBudget
    }

    public var diagnostics: MusicHapticsMixerDiagnostics { lastDiagnostics }

    public mutating func reset() {
        activeTexture = nil
        pendingTransientCluster = nil
        recentOutput.removeAll(keepingCapacity: true)
        acceptedDetailTimes.removeAll(keepingCapacity: true)
        lastHighPercussionTime = -.infinity
        totalDominant = 0
        totalPulseCandidates = 0
        totalPulseOutput = 0
        totalSuppressedTransient = 0
        totalSuppressedHighPercussion = 0
        totalMergedCollisions = 0
        lastBeat = MusicHapticsBeatEstimate()
        lastDiagnostics = MusicHapticsMixerDiagnostics()
        macroEnergy = 0
        transientDensityRate = 0.8
        quietGain = 1
        quietMode = false
        lastControlTime = -.infinity
    }

    public mutating func mix(frames: [MusicHapticsCandidateFrame]) -> MusicHapticsMixerResult {
        guard !frames.isEmpty else { return MusicHapticsMixerResult(events: [], diagnostics: diagnostics) }
        var output: [MusicHapticsEvent] = []
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            lastBeat = frame.beat
            updatePerceptualControls(for: frame)
            pruneHistory(at: frame.time)
            let transientCandidates = frame.events.filter { $0.kind == .transient }
            flushPendingTransientCluster(before: frame.time, output: &output)
            enqueueTransients(transientCandidates, frame: frame, output: &output)
            for event in frame.events where event.kind == .continuous {
                consumeTexture(event, output: &output)
            }
        }
        // A transient is held for one collision window so adjacent DSP frames
        // share the same bounded pulse/detail composition. Texture sections remain a
        // single logical accumulator, but materialize non-overlapping suffixes
        // progressively instead of waiting for section close.
        let resultEvents = output.sorted { $0.time < $1.time }
        appendHistory(resultEvents)
        let diagnostics = makeDiagnostics(at: frames.last?.time ?? 0)
        return MusicHapticsMixerResult(events: resultEvents, diagnostics: diagnostics)
    }

    /// Keeps the fast musical response and the long fatigue response on
    /// separate time scales. A short loud passage can therefore raise the
    /// tactile density smoothly, while a return to a quiet verse is allowed
    /// to recover without waiting for a 15-second history to expire.
    private mutating func updatePerceptualControls(for frame: MusicHapticsCandidateFrame) {
        let time = frame.time
        let delta: TimeInterval
        if lastControlTime.isFinite {
            delta = min(0.5, max(0.005, time - lastControlTime))
        } else {
            delta = 0.02
        }
        lastControlTime = time

        let rawMacroEnergy = min(
            1,
            max(
                0,
                frame.energyLevel * 0.58
                    + max(frame.slowEnergy, frame.energyLevel * 0.42) * 0.42
            )
        )
        let macroTimeConstant = rawMacroEnergy >= macroEnergy ? 0.45 : 1.35
        macroEnergy = Float(approach(
            Double(macroEnergy),
            target: Double(rawMacroEnergy),
            delta: delta,
            timeConstant: macroTimeConstant
        ))

        let energyRate = targetTransientRate(for: macroEnergy)
        let beatMultiplier: Double
        if frame.beat.isBeat {
            beatMultiplier = switch frame.beat.strength {
            case .strongBeat: 1.12
            case .normalBeat: 1.05
            case .subBeat: 0.96
            }
        } else {
            beatMultiplier = 1
        }
        let activityMultiplier = 1 + Double(frame.onsetActivity) * 0.06
        let targetDensity = min(5.4, energyRate * beatMultiplier * activityMultiplier)
        let densityTimeConstant = targetDensity >= transientDensityRate ? 0.55 : 1.6
        transientDensityRate = approach(
            transientDensityRate,
            target: targetDensity,
            delta: delta,
            timeConstant: densityTimeConstant
        )

        let entersQuiet = frame.isQuiet
            && macroEnergy < 0.18
            && frame.onsetActivity < 0.35
        let exitsQuiet = !frame.isQuiet
            || macroEnergy > 0.28
            || frame.onsetActivity > 0.45
            || frame.beat.strength == .strongBeat
        if quietMode {
            if exitsQuiet { quietMode = false }
        } else if entersQuiet {
            quietMode = true
        }
        let targetQuietGain: Float = quietMode ? 0.55 : 1
        let quietTimeConstant: TimeInterval = targetQuietGain < quietGain ? 0.45 : 0.30
        quietGain = Float(approach(
            Double(quietGain),
            target: Double(targetQuietGain),
            delta: delta,
            timeConstant: quietTimeConstant
        ))
    }

    private func approach(
        _ current: Double,
        target: Double,
        delta: TimeInterval,
        timeConstant: TimeInterval
    ) -> Double {
        let alpha = 1 - exp(-delta / max(0.001, timeConstant))
        return current + (target - current) * alpha
    }

    private func targetTransientRate(for energy: Float) -> Double {
        let value = min(1, max(0, Double(energy)))
        // Approximately 0.8, 1.8, 2.5, 3.6, 4.8 and 5.2 events/s at
        // energy 0, .2, .4, .6, .8 and 1.0 respectively.
        return 0.8 + 5.0 * value - 0.6 * value * value
    }

    /// Convenience entry point for callers that already have a single DSP
    /// batch. It keeps the same stateful texture semantics as `mix(frames:)`.
    public mutating func mix(
        events: [MusicHapticsEvent],
        time: TimeInterval = 0,
        energyLevel: Float = 0,
        slowEnergy: Float = 0,
        onsetActivity: Float = 0,
        beat: MusicHapticsBeatEstimate = .init(),
        isQuiet: Bool = false
    ) -> MusicHapticsMixerResult {
        mix(frames: [MusicHapticsCandidateFrame(
            time: time,
            events: events,
            energyLevel: energyLevel,
            slowEnergy: slowEnergy,
            onsetActivity: onsetActivity,
            beat: beat,
            isQuiet: isQuiet
        )])
    }

    public mutating func finish() -> MusicHapticsMixerResult {
        var output: [MusicHapticsEvent] = []
        flushPendingTransientCluster(before: .infinity, output: &output)
        if let activeTexture {
            var activeTexture = activeTexture
            if let segment = activeTexture.materialize(
                minimumDuration: progressiveTextureCommitInterval,
                force: true,
                fatigueGain: Float(fatigue(at: activeTexture.end)) * quietGain
            ) {
                output.append(segment)
            }
            self.activeTexture = nil
        }
        appendHistory(output)
        let diagnostics = makeDiagnostics(at: output.map(\.time).max() ?? 0)
        return MusicHapticsMixerResult(events: output.sorted { $0.time < $1.time }, diagnostics: diagnostics)
    }

    private mutating func enqueueTransients(
        _ candidates: [MusicHapticsEvent],
        frame: MusicHapticsCandidateFrame,
        output: inout [MusicHapticsEvent]
    ) {
        for candidate in candidates.sorted(by: { $0.time < $1.time }) {
            var event = candidate
            // Compatibility callers supply beat context separately. Production
            // DSP already attaches it to the exact localized attack.
            if event.rhythm == nil, abs(event.time - frame.time) <= 0.035 {
                event.rhythm = MusicHapticsRhythm.observed(beat: frame.beat, time: event.time)
            }
            if event.isRhythmicPulse { totalPulseCandidates += 1 }
            if var pendingTransientCluster,
               event.time - pendingTransientCluster.firstTime <= voiceBudget.collisionWindow {
                pendingTransientCluster.candidates.append(event)
                pendingTransientCluster.frame = mergedFrame(
                    pendingTransientCluster.frame,
                    with: frame
                )
                self.pendingTransientCluster = pendingTransientCluster
            } else {
                flushPendingTransientCluster(before: event.time, output: &output)
                pendingTransientCluster = PendingTransientCluster(
                    firstTime: event.time,
                    candidates: [event],
                    frame: frame
                )
            }
        }
    }

    private mutating func flushPendingTransientCluster(
        before time: TimeInterval,
        output: inout [MusicHapticsEvent]
    ) {
        guard let pendingTransientCluster,
              time - pendingTransientCluster.firstTime > voiceBudget.collisionWindow
                || !time.isFinite
        else { return }
        self.pendingTransientCluster = nil
        resolveTransients(
            pendingTransientCluster.candidates,
            frame: pendingTransientCluster.frame,
            output: &output
        )
    }

    private func mergedFrame(
        _ first: MusicHapticsCandidateFrame,
        with second: MusicHapticsCandidateFrame
    ) -> MusicHapticsCandidateFrame {
        MusicHapticsCandidateFrame(
            time: second.time,
            events: [],
            energyLevel: max(first.energyLevel, second.energyLevel),
            slowEnergy: max(first.slowEnergy, second.slowEnergy),
            onsetActivity: max(first.onsetActivity, second.onsetActivity),
            beat: first.beat.isBeat && !second.beat.isBeat ? first.beat : second.beat,
            isQuiet: first.isQuiet && second.isQuiet
        )
    }

    private mutating func resolveTransients(
        _ candidates: [MusicHapticsEvent],
        frame: MusicHapticsCandidateFrame,
        output: inout [MusicHapticsEvent]
    ) {
        guard !candidates.isEmpty else { return }
        var clusters: [[MusicHapticsEvent]] = []
        for event in candidates.sorted(by: { $0.time < $1.time }) {
            if let index = clusters.indices.last,
               event.time - clusters[index][0].time <= voiceBudget.collisionWindow {
                clusters[index].append(event)
            } else {
                clusters.append([event])
            }
        }
        for cluster in clusters {
            let modifiers = cluster.filter { $0.classification == .climax }
            var realCandidates = cluster.filter { $0.classification != .climax }
            if quietMode {
                let before = realCandidates.count
                let highPercussionBefore = realCandidates.filter { $0.classification == .highPercussion }.count
                let quietNoiseFloor = 0.20 + 0.12 * quietGain
                realCandidates.removeAll {
                    !$0.isRhythmicPulse && ($0.classification == .highPercussion || $0.classification == .unknown)
                        && $0.intensity < quietNoiseFloor
                }
                totalSuppressedTransient += before - realCandidates.count
                totalSuppressedHighPercussion += highPercussionBefore - realCandidates.filter { $0.classification == .highPercussion }.count
            }
            let selectedEvents = layeredTransientEvents(realCandidates + modifiers, beat: frame.beat)
            totalMergedCollisions += max(0, realCandidates.count - selectedEvents.count)
            totalSuppressedTransient += max(0, realCandidates.count - selectedEvents.count)
            for var selected in selectedEvents {
                pruneDetailTimes(at: selected.time)
                if shouldSuppressForDensity(selected, beat: frame.beat)
                    || (selected.classification == .highPercussion && !selected.isRhythmicPulse
                        && selected.time - lastHighPercussionTime < highPercussionSpacing(energyLevel: frame.energyLevel)) {
                    totalSuppressedTransient += 1
                    if selected.classification == .highPercussion { totalSuppressedHighPercussion += 1 }
                    continue
                }
                // The added pulse has its own bounded lane. It must not consume
                // the pre-existing detail rate, spacing or fatigue allowance.
                let fatigueGain = selected.classification == .highPercussion && !selected.isRhythmicPulse
                    ? Float(fatigue(at: selected.time)) : 1
                let quietAttenuation: Float = !selected.isRhythmicPulse
                    && (selected.classification == .highPercussion || selected.classification == .unknown)
                    ? quietGain : 1
                selected = attenuate(selected, factor: fatigueGain * quietAttenuation)
                output.append(selected)
                if selected.isRhythmicPulse {
                    totalPulseOutput += 1
                } else {
                    acceptedDetailTimes.append(selected.time)
                    if selected.classification == .highPercussion { lastHighPercussionTime = selected.time }
                }
                totalDominant += 1
            }
        }
    }

    private mutating func consumeTexture(
        _ event: MusicHapticsEvent,
        output: inout [MusicHapticsEvent]
    ) {
        guard voiceBudget.maxContinuousVoices > 0 else { return }
        if let activeTexture {
            if event.time >= activeTexture.start + 8 {
                var activeTexture = activeTexture
                if let segment = activeTexture.materialize(
                    minimumDuration: progressiveTextureCommitInterval,
                    force: true,
                    fatigueGain: Float(fatigue(at: activeTexture.end)) * quietGain
                ) {
                    output.append(segment)
                }
                self.activeTexture = nil
            }
        }
        if let activeTexture {
            let activeEnd = activeTexture.end
            if event.time <= activeEnd + 0.16 {
                var merged = activeTexture
                merged.absorb(event)
                if let segment = merged.materialize(
                    minimumDuration: progressiveTextureCommitInterval,
                    force: false,
                    fatigueGain: Float(fatigue(at: event.time)) * quietGain
                ) {
                    output.append(segment)
                }
                self.activeTexture = merged
                totalMergedCollisions += 1
                return
            }
            var activeTexture = activeTexture
            if let segment = activeTexture.materialize(
                minimumDuration: progressiveTextureCommitInterval,
                force: true,
                fatigueGain: Float(fatigue(at: activeTexture.end)) * quietGain
            ) {
                output.append(segment)
            }
            self.activeTexture = nil
        }
        var newTexture = TextureAccumulator(event)
        if let segment = newTexture.materialize(
            minimumDuration: progressiveTextureCommitInterval,
            force: false,
            fatigueGain: Float(fatigue(at: event.time)) * quietGain
        ) {
            output.append(segment)
        }
        self.activeTexture = newTexture
    }

    private func attenuate(_ event: MusicHapticsEvent, factor: Float) -> MusicHapticsEvent {
        let safeFactor = min(1, max(0, factor.isFinite ? factor : 1))
        return MusicHapticsEvent(
            time: event.time,
            duration: event.duration,
            intensity: event.intensity * safeFactor,
            sharpness: event.sharpness,
            kind: event.kind,
            classification: event.classification,
            climaxAmount: event.climaxAmount,
            curve: event.curve.map {
                MusicHapticsCurvePoint(timeOffset: $0.timeOffset, intensity: $0.intensity * safeFactor, sharpness: $0.sharpness)
            },
            rhythm: event.rhythm
        )
    }

    private func shouldSuppressForDensity(
        _ event: MusicHapticsEvent,
        beat: MusicHapticsBeatEstimate
    ) -> Bool {
        let projectedRate = Double(acceptedDetailTimes.count + 1) / shortDensityWindow
        guard projectedRate > transientDensityRate else { return false }
        return !isImportantAttack(event, beat: beat)
    }

    private func highPercussionSpacing(energyLevel: Float) -> TimeInterval {
        // Keep the high-frequency layer below the smoothed perceptual budget;
        // energyLevel remains in the signature for source compatibility and
        // documents that this is an energy-dependent guard.
        let energyBias = 0.92 + Double(min(1, max(0, energyLevel))) * 0.08
        let rate = max(0.8, transientDensityRate * energyBias)
        return 1 / rate
    }

    private func isImportantAttack(
        _ event: MusicHapticsEvent,
        beat: MusicHapticsBeatEstimate = .init()
    ) -> Bool {
        // Pulse density is protected independently of the decoration budget.
        // The tracker bounds it to 55...200 BPM; details keep their own voice.
        if event.isRhythmicPulse, event.intensity >= 0.03 { return true }
        if beat.isBeat && event.rhythm == nil {
            switch beat.strength {
            case .strongBeat:
                if event.classification != .unknown && event.intensity >= 0.42 {
                    return true
                }
            case .normalBeat:
                if event.classification != .unknown && event.intensity >= 0.62 {
                    return true
                }
            case .subBeat:
                break
            }
        }
        switch event.classification {
        case .kick, .bassAttack:
            return event.intensity >= 0.72
        case .snareClap:
            return event.intensity >= 0.86
        default:
            return false
        }
    }

    private mutating func pruneHistory(at time: TimeInterval) {
        recentOutput.removeAll { time - $0.time > 15 }
        pruneDetailTimes(at: time)
    }

    private mutating func pruneDetailTimes(at time: TimeInterval) {
        acceptedDetailTimes.removeAll { time - $0 > shortDensityWindow }
    }

    private mutating func appendHistory(_ events: [MusicHapticsEvent]) {
        recentOutput.append(contentsOf: events)
        if recentOutput.count > 512 { recentOutput.removeFirst(recentOutput.count - 512) }
    }

    private func fatigue(at time: TimeInterval) -> Double {
        let recent = recentOutput.filter { time - $0.time >= 0 && time - $0.time <= 15 }
        let transientRate = Double(recent.filter { $0.kind == .transient && !$0.isRhythmicPulse }.count) / 15
        let duty = recent
            .filter { $0.kind == .continuous }
            .reduce(0) { $0 + ($1.duration ?? 0) } / 15
        return max(0.62, 1 - min(0.38, transientRate * 0.12 + duty * 0.25))
    }

    private mutating func makeDiagnostics(at time: TimeInterval) -> MusicHapticsMixerDiagnostics {
        pruneHistory(at: time)
        let continuousDuration = recentOutput
            .filter { $0.kind == .continuous }
            .reduce(0) { $0 + ($1.duration ?? 0) }
        let activeDuration = activeTexture.map {
            max(0, min(15, min(time, $0.end) - $0.start))
        } ?? 0
        let duty = min(1, (continuousDuration + activeDuration) / 15)
        let eventRate = Double(recentOutput.filter { time - $0.time >= 0 && time - $0.time <= 5 }.count) / 5
        let gain = fatigue(at: time)
        lastDiagnostics = MusicHapticsMixerDiagnostics(
            dominantTransientCount: totalDominant,
            suppressedTransientCount: totalSuppressedTransient,
            suppressedHighPercussionCount: totalSuppressedHighPercussion,
            mergedCollisionCount: totalMergedCollisions,
            activeTextureType: activeTexture?.eventClass,
            continuousDutyCycle: duty,
            perceptualEventsPerSecond: eventRate,
            fatigueGain: gain,
            beatGridConfidence: lastBeat.confidence,
            beatGridBPM: lastBeat.tempoBPM,
            beatPhaseError: lastBeat.phaseError
        )
        lastDiagnostics.pulseCandidateCount = totalPulseCandidates
        lastDiagnostics.pulseOutputCount = totalPulseOutput
        return lastDiagnostics
    }

}

private func texturePriority(_ value: MusicHapticsEventClass) -> Int {
    switch value {
    case .buildTexture: 2
    case .sustainedBass: 1
    default: 0
    }
}

func transientScore(_ event: MusicHapticsEvent) -> Float {
    let classWeight: Float = switch event.classification {
    case .kick: 1.00
    case .bassAttack: 0.88
    case .snareClap: 0.82
    case .highPercussion: 0.42
    case .unknown: 0.25
    case .sustainedBass, .buildTexture, .climax: 0.10
    }
    return event.intensity * 0.70 + classWeight * 0.30
}

/// Preserve the original detail voice when a newly recognized pulse shares
/// its collision window. Copies of that same instrument attack are supports,
/// not another layer. Both the streaming mixer and cache merge use this rule.
func layeredTransientEvents(
    _ candidates: [MusicHapticsEvent],
    beat: MusicHapticsBeatEstimate = .init()
) -> [MusicHapticsEvent] {
    let modifiers = candidates.filter { $0.classification == .climax }
    let real = candidates.filter { $0.classification != .climax }
    let pulses = real.filter(\.isRhythmicPulse)
    guard let pulse = pulses.max(by: { transientScore($0) < transientScore($1) }) else {
        guard let dominant = real.max(by: { transientScore($0) < transientScore($1) }) else { return [] }
        return [fusedTransientEvent(dominant: dominant, supports: real.filter { $0 != dominant },
                                    climaxModifiers: modifiers, beat: beat)]
    }
    let copies = real.filter { event in
        !event.isRhythmicPulse && pulses.contains {
            $0.classification == event.classification
                && abs($0.time - event.time) < event.classification.deduplicationWindow
        }
    }
    var observedPulse = pulse
    observedPulse.intensity = max(pulse.intensity, copies.map(\.intensity).max() ?? 0)
    var result = [fusedTransientEvent(dominant: observedPulse,
        supports: pulses.filter { $0 != pulse }, climaxModifiers: modifiers, beat: beat)]
    let details = real.filter { !$0.isRhythmicPulse && !copies.contains($0) }
    if let detail = details.max(by: { transientScore($0) < transientScore($1) }) {
        result.append(fusedTransientEvent(dominant: detail, supports: details.filter { $0 != detail },
                                          climaxModifiers: []))
    }
    return result.sorted { $0.time < $1.time }
}

/// Fuses candidates within one pulse or detail lane into the dominant event.
/// Supporting attacks only contribute a bounded intensity accent and a small
/// sharpness blend; they never become another Core Haptics event.
func fusedTransientEvent(
    dominant: MusicHapticsEvent,
    supports: [MusicHapticsEvent],
    climaxModifiers: [MusicHapticsEvent],
    beat: MusicHapticsBeatEstimate = .init()
) -> MusicHapticsEvent {
    let strongestSupport = supports.max(by: { transientScore($0) < transientScore($1) })
    let supportAccent = supports
        .sorted(by: { transientScore($0) > transientScore($1) })
        .prefix(2)
        .enumerated()
        .reduce(Float(0)) { partial, item in
            let weight: Float = item.offset == 0 ? 0.08 : 0.03
            return partial + item.element.intensity * weight
        }
    let blendedSharpness: Float
    if let strongestSupport {
        blendedSharpness = dominant.sharpness * 0.78 + strongestSupport.sharpness * 0.22
    } else {
        blendedSharpness = dominant.sharpness
    }
    let climaxAmount = climaxModifiers.map {
        $0.climaxAmount > 0 ? $0.climaxAmount : $0.intensity * 0.18
    }.max() ?? dominant.climaxAmount
    let climaxIntensity = climaxAmount > 0 ? climaxAmount * 0.18 : 0
    let climaxSharpness = climaxAmount > 0 ? climaxAmount * 0.10 : 0
    let beatIntensity: Float
    if beat.isBeat {
        beatIntensity = switch beat.strength {
        case .strongBeat: 0.08
        case .normalBeat: 0.035
        case .subBeat: 0
        }
    } else {
        beatIntensity = 0
    }
    let pulse = ([dominant] + supports).filter(\.isRhythmicPulse).max {
        ($0.rhythm?.confidence ?? 0) < ($1.rhythm?.confidence ?? 0)
    }
    return MusicHapticsEvent(
        // Keep the audible pulse's time when a timbral support wins fusion.
        time: pulse?.time ?? dominant.time,
        duration: dominant.duration,
        intensity: min(1, dominant.intensity + min(0.10, supportAccent) + climaxIntensity + beatIntensity),
        sharpness: min(1, blendedSharpness + climaxSharpness),
        kind: .transient,
        classification: dominant.classification,
        climaxAmount: climaxAmount,
        curve: dominant.curve,
        rhythm: pulse?.rhythm ?? dominant.rhythm
    )
}
