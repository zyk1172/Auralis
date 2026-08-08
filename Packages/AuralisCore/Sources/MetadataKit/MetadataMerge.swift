import Domain
import Foundation

public struct ResolvedTrackMetadata: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let year: Int?
    public let genres: [String]
    public let language: String?
    public let provenance: [MetadataSource]

    public init(title: String, artist: String, album: String, year: Int?, genres: [String], language: String?, provenance: [MetadataSource]) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genres = genres
        self.language = language
        self.provenance = provenance
    }
}

public enum MetadataMerge {
    public static func resolve(original: Track, overlay: MetadataOverlay?) -> ResolvedTrackMetadata {
        guard let overlay else {
            return ResolvedTrackMetadata(
                title: original.title,
                artist: original.artistName,
                album: original.albumTitle,
                year: original.year,
                genres: original.genres,
                language: original.language,
                provenance: [.server]
            )
        }
        return ResolvedTrackMetadata(
            title: nonEmpty(overlay.correctedTitle) ?? original.title,
            artist: nonEmpty(overlay.correctedArtist) ?? original.artistName,
            album: nonEmpty(overlay.correctedAlbum) ?? original.albumTitle,
            year: overlay.releaseYear ?? original.year,
            genres: overlay.genres.isEmpty ? original.genres : overlay.genres,
            language: nonEmpty(overlay.language) ?? original.language,
            provenance: [.server] + overlay.provenance
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct MetadataCandidate<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let value: Value
    public let confidence: Double
    public let source: MetadataSource
    public let reason: String
    public let requiresUserReview: Bool
    public init(value: Value, confidence: Double, source: MetadataSource, reason: String, requiresUserReview: Bool = true) {
        self.value = value
        self.confidence = confidence
        self.source = source
        self.reason = reason
        self.requiresUserReview = requiresUserReview
    }
}

public actor MetadataOverlayStore {
    private var overlays: [TrackID: MetadataOverlay] = [:]
    private var undoStack: [[TrackID: MetadataOverlay]] = []
    public init() {}
    public func apply(_ overlay: MetadataOverlay) {
        undoStack.append(overlays)
        overlays[overlay.trackID] = overlay
    }
    public func overlay(for trackID: TrackID) -> MetadataOverlay? { overlays[trackID] }
    public func restoreOriginal(trackID: TrackID) {
        undoStack.append(overlays)
        overlays.removeValue(forKey: trackID)
    }
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        overlays = previous
    }
}
