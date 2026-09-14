// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation
import OfflineManager
import Testing

@Test func downloadedTrackGetsStableCanonicalLocalIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("local-music-promotion-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let remote = TrackCacheStore.TrackCacheID(
        serverID: ServerID(rawValue: "srv"),
        trackID: TrackID(rawValue: "42")
    )
    let store = TrackCacheStore(directory: root)
    _ = try await store.store(data: Data([1, 2, 3]), for: remote, codec: "mp3")

    let first = await store.canonicalLocalTrackID(for: remote)
    #expect(first != nil)
    let transition = await store.identityTransition(for: remote)
    #expect(transition?.remoteTrackID == remote.trackID)
    #expect(transition?.localTrackID == first)
    #expect(transition?.localLibraryID == TrackCacheStore.downloadsLibraryID)

    let restored = TrackCacheStore(directory: root)
    let second = await restored.canonicalLocalTrackID(for: remote)
    #expect(second == first)
}

@Test func deletingDownloadRemovesCanonicalAlias() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("local-music-delete-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let remote = TrackCacheStore.TrackCacheID(
        serverID: ServerID(rawValue: "srv"),
        trackID: TrackID(rawValue: "99")
    )
    let store = TrackCacheStore(directory: root)
    _ = try await store.store(data: Data([9]), for: remote, codec: "flac")
    try await store.remove(for: remote)
    let canonical = await store.canonicalLocalTrackID(for: remote)
    #expect(canonical == nil)
}

@Test func cachedDownloadCanRelocateIntoManagedSongPackage() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("local-music-package-relocation-\(UUID().uuidString)", isDirectory: true)
    let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
    let package = root.appendingPathComponent("LocalMusic/Test Song", isDirectory: true)
    let destination = package.appendingPathComponent("audio.flac")
    defer { try? fileManager.removeItem(at: root) }

    let remote = TrackCacheStore.TrackCacheID(
        serverID: ServerID(rawValue: "srv"),
        trackID: TrackID(rawValue: "download-1")
    )
    let store = TrackCacheStore(directory: cacheRoot)
    let oldURL = try await store.store(data: Data([1, 2, 3, 4]), for: remote, codec: "flac")
    try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
    try "{\"managedByAuralisDownload\":true}".write(
        to: package.appendingPathComponent("metadata.json"),
        atomically: true,
        encoding: .utf8
    )

    _ = try await store.relocateCachedFile(for: remote, toManagedPackageAudioURL: destination)

    #expect(!fileManager.fileExists(atPath: oldURL.path))
    #expect(fileManager.fileExists(atPath: destination.path))
    #expect(await store.isStoredInManagedPackage(remote))
    #expect(await store.cachedFileURL(for: remote)?.standardizedFileURL == destination.standardizedFileURL)

    let restored = TrackCacheStore(directory: cacheRoot)
    #expect(await restored.cachedFileURL(for: remote)?.standardizedFileURL == destination.standardizedFileURL)
    #expect(await restored.canonicalLocalTrackID(for: remote) != nil)

    try await restored.remove(for: remote)
    #expect(!fileManager.fileExists(atPath: package.path))
    #expect(await restored.canonicalLocalTrackID(for: remote) == nil)
}
