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
        CREATE TABLE IF NOT EXISTS sync_meta (
            server_id TEXT PRIMARY KEY,
            mode TEXT,
            last_completed_at REAL,
            last_processed_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at REAL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(kind UNINDEXED, global_id UNINDEXED, text);
        CREATE INDEX IF NOT EXISTS idx_tracks_server ON tracks(server_id);
        CREATE INDEX IF NOT EXISTS idx_albums_server ON albums(server_id);
        CREATE INDEX IF NOT EXISTS idx_artists_server ON artists(server_id);
        CREATE INDEX IF NOT EXISTS idx_playlists_server ON playlists(server_id);
        """)
    }

    // MARK: - LibrarySyncStore

    public func beginSync(serverID: ServerID, mode: LibrarySyncMode) async throws -> LibrarySyncSession {
        if mode == .full {
            // 全量同步前清空该服务器已有的艺人与专辑（曲目在 staging 时按页覆盖）。
            try db.run("DELETE FROM artists WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM albums WHERE server_id = ?", [.text(serverID.rawValue)])
        }
        return LibrarySyncSession(serverID: serverID, mode: mode)
    }

    public func checkpoint(session: LibrarySyncSession, section: LibrarySyncSection) async throws -> LibrarySyncCheckpoint? {
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
        try db.transaction {
            for artist in artists {
                try upsertArtist(artist, session: session)
            }
        }
    }

    public func stageAlbums(_ albums: [Album], session: LibrarySyncSession) async throws {
        try db.transaction {
            for album in albums {
                try upsertAlbum(album, session: session)
            }
        }
    }

    public func stageTracks(_ tracks: [Track], session: LibrarySyncSession) async throws {
        try db.transaction {
            for track in tracks {
                try upsertTrack(track, session: session)
            }
        }
    }

    public func saveCheckpoint(_ checkpoint: LibrarySyncCheckpoint, session: LibrarySyncSession) async throws {
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
                .text(session.serverID.rawValue),
                .text(session.mode.rawValue),
                .real(completedAt.timeIntervalSince1970),
                .integer(0),
            ]
        )
    }

    public func suspendSync(_ session: LibrarySyncSession) async {
        // 暂停的同步保留已写入数据，元数据保留为未完成（stale 由 UI 依据时间判断）。
    }

    public func discardSync(_ session: LibrarySyncSession) async {
        try? db.run("DELETE FROM sync_checkpoints WHERE session_id = ?", [.text(session.id.uuidString)])
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
