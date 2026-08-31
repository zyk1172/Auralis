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
        if let serverID = identity.serverID,
           let remoteID = identity.remoteID,
           let url = await connector.musicHapticsAnalysisURL(
               serverID: ServerID(rawValue: serverID),
               trackID: TrackID(rawValue: remoteID)
           ) {
            return .remoteLookahead(.init(url: url, bitrate: 96, format: "mp3"))
        }
        // If the server cannot construct the 96 kbps sidecar, keep the
        // analysis path alive with a separate progressive HTTP decoder. The
        // PlaybackEngine continues to own the original AVPlayerItem; this URL
        // is consumed only by LookaheadMusicHapticsAnalyzer.
        if let playbackURL, !playbackURL.isFileURL {
            return .remoteProgressive(playbackURL)
        }
        return .realtimeTap
    }

    func fallbackSources(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?,
        after failedSource: MusicHapticsAnalysisSource
    ) async -> [MusicHapticsAnalysisSource] {
        guard playbackURL?.isFileURL != true else { return [] }

        var candidates: [MusicHapticsAnalysisSource] = []
        let serverTrack: (serverID: ServerID, trackID: TrackID)? = if let serverID = identity.serverID,
                                                                         let remoteID = identity.remoteID {
            (ServerID(rawValue: serverID), TrackID(rawValue: remoteID))
        } else {
            nil
        }
        if let serverTrack,
           let refreshedURL = await connector.musicHapticsAnalysisURL(
               serverID: serverTrack.serverID,
               trackID: serverTrack.trackID
           ) {
            candidates.append(.remoteLookahead(.init(url: refreshedURL, bitrate: 96, format: "mp3")))
        }

        // The AVPlayer URL can be a short-lived tokenized address. Refresh it
        // for the independent progressive decoder when the sidecar failed;
        // this does not replace, seek, or mutate the current AVPlayerItem.
        let progressiveURL = if let serverTrack,
                                let refreshedPlaybackURL = await connector.refreshStreamURL(
                                    serverID: serverTrack.serverID,
                                    trackID: serverTrack.trackID
                                ) {
            refreshedPlaybackURL
        } else {
            playbackURL
        }
        if let progressiveURL, !progressiveURL.isFileURL {
            candidates.append(.remoteProgressive(progressiveURL))
        }

        // A connector may return a deterministic URL when a server has no
        // tokenized refresh. Do not retry the exact same source indefinitely.
        var seen: Set<MusicHapticsAnalysisSource> = [failedSource]
        return candidates.filter { seen.insert($0).inserted }
    }
}
