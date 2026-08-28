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

    private var onsets: [Onset] = []
    private var intervals: [TimeInterval] = []
    private var lastOnsetTime: TimeInterval = -.infinity
    private var period: TimeInterval?
    private var phaseAnchor: TimeInterval?
    private var confidence: Double = 0
    private var lastTime: TimeInterval = 0

    public init() {}

    public mutating func reset() {
        onsets.removeAll(keepingCapacity: true)
        intervals.removeAll(keepingCapacity: true)
        lastOnsetTime = -.infinity
        period = nil
        phaseAnchor = nil
        confidence = 0
        lastTime = 0
    }

    public mutating func update(
        time: TimeInterval,
        onset: Float,
        threshold: Float,
        energy: Float
    ) -> MusicHapticsBeatEstimate {
        guard time.isFinite, time >= 0 else { return MusicHapticsBeatEstimate() }
        lastTime = time
        let safeEnergy = max(0, energy.isFinite ? energy : 0)
        let safeThreshold = max(0.0001, threshold.isFinite ? threshold : 0.0001)
        let candidate = onset.isFinite
            && onset >= safeThreshold
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

        guard let period, period > 0 else {
            return MusicHapticsBeatEstimate(
                isBeat: false,
                strength: candidate ? .subBeat : .subBeat,
                confidence: 0,
                phaseError: 1
            )
        }

        let normalizedIntervals = intervals.map { normalizedInterval($0, relativeTo: period) }
        let medianInterval = median(normalizedIntervals)
        let deviation = normalizedIntervals.isEmpty
            ? 1
            : normalizedIntervals.reduce(0) { $0 + abs($1 - medianInterval) } / Double(normalizedIntervals.count)
        // FFT-frame quantization and interleaved sub-beat onsets can move a
        // legitimate grid by a few frames. Keep the tolerance bounded, while
        // still leaving irregular onset sequences below the promotion gate.
        let consistency = max(0, min(1, 1 - deviation / max(0.001, medianInterval * 0.16)))
        // Six matching intervals are the minimum useful evidence for a
        // continuous grid. The seventh sample removes the early false
        // promotion seen with a handful of coincident random onsets.
        let maturity = min(1, Double(intervals.count) / 7)
        confidence = max(0, min(1, consistency * maturity))

        if phaseAnchor == nil, candidate, confidence >= 0.35 {
            phaseAnchor = time
        }
        let phaseValues: (phase: Double?, error: Double, next: TimeInterval?) = {
            guard let phaseAnchor else { return (nil, 1, nil) }
            let relative = (time - phaseAnchor) / period
            let nearestBeatIndex = relative.rounded()
            let predicted = phaseAnchor + nearestBeatIndex * period
            let error = min(1, abs(time - predicted) / period)
            let normalized = relative - floor(relative)
            let nextIndex = max(nearestBeatIndex + (error < 0.005 ? 1 : 0), ceil(relative))
            return (
                normalized >= 0 ? normalized : normalized + 1,
                error,
                phaseAnchor + nextIndex * period
            )
        }()

        let onGrid = phaseValues.error <= 0.22
        let promoted = candidate && confidence >= 0.45 && onGrid
        let latestEnergy = onsets.last?.energy ?? safeEnergy
        let strength: MusicHapticsBeatStrength
        if promoted && latestEnergy >= safeThreshold * 2.2 {
            strength = .strongBeat
        } else if promoted {
            strength = .normalBeat
        } else {
            strength = .subBeat
        }
        return MusicHapticsBeatEstimate(
            isBeat: promoted,
            strength: strength,
            confidence: confidence,
            tempoBPM: 60 / period,
            phase: phaseValues.phase,
            phaseAnchor: phaseAnchor,
            nextBeatTime: phaseValues.next,
            phaseError: phaseValues.error
        )
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

/// The perceptual budget is intentionally small. A collision can produce one
/// dominant attack and one supporting texture, but never a stack of voices.
public struct HapticVoiceBudget: Hashable, Sendable {
    public let collisionWindow: TimeInterval
    public let maxDominantTransientVoices: Int
    public let maxSupportingTextureVoices: Int

    public init(
        collisionWindow: TimeInterval = 0.070,
        maxDominantTransientVoices: Int = 1,
        maxSupportingTextureVoices: Int = 1
    ) {
        self.collisionWindow = min(max(collisionWindow, 0.050), 0.080)
        self.maxDominantTransientVoices = max(1, maxDominantTransientVoices)
        self.maxSupportingTextureVoices = max(0, maxSupportingTextureVoices)
    }
}

public struct MusicHapticsMixerDiagnostics: Hashable, Sendable {
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
/// haptic event stream. It owns only bounded history and deliberately does not
/// amplify intensity when reducing voices.
public struct MusicHapticsPerceptualMixer: Sendable {
    private struct TextureAccumulator: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var eventClass: MusicHapticsEventClass
        var peakIntensity: Float
        var sharpness: Float
        var points: [MusicHapticsCurvePoint]

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
            points.append(contentsOf: incoming)
            if points.count > 128 {
                points = Self.downsampleCurve(points, limit: 128)
            }
        }

        func event(fatigueGain: Float) -> MusicHapticsEvent {
            let duration = max(0.16, end - start)
            var normalized = points
                .map {
                    MusicHapticsCurvePoint(
                        timeOffset: min(duration, max(0, $0.timeOffset)),
                        intensity: min(1, max(0, $0.intensity * fatigueGain)),
                        sharpness: $0.sharpness
                    )
                }
                .sorted { $0.timeOffset < $1.timeOffset }
            if normalized.first?.timeOffset != 0 {
                normalized.insert(MusicHapticsCurvePoint(timeOffset: 0, intensity: peakIntensity * fatigueGain * 0.72, sharpness: sharpness), at: 0)
            }
            if normalized.last?.timeOffset != duration {
                normalized.append(MusicHapticsCurvePoint(timeOffset: duration, intensity: peakIntensity * fatigueGain * 0.76, sharpness: sharpness))
            }
            return MusicHapticsEvent(
                time: start,
                duration: duration,
                intensity: min(1, max(0, peakIntensity * fatigueGain)),
                sharpness: sharpness,
                kind: .continuous,
                classification: eventClass,
                curve: normalized
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
    private var recentOutput: [MusicHapticsEvent] = []
    private var acceptedTransientTimes: [TimeInterval] = []
    private var lastHighPercussionTime: TimeInterval = -.infinity
    private var totalDominant = 0
    private var totalSuppressedTransient = 0
    private var totalSuppressedHighPercussion = 0
    private var totalMergedCollisions = 0
    private var lastBeat = MusicHapticsBeatEstimate()
    private var lastDiagnostics = MusicHapticsMixerDiagnostics()

    public init(voiceBudget: HapticVoiceBudget = .init()) {
        self.voiceBudget = voiceBudget
    }

    public var diagnostics: MusicHapticsMixerDiagnostics { lastDiagnostics }

    public mutating func reset() {
        activeTexture = nil
        recentOutput.removeAll(keepingCapacity: true)
        acceptedTransientTimes.removeAll(keepingCapacity: true)
        lastHighPercussionTime = -.infinity
        totalDominant = 0
        totalSuppressedTransient = 0
        totalSuppressedHighPercussion = 0
        totalMergedCollisions = 0
        lastBeat = MusicHapticsBeatEstimate()
        lastDiagnostics = MusicHapticsMixerDiagnostics()
    }

    public mutating func mix(frames: [MusicHapticsCandidateFrame]) -> MusicHapticsMixerResult {
        guard !frames.isEmpty else { return MusicHapticsMixerResult(events: [], diagnostics: diagnostics) }
        var output: [MusicHapticsEvent] = []
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            lastBeat = frame.beat
            pruneHistory(at: frame.time)
            let transientCandidates = frame.events.filter { $0.kind == .transient }
            resolveTransients(transientCandidates, frame: frame, output: &output)
            for event in frame.events where event.kind == .continuous {
                consumeTexture(event, frame: frame, output: &output)
            }
        }
        // Transients are returned immediately. A texture is held until a gap
        // or finish so a sustained bass section remains one continuous event.
        let resultEvents = output.sorted { $0.time < $1.time }
        appendHistory(resultEvents)
        let diagnostics = makeDiagnostics(at: frames.last?.time ?? 0)
        return MusicHapticsMixerResult(events: resultEvents, diagnostics: diagnostics)
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
        if let activeTexture {
            output.append(activeTexture.event(fatigueGain: Float(fatigue(at: activeTexture.end))))
            self.activeTexture = nil
        }
        appendHistory(output)
        let diagnostics = makeDiagnostics(at: output.map(\.time).max() ?? 0)
        return MusicHapticsMixerResult(events: output.sorted { $0.time < $1.time }, diagnostics: diagnostics)
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
            if frame.isQuiet {
                let before = realCandidates.count
                realCandidates.removeAll {
                    ($0.classification == .highPercussion || $0.classification == .unknown)
                        && $0.intensity < 0.32
                }
                totalSuppressedTransient += before - realCandidates.count
                totalSuppressedHighPercussion += before - realCandidates.filter { $0.classification != .highPercussion }.count
            }
            guard let dominant = realCandidates.max(by: { score($0) < score($1) }) else {
                totalSuppressedTransient += cluster.count
                totalMergedCollisions += max(0, cluster.count - 1)
                continue
            }
            pruneTransientTimes(at: dominant.time)
            let targetRate = transientRateLimit(energyLevel: frame.energyLevel)
            let rateIsFull = Double(acceptedTransientTimes.count) / 15 >= targetRate
            if rateIsFull, !isImportantAttack(dominant) {
                totalSuppressedTransient += cluster.count
                if dominant.classification == .highPercussion {
                    totalSuppressedHighPercussion += 1
                }
                continue
            }
            if dominant.classification == .highPercussion,
               dominant.time - lastHighPercussionTime < highPercussionSpacing(energyLevel: frame.energyLevel) {
                totalSuppressedTransient += cluster.count
                totalSuppressedHighPercussion += 1
                continue
            }
            var selected = applyClimax(modifiers, to: dominant)
            selected = attenuate(selected, factor: dominant.classification == .highPercussion ? Float(fatigue(at: selected.time)) : 1)
            output.append(selected)
            acceptedTransientTimes.append(selected.time)
            totalDominant += 1
            if dominant.classification == .highPercussion {
                lastHighPercussionTime = dominant.time
            }

            let supporting = realCandidates
                .filter { $0 != dominant && ($0.classification == .highPercussion || $0.classification == .snareClap) }
                .max(by: { score($0) < score($1) })
            var supportingAccepted = false
            if voiceBudget.maxSupportingTextureVoices > 0, let supporting {
                if supporting.classification == .highPercussion {
                    let minimumSpacing = highPercussionSpacing(energyLevel: frame.energyLevel)
                    if supporting.time - lastHighPercussionTime >= minimumSpacing {
                        output.append(attenuate(supporting, factor: Float(fatigue(at: supporting.time) * 0.58)))
                        acceptedTransientTimes.append(supporting.time)
                        supportingAccepted = true
                        lastHighPercussionTime = supporting.time
                    } else {
                        totalSuppressedHighPercussion += 1
                    }
                } else {
                    output.append(attenuate(supporting, factor: Float(fatigue(at: supporting.time) * 0.62)))
                    acceptedTransientTimes.append(supporting.time)
                    supportingAccepted = true
                }
            }
            let accepted = 1 + (supportingAccepted ? 1 : 0)
            totalSuppressedTransient += max(0, cluster.count - accepted)
            totalMergedCollisions += max(0, cluster.count - accepted)
        }
    }

    private mutating func consumeTexture(
        _ event: MusicHapticsEvent,
        frame: MusicHapticsCandidateFrame,
        output: inout [MusicHapticsEvent]
    ) {
        if frame.isQuiet && event.classification != .sustainedBass {
            totalSuppressedTransient += 1
            return
        }
        if let activeTexture {
            if event.time >= activeTexture.start + 8 {
                output.append(activeTexture.event(fatigueGain: Float(fatigue(at: activeTexture.end))))
                self.activeTexture = nil
            }
        }
        if let activeTexture {
            let activeEnd = activeTexture.end
            if event.time <= activeEnd + 0.16 {
                var merged = activeTexture
                merged.absorb(event)
                self.activeTexture = merged
                totalMergedCollisions += 1
                return
            }
            output.append(activeTexture.event(fatigueGain: Float(fatigue(at: activeEnd))))
            self.activeTexture = nil
        }
        self.activeTexture = TextureAccumulator(event)
    }

    private func applyClimax(_ modifiers: [MusicHapticsEvent], to event: MusicHapticsEvent) -> MusicHapticsEvent {
        guard let modifier = modifiers.max(by: { $0.intensity < $1.intensity }) else { return event }
        let amount = max(0.06, modifier.climaxAmount > 0 ? modifier.climaxAmount : modifier.intensity * 0.18)
        return MusicHapticsEvent(
            time: event.time,
            duration: event.duration,
            intensity: min(1, event.intensity + amount * 0.18),
            sharpness: min(1, event.sharpness + amount * 0.10),
            kind: event.kind,
            classification: event.classification,
            climaxAmount: amount,
            curve: event.curve
        )
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
            }
        )
    }

    private func score(_ event: MusicHapticsEvent) -> Float {
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

    private func highPercussionSpacing(energyLevel: Float) -> TimeInterval {
        let rate: Double
        if energyLevel < 0.20 { rate = 1.5 }
        else if energyLevel < 0.55 { rate = 4.0 }
        else { rate = 6.0 }
        return 1 / rate
    }

    private func transientRateLimit(energyLevel: Float) -> Double {
        if energyLevel < 0.20 { return 1.5 }
        if energyLevel < 0.55 { return 4 }
        return 6
    }

    private func isImportantAttack(_ event: MusicHapticsEvent) -> Bool {
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
        pruneTransientTimes(at: time)
    }

    private mutating func pruneTransientTimes(at time: TimeInterval) {
        acceptedTransientTimes.removeAll { time - $0 > 15 }
    }

    private mutating func appendHistory(_ events: [MusicHapticsEvent]) {
        recentOutput.append(contentsOf: events)
        if recentOutput.count > 512 { recentOutput.removeFirst(recentOutput.count - 512) }
    }

    private func fatigue(at time: TimeInterval) -> Double {
        let recent = recentOutput.filter { time - $0.time >= 0 && time - $0.time <= 15 }
        let transientRate = Double(recent.filter { $0.kind == .transient }.count) / 15
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
