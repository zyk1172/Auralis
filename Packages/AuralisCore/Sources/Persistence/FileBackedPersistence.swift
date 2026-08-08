import Darwin
import Domain
import Foundation

/// A dependency-free durable store intended for the first production slice.
///
/// It provides atomic archive replacement and actor isolation. The application must create one
/// instance per archive URL. It deliberately does not pretend to be the final 100k-track database:
/// GRDB-backed pagination/indexing can replace this implementation behind `AuralisPersisting`
/// without changing repositories or sync use cases.
public actor FileBackedPersistence: AuralisPersisting {
    private struct Archive: Codable, Sendable {
        var schemaVersion: Int
        var servers: [String: ServerRecords]
        var checkpoints: [String: PersistenceSyncCheckpoint]

        init(
            schemaVersion: Int = AuralisSchema.currentVersion,
            servers: [String: ServerRecords] = [:],
            checkpoints: [String: PersistenceSyncCheckpoint] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.servers = servers
            self.checkpoints = checkpoints
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case servers
            case checkpoints
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            servers = try container.decodeIfPresent([String: ServerRecords].self, forKey: .servers) ?? [:]
            checkpoints = try container.decodeIfPresent(
                [String: PersistenceSyncCheckpoint].self,
                forKey: .checkpoints
            ) ?? [:]
        }
    }

    private struct ServerRecords: Codable, Sendable {
        var account: ServerAccount?
        var artists: [String: Artist]
        var albums: [String: Album]
        var tracks: [String: Track]

        init(
            account: ServerAccount? = nil,
            artists: [String: Artist] = [:],
            albums: [String: Album] = [:],
            tracks: [String: Track] = [:]
        ) {
            self.account = account
            self.artists = artists
            self.albums = albums
            self.tracks = tracks
        }

        private enum CodingKeys: String, CodingKey {
            case account
            case artists
            case albums
            case tracks
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            account = try container.decodeIfPresent(ServerAccount.self, forKey: .account)
            artists = try container.decodeIfPresent([String: Artist].self, forKey: .artists) ?? [:]
            albums = try container.decodeIfPresent([String: Album].self, forKey: .albums) ?? [:]
            tracks = try container.decodeIfPresent([String: Track].self, forKey: .tracks) ?? [:]
        }
    }

    private struct StagedRecords: Sendable {
        let session: PersistenceSyncSession
        var records: ServerRecords
    }

    public nonisolated let fileURL: URL
    private var archive: Archive
    private var stagedBySession: [UUID: StagedRecords] = [:]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL.standardizedFileURL
        let loaded = try Self.loadArchive(from: self.fileURL)
        let migrated = try Self.migrate(loaded.archive)
        archive = migrated

        if loaded.requiresWrite || migrated.schemaVersion != loaded.archive.schemaVersion {
            try Self.writeArchive(migrated, to: self.fileURL)
        }
    }

    public func schemaVersion() -> Int { archive.schemaVersion }

    public func saveAccount(_ account: ServerAccount) throws {
        try Task.checkCancellation()
        var next = archive
        var records = next.servers[account.id.rawValue] ?? ServerRecords()
        records.account = account
        next.servers[account.id.rawValue] = records
        try commit(next)
    }

    public func accounts() -> [ServerAccount] {
        archive.servers.values.compactMap(\.account).sorted {
            let lhs = SearchIndex.normalize($0.displayName)
            let rhs = SearchIndex.normalize($1.displayName)
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
        }
    }

    public func account(id: ServerID) -> ServerAccount? {
        archive.servers[id.rawValue]?.account
    }

    public func saveSnapshot(_ snapshot: ServerLibrarySnapshot) throws {
        try validateSnapshot(snapshot)
        try Task.checkCancellation()

        let records = ServerRecords(
            account: snapshot.account,
            artists: Dictionary(snapshot.artists.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { _, latest in latest }),
            albums: Dictionary(snapshot.albums.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { _, latest in latest }),
            tracks: Dictionary(snapshot.tracks.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { _, latest in latest })
        )

        var next = archive
        next.servers[snapshot.serverID.rawValue] = records
        next.checkpoints = next.checkpoints.filter { $0.value.serverID != snapshot.serverID }
        for checkpoint in snapshot.checkpoints {
            next.checkpoints[checkpoint.id] = checkpoint
        }
        try commit(next)
    }

    public func snapshot(serverID: ServerID) -> ServerLibrarySnapshot? {
        guard let records = archive.servers[serverID.rawValue] else { return nil }
        return ServerLibrarySnapshot(
            serverID: serverID,
            account: records.account,
            artists: sortedArtists(records.artists.values),
            albums: sortedAlbums(records.albums.values),
            tracks: sortedTracks(records.tracks.values),
            checkpoints: archive.checkpoints.values
                .filter { $0.serverID == serverID }
                .sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
    }

    @discardableResult
    public func upsertArtists(_ artists: [Artist], serverID: ServerID) throws -> PersistenceMutationSummary {
        try validate(artists.map { ($0.serverID, $0.id.rawValue) }, serverID: serverID)
        try Task.checkCancellation()
        var next = archive
        var records = next.servers[serverID.rawValue] ?? ServerRecords()
        let existing = Dictionary(uniqueKeysWithValues: records.artists.map { (ArtistID(rawValue: $0.key), $0.value) })
        let summary = mutationSummary(existing: existing, incoming: artists, id: \.id)
        for artist in artists { records.artists[artist.id.rawValue] = artist }
        next.servers[serverID.rawValue] = records
        try commit(next)
        return summary
    }

    @discardableResult
    public func upsertAlbums(_ albums: [Album], serverID: ServerID) throws -> PersistenceMutationSummary {
        try validate(albums.map { ($0.serverID, $0.id.rawValue) }, serverID: serverID)
        try Task.checkCancellation()
        var next = archive
        var records = next.servers[serverID.rawValue] ?? ServerRecords()
        let existing = Dictionary(uniqueKeysWithValues: records.albums.map { (AlbumID(rawValue: $0.key), $0.value) })
        let summary = mutationSummary(existing: existing, incoming: albums, id: \.id)
        for album in albums { records.albums[album.id.rawValue] = album }
        next.servers[serverID.rawValue] = records
        try commit(next)
        return summary
    }

    @discardableResult
    public func upsertTracks(_ tracks: [Track], serverID: ServerID) throws -> PersistenceMutationSummary {
        try validate(tracks.map { ($0.serverID, $0.id.rawValue) }, serverID: serverID)
        try Task.checkCancellation()
        var next = archive
        var records = next.servers[serverID.rawValue] ?? ServerRecords()
        let existing = Dictionary(uniqueKeysWithValues: records.tracks.map { (TrackID(rawValue: $0.key), $0.value) })
        let summary = mutationSummary(existing: existing, incoming: tracks, id: \.id)
        for track in tracks { records.tracks[track.id.rawValue] = track }
        next.servers[serverID.rawValue] = records
        try commit(next)
        return summary
    }

    public func artists(serverID: ServerID, offset: Int, limit: Int) -> [Artist] {
        page(sortedArtists(archive.servers[serverID.rawValue]?.artists.values ?? Dictionary<String, Artist>().values), offset: offset, limit: limit)
    }

    public func albums(serverID: ServerID, offset: Int, limit: Int) -> [Album] {
        page(sortedAlbums(archive.servers[serverID.rawValue]?.albums.values ?? Dictionary<String, Album>().values), offset: offset, limit: limit)
    }

    public func tracks(serverID: ServerID, offset: Int, limit: Int) -> [Track] {
        page(sortedTracks(archive.servers[serverID.rawValue]?.tracks.values ?? Dictionary<String, Track>().values), offset: offset, limit: limit)
    }

    public func track(id: TrackID, serverID: ServerID) -> Track? {
        archive.servers[serverID.rawValue]?.tracks[id.rawValue]
    }

    public func searchTracks(serverID: ServerID, query: String, offset: Int, limit: Int) -> [Track] {
        SearchIndex.search(
            archive.servers[serverID.rawValue]?.tracks.values.map { $0 } ?? [],
            query: query,
            offset: offset,
            limit: limit
        )
    }

    public func saveCheckpoint(_ checkpoint: PersistenceSyncCheckpoint) throws {
        guard checkpoint.processedCount >= 0 else {
            throw PersistenceError.corruptArchive("A sync checkpoint has a negative processed count.")
        }
        try Task.checkCancellation()
        var next = archive
        next.checkpoints[checkpoint.id] = checkpoint
        try commit(next)
    }

    public func checkpoint(serverID: ServerID, kind: LibraryRecordKind) -> PersistenceSyncCheckpoint? {
        archive.checkpoints[checkpointKey(serverID: serverID, kind: kind)]
    }

    public func clearCheckpoints(serverID: ServerID) throws {
        try Task.checkCancellation()
        var next = archive
        next.checkpoints = next.checkpoints.filter { $0.value.serverID != serverID }
        try commit(next)
    }

    public func beginFullSync(serverID: ServerID) throws -> PersistenceSyncSession {
        try Task.checkCancellation()
        let session = PersistenceSyncSession(serverID: serverID)
        let account = archive.servers[serverID.rawValue]?.account
        stagedBySession[session.id] = StagedRecords(
            session: session,
            records: ServerRecords(account: account)
        )
        return session
    }

    public func stageArtists(_ artists: [Artist], session: PersistenceSyncSession) throws {
        try validateSession(session)
        try validate(artists.map { ($0.serverID, $0.id.rawValue) }, serverID: session.serverID)
        try Task.checkCancellation()
        for artist in artists { stagedBySession[session.id]?.records.artists[artist.id.rawValue] = artist }
    }

    public func stageAlbums(_ albums: [Album], session: PersistenceSyncSession) throws {
        try validateSession(session)
        try validate(albums.map { ($0.serverID, $0.id.rawValue) }, serverID: session.serverID)
        try Task.checkCancellation()
        for album in albums { stagedBySession[session.id]?.records.albums[album.id.rawValue] = album }
    }

    public func stageTracks(_ tracks: [Track], session: PersistenceSyncSession) throws {
        try validateSession(session)
        try validate(tracks.map { ($0.serverID, $0.id.rawValue) }, serverID: session.serverID)
        try Task.checkCancellation()
        for track in tracks { stagedBySession[session.id]?.records.tracks[track.id.rawValue] = track }
    }

    public func commitFullSync(_ session: PersistenceSyncSession) throws {
        try validateSession(session)
        try Task.checkCancellation()
        guard let staged = stagedBySession[session.id] else {
            throw PersistenceError.unknownSyncSession(session.id)
        }
        var next = archive
        next.servers[session.serverID.rawValue] = staged.records
        try commit(next)
        stagedBySession.removeValue(forKey: session.id)
    }

    public func discardFullSync(_ session: PersistenceSyncSession) {
        stagedBySession.removeValue(forKey: session.id)
    }

    public func removeServer(_ serverID: ServerID) throws {
        try Task.checkCancellation()
        var next = archive
        next.servers.removeValue(forKey: serverID.rawValue)
        next.checkpoints = next.checkpoints.filter { $0.value.serverID != serverID }
        try commit(next)
        stagedBySession = stagedBySession.filter { $0.value.session.serverID != serverID }
    }

    public func integrityReport() -> PersistenceIntegrityReport {
        makeIntegrityReport(
            schemaVersion: archive.schemaVersion,
            records: Dictionary(uniqueKeysWithValues: archive.servers.map { key, records in
                (
                    ServerID(rawValue: key),
                    IntegrityRecords(
                        account: records.account,
                        artists: Array(records.artists.values),
                        albums: Array(records.albums.values),
                        tracks: Array(records.tracks.values)
                    )
                )
            }),
            checkpoints: Array(archive.checkpoints.values)
        )
    }

    private func validateSession(_ session: PersistenceSyncSession) throws {
        guard let stored = stagedBySession[session.id] else {
            throw PersistenceError.unknownSyncSession(session.id)
        }
        guard stored.session.serverID == session.serverID else {
            throw PersistenceError.syncSessionServerMismatch(
                expected: stored.session.serverID,
                actual: session.serverID
            )
        }
    }

    private func commit(_ next: Archive) throws {
        try Task.checkCancellation()
        try Self.writeArchive(next, to: fileURL)
        // Once the atomic rename succeeds, in-memory state must advance even if the caller was
        // cancelled concurrently. Checking cancellation here would split durable and visible state.
        archive = next
    }

    private static func loadArchive(from fileURL: URL) throws -> (archive: Archive, requiresWrite: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (Archive(), true)
        }

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            return (try decoder().decode(Archive.self, from: data), false)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.corruptArchive("The library archive could not be decoded: \(error.localizedDescription)")
        }
    }

    private static func migrate(_ archive: Archive) throws -> Archive {
        guard archive.schemaVersion <= AuralisSchema.currentVersion else {
            throw PersistenceError.unsupportedSchemaVersion(
                found: archive.schemaVersion,
                supported: AuralisSchema.currentVersion
            )
        }
        guard archive.schemaVersion >= 1 else {
            throw PersistenceError.corruptArchive("Schema versions below 1 are invalid.")
        }

        var migrated = archive
        // Version 2 adds optional account records and sync checkpoints. Both decode to empty values,
        // so migration is metadata-only and preserves every version-1 record.
        if migrated.schemaVersion == 1 {
            migrated.schemaVersion = 2
        }
        return migrated
    }

    private static func writeArchive(_ archive: Archive, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder().encode(archive)
        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).secure-write",
            isDirectory: false
        )

        // Create the temporary inode with owner-only permissions. Applying chmod
        // after Data.write(.atomic) leaves a short interval in which the temporary
        // file can inherit a broader process umask.
        let descriptor = temporaryURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw posixError(errno) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            // This protection class remains available to background synchronization
            // after the first device unlock, matching the Keychain accessibility
            // selected for server credentials.
            try fileManager.setAttributes(secureFileAttributes, ofItemAtPath: temporaryURL.path)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            let renameStatus = temporaryURL.path.withCString { source in
                fileURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameStatus == 0 else { throw posixError(errno) }
            shouldRemoveTemporaryFile = false
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static var secureFileAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
#endif
        return attributes
    }

    private static func posixError(_ code: Int32) -> Error {
        if let errorCode = POSIXErrorCode(rawValue: code) {
            return POSIXError(errorCode)
        }
        return CocoaError(.fileWriteUnknown)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
