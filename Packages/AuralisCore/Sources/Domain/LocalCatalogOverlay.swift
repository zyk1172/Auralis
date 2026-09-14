// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Process-local projection of true local-file entities into the ordinary Auralis catalog.
///
/// The overlay is deliberately not a ServerAccount. `auralis-local` is only an identity namespace
/// for entities that never route through OpenSubsonic. AppShell owns file authorization/scanning;
/// Domain only owns this immutable read snapshot and source-safe merge rules.
public struct LocalCatalogOverlaySnapshot: Sendable {
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
    public var genres: [Genre]

    public init(
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = [],
        genres: [Genre] = []
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.genres = genres
    }

    public static let empty = LocalCatalogOverlaySnapshot()
}

public enum LocalCatalogOverlay {
    public static let localServerID = ServerID(rawValue: "auralis-local")

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value: LocalCatalogOverlaySnapshot = .empty
    }

    private static let storage = Storage()

    public static func replace(with snapshot: LocalCatalogOverlaySnapshot) {
        storage.lock.lock()
        storage.value = snapshot
        storage.lock.unlock()
    }

    public static func snapshot() -> LocalCatalogOverlaySnapshot {
        storage.lock.lock()
        let result = storage.value
        storage.lock.unlock()
        return result
    }

    public static func mergedArtists(
        remote: [Artist],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Artist] {
        let local = snapshot ?? self.snapshot()
        let remoteOnly = remote.filter { $0.serverID != localServerID }
        var seen = Set<GlobalID>()
        return (remoteOnly + local.artists).filter { artist in
            seen.insert(GlobalID(serverID: artist.serverID, remoteID: artist.id.rawValue)).inserted
        }
    }

    public static func mergedAlbums(
        remote: [Album],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Album] {
        let local = snapshot ?? self.snapshot()
        let remoteOnly = remote.filter { $0.serverID != localServerID }
        var seen = Set<GlobalID>()
        return (remoteOnly + local.albums).filter { album in
            seen.insert(GlobalID(serverID: album.serverID, remoteID: album.id.rawValue)).inserted
        }
    }

    public static func mergedTracks(
        remote: [Track],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Track] {
        let local = snapshot ?? self.snapshot()
        let remoteOnly = remote.filter { $0.serverID != localServerID }
        return TrackQuality.deduplicatedPreferringQuality(remoteOnly + local.tracks)
    }

    public static func mergedGenres(
        remote: [Genre],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Genre] {
        let local = snapshot ?? self.snapshot()
        let remoteOnly = remote.filter { $0.serverID != localServerID }
        var order: [String] = []
        var merged: [String: Genre] = [:]
        for genre in remoteOnly + local.genres {
            let key = genre.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if var existing = merged[key] {
                existing.songCount += genre.songCount
                merged[key] = existing
            } else {
                merged[key] = genre
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
