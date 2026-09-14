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
        var seen = Set<String>()
        return (remoteOnly + local.artists).filter { artist in
            seen.insert(identityKey(serverID: artist.serverID, remoteID: artist.id.rawValue)).inserted
        }
    }

    public static func mergedAlbums(
        remote: [Album],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Album] {
        let local = snapshot ?? self.snapshot()
        let remoteOnly = remote.filter { $0.serverID != localServerID }
        var seen = Set<String>()
        return (remoteOnly + local.albums).filter { album in
            seen.insert(identityKey(serverID: album.serverID, remoteID: album.id.rawValue)).inserted
        }
    }

    public static func mergedTracks(
        remote: [Track],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Track] {
        let local = snapshot ?? self.snapshot()
        let remoteOnly = remote.filter { $0.serverID != localServerID }

        // The catalog is an identity-preserving source of truth. Two tracks that sound like the
        // same recording can still represent different servers, a server copy and a true local
        // file, or distinct encodings that the user must be able to browse and address separately.
        // Recording-level quality deduplication therefore belongs only in recommendation/smart-
        // queue consumers (`TrackQuality.deduplicatedPreferringQuality`), never at this boundary.
        var seen = Set<String>()
        return (remoteOnly + local.tracks).filter { track in
            seen.insert(identityKey(serverID: track.serverID, remoteID: track.id.rawValue)).inserted
        }
    }

    /// Swift `Genre` is intentionally source-agnostic, so provenance cannot be removed by serverID.
    /// Callers that rebuild an already-overlaid catalog must first use `removingLocalGenreContribution`
    /// with the previous snapshot, then add the replacement local snapshot here.
    public static func mergedGenres(
        remote: [Genre],
        local snapshot: LocalCatalogOverlaySnapshot? = nil
    ) -> [Genre] {
        let local = snapshot ?? self.snapshot()
        var order: [String] = []
        var merged: [String: Genre] = [:]
        for genre in remote + local.genres {
            let key = normalizedGenreKey(genre.name)
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

    /// Removes exactly the previous local overlay's contribution from a mixed genre snapshot.
    /// This prevents repeated scans from accumulating counts while preserving server-only genres.
    public static func removingLocalGenreContribution(
        from mixed: [Genre],
        previousLocal: LocalCatalogOverlaySnapshot
    ) -> [Genre] {
        let localCounts = Dictionary(grouping: previousLocal.genres, by: { normalizedGenreKey($0.name) })
            .mapValues { $0.reduce(0) { $0 + $1.songCount } }
        return mixed.compactMap { genre in
            let key = normalizedGenreKey(genre.name)
            let remainder = max(0, genre.songCount - (localCounts[key] ?? 0))
            guard remainder > 0 else { return nil }
            var copy = genre
            copy.songCount = remainder
            return copy
        }
    }

    /// Domain deliberately does not depend on LocalCatalog's `GlobalID` type. Build a stable,
    /// collision-resistant-enough composite key locally so the overlay remains dependency-safe.
    private static func identityKey(serverID: ServerID, remoteID: String) -> String {
        "\(serverID.rawValue)\u{1F}\(remoteID)"
    }

    private static func normalizedGenreKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}