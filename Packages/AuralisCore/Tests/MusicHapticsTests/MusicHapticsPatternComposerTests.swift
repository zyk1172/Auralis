// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@testable import MusicHaptics
import Testing

private func texture(at time: TimeInterval, duration: TimeInterval = 1) -> MusicHapticsEvent {
    MusicHapticsEvent(
        time: time, duration: duration, intensity: 0.5, sharpness: 0.2,
        kind: .continuous, classification: .sustainedBass,
        curve: [
            .init(timeOffset: 0, intensity: 0.4, sharpness: 0.1),
            .init(timeOffset: duration, intensity: 0.6, sharpness: 0.3),
        ]
    )
}

@Test func textureControlsCannotModulateDrumAttacks() throws {
    let bass = texture(at: 0)
    let kick = MusicHapticsEvent(time: 0.5, intensity: 0.8, sharpness: 0.2,
                               kind: .transient, classification: .kick)
    let layers = MusicHapticsPatternComposer.layers(for: [bass, kick])
    #expect(layers.count == 2)
    let attacks = try #require(layers.first { $0.contains(kick) })
    #expect(attacks == [kick])
    #expect(layers.contains([bass]))
}

@Test func transientDurationMaterializesAsRealContinuousBody() throws {
    let kick = MusicHapticsEvent(
        time: 1,
        duration: 0.09,
        intensity: 0.82,
        sharpness: 0.22,
        kind: .transient,
        classification: .kick
    )
    let expanded = MusicHapticsPatternComposer.expandedEvents(for: [kick])

    #expect(expanded.count == 2)
    #expect(expanded.contains(kick))
    let body = try #require(expanded.first { $0.kind == .continuous })
    #expect(body.classification == .kick)
    #expect(body.time > kick.time)
    #expect((body.duration ?? 0) >= 0.028)
    #expect(body.intensity < kick.intensity)
    #expect(body.sharpness <= 0.22)
    #expect(body.curve.isEmpty)

    // No parameter curve means the short body can share the unmodulated Core
    // Haptics pattern with its transient instead of allocating a texture lane.
    let layers = MusicHapticsPatternComposer.layers(for: [kick])
    #expect(layers.count == 1)
    #expect(layers[0].contains { $0.kind == .transient })
    #expect(layers[0].contains { $0.kind == .continuous })
}

@Test func highPercussionDurationStaysTransientOnly() {
    let hat = MusicHapticsEvent(
        time: 1,
        duration: 0.04,
        intensity: 0.72,
        sharpness: 0.88,
        kind: .transient,
        classification: .highPercussion
    )
    let expanded = MusicHapticsPatternComposer.expandedEvents(for: [hat])

    #expect(expanded == [hat])
    #expect(!expanded.contains { $0.kind == .continuous })
}

@Test func overlappingCurvesUseIndependentPlayersButAdjacentTexturesReuseALane() {
    let first = texture(at: 0)
    let overlapping = texture(at: 0.5)
    let adjacent = texture(at: 1)
    let layers = MusicHapticsPatternComposer.layers(for: [adjacent, overlapping, first])
    #expect(layers.count == 2)
    #expect(layers.contains([first, adjacent]))
    #expect(layers.contains([overlapping]))
    #expect(layers.flatMap { $0 }.count == 3)
}

@Test(arguments: [MusicHapticsIntensity.light, .medium, .strong])
func absoluteTextureEnvelopeAppliesGainExactlyOnce(intensity: MusicHapticsIntensity) {
    let event = texture(at: 0)
    let base = MusicHapticsPatternComposer.baseParameters(for: event, intensity: intensity)
    let point = event.curve[0]
    let control = MusicHapticsPatternComposer.scaledIntensity(
        point.intensity, continuous: true, intensity: intensity
    )
    let effective = base.intensity * control
    let expected = min(1, point.intensity * intensity.masterIntensity * intensity.continuousTextureScale)
    #expect(abs(effective - expected) < 0.00001)
    #expect(abs(base.sharpness + point.sharpness - point.sharpness) < 0.00001)
}

@Test func unmodulatedTextureKeepsItsStaticParameters() {
    let event = MusicHapticsEvent(time: 0, duration: 1, intensity: 0.5,
                                 sharpness: 0.2, kind: .continuous)
    let base = MusicHapticsPatternComposer.baseParameters(for: event, intensity: .medium)
    #expect(base.intensity == 0.5)
    #expect(base.sharpness == 0.2)
    #expect(MusicHapticsPatternComposer.layers(for: [event]) == [[event]])
    #expect(MusicHapticsPatternComposer.layers(for: []).isEmpty)
}

@Test(arguments: [1, 2, 4])
func lowPowerDSPKeepsThreeSecondsOfAnalyzedHistory(stride: Int) {
    let processor = MusicHapticsDSPProcessor(configuration: .init(fftFrameStride: stride))
    let samples = processor.historyLimit(sampleRate: 22_050)
    let historySeconds = Double(samples * 256 * stride) / 22_050
    #expect(abs(historySeconds - 3) < 0.05)
}

@Test func steadyBeatsAreNotAllPromotedToStrongAccents() {
    var tracker = MusicHapticsBeatTracker()
    var estimate = MusicHapticsBeatEstimate()
    for beat in 0..<20 {
        estimate = tracker.update(time: Double(beat) * 0.5, onset: 0.02,
                                  threshold: 0.005, energy: 0.1)
    }
    #expect(estimate.isBeat)
    #expect(estimate.strength == .normalBeat)
    let accent = tracker.update(time: 10, onset: 0.04, threshold: 0.005, energy: 0.2)
    #expect(accent.isBeat)
    #expect(accent.strength == .strongBeat)
}

@Test(arguments: [Float(0.05), 0.1, 0.3])
func relativeBeatAccentsSurviveDifferentMasteringLevels(level: Float) {
    var tracker = MusicHapticsBeatTracker()
    for beat in 0..<20 {
        _ = tracker.update(time: Double(beat) * 0.5, onset: 0.02,
                           threshold: 0.005, energy: level)
    }
    let accent = tracker.update(time: 10, onset: 0.04, threshold: 0.005, energy: level * 1.5)
    #expect(accent.strength == .strongBeat)
}
