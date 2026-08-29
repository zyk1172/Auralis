import AVFoundation
import Domain
import Foundation
import MusicHaptics
import Testing
@testable import PlaybackEngine

/// The main music URL is an invariant across every Music Haptics path. The
/// sidecar may use a separate low-bitrate analysis source, but it must never
/// become the AVPlayer source.
@Suite("AVFoundation audio fidelity invariant", .serialized)
struct AVFoundationAudioFidelityTests {
    @Test("Music Haptics never replaces the original AVPlayer URL")
    @MainActor
    func hapticsPathsPreserveOriginalPlaybackURL() async throws {
        let originalURL = try #require(
            URL(string: "https://media.example.test/original.flac?quality=original")
        )
        let analysisURL = try #require(
            URL(string: "https://haptics.example.test/sidecar.mp3?bitrate=96")
        )
        let track = Track(
            id: TrackID(rawValue: "fidelity"),
            serverID: "server",
            albumID: "album",
            artistID: "artist",
            title: "Fidelity",
            artistName: "Artist",
            albumTitle: "Album",
            duration: 60,
            streamURL: originalURL
        )
        let identity = MusicHapticsIdentity(
            globalID: "server:fidelity",
            serverID: "server",
            remoteID: "fidelity",
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle,
            durationMilliseconds: 60_000
        )
        let lookaheadRequest = MusicHapticsAnalysisRequest(
            identity: identity,
            favorite: false,
            duration: 60,
            analysisSource: .remoteLookahead(
                MusicHapticsRemoteLookaheadSource(url: analysisURL, bitrate: 96)
            )
        )

        let cases: [(label: String, plan: MusicHapticsPlaybackPlan, usesRealtimeFallback: Bool)] = [
            ("disabled", .disabled, false),
            ("system", .system, false),
            ("lookahead", .analyzeLookahead(lookaheadRequest), false),
            ("realtime fallback", .analyzeLookahead(lookaheadRequest), true),
        ]
        let engine = AVFoundationPlaybackEngine()

        for testCase in cases {
            let fallbackSink = testCase.usesRealtimeFallback ? FidelityNoopSink() : nil
            let preparation = MusicHapticsPlaybackPreparation(
                identity: identity,
                favorite: false,
                plan: testCase.plan,
                reason: testCase.label,
                systemAvailability: MusicHapticsSystemAvailability(
                    hasISRC: false,
                    active: false,
                    timelineAvailable: false
                ),
                fullTimelineExists: false,
                partialExists: false,
                analysisSink: nil,
                realtimeFallbackSink: fallbackSink
            )

            engine.setMusicHapticsPlaybackPreparation(preparation)
            try await engine.play(track: track)

            if let fallbackSink {
                engine.activateMusicHapticsRealtimeFallback(
                    preparationID: preparation.id,
                    sink: fallbackSink
                )
            }

            #expect(
                engine.currentPlaybackURLForTesting == originalURL,
                "\(testCase.label) changed the main AVPlayer URL"
            )
            engine.stop()
        }
    }
}

private final class FidelityNoopSink: MusicHapticsAnalysisSink, @unchecked Sendable {
    func tapAttached() {}
    func begin(format: MusicHapticsPCMFormat) {}
    func consumePCM(
        _ bytes: Data,
        time: TimeInterval,
        format: MusicHapticsPCMFormat,
        frameCount: Int
    ) {}
    func pause() {}
    func resume() {}
    func seek(to position: TimeInterval) {}
    func finish() {}
    func finishPartial(reason: MusicHapticsAnalysisFinishReason) {}
    func cancel() {}
}
