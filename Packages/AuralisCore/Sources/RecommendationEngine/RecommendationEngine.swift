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
        // 推荐排序不使用收藏、评分或播放历史；这些都是个人行为数据，
        // 只在用户明确要求“只看收藏”时作为筛选条件参与。
        _ = history
        let filtered = tracks.filter { track in
            (query.languages.isEmpty || track.language.map(query.languages.contains) == true)
                && (query.genres.isEmpty || !query.genres.isDisjoint(with: track.genres))
                && (query.yearRange == nil || track.year.map { query.yearRange?.contains($0) == true } == true)
                && (!query.favoritesOnly || track.isFavorite)
        }
        let ranked = filtered.sorted { lhs, rhs in
            objectiveOrder(lhs, rhs)
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

    /// 无明确偏好时使用稳定、可复现的资料库顺序，避免私人行为数据塑造结果。
    private static func objectiveOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let artist = lhs.artistName.localizedStandardCompare(rhs.artistName)
        if artist != .orderedSame { return artist == .orderedAscending }
        let title = lhs.title.localizedStandardCompare(rhs.title)
        if title != .orderedSame { return title == .orderedAscending }
        return lhs.id.rawValue.localizedStandardCompare(rhs.id.rawValue) == .orderedAscending
    }
}

public enum MusicAssistantTool: String, CaseIterable, Codable, Sendable {
    case searchLibrary, filterTracks, getTrack, getAlbum, getArtist, getSimilarTracks
    case getRecentHistory, getLeastPlayed, getFavorites, getCurrentQueue
    case replaceQueue, appendToQueue, playNext, createPlaylist, addTracksToPlaylist
}
