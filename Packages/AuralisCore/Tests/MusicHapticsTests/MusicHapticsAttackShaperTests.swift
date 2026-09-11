// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MusicHaptics
import Testing

@Test func attackLocalizationMovesTowardPCMEdgeWithoutUsingFFTFrameStart() {
    var samples = [Float](repeating: 0, count: 1_024)
    samples[900] = 1
    samples[901] = -0.8

    let localization = MusicHapticsAttackShaper.localizeAttack(
        samples: samples,
        sampleRate: 22_050,
        hopSize: 256,
        frameStride: 1
    )
    let expected = 900.0 / 22_050.0

    #expect(!localization.usedFallback)
    #expect(localization.confidence > 0.60)
    #expect(localization.offset > 0.025)
    #expect(localization.offset <= expected)
    // The observation-clock guard may bound the last hop of a frame so the
    // next BeatTracker update cannot move backwards. The residual bias stays
    // within roughly one production hop.
    #expect(expected - localization.offset < 0.012)
}

@Test func attackLocalizationCoversSkippedHopsInLowPowerMode() {
    var samples = [Float](repeating: 0, count: 1_024)
    samples[304] = 0.9
    samples[305] = -0.7

    let localization = MusicHapticsAttackShaper.localizeAttack(
        samples: samples,
        sampleRate: 22_050,
        hopSize: 256,
        frameStride: 4
    )
    let expected = 304.0 / 22_050.0

    #expect(!localization.usedFallback)
    #expect(localization.confidence > 0.60)
    #expect(abs(localization.offset - expected) < 0.005)
}

@Test func steadyToneFallsBackInsteadOfInventingAnAttack() {
    let sampleRate = 22_050.0
    let samples = (0..<1_024).map { index -> Float in
        let phase = 2 * Double.pi * 440 * Double(index) / sampleRate
        return Float(0.4 * sin(phase))
    }

    let localization = MusicHapticsAttackShaper.localizeAttack(
        samples: samples,
        sampleRate: sampleRate,
        hopSize: 256,
        frameStride: 1
    )

    #expect(localization.usedFallback)
    #expect(localization.band == .fallback)
    #expect(abs(localization.offset - 512.0 / sampleRate) < 0.000_001)
}

@Test func smoothCrescendoFallsBackInsteadOfLockingToCarrierPhase() {
    let sampleRate = 22_050.0
    let samples = (0..<1_024).map { index -> Float in
        let progress = Double(index) / 1_023.0
        let amplitude = 0.05 + progress * 0.45
        let phase = 2 * Double.pi * 440 * Double(index) / sampleRate
        return Float(amplitude * sin(phase))
    }

    let localization = MusicHapticsAttackShaper.localizeAttack(
        samples: samples,
        sampleRate: sampleRate,
        hopSize: 256,
        frameStride: 1
    )

    #expect(localization.usedFallback)
    #expect(localization.band == .fallback)
}

@Test func structuralLowAttackIsNotStolenByLaterHighFrequencySpike() {
    let sampleRate = 22_050.0
    var samples = [Float](repeating: 0, count: 1_024)
    for index in 730..<860 {
        let attack = min(1.0, Double(index - 730) / 20.0)
        let release = max(0.0, 1.0 - max(0.0, Double(index - 820)) / 40.0)
        let phase = 2 * Double.pi * 100 * Double(index - 730) / sampleRate
        samples[index] += Float(0.9 * attack * release * sin(phase))
    }
    samples[900] += 0.7
    samples[901] -= 0.6

    let localization = MusicHapticsAttackShaper.localizeAttack(
        samples: samples,
        sampleRate: sampleRate,
        hopSize: 256,
        frameStride: 1
    )
    let expectedLowAttack = 730.0 / sampleRate
    let laterSpike = 900.0 / sampleRate

    #expect(!localization.usedFallback)
    #expect(localization.band == .low)
    #expect(abs(localization.offset - expectedLowAttack) < 0.006)
    #expect(abs(localization.offset - expectedLowAttack) < abs(localization.offset - laterSpike))
}

@Test(arguments: [1, 2, 4])
func localizedTimestampCannotOutrunNextDSPObservation(stride: Int) {
    let sampleRate = 22_050.0
    var samples = [Float](repeating: 0, count: 1_024)
    samples[980] = 1
    samples[981] = -0.8

    let localization = MusicHapticsAttackShaper.localizeAttack(
        samples: samples,
        sampleRate: sampleRate,
        hopSize: 256,
        frameStride: stride
    )
    let nextFrameCenter = Double(256 * stride + 512) / sampleRate

    #expect(localization.offset <= nextFrameCenter + 0.000_001)
}

@Test func tactileShapeKeepsKickRoundedAndPercussionCrisp() {
    let beat = MusicHapticsBeatEstimate(
        isBeat: true,
        strength: .normalBeat,
        confidence: 0.8
    )
    let kick = MusicHapticsAttackShaper.shape(
        classification: .kick,
        baseSharpness: 0.16,
        attackStrength: 0.8,
        spectralCentroid: 1_200,
        spectralFlatness: 0.05,
        beat: beat
    )
    let percussion = MusicHapticsAttackShaper.shape(
        classification: .highPercussion,
        baseSharpness: 0.82,
        attackStrength: 0.8,
        spectralCentroid: 6_500,
        spectralFlatness: 0.35,
        beat: beat
    )

    #expect(kick.sharpness <= 0.32)
    #expect(percussion.sharpness >= 0.58)
    #expect(percussion.sharpness > kick.sharpness)
    #expect(kick.duration > percussion.duration)
}

@Test func offGridHighPercussionIsBackgroundMaterial() {
    let offGrid = MusicHapticsAttackShaper.shape(
        classification: .highPercussion,
        baseSharpness: 0.8,
        attackStrength: 0.6,
        spectralCentroid: 6_000,
        spectralFlatness: 0.3,
        beat: .init()
    )
    let onGrid = MusicHapticsAttackShaper.shape(
        classification: .highPercussion,
        baseSharpness: 0.8,
        attackStrength: 0.6,
        spectralCentroid: 6_000,
        spectralFlatness: 0.3,
        beat: MusicHapticsBeatEstimate(
            isBeat: true,
            strength: .strongBeat,
            confidence: 0.9
        )
    )

    #expect(offGrid.intensityScale < onGrid.intensityScale)
    #expect(offGrid.intensityScale < 0.8)
}

@Test func dspTransientTimestampTracksPCMImpulse() {
    let sampleRate = 22_050.0
    var processor = MusicHapticsDSPProcessor(configuration: .init(
        targetSampleRate: sampleRate,
        fftSize: 1_024,
        hopSize: 256,
        adaptiveWindowSeconds: 2,
        fftFrameStride: 1
    ))

    let silence = [Float](repeating: 0, count: 1_024)
    _ = processor.processCandidates(
        monoSamples: silence,
        startTime: 0,
        sampleRate: sampleRate
    )

    var attack = [Float](repeating: 0, count: 1_024)
    for index in 896..<912 {
        attack[index] = index.isMultiple(of: 2) ? 1 : -1
    }
    let blockStart = 1_024.0 / sampleRate
    let frames = processor.processCandidates(
        monoSamples: attack,
        startTime: blockStart,
        sampleRate: sampleRate
    )
    let transients = frames
        .flatMap(\.events)
        .filter { $0.kind == .transient && $0.classification != .climax }
    let expected = blockStart + 896.0 / sampleRate
    let closest = transients.min { lhs, rhs in
        abs(lhs.time - expected) < abs(rhs.time - expected)
    }

    #expect(closest != nil)
    if let closest {
        #expect(closest.time > blockStart + 0.025)
        #expect(abs(closest.time - expected) < 0.016)
    }
}

@Test func v3TimelineInvalidatesOlderCachedHapticAnalysis() {
    #expect(MusicHapticsTimeline.algorithmVersion == "auralis-haptics-v3.0")
}
