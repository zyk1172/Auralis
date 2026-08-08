import Domain
import Foundation

public protocol LyricsRepository: Sendable {
    func lyrics(for trackID: TrackID) async throws -> LyricsDocument?
    func save(_ document: LyricsDocument) async throws
}

public enum LyricTimeline {
    public static func currentLine(in document: LyricsDocument, at time: TimeInterval) -> TimedLyricLine? {
        document.lines.last { ($0.startTime ?? .greatestFiniteMagnitude) <= time }
    }
}
