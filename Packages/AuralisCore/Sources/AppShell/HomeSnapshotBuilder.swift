import Domain
import Foundation
import LocalCatalog

struct HomeSnapshot: Sendable {
    var favorites: [Track]
    var mostPlayed: [Track]
    var recentlyPlayed: [Track]
    var recentlyAdded: [Track]
    var longUnplayed: [Track]
    var neverPlayed: [Track]
    var recentlyAdded30Days: [Track]
    var favoriteRandom: [Track]
    var topArtists: [Artist]
    var topAlbums: [Album]
    var artistPlayCounts: [ArtistID: Int]
    var albumPlayCounts: [AlbumID: Int]
}

/// Pure, testable home-data projection. It builds lookup tables once and reuses
/// a single added-date sort, avoiding repeated `first(where:)` scans and duplicate
/// full-library sorting for each shelf.
enum HomeSnapshotBuilder {
    static func build(
        catalog: LibraryCatalog,
        playCounts: [TrackID: Int],
        recentIDs: [TrackID],
        addedDates: [GlobalID: Date],
        dislikedTrackIDs: Set<GlobalID> = [],
        now: Date = .now
    ) -> HomeSnapshot {
        let tracks = catalog.tracks
        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let recentSet = Set(recentIDs)
        let addedDate: (Track) -> Date = { track in
            addedDates[GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)] ?? .distantPast
        }
        let isDisliked: (Track) -> Bool = { track in
            dislikedTrackIDs.contains(GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
        }

        // 浏览型货架（收藏 / 最常听 / 最近播放 / 最近添加）完整保留 disliked；
        // 只有“自动发现”货架（很久没听 / 从未播放 / 收藏里随便听）硬排除 disliked。
        let favorites = tracks.filter(\.isFavorite)
        let mostPlayed = tracks
            .filter { (playCounts[$0.id] ?? 0) > 0 }
            .sorted { (playCounts[$0.id] ?? 0, $0.title) > (playCounts[$1.id] ?? 0, $1.title) }
        let recentlyPlayed = recentIDs.compactMap { trackByID[$0] }
        let recentlyAdded = tracks.sorted { addedDate($0) > addedDate($1) }
        let longUnplayed = Array(mostPlayed.filter { !recentSet.contains($0.id) && !isDisliked($0) }.prefix(24))
        let neverPlayed = Array(recentlyAdded
            .filter { (playCounts[$0.id] ?? 0) == 0 && !recentSet.contains($0.id) && !isDisliked($0) }
            .prefix(24))
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let recentlyAdded30Days = Array(recentlyAdded.filter { addedDate($0) >= cutoff }.prefix(24))

        var artistTotals: [ArtistID: Int] = [:]
        var albumTotals: [AlbumID: Int] = [:]
        artistTotals.reserveCapacity(catalog.artists.count)
        albumTotals.reserveCapacity(catalog.albums.count)
        for track in tracks {
            let count = playCounts[track.id] ?? 0
            guard count > 0 else { continue }
            artistTotals[track.artistID, default: 0] += count
            albumTotals[track.albumID, default: 0] += count
        }

        let topArtists = Array(catalog.artists
            .filter { (artistTotals[$0.id] ?? 0) > 0 }
            .sorted { (artistTotals[$0.id] ?? 0, $0.name) > (artistTotals[$1.id] ?? 0, $1.name) }
            .prefix(24))
        let topAlbums = Array(catalog.albums
            .filter { (albumTotals[$0.id] ?? 0) > 0 }
            .sorted { (albumTotals[$0.id] ?? 0, $0.title) > (albumTotals[$1.id] ?? 0, $1.title) }
            .prefix(24))

        return HomeSnapshot(
            favorites: favorites,
            mostPlayed: mostPlayed,
            recentlyPlayed: recentlyPlayed,
            recentlyAdded: recentlyAdded,
            longUnplayed: longUnplayed,
            neverPlayed: neverPlayed,
            recentlyAdded30Days: recentlyAdded30Days,
            favoriteRandom: Array(favorites.filter { !isDisliked($0) }.shuffled().prefix(18)),
            topArtists: topArtists,
            topAlbums: topAlbums,
            artistPlayCounts: artistTotals,
            albumPlayCounts: albumTotals
        )
    }
}