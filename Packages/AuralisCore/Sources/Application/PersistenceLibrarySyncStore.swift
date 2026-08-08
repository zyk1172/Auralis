import Domain
import Foundation
import MusicLibrary
import Persistence

/// Bridges the application sync use case to the persistence transaction API.
///
/// A full sync is invisible to readers until `completeSync`. Incremental syncs
/// seed the transaction with the last committed snapshot before applying pages,
/// so a partial or cancelled run cannot delete previously committed records.
public actor PersistenceLibrarySyncStore: LibrarySyncStore {
    private struct Context: Sendable {
        let librarySession: LibrarySyncSession
        let persistenceSession: PersistenceSyncSession
    }

    private let persistence: any AuralisPersisting
    private var contexts: [UUID: Context] = [:]

    public init(persistence: any AuralisPersisting) {
        self.persistence = persistence
    }

    public func beginSync(serverID: ServerID, mode: LibrarySyncMode) async throws -> LibrarySyncSession {
        try Task.checkCancellation()

        // Staged pages currently live in the persistence actor until commit. A
        // process restart therefore cannot safely reuse an older continuation;
        // clearing it prevents a resumed run from skipping pages that were never
        // durably staged.
        try await persistence.clearCheckpoints(serverID: serverID)
        let persistenceSession = try await persistence.beginFullSync(serverID: serverID)
        let librarySession = LibrarySyncSession(serverID: serverID, mode: mode)

        if mode == .incremental, let snapshot = try await persistence.snapshot(serverID: serverID) {
            try await persistence.stageArtists(snapshot.artists, session: persistenceSession)
            try await persistence.stageAlbums(snapshot.albums, session: persistenceSession)
            try await persistence.stageTracks(snapshot.tracks, session: persistenceSession)
        }

        contexts[librarySession.id] = Context(
            librarySession: librarySession,
            persistenceSession: persistenceSession
        )
        return librarySession
    }

    public func checkpoint(
        session: LibrarySyncSession,
        section: LibrarySyncSection
    ) async throws -> LibrarySyncCheckpoint? {
        _ = try context(for: session)
        guard let stored = try await persistence.checkpoint(
            serverID: session.serverID,
            kind: section.persistenceKind
        ) else {
            return nil
        }
        return LibrarySyncCheckpoint(
            sessionID: session.id,
            serverID: session.serverID,
            section: section,
            continuation: stored.continuation,
            sourceRevision: stored.sourceRevision,
            processedCount: stored.processedCount,
            completedAt: stored.completedAt,
            updatedAt: stored.updatedAt
        )
    }

    public func stageArtists(_ artists: [Artist], session: LibrarySyncSession) async throws {
        let context = try context(for: session)
        try await persistence.stageArtists(artists, session: context.persistenceSession)
    }

    public func stageAlbums(_ albums: [Album], session: LibrarySyncSession) async throws {
        let context = try context(for: session)
        try await persistence.stageAlbums(albums, session: context.persistenceSession)
    }

    public func stageTracks(_ tracks: [Track], session: LibrarySyncSession) async throws {
        let context = try context(for: session)
        try await persistence.stageTracks(tracks, session: context.persistenceSession)
    }

    public func saveCheckpoint(
        _ checkpoint: LibrarySyncCheckpoint,
        session: LibrarySyncSession
    ) async throws {
        _ = try context(for: session)
        guard checkpoint.sessionID == session.id,
              checkpoint.serverID == session.serverID
        else {
            throw LibrarySyncError.sessionMismatch
        }
        try await persistence.saveCheckpoint(
            PersistenceSyncCheckpoint(
                serverID: session.serverID,
                kind: checkpoint.section.persistenceKind,
                continuation: checkpoint.continuation,
                sourceRevision: checkpoint.sourceRevision,
                processedCount: checkpoint.processedCount,
                completedAt: checkpoint.completedAt,
                updatedAt: checkpoint.updatedAt
            )
        )
    }

    public func completeSync(_ session: LibrarySyncSession, completedAt _: Date) async throws {
        let context = try context(for: session)
        try await persistence.commitFullSync(context.persistenceSession)
        try await persistence.clearCheckpoints(serverID: session.serverID)
        contexts.removeValue(forKey: session.id)
    }

    public func suspendSync(_ session: LibrarySyncSession) async {
        guard let context = contexts.removeValue(forKey: session.id) else { return }
        await persistence.discardFullSync(context.persistenceSession)
        try? await persistence.clearCheckpoints(serverID: session.serverID)
    }

    public func discardSync(_ session: LibrarySyncSession) async {
        await suspendSync(session)
    }

    private func context(for session: LibrarySyncSession) throws -> Context {
        guard let context = contexts[session.id] else {
            throw LibrarySyncError.unknownSession(session.id)
        }
        guard context.librarySession == session else {
            throw LibrarySyncError.sessionMismatch
        }
        return context
    }
}

private extension LibrarySyncSection {
    var persistenceKind: LibraryRecordKind {
        switch self {
        case .artists: .artists
        case .albums: .albums
        case .tracks: .tracks
        }
    }
}
