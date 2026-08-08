import Domain
import Foundation

/// Deterministic transactional store used by previews and sync integration tests.
/// Production composition should adapt the Persistence module to the same protocols.
public actor InMemoryServerMusicLibraryStore: ServerMusicLibraryStore, LibrarySyncStore {
    private struct Records: Sendable {
        var artists: [ArtistID: Artist] = [:]
        var albums: [AlbumID: Album] = [:]
        var tracks: [TrackID: Track] = [:]
    }

    private struct Staging: Sendable {
        let session: LibrarySyncSession
        var records: Records
        var checkpoints: [LibrarySyncSection: LibrarySyncCheckpoint]
        var isSuspended: Bool
    }

    private var committed: [ServerID: Records] = [:]
    private var completedCheckpoints: [ServerID: [LibrarySyncSection: LibrarySyncCheckpoint]] = [:]
    private var staging: [UUID: Staging] = [:]

    public init() {}

    public init(serverID: ServerID, artists: [Artist], albums: [Album], tracks: [Track]) {
        var records = Records()
        for artist in artists where artist.serverID == serverID { records.artists[artist.id] = artist }
        for album in albums where album.serverID == serverID { records.albums[album.id] = album }
        for track in tracks where track.serverID == serverID { records.tracks[track.id] = track }
        committed[serverID] = records
    }

    public func artists(serverID: ServerID, offset: Int, limit: Int) -> [Artist] {
        page(
            committed[serverID]?.artists.values.sorted {
                let lhs = normalized($0.name)
                let rhs = normalized($1.name)
                return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
            } ?? [],
            offset: offset,
            limit: limit
        )
    }

    public func albums(serverID: ServerID, offset: Int, limit: Int) -> [Album] {
        page(
            committed[serverID]?.albums.values.sorted {
                let lhs = normalized("\($0.artistName) \($0.title)")
                let rhs = normalized("\($1.artistName) \($1.title)")
                return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
            } ?? [],
            offset: offset,
            limit: limit
        )
    }

    public func tracks(serverID: ServerID, offset: Int, limit: Int) -> [Track] {
        page(sortedTracks(committed[serverID]?.tracks.values.map { $0 } ?? []), offset: offset, limit: limit)
    }

    public func track(id: TrackID, serverID: ServerID) -> Track? {
        committed[serverID]?.tracks[id]
    }

    public func searchTracks(serverID: ServerID, query: String, offset: Int, limit: Int) -> [Track] {
        let needle = normalized(query)
        let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let matches = sortedTracks(committed[serverID]?.tracks.values.map { $0 } ?? []).filter { track in
            let value = normalized([track.title, track.artistName, track.albumTitle, track.genres.joined(separator: " ")].joined(separator: " "))
            return tokens.allSatisfy(value.contains)
        }
        return page(matches, offset: offset, limit: limit)
    }

    public func beginSync(serverID: ServerID, mode: LibrarySyncMode) throws -> LibrarySyncSession {
        try Task.checkCancellation()
        if let existing = staging.values.first(where: {
            $0.session.serverID == serverID && $0.session.mode == mode
        }) {
            var resumed = existing
            resumed.isSuspended = false
            staging[existing.session.id] = resumed
            return existing.session
        }

        let session = LibrarySyncSession(serverID: serverID, mode: mode)
        var initialCheckpoints: [LibrarySyncSection: LibrarySyncCheckpoint] = [:]
        if mode == .incremental {
            for section in LibrarySyncSection.allCases {
                let baseline = completedCheckpoints[serverID]?[section]
                initialCheckpoints[section] = LibrarySyncCheckpoint(
                    sessionID: session.id,
                    serverID: serverID,
                    section: section,
                    sourceRevision: baseline?.sourceRevision
                )
            }
        }
        staging[session.id] = Staging(
            session: session,
            records: mode == .full ? Records() : (committed[serverID] ?? Records()),
            checkpoints: initialCheckpoints,
            isSuspended: false
        )
        return session
    }

    public func checkpoint(
        session: LibrarySyncSession,
        section: LibrarySyncSection
    ) throws -> LibrarySyncCheckpoint? {
        try staging(for: session).checkpoints[section]
    }

    public func stageArtists(_ artists: [Artist], session: LibrarySyncSession) throws {
        try validate(artists.map { ($0.serverID, $0.id.rawValue) }, session: session)
        try Task.checkCancellation()
        for artist in artists { staging[session.id]?.records.artists[artist.id] = artist }
    }

    public func stageAlbums(_ albums: [Album], session: LibrarySyncSession) throws {
        try validate(albums.map { ($0.serverID, $0.id.rawValue) }, session: session)
        try Task.checkCancellation()
        for album in albums { staging[session.id]?.records.albums[album.id] = album }
    }

    public func stageTracks(_ tracks: [Track], session: LibrarySyncSession) throws {
        try validate(tracks.map { ($0.serverID, $0.id.rawValue) }, session: session)
        try Task.checkCancellation()
        for track in tracks { staging[session.id]?.records.tracks[track.id] = track }
    }

    public func saveCheckpoint(
        _ checkpoint: LibrarySyncCheckpoint,
        session: LibrarySyncSession
    ) throws {
        _ = try staging(for: session)
        guard checkpoint.sessionID == session.id,
              checkpoint.serverID == session.serverID,
              checkpoint.processedCount >= 0
        else {
            throw LibrarySyncError.sessionMismatch
        }
        try Task.checkCancellation()
        staging[session.id]?.checkpoints[checkpoint.section] = checkpoint
    }

    public func completeSync(_ session: LibrarySyncSession, completedAt: Date) throws {
        let staged = try staging(for: session)
        try Task.checkCancellation()
        guard LibrarySyncSection.allCases.allSatisfy({ staged.checkpoints[$0]?.completedAt != nil }) else {
            throw LibrarySyncError.sessionMismatch
        }
        committed[session.serverID] = staged.records
        completedCheckpoints[session.serverID] = staged.checkpoints.mapValues { checkpoint in
            var value = checkpoint
            value.completedAt = completedAt
            value.updatedAt = completedAt
            return value
        }
        staging.removeValue(forKey: session.id)
    }

    public func suspendSync(_ session: LibrarySyncSession) {
        guard var value = staging[session.id], value.session == session else { return }
        value.isSuspended = true
        staging[session.id] = value
    }

    public func discardSync(_ session: LibrarySyncSession) {
        guard staging[session.id]?.session == session else { return }
        staging.removeValue(forKey: session.id)
    }

    public func hasSuspendedSync(serverID: ServerID, mode: LibrarySyncMode) -> Bool {
        staging.values.contains {
            $0.session.serverID == serverID && $0.session.mode == mode && $0.isSuspended
        }
    }

    public func completedCheckpoint(
        serverID: ServerID,
        section: LibrarySyncSection
    ) -> LibrarySyncCheckpoint? {
        completedCheckpoints[serverID]?[section]
    }

    private func staging(for session: LibrarySyncSession) throws -> Staging {
        guard let value = staging[session.id] else {
            throw LibrarySyncError.unknownSession(session.id)
        }
        guard value.session == session else { throw LibrarySyncError.sessionMismatch }
        return value
    }

    private func validate(_ records: [(ServerID, String)], session: LibrarySyncSession) throws {
        _ = try staging(for: session)
        for (serverID, recordID) in records where serverID != session.serverID {
            throw LibrarySyncError.invalidRecordServer(
                section: .tracks,
                recordID: recordID,
                expected: session.serverID,
                actual: serverID
            )
        }
    }

    private func page<Value>(_ values: [Value], offset: Int, limit: Int) -> [Value] {
        guard limit > 0, !values.isEmpty else { return [] }
        let start = min(max(0, offset), values.count)
        let end = min(values.count, start + limit)
        return Array(values[start..<end])
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func sortedTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted {
            let lhs = normalized("\($0.artistName) \($0.albumTitle) \($0.discNumber ?? 0) \($0.trackNumber ?? 0) \($0.title)")
            let rhs = normalized("\($1.artistName) \($1.albumTitle) \($1.discNumber ?? 0) \($1.trackNumber ?? 0) \($1.title)")
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
        }
    }
}
