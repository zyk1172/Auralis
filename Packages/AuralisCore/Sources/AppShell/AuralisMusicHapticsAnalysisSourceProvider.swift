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
        if let playbackURL, !playbackURL.isFileURL {
            // Analyze the same original encoding that AVPlayer receives. The
            // MusicHaptics decoder consumes it incrementally and never asks the
            // server for a bitrate/format-specific sidecar.
            return .remoteOriginal(playbackURL)
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
        // The AVPlayer URL can be a short-lived tokenized address. Refresh the
        // same original encoding for the independent decoder; this does not
        // replace, seek, or mutate the current AVPlayerItem.
        let refreshedOriginalURL = if let serverTrack,
                                      let refreshedPlaybackURL = await connector.refreshStreamURL(
                                    serverID: serverTrack.serverID,
                                    trackID: serverTrack.trackID
                                ) {
            refreshedPlaybackURL
        } else {
            playbackURL
        }
        if let refreshedOriginalURL, !refreshedOriginalURL.isFileURL {
            candidates.append(.remoteOriginal(refreshedOriginalURL))
        }

        // A connector may return a deterministic URL when a server has no
        // tokenized refresh. Do not retry the exact same source indefinitely.
        var seen: Set<MusicHapticsAnalysisSource> = [failedSource]
        return candidates.filter { seen.insert($0).inserted }
    }
}
