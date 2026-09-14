// SPDX-License-Identifier: GPL-3.0-only
import AIKit
import Domain
import Foundation
import LocalCatalog

/// 云端模型只负责“想到哪些歌可能符合语义”；本类型只携带公开音乐实体文本，
/// 不携带用户曲库 ID。真正是否存在、是否可推荐由本地 Runtime 决定。
struct SemanticRecommendationCandidate: Sendable, Equatable {
    let title: String
    let artist: String?
    let album: String?
}

/// Open-world recall -> closed-world catalog grounding.
///
/// 设计原则：
/// - 批量：一次处理最多 200 个模型候选，禁止逐首 tool round-trip；
/// - 保守：艺人不匹配时宁可漏掉，不把同名歌曲撞错；
/// - 真实：只返回 LocalCatalog 中存在的 GlobalID；
/// - 本地：不喜欢、去重与同艺人上限在 Runtime 执行，模型不能绕过；
/// - 降级：本工具不负责随机补足，命中不足由 Agent 转入现有推荐链路。
enum SemanticCollisionMatcher {
    private struct IndexedTrack {
        let track: Track
        let title: String
        let baseTitle: String
        let artist: String
        let album: String
    }

    private struct Scored {
        let track: Track
        let score: Double
    }

    static func match(
        candidates: [SemanticRecommendationCandidate],
        tracks: [Track],
        disliked: Set<GlobalID> = [],
        targetCount: Int,
        maxPerArtist: Int = 2
    ) -> [Track] {
        let target = min(max(targetCount, 1), 100)
        let artistLimit = min(max(maxPerArtist, 1), 10)
        let index = tracks.compactMap { track -> IndexedTrack? in
            let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            guard !disliked.contains(gid) else { return nil }
            let title = normalize(track.title)
            guard !title.isEmpty else { return nil }
            return IndexedTrack(
                track: track,
                title: title,
                baseTitle: baseTitle(track.title),
                artist: normalizeArtist(track.artistName),
                album: normalize(track.albumTitle)
            )
        }

        var result: [Track] = []
        var seen = Set<GlobalID>()
        var artistCounts: [String: Int] = [:]

        for candidate in candidates.prefix(200) {
            guard result.count < target else { break }
            guard let resolved = bestMatch(candidate, index: index) else { continue }
            let gid = GlobalID(serverID: resolved.serverID, remoteID: resolved.id.rawValue)
            guard seen.insert(gid).inserted else { continue }
            let artistKey = normalizeArtist(resolved.artistName)
            guard artistCounts[artistKey, default: 0] < artistLimit else { continue }
            artistCounts[artistKey, default: 0] += 1
            result.append(resolved)
        }
        return result
    }

    private static func bestMatch(
        _ candidate: SemanticRecommendationCandidate,
        index: [IndexedTrack]
    ) -> Track? {
        let wantedTitle = normalize(candidate.title)
        guard !wantedTitle.isEmpty else { return nil }
        let wantedBaseTitle = baseTitle(candidate.title)
        let wantedArtist = candidate.artist.flatMap { raw -> String? in
            let value = normalizeArtist(raw)
            return value.isEmpty ? nil : value
        }
        let wantedAlbum = candidate.album.flatMap { raw -> String? in
            let value = normalize(raw)
            return value.isEmpty ? nil : value
        }

        var scored: [Scored] = []
        for item in index {
            let titleExact = wantedTitle == item.title
            let baseExact = !wantedBaseTitle.isEmpty && wantedBaseTitle == item.baseTitle
            let titleSimilarity = similarity(wantedTitle, item.title)

            // 无艺人信息时只接受唯一的标题精确匹配，不做模糊猜测。
            if wantedArtist == nil {
                guard titleExact else { continue }
                let albumBonus = wantedAlbum == item.album ? 8.0 : 0
                scored.append(Scored(track: item.track, score: 70 + albumBonus))
                continue
            }

            guard titleExact || baseExact || titleSimilarity >= 0.90 else { continue }
            guard let artist = wantedArtist else { continue }
            let artistSimilarity = similarity(artist, item.artist)
            let artistStrong = artist == item.artist
                || (!artist.isEmpty && (item.artist.contains(artist) || artist.contains(item.artist)))
                || artistSimilarity >= 0.86
            guard artistStrong else { continue }

            let titleScore: Double
            if titleExact { titleScore = 70 }
            else if baseExact { titleScore = 64 }
            else { titleScore = titleSimilarity * 60 }

            let artistScore: Double
            if artist == item.artist { artistScore = 30 }
            else if item.artist.contains(artist) || artist.contains(item.artist) { artistScore = 26 }
            else { artistScore = artistSimilarity * 24 }

            let albumBonus = wantedAlbum == item.album ? 8.0 : 0
            scored.append(Scored(track: item.track, score: titleScore + artistScore + albumBonus))
        }

        guard !scored.isEmpty else { return nil }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let artist = lhs.track.artistName.localizedStandardCompare(rhs.track.artistName)
            if artist != .orderedSame { return artist == .orderedAscending }
            let album = lhs.track.albumTitle.localizedStandardCompare(rhs.track.albumTitle)
            if album != .orderedSame { return album == .orderedAscending }
            return lhs.track.id.rawValue < rhs.track.id.rawValue
        }

        // 只有标题、没有艺人/专辑，且存在多个同名版本时拒绝猜测。
        if wantedArtist == nil, wantedAlbum == nil, scored.count > 1 {
            return nil
        }
        return scored[0].track
    }

    private static func normalizeArtist(_ raw: String) -> String {
        var value = normalize(raw)
        for marker in [" feat ", " featuring ", " ft "] {
            if let range = value.range(of: marker) {
                value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return value
    }

    private static func baseTitle(_ raw: String) -> String {
        var value = normalize(raw)
        let patterns = [
            #"\s+\d{4}\s+remaster(?:ed)?$"#,
            #"\s+remaster(?:ed)?(?:\s+\d{4})?$"#,
            #"\s+\d{4}\s+重制(?:版)?$"#,
            #"\s+重制(?:版)?(?:\s+\d{4})?$"#,
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func normalize(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let mapped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let a = Array(lhs)
        let b = Array(rhs)
        let denominator = max(a.count, b.count)
        guard denominator > 0 else { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }

        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                let cost = left == right ? 0 : 1
                current[j + 1] = min(
                    min(current[j] + 1, previous[j + 1] + 1),
                    previous[j] + cost
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(denominator)
    }
}

enum SemanticCollisionRecommendation {
    static func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        catalog: LocalCatalogStore,
        serverID: ServerID?
    ) async throws -> ToolResult {
        let candidates = try parseCandidates(call)
        guard !candidates.isEmpty else {
            throw ToolArgumentError.invalid("candidates", expected: "至少一首带 title 的歌曲候选")
        }
        let targetCount = min(max((try? call.int("targetCount")) ?? 20, 1), 100)
        let maxPerArtist = min(max((try? call.int("maxPerArtist")) ?? 2, 1), 10)

        // Ground against the user's complete playable catalog: active server + true local files.
        // `auralis-local` is a catalog namespace, never a remote server route.
        let remoteTracks = try await catalog.allTracks(serverID: serverID)
        let localTracks = try await catalog.allTracks(serverID: LocalCatalogOverlay.localServerID)
        let tracks = TrackQuality.deduplicatedPreferringQuality(remoteTracks + localTracks)

        var disliked = Set<GlobalID>()
        if let serverID {
            disliked.formUnion((try? await catalog.dislikedTrackIDs(serverID: serverID)) ?? [])
        }
        disliked.formUnion(
            (try? await catalog.dislikedTrackIDs(serverID: LocalCatalogOverlay.localServerID)) ?? []
        )

        let grounded = SemanticCollisionMatcher.match(
            candidates: candidates,
            tracks: tracks,
            disliked: disliked,
            targetCount: targetCount,
            maxPerArtist: maxPerArtist
        )
        let fallbackNeeded = grounded.count < targetCount
        let summary = fallbackNeeded
            ? "语义撞库：模型候选 \(candidates.count) 首，统一本地目录高置信度命中 \(grounded.count)/\(targetCount) 首；请用 Recommendation Index / 本地推荐继续补足，未命中的模型歌曲不得直接展示。"
            : "语义撞库：模型候选 \(candidates.count) 首，统一本地目录高置信度命中目标 \(grounded.count) 首。"
        return ToolResult(
            call: call,
            permission: descriptor.permission,
            success: true,
            summary: summary,
            payload: .trackCards(grounded.map(TrackCard.from)),
            facts: [
                "recommendation.collision.generated": String(candidates.count),
                "recommendation.collision.matched": String(grounded.count),
                "recommendation.collision.target": String(targetCount),
                "recommendation.collision.fallback_needed": fallbackNeeded ? "true" : "false",
            ],
            presentationRole: .candidate
        )
    }

    private static func parseCandidates(_ call: ToolCall) throws -> [SemanticRecommendationCandidate] {
        guard let raw = call.arguments["candidates"] else {
            throw ToolArgumentError.missing("candidates")
        }
        let value: AIJSONValue
        if case let .string(text) = raw {
            value = try AIJSONValue(jsonString: text)
        } else {
            value = raw
        }
        guard case let .array(items) = value else {
            throw ToolArgumentError.invalid("candidates", expected: "JSON array")
        }
        return items.prefix(200).compactMap { item in
            guard case let .object(object) = item,
                  case let .string(title)? = object["title"],
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let artist: String?
            if case let .string(value)? = object["artist"] { artist = value } else { artist = nil }
            let album: String?
            if case let .string(value)? = object["album"] { album = value } else { album = nil }
            return SemanticRecommendationCandidate(title: title, artist: artist, album: album)
        }
    }
}
