import Foundation
import MusicHaptics
import Testing

@Test func isrcMatchesAcrossServers() {
    let original = MusicHapticsIdentity(serverID: "one", remoteID: "1", isrc: "US-ABC-12-34567", title: "Song", artist: "Artist", durationMilliseconds: 180_000)
    let restored = MusicHapticsIdentity(serverID: "two", remoteID: "8", isrc: "usabc1234567", title: "Different title", artist: "Different artist", durationMilliseconds: 181_000)
    #expect(original.matchConfidence(with: restored) == 1)
}

@Test func durationGuardRejectsDifferentRecording() {
    let studio = MusicHapticsIdentity(title: "Song", artist: "Artist", durationMilliseconds: 180_000)
    let live = MusicHapticsIdentity(title: "Song", artist: "Artist", durationMilliseconds: 250_000)
    #expect(studio.matchConfidence(with: live) == 0)
}

@Test func explicitPreferenceOverridesGlobalSetting() {
    #expect(TrackHapticsPreference.enabled.effective(globalEnabled: false))
    #expect(!TrackHapticsPreference.disabled.effective(globalEnabled: true))
    #expect(TrackHapticsPreference.inherit.effective(globalEnabled: true))
}

@Test @MainActor func preparedHapticsReevaluatesGlobalDefaultForEveryPreferenceState() {
    let defaults = UserDefaults(suiteName: "music-haptics-preparation-(UUID().uuidString)")!
    let coordinator = MusicHapticsCoordinator(defaults: defaults)
    let identity = MusicHapticsIdentity(
        serverID: "server",
        remoteID: "track",
        title: "Song",
        artist: "Artist",
        durationMilliseconds: 180_000
    )

    func preparation(for preference: TrackHapticsPreference) -> MusicHapticsPlaybackPreparation {
        MusicHapticsPlaybackPreparation(
            identity: identity,
            favorite: false,
            plan: .disabled,
            reason: "test",
            systemAvailability: MusicHapticsSystemAvailability(
                hasISRC: false,
                active: false,
                timelineAvailable: false
            ),
            fullTimelineExists: false,
            partialExists: false,
            preference: preference,
            effectiveEnabled: preference.effective(globalEnabled: true),
            analysisSink: nil
        )
    }

    defaults.set(false, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    #expect(coordinator.effectiveEnabled(for: preparation(for: .enabled)))
    #expect(!coordinator.effectiveEnabled(for: preparation(for: .inherit)))
    #expect(!coordinator.effectiveEnabled(for: preparation(for: .disabled)))

    defaults.set(true, forKey: MusicHapticsCoordinator.enabledDefaultsKey)
    #expect(coordinator.effectiveEnabled(for: preparation(for: .enabled)))
    #expect(coordinator.effectiveEnabled(for: preparation(for: .inherit)))
    #expect(!coordinator.effectiveEnabled(for: preparation(for: .disabled)))
}

@Test func playbackTogglePreservesThreeStatePreferenceSemantics() {
    #expect(TrackHapticsPreference.preference(for: true, globalEnabled: true) == .inherit)
    #expect(TrackHapticsPreference.preference(for: false, globalEnabled: true) == .disabled)
    #expect(TrackHapticsPreference.preference(for: false, globalEnabled: false) == .inherit)
    #expect(TrackHapticsPreference.preference(for: true, globalEnabled: false) == .enabled)
}

@Test func explicitPreferenceSurvivesIdentityEnrichment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let uncachedIdentity = MusicHapticsIdentity(
        globalID: "server:track",
        serverID: "server",
        remoteID: "track",
        title: "Song",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let enrichedIdentity = MusicHapticsIdentity(
        globalID: "server:track",
        serverID: "server",
        remoteID: "track",
        isrc: "USABC1234567",
        title: "Song",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let store = MusicHapticsStore(root: root)

    try await store.setPreference(.disabled, for: uncachedIdentity)
    #expect(try await store.preference(for: enrichedIdentity) == .disabled)

    try await store.setPreference(.inherit, for: enrichedIdentity)
    #expect(try await store.preference(for: enrichedIdentity) == .inherit)
}

@Test func assetInfoKeepsSystemMatchSeparateFromAlgorithmOutput() {
    let system = MusicHapticsAssetInfo(
        origin: .systemISRC,
        state: .available,
        isrc: "USABC1234567",
        isCurrentlyUsed: true
    )
    let algorithm = MusicHapticsAssetInfo(
        origin: .algorithmGenerated,
        state: .available,
        isrc: "USABC1234567",
        algorithmVersion: MusicHapticsTimeline.algorithmVersion,
        coverage: 1
    )

    #expect(system.origin == .systemISRC)
    #expect(system.isCurrentlyUsed)
    #expect(algorithm.origin == .algorithmGenerated)
    #expect(algorithm.algorithmVersion == MusicHapticsTimeline.algorithmVersion)
    #expect(algorithm.origin != system.origin)
}

@Test func playbackPlanResolverHasOneAuthoritativeOrder() {
    let identity = MusicHapticsIdentity(
        title: "Plan",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let request = MusicHapticsAnalysisRequest(identity: identity, favorite: false, duration: 180)
    let fullTimeline = MusicHapticsTimeline(
        identity: identity,
        duration: 180,
        analyzedDuration: 180,
        analysisCoverage: 1,
        events: []
    )

    #expect(MusicHapticsPlaybackPlanResolver.resolve(
        featureEnabled: false,
        customHapticsSupported: true,
        systemTimelineAvailable: false,
        fullTimeline: fullTimeline,
        partial: nil,
        request: request
    ).plan.kind == .disabled)
    #expect(MusicHapticsPlaybackPlanResolver.resolve(
        featureEnabled: true,
        customHapticsSupported: true,
        systemTimelineAvailable: true,
        fullTimeline: fullTimeline,
        partial: nil,
        request: request
    ).plan.kind == .system)
    #expect(MusicHapticsPlaybackPlanResolver.resolve(
        featureEnabled: true,
        customHapticsSupported: true,
        systemTimelineAvailable: false,
        fullTimeline: fullTimeline,
        partial: nil,
        request: request
    ).plan.kind == .custom)
    #expect(MusicHapticsPlaybackPlanResolver.resolve(
        featureEnabled: true,
        customHapticsSupported: true,
        systemTimelineAvailable: false,
        fullTimeline: nil,
        partial: nil,
        request: request
    ).plan.kind == .analyze)
}

@Test func playbackPlanResolverUsesLookaheadAndRejectsStaleTimelines() {
    let identity = MusicHapticsIdentity(
        serverID: "server",
        remoteID: "remote-track",
        title: "Remote",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let source = MusicHapticsAnalysisSource.remoteLookahead(
        .init(url: URL(string: "https://example.invalid/stream?token=not-a-diagnostic")!, bitrate: 96)
    )
    let request = MusicHapticsAnalysisRequest(
        identity: identity,
        favorite: false,
        duration: 180,
        analysisSource: source
    )
    for staleAlgorithmVersion in [
        MusicHapticsTimeline.legacyAlgorithmVersion,
        "auralis-haptics-v2.1",
    ] {
        let stale = MusicHapticsTimeline(
            identity: identity,
            duration: 180,
            analyzedDuration: 180,
            analysisCoverage: 1,
            events: [],
            algorithmVersion: staleAlgorithmVersion
        )
        let decision = MusicHapticsPlaybackPlanResolver.resolve(
            featureEnabled: true,
            customHapticsSupported: true,
            systemTimelineAvailable: false,
            fullTimeline: stale,
            partial: nil,
            request: request
        )
        #expect(decision.plan.kind == .analyzeLookahead)
        #expect(decision.reason == "no_timeline")
    }

    let systemDecision = MusicHapticsPlaybackPlanResolver.resolve(
        featureEnabled: true,
        customHapticsSupported: true,
        systemTimelineAvailable: true,
        fullTimeline: nil,
        partial: nil,
        request: request
    )
    #expect(systemDecision.plan.kind == .system)
}

@Test func v1PartialCannotBePromotedAsV2() {
    let identity = MusicHapticsIdentity(title: "Legacy", artist: "Artist", durationMilliseconds: 10_000)
    let legacy = MusicHapticsPartialCheckpoint(
        identity: identity,
        algorithmVersion: MusicHapticsTimeline.legacyAlgorithmVersion,
        duration: 10,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 10)],
        events: []
    )
    #expect(!legacy.isCurrentAlgorithm)
    #expect(!legacy.isComplete || legacy.timeline().algorithmVersion == MusicHapticsTimeline.legacyAlgorithmVersion)

    let request = MusicHapticsAnalysisRequest(identity: identity, favorite: false, duration: 10)
    let decision = MusicHapticsPlaybackPlanResolver.resolve(
        featureEnabled: true,
        customHapticsSupported: true,
        systemTimelineAvailable: false,
        fullTimeline: nil,
        partial: legacy,
        request: request
    )
    #expect(decision.plan.kind == .analyze)
}

@Test func partialPromotionRequiresNinetyFivePercentCoverage() {
    let identity = MusicHapticsIdentity(title: "Threshold", artist: "Artist", durationMilliseconds: 100_000)
    let incomplete = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 100,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 94)],
        events: []
    )
    let complete = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 100,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 96)],
        events: []
    )
    #expect(!incomplete.isComplete)
    #expect(complete.isComplete)
    #expect(complete.timeline().algorithmVersion == MusicHapticsTimeline.algorithmVersion)
}

@Test func eventDedupFusesDifferentTransientClassesInsideCollisionWindow() {
    let kick = MusicHapticsEvent(
        time: 1,
        intensity: 0.7,
        sharpness: 0.15,
        kind: .transient,
        classification: .kick
    )
    let duplicateKick = MusicHapticsEvent(
        time: 1.02,
        intensity: 0.4,
        sharpness: 0.2,
        kind: .transient,
        classification: .kick
    )
    let hat = MusicHapticsEvent(
        time: 1.01,
        intensity: 0.3,
        sharpness: 0.85,
        kind: .transient,
        classification: .highPercussion
    )
    let merged = MusicHapticsEventDeduplicator.merge([kick, duplicateKick, hat])
    #expect(merged.count == 1)
    #expect(merged[0].classification == .kick)
    #expect(merged[0].intensity > 0.7)
}

@Test func playbackRateMappingScalesTrackTimeAndDuration() {
    #expect(abs(MusicHapticsPlaybackTimeMapping.relativeTime(
        trackTime: 12,
        playbackPosition: 10,
        playbackRate: 2
    ) - 1) < 0.0001)
    #expect(abs(MusicHapticsPlaybackTimeMapping.relativeTime(
        trackTime: 12,
        playbackPosition: 10,
        playbackRate: 0.5
    ) - 4) < 0.0001)
    #expect(abs(MusicHapticsPlaybackTimeMapping.scaledDuration(
        4,
        playbackRate: 2
    ) - 2) < 0.0001)
}

@Test func voiceBudgetSeparatesTransientAndContinuousCaps() {
    let budget = HapticVoiceBudget(maxContinuousVoices: 4)
    #expect(budget.maxTransientVoices == 1)
    #expect(budget.maxContinuousVoices == 1)
}

#if os(macOS)
@Test @MainActor func musicHapticsPlatformPolicyDisablesMacOS() {
    #expect(!MusicHapticsPlatformPolicy.isFeatureAvailable)
}
#endif

@Test func v2DSPSilenceDoesNotCreateHaptics() {
    var processor = MusicHapticsDSPProcessor(
        configuration: .init(targetSampleRate: 22_050, fftFrameStride: 1)
    )
    let events = processor.process(
        monoSamples: Array(repeating: Float(0), count: 22_050 * 2),
        startTime: 0,
        sampleRate: 22_050
    ) + processor.finish()
    #expect(events.isEmpty)
    #expect(processor.diagnostics.eventCount == 0)
}

@Test func v2DSPDetectsLowLevelDynamicEventsAndBeatMetadata() {
    let sampleRate = 22_050.0
    let samples = syntheticRhythmicSignal(sampleRate: sampleRate, seconds: 4)
    var processor = MusicHapticsDSPProcessor(
        configuration: .init(targetSampleRate: sampleRate, fftFrameStride: 1)
    )
    let events = processor.process(monoSamples: samples, startTime: 0, sampleRate: sampleRate)
        + processor.finish()
    let classes = Set(events.map(\.classification))
    #expect(!events.isEmpty)
    #expect(classes.contains(.kick) || classes.contains(.bassAttack) || classes.contains(.snareClap))
    #expect(events.contains { $0.kind == .continuous && $0.curve.count >= 2 })
    #expect(processor.diagnostics.eventCount >= events.count)
    #expect(processor.diagnostics.tempoBPM != nil)
    #expect(processor.diagnostics.beatConfidence > 0.4)
}

@Test func v2DSPAdaptiveThresholdDetectsQuietPulseBelowV1RMSFloor() {
    let sampleRate = 22_050.0
    let count = Int(sampleRate * 3)
    var samples = Array(repeating: Float(0), count: count)
    for index in samples.indices {
        let time = Double(index) / sampleRate
        let pulsePhase = time.truncatingRemainder(dividingBy: 0.75)
        let amplitude: Float = pulsePhase < 0.055 ? 0.018 : 0.004
        samples[index] = amplitude * Float(sin(2 * Double.pi * 70 * time))
    }
    var processor = MusicHapticsDSPProcessor(
        configuration: .init(targetSampleRate: sampleRate, fftFrameStride: 1)
    )
    let events = processor.process(monoSamples: samples, startTime: 0, sampleRate: sampleRate)
        + processor.finish()
    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.intensity >= 0 && $0.intensity <= 1 })
}

private func syntheticRhythmicSignal(sampleRate: Double, seconds: Int) -> [Float] {
    let count = Int(sampleRate * Double(seconds))
    return (0..<count).map { index in
        let time = Double(index) / sampleRate
        let beatPhase = time.truncatingRemainder(dividingBy: 0.5)
        let kickEnvelope = Float(exp(-beatPhase * 34))
        let kickOscillation = Float(sin(2 * Double.pi * 62 * time))
        let kick = 0.34 * kickEnvelope * kickOscillation
        let snarePhase = (time + 0.25).truncatingRemainder(dividingBy: 0.5)
        let snareEnvelope = Float(exp(-snarePhase * 45))
        let snareOscillation = Float(sin(2 * Double.pi * 2_800 * time))
        let snare = 0.16 * snareEnvelope * snareOscillation
        let sustained = 0.10 * Float(sin(2 * Double.pi * 58 * time))
        return kick + snare + sustained
    }
}

@Test @MainActor func rollingSchedulerOnlySchedulesStrictlyAheadWindowsAndFlushesOnSeek() {
    let event = MusicHapticsEvent(
        time: 2,
        intensity: 0.7,
        sharpness: 0.2,
        kind: .transient,
        classification: .kick
    )
    let ahead = MusicHapticsAnalysisWindow(
        startTime: 0,
        endTime: 6,
        analysisPosition: 6,
        events: [event],
        coverage: 0.03,
        analysisSpeedX: 4,
        tempoBPM: 120,
        beatConfidence: 0.8
    )
    let notAhead = MusicHapticsAnalysisWindow(
        startTime: 6,
        endTime: 12,
        analysisPosition: 0,
        events: [event],
        coverage: 0.03,
        analysisSpeedX: 4,
        tempoBPM: 120,
        beatConfidence: 0.8
    )
    let scheduler = RollingMusicHapticsScheduler(targetLead: 8, schedulingHorizon: 18)
    #expect(scheduler.ingest(notAhead).isEmpty)
    #expect(scheduler.ingest(ahead).isEmpty)
    let scheduled = scheduler.updateClock(position: 0, isPlaying: true)
    #expect(scheduled.map(\.startTime) == [0])
    #expect(scheduler.scheduledUntil == 6)
    scheduler.pause()
    #expect(!scheduler.resume(position: 1).isEmpty)
    let afterSeek = scheduler.seek(to: 8, playing: true)
    #expect(afterSeek.isEmpty)
    #expect(scheduler.scheduledUntil == 8)
}

@Test func partialCheckpointRoundTripPreservesHoles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = MusicHapticsIdentity(
        serverID: "server",
        remoteID: "track",
        title: "Checkpoint",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let checkpoint = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 180,
        analyzedRanges: [
            MusicHapticsTimeRange(lowerBound: 0, upperBound: 42),
            MusicHapticsTimeRange(lowerBound: 90, upperBound: 130),
        ],
        events: [MusicHapticsEvent(time: 4, intensity: 0.5, sharpness: 0.2, kind: .transient)]
    )
    let store = MusicHapticsStore(root: root)
    try await store.storePartial(checkpoint)

    let restored = try await store.partial(for: identity)
    #expect(restored?.analyzedRanges == checkpoint.analyzedRanges)
    #expect(restored?.events == checkpoint.events)
    #expect(abs((restored?.coverage ?? 0) - (82.0 / 180.0)) < 0.0001)
    #expect(try await store.timeline(for: identity) == nil)
}

@Test func partialCheckpointMergesAdjacentPCMRangeTolerance() {
    let identity = MusicHapticsIdentity(title: "Adjacent", artist: "Artist", durationMilliseconds: 1_000)
    let merged = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 1,
        analyzedRanges: [
            MusicHapticsTimeRange(lowerBound: 0, upperBound: 0.5),
            MusicHapticsTimeRange(lowerBound: 0.515, upperBound: 1),
        ],
        events: []
    )
    #expect(merged.analyzedRanges == [MusicHapticsTimeRange(lowerBound: 0, upperBound: 1)])

    let separate = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 1,
        analyzedRanges: [
            MusicHapticsTimeRange(lowerBound: 0, upperBound: 0.5),
            MusicHapticsTimeRange(lowerBound: 0.521, upperBound: 1),
        ],
        events: []
    )
    #expect(separate.analyzedRanges.count == 2)
}

@Test func partialCheckpointNeverPersistsAnalysisURLOrToken() throws {
    let identity = MusicHapticsIdentity(
        serverID: "server",
        remoteID: "track",
        title: "Privacy",
        artist: "Artist",
        durationMilliseconds: 30_000
    )
    let checkpoint = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 30,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 3)],
        events: []
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let payload = String(data: try encoder.encode(checkpoint), encoding: .utf8) ?? ""
    #expect(!payload.contains("example.invalid"))
    #expect(!payload.localizedCaseInsensitiveContains("token"))
    #expect(!payload.localizedCaseInsensitiveContains("streamurl"))
}

@Test func encodedAnalysisPlanNeverPersistsSidecarURLOrToken() throws {
    let identity = MusicHapticsIdentity(
        serverID: "server",
        remoteID: "track",
        title: "Plan privacy",
        artist: "Artist",
        durationMilliseconds: 30_000
    )
    let source = MusicHapticsAnalysisSource.remoteLookahead(
        .init(url: URL(string: "https://example.invalid/stream?token=never-persist")!)
    )
    let plan = MusicHapticsPlaybackPlan.analyzeLookahead(
        MusicHapticsAnalysisRequest(
            identity: identity,
            favorite: false,
            duration: 30,
            analysisSource: source
        )
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let payload = String(data: try encoder.encode(plan), encoding: .utf8) ?? ""
    #expect(!payload.contains("example.invalid"))
    #expect(!payload.localizedCaseInsensitiveContains("never-persist"))
    #expect(!payload.localizedCaseInsensitiveContains("token"))
}

@Test func promotingOneTrackDoesNotDeleteAnotherPartial() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = MusicHapticsIdentity(serverID: "server", remoteID: "first", title: "First", artist: "Artist", durationMilliseconds: 10_000)
    let second = MusicHapticsIdentity(serverID: "server", remoteID: "second", title: "Second", artist: "Artist", durationMilliseconds: 10_000)
    let store = MusicHapticsStore(root: root)
    try await store.storePartial(MusicHapticsPartialCheckpoint(
        identity: second,
        duration: 10,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 2)],
        events: []
    ))
    try await store.store(MusicHapticsTimeline(
        identity: first,
        duration: 10,
        analyzedDuration: 10,
        analysisCoverage: 1,
        events: []
    ), favorite: false)

    #expect(try await store.partial(for: second)?.identity == second)
}

@Test func partialStoreMergesOutOfOrderRanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = MusicHapticsIdentity(serverID: "server", remoteID: "same", title: "Same", artist: "Artist", durationMilliseconds: 20_000)
    let store = MusicHapticsStore(root: root)

    try await store.storePartial(MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 20,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 4)],
        events: [MusicHapticsEvent(time: 1, intensity: 0.4, sharpness: 0.2, kind: .transient)]
    ))
    try await store.storePartial(MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 20,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 12, upperBound: 16)],
        events: [MusicHapticsEvent(time: 13, intensity: 0.6, sharpness: 0.3, kind: .transient)]
    ))

    let merged = try await store.partial(for: identity)
    #expect(merged?.analyzedRanges == [
        MusicHapticsTimeRange(lowerBound: 0, upperBound: 4),
        MusicHapticsTimeRange(lowerBound: 12, upperBound: 16),
    ])
    #expect(merged?.events.count == 2)
    #expect(abs((merged?.coverage ?? 0) - 0.4) < 0.0001)
}

@Test func favoriteMigrationPreservesTimelineAndLeavesTransientBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = MusicHapticsIdentity(serverID: "server", remoteID: "track", title: "Song", artist: "Artist", durationMilliseconds: 180_000)
    let timeline = MusicHapticsTimeline(identity: identity, duration: 180, analyzedDuration: 180, analysisCoverage: 1, events: [MusicHapticsEvent(time: 1, intensity: 0.5, sharpness: 0.2, kind: .transient)])
    let store = MusicHapticsStore(root: root)
    try await store.store(timeline, favorite: false)
    try await store.updateFavorite(true, for: identity)
    let usage = try await store.usage()
    #expect(usage.transientBytes == 0)
    #expect(usage.favoriteBytes > 0)
    #expect(try await store.timeline(for: identity) == timeline)
}

private actor TimelineCapture {
    var timeline: MusicHapticsTimeline?
    func record(_ timeline: MusicHapticsTimeline) { self.timeline = timeline }
}

private actor AnalysisCapture {
    var result: MusicHapticsAnalysisResult?

    func record(_ result: MusicHapticsAnalysisResult) {
        self.result = result
    }
}

private actor WindowCapture {
    var windows: [MusicHapticsAnalysisWindow] = []

    func record(_ window: MusicHapticsAnalysisWindow) {
        windows.append(window)
    }
}

@Test func streamingAnalysisPublishesProgressiveWindowsBeforeTwoSecondBatch() async {
    let identity = MusicHapticsIdentity(title: "Progressive", artist: "Artist", durationMilliseconds: 10_000)
    let capture = WindowCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(
        identity: identity,
        duration: 10,
        onResult: { _ in },
        onWindow: { window in Task { await capture.record(window) } }
    )
    let format = MusicHapticsPCMFormat(
        sampleRate: 20,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
    let samples = Array(repeating: Int16(1_200), count: 20)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }

    analyzer.begin(format: format)
    for second in 0..<4 {
        analyzer.consumePCM(bytes, time: Double(second), format: format, frameCount: 20)
    }
    for _ in 0..<100 where await capture.windows.isEmpty {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let firstWindow = await capture.windows.first
    #expect(firstWindow != nil)
    #expect(firstWindow?.endTime ?? 2 < 2)
    #expect(firstWindow?.events.contains { $0.kind == .continuous } == true)
    analyzer.cancel()
}

@Test func streamingAnalysisResumesAndMergesPartialRanges() async {
    let identity = MusicHapticsIdentity(title: "Resume", artist: "Artist", durationMilliseconds: 10_000)
    let partial = MusicHapticsPartialCheckpoint(
        identity: identity,
        duration: 10,
        analyzedRanges: [MusicHapticsTimeRange(lowerBound: 0, upperBound: 5)],
        events: []
    )
    let capture = AnalysisCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(
        identity: identity,
        duration: 10,
        partial: partial,
        onResult: { result in Task { await capture.record(result) } }
    )
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
    let samples = Array(repeating: Int16(1_200), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }

    analyzer.begin(format: format)
    for second in 5..<10 {
        analyzer.consumePCM(bytes, time: Double(second), format: format, frameCount: 10)
    }
    analyzer.finishPartial(reason: .trackSwitch)

    for _ in 0..<80 where await capture.result == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let result = await capture.result
    #expect(result?.finishReason == .trackSwitch)
    #expect(result?.checkpoint.analyzedRanges == [MusicHapticsTimeRange(lowerBound: 0, upperBound: 10)])
    #expect(result?.checkpoint.coverage == 1)
    #expect(result?.timeline?.isComplete == true)
}

@Test func streamingAnalysisPauseStopsPCMUntilResume() async {
    let identity = MusicHapticsIdentity(title: "Pause", artist: "Artist", durationMilliseconds: 10_000)
    let analyzer = StreamingMusicHapticsAnalyzer(
        identity: identity,
        duration: 10,
        onResult: { _ in }
    )
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
    let samples = Array(repeating: Int16(1_200), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }

    analyzer.pause()
    analyzer.consumePCM(bytes, time: 0, format: format, frameCount: 10)
    try? await Task.sleep(for: .milliseconds(20))
    #expect((await analyzer.partialCheckpoint()).coverage == 0)

    analyzer.resume()
    analyzer.consumePCM(bytes, time: 0, format: format, frameCount: 10)
    var checkpoint = await analyzer.partialCheckpoint()
    for _ in 0..<40 where checkpoint.coverage == 0 {
        try? await Task.sleep(for: .milliseconds(5))
        checkpoint = await analyzer.partialCheckpoint()
    }
    #expect(checkpoint.analyzedRanges == [MusicHapticsTimeRange(lowerBound: 0, upperBound: 1)])
    analyzer.cancel()
}

@Test func streamingAnalysisPreservesNonContiguousRanges() async {
    let identity = MusicHapticsIdentity(title: "Holes", artist: "Artist", durationMilliseconds: 10_000)
    let capture = AnalysisCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(
        identity: identity,
        duration: 10,
        onResult: { result in Task { await capture.record(result) } }
    )
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
    let samples = Array(repeating: Int16(1_200), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    analyzer.consumePCM(bytes, time: 0, format: format, frameCount: 10)
    analyzer.consumePCM(bytes, time: 8, format: format, frameCount: 10)
    analyzer.finishPartial(reason: .trackSwitch)

    for _ in 0..<80 where await capture.result == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(await capture.result?.checkpoint.analyzedRanges == [
        MusicHapticsTimeRange(lowerBound: 0, upperBound: 1),
        MusicHapticsTimeRange(lowerBound: 8, upperBound: 9),
    ])
}

@Test func naturalEndKeepsIncompleteCheckpoint() async {
    let identity = MusicHapticsIdentity(title: "Partial end", artist: "Artist", durationMilliseconds: 10_000)
    let capture = AnalysisCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(
        identity: identity,
        duration: 10,
        onResult: { result in Task { await capture.record(result) } }
    )
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
    let samples = Array(repeating: Int16(1_200), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    analyzer.begin(format: format)
    analyzer.consumePCM(bytes, time: 0, format: format, frameCount: 10)
    analyzer.consumePCM(bytes, time: 1, format: format, frameCount: 10)
    analyzer.finish()

    for _ in 0..<80 where await capture.result == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let result = await capture.result
    #expect(result?.finishReason == .naturalEnd)
    #expect(result?.checkpoint.coverage ?? 1 < 0.95)
    #expect(result?.timeline == nil)
}

@Test func sparseTimelineIsVisibleAsDiagnosticOnly() {
    let identity = MusicHapticsIdentity(title: "Sparse", artist: "Artist", durationMilliseconds: 180_000)
    let sparse = MusicHapticsTimeline(
        identity: identity,
        duration: 180,
        analyzedDuration: 180,
        analysisCoverage: 1,
        events: [MusicHapticsEvent(time: 1, intensity: 0.4, sharpness: 0.2, kind: .transient)]
    )
    #expect(sparse.timelineSuspiciouslySparse)
    #expect(sparse.eventDensity > 0)
}

@Test func streamingPCMCompletesAfterCoverageThreshold() async {
    let identity = MusicHapticsIdentity(title: "Stream", artist: "Artist", durationMilliseconds: 10_000)
    let capture = TimelineCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(identity: identity, duration: 10) { timeline in
        Task { await capture.record(timeline) }
    }
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 1,
        sampleType: .int16,
        interleaved: true,
        bytesPerFrame: 2,
        bytesPerSample: 2
    )!
    let samples = Array(repeating: Int16(1_200), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    analyzer.begin(format: format)
    for second in 0..<10 {
        analyzer.consumePCM(bytes, time: Double(second), format: format, frameCount: 10)
    }
    analyzer.finish()
    for _ in 0..<40 where await capture.timeline == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let timeline = await capture.timeline
    #expect(timeline?.isComplete == true)
    #expect(timeline?.analysisCoverage ?? 0 >= 0.95)
}

@Test func streamingPCMUsesDeclaredFloat32Format() async {
    let identity = MusicHapticsIdentity(title: "Float stream", artist: "Artist", durationMilliseconds: 1_000)
    let capture = TimelineCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(identity: identity, duration: 1) { timeline in
        Task { await capture.record(timeline) }
    }
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 1,
        sampleType: .float32,
        interleaved: true,
        bytesPerFrame: 4,
        bytesPerSample: 4
    )!
    let samples = Array(repeating: Float32(0.05), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }

    analyzer.begin(format: format)
    analyzer.consumePCM(bytes, time: 0, format: format, frameCount: samples.count)
    analyzer.finish()
    for _ in 0..<40 where await capture.timeline == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }

    let event = await capture.timeline?.events.first
    #expect(await capture.timeline?.isComplete == true)
    #expect(event != nil)
    #expect(event?.intensity ?? 1 < 0.65)
}

@Test func streamingPCMUsesDeclaredBigEndianNonInterleavedLayout() async {
    let identity = MusicHapticsIdentity(title: "Planar stream", artist: "Artist", durationMilliseconds: 1_000)
    let capture = TimelineCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(identity: identity, duration: 1) { timeline in
        Task { await capture.record(timeline) }
    }
    let format = MusicHapticsPCMFormat(
        sampleRate: 10,
        channels: 2,
        sampleType: .int16,
        interleaved: false,
        bytesPerFrame: 4,
        bytesPerSample: 2,
        isBigEndian: true
    )!
    let samples = Array(repeating: Int16(1_200), count: 10)
    let channelBytes = samples.reduce(into: Data()) { data, sample in
        let bits = UInt16(bitPattern: sample)
        data.append(UInt8(bits >> 8))
        data.append(UInt8(bits & 0xFF))
    }
    var bytes = channelBytes
    bytes.append(channelBytes)

    analyzer.begin(format: format)
    analyzer.consumePCM(bytes, time: 0, format: format, frameCount: samples.count)
    analyzer.finish()
    for _ in 0..<40 where await capture.timeline == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }

    let event = await capture.timeline?.events.first
    #expect(await capture.timeline?.isComplete == true)
    #expect(event != nil)
    #expect(event?.intensity ?? 1 < 0.65)
}
