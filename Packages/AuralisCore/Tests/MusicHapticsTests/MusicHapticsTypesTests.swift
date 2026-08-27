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

@Test func streamingPCMCompletesAfterCoverageThreshold() async {
    let identity = MusicHapticsIdentity(title: "Stream", artist: "Artist", durationMilliseconds: 10_000)
    let capture = TimelineCapture()
    let analyzer = StreamingMusicHapticsAnalyzer(identity: identity, duration: 10) { timeline in
        Task { await capture.record(timeline) }
    }
    let samples = Array(repeating: Int16(1_200), count: 10)
    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    for second in 0..<10 {
        analyzer.consumePCM(bytes, time: Double(second), sampleRate: 10, channels: 1)
    }
    analyzer.finish()
    for _ in 0..<40 where await capture.timeline == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let timeline = await capture.timeline
    #expect(timeline?.isComplete == true)
    #expect(timeline?.analysisCoverage ?? 0 >= 0.95)
}
