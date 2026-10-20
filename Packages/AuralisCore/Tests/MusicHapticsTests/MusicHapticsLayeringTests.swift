// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
@testable import MusicHaptics
import Testing

@Suite("Music Haptics additive layers")
struct MusicHapticsLayeringTests {
    private func pulse(_ time: TimeInterval) -> MusicHapticsEvent {
        .init(time: time, duration: 0.08, intensity: 0.45, sharpness: 0.2,
              kind: .transient, classification: .kick,
              rhythm: .init(role: .pulse, confidence: 0.9, beatTime: time, period: 0.5))
    }

    private func detail(_ time: TimeInterval) -> MusicHapticsEvent {
        .init(time: time, intensity: 0.38, sharpness: 0.8,
              kind: .transient, classification: .highPercussion,
              rhythm: .init(role: .ornament, confidence: 0.8))
    }

    private func texture(_ time: TimeInterval) -> MusicHapticsEvent {
        .init(time: time, duration: 0.5, intensity: 0.4, sharpness: 0.2,
              kind: .continuous, classification: .sustainedBass,
              curve: [.init(timeOffset: 0, intensity: 0.2, sharpness: 0.1),
                      .init(timeOffset: 0.25, intensity: 0.4, sharpness: 0.3),
                      .init(timeOffset: 0.5, intensity: 0.28, sharpness: 0.2)])
    }

    @Test func addingPulseDoesNotConsumeDetailDensitySpacingOrFatigueBudget() {
        func mix(withPulse: Bool) -> [MusicHapticsEvent] {
            var mixer = MusicHapticsPerceptualMixer()
            var output: [MusicHapticsEvent] = []
            for index in 0..<160 {
                let time = Double(index) * 0.125
                var events: [MusicHapticsEvent] = []
                if index.isMultiple(of: 4) {
                    events.append(texture(time))
                    if withPulse { events.append(pulse(time)) }
                } else if !index.isMultiple(of: 2) {
                    events.append(detail(time))
                }
                output += mixer.mix(events: events, time: time, energyLevel: 0.55,
                                    slowEnergy: 0.5, onsetActivity: 0.5).events
            }
            return output + mixer.finish().events
        }
        let original = mix(withPulse: false)
        let layered = mix(withPulse: true)
        // Twenty seconds exercises both the short density and long fatigue
        // windows. Compare all detail amplitudes and every texture point too.
        #expect(original.filter { $0.kind == .transient }.count >= 15)
        #expect(layered.filter(\.isRhythmicPulse).count == 40)
        #expect(layered.filter { !$0.isRhythmicPulse } == original)
    }

    @Test func pulseAndNearbyDetailSurviveRepeatedCacheMergesAndPatternComposition() throws {
        var mixer = MusicHapticsPerceptualMixer()
        let bass = texture(1)
        let hat = detail(1.04)
        let initial = mixer.mix(events: [pulse(1), hat, bass], time: 1, energyLevel: 0.6).events
        let mixed = initial + mixer.finish().events
        let once = MusicHapticsEventDeduplicator.merge(mixed + mixed)
        let twice = MusicHapticsEventDeduplicator.merge(once + once)
        #expect(twice == once)
        #expect(twice.filter { $0.kind == .transient }.count == 2)
        #expect(twice.contains { $0.isRhythmicPulse && $0.time == 1 && $0.classification == .kick })
        #expect(twice.contains { !$0.isRhythmicPulse && $0.time == 1.04 && $0.classification == .highPercussion })
        let retainedTexture = try #require(twice.first { $0.kind == .continuous })
        let rendered = MusicHapticsRendering.events(twice, style: .rhythm)
        #expect(rendered.contains(retainedTexture))
        let layers = MusicHapticsPatternComposer.layers(for: rendered)
        #expect(layers.contains { $0.contains(retainedTexture) && $0.allSatisfy { $0.kind == .continuous } })
        #expect(layers.flatMap { $0 }.contains { $0.classification == .highPercussion })
        #expect(layers.flatMap { $0 }.filter { $0.kind == .transient && $0.isRhythmicPulse }.count == 1)
    }

    @Test(arguments: [MusicHapticsStyle.rhythm, .immersive])
    func addingDensePulsePreservesEveryTextureSampleAndDecoration(style: MusicHapticsStyle) throws {
        let bass = texture(0)
        let hat = detail(0.2)
        let pulses = (0..<4).map { pulse(Double($0) * 0.15) }
        let rendered = MusicHapticsRendering.events([bass, hat] + pulses, style: style)
        #expect(rendered.contains(hat))
        let output = try #require(rendered.first { $0.kind == .continuous })
        #expect(output == bass)
        for index in 0...500 {
            let offset = Double(index) / 1000
            let before = MusicHapticsRendering.curvePoint(in: bass, at: offset)
            let after = MusicHapticsRendering.curvePoint(in: output, at: offset)
            #expect(after == before)
        }
    }

    @Test(arguments: [MusicHapticsIntensity.light, .medium, .strong])
    func forceLevelsRetainWeakMusicalLayersAndTheirBalance(intensity: MusicHapticsIntensity) {
        var bass = texture(0)
        bass.intensity = 0.02 // Quiet entrance with an audible crescendo later.
        var hat = detail(0.2)
        hat.intensity = 0.09
        #expect(MusicHapticsRendering.shouldKeep(bass, intensity: intensity))
        #expect(MusicHapticsRendering.shouldKeep(hat, intensity: intensity))
        let textureLevel = MusicHapticsPatternComposer.scaledIntensity(0.4, continuous: true, intensity: intensity)
        let attackLevel = MusicHapticsPatternComposer.scaledIntensity(0.4, continuous: false, intensity: intensity)
        #expect(abs(textureLevel - attackLevel) < 0.00001)
        #expect(abs(textureLevel - 0.4 * intensity.masterIntensity) < 0.00001)
    }

    @Test func pulseDoesNotTurnACopyOfTheSameAttackIntoAnExtraLayer() {
        var copy = pulse(1.02)
        copy.rhythm = nil
        let events = layeredTransientEvents([pulse(1), copy, detail(1.04)])
        #expect(events.count == 2)
        #expect(events.filter(\.isRhythmicPulse).count == 1)
        #expect(events.contains { $0.classification == .highPercussion && $0.time == 1.04 })
    }
}
