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
