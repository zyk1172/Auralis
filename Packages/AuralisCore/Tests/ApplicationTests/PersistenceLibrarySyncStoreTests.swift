import Application
import Domain
import MusicLibrary
import Persistence
import Testing

@Test("Cancelled synchronization keeps the last committed library")
func cancelledSyncKeepsCommittedLibrary() async throws {
    let serverID: ServerID = "sync-store-server"
    let persistence = InMemoryPersistence()
    let original = makeTrack(id: "original", serverID: serverID)
    _ = try await persistence.upsertTracks([original], serverID: serverID)
    let store = PersistenceLibrarySyncStore(persistence: persistence)

    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks([makeTrack(id: "replacement", serverID: serverID)], session: session)
    await store.suspendSync(session)

    let visible = await persistence.tracks(serverID: serverID, offset: 0, limit: 10)
    #expect(visible.map(\.id) == [original.id])
}

@Test("Incremental synchronization merges with the committed snapshot")
func incrementalSyncMergesSnapshot() async throws {
    let serverID: ServerID = "incremental-store-server"
    let persistence = InMemoryPersistence()
    let original = makeTrack(id: "original", serverID: serverID)
    _ = try await persistence.upsertTracks([original], serverID: serverID)
    let store = PersistenceLibrarySyncStore(persistence: persistence)

    let session = try await store.beginSync(serverID: serverID, mode: .incremental)
    let added = makeTrack(id: "added", serverID: serverID)
    try await store.stageTracks([added], session: session)
    try await store.completeSync(session, completedAt: .now)

    let visible = await persistence.tracks(serverID: serverID, offset: 0, limit: 10)
    #expect(Set(visible.map(\.id)) == Set([original.id, added.id]))
}

private func makeTrack(id: String, serverID: ServerID) -> Track {
    Track(
        id: TrackID(rawValue: id),
        serverID: serverID,
        albumID: AlbumID(rawValue: "album"),
        artistID: ArtistID(rawValue: "artist"),
        title: id,
        artistName: "Artist",
        albumTitle: "Album",
        duration: 180
    )
}
