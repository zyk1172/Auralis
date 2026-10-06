// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AppShell
import Domain
import Foundation
import LocalCatalog
import Testing

@Suite("Library snapshot integrity", .serialized)
@MainActor
struct LibrarySnapshotIntegrityTests {
    @Test("Playlist-only changes do not rebuild track indexes")
    func playlistDoesNotInvalidateTrackIndexes() {
        let track = Track(id: "track", serverID: "server", albumID: "album", artistID: "artist",
                          title: "Old", artistName: "Artist", albumTitle: "Album", duration: 180)
        var catalog = LibraryCatalog.empty
        catalog.tracks = [track]
        let store = LibraryStore(catalog: catalog)
        let revision = store.catalogRevision
        store.catalog.playlists.append(Playlist(id: "list", serverID: "server", name: "List", trackIDs: [track.id]))
        #expect(store.catalogRevision == revision)
        #expect(store.track(for: GlobalID(serverID: "server", remoteID: "track"))?.title == "Old")
        store.catalog.tracks[0].title = "New"
        #expect(store.catalogRevision == revision + 1)
        #expect(store.track(for: GlobalID(serverID: "server", remoteID: "track"))?.title == "New")
    }

    @Test("Directory read failure preserves the previous local snapshot")
    func failedDirectoryRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("LocalMusic")
        let store = LocalMusicLibraryStore(directory: root.appendingPathComponent("metadata"), managedDirectory: managed)
        let source = try #require(store.sources.first)
        let song = managed.appendingPathComponent("Song")
        try FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        try Data([0]).write(to: song.appendingPathComponent("audio.mp3"))
        _ = await store.scan(source: source, manageState: false)
        let previous = store.tracks
        #expect(previous.count == 1)
        try FileManager.default.removeItem(at: managed)
        try Data([0]).write(to: managed)
        let failed = await store.scan(source: source, manageState: false)
        #expect(failed.failedFiles == 1)
        #expect(store.tracks == previous)
    }

    @Test("A partial scan preserves a song whose package could not be read")
    func partialScanPreservesOldSong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("LocalMusic")
        let store = LocalMusicLibraryStore(directory: root.appendingPathComponent("metadata"), managedDirectory: managed)
        let source = try #require(store.sources.first)
        let song = managed.appendingPathComponent("Song")
        try FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        try Data([0]).write(to: song.appendingPathComponent("audio.mp3"))
        _ = await store.scan(source: source, manageState: false)
        let previous = store.tracks
        #expect(previous.count == 1)
        try Data([0]).write(to: song.appendingPathComponent("duplicate.flac"))
        let partial = await store.scan(source: source, manageState: false)
        #expect(partial.failedFiles == 1)
        #expect(partial.removedTracks == 0)
        #expect(store.tracks == previous)
    }
}
