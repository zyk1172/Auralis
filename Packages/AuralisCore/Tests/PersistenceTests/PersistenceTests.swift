import Domain
import Foundation
import Persistence
import Testing

@Test("Upserts are isolated by server and report inserts, updates, and no-op records")
func upsertIsolationAndSummary() async throws {
    let store = InMemoryPersistence()
    let first = fixture(serverID: "server-a", suffix: "a")
    let second = fixture(serverID: "server-b", suffix: "b")

    try await store.saveSnapshot(first)
    try await store.saveSnapshot(second)

    let firstPage = await store.tracks(serverID: first.serverID, offset: 0, limit: 10)
    let secondPage = await store.tracks(serverID: second.serverID, offset: 0, limit: 10)
    #expect(firstPage.map(\.serverID) == [first.serverID])
    #expect(secondPage.map(\.serverID) == [second.serverID])

    let unchanged = try await store.upsertTracks(first.tracks, serverID: first.serverID)
    #expect(unchanged == .init(inserted: 0, updated: 0, unchanged: 1))

    var changedTrack = first.tracks[0]
    changedTrack.title = "Updated title"
    let updated = try await store.upsertTracks([changedTrack], serverID: first.serverID)
    #expect(updated == .init(inserted: 0, updated: 1, unchanged: 0))
    #expect(await store.track(id: changedTrack.id, serverID: first.serverID)?.title == "Updated title")
}

@Test("File-backed snapshots round-trip accounts, checkpoints, paging, and search")
func fileBackedRoundTrip() async throws {
    let location = temporaryArchiveURL()
    let snapshot = fixture(serverID: "server-roundtrip", suffix: "roundtrip")
    let checkpoint = PersistenceSyncCheckpoint(
        serverID: snapshot.serverID,
        kind: .tracks,
        continuation: "500",
        sourceRevision: "revision-7",
        processedCount: 500,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var snapshotWithCheckpoint = snapshot
    snapshotWithCheckpoint.checkpoints = [checkpoint]

    do {
        let store = try FileBackedPersistence(fileURL: location)
        try await store.saveSnapshot(snapshotWithCheckpoint)
        #expect(await store.accounts().map(\.id) == [snapshot.serverID])
        #expect(await store.searchTracks(
            serverID: snapshot.serverID,
            query: "cafe artist",
            offset: 0,
            limit: 5
        ).map(\.id) == snapshot.tracks.map(\.id))
    }

    let reopened = try FileBackedPersistence(fileURL: location)
    #expect(await reopened.schemaVersion() == AuralisSchema.currentVersion)
    #expect(await reopened.account(id: snapshot.serverID) == snapshot.account)
    #expect(await reopened.snapshot(serverID: snapshot.serverID) == snapshotWithCheckpoint)
    #expect(await reopened.checkpoint(serverID: snapshot.serverID, kind: .tracks) == checkpoint)
}

@Test("File-backed archives keep private attributes across atomic replacements")
func fileBackedArchiveSecurityAttributes() async throws {
    let location = temporaryArchiveURL()
    let fileManager = FileManager.default
    let store = try FileBackedPersistence(fileURL: location)

    var attributes = try fileManager.attributesOfItem(atPath: location.path)
    var permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)

    // A secure replacement must not inherit an accidentally loosened mode from
    // the previous archive.
    try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: location.path)
    try await store.saveSnapshot(fixture(serverID: "server-secure-file", suffix: "secure-file"))

    attributes = try fileManager.attributesOfItem(atPath: location.path)
    permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
    #expect(
        try fileManager.contentsOfDirectory(atPath: location.deletingLastPathComponent().path)
            == [location.lastPathComponent]
    )

#if os(iOS)
    #expect(
        attributes[.protectionKey] as? FileProtectionType
            == FileProtectionType.completeUntilFirstUserAuthentication
    )
#endif
}

@Test("A full sync is invisible until commit and removes stale records atomically")
func fullSyncAtomicCommit() async throws {
    let store = InMemoryPersistence()
    let old = fixture(serverID: "server-full", suffix: "old")
    let new = fixture(serverID: old.serverID, suffix: "new")
    try await store.saveSnapshot(old)

    let session = try await store.beginFullSync(serverID: old.serverID)
    try await store.stageArtists(new.artists, session: session)
    try await store.stageAlbums(new.albums, session: session)
    try await store.stageTracks(new.tracks, session: session)

    #expect(await store.tracks(serverID: old.serverID, offset: 0, limit: 10).map(\.id) == old.tracks.map(\.id))
    try await store.commitFullSync(session)
    #expect(await store.tracks(serverID: old.serverID, offset: 0, limit: 10).map(\.id) == new.tracks.map(\.id))
    #expect(await store.account(id: old.serverID) == old.account)
}

@Test("Discarding a full sync preserves the committed snapshot")
func discardFullSync() async throws {
    let store = try FileBackedPersistence(fileURL: temporaryArchiveURL())
    let old = fixture(serverID: "server-discard", suffix: "old")
    let replacement = fixture(serverID: old.serverID, suffix: "replacement")
    try await store.saveSnapshot(old)

    let session = try await store.beginFullSync(serverID: old.serverID)
    try await store.stageArtists(replacement.artists, session: session)
    try await store.stageAlbums(replacement.albums, session: session)
    try await store.stageTracks(replacement.tracks, session: session)
    await store.discardFullSync(session)

    #expect(await store.snapshot(serverID: old.serverID) == old)
}

@Test("A cancelled mutation does not change durable state")
func cancellationIsAtomic() async throws {
    let store = try FileBackedPersistence(fileURL: temporaryArchiveURL())
    let original = fixture(serverID: "server-cancel", suffix: "old")
    let replacement = fixture(serverID: original.serverID, suffix: "new")
    try await store.saveSnapshot(original)

    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await store.upsertTracks(replacement.tracks, serverID: original.serverID)
    }
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(await store.tracks(serverID: original.serverID, offset: 0, limit: 10) == original.tracks)
}

@Test("Cross-server records are rejected without partial writes")
func crossServerBatchRejected() async throws {
    let store = InMemoryPersistence()
    let first = fixture(serverID: "server-expected", suffix: "first")
    let wrong = fixture(serverID: "server-wrong", suffix: "wrong")
    try await store.saveSnapshot(first)

    await #expect(throws: PersistenceError.self) {
        _ = try await store.upsertTracks(wrong.tracks, serverID: first.serverID)
    }
    #expect(await store.tracks(serverID: first.serverID, offset: 0, limit: 10) == first.tracks)
}

@Test("Integrity reports missing relationships and accepts a complete snapshot")
func integrityRelationships() async throws {
    let store = InMemoryPersistence()
    let snapshot = fixture(serverID: "server-integrity", suffix: "integrity")
    _ = try await store.upsertTracks(snapshot.tracks, serverID: snapshot.serverID)

    let invalid = await store.integrityReport()
    #expect(!invalid.isValid)
    #expect(invalid.issues.contains { $0.code == .missingArtist })
    #expect(invalid.issues.contains { $0.code == .missingAlbum })

    try await store.saveSnapshot(snapshot)
    let valid = await store.integrityReport()
    #expect(valid.isValid)
    #expect(valid.checkedArtistCount == 1)
    #expect(valid.checkedAlbumCount == 1)
    #expect(valid.checkedTrackCount == 1)
}

@Test("Version 1 archives migrate in place and newer archives are rejected")
func schemaMigrationAndForwardCompatibility() async throws {
    let oldURL = temporaryArchiveURL()
    try Data(#"{"schemaVersion":1,"servers":{}}"#.utf8).write(to: oldURL, options: .atomic)
    let migrated = try FileBackedPersistence(fileURL: oldURL)
    #expect(await migrated.schemaVersion() == AuralisSchema.currentVersion)
    let migratedJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: oldURL)) as? [String: Any])
    #expect(migratedJSON["schemaVersion"] as? Int == AuralisSchema.currentVersion)

    let futureURL = temporaryArchiveURL()
    try Data(#"{"schemaVersion":999,"servers":{}}"#.utf8).write(to: futureURL, options: .atomic)
    #expect(throws: PersistenceError.unsupportedSchemaVersion(found: 999, supported: AuralisSchema.currentVersion)) {
        _ = try FileBackedPersistence(fileURL: futureURL)
    }
}

private func fixture(serverID: ServerID, suffix: String) -> ServerLibrarySnapshot {
    let artistID = ArtistID(rawValue: "artist-\(suffix)")
    let albumID = AlbumID(rawValue: "album-\(suffix)")
    let trackID = TrackID(rawValue: "track-\(suffix)")
    let artist = Artist(
        id: artistID,
        serverID: serverID,
        name: "Café Artist \(suffix)",
        albumCount: 1
    )
    let album = Album(
        id: albumID,
        serverID: serverID,
        artistID: artistID,
        title: "Album \(suffix)",
        artistName: artist.name
    )
    let track = Track(
        id: trackID,
        serverID: serverID,
        albumID: albumID,
        artistID: artistID,
        title: "Track \(suffix)",
        artistName: artist.name,
        albumTitle: album.title,
        duration: 180,
        trackNumber: 1,
        genres: ["Alternative"]
    )
    return ServerLibrarySnapshot(
        serverID: serverID,
        account: ServerAccount(
            id: serverID,
            displayName: "Server \(suffix)",
            credentialReference: "secret://test-credential-\(suffix)"
        ),
        artists: [artist],
        albums: [album],
        tracks: [track]
    )
}

private func temporaryArchiveURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuralisPersistenceTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("library.json", isDirectory: false)
}
