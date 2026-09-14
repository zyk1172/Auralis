// SPDX-License-Identifier: GPL-3.0-only
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
        #expect(snapshot.discoveredFiles == 0)
        #expect(snapshot.failedFiles == 0)
    }
}
