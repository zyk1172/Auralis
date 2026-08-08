import Domain
import Foundation

public struct DatabaseMigration: Codable, Hashable, Sendable {
    public let version: Int
    public let name: String

    public init(version: Int, name: String) {
        self.version = version
        self.name = name
    }
}

public enum AuralisSchema {
    public static let migrations: [DatabaseMigration] = [
        .init(version: 1, name: "initial-domain-schema"),
        .init(version: 2, name: "multi-server-library-and-sync-checkpoints"),
    ]

    public static var currentVersion: Int {
        migrations.map(\.version).max() ?? 1
    }
}

public enum LibraryRecordKind: String, Codable, CaseIterable, Hashable, Sendable {
    case artists
    case albums
    case tracks
}

public struct PersistenceMutationSummary: Codable, Hashable, Sendable {
    public let inserted: Int
    public let updated: Int
    public let unchanged: Int

    public init(inserted: Int, updated: Int, unchanged: Int) {
        self.inserted = inserted
        self.updated = updated
        self.unchanged = unchanged
    }

    public static let none = PersistenceMutationSummary(inserted: 0, updated: 0, unchanged: 0)
}

public struct PersistenceSyncCheckpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(serverID.rawValue):\(kind.rawValue)" }
    public let serverID: ServerID
    public let kind: LibraryRecordKind
    public var continuation: String?
    public var sourceRevision: String?
    public var processedCount: Int
    public var completedAt: Date?
    public var updatedAt: Date

    public init(
        serverID: ServerID,
        kind: LibraryRecordKind,
        continuation: String? = nil,
        sourceRevision: String? = nil,
        processedCount: Int = 0,
        completedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.serverID = serverID
        self.kind = kind
        self.continuation = continuation
        self.sourceRevision = sourceRevision
        self.processedCount = processedCount
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

public struct PersistenceSyncSession: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let serverID: ServerID
    public let startedAt: Date

    public init(id: UUID = UUID(), serverID: ServerID, startedAt: Date = .now) {
        self.id = id
        self.serverID = serverID
        self.startedAt = startedAt
    }
}

public struct ServerLibrarySnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: ServerID { serverID }
    public let serverID: ServerID
    public var account: ServerAccount?
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
    public var checkpoints: [PersistenceSyncCheckpoint]

    public init(
        serverID: ServerID,
        account: ServerAccount? = nil,
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = [],
        checkpoints: [PersistenceSyncCheckpoint] = []
    ) {
        self.serverID = serverID
        self.account = account
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.checkpoints = checkpoints
    }
}

public struct PersistenceIntegrityIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case mismatchedServer
        case duplicateIdentifier
        case missingArtist
        case missingAlbum
        case invalidCheckpoint
        case invalidSchemaVersion
    }

    public var id: String {
        [code.rawValue, serverID?.rawValue, recordID].compactMap { $0 }.joined(separator: ":")
    }

    public let code: Code
    public let serverID: ServerID?
    public let recordID: String?
    public let message: String

    public init(code: Code, serverID: ServerID? = nil, recordID: String? = nil, message: String) {
        self.code = code
        self.serverID = serverID
        self.recordID = recordID
        self.message = message
    }
}

public struct PersistenceIntegrityReport: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let checkedServerCount: Int
    public let checkedArtistCount: Int
    public let checkedAlbumCount: Int
    public let checkedTrackCount: Int
    public let issues: [PersistenceIntegrityIssue]
    public var isValid: Bool { issues.isEmpty }

    public init(
        schemaVersion: Int,
        checkedServerCount: Int,
        checkedArtistCount: Int,
        checkedAlbumCount: Int,
        checkedTrackCount: Int,
        issues: [PersistenceIntegrityIssue]
    ) {
        self.schemaVersion = schemaVersion
        self.checkedServerCount = checkedServerCount
        self.checkedArtistCount = checkedArtistCount
        self.checkedAlbumCount = checkedAlbumCount
        self.checkedTrackCount = checkedTrackCount
        self.issues = issues
    }
}

public enum PersistenceError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptArchive(String)
    case invalidRecordServer(expected: ServerID, actual: ServerID, recordID: String)
    case unknownSyncSession(UUID)
    case syncSessionServerMismatch(expected: ServerID, actual: ServerID)
}

/// The storage contract used by application-layer repositories and synchronizers.
///
/// Implementations must make each mutation atomic: cancellation or a failed durable write
/// must leave the previously committed library visible.
public protocol AuralisPersisting: Sendable {
    func schemaVersion() async -> Int

    func saveAccount(_ account: ServerAccount) async throws
    func accounts() async throws -> [ServerAccount]
    func account(id: ServerID) async throws -> ServerAccount?
    func saveSnapshot(_ snapshot: ServerLibrarySnapshot) async throws
    func snapshot(serverID: ServerID) async throws -> ServerLibrarySnapshot?

    @discardableResult
    func upsertArtists(_ artists: [Artist], serverID: ServerID) async throws -> PersistenceMutationSummary
    @discardableResult
    func upsertAlbums(_ albums: [Album], serverID: ServerID) async throws -> PersistenceMutationSummary
    @discardableResult
    func upsertTracks(_ tracks: [Track], serverID: ServerID) async throws -> PersistenceMutationSummary

    func artists(serverID: ServerID, offset: Int, limit: Int) async throws -> [Artist]
    func albums(serverID: ServerID, offset: Int, limit: Int) async throws -> [Album]
    func tracks(serverID: ServerID, offset: Int, limit: Int) async throws -> [Track]
    func track(id: TrackID, serverID: ServerID) async throws -> Track?
    func searchTracks(serverID: ServerID, query: String, offset: Int, limit: Int) async throws -> [Track]

    func saveCheckpoint(_ checkpoint: PersistenceSyncCheckpoint) async throws
    func checkpoint(serverID: ServerID, kind: LibraryRecordKind) async throws -> PersistenceSyncCheckpoint?
    func clearCheckpoints(serverID: ServerID) async throws

    func beginFullSync(serverID: ServerID) async throws -> PersistenceSyncSession
    func stageArtists(_ artists: [Artist], session: PersistenceSyncSession) async throws
    func stageAlbums(_ albums: [Album], session: PersistenceSyncSession) async throws
    func stageTracks(_ tracks: [Track], session: PersistenceSyncSession) async throws
    func commitFullSync(_ session: PersistenceSyncSession) async throws
    func discardFullSync(_ session: PersistenceSyncSession) async

    func removeServer(_ serverID: ServerID) async throws
    func integrityReport() async throws -> PersistenceIntegrityReport
}

public extension AuralisPersisting {
    /// Backward-compatible alias. Saving is an upsert and never removes records omitted from the batch.
    func saveTracks(_ tracks: [Track], serverID: ServerID) async throws {
        _ = try await upsertTracks(tracks, serverID: serverID)
    }

    func integrityCheck() async throws -> Bool {
        try await integrityReport().isValid
    }
}

public actor InMemoryPersistence: AuralisPersisting {
    private struct ServerRecords: Sendable {
        var account: ServerAccount?
        var artists: [ArtistID: Artist] = [:]
        var albums: [AlbumID: Album] = [:]
        var tracks: [TrackID: Track] = [:]
    }

    private struct StagedRecords: Sendable {
        let session: PersistenceSyncSession
        var records = ServerRecords()
    }

    private var recordsByServer: [ServerID: ServerRecords] = [:]
    private var checkpoints: [String: PersistenceSyncCheckpoint] = [:]
    private var stagedBySession: [UUID: StagedRecords] = [:]

    public init() {}

    public func schemaVersion() -> Int { AuralisSchema.currentVersion }

    public func saveAccount(_ account: ServerAccount) throws {
        try Task.checkCancellation()
        var records = recordsByServer[account.id] ?? ServerRecords()
        records.account = account
        recordsByServer[account.id] = records
    }

    public func accounts() -> [ServerAccount] {
        recordsByServer.values.compactMap(\.account).sorted {
            let lhs = SearchIndex.normalize($0.displayName)
            let rhs = SearchIndex.normalize($1.displayName)
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
        }
    }

    public func account(id: ServerID) -> ServerAccount? {
        recordsByServer[id]?.account
    }

    public func saveSnapshot(_ snapshot: ServerLibrarySnapshot) throws {
        try validateSnapshot(snapshot)
        try Task.checkCancellation()
        var records = ServerRecords(account: snapshot.account)
        for artist in snapshot.artists { records.artists[artist.id] = artist }
        for album in snapshot.albums { records.albums[album.id] = album }
        for track in snapshot.tracks { records.tracks[track.id] = track }

        var nextCheckpoints = checkpoints.filter { $0.value.serverID != snapshot.serverID }
        for checkpoint in snapshot.checkpoints {
            nextCheckpoints[checkpoint.id] = checkpoint
        }

        recordsByServer[snapshot.serverID] = records
        checkpoints = nextCheckpoints
    }

    public func snapshot(serverID: ServerID) -> ServerLibrarySnapshot? {
        guard let records = recordsByServer[serverID] else { return nil }
        return ServerLibrarySnapshot(
            serverID: serverID,
            account: records.account,
            artists: sortedArtists(records.artists.values),
            albums: sortedAlbums(records.albums.values),
            tracks: sortedTracks(records.tracks.values),
            checkpoints: checkpoints.values.filter { $0.serverID == serverID }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
    }

    @discardableResult
    public func upsertArtists(_ artists: [Artist], serverID: ServerID) throws -> PersistenceMutationSummary {
        try validate(artists.map { ($0.serverID, $0.id.rawValue) }, serverID: serverID)
        try Task.checkCancellation()
        var records = recordsByServer[serverID] ?? ServerRecords()
        let summary = mutationSummary(existing: records.artists, incoming: artists, id: \.id)
        for artist in artists { records.artists[artist.id] = artist }
        recordsByServer[serverID] = records
        return summary
    }

    @discardableResult
    public func upsertAlbums(_ albums: [Album], serverID: ServerID) throws -> PersistenceMutationSummary {
        try validate(albums.map { ($0.serverID, $0.id.rawValue) }, serverID: serverID)
        try Task.checkCancellation()
        var records = recordsByServer[serverID] ?? ServerRecords()
        let summary = mutationSummary(existing: records.albums, incoming: albums, id: \.id)
        for album in albums { records.albums[album.id] = album }
        recordsByServer[serverID] = records
        return summary
    }

    @discardableResult
    public func upsertTracks(_ tracks: [Track], serverID: ServerID) throws -> PersistenceMutationSummary {
        try validate(tracks.map { ($0.serverID, $0.id.rawValue) }, serverID: serverID)
        try Task.checkCancellation()
        var records = recordsByServer[serverID] ?? ServerRecords()
        let summary = mutationSummary(existing: records.tracks, incoming: tracks, id: \.id)
        for track in tracks { records.tracks[track.id] = track }
        recordsByServer[serverID] = records
        return summary
    }

    public func artists(serverID: ServerID, offset: Int, limit: Int) -> [Artist] {
        page(sortedArtists(recordsByServer[serverID]?.artists.values ?? Dictionary<ArtistID, Artist>().values), offset: offset, limit: limit)
    }

    public func albums(serverID: ServerID, offset: Int, limit: Int) -> [Album] {
        page(sortedAlbums(recordsByServer[serverID]?.albums.values ?? Dictionary<AlbumID, Album>().values), offset: offset, limit: limit)
    }

    public func tracks(serverID: ServerID, offset: Int, limit: Int) -> [Track] {
        page(sortedTracks(recordsByServer[serverID]?.tracks.values ?? Dictionary<TrackID, Track>().values), offset: offset, limit: limit)
    }

    public func track(id: TrackID, serverID: ServerID) -> Track? {
        recordsByServer[serverID]?.tracks[id]
    }

    public func searchTracks(serverID: ServerID, query: String, offset: Int, limit: Int) -> [Track] {
        SearchIndex.search(
            recordsByServer[serverID]?.tracks.values.map { $0 } ?? [],
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
        checkpoints[checkpoint.id] = checkpoint
    }

    public func checkpoint(serverID: ServerID, kind: LibraryRecordKind) -> PersistenceSyncCheckpoint? {
        checkpoints[checkpointKey(serverID: serverID, kind: kind)]
    }

    public func clearCheckpoints(serverID: ServerID) throws {
        try Task.checkCancellation()
        checkpoints = checkpoints.filter { $0.value.serverID != serverID }
    }

    public func beginFullSync(serverID: ServerID) throws -> PersistenceSyncSession {
        try Task.checkCancellation()
        let session = PersistenceSyncSession(serverID: serverID)
        stagedBySession[session.id] = StagedRecords(
            session: session,
            records: ServerRecords(account: recordsByServer[serverID]?.account)
        )
        return session
    }

    public func stageArtists(_ artists: [Artist], session: PersistenceSyncSession) throws {
        try validateSession(session)
        try validate(artists.map { ($0.serverID, $0.id.rawValue) }, serverID: session.serverID)
        try Task.checkCancellation()
        for artist in artists { stagedBySession[session.id]?.records.artists[artist.id] = artist }
    }

    public func stageAlbums(_ albums: [Album], session: PersistenceSyncSession) throws {
        try validateSession(session)
        try validate(albums.map { ($0.serverID, $0.id.rawValue) }, serverID: session.serverID)
        try Task.checkCancellation()
        for album in albums { stagedBySession[session.id]?.records.albums[album.id] = album }
    }

    public func stageTracks(_ tracks: [Track], session: PersistenceSyncSession) throws {
        try validateSession(session)
        try validate(tracks.map { ($0.serverID, $0.id.rawValue) }, serverID: session.serverID)
        try Task.checkCancellation()
        for track in tracks { stagedBySession[session.id]?.records.tracks[track.id] = track }
    }

    public func commitFullSync(_ session: PersistenceSyncSession) throws {
        try validateSession(session)
        try Task.checkCancellation()
        guard let staged = stagedBySession.removeValue(forKey: session.id) else {
            throw PersistenceError.unknownSyncSession(session.id)
        }
        recordsByServer[session.serverID] = staged.records
    }

    public func discardFullSync(_ session: PersistenceSyncSession) {
        stagedBySession.removeValue(forKey: session.id)
    }

    public func removeServer(_ serverID: ServerID) throws {
        try Task.checkCancellation()
        recordsByServer.removeValue(forKey: serverID)
        checkpoints = checkpoints.filter { $0.value.serverID != serverID }
        stagedBySession = stagedBySession.filter { $0.value.session.serverID != serverID }
    }

    public func integrityReport() -> PersistenceIntegrityReport {
        makeIntegrityReport(
            schemaVersion: AuralisSchema.currentVersion,
            records: recordsByServer.mapValues { records in
                IntegrityRecords(
                    account: records.account,
                    artists: Array(records.artists.values),
                    albums: Array(records.albums.values),
                    tracks: Array(records.tracks.values)
                )
            },
            checkpoints: Array(checkpoints.values)
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
}

struct IntegrityRecords: Sendable {
    let account: ServerAccount?
    let artists: [Artist]
    let albums: [Album]
    let tracks: [Track]
}

func validateSnapshot(_ snapshot: ServerLibrarySnapshot) throws {
    try Task.checkCancellation()
    if let account = snapshot.account, account.id != snapshot.serverID {
        throw PersistenceError.invalidRecordServer(
            expected: snapshot.serverID,
            actual: account.id,
            recordID: account.id.rawValue
        )
    }
    try validate(snapshot.artists.map { ($0.serverID, $0.id.rawValue) }, serverID: snapshot.serverID)
    try validate(snapshot.albums.map { ($0.serverID, $0.id.rawValue) }, serverID: snapshot.serverID)
    try validate(snapshot.tracks.map { ($0.serverID, $0.id.rawValue) }, serverID: snapshot.serverID)
    for checkpoint in snapshot.checkpoints where checkpoint.serverID != snapshot.serverID {
        throw PersistenceError.invalidRecordServer(
            expected: snapshot.serverID,
            actual: checkpoint.serverID,
            recordID: checkpoint.kind.rawValue
        )
    }
}

func checkpointKey(serverID: ServerID, kind: LibraryRecordKind) -> String {
    "\(serverID.rawValue):\(kind.rawValue)"
}

func validate(_ records: [(serverID: ServerID, recordID: String)], serverID: ServerID) throws {
    try Task.checkCancellation()
    for (index, record) in records.enumerated() {
        if index.isMultiple(of: 128) { try Task.checkCancellation() }
        guard record.serverID == serverID else {
            throw PersistenceError.invalidRecordServer(
                expected: serverID,
                actual: record.serverID,
                recordID: record.recordID
            )
        }
    }
}

func mutationSummary<ID: Hashable, Value: Hashable>(
    existing: [ID: Value],
    incoming: [Value],
    id: KeyPath<Value, ID>
) -> PersistenceMutationSummary {
    var inserted = 0
    var updated = 0
    var unchanged = 0
    var effective = existing

    for value in incoming {
        let identifier = value[keyPath: id]
        switch effective[identifier] {
        case nil:
            inserted += 1
        case value?:
            unchanged += 1
        default:
            updated += 1
        }
        effective[identifier] = value
    }

    return PersistenceMutationSummary(inserted: inserted, updated: updated, unchanged: unchanged)
}

func page<Value>(_ values: [Value], offset: Int, limit: Int) -> [Value] {
    guard limit > 0, !values.isEmpty else { return [] }
    let start = min(max(0, offset), values.count)
    let end = min(values.count, start + limit)
    return Array(values[start..<end])
}

func sortedArtists<S: Sequence>(_ values: S) -> [Artist] where S.Element == Artist {
    values.sorted {
        let lhs = SearchIndex.normalize($0.name)
        let rhs = SearchIndex.normalize($1.name)
        return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
    }
}

func sortedAlbums<S: Sequence>(_ values: S) -> [Album] where S.Element == Album {
    values.sorted {
        let lhs = SearchIndex.normalize("\($0.artistName) \($0.title)")
        let rhs = SearchIndex.normalize("\($1.artistName) \($1.title)")
        return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
    }
}

func sortedTracks<S: Sequence>(_ values: S) -> [Track] where S.Element == Track {
    values.sorted {
        let lhs = SearchIndex.sortKey(for: $0)
        let rhs = SearchIndex.sortKey(for: $1)
        return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
    }
}

func makeIntegrityReport(
    schemaVersion: Int,
    records: [ServerID: IntegrityRecords],
    checkpoints: [PersistenceSyncCheckpoint]
) -> PersistenceIntegrityReport {
    var issues: [PersistenceIntegrityIssue] = []
    var artistCount = 0
    var albumCount = 0
    var trackCount = 0

    if schemaVersion != AuralisSchema.currentVersion {
        issues.append(.init(
            code: .invalidSchemaVersion,
            message: "Schema version \(schemaVersion) is not the current version \(AuralisSchema.currentVersion)."
        ))
    }

    for (serverID, serverRecords) in records {
        artistCount += serverRecords.artists.count
        albumCount += serverRecords.albums.count
        trackCount += serverRecords.tracks.count

        let artistIDs = Set(serverRecords.artists.map(\.id))
        let albumIDs = Set(serverRecords.albums.map(\.id))

        if let account = serverRecords.account, account.id != serverID {
            issues.append(.init(
                code: .mismatchedServer,
                serverID: serverID,
                recordID: account.id.rawValue,
                message: "Account is stored under a different server identifier."
            ))
        }

        for artist in serverRecords.artists where artist.serverID != serverID {
            issues.append(.init(
                code: .mismatchedServer,
                serverID: serverID,
                recordID: artist.id.rawValue,
                message: "Artist belongs to a different server."
            ))
        }

        for album in serverRecords.albums {
            if album.serverID != serverID {
                issues.append(.init(
                    code: .mismatchedServer,
                    serverID: serverID,
                    recordID: album.id.rawValue,
                    message: "Album belongs to a different server."
                ))
            }
            if !artistIDs.contains(album.artistID) {
                issues.append(.init(
                    code: .missingArtist,
                    serverID: serverID,
                    recordID: album.id.rawValue,
                    message: "Album references an artist that is not stored for this server."
                ))
            }
        }

        for track in serverRecords.tracks {
            if track.serverID != serverID {
                issues.append(.init(
                    code: .mismatchedServer,
                    serverID: serverID,
                    recordID: track.id.rawValue,
                    message: "Track belongs to a different server."
                ))
            }
            if !artistIDs.contains(track.artistID) {
                issues.append(.init(
                    code: .missingArtist,
                    serverID: serverID,
                    recordID: track.id.rawValue,
                    message: "Track references an artist that is not stored for this server."
                ))
            }
            if !albumIDs.contains(track.albumID) {
                issues.append(.init(
                    code: .missingAlbum,
                    serverID: serverID,
                    recordID: track.id.rawValue,
                    message: "Track references an album that is not stored for this server."
                ))
            }
        }
    }

    for checkpoint in checkpoints {
        if checkpoint.processedCount < 0 {
            issues.append(.init(
                code: .invalidCheckpoint,
                serverID: checkpoint.serverID,
                recordID: checkpoint.kind.rawValue,
                message: "Sync checkpoint has a negative processed count."
            ))
        }
    }

    return PersistenceIntegrityReport(
        schemaVersion: schemaVersion,
        checkedServerCount: records.count,
        checkedArtistCount: artistCount,
        checkedAlbumCount: albumCount,
        checkedTrackCount: trackCount,
        issues: issues.sorted { $0.id < $1.id }
    )
}
