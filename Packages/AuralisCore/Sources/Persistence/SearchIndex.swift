import Domain
import Foundation

enum SearchIndex {
    struct Entry: Sendable {
        let track: Track
        let title: String
        let artist: String
        let album: String
        let genres: String
        let aggregate: String
    }

    static func build(_ tracks: some Sequence<Track>) -> [Entry] {
        tracks.map { track in
            let title = normalize(track.title)
            let artist = normalize(track.artistName)
            let album = normalize(track.albumTitle)
            let genres = normalize(track.genres.joined(separator: " "))
            return Entry(
                track: track,
                title: title,
                artist: artist,
                album: album,
                genres: genres,
                aggregate: [title, artist, album, genres].joined(separator: " ")
            )
        }
    }

    static func search(
        _ tracks: some Sequence<Track>,
        query: String,
        offset: Int,
        limit: Int
    ) -> [Track] {
        guard limit > 0 else { return [] }
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let matches = build(tracks).compactMap { entry -> (score: Int, track: Track)? in
            guard tokens.allSatisfy({ entry.aggregate.contains($0) }) else { return nil }

            var score = 0
            if entry.title == normalizedQuery { score += 1_000 }
            if entry.title.hasPrefix(normalizedQuery) { score += 300 }
            if entry.artist == normalizedQuery { score += 250 }
            if entry.artist.hasPrefix(normalizedQuery) { score += 160 }
            if entry.album == normalizedQuery { score += 120 }
            if entry.album.hasPrefix(normalizedQuery) { score += 80 }
            score += tokens.reduce(into: 0) { partial, token in
                if entry.title.contains(token) { partial += 40 }
                if entry.artist.contains(token) { partial += 25 }
                if entry.album.contains(token) { partial += 15 }
                if entry.genres.contains(token) { partial += 5 }
            }
            return (score, entry.track)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = sortKey(for: $0.track)
            let rhs = sortKey(for: $1.track)
            return lhs == rhs ? $0.track.id.rawValue < $1.track.id.rawValue : lhs < rhs
        }
        .map(\.track)

        return page(matches, offset: offset, limit: limit)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func sortKey(for track: Track) -> String {
        let disc = String(format: "%04d", track.discNumber ?? 0)
        let number = String(format: "%06d", track.trackNumber ?? 0)
        return normalize("\(track.artistName) \(track.albumTitle) \(disc) \(number) \(track.title)")
    }
}
