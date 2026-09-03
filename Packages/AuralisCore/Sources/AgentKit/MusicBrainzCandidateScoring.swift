import Domain
import Foundation
import LocalCatalog

/// The individual terms used by the MusicBrainz recording matcher. Keeping
/// these values separate makes version and duration guard behavior observable
/// in regression tests instead of hiding it behind one opaque score.
struct MusicBrainzCandidateScore: Sendable, Equatable {
    let searchScore: Double
    let titleScore: Double
    let artistScore: Double
    let durationScore: Double
    let albumScore: Double
    let strongMatchBonus: Double
    let versionPenalty: Double
    let titleExact: Bool
    let artistExact: Bool
    let durationDifference: TimeInterval?
    let hardVersionMismatch: Bool
    let hardDurationMismatch: Bool
    let confidence: Double
}

/// Pure, side-effect-free MusicBrainz candidate scoring. The scorer knows
/// about recordings and local track metadata only; persistence and network
/// policy remain in MusicBrainzExternalMusicService.
struct MusicBrainzCandidateScorer {
    static let softVersionMarkers: Set<String> = [
        "remaster", "remastered", "deluxe", "anniversary", "edition",
        "explicit", "mono", "stereo", "bonus", "version",
        "重制", "重制版", "豪华", "豪华版", "纪念", "纪念版",
    ]

    static let hardVersionMarkers: Set<String> = [
        "live", "concert", "acoustic", "unplugged", "instrumental",
        "karaoke", "cover", "demo", "remix", "现场", "现场版",
        "演唱会", "不插电", "纯音乐", "伴奏", "翻唱", "小样",
    ]

    private static let titleCollaborationMarkers: Set<String> = ["feat", "featuring", "ft"]
    static func score(
        recording: MBRecording,
        track: Track
    ) -> MusicBrainzCandidateScore {
        let candidateArtist = artistCreditString(recording.artistCredit)
        let candidateDuration = recording.length.flatMap { length in
            length >= 0 ? Double(length) / 1_000 : nil
        }
        let durationDifference = candidateDuration.map { abs($0 - track.duration) }
        let titleSimilarity = similarity(
            normalizedCoreTitle(recording.title),
            normalizedCoreTitle(track.title)
        )
        let titleExact = normalizedCoreTitle(recording.title) == normalizedCoreTitle(track.title)
        let artistSimilarity = artistSimilarity(candidateArtist, track.artistName)
        let artistExact = artistSimilarity >= 0.999
        let release = bestRelease(recording.releases, album: track.albumTitle)
        let albumScore = 0.04 * albumSimilarity(release?.title ?? "", track.albumTitle)
        let durationScore = durationScore(
            localDuration: track.duration,
            candidateDuration: candidateDuration,
            difference: durationDifference
        )
        let version = versionMismatch(
            local: track.title + " " + track.albumTitle,
            remote: recording.title + " " + (release?.title ?? "")
        )
        let hardDurationMismatch = durationDifference.map {
            track.duration.isFinite && track.duration > 0
                && $0 > max(18, track.duration * 0.08)
        } ?? false

        let searchScore = min(max(Double(recording.score ?? 0) / 100, 0), 1) * 0.32
        let titleScore = titleExact ? 0.30 : 0.16 * titleSimilarity
        let artistScore = artistExact ? 0.22 : 0.18 * artistSimilarity
        let strongMatchBonus = titleExact && artistSimilarity >= 0.85 ? 0.08 : 0
        var confidence = searchScore
            + titleScore
            + artistScore
            + durationScore
            + albumScore
            + strongMatchBonus
            - version.penalty
        if hardDurationMismatch {
            // A title/artist collision with a materially different duration
            // must never become an automatic Stable Identity.
            confidence = min(confidence, 0.74)
        }
        confidence = min(max(confidence, 0), 1)

        return MusicBrainzCandidateScore(
            searchScore: searchScore,
            titleScore: titleScore,
            artistScore: artistScore,
            durationScore: durationScore,
            albumScore: albumScore,
            strongMatchBonus: strongMatchBonus,
            versionPenalty: version.penalty,
            titleExact: titleExact,
            artistExact: artistExact,
            durationDifference: durationDifference,
            hardVersionMismatch: version.hardMismatch,
            hardDurationMismatch: hardDurationMismatch,
            confidence: confidence
        )
    }

    static func candidate(
        recording: MBRecording,
        track: Track,
        globalID: GlobalID,
        createdAt: Date
    ) -> ExternalMusicIdentityCandidate {
        let score = score(recording: recording, track: track)
        let release = bestRelease(recording.releases, album: track.albumTitle)
        let duration = recording.length.flatMap { length in
            length >= 0 ? Double(length) / 1_000 : nil
        }
        return ExternalMusicIdentityCandidate(
            globalTrackID: globalID,
            recordingMBID: recording.id,
            releaseMBID: release?.id,
            releaseGroupMBID: release?.releaseGroup?.id,
            artistMBID: recording.artistCredit?.first?.artist?.id,
            isrc: recording.isrcs?.compactMap(ExternalMusicIdentity.normalizedISRC).first,
            title: recording.title,
            artistName: artistCreditString(recording.artistCredit),
            duration: duration,
            confidence: score.confidence,
            matchMethod: score.titleExact && score.artistExact && score.durationDifference.map { $0 <= 5 } == true
                ? .metadataExact
                : .metadataFuzzy,
            createdAt: createdAt
        )
    }

    static func normalizedCoreTitle(_ string: String) -> String {
        var tokens = normalized(string).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return "" }

        var end = tokens.count
        var removedSoftMarker = false
        while end > 0 {
            let token = tokens[end - 1]
            if softVersionMarkers.contains(token) {
                removedSoftMarker = true
                end -= 1
                continue
            }
            if let stripped = softSuffix(from: token) {
                tokens[end - 1] = stripped
                removedSoftMarker = true
                if stripped.isEmpty { end -= 1 }
                continue
            }
            if isYear(token), removedSoftMarker {
                end -= 1
                continue
            }
            // Also accept the common `Remastered 2021` order. A bare year is
            // retained because it may be part of the recording title.
            if isYear(token), end > 1 {
                let previous = tokens[end - 2]
                if softVersionMarkers.contains(previous) || softSuffix(from: previous) != nil {
                    end -= 1
                    continue
                }
            }
            break
        }

        if let collaborationIndex = tokens[..<end].firstIndex(where: {
            titleCollaborationMarkers.contains($0)
        }), collaborationIndex > 0 {
            end = min(end, collaborationIndex)
        }
        return tokens[..<end].joined(separator: " ")
    }

    static func artistSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let leftParts = Set(normalizedArtistParts(lhs))
        let rightParts = Set(normalizedArtistParts(rhs))
        guard !leftParts.isEmpty, !rightParts.isEmpty else { return 0 }
        if leftParts == rightParts { return 1 }
        if leftParts.isSubset(of: rightParts) || rightParts.isSubset(of: leftParts) {
            // A guest artist omitted by one source is strong evidence, but it
            // is intentionally below an exact participating-artist match.
            return 0.95
        }

        let partSimilarity = jaccard(leftParts, rightParts)
        let leftTokens = Set(leftParts.joined(separator: " ").split(separator: " "))
        let rightTokens = Set(rightParts.joined(separator: " ").split(separator: " "))
        return max(partSimilarity, jaccard(leftTokens, rightTokens))
    }

    static func primaryArtistName(_ string: String) -> String {
        normalizedArtistParts(string).first ?? ""
    }

    static func albumSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedCoreTitle(lhs)
        let right = normalizedCoreTitle(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return left == right ? 1 : similarity(left, right)
    }

    private static func durationScore(
        localDuration: TimeInterval,
        candidateDuration: TimeInterval?,
        difference: TimeInterval?
    ) -> Double {
        guard let candidateDuration,
              candidateDuration.isFinite,
              candidateDuration >= 0,
              localDuration.isFinite,
              localDuration > 0,
              let difference
        else {
            // Missing MusicBrainz length is neutral-to-positive evidence, not
            // a mismatch. It cannot trigger the hard duration guard.
            return 0.05
        }
        switch difference {
        case ...2: return 0.11
        case ...5: return 0.09
        case ...10: return 0.06
        case ...max(15, localDuration * 0.06): return 0.03
        default: return 0
        }
    }

    private static func versionMismatch(
        local: String,
        remote: String
    ) -> (penalty: Double, hardMismatch: Bool) {
        let localMarkers = markerSet(local)
        let remoteMarkers = markerSet(remote)
        let hardMismatch = hardVersionMarkers.contains {
            localMarkers.contains($0) != remoteMarkers.contains($0)
        }
        if hardMismatch { return (0.26, true) }
        let softMismatch = softVersionMarkers.contains {
            localMarkers.contains($0) != remoteMarkers.contains($0)
        }
        return (softMismatch ? 0.04 : 0, false)
    }

    private static func markerSet(_ string: String) -> Set<String> {
        let text = normalized(string)
        var markers = Set(text.split(separator: " ").map(String.init))
        for marker in softVersionMarkers.union(hardVersionMarkers)
            where marker.unicodeScalars.contains(where: { $0.value > 127 }) && text.contains(marker) {
            markers.insert(marker)
        }
        return markers
    }

    private static func normalizedArtistParts(_ string: String) -> [String] {
        var value = string
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        for separator in ["&", "、", ",", ";", "/", "+"] {
            value = value.replacingOccurrences(of: separator, with: "|")
        }
        for separator in [
            "featuring", "feat.", " ft.", "ft.", " feat ", " ft ",
            " with ", " vs ", " x ", " and ",
        ] {
            value = value.replacingOccurrences(of: separator, with: "|")
        }
        return value
            .split(separator: "|")
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func softSuffix(from token: String) -> String? {
        for marker in softVersionMarkers where marker.unicodeScalars.contains(where: { $0.value > 127 }) {
            guard token != marker, token.hasSuffix(marker) else { continue }
            return String(token.dropLast(marker.count))
        }
        return nil
    }

    private static func isYear(_ token: String) -> Bool {
        token.count == 4 && token.allSatisfy { $0.isNumber }
    }

    private static func bestRelease(_ releases: [MBRelease]?, album: String) -> MBRelease? {
        releases?.max { lhs, rhs in
            albumSimilarity(lhs.title, album) < albumSimilarity(rhs.title, album)
        }
    }

    private static func normalized(_ string: String) -> String {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.split(separator: " "))
        let right = Set(rhs.split(separator: " "))
        return jaccard(left, right)
    }

    private static func jaccard<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func artistCreditString(_ credits: [MBArtistCredit]?) -> String {
        guard let credits, !credits.isEmpty else { return "" }
        return credits.map(\.name).joined(separator: " & ")
    }
}
