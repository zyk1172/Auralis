// SPDX-License-Identifier: GPL-3.0-only
import Domain
import SwiftUI

/// Stable spatial identities for iOS library transitions.
/// GlobalID keeps the transition source isolated across music servers.
enum IOSBrowseTransitionID: Hashable {
    case album(GlobalID)
    case artist(GlobalID)
    case playlist(GlobalID)

    init?(_ destination: BrowseDestination) {
        switch destination {
        case let .album(album):
            self = .album(GlobalID(serverID: album.serverID, remoteID: album.id.rawValue))
        case let .artist(artist):
            self = .artist(GlobalID(serverID: artist.serverID, remoteID: artist.id.rawValue))
        case let .playlist(playlist):
            self = .playlist(GlobalID(serverID: playlist.serverID, remoteID: playlist.id.rawValue))
        default:
            return nil
        }
    }

    static func album(_ album: Album) -> Self {
        .album(GlobalID(serverID: album.serverID, remoteID: album.id.rawValue))
    }

    static func artist(_ artist: Artist) -> Self {
        .artist(GlobalID(serverID: artist.serverID, remoteID: artist.id.rawValue))
    }

    static func playlist(_ playlist: Playlist) -> Self {
        .playlist(GlobalID(serverID: playlist.serverID, remoteID: playlist.id.rawValue))
    }
}

enum IOSNowPlayingTransitionID: Hashable {
    case player
}

extension View {
    /// Marks a source only on iOS. The same AppShell files also compile for
    /// macOS, where these mobile spatial transitions are intentionally absent.
    @ViewBuilder
    func auralisMatchedTransitionSource<ID: Hashable>(
        id: ID?,
        in namespace: Namespace.ID?
    ) -> some View {
#if os(iOS)
        if let id, let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
#else
        self
#endif
    }

    /// Uses the native zoom transition for a known matched source. Reduce
    /// Motion and unmatched routes stay on the platform automatic transition.
    @ViewBuilder
    func auralisZoomNavigationTransition<ID: Hashable>(
        sourceID: ID?,
        in namespace: Namespace.ID?,
        reduceMotion: Bool
    ) -> some View {
#if os(iOS)
        if !reduceMotion, let sourceID, let namespace {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self.navigationTransition(.automatic)
        }
#else
        self
#endif
    }
}
