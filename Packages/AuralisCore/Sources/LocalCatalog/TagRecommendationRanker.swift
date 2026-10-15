// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import Foundation

/// Explicit content constraints, independent of private listening/favorite history.
public struct TagRecommendationQuery: Sendable {
    public var includeTags: [String]
    public var preferTags: [String]
    /// At least one group must match completely (OR of AND clauses), in addition to includeTags.
    public var anyTagGroups: [[String]]
    /// Zero keeps preferences soft when a positive hard condition exists.
    public var minimumPreferredMatches: Int
    public var excludeTags: [String]
    public var numericRanges: [String: ClosedRange<Int>]
    public var excludedTrackIDs: Set<String>
    public var minimumConfidence: Double
    public var maxPerArtist: Int
    public var maxPerAlbum: Int
    public var limit: Int

    public init(
        includeTags: [String] = [], preferTags: [String] = [], excludeTags: [String] = [],
        anyTagGroups: [[String]] = [], minimumPreferredMatches: Int = 0,
        numericRanges: [String: ClosedRange<Int>] = [:], excludedTrackIDs: Set<String> = [],
        minimumConfidence: Double = 0.35, maxPerArtist: Int = 2, maxPerAlbum: Int = 2, limit: Int = 20
    ) {
        self.includeTags = includeTags
        self.preferTags = preferTags
        self.anyTagGroups = anyTagGroups
        self.minimumPreferredMatches = minimumPreferredMatches
        self.excludeTags = excludeTags
        self.numericRanges = numericRanges
        self.excludedTrackIDs = excludedTrackIDs
        self.minimumConfidence = minimumConfidence
        self.maxPerArtist = max(1, min(maxPerArtist, 10))
        self.maxPerAlbum = max(1, min(maxPerAlbum, 10))
        self.limit = max(1, min(limit, 100))
    }

    public static let numericUpperBounds: [String: Int] = [
        "energy": 10, "tempo": 5, "acousticness": 5, "danceability": 5,
        "instrumentalness": 5, "liveness": 5, "speechiness": 5, "valence": 5, "complexity": 5,
    ]

    public var hasIntent: Bool {
        !includeTags.isEmpty || !preferTags.isEmpty || !anyTagGroups.isEmpty || !numericRanges.isEmpty
    }

    public var hasHardTagConditions: Bool {
        !includeTags.isEmpty || !anyTagGroups.isEmpty || minimumPreferredMatches > 0
            || !excludeTags.isEmpty || !numericRanges.isEmpty
    }

    public func validated() throws -> TagRecommendationQuery {
        var result = self
        func resolve(_ tags: [String]) throws -> [String] {
            try Set(tags.map { raw in
                guard let definition = RecommendationIndexTaxonomy.resolve(raw) else {
                    throw TagRecommendationError.invalidTag(raw)
                }
                return definition.id.rawValue
            }).sorted()
        }
        result.includeTags = try resolve(includeTags)
        result.preferTags = try resolve(preferTags)
        result.excludeTags = try resolve(excludeTags)
        guard anyTagGroups.count <= 20,
              anyTagGroups.allSatisfy({ !$0.isEmpty && $0.count <= 20 }) else {
            throw TagRecommendationError.invalidRange("anyTagGroups (1...20 tags per group, at most 20 groups)")
        }
        result.anyTagGroups = try Array(Set(anyTagGroups.map { try resolve($0) }))
            .sorted { $0.lexicographicallyPrecedes($1) }
        guard (0...result.preferTags.count).contains(minimumPreferredMatches) else {
            throw TagRecommendationError.invalidRange("minimumPreferredMatches")
        }
        for (dimension, range) in numericRanges {
            guard let upper = Self.numericUpperBounds[dimension],
                  range.lowerBound >= 1, range.upperBound <= upper else {
                throw TagRecommendationError.invalidRange(dimension)
            }
        }
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
            throw TagRecommendationError.invalidRange("minimumConfidence")
        }
        guard result.hasIntent else {
            throw TagRecommendationError.emptyIntent
        }
        return result
    }
}

public enum TagRecommendationError: Error, LocalizedError, Sendable {
    case invalidTag(String), invalidRange(String), emptyIntent
    public var errorDescription: String? {
        switch self {
        case let .invalidTag(value): "标签未知或有歧义：\(value)。请用 taxonomy 工具选择稳定 TagID。"
        case let .invalidRange(value): "无效的推荐数值范围：\(value)"
        case .emptyIntent: "请提供必需标签、偏好标签或数值范围；不会从整库随机补足。"
        }
    }
}

public struct TagRecommendationCandidate: Sendable {
    public let track: Track
    public let tags: [String: Double]
    public let numericFeatures: [String: Int]
    public init(track: Track, tags: [String: Double], numericFeatures: [String: Int] = [:]) {
        self.track = track
        self.tags = tags
        self.numericFeatures = numericFeatures
    }
}

public struct TagRecommendationPick: Sendable {
    public let track: Track
    public let score: Double
    public let matchedTags: [String]
}

/// Confidence-weighted, dimension-balanced content matching followed by MMR-style diversity.
/// Selection traverses the whole valid candidate set before imposing result limits.
public enum TagRecommendationRanker {
    public static func applyDiversityLimits(_ tracks: [Track], query: TagRecommendationQuery) -> [Track] {
        var artists = [String: Int](), albums = [String: Int](), recordings = Set<String>()
        return Array(tracks.filter { track in
            let artistKey = artist(track), albumKey = album(track)
            guard artists[artistKey, default: 0] < query.maxPerArtist,
                  albumKey.map({ albums[$0, default: 0] < query.maxPerAlbum }) ?? true,
                  recordings.insert(recording(track)).inserted else { return false }
            artists[artistKey, default: 0] += 1
            if let albumKey { albums[albumKey, default: 0] += 1 }
            return true
        }.prefix(query.limit))
    }

    /// Caller validates/normalizes the query once, before filtering a catalog.
    public static func satisfiesHardConstraints(_ candidate: TagRecommendationCandidate, query: TagRecommendationQuery) -> Bool {
        let reliable = Set(candidate.tags.filter { $0.value.isFinite && $0.value >= query.minimumConfidence }.keys)
        return Set(query.includeTags).isSubset(of: reliable)
            && (query.anyTagGroups.isEmpty || query.anyTagGroups.contains { Set($0).isSubset(of: reliable) })
            && reliable.intersection(query.preferTags).count >= query.minimumPreferredMatches
            && Set(query.excludeTags).isDisjoint(with: Set(candidate.tags.keys))
            && !query.excludedTrackIDs.contains(identity(candidate.track))
            && query.numericRanges.allSatisfy { dimension, range in candidate.numericFeatures[dimension].map(range.contains) == true }
    }

    public static func recommend(
        candidates: [TagRecommendationCandidate], query raw: TagRecommendationQuery,
        existingTracks: [Track] = []
    ) throws -> [TagRecommendationPick] {
        let query = try raw.validated()
        let include = Set(query.includeTags), prefer = Set(query.preferTags)
        let groupTags = Set(query.anyTagGroups.flatMap { $0 })
        let scoringTags = prefer.isEmpty ? groupTags : prefer
        let preferences = Dictionary(grouping: scoringTags.sorted(), by: { $0.split(separator: ".").first.map(String.init) ?? "" })
        let existingIDs = Set(existingTracks.map(identity))
        let existingRecordings = Set(existingTracks.map(recording))
        let eligible = candidates.filter { candidate in
            let tags = Set(candidate.tags.filter { $0.value.isFinite && $0.value >= query.minimumConfidence }.keys)
            return !existingIDs.contains(identity(candidate.track))
                && !existingRecordings.contains(recording(candidate.track))
                && satisfiesHardConstraints(candidate, query: query)
                && (prefer.isEmpty || !include.isEmpty || !groupTags.isEmpty || !query.numericRanges.isEmpty || !prefer.isDisjoint(with: tags))
        }
        let frequencies = eligible.reduce(into: [String: Int]()) { counts, candidate in
            for (tag, confidence) in candidate.tags where confidence.isFinite && confidence >= query.minimumConfidence { counts[tag, default: 0] += 1 }
        }
        let weights = Dictionary(uniqueKeysWithValues: scoringTags.map { tag in
            (tag, 1 + log(Double(eligible.count + 1) / Double(frequencies[tag, default: 0] + 1)))
        })
        let byID = Dictionary(eligible.map { (identity($0.track), $0) }, uniquingKeysWith: { a, _ in a })
        // Keep the best available encoding of one recording, after hard filters have been applied.
        var seenRecordings = Set<String>()
        let uniqueTracks = eligible.map(\.track).sorted {
            let lhs = TrackQuality.score($0), rhs = TrackQuality.score($1)
            return lhs == rhs ? identity($0) < identity($1) : lhs > rhs
        }.filter { seenRecordings.insert(recording($0)).inserted }
        var pool: [(pick: TagRecommendationPick, tags: Set<String>, redundancy: Double, artist: String, album: String?, id: String)] = uniqueTracks.compactMap { track in
            guard let candidate = byID[identity(track)] else { return nil }
            let matched = Set(candidate.tags.filter { $0.value.isFinite && $0.value >= query.minimumConfidence }.keys)
            let relevance: Double
            if scoringTags.isEmpty { relevance = 1 }
            else {
                // Balance dimensions, then reward additional distinct matches within each dimension.
                let balanced = preferences.keys.sorted().reduce(0.0) { sum, dimension in
                    let tags = preferences[dimension, default: []]
                    let denominator = tags.map { weights[$0, default: 1] }.max() ?? 1
                    let evidence = tags.map { tag in
                        matched.contains(tag) ? min(1, candidate.tags[tag, default: 0]) * weights[tag, default: 1] / denominator : 0
                    }.max() ?? 0
                    return sum + evidence
                } / Double(preferences.count)
                let coverage = scoringTags.sorted().reduce(0.0) { sum, tag in
                    sum + (matched.contains(tag) ? min(1, candidate.tags[tag, default: 0]) * weights[tag, default: 1] : 0)
                } / scoringTags.sorted().reduce(0.0) { $0 + weights[$1, default: 1] }
                relevance = 0.75 * balanced + 0.25 * coverage
            }
            let confidence = matched.map { min(1, candidate.tags[$0, default: 0]) }.max() ?? 0
            return (TagRecommendationPick(
                track: track, score: 0.9 * relevance + 0.1 * confidence,
                matchedTags: Array(matched.intersection(include.union(prefer).union(groupTags))).sorted()
            ), matched, 0, artist(track), album(track), identity(track))
        }
        var artists = [String: Int](), albums = [String: Int]()
        for track in existingTracks {
            artists[artist(track), default: 0] += 1
            if let key = album(track) { albums[key, default: 0] += 1 }
        }
        var selected: [TagRecommendationPick] = []
        while selected.count < query.limit && !pool.isEmpty {
            var best: Int?, bestScore = -Double.infinity
            for (index, item) in pool.enumerated() {
                let artistCount = artists[item.artist, default: 0]
                let albumCount = item.album.map { albums[$0, default: 0] } ?? 0
                guard artistCount < query.maxPerArtist, albumCount < query.maxPerAlbum else { continue }
                let score = item.pick.score - 0.18 * Double(artistCount) - 0.10 * Double(albumCount) - 0.08 * item.redundancy
                if score > bestScore || (score == bestScore && best.map { item.id < pool[$0].id } == true) {
                    best = index; bestScore = score
                }
            }
            guard let best else { break }
            let item = pool.remove(at: best)
            selected.append(item.pick)
            artists[item.artist, default: 0] += 1
            if let key = item.album { albums[key, default: 0] += 1 }
            for index in pool.indices {
                let overlap = Double(pool[index].tags.intersection(item.tags).count) / Double(max(1, pool[index].tags.union(item.tags).count))
                pool[index].redundancy = max(pool[index].redundancy, overlap)
            }
        }
        return selected
    }

    private static func identity(_ track: Track) -> String { "\(track.serverID.rawValue):\(track.id.rawValue)" }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func artist(_ track: Track) -> String {
        let name = normalize(track.artistName)
        return name.isEmpty ? "\(track.serverID.rawValue):\(track.artistID.rawValue)" : name
    }
    private static func album(_ track: Track) -> String? {
        let name = normalize(track.albumTitle)
        return name.isEmpty ? nil : "\(artist(track))|\(name)"
    }
    private static func recording(_ track: Track) -> String { TrackQuality.recordingKey(for: track) }
}
