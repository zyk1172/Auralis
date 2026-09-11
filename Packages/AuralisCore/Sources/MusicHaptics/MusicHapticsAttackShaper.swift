// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Perceptual transient shaping shared by offline, lookahead and realtime DSP.
///
/// FFT frames are deliberately overlapped, so their start time is not a good
/// proxy for the audible attack. This helper localizes the newest rising edge
/// inside the frame and maps spectral attack cues onto the smaller tactile
/// intensity/sharpness space of Core Haptics.
public enum MusicHapticsAttackShaper {
    public enum LocalizationBand: String, Hashable, Sendable {
        case low
        case broadband
        case high
        case fallback
    }

    public struct Localization: Hashable, Sendable {
        public let offset: TimeInterval
        public let confidence: Float
        public let band: LocalizationBand
        public let usedFallback: Bool

        public init(
            offset: TimeInterval,
            confidence: Float,
            band: LocalizationBand,
            usedFallback: Bool
        ) {
            self.offset = max(0, offset.isFinite ? offset : 0)
            self.confidence = Self.clamp(confidence)
            self.band = band
            self.usedFallback = usedFallback
        }

        private static func clamp(_ value: Float) -> Float {
            min(1, max(0, value.isFinite ? value : 0))
        }
    }

    public struct Shape: Hashable, Sendable {
        /// Perceptual body budget. The attack itself is a Core Haptics
        /// transient; the pattern composer may turn part of this budget into a
        /// short continuous body for classes that benefit from tactile weight.
        public let duration: TimeInterval
        public let intensityScale: Float
        public let sharpness: Float

        public init(duration: TimeInterval, intensityScale: Float, sharpness: Float) {
            self.duration = min(max(duration.isFinite ? duration : 0.06, 0.025), 0.14)
            self.intensityScale = min(max(intensityScale.isFinite ? intensityScale : 1, 0.55), 1.05)
            self.sharpness = min(max(sharpness.isFinite ? sharpness : 0.4, 0), 1)
        }
    }

    private struct Candidate {
        let index: Int
        let fullScore: Float
        let lowScore: Float
        let highScore: Float
    }

    /// Compatibility entry point used by the shared DSP.
    public static func localizedAttackOffset(
        samples: [Float],
        sampleRate: Double,
        hopSize: Int,
        frameStride: Int
    ) -> TimeInterval {
        localizeAttack(
            samples: samples,
            sampleRate: sampleRate,
            hopSize: hopSize,
            frameStride: frameStride
        ).offset
    }

    /// Returns a confidence-gated, band-aware attack localization.
    ///
    /// The first v3 draft always selected *some* waveform rise. That can turn
    /// a steady tone, a smooth crescendo, or a later hi-hat inside the same
    /// FFT frame into the timestamp for a bass/kick event. This implementation
    /// compares smoothed full-band, low-band and high-residual envelopes,
    /// derives confidence from local contrast and peak separation, and falls
    /// back to the frame center when the evidence is ambiguous.
    ///
    /// Only the newest audio region is searched. With overlapping windows a
    /// strong attack can remain inside several consecutive FFT frames; looking
    /// across the complete frame repeatedly would timestamp the same attack at
    /// an old waveform peak. The search span grows with the low-power FFT
    /// stride so skipped hops remain covered.
    public static func localizeAttack(
        samples: [Float],
        sampleRate: Double,
        hopSize: Int,
        frameStride: Int
    ) -> Localization {
        guard samples.count > 4,
              sampleRate.isFinite,
              sampleRate > 0,
              hopSize > 0
        else {
            return Localization(offset: 0, confidence: 0, band: .fallback, usedFallback: true)
        }

        let safeSamples = samples.map { sample -> Float in
            guard sample.isFinite else { return 0 }
            return min(1, max(-1, sample))
        }
        let count = safeSamples.count
        let stride = max(1, frameStride)
        let searchSamples = min(
            count,
            max(hopSize, hopSize * stride + hopSize / 2)
        )
        let searchStart = max(1, count - searchSamples)
        let frameDuration = Double(count) / sampleRate
        let frameCenter = frameDuration / 2

        // A centered moving average gives us a cheap near-zero-phase low-band
        // proxy. The residual is a useful high-frequency proxy for cymbals,
        // hats and sharp broadband noise without running another FFT.
        let lowRadius = max(8, min(64, Int((sampleRate * 0.0015).rounded())))
        var rawPrefix = [Float](repeating: 0, count: count + 1)
        for index in 0..<count {
            rawPrefix[index + 1] = rawPrefix[index] + safeSamples[index]
        }
        var lowBand = [Float](repeating: 0, count: count)
        var highBand = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let lower = max(0, index - lowRadius)
            let upper = min(count, index + lowRadius + 1)
            let average = (rawPrefix[upper] - rawPrefix[lower]) / Float(max(1, upper - lower))
            lowBand[index] = average
            highBand[index] = safeSamples[index] - average
        }

        let fullAbs = safeSamples.map { abs($0) }
        let lowAbs = lowBand.map { abs($0) }
        let highAbs = highBand.map { abs($0) }
        let fullPrefix = prefixSums(fullAbs)
        let lowPrefix = prefixSums(lowAbs)
        let highPrefix = prefixSums(highAbs)

        // Around three milliseconds is long enough to smooth carrier phase in
        // ordinary pitched tones but still short enough to localize a tactile
        // attack inside the 1024-sample production FFT window.
        let windowRadius = max(8, min(96, Int((sampleRate * 0.0030).rounded())))
        let step = max(1, windowRadius / 6)
        let immediateRadius = max(2, min(12, Int((sampleRate * 0.00035).rounded())))
        let searchMean = mean(fullPrefix, lower: searchStart, upper: count)
        let lowSearchMean = mean(lowPrefix, lower: searchStart, upper: count)
        let highSearchMean = mean(highPrefix, lower: searchStart, upper: count)

        var candidates: [Candidate] = []
        var index = searchStart
        while index < count {
            let beforeStart = max(0, index - windowRadius)
            let afterEnd = min(count, index + windowRadius)
            guard index > beforeStart, afterEnd > index else {
                index += step
                continue
            }

            let fullBefore = mean(fullPrefix, lower: beforeStart, upper: index)
            let fullAfter = mean(fullPrefix, lower: index, upper: afterEnd)
            let lowBefore = mean(lowPrefix, lower: beforeStart, upper: index)
            let lowAfter = mean(lowPrefix, lower: index, upper: afterEnd)
            let highBefore = mean(highPrefix, lower: beforeStart, upper: index)
            let highAfter = mean(highPrefix, lower: index, upper: afterEnd)

            let immediateRise = normalizedRise(
                before: mean(
                    fullPrefix,
                    lower: max(0, index - immediateRadius),
                    upper: index
                ),
                after: mean(
                    fullPrefix,
                    lower: index,
                    upper: min(count, index + immediateRadius)
                )
            )
            let fullRise = normalizedRise(before: fullBefore, after: fullAfter)
            let lowRise = normalizedRise(before: lowBefore, after: lowAfter)
            let highRise = normalizedRise(before: highBefore, after: highAfter)
            let fullSalience = salience(fullAfter, baseline: searchMean)
            let lowSalience = salience(lowAfter, baseline: lowSearchMean)
            let highSalience = salience(highAfter, baseline: highSearchMean)

            candidates.append(Candidate(
                index: index,
                fullScore: clamp(fullRise * 0.70 + immediateRise * 0.20 + fullSalience * 0.10),
                lowScore: clamp(lowRise * 0.76 + fullRise * 0.16 + lowSalience * 0.08),
                highScore: clamp(highRise * 0.76 + fullRise * 0.16 + highSalience * 0.08)
            ))
            index += step
        }

        guard !candidates.isEmpty,
              let bestFull = candidates.max(by: { $0.fullScore < $1.fullScore }),
              let bestLow = candidates.max(by: { $0.lowScore < $1.lowScore }),
              let bestHigh = candidates.max(by: { $0.highScore < $1.highScore })
        else {
            return Localization(offset: frameCenter, confidence: 0, band: .fallback, usedFallback: true)
        }

        let selectedBand: LocalizationBand
        let selected: Candidate
        let selectedScore: Float
        if bestLow.lowScore >= bestHigh.highScore * 0.90,
           bestLow.lowScore >= bestFull.fullScore * 0.78 {
            // A modest low-band preference prevents a later hi-hat spike from
            // stealing the timestamp of a concurrent kick/bass attack.
            selectedBand = .low
            selected = bestLow
            selectedScore = bestLow.lowScore
        } else if bestHigh.highScore > bestLow.lowScore * 1.22,
                  bestHigh.highScore >= bestFull.fullScore * 0.88 {
            selectedBand = .high
            selected = bestHigh
            selectedScore = bestHigh.highScore
        } else {
            selectedBand = .broadband
            selected = bestFull
            selectedScore = bestFull.fullScore
        }

        let scores: [Float] = candidates.map { candidate in
            switch selectedBand {
            case .low: candidate.lowScore
            case .high: candidate.highScore
            case .broadband, .fallback: candidate.fullScore
            }
        }
        let sortedScores = scores.sorted()
        let medianScore = sortedScores[sortedScores.count / 2]
        let contrast = clamp((selectedScore - medianScore) / max(0.08, selectedScore))
        let exclusion = max(windowRadius, step * 2)
        let secondBest = zip(candidates, scores)
            .filter { abs($0.0.index - selected.index) > exclusion }
            .map { $0.1 }
            .max() ?? 0
        let separation = clamp((selectedScore - secondBest) / max(0.08, selectedScore))
        let confidence = clamp(selectedScore * 0.60 + contrast * 0.30 + separation * 0.10)

        // Gradual changes and steady periodic waveforms can still contain a
        // numerical "best" rise. Do not move haptic timing unless the evidence
        // is materially stronger than the local envelope floor.
        guard selectedScore >= 0.28, confidence >= 0.50 else {
            return Localization(
                offset: frameCenter,
                confidence: confidence,
                band: .fallback,
                usedFallback: true
            )
        }

        let rawOffset = min(frameDuration, Double(selected.index) / sampleRate)

        // The DSP feeds this timestamp into BeatTracker as well as the emitted
        // transient. Bound a late-frame localization so the next analyzed
        // frame's center/earliest search point cannot move the tracker clock
        // backwards. At the production 1024/256 stride-1 configuration this
        // only bounds the final ~11.6 ms of the FFT window; it still removes
        // most of the old frame-start timing bias.
        let nextFrameAdvance = Double(hopSize * stride) / sampleRate
        let nextFrameCenter = nextFrameAdvance + frameCenter
        let nextEarliestSearchPoint = nextFrameAdvance + Double(searchStart) / sampleRate
        let monotonicUpperBound = min(
            frameDuration,
            min(nextFrameCenter, nextEarliestSearchPoint)
        )

        return Localization(
            offset: min(rawOffset, monotonicUpperBound),
            confidence: confidence,
            band: selectedBand,
            usedFallback: false
        )
    }

    /// Converts audio-domain attack features into tactile-domain parameters.
    /// This intentionally compresses differences: a mastered recording has a
    /// much wider useful amplitude range than the Taptic Engine, so directly
    /// copying audio brightness/energy produces harsh, fatiguing vibration.
    public static func shape(
        classification: MusicHapticsEventClass,
        baseSharpness: Float,
        attackStrength: Float,
        spectralCentroid: Float,
        spectralFlatness: Float,
        beat: MusicHapticsBeatEstimate
    ) -> Shape {
        let attack = clamp(attackStrength)
        let brightness = clamp((spectralCentroid - 700) / 7_000)
        let noisiness = clamp(spectralFlatness * 1.5)

        var sharpness = clamp(baseSharpness) * 0.58
            + brightness * 0.16
            + noisiness * 0.08
            + attack * 0.18

        let duration: TimeInterval
        var intensityScale: Float
        switch classification {
        case .kick:
            sharpness = min(0.32, max(0.10, sharpness))
            duration = 0.092 - Double(attack) * 0.020
            intensityScale = 1.00
        case .bassAttack:
            sharpness = min(0.36, max(0.12, sharpness))
            duration = 0.105 - Double(attack) * 0.022
            intensityScale = 0.96
        case .snareClap:
            sharpness = min(0.78, max(0.38, sharpness))
            duration = 0.070 - Double(attack) * 0.018
            intensityScale = 0.92 + attack * 0.05
        case .highPercussion:
            sharpness = min(0.94, max(0.58, sharpness))
            duration = 0.040 - Double(attack) * 0.010
            // Dense hats/shakers are deliberately background material unless
            // the beat grid says the attack carries structural weight.
            intensityScale = beat.isBeat ? 0.84 : 0.70
            intensityScale += attack * 0.06
        case .climax:
            sharpness = min(0.82, max(0.42, sharpness))
            duration = 0.080
            intensityScale = 0.96
        case .sustainedBass, .buildTexture, .unknown:
            sharpness = min(0.72, max(0.20, sharpness))
            duration = 0.072
            intensityScale = 0.88
        }

        if beat.isBeat {
            switch beat.strength {
            case .strongBeat:
                intensityScale += 0.04
            case .normalBeat:
                intensityScale += 0.015
            case .subBeat:
                break
            }
        }

        return Shape(
            duration: duration,
            intensityScale: intensityScale,
            sharpness: sharpness
        )
    }

    private static func prefixSums(_ values: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: values.count + 1)
        for index in values.indices {
            result[index + 1] = result[index] + values[index]
        }
        return result
    }

    private static func mean(_ prefix: [Float], lower: Int, upper: Int) -> Float {
        guard upper > lower,
              lower >= 0,
              upper < prefix.count
        else { return 0 }
        return (prefix[upper] - prefix[lower]) / Float(upper - lower)
    }

    private static func normalizedRise(before: Float, after: Float) -> Float {
        let rise = max(0, after - before)
        return clamp(rise / max(0.0005, (before + after) * 0.5))
    }

    private static func salience(_ value: Float, baseline: Float) -> Float {
        clamp(value / max(0.001, baseline * 2.2))
    }

    private static func clamp(_ value: Float) -> Float {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
