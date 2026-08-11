import Domain
import Foundation
import LyricsKit
import Testing

@Suite("Lyrics GlobalID migration")
struct LyricsDiskCacheMigrationTests {
    @Test("Legacy lyric document and miss key migrate without deletion")
    func migration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = LyricsDocument(
            trackID: "song-one",
            language: "zh",
            lines: [TimedLyricLine(startTime: 0, text: "第一句")],
            isSynced: true
        )
        try JSONEncoder().encode(document).write(
            to: directory.appendingPathComponent("song_one.json"),
            options: .atomic
        )
        try JSONEncoder().encode(Set(["song-missing"])).write(
            to: directory.appendingPathComponent("misses.json"),
            options: .atomic
        )

        let cache = LyricsDiskCache(directory: directory)
        await cache.migrateLegacyEntries(to: "old-server")

        #expect(await cache.document(forServer: "old-server", trackID: "song-one") == document)
        #expect(await cache.isKnownMissing(serverID: "old-server", trackID: "song-missing"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("song_one.json").path))
    }
}
