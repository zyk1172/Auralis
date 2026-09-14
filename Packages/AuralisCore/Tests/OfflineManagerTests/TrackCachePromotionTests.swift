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
