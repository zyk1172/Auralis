import Foundation
import MusicHaptics
import Testing

private func transient(
    _ time: TimeInterval,
    intensity: Float = 0.8,
    classification: MusicHapticsEventClass,
    climaxAmount: Float = 0
) -> MusicHapticsEvent {
    MusicHapticsEvent(
        time: time,
        duration: classification == .highPercussion ? 0.045 : 0.08,
        intensity: intensity,
        sharpness: classification == .highPercussion ? 0.85 : 0.2,
        kind: .transient,
        classification: classification,
        climaxAmount: climaxAmount
    )
}

private func texture(_ time: TimeInterval, duration: TimeInterval = 0.24) -> MusicHapticsEvent {
    MusicHapticsEvent(
        time: time,
        duration: duration,
        intensity: 0.45,
        sharpness: 0.18,
        kind: .continuous,
        classification: .sustainedBass,
        curve: [
            MusicHapticsCurvePoint(timeOffset: 0, intensity: 0.25, sharpness: 0.14),
            MusicHapticsCurvePoint(timeOffset: duration, intensity: 0.45, sharpness: 0.2),
        ]
    )
}

@Test func sustainedSectionIsOneContinuousVoice() {
    var mixer = MusicHapticsPerceptualMixer()
    var output: [MusicHapticsEvent] = []
    for index in 0..<8 {
        output.append(contentsOf: mixer.mix(
            events: [texture(Double(index) * 0.22)],
            time: Double(index) * 0.22,
            energyLevel: 0.5
        ).events)
    }
    #expect(output.contains { $0.kind == .continuous })
    output.append(contentsOf: mixer.finish().events)
    let continuous = output.filter { $0.kind == .continuous }
    #expect(continuous.count >= 2)
    #expect(continuous.allSatisfy { $0.curve.count >= 2 })
    #expect(continuous.dropFirst().enumerated().allSatisfy { index, event in
        let previous = continuous[index]
        guard event.time >= previous.time + (previous.duration ?? 0) - 0.001,
              let previousEnd = previous.curve.last,
              let nextStart = event.curve.first
        else { return false }
        return abs(previousEnd.intensity - nextStart.intensity) <= 0.001
            && abs(previousEnd.sharpness - nextStart.sharpness) <= 0.001
    })
    #expect(continuous.reduce(0) { $0 + ($1.duration ?? 0) } > 1.2)
}

@Test func climaxModifiesKickWithoutAddingTransientVoice() {
    var mixer = MusicHapticsPerceptualMixer()
    _ = mixer.mix(events: [
        transient(1, intensity: 0.65, classification: .kick),
        transient(1.01, intensity: 0.9, classification: .climax, climaxAmount: 0.8),
    ], time: 1, energyLevel: 0.8)
    let result = mixer.finish()
    #expect(result.events.count == 1)
    #expect(result.events[0].classification == .kick)
    #expect(result.events[0].climaxAmount > 0)
    #expect(result.diagnostics.dominantTransientCount == 1)
}

@Test func collisionFusesKickAndSupportingPercussionIntoOneTransient() {
    var mixer = MusicHapticsPerceptualMixer()
    _ = mixer.mix(events: [
        transient(1, intensity: 0.9, classification: .kick),
        transient(1.02, intensity: 0.7, classification: .highPercussion),
        transient(1.03, intensity: 0.6, classification: .highPercussion),
    ], time: 1, energyLevel: 0.7)
    let result = mixer.finish()
    #expect(result.events.filter { $0.kind == .transient }.count == 1)
    #expect(result.events.first?.classification == .kick)
    #expect((result.events.first?.intensity ?? 0) > 0.9)
    #expect(result.diagnostics.suppressedTransientCount >= 2)
}

@Test func collisionFusesKickAndSnareWithoutSupportingTransientVoice() {
    var mixer = MusicHapticsPerceptualMixer()
    _ = mixer.mix(events: [
        transient(1, intensity: 0.72, classification: .kick),
        MusicHapticsEvent(
            time: 1.04,
            duration: 0.08,
            intensity: 0.55,
            sharpness: 0.65,
            kind: .transient,
            classification: .snareClap
        ),
    ], time: 1, energyLevel: 0.7)

    let transientEvents = mixer.finish().events.filter { $0.kind == .transient }
    #expect(transientEvents.count == 1)
    #expect(transientEvents.first?.classification == .kick)
    #expect((transientEvents.first?.intensity ?? 0) > 0.72)
    #expect((transientEvents.first?.sharpness ?? 0) > 0.20)
    #expect((transientEvents.first?.sharpness ?? 1) < 0.65)
}

@Test func collisionAcrossAnalysisFramesStillEmitsOneTransient() {
    var mixer = MusicHapticsPerceptualMixer()
    _ = mixer.mix(
        events: [transient(1, intensity: 0.78, classification: .kick)],
        time: 1,
        energyLevel: 0.7
    )
    _ = mixer.mix(
        events: [transient(1.04, intensity: 0.64, classification: .highPercussion)],
        time: 1.04,
        energyLevel: 0.7
    )
    let flushed = mixer.mix(events: [], time: 1.20, energyLevel: 0.7)
    #expect(flushed.events.filter { $0.kind == .transient }.count == 1)
    #expect(flushed.events.first?.classification == .kick)
    #expect(flushed.events.first?.sharpness ?? 0 > 0.2)
}

@Test func highPercussionUsesEnergyDependentDensityBudget() {
    var mixer = MusicHapticsPerceptualMixer()
    var output: [MusicHapticsEvent] = []
    for index in 0..<20 {
        let time = Double(index) * 0.05
        output.append(contentsOf: mixer.mix(
            events: [transient(time, intensity: 0.4, classification: .highPercussion)],
            time: time,
            energyLevel: 0.4
        ).events)
    }
    #expect(output.count <= 5)
    #expect(mixer.diagnostics.suppressedHighPercussionCount > 0)
}

@Test func quietGateSuppressesWeakNoiseButKeepsImportantAttack() {
    var mixer = MusicHapticsPerceptualMixer()
    let weak = mixer.mix(
        events: [transient(1, intensity: 0.1, classification: .unknown)],
        time: 1,
        energyLevel: 0.05,
        isQuiet: true
    )
    #expect(weak.events.isEmpty)
    let important = mixer.mix(
        events: [transient(1.2, intensity: 0.8, classification: .snareClap)],
        time: 1.2,
        energyLevel: 0.08,
        isQuiet: true
    )
    let finished = mixer.finish()
    #expect((important.events + finished.events).contains { $0.classification == .snareClap })
}

@Test func stableBeatGridPromotes120BPMAndExposesPhase() {
    var tracker = MusicHapticsBeatTracker()
    var estimates: [MusicHapticsBeatEstimate] = []
    for index in 0..<12 {
        estimates.append(tracker.update(
            time: Double(index) * 0.5,
            onset: 1,
            threshold: 0.5,
            energy: 0.8
        ))
    }
    let stable = estimates.last!
    #expect(abs((stable.tempoBPM ?? 0) - 120) < 2)
    #expect(stable.confidence > 0.45)
    #expect(stable.phaseAnchor != nil)
    #expect(stable.nextBeatTime != nil)
    #expect(estimates.dropFirst().contains { $0.isBeat })
}

@Test func irregularOnsetsRemainLowConfidence() {
    var tracker = MusicHapticsBeatTracker()
    let times: [TimeInterval] = [0, 0.37, 1.03, 1.41, 2.20, 2.71, 3.64]
    let estimates = times.map {
        tracker.update(time: $0, onset: 1, threshold: 0.5, energy: 0.5)
    }
    #expect(estimates.allSatisfy { !$0.isBeat })
    #expect(estimates.last?.confidence ?? 1 < 0.45)
}

@Test func beatGridReacquiresAfterWrongInitialPeriod() {
    var tracker = MusicHapticsBeatTracker()
    let times: [TimeInterval] = [
        0, 0.43, 0.86,
        1.5122, 2.1644, 2.8166, 3.4688, 4.1210,
        4.7732, 5.4254, 6.0776
    ]
    let estimates = times.map {
        tracker.update(time: $0, onset: 1, threshold: 0.5, energy: 0.7)
    }
    let recovered = estimates.last!
    #expect(abs((recovered.tempoBPM ?? 0) - 92) < 4)
    #expect(recovered.confidence > 0.45)
    #expect(estimates.dropFirst(2).contains { $0.tempoBPM ?? 0 < 110 })
}

@Test func halfDoubleTempoObservationsStayAt70BPM() {
    var tracker = MusicHapticsBeatTracker()
    var last: MusicHapticsBeatEstimate?
    var time: TimeInterval = 0
    for _ in 0..<8 {
        last = tracker.update(time: time, onset: 1, threshold: 0.5, energy: 0.7)
        time += 60.0 / 70.0
    }
    for _ in 0..<8 {
        last = tracker.update(time: time, onset: 1, threshold: 0.5, energy: 0.7)
        time += 60.0 / 140.0
    }
    #expect(abs((last?.tempoBPM ?? 0) - 70) < 4)
    #expect((last?.confidence ?? 0) > 0.45)
}

@Test @MainActor func commitSchedulerNeverHandsOutMoreThanHapticHorizon() {
    let scheduler = RollingMusicHapticsScheduler(analysisLeadTarget: 10, hapticCommitHorizon: 3)
    let window = MusicHapticsAnalysisWindow(
        startTime: 0,
        endTime: 6,
        analysisPosition: 6,
        events: [
            transient(1, classification: .kick),
            texture(2, duration: 3),
            transient(5, classification: .snareClap),
        ],
        coverage: 0.1,
        analysisSpeedX: 4,
        tempoBPM: 120,
        beatConfidence: 0.8
    )
    let first = scheduler.ingest(window)
    #expect(first.isEmpty)
    let committed = scheduler.updateClock(position: 0, isPlaying: true)
    #expect(committed.allSatisfy { $0.endTime - $0.startTime <= 3.001 })
    #expect(scheduler.scheduledUntil <= 3.001)
    scheduler.pause()
    #expect(scheduler.resume(position: 0).count > 0)
}

@Test @MainActor func schedulerDriftGuardFlushesLargeClockError() {
    let scheduler = RollingMusicHapticsScheduler(analysisLeadTarget: 10, hapticCommitHorizon: 3)
    let window = MusicHapticsAnalysisWindow(
        startTime: 0,
        endTime: 12,
        analysisPosition: 12,
        events: [transient(4, classification: .kick)],
        coverage: 1,
        analysisSpeedX: 4,
        tempoBPM: 120,
        beatConfidence: 0.8
    )
    _ = scheduler.ingest(window)
    _ = scheduler.updateClock(position: 0, isPlaying: true)
    _ = scheduler.updateClock(position: 0.2, isPlaying: true)
    #expect(scheduler.driftGuardBand == .flush)
    #expect(scheduler.hapticDriftSeconds > 0.08)
    #expect(scheduler.consumeHapticFlushRequest())
    #expect(!scheduler.consumeHapticFlushRequest())
}

@Test @MainActor func schedulerDriftGuardMarksSmallErrorForNextWindow() {
    let scheduler = RollingMusicHapticsScheduler(analysisLeadTarget: 10, hapticCommitHorizon: 3)
    let window = MusicHapticsAnalysisWindow(
        startTime: 0,
        endTime: 6,
        analysisPosition: 6,
        events: [transient(2, classification: .kick)],
        coverage: 1,
        analysisSpeedX: 4,
        tempoBPM: 120,
        beatConfidence: 0.8
    )
    _ = scheduler.ingest(window)
    _ = scheduler.updateClock(position: 0, isPlaying: true)
    _ = scheduler.updateClock(position: 0.05, isPlaying: true)
    #expect(scheduler.driftGuardBand == .rebase)
    #expect(!scheduler.consumeHapticFlushRequest())
}

@Test @MainActor func schedulerPauseAndForegroundSeekDropOldFutureSlices() {
    let scheduler = RollingMusicHapticsScheduler(analysisLeadTarget: 10, hapticCommitHorizon: 3)
    let window = MusicHapticsAnalysisWindow(
        startTime: 0,
        endTime: 90,
        analysisPosition: 90,
        events: [
            transient(42, classification: .kick),
            transient(66, classification: .snareClap),
        ],
        coverage: 0.5,
        analysisSpeedX: 4,
        tempoBPM: 120,
        beatConfidence: 0.8
    )
    _ = scheduler.ingest(window)
    _ = scheduler.updateClock(position: 40, isPlaying: true)
    #expect(scheduler.scheduledUntil <= 43.001)

    // This is the same state transition used by buffering/scene suspension:
    // no previously committed slice may survive the pause.
    _ = scheduler.updateClock(position: 40.8, isPlaying: false)
    #expect(scheduler.scheduledUntil == 40.8)
    #expect(scheduler.updateClock(position: 40.8, isPlaying: true).allSatisfy { $0.startTime >= 40.8 })

    scheduler.pause()
    let resumed = scheduler.seek(to: 65, playing: true)
    #expect(resumed.allSatisfy { $0.events.allSatisfy { $0.time >= 65 } })
    #expect(scheduler.scheduledUntil <= 68.001)
}
