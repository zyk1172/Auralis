// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation
import Testing
@testable import AppShell

@Suite(.serialized)
struct LocalMusicLibraryStoreTests {
    @Test @MainActor
    func managedSourceIsCreatedAutomaticallyAndCannotBeRemoved() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("auralis-local-music-test-\(UUID().uuidString)", isDirectory: true)
        let metadata = root.appendingPathComponent("metadata", isDirectory: true)
        let managed = root.appendingPathComponent("visible/LocalMusic", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let store = LocalMusicLibraryStore(directory: metadata, managedDirectory: managed)

        #expect(fileManager.fileExists(atPath: managed.path))
        #expect(fileManager.fileExists(atPath: managed.appendingPathComponent("README.txt").path))
        #expect(store.sources.first?.id == LocalMusicLibraryStore.managedSourceID)
        #expect(store.sources.first?.displayName == "Auralis 本地音乐")

        if let source = store.sources.first {
            store.removeSource(source)
        }
        #expect(store.sources.first?.id == LocalMusicLibraryStore.managedSourceID)

        try fileManager.removeItem(at: managed)
        #expect(!fileManager.fileExists(atPath: managed.path))

        let snapshot = await store.scanAll()
        #expect(fileManager.fileExists(atPath: managed.path))
        #expect(fileManager.fileExists(atPath: managed.appendingPathComponent("README.txt").path))
        #expect(snapshot.discoveredFiles == 0)
        #expect(snapshot.failedFiles == 0)
    }

    @Test @MainActor
    func managedSourceTreatsEachChildFolderAsOneSongPackage() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("auralis-song-package-test-\(UUID().uuidString)", isDirectory: true)
        let metadataRoot = root.appendingPathComponent("metadata", isDirectory: true)
        let managed = root.appendingPathComponent("visible/LocalMusic", isDirectory: true)
        let song = managed.appendingPathComponent("夜行", isDirectory: true)
        let invalid = managed.appendingPathComponent("重复音频", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: song, withIntermediateDirectories: true)
        try Data([0x00]).write(to: song.appendingPathComponent("audio.mp3"))
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: song.appendingPathComponent("cover.jpg"))
        try """
        [00:01.50]第一句
        [00:03.250]第二句
        """.write(to: song.appendingPathComponent("lyrics.lrc"), atomically: true, encoding: .utf8)
        try """
        {
          "title": "夜行",
          "artist": "测试艺人",
          "album": "测试专辑",
          "year": 2026,
          "trackNumber": 2,
          "discNumber": 1,
          "genres": ["Electronic", "Pop"],
          "language": "zh-Hans"
        }
        """.write(to: song.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        try fileManager.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data([0x00]).write(to: invalid.appendingPathComponent("a.mp3"))
        try Data([0x00]).write(to: invalid.appendingPathComponent("b.flac"))

        let store = LocalMusicLibraryStore(directory: metadataRoot, managedDirectory: managed)
        let snapshot = await store.scanAll()

        #expect(snapshot.discoveredFiles == 2)
        #expect(snapshot.importedTracks == 1)
        #expect(snapshot.failedFiles == 1)
        #expect(store.tracks.count == 1)

        let track = try #require(store.tracks.first)
        #expect(track.title == "夜行")
        #expect(track.artistName == "测试艺人")
        #expect(track.albumTitle == "测试专辑")
        #expect(track.year == 2026)
        #expect(track.trackNumber == 2)
        #expect(track.discNumber == 1)
        #expect(track.genres == ["Electronic", "Pop"])
        #expect(track.language == "zh-Hans")

        let artworkKey = try #require(track.artworkKey)
        let artworkURL = try #require(LocalArtworkKey.fileURL(from: artworkKey))
        #expect(artworkURL.lastPathComponent == "cover.jpg")

        let document = try #require(store.lyrics[track.id])
        #expect(document.isSynced)
        #expect(document.language == "zh-Hans")
        #expect(document.lines.count == 2)
        #expect(document.lines[0].text == "第一句")
        #expect(abs((document.lines[0].startTime ?? 0) - 1.5) < 0.001)
        #expect(abs((document.lines[1].startTime ?? 0) - 3.25) < 0.001)
    }
}
