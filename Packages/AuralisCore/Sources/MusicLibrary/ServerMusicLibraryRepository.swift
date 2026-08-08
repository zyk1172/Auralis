import Domain
import Foundation

/// Read-only server-scoped storage boundary used by UI-facing repositories.
/// A composition module can adapt `AuralisPersisting` without making MusicLibrary depend on a
/// concrete database implementation.
public protocol ServerMusicLibraryStore: Sendable {
    func artists(serverID: ServerID, offset: Int, limit: Int) async throws -> [Artist]
    func albums(serverID: ServerID, offset: Int, limit: Int) async throws -> [Album]
    func tracks(serverID: ServerID, offset: Int, limit: Int) async throws -> [Track]
    func track(id: TrackID, serverID: ServerID) async throws -> Track?
    func searchTracks(serverID: ServerID, query: String, offset: Int, limit: Int) async throws -> [Track]
}

public struct ServerMusicLibraryRepository: MusicLibraryRepository, Sendable {
    public let serverID: ServerID
    private let store: any ServerMusicLibraryStore

    public init(serverID: ServerID, store: any ServerMusicLibraryStore) {
        self.serverID = serverID
        self.store = store
    }

    public func artists(offset: Int, limit: Int) async throws -> [Artist] {
        try await store.artists(serverID: serverID, offset: offset, limit: limit)
    }

    public func albums(offset: Int, limit: Int) async throws -> [Album] {
        try await store.albums(serverID: serverID, offset: offset, limit: limit)
    }

    public func tracks(offset: Int, limit: Int) async throws -> [Track] {
        try await store.tracks(serverID: serverID, offset: offset, limit: limit)
    }

    public func track(id: TrackID) async throws -> Track? {
        try await store.track(id: id, serverID: serverID)
    }

    public func search(query: String, limit: Int) async throws -> [Track] {
        try await store.searchTracks(serverID: serverID, query: query, offset: 0, limit: limit)
    }
}
