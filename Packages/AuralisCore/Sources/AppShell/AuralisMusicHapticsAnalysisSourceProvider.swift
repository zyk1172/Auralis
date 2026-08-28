import Application
import Domain
import Foundation
import MusicHaptics

/// Composition-root adapter: only AppShell knows how a Track maps to a
/// connector/server.  MusicHaptics receives an opaque source and never sees
/// credentials, OpenSubsonic types, or a URL in diagnostics/cache records.
struct AuralisMusicHapticsAnalysisSourceProvider: MusicHapticsAnalysisSourceProvider {
    let connector: any ServerConnecting

    func source(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?
    ) async -> MusicHapticsAnalysisSource? {
        if let playbackURL, playbackURL.isFileURL {
            return .localFile(playbackURL)
        }
        guard let serverID = identity.serverID,
              let remoteID = identity.remoteID,
              let url = await connector.musicHapticsAnalysisURL(
                  serverID: ServerID(rawValue: serverID),
                  trackID: TrackID(rawValue: remoteID)
              )
        else {
            return .realtimeTap
        }
        return .remoteLookahead(.init(url: url, bitrate: 96, format: "mp3"))
    }
}
