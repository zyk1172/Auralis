@testable import AppShell
import Application
import Domain
import Foundation
import MusicHaptics
import Testing

@Test("remote haptics sidecar failure refreshes independent progressive playback URL")
func remoteHapticsFallbackRefreshesProgressiveURL() async throws {
    let identity = MusicHapticsIdentity(
        globalID: "server:track",
        serverID: "server",
        remoteID: "track",
        title: "Track",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let initialPlaybackURL = URL(string: "https://music.example.test/stream/track?token=old")!
    let refreshedPlaybackURL = URL(string: "https://music.example.test/stream/track?token=new")!
    let sidecarURL = URL(string: "https://music.example.test/stream/track?maxBitRate=96&format=mp3&token=old")!
    let refreshedSidecarURL = URL(string: "https://music.example.test/stream/track?maxBitRate=96&format=mp3&token=new")!
    let provider = AuralisMusicHapticsAnalysisSourceProvider(
        connector: InjectedHapticsSourceConnector(
            initialSidecarURL: sidecarURL,
            refreshedSidecarURL: refreshedSidecarURL,
            refreshedPlaybackURL: refreshedPlaybackURL
        )
    )

    let primary = try #require(
        await provider.source(for: identity, playbackURL: initialPlaybackURL)
    )
    #expect(primary == .remoteLookahead(.init(url: sidecarURL, bitrate: 96, format: "mp3")))

    let fallbacks = await provider.fallbackSources(
        for: identity,
        playbackURL: initialPlaybackURL,
        after: primary
    )
    #expect(fallbacks == [
        .remoteLookahead(.init(url: refreshedSidecarURL, bitrate: 96, format: "mp3")),
        .remoteProgressive(refreshedPlaybackURL),
    ])
}

@Test("missing haptics sidecar starts progressive analysis and still refreshes after decoder failure")
func missingRemoteHapticsSidecarUsesIndependentProgressiveSource() async throws {
    let identity = MusicHapticsIdentity(
        globalID: "server:track-without-sidecar",
        serverID: "server",
        remoteID: "track-without-sidecar",
        title: "Track",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
    let playbackURL = URL(string: "https://music.example.test/stream/track-without-sidecar")!
    let refreshedPlaybackURL = URL(string: "https://music.example.test/stream/track-without-sidecar?token=fresh")!
    let provider = AuralisMusicHapticsAnalysisSourceProvider(
        connector: InjectedHapticsSourceConnector(
            initialSidecarURL: nil,
            refreshedSidecarURL: nil,
            refreshedPlaybackURL: refreshedPlaybackURL
        )
    )

    let primary = try #require(await provider.source(for: identity, playbackURL: playbackURL))
    #expect(primary == .remoteProgressive(playbackURL))

    let fallbacks = await provider.fallbackSources(
        for: identity,
        playbackURL: playbackURL,
        after: primary
    )
    #expect(fallbacks == [.remoteProgressive(refreshedPlaybackURL)])
}

private actor InjectedHapticsSourceConnector: ServerConnecting {
    let initialSidecarURL: URL?
    let refreshedSidecarURL: URL?
    let refreshedPlaybackURL: URL?
    private var sidecarCallCount = 0

    init(
        initialSidecarURL: URL?,
        refreshedSidecarURL: URL?,
        refreshedPlaybackURL: URL?
    ) {
        self.initialSidecarURL = initialSidecarURL
        self.refreshedSidecarURL = refreshedSidecarURL
        self.refreshedPlaybackURL = refreshedPlaybackURL
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ConnectorCall.unexpected
    }

    func musicHapticsAnalysisURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        sidecarCallCount += 1
        return sidecarCallCount == 1 ? initialSidecarURL : refreshedSidecarURL
    }

    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        refreshedPlaybackURL
    }
}

private enum ConnectorCall: Error {
    case unexpected
}
