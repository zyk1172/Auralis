// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import Foundation

extension LocalCatalogStore {
    /// Returns only current, hash-verified index entries from explicitly selected servers.
    /// Dislikes and stale classifications are eliminated before ranking and before any limit.
    public func recommendByTags(
        serverIDs: [ServerID], query: TagRecommendationQuery, existingTracks: [Track] = []
    ) throws -> [TagRecommendationPick] {
        _ = try query.validated()
        let candidates = try tagRecommendationCandidates(serverIDs: serverIDs, minimumConfidence: query.minimumConfidence)
        return try TagRecommendationRanker.recommend(candidates: candidates, query: query, existingTracks: existingTracks)
    }

    public func tagRecommendationCandidates(serverIDs: [ServerID], minimumConfidence: Double = 0.35) throws -> [TagRecommendationCandidate] {
        var candidates: [TagRecommendationCandidate] = []
        for serverID in Set(serverIDs) {
            let snapshot = try recommendationIndexSnapshot(serverID: serverID)
            let disliked = try dislikedTrackIDs(serverID: serverID)
            let validIDs = Set(snapshot.lines.filter { line in
                snapshot.states[line.id]?.hash == recommendationIndexContentHash(line)
                    && snapshot.states[line.id]?.hashVersion == RecommendationIndex.contentHashVersion
                    && GlobalID(line.id).map { !disliked.contains($0) } == true
            }.map(\.id))
            let tracks = try allTracks(serverID: serverID)
            let rows = try db.query(
                """
                SELECT t.global_id, t.dimension, t.value, t.confidence
                FROM recommendation_index_v2_tags t
                JOIN recommendation_index_v2_state s ON s.global_id = t.global_id
                WHERE s.server_id = ? AND s.rules_version = ?
                """, [.text(serverID.rawValue), .text(RecommendationIndex.rulesVersion)]
            )
            var tags = [String: [String: Double]](), numeric = [String: [String: Int]]()
            for row in rows {
                guard let id = row["global_id"]?.string, validIDs.contains(id),
                      let dimension = row["dimension"]?.string, let value = row["value"]?.string,
                      let confidence = row["confidence"]?.double, confidence.isFinite else { continue }
                if let definition = RecommendationIndexTaxonomy.byID[TagID(rawValue: value)], definition.dimension.rawValue == dimension {
                    tags[id, default: [:]][value] = confidence
                } else if let upper = TagRecommendationQuery.numericUpperBounds[dimension],
                          let number = Int(value), (1...upper).contains(number), confidence >= minimumConfidence {
                    numeric[id, default: [:]][dimension] = number
                }
            }
            for track in tracks {
                let id = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue).description
                guard validIDs.contains(id) else { continue }
                candidates.append(.init(track: track, tags: tags[id] ?? [:], numericFeatures: numeric[id] ?? [:]))
            }
        }
        return candidates
    }
}
