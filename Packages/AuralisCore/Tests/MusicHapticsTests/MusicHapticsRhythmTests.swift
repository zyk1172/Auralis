// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
@testable import MusicHaptics
import Testing

private func rhythmPulse(_ time: TimeInterval, intensity: Float = 0.25) -> MusicHapticsEvent {
    .init(time: time, duration: 0.08, intensity: intensity, sharpness: 0.2, kind: .transient,
          classification: .kick, rhythm: .init(role: .pulse, confidence: 0.9, beatTime: time, period: 0.5))
}

@Suite("Music Haptics rhythm preservation")
struct MusicHapticsRhythmTests {
    @Test func musicalMetadataSurvivesTimelineAndCheckpointRoundTrips() throws {
        let identity = MusicHapticsIdentity(title: "Rhythm", artist: "Fixture", durationMilliseconds: 2000)
        let pulse = rhythmPulse(0.5)
        let timeline = MusicHapticsTimeline(identity: identity, duration: 2, analyzedDuration: 2,
                                           analysisCoverage: 1, events: [pulse])
        let restored = try JSONDecoder().decode(MusicHapticsTimeline.self, from: JSONEncoder().encode(timeline))
        #expect(restored.events == [pulse])
        let partial = MusicHapticsPartialCheckpoint(identity: identity, duration: 2,
            analyzedRanges: [.init(lowerBound: 0, upperBound: 1)], events: [pulse])
        let checkpoint = try JSONDecoder().decode(MusicHapticsPartialCheckpoint.self, from: JSONEncoder().encode(partial))
        #expect(checkpoint.events == [pulse])
        let legacy = Data(#"{"time":0.5,"intensity":0.4,"sharpness":0.2,"kind":"transient"}"#.utf8)
        #expect(try JSONDecoder().decode(MusicHapticsEvent.self, from: legacy).rhythm == nil)
    }

    @Test func laterDecorationCannotOverwritePulseInCollision() throws {
        var mixer = MusicHapticsPerceptualMixer()
        _ = mixer.mix(events: [rhythmPulse(1, intensity: 0.28)], time: 1, energyLevel: 0.1)
        _ = mixer.mix(events: [.init(time: 1.04, intensity: 1, sharpness: 0.9,
                                    kind: .transient, classification: .highPercussion)], time: 1.04, energyLevel: 0.1)
        let events = mixer.finish().events
        let pulse = try #require(events.first)
        #expect(events.count == 1)
        #expect(pulse.isRhythmicPulse)
        #expect(pulse.time == 1)
    }

    @Test func quiet120BPMMainPulseSurvivesDecorationBudget() {
        var mixer = MusicHapticsPerceptualMixer()
        var output: [MusicHapticsEvent] = []
        for index in 0..<16 {
            let time = Double(index) * 0.5
            output += mixer.mix(events: [rhythmPulse(time)], time: time, energyLevel: 0.05, isQuiet: true).events
        }
        output += mixer.finish().events
        #expect(output.filter(\.isRhythmicPulse).count == 16)
        #expect(output.allSatisfy { MusicHapticsRendering.shouldKeep($0, intensity: .light) })
    }

    @Test func deduplicationRetainsPulseAndItsAudibleTimestamp() throws {
        var decoration = rhythmPulse(1.02, intensity: 0.9)
        decoration.rhythm = nil
        let result = MusicHapticsEventDeduplicator.merge([rhythmPulse(1), decoration])
        let pulse = try #require(result.first)
        #expect(result.count == 1)
        #expect(pulse.isRhythmicPulse)
        #expect(pulse.time == 1)
    }

    @Test func textureDucksAtPulseWithoutChangingAttackOrCachedInput() throws {
        let pulse = rhythmPulse(0.5, intensity: 0.6)
        let texture = MusicHapticsEvent(time: 0, duration: 2, intensity: 0.5, sharpness: 0.2,
                                        kind: .continuous, classification: .sustainedBass)
        let rendered = MusicHapticsRendering.events([texture, pulse], style: .rhythm)
        let output = try #require(rendered.first { $0.kind == .continuous })
        let onBeat = MusicHapticsRendering.curvePoint(in: output, at: 0.5).intensity
        let away = MusicHapticsRendering.curvePoint(in: output, at: 1).intensity
        #expect(onBeat < away * 0.4)
        #expect(rendered.contains(pulse))
        #expect(texture.curve.isEmpty)
        let immersive = MusicHapticsRendering.events([texture, pulse], style: .immersive)
        #expect(immersive[0].intensity > output.intensity)
    }

    @Test func previousSlicePulseStillDucksTextureAcrossBoundary() throws {
        let texture = MusicHapticsEvent(time: 1.04, duration: 0.5, intensity: 0.5, sharpness: 0.2,
                                        kind: .continuous, classification: .sustainedBass)
        let output = try #require(MusicHapticsRendering.events([texture], style: .immersive,
                                                               precedingAttacks: [1]).first)
        #expect(output.curve.first!.intensity < output.curve.last!.intensity * 0.4)
    }

    @Test func windowClippingPreservesPulseAndInterpolatesTextureBoundaries() throws {
        let texture = MusicHapticsEvent(time: 0, duration: 2, intensity: 0.5, sharpness: 0.2,
            kind: .continuous, classification: .sustainedBass,
            curve: [.init(timeOffset: 0, intensity: 0.1, sharpness: 0.2),
                    .init(timeOffset: 2, intensity: 0.9, sharpness: 0.2)])
        let window = MusicHapticsAnalysisWindow(startTime: 0, endTime: 2, analysisPosition: 2,
            events: [texture, rhythmPulse(1)], coverage: 1, analysisSpeedX: 1, tempoBPM: 120, beatConfidence: 0.9)
        let slice = window.sliced(from: 0.5, to: 1.5)
        #expect(slice.events.contains(rhythmPulse(1)))
        let clipped = try #require(slice.events.first { $0.kind == .continuous })
        #expect(abs(clipped.curve.first!.intensity - 0.3) < 0.001)
        #expect(abs(clipped.curve.last!.intensity - 0.7) < 0.001)
    }

    @Test(arguments: [55.1, 70.0, 92.0, 120.0, 180.0, 200.0])
    func trackerFollowsDifferentTemposWithoutAssumingMeter(bpm: Double) {
        var tracker = MusicHapticsBeatTracker()
        var estimate = MusicHapticsBeatEstimate()
        for index in 0..<16 {
            estimate = tracker.update(time: Double(index) * 60 / bpm, onset: 1, threshold: 0.5, energy: 0.7)
        }
        #expect(abs((estimate.tempoBPM ?? 0) - bpm) < 2)
        #expect(estimate.isBeat)
    }

    @Test func lockedGridAcceptsWeakerObservedBeatsButNotSilence() {
        var tracker = MusicHapticsBeatTracker()
        for index in 0..<10 {
            _ = tracker.update(time: Double(index) * 0.5, onset: 1, threshold: 0.5, energy: 0.7)
        }
        let weak = tracker.update(time: 5, onset: 0.3, threshold: 0.5, energy: 0.35)
        #expect(weak.isBeat)
        let missing = tracker.update(time: 5.5, onset: 0, threshold: 0.5, energy: 0.35)
        #expect(!missing.isBeat)
        let quiet = tracker.update(time: 6, onset: 0, threshold: 0.5, energy: 0)
        #expect(quiet.confidence < 0.45)
        #expect(!quiet.isBeat)
        let stopped = tracker.update(time: 9, onset: 0, threshold: 0.5, energy: 0)
        #expect(stopped.tempoBPM == nil)
    }

    @Test func swingDecorationsDoNotStealMainPulse() {
        var tracker = MusicHapticsBeatTracker()
        var mainBeats = 0
        var last = MusicHapticsBeatEstimate()
        for index in 0..<24 {
            last = tracker.update(time: Double(index) * 0.5, onset: 1, threshold: 0.5, energy: 0.8)
            if index >= 16, last.isBeat { mainBeats += 1 }
            _ = tracker.update(time: Double(index) * 0.5 + 1.0 / 3.0, onset: 0.6, threshold: 0.5, energy: 0.2)
        }
        #expect(abs((last.tempoBPM ?? 0) - 120) < 4)
        #expect(mainBeats >= 6)
    }

    @Test func backwardSeekDropsOldBeatEvidence() {
        var tracker = MusicHapticsBeatTracker()
        for index in 0..<12 { _ = tracker.update(time: Double(index) * 0.5, onset: 1, threshold: 0.5, energy: 0.7) }
        let afterSeek = tracker.update(time: 0, onset: 1, threshold: 0.5, energy: 0.7)
        #expect(!afterSeek.isBeat)
        #expect(afterSeek.confidence == 0)
    }

    @Test func delayedClockSampleIsExtrapolatedAtPlaybackRate() {
        let clock = MusicHapticsPlaybackClock(position: 10, uptime: 100, rate: 1.5)
        #expect(abs(clock.position(at: 100.2, playing: true) - 10.3) < 0.0001)
        #expect(clock.position(at: 100.2, playing: false) == 10)
        #expect(clock.position(at: 99, playing: true) == 10)
    }

    @Test @MainActor func rejectedSliceRetriesOnlyFutureEvents() {
        let scheduler = RollingMusicHapticsScheduler()
        let window = MusicHapticsAnalysisWindow(startTime: 0, endTime: 4, analysisPosition: 4,
            events: [rhythmPulse(0.1), rhythmPulse(1)], coverage: 1, analysisSpeedX: 1, tempoBPM: 120, beatConfidence: 0.9)
        _ = scheduler.ingest(window)
        let slices = scheduler.updateClock(position: 0, isPlaying: true)
        slices.forEach { scheduler.reject($0) }
        let retry = scheduler.updateClock(position: 0.3, isPlaying: true)
        #expect(retry.flatMap(\.events).allSatisfy { $0.time >= 0.3 })
        #expect(retry.flatMap(\.events).contains { $0.time == 1 })
    }
}
