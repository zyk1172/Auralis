import Domain
import Foundation

public struct RecommendationQuery: Hashable, Sendable {
    public var languages: Set<String>
    public var genres: Set<String>
    public var yearRange: ClosedRange<Int>?
    public var favoritesOnly: Bool
    public var maximumTracksPerArtist: Int
    public var limit: Int

    public init(languages: Set<String> = [], genres: Set<String> = [], yearRange: ClosedRange<Int>? = nil, favoritesOnly: Bool = false, maximumTracksPerArtist: Int = 2, limit: Int = 20) {
        self.languages = languages
        self.genres = genres
        self.yearRange = yearRange
        self.favoritesOnly = favoritesOnly
        self.maximumTracksPerArtist = maximumTracksPerArtist
        self.limit = limit
    }
}

public enum HybridRecommendationEngine {
    public static func recommend(tracks: [Track], query: RecommendationQuery, history: [PlayHistory] = []) -> [Track] {
        let recentIDs = Set(history.sorted(by: { $0.playedAt > $1.playedAt }).prefix(30).map(\.trackID))
        let filtered = tracks.filter { track in
            (query.languages.isEmpty || track.language.map(query.languages.contains) == true)
                && (query.genres.isEmpty || !query.genres.isDisjoint(with: track.genres))
                && (query.yearRange == nil || track.year.map { query.yearRange?.contains($0) == true } == true)
                && (!query.favoritesOnly || track.isFavorite)
        }
        let ranked = filtered.sorted { lhs, rhs in
            score(lhs, recentIDs: recentIDs) > score(rhs, recentIDs: recentIDs)
        }
        var artistCounts: [ArtistID: Int] = [:]
        var result: [Track] = []
        for track in ranked {
            guard artistCounts[track.artistID, default: 0] < max(1, query.maximumTracksPerArtist) else { continue }
            artistCounts[track.artistID, default: 0] += 1
            result.append(track)
            if result.count >= max(0, query.limit) { break }
        }
        return result
    }

    public static func validate(trackIDs: [TrackID], library: [Track]) -> Bool {
        let known = Set(library.map(\.id))
        return trackIDs.allSatisfy(known.contains)
    }

    private static func score(_ track: Track, recentIDs: Set<TrackID>) -> Double {
        let favorite = track.isFavorite ? 2.0 : 0
        let rating = Double(track.rating ?? 0) * 0.25
        let freshness = recentIDs.contains(track.id) ? -1.5 : 0.7
        return favorite + rating + freshness
    }
}

public enum MusicAssistantTool: String, CaseIterable, Codable, Sendable {
    case searchLibrary, filterTracks, getTrack, getAlbum, getArtist, getSimilarTracks
    case getRecentHistory, getLeastPlayed, getFavorites, getCurrentQueue
    case replaceQueue, appendToQueue, playNext, createPlaylist, addTracksToPlaylist
}
