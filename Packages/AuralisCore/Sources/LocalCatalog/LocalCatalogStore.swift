import Domain
import Foundation
import MusicLibrary

/// SQLite 支撑的本地音乐目录。
///
/// - 所有远程对象以 `GlobalID = serverID + remoteID` 组合标识，多服务器数据隔离。
/// - 实现 `LibrarySyncStore`，可接入现有的 `LibrarySynchronizer` 完成全量/增量同步。
/// - 提供 `CatalogReader` 查询 API 供 Agent 工具与 UI 使用。
/// - 使用 FTS5 全文索引支持本地检索。
public actor LocalCatalogStore: LibrarySyncStore {
    let db: SQLiteDatabase
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public init(url: URL) throws {
        self.db = try SQLiteDatabase(url: url)
        try createSchema()
        try cleanupOrphanedSyncState()
        // 开放语义标签已恢复（dimension='tag'）：不再清理任何非固定维度，保留全部标签。
    }

    /// Canonical on-device catalog location shared by the app and extensions.
    /// Keeping this path in LocalCatalog prevents Application and AppShell from accidentally
    /// opening different databases and reintroducing a second music-library snapshot.
    public nonisolated static func defaultStoreURL(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = "group.com.auralis.player"
    ) -> URL {
        let base: URL
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            base = group
        } else {
            base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
        }
        let directory = base.appendingPathComponent("Auralis", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("catalog.sqlite")
    }

    // MARK: - Schema

    nonisolated private func createSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS servers (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            base_url TEXT,
            username TEXT,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS artists (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS albums (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tracks (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            title TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            album_title TEXT NOT NULL,
            duration REAL NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS genres (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playlists (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            is_readonly INTEGER NOT NULL DEFAULT 0,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playlist_tracks (
            playlist_gid TEXT NOT NULL,
            position INTEGER NOT NULL,
            track_gid TEXT NOT NULL,
            PRIMARY KEY (playlist_gid, position)
        );
        CREATE TABLE IF NOT EXISTS favorites (
            global_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            value INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ratings (
            global_id TEXT PRIMARY KEY,
            value INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS play_history (
            global_id TEXT PRIMARY KEY,
            last_played REAL NOT NULL,
            play_count INTEGER NOT NULL,
            completed INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS downloads (
            global_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            local_path TEXT,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS lyrics (
            global_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_checkpoints (
            session_id TEXT NOT NULL,
            server_id TEXT NOT NULL,
            section TEXT NOT NULL,
            continuation TEXT,
            source_revision TEXT,
            processed_count INTEGER NOT NULL,
            completed_at REAL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (session_id, section)
        );
        CREATE TABLE IF NOT EXISTS sync_sessions (
            session_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL UNIQUE,
            mode TEXT NOT NULL,
            started_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_staged_artists (
            session_id TEXT NOT NULL,
            global_id TEXT NOT NULL,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (session_id, global_id)
        );
        CREATE TABLE IF NOT EXISTS sync_staged_albums (
            session_id TEXT NOT NULL,
            global_id TEXT NOT NULL,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (session_id, global_id)
        );
        CREATE TABLE IF NOT EXISTS sync_staged_tracks (
            session_id TEXT NOT NULL,
            global_id TEXT NOT NULL,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            title TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            album_title TEXT NOT NULL,
            duration REAL NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (session_id, global_id)
        );
        CREATE TABLE IF NOT EXISTS sync_meta (
            server_id TEXT PRIMARY KEY,
            mode TEXT,
            last_completed_at REAL,
            last_processed_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at REAL,
            remote_fingerprint TEXT,
            remote_probe_kind TEXT,
            last_probe_at REAL,
            last_validated_at REAL
        );
        CREATE TABLE IF NOT EXISTS recommendation_index_v2_state (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            source_hash TEXT NOT NULL,
            rules_version TEXT NOT NULL,
            classifier TEXT NOT NULL,
            classified_at REAL NOT NULL,
            source_hash_version INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS recommendation_index_v2_tags (
            global_id TEXT NOT NULL,
            dimension TEXT NOT NULL,
            value TEXT NOT NULL,
            confidence REAL NOT NULL,
            PRIMARY KEY (global_id, dimension, value)
        );
        CREATE TABLE IF NOT EXISTS external_music_identities (
            global_track_id TEXT PRIMARY KEY,
            recording_mbid TEXT,
            release_mbid TEXT,
            release_group_mbid TEXT,
            artist_mbid TEXT,
            isrc TEXT,
            match_confidence REAL NOT NULL,
            match_method TEXT NOT NULL,
            verified_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS external_music_candidates (
            global_track_id TEXT NOT NULL,
            recording_mbid TEXT NOT NULL,
            payload TEXT NOT NULL,
            confidence REAL NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (global_track_id, recording_mbid)
        );
        CREATE TABLE IF NOT EXISTS community_music_metrics (
            global_track_id TEXT NOT NULL,
            source TEXT NOT NULL,
            payload TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            status TEXT NOT NULL,
            PRIMARY KEY (global_track_id, source)
        );
        CREATE TABLE IF NOT EXISTS community_music_evidence (
            global_track_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            fetched_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS community_music_reviews (
            global_track_id TEXT NOT NULL,
            source TEXT NOT NULL,
            review_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            PRIMARY KEY (global_track_id, source, review_id)
        );
        CREATE TABLE IF NOT EXISTS disliked_tracks (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            source TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(kind UNINDEXED, global_id UNINDEXED, text);
        CREATE INDEX IF NOT EXISTS idx_tracks_server ON tracks(server_id);
        CREATE INDEX IF NOT EXISTS idx_albums_server ON albums(server_id);
        CREATE INDEX IF NOT EXISTS idx_artists_server ON artists(server_id);
        CREATE INDEX IF NOT EXISTS idx_playlists_server ON playlists(server_id);
        CREATE INDEX IF NOT EXISTS idx_sync_checkpoints_server ON sync_checkpoints(server_id);
        CREATE INDEX IF NOT EXISTS idx_sync_staged_artists_session ON sync_staged_artists(session_id);
        CREATE INDEX IF NOT EXISTS idx_sync_staged_albums_session ON sync_staged_albums(session_id);
        CREATE INDEX IF NOT EXISTS idx_sync_staged_tracks_session ON sync_staged_tracks(session_id);
        CREATE INDEX IF NOT EXISTS idx_recommendation_v2_state_server ON recommendation_index_v2_state(server_id);
        CREATE INDEX IF NOT EXISTS idx_recommendation_v2_tags_dimension_value ON recommendation_index_v2_tags(dimension, value);
        CREATE INDEX IF NOT EXISTS idx_external_identity_recording ON external_music_identities(recording_mbid);
        CREATE INDEX IF NOT EXISTS idx_external_candidates_track ON external_music_candidates(global_track_id, confidence DESC);
        CREATE INDEX IF NOT EXISTS idx_community_metrics_track ON community_music_metrics(global_track_id, fetched_at DESC);
        CREATE INDEX IF NOT EXISTS idx_disliked_tracks_server ON disliked_tracks(server_id);
        CREATE INDEX IF NOT EXISTS idx_community_reviews_track ON community_music_reviews(global_track_id, fetched_at DESC);
        """)
        // Additive migration for databases created before revision-aware sync probes.
        try? db.run("ALTER TABLE recommendation_index_v2_state ADD COLUMN source_hash_version INTEGER NOT NULL DEFAULT 0")
        try? db.run("ALTER TABLE sync_meta ADD COLUMN remote_fingerprint TEXT")
        try? db.run("ALTER TABLE sync_meta ADD COLUMN remote_probe_kind TEXT")
        try? db.run("ALTER TABLE sync_meta ADD COLUMN last_probe_at REAL")
        try? db.run("ALTER TABLE sync_meta ADD COLUMN last_validated_at REAL")
    }

    /// Older builds persisted checkpoints without durable staged pages. Those rows cannot be
    /// resumed safely, so retain only checkpoints that belong to the new durable session table.
    nonisolated private func cleanupOrphanedSyncState() throws {
        try db.run("DELETE FROM sync_checkpoints WHERE session_id NOT IN (SELECT session_id FROM sync_sessions)")
        try db.run("DELETE FROM sync_staged_artists WHERE session_id NOT IN (SELECT session_id FROM sync_sessions)")
        try db.run("DELETE FROM sync_staged_albums WHERE session_id NOT IN (SELECT session_id FROM sync_sessions)")
        try db.run("DELETE FROM sync_staged_tracks WHERE session_id NOT IN (SELECT session_id FROM sync_sessions)")
    }

    // MARK: - LibrarySyncStore

    public func beginSync(serverID: ServerID, mode: LibrarySyncMode) async throws -> LibrarySyncSession {
        if let row = try db.query(
            "SELECT session_id, mode, started_at FROM sync_sessions WHERE server_id = ?",
            [.text(serverID.rawValue)]
        ).first,
           let idString = row["session_id"]?.string,
           let id = UUID(uuidString: idString),
           let storedMode = row["mode"]?.string.flatMap(LibrarySyncMode.init(rawValue:)),
           storedMode == mode {
            return LibrarySyncSession(
                id: id,
                serverID: serverID,
                mode: storedMode,
                startedAt: Date(timeIntervalSince1970: row["started_at"]?.double ?? Date().timeIntervalSince1970)
            )
        }

        let session = LibrarySyncSession(serverID: serverID, mode: mode)
        try db.transaction {
            try discardSyncState(serverID: serverID)
            try db.run(
                "INSERT INTO sync_sessions (session_id, server_id, mode, started_at) VALUES (?, ?, ?, ?)",
                [
                    .text(session.id.uuidString),
                    .text(serverID.rawValue),
                    .text(mode.rawValue),
                    .real(session.startedAt.timeIntervalSince1970),
                ]
            )
        }
        return session
    }

    public func remoteProbeState(for serverID: ServerID) -> CatalogRemoteProbeState {
        let rows = try? db.query(
            "SELECT remote_fingerprint, remote_probe_kind, last_probe_at, last_validated_at FROM sync_meta WHERE server_id = ?",
            [.text(serverID.rawValue)]
        )
        let row = rows?.first
        return CatalogRemoteProbeState(
            fingerprint: row?["remote_fingerprint"]?.string,
            kind: row?["remote_probe_kind"]?.string,
            lastProbedAt: row?["last_probe_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            lastValidatedAt: row?["last_validated_at"]?.double.map { Date(timeIntervalSince1970: $0) }
        )
    }

    public func recordRemoteProbe(
        serverID: ServerID,
        fingerprint: String?,
        kind: String,
        probedAt: Date,
        markValidated: Bool
    ) throws {
        try db.run(
            """
            INSERT INTO sync_meta
                (server_id, last_processed_count, remote_fingerprint, remote_probe_kind, last_probe_at, last_validated_at)
            VALUES (?, 0, ?, ?, ?, ?)
            ON CONFLICT(server_id) DO UPDATE SET
                remote_fingerprint = excluded.remote_fingerprint,
                remote_probe_kind = excluded.remote_probe_kind,
                last_probe_at = excluded.last_probe_at,
                last_validated_at = CASE
                    WHEN ? = 1 THEN excluded.last_validated_at
                    ELSE sync_meta.last_validated_at
                END
            """,
            [
                .text(serverID.rawValue),
                fingerprint.map(SQLiteValue.text) ?? .null,
                .text(kind),
                .real(probedAt.timeIntervalSince1970),
                markValidated ? .real(probedAt.timeIntervalSince1970) : .null,
                .integer(markValidated ? 1 : 0),
            ]
        )
    }

    public func checkpoint(session: LibrarySyncSession, section: LibrarySyncSection) async throws -> LibrarySyncCheckpoint? {
        try validateSession(session)
        let rows = try db.query(
            "SELECT * FROM sync_checkpoints WHERE session_id = ? AND section = ?",
            [.text(session.id.uuidString), .text(section.rawValue)]
        )
        guard let row = rows.first else { return nil }
        return LibrarySyncCheckpoint(
            sessionID: session.id,
            serverID: session.serverID,
            section: section,
            continuation: row["continuation"]?.string,
            sourceRevision: row["source_revision"]?.string,
            processedCount: Int(row["processed_count"]?.int ?? 0),
            completedAt: row["completed_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0)
        )
    }

    public func stageArtists(_ artists: [Artist], session: LibrarySyncSession) async throws {
        try validateSession(session)
        try db.transaction {
            for artist in artists {
                guard artist.serverID == session.serverID else {
                    throw LibrarySyncError.invalidRecordServer(
                        section: .artists,
                        recordID: artist.id.rawValue,
                        expected: session.serverID,
                        actual: artist.serverID
                    )
                }
                let gid = GlobalID(serverID: artist.serverID, remoteID: artist.id.rawValue)
                try db.run(
                    """
                    INSERT OR REPLACE INTO sync_staged_artists
                    (session_id, global_id, server_id, remote_id, name, payload, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(session.id.uuidString), .text(gid.description), .text(artist.serverID.rawValue),
                        .text(artist.id.rawValue), .text(artist.name), .text(try encode(artist)),
                        .real(Date().timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    public func stageAlbums(_ albums: [Album], session: LibrarySyncSession) async throws {
        try validateSession(session)
        try db.transaction {
            for album in albums {
                guard album.serverID == session.serverID else {
                    throw LibrarySyncError.invalidRecordServer(
                        section: .albums,
                        recordID: album.id.rawValue,
                        expected: session.serverID,
                        actual: album.serverID
                    )
                }
                let gid = GlobalID(serverID: album.serverID, remoteID: album.id.rawValue)
                try db.run(
                    """
                    INSERT OR REPLACE INTO sync_staged_albums
                    (session_id, global_id, server_id, remote_id, name, artist_name, payload, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(session.id.uuidString), .text(gid.description), .text(album.serverID.rawValue),
                        .text(album.id.rawValue), .text(album.title), .text(album.artistName),
                        .text(try encode(album)), .real(Date().timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    public func stageTracks(_ tracks: [Track], session: LibrarySyncSession) async throws {
        try validateSession(session)
        try db.transaction {
            for track in tracks {
                guard track.serverID == session.serverID else {
                    throw LibrarySyncError.invalidRecordServer(
                        section: .tracks,
                        recordID: track.id.rawValue,
                        expected: session.serverID,
                        actual: track.serverID
                    )
                }
                let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
                try db.run(
                    """
                    INSERT OR REPLACE INTO sync_staged_tracks
                    (session_id, global_id, server_id, remote_id, title, artist_name, album_title, duration, payload, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(session.id.uuidString), .text(gid.description), .text(track.serverID.rawValue),
                        .text(track.id.rawValue), .text(track.title), .text(track.artistName),
                        .text(track.albumTitle), .real(track.duration), .text(try encode(track)),
                        .real(Date().timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    public func saveCheckpoint(_ checkpoint: LibrarySyncCheckpoint, session: LibrarySyncSession) async throws {
        try validateSession(session)
        guard checkpoint.sessionID == session.id, checkpoint.serverID == session.serverID else {
            throw LibrarySyncError.sessionMismatch
        }
        try db.run(
            """
            INSERT INTO sync_checkpoints
            (session_id, server_id, section, continuation, source_revision, processed_count, completed_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, section) DO UPDATE SET
                continuation = excluded.continuation,
                source_revision = excluded.source_revision,
                processed_count = excluded.processed_count,
                completed_at = excluded.completed_at,
                updated_at = excluded.updated_at
            """,
            [
                .text(session.id.uuidString),
                .text(session.serverID.rawValue),
                .text(checkpoint.section.rawValue),
                checkpoint.continuation.map { .text($0) } ?? .null,
                checkpoint.sourceRevision.map { .text($0) } ?? .null,
                .integer(Int64(checkpoint.processedCount)),
                checkpoint.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    public func completeSync(_ session: LibrarySyncSession, completedAt: Date) async throws {
        try validateSession(session)
        let sessionID = session.id.uuidString
        let serverID = session.serverID.rawValue
        let trackCount = Int(try db.query(
            "SELECT processed_count FROM sync_checkpoints WHERE session_id = ? AND section = ?",
            [.text(sessionID), .text(LibrarySyncSection.tracks.rawValue)]
        ).first?["processed_count"]?.int ?? 0)

        try db.transaction {
            if session.mode == .full {
                try db.run("DELETE FROM artists WHERE server_id = ?", [.text(serverID)])
                try db.run("DELETE FROM albums WHERE server_id = ?", [.text(serverID)])
                try db.run("DELETE FROM tracks WHERE server_id = ?", [.text(serverID)])
            }

            try db.run(
                """
                INSERT OR REPLACE INTO artists (global_id, server_id, remote_id, name, payload, updated_at)
                SELECT global_id, server_id, remote_id, name, payload, updated_at
                FROM sync_staged_artists WHERE session_id = ?
                """,
                [.text(sessionID)]
            )
            try db.run(
                """
                INSERT OR REPLACE INTO albums
                (global_id, server_id, remote_id, name, artist_name, payload, updated_at)
                SELECT global_id, server_id, remote_id, name, artist_name, payload, updated_at
                FROM sync_staged_albums WHERE session_id = ?
                """,
                [.text(sessionID)]
            )
            try db.run(
                """
                INSERT OR REPLACE INTO tracks
                (global_id, server_id, remote_id, title, artist_name, album_title, duration, payload, updated_at)
                SELECT global_id, server_id, remote_id, title, artist_name, album_title, duration, payload, updated_at
                FROM sync_staged_tracks WHERE session_id = ?
                """,
                [.text(sessionID)]
            )

            // FTS is derived from the committed catalog. Rebuilding one server here keeps the
            // searchable view atomic with the visible catalog and removes deleted full-sync rows.
            let prefix = session.serverID.rawValue + ":%"
            try db.run("DELETE FROM catalog_fts WHERE global_id LIKE ?", [.text(prefix)])
            try db.run(
                "INSERT INTO catalog_fts (kind, global_id, text) SELECT 'artist', global_id, name FROM artists WHERE server_id = ?",
                [.text(serverID)]
            )
            try db.run(
                "INSERT INTO catalog_fts (kind, global_id, text) SELECT 'album', global_id, name || ' ' || artist_name FROM albums WHERE server_id = ?",
                [.text(serverID)]
            )
            try db.run(
                "INSERT INTO catalog_fts (kind, global_id, text) SELECT 'track', global_id, title || ' ' || artist_name || ' ' || album_title FROM tracks WHERE server_id = ?",
                [.text(serverID)]
            )

            try db.run(
                """
                INSERT INTO sync_meta (server_id, mode, last_completed_at, last_processed_count, next_retry_at)
                VALUES (?, ?, ?, ?, NULL)
                ON CONFLICT(server_id) DO UPDATE SET
                    mode = excluded.mode,
                    last_completed_at = excluded.last_completed_at,
                    last_processed_count = excluded.last_processed_count,
                    next_retry_at = NULL
                """,
                [
                    .text(serverID), .text(session.mode.rawValue),
                    .real(completedAt.timeIntervalSince1970), .integer(Int64(trackCount)),
                ]
            )
            try discardSyncState(sessionID: sessionID)
        }
    }

    public func suspendSync(_ session: LibrarySyncSession) async {
        // Session, staged pages, and checkpoints are intentionally retained. The next process
        // reopens the same SQLite database and resumes from the last durable continuation.
    }

    public func discardSync(_ session: LibrarySyncSession) async {
        try? db.transaction {
            try discardSyncState(sessionID: session.id.uuidString)
        }
    }

    private func validateSession(_ session: LibrarySyncSession) throws {
        let row = try db.query(
            "SELECT server_id, mode FROM sync_sessions WHERE session_id = ?",
            [.text(session.id.uuidString)]
        ).first
        guard let row else { throw LibrarySyncError.unknownSession(session.id) }
        guard row["server_id"]?.string == session.serverID.rawValue,
              row["mode"]?.string == session.mode.rawValue
        else { throw LibrarySyncError.sessionMismatch }
    }

    private func discardSyncState(serverID: ServerID) throws {
        let rows = try db.query(
            "SELECT session_id FROM sync_sessions WHERE server_id = ?",
            [.text(serverID.rawValue)]
        )
        for row in rows {
            if let sessionID = row["session_id"]?.string {
                try discardSyncState(sessionID: sessionID)
            }
        }
    }

    private func discardSyncState(sessionID: String) throws {
        try db.run("DELETE FROM sync_checkpoints WHERE session_id = ?", [.text(sessionID)])
        try db.run("DELETE FROM sync_staged_artists WHERE session_id = ?", [.text(sessionID)])
        try db.run("DELETE FROM sync_staged_albums WHERE session_id = ?", [.text(sessionID)])
        try db.run("DELETE FROM sync_staged_tracks WHERE session_id = ?", [.text(sessionID)])
        try db.run("DELETE FROM sync_sessions WHERE session_id = ?", [.text(sessionID)])
    }

    // MARK: - Upserts

    private func upsertArtist(_ artist: Artist, session _: LibrarySyncSession) throws {
        let gid = GlobalID(serverID: artist.serverID, remoteID: artist.id.rawValue)
        let payload = try encode(artist)
        try db.run(
            """
            INSERT INTO artists (global_id, server_id, remote_id, name, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(global_id) DO UPDATE SET
                name = excluded.name, payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(gid.description), .text(artist.serverID.rawValue), .text(artist.id.rawValue),
             .text(artist.name), .text(payload), .real(Date().timeIntervalSince1970)]
        )
        try upsertFTS(kind: "artist", globalID: gid, text: artist.name)
    }

    private func upsertAlbum(_ album: Album, session _: LibrarySyncSession) throws {
        let gid = GlobalID(serverID: album.serverID, remoteID: album.id.rawValue)
        let payload = try encode(album)
        try db.run(
            """
            INSERT INTO albums (global_id, server_id, remote_id, name, artist_name, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(global_id) DO UPDATE SET
                name = excluded.name, artist_name = excluded.artist_name,
                payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(gid.description), .text(album.serverID.rawValue), .text(album.id.rawValue),
             .text(album.title), .text(album.artistName), .text(payload), .real(Date().timeIntervalSince1970)]
        )
        try upsertFTS(kind: "album", globalID: gid, text: "\(album.title) \(album.artistName)")
    }

    private func upsertTrack(_ track: Track, session _: LibrarySyncSession) throws {
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        let payload = try encode(track)
        try db.run(
            """
            INSERT INTO tracks (global_id, server_id, remote_id, title, artist_name, album_title, duration, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(global_id) DO UPDATE SET
                title = excluded.title, artist_name = excluded.artist_name,
                album_title = excluded.album_title, duration = excluded.duration,
                payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(gid.description), .text(track.serverID.rawValue), .text(track.id.rawValue),
             .text(track.title), .text(track.artistName), .text(track.albumTitle),
             .real(track.duration), .text(payload), .real(Date().timeIntervalSince1970)]
        )
        try upsertFTS(kind: "track", globalID: gid, text: "\(track.title) \(track.artistName) \(track.albumTitle)")
    }

    func upsertFTS(kind: String, globalID: GlobalID, text: String) throws {
        try db.run("DELETE FROM catalog_fts WHERE global_id = ?", [.text(globalID.description)])
        try db.run(
            "INSERT INTO catalog_fts (kind, global_id, text) VALUES (?, ?, ?)",
            [.text(kind), .text(globalID.description), .text(text)]
        )
    }

    // MARK: - Server mirror

    public func upsertServer(_ account: ServerAccount) throws {
        let gid = GlobalID(serverID: account.id, remoteID: account.id.rawValue)
        let payload = try encode(account)
        try db.run(
            """
            INSERT INTO servers (global_id, server_id, remote_id, name, base_url, username, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(global_id) DO UPDATE SET
                name = excluded.name, base_url = excluded.base_url,
                username = excluded.username, payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(gid.description), .text(account.id.rawValue), .text(account.id.rawValue),
             .text(account.displayName),
             account.baseURL.map { .text($0.absoluteString) } ?? .null,
             account.username.map { .text($0) } ?? .null,
             .text(payload), .real(Date().timeIntervalSince1970)]
        )
    }

    // MARK: - Encode/Decode helpers

    func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalCatalogError.executeFailed("encode failed")
        }
        return string
    }

    func decode<T: Decodable>(_ type: T.Type, _ payload: String) throws -> T {
        guard let data = payload.data(using: .utf8) else {
            throw LocalCatalogError.executeFailed("decode failed")
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - FTS query

    func ftsGlobalIDs(matching query: String) throws -> (tracks: [GlobalID], albums: [GlobalID], artists: [GlobalID]) {
        let ftsQuery = Self.buildFTSQuery(query)
        guard !ftsQuery.isEmpty else { return ([], [], []) }
        let rows = try db.query("SELECT kind, global_id FROM catalog_fts WHERE catalog_fts MATCH ?", [.text(ftsQuery)])
        var tracks: [GlobalID] = []
        var albums: [GlobalID] = []
        var artists: [GlobalID] = []
        for row in rows {
            guard let kind = row["kind"]?.string, let idString = row["global_id"]?.string, let gid = GlobalID(idString) else { continue }
            switch kind {
            case "track": tracks.append(gid)
            case "album": albums.append(gid)
            case "artist": artists.append(gid)
            default: break
            }
        }
        return (tracks, albums, artists)
    }

    private static func buildFTSQuery(_ query: String) -> String {
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        // FTS5 短语内双引号必须转义（`"` → `""`），否则含引号查询（如 The "Beatles"）会触发 MATCH 语法错误。
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " OR ")
    }
}
