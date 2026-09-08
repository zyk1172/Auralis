// SPDX-License-Identifier: GPL-3.0-only
@testable import AppShell
import Application
import Domain
import Foundation
import MusicHaptics
import Testing

@Test("Music Haptics uses the original remote playback URL without a sidecar")
func remoteHapticsSourceUsesOriginalEncoding() async throws {
    let identity = testIdentity(remoteID: "track")
    let playbackURL = URL(string: "https://music.example.test/stream/track?token=old")!
    let provider = AuralisMusicHapticsAnalysisSourceProvider(
        connector: InjectedHapticsSourceConnector(refreshedPlaybackURL: nil)
    )

    let primary = try #require(
        await provider.source(for: identity, playbackURL: playbackURL)
    )
    #expect(primary == .remoteOriginal(playbackURL))
    #expect(primary.mode == .remoteOriginal)
}

@Test("Remote decoder recovery refreshes the same original stream only once")
func remoteHapticsFallbackRefreshesOriginalURL() async throws {
    let identity = testIdentity(remoteID: "track-refresh")
    let initialURL = URL(string: "https://music.example.test/stream/track?token=old")!
    let refreshedURL = URL(string: "https://music.example.test/stream/track?token=new")!
    let provider = AuralisMusicHapticsAnalysisSourceProvider(
        connector: InjectedHapticsSourceConnector(refreshedPlaybackURL: refreshedURL)
    )
    let primary = try #require(await provider.source(for: identity, playbackURL: initialURL))

    let fallbacks = await provider.fallbackSources(
        for: identity,
        playbackURL: initialURL,
        after: primary
    )
    #expect(fallbacks == [.remoteOriginal(refreshedURL)])
    #expect(fallbacks.allSatisfy { $0.mode == .remoteOriginal })
}

@Test("A local playback URL remains a local analysis source")
func localHapticsSourceIsNotRemote() async throws {
    let identity = testIdentity(remoteID: "local-track")
    let localURL = URL(fileURLWithPath: "/private/tmp/auralis-local.flac")
    let provider = AuralisMusicHapticsAnalysisSourceProvider(
        connector: InjectedHapticsSourceConnector(refreshedPlaybackURL: nil)
    )

    #expect(await provider.source(for: identity, playbackURL: localURL) == .localFile(localURL))
    #expect(await provider.fallbackSources(for: identity, playbackURL: localURL, after: .localFile(localURL)).isEmpty)
}

private func testIdentity(remoteID: String) -> MusicHapticsIdentity {
    MusicHapticsIdentity(
        globalID: "server:\(remoteID)",
        serverID: "server",
        remoteID: remoteID,
        title: "Track",
        artist: "Artist",
        durationMilliseconds: 180_000
    )
}

private actor InjectedHapticsSourceConnector: ServerConnecting {
    let refreshedPlaybackURL: URL?

    init(refreshedPlaybackURL: URL?) {
        self.refreshedPlaybackURL = refreshedPlaybackURL
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ConnectorCall.unexpected
    }

    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        refreshedPlaybackURL
    }
}

private enum ConnectorCall: Error {
    case unexpected
}
