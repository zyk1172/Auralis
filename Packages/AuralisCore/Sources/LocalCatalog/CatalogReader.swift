import Domain
import Foundation
import MusicLibrary

extension LocalCatalogStore {
    // MARK: - Catalog queries (Agent + UI)

    public func searchTracks(query: String, serverID: ServerID? = nil) throws -> [CatalogTrackSummary] {
        let (ids, _, _) = try ftsGlobalIDs(matching: query)
        return try fetchTrackSummaries(globalIDs: ids, serverID: serverID)
    }

    public func searchAlbums(query: String, serverID: ServerID? = nil) throws -> [CatalogAlbumSummary] {
        let (_, ids, _) = try ftsGlobalIDs(matching: query)
        return try fetchAlbumSummaries(globalIDs: ids, serverID: serverID)
    }

    public func searchArtists(query: String, serverID: ServerID? = nil) throws -> [CatalogArtistSummary] {
        let (_, _, ids) = try ftsGlobalIDs(matching: query)
        return try fetchArtistSummaries(globalIDs: ids, serverID: serverID)
    }

    /// 读取指定服务器的全部完整 Track（用于资料库维护 / 诊断，可限制数量）。
    public func allTracks(serverID: ServerID?, limit: Int = 2000) throws -> [Track] {
        // 服务器过滤下沉到 SQL（tracks 表有 server_id 列）：先 LIMIT 再在内存过滤，
        // 会导致第二台服务器在首台记录数 ≥ limit 时整段被截断。
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                "SELECT global_id, payload FROM tracks WHERE server_id = ? ORDER BY rowid LIMIT ?",
                [.text(serverID.rawValue), .integer(Int64(limit))]
            )
        } else {
            rows = try db.query(
                "SELECT global_id, payload FROM tracks ORDER BY rowid LIMIT ?",
                [.integer(Int64(limit))]
            )
        }
        var result: [Track] = []
        for row in rows {
            guard let idString = row["global_id"]?.string,
                  let gid = GlobalID(idString),
                  let payload = row["payload"]?.string
            else { continue }
            if let serverID, gid.serverID != serverID { continue }
            if let track = try? decode(Track.self, payload) {
                result.append(track)
            }
        }
        return result
    }

    /// 读取指定服务器的全部完整 Album（用于资料库刷新 / 维护，可限制数量）。
    /// 与 allTracks 同风格：服务器过滤下沉到 SQL，避免多服务器在 LIMIT 时互相截断。
    public func allAlbums(serverID: ServerID?, limit: Int = 2000) throws -> [Album] {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                "SELECT global_id, payload FROM albums WHERE server_id = ? ORDER BY rowid LIMIT ?",
                [.text(serverID.rawValue), .integer(Int64(limit))]
            )
        } else {
            rows = try db.query(
                "SELECT global_id, payload FROM albums ORDER BY rowid LIMIT ?",
                [.integer(Int64(limit))]
            )
        }
        var result: [Album] = []
        for row in rows {
            guard let idString = row["global_id"]?.string,
                  let gid = GlobalID(idString),
                  let payload = row["payload"]?.string
            else { continue }
            if let serverID, gid.serverID != serverID { continue }
            if let album = try? decode(Album.self, payload) {
                result.append(album)
            }
        }
        return result
    }

    /// 读取指定服务器的全部完整 Artist（用于资料库刷新 / 维护，可限制数量）。
    /// 与 allTracks 同风格：服务器过滤下沉到 SQL，避免多服务器在 LIMIT 时互相截断。
    public func allArtists(serverID: ServerID?, limit: Int = 2000) throws -> [Artist] {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                "SELECT global_id, payload FROM artists WHERE server_id = ? ORDER BY rowid LIMIT ?",
                [.text(serverID.rawValue), .integer(Int64(limit))]
            )
        } else {
            rows = try db.query(
                "SELECT global_id, payload FROM artists ORDER BY rowid LIMIT ?",
                [.integer(Int64(limit))]
            )
        }
        var result: [Artist] = []
        for row in rows {
            guard let idString = row["global_id"]?.string,
                  let gid = GlobalID(idString),
                  let payload = row["payload"]?.string
            else { continue }
            if let serverID, gid.serverID != serverID { continue }
            if let artist = try? decode(Artist.self, payload) {
                result.append(artist)
            }
        }
        return result
    }

    public func getTrack(_ globalID: GlobalID) throws -> Track? {
        guard let payload = try trackPayload(globalID) else { return nil }
        return try decode(Track.self, payload)
    }

    public func getAlbum(_ globalID: GlobalID) throws -> Album? {
        guard let payload = try albumPayload(globalID) else { return nil }
        return try decode(Album.self, payload)
    }

    public func getArtist(_ globalID: GlobalID) throws -> Artist? {
        guard let payload = try artistPayload(globalID) else { return nil }
        return try decode(Artist.self, payload)
    }

    public func getFavorites(serverID: ServerID? = nil) throws -> [CatalogTrackSummary] {
        let ids = try favoriteTrackIDs()
        return try fetchTrackSummaries(globalIDs: ids, serverID: serverID)
    }

    public func getRecentHistory(serverID: ServerID? = nil, limit: Int = 50) throws -> [CatalogTrackSummary] {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                "SELECT global_id FROM play_history WHERE global_id LIKE ? ORDER BY last_played DESC LIMIT ?",
                [.text(serverID.rawValue + ":%"), .integer(Int64(limit))]
            )
        } else {
            rows = try db.query(
                "SELECT global_id FROM play_history ORDER BY last_played DESC LIMIT ?",
                [.integer(Int64(limit))]
            )
        }
        var result: [CatalogTrackSummary] = []
        for row in rows {
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString),
                  let summary = try trackSummary(gid), serverIDMatches(summary, serverID) else { continue }
            result.append(summary)
        }
        return result
    }

    public func getLeastPlayed(serverID: ServerID? = nil, limit: Int = 50) throws -> [CatalogTrackSummary] {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                "SELECT global_id FROM play_history WHERE global_id LIKE ? ORDER BY play_count ASC, last_played ASC LIMIT ?",
                [.text(serverID.rawValue + ":%"), .integer(Int64(limit))]
            )
        } else {
            rows = try db.query(
                "SELECT global_id FROM play_history ORDER BY play_count ASC, last_played ASC LIMIT ?",
                [.integer(Int64(limit))]
            )
        }
        var result: [CatalogTrackSummary] = []
        for row in rows {
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString),
                  let summary = try trackSummary(gid), serverIDMatches(summary, serverID) else { continue }
            result.append(summary)
        }
        return result
    }

    public func getDownloadedTracks(serverID: ServerID? = nil) throws -> [CatalogTrackSummary] {
        let rows = try db.query("SELECT global_id FROM downloads WHERE state = ?", [.text(DownloadStateValue.cached.rawValue)])
        var result: [CatalogTrackSummary] = []
        for row in rows {
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString),
                  let summary = try trackSummary(gid), serverIDMatches(summary, serverID) else { continue }
            result.append(summary)
        }
        return result
    }

    public func getSimilarTracks(_ globalID: GlobalID, limit: Int = 20) throws -> [CatalogTrackSummary] {
        guard let base = try getTrack(globalID) else { return [] }
        let rows = try db.query(
            "SELECT global_id FROM tracks WHERE server_id = ? AND global_id != ? AND (artist_name = ? OR album_title = ?) LIMIT ?",
            [.text(base.serverID.rawValue), .text(globalID.description), .text(base.artistName), .text(base.albumTitle), .integer(Int64(limit))]
        )
        return try rows.compactMap { row -> CatalogTrackSummary? in
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString) else { return nil }
            return try trackSummary(gid)
        }
    }

    public func listPlaylists(serverID: ServerID? = nil) throws -> [CatalogPlaylistSummary] {
        let rows = try db.query("SELECT global_id, name, is_readonly, payload FROM playlists")
        return try rows.compactMap { row -> CatalogPlaylistSummary? in
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString),
                  let name = row["name"]?.string else { return nil }
            if let serverID, gid.serverID != serverID { return nil }
            let trackIDs = try playlistTrackIDs(gid)
            let isReadOnly = (row["is_readonly"]?.int ?? 0) == 1
            return CatalogPlaylistSummary(globalID: gid, name: name, trackIDs: trackIDs, isReadOnly: isReadOnly)
        }
    }

    public func getPlaylist(_ globalID: GlobalID) throws -> (playlist: Playlist, tracks: [Track])? {
        guard let payload = try playlistPayload(globalID),
              let playlist = try? decode(Playlist.self, payload) else { return nil }
        let trackIDs = try playlistTrackIDs(globalID)
        let tracks = try trackIDs.compactMap { try getTrack($0) }
        return (playlist, tracks)
    }

    public func listServers() throws -> [ServerAccount] {
        let rows = try db.query("SELECT payload FROM servers")
        return rows.compactMap { row -> ServerAccount? in
            guard let payload = row["payload"]?.string else { return nil }
            return try? decode(ServerAccount.self, payload)
        }
    }

    public func server(localID: ServerID) throws -> ServerAccount? {
        try listServers().first { $0.id == localID }
    }

    public func allTrackSummaries(serverID: ServerID? = nil) throws -> [CatalogTrackSummary] {
        var sql = "SELECT global_id FROM tracks"
        var bindings: [SQLiteValue] = []
        if let serverID {
            sql += " WHERE server_id = ?"
            bindings = [.text(serverID.rawValue)]
        }
        let rows = try db.query(sql, bindings)
        return try rows.compactMap { row -> CatalogTrackSummary? in
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString) else { return nil }
            return try trackSummary(gid)
        }
    }

    public func tracksForAlbum(_ albumGID: GlobalID) throws -> [CatalogTrackSummary] {
        let rows = try db.query(
            "SELECT global_id FROM tracks WHERE album_title = (SELECT name FROM albums WHERE global_id = ?) AND server_id = ?",
            [.text(albumGID.description), .text(albumGID.serverID.rawValue)]
        )
        return try rows.compactMap { row -> CatalogTrackSummary? in
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString) else { return nil }
            return try trackSummary(gid)
        }
    }

    public func tracksForArtist(_ artistGID: GlobalID) throws -> [CatalogTrackSummary] {
        let rows = try db.query(
            "SELECT global_id FROM tracks WHERE artist_name = (SELECT name FROM artists WHERE global_id = ?) AND server_id = ?",
            [.text(artistGID.description), .text(artistGID.serverID.rawValue)]
        )
        return try rows.compactMap { row -> CatalogTrackSummary? in
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString) else { return nil }
            return try trackSummary(gid)
        }
    }

    public func syncStatus(for serverID: ServerID, isRunning: Bool = false, nextRetryAt: Date? = nil, staleAfter: TimeInterval = 60 * 60 * 24 * 7) -> CatalogSyncStatus {
        let rows = try? db.query("SELECT * FROM sync_meta WHERE server_id = ?", [.text(serverID.rawValue)])
        guard let row = rows?.first else {
            return CatalogSyncStatus(serverID: serverID, isRunning: isRunning, nextRetryAt: nextRetryAt)
        }
        let lastCompleted = row["last_completed_at"]?.double.map { Date(timeIntervalSince1970: $0) }
        let isStale = lastCompleted.map { Date().timeIntervalSince($0) > staleAfter } ?? true
        return CatalogSyncStatus(
            serverID: serverID,
            mode: row["mode"]?.string.flatMap { LibrarySyncMode(rawValue: $0) },
            isRunning: isRunning,
            isStale: isStale,
            lastCompletedAt: lastCompleted,
            lastProcessedCount: Int(row["last_processed_count"]?.int ?? 0),
            nextRetryAt: nextRetryAt
        )
    }

    // MARK: - Annotations

    public func setFavorite(_ globalID: GlobalID, value: Bool) throws {
        if value {
            try db.run(
                "INSERT INTO favorites (global_id, kind, value, updated_at) VALUES (?, 'track', 1, ?) ON CONFLICT(global_id) DO UPDATE SET value = 1, updated_at = excluded.updated_at",
                [.text(globalID.description), .real(Date().timeIntervalSince1970)]
            )
        } else {
            try db.run("DELETE FROM favorites WHERE global_id = ?", [.text(globalID.description)])
        }
    }

    /// 读取指定服务器的全部本地评分（GlobalID → 0-5），供冷启动回填。
    public func ratings(serverID: ServerID) throws -> [GlobalID: Int] {
        let prefix = serverID.rawValue + ":"
        let rows = try db.query("SELECT global_id, value FROM ratings")
        var result: [GlobalID: Int] = [:]
        for row in rows {
            guard let idString = row["global_id"]?.string, idString.hasPrefix(prefix),
                  let gid = GlobalID(idString) else { continue }
            result[gid] = Int(row["value"]?.int ?? 0)
        }
        return result
    }

    public func setRating(_ globalID: GlobalID, rating: Int) throws {
        try db.run(
            "INSERT INTO ratings (global_id, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(global_id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            [.text(globalID.description), .integer(Int64(rating)), .real(Date().timeIntervalSince1970)]
        )
    }

    public func clearRating(_ globalID: GlobalID) throws {
        try db.run("DELETE FROM ratings WHERE global_id = ?", [.text(globalID.description)])
    }

    public func recordPlay(_ globalID: GlobalID, completed: Bool) throws {
        let existing = try db.query("SELECT * FROM play_history WHERE global_id = ?", [.text(globalID.description)])
        if let row = existing.first {
            let count = Int(row["play_count"]?.int ?? 0) + 1
            let done = (row["completed"]?.int ?? 0) + (completed ? 1 : 0)
            try db.run(
                "UPDATE play_history SET last_played = ?, play_count = ?, completed = ? WHERE global_id = ?",
                [.real(Date().timeIntervalSince1970), .integer(Int64(count)), .integer(Int64(done)), .text(globalID.description)]
            )
        } else {
            try db.run(
                "INSERT INTO play_history (global_id, last_played, play_count, completed) VALUES (?, ?, 1, ?)",
                [.text(globalID.description), .real(Date().timeIntervalSince1970), .integer(completed ? 1 : 0)]
            )
        }
    }

    public func setDownloadState(_ globalID: GlobalID, state: DownloadStateValue, localPath: String? = nil) throws {
        try db.run(
            "INSERT INTO downloads (global_id, state, local_path, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(global_id) DO UPDATE SET state = excluded.state, local_path = excluded.local_path, updated_at = excluded.updated_at",
            [.text(globalID.description), .text(state.rawValue), localPath.map { .text($0) } ?? .null, .real(Date().timeIntervalSince1970)]
        )
    }

    public func setLyrics(_ globalID: GlobalID, _ lyrics: LyricsDocument) throws {
        let payload = try encode(lyrics)
        try db.run(
            "INSERT INTO lyrics (global_id, payload) VALUES (?, ?) ON CONFLICT(global_id) DO UPDATE SET payload = excluded.payload",
            [.text(globalID.description), .text(payload)]
        )
    }

    public func getLyrics(_ globalID: GlobalID) throws -> LyricsDocument? {
        guard let payload = try db.query("SELECT payload FROM lyrics WHERE global_id = ?", [.text(globalID.description)]).first?["payload"]?.string else { return nil }
        return try? decode(LyricsDocument.self, payload)
    }

    // MARK: - Playlists

    public func upsertPlaylist(_ playlist: Playlist, serverID: ServerID, isReadOnly: Bool = false) throws {
        let gid = GlobalID(serverID: serverID, remoteID: playlist.id.rawValue)
        let payload = try encode(playlist)
        try db.run(
            """
            INSERT INTO playlists (global_id, server_id, remote_id, name, is_readonly, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(global_id) DO UPDATE SET name = excluded.name, is_readonly = excluded.is_readonly, payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(gid.description), .text(serverID.rawValue), .text(playlist.id.rawValue),
             .text(playlist.name), .integer(isReadOnly ? 1 : 0), .text(payload), .real(Date().timeIntervalSince1970)]
        )
        try db.run("DELETE FROM playlist_tracks WHERE playlist_gid = ?", [.text(gid.description)])
        for (index, trackID) in playlist.trackIDs.enumerated() {
            let trackGID = GlobalID(serverID: serverID, remoteID: trackID.rawValue)
            try db.run(
                "INSERT INTO playlist_tracks (playlist_gid, position, track_gid) VALUES (?, ?, ?)",
                [.text(gid.description), .integer(Int64(index)), .text(trackGID.description)]
            )
        }
    }

    public func setPlaylistTracks(_ playlistGID: GlobalID, trackGIDs: [GlobalID]) throws {
        try db.run("DELETE FROM playlist_tracks WHERE playlist_gid = ?", [.text(playlistGID.description)])
        for (index, trackGID) in trackGIDs.enumerated() {
            try db.run(
                "INSERT INTO playlist_tracks (playlist_gid, position, track_gid) VALUES (?, ?, ?)",
                [.text(playlistGID.description), .integer(Int64(index)), .text(trackGID.description)]
            )
        }
    }

    /// 删除单个本地歌单（连同其曲目关系），不触碰服务器数据。
    public func deletePlaylist(_ globalID: GlobalID) throws {
        try db.run("DELETE FROM playlist_tracks WHERE playlist_gid = ?", [.text(globalID.description)])
        try db.run("DELETE FROM playlists WHERE global_id = ?", [.text(globalID.description)])
    }

    // MARK: - Server cleanup

    /// 删除服务器后的本地清理：移除该服务器的全部记录与标注，不影响远程数据。
    public func purgeServer(_ serverID: ServerID) throws {
        let prefix = "\(serverID.rawValue):"
        try db.transaction {
            try db.run("DELETE FROM artists WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM albums WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM tracks WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM genres WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM playlists WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM playlist_tracks WHERE playlist_gid LIKE ?", [.text(prefix + "%")])
            try db.run("DELETE FROM servers WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM sync_meta WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM sync_checkpoints WHERE server_id = ?", [.text(serverID.rawValue)])
            try db.run("DELETE FROM catalog_fts WHERE global_id LIKE ?", [.text(prefix + "%")])
            try db.run("DELETE FROM favorites WHERE global_id LIKE ?", [.text(prefix + "%")])
            try db.run("DELETE FROM ratings WHERE global_id LIKE ?", [.text(prefix + "%")])
            try db.run("DELETE FROM play_history WHERE global_id LIKE ?", [.text(prefix + "%")])
            try db.run("DELETE FROM downloads WHERE global_id LIKE ?", [.text(prefix + "%")])
            try db.run("DELETE FROM lyrics WHERE global_id LIKE ?", [.text(prefix + "%")])
        }
    }

    // MARK: - Private fetch helpers

    private func serverIDMatches(_ summary: CatalogTrackSummary, _ serverID: ServerID?) -> Bool {
        guard let serverID else { return true }
        return summary.globalID.serverID == serverID
    }

    private func trackSummary(_ gid: GlobalID) throws -> CatalogTrackSummary? {
        guard let payload = try trackPayload(gid),
              let track = try? decode(Track.self, payload) else { return nil }
        let isFavorite = try isFavorite(gid)
        let rating = Int(try db.query("SELECT value FROM ratings WHERE global_id = ?", [.text(gid.description)]).first?["value"]?.int ?? 0)
        let downloaded = try downloadState(gid) == .cached
        return CatalogTrackSummary(
            globalID: gid,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration,
            isFavorite: isFavorite,
            userRating: rating,
            isDownloaded: downloaded
        )
    }

    private func fetchTrackSummaries(globalIDs: [GlobalID], serverID: ServerID? = nil) throws -> [CatalogTrackSummary] {
        try globalIDs.compactMap { gid -> CatalogTrackSummary? in
            guard let summary = try trackSummary(gid), serverIDMatches(summary, serverID) else { return nil }
            return summary
        }
    }

    private func fetchAlbumSummaries(globalIDs: [GlobalID], serverID: ServerID? = nil) throws -> [CatalogAlbumSummary] {
        try globalIDs.compactMap { gid -> CatalogAlbumSummary? in
            guard let payload = try albumPayload(gid),
                  let album = try? decode(Album.self, payload) else { return nil }
            if let serverID, gid.serverID != serverID { return nil }
            let songCount = try db.query("SELECT global_id FROM tracks WHERE album_title = ? AND server_id = ?",
                                         [.text(album.title), .text(gid.serverID.rawValue)]).count
            return CatalogAlbumSummary(globalID: gid, title: album.title, artistName: album.artistName, songCount: songCount)
        }
    }

    private func fetchArtistSummaries(globalIDs: [GlobalID], serverID: ServerID? = nil) throws -> [CatalogArtistSummary] {
        try globalIDs.compactMap { gid -> CatalogArtistSummary? in
            guard let payload = try artistPayload(gid),
                  let artist = try? decode(Artist.self, payload) else { return nil }
            if let serverID, gid.serverID != serverID { return nil }
            let albumCount = try db.query("SELECT global_id FROM albums WHERE artist_name = ? AND server_id = ?",
                                          [.text(artist.name), .text(gid.serverID.rawValue)]).count
            return CatalogArtistSummary(globalID: gid, name: artist.name, albumCount: albumCount)
        }
    }

    private func isFavorite(_ gid: GlobalID) throws -> Bool {
        (try? db.query("SELECT value FROM favorites WHERE global_id = ?", [.text(gid.description)]).first?["value"]?.int) == 1
    }

    private func downloadState(_ gid: GlobalID) throws -> DownloadStateValue {
        guard let raw = try? db.query("SELECT state FROM downloads WHERE global_id = ?", [.text(gid.description)]).first?["state"]?.string,
              let state = DownloadStateValue(rawValue: raw) else { return .none }
        return state
    }

    private func trackPayload(_ gid: GlobalID) throws -> String? {
        try db.query("SELECT payload FROM tracks WHERE global_id = ?", [.text(gid.description)]).first?["payload"]?.string
    }

    private func albumPayload(_ gid: GlobalID) throws -> String? {
        try db.query("SELECT payload FROM albums WHERE global_id = ?", [.text(gid.description)]).first?["payload"]?.string
    }

    private func artistPayload(_ gid: GlobalID) throws -> String? {
        try db.query("SELECT payload FROM artists WHERE global_id = ?", [.text(gid.description)]).first?["payload"]?.string
    }

    private func playlistPayload(_ gid: GlobalID) throws -> String? {
        try db.query("SELECT payload FROM playlists WHERE global_id = ?", [.text(gid.description)]).first?["payload"]?.string
    }

    private func playlistTrackIDs(_ gid: GlobalID) throws -> [GlobalID] {
        let rows = try db.query(
            "SELECT track_gid FROM playlist_tracks WHERE playlist_gid = ? ORDER BY position ASC",
            [.text(gid.description)]
        )
        return rows.compactMap { row -> GlobalID? in
            guard let idString = row["track_gid"]?.string else { return nil }
            return GlobalID(idString)
        }
    }

    private func favoriteTrackIDs() throws -> [GlobalID] {
        let rows = try db.query("SELECT global_id FROM favorites WHERE kind = 'track' AND value = 1")
        return rows.compactMap { row -> GlobalID? in
            guard let idString = row["global_id"]?.string else { return nil }
            return GlobalID(idString)
        }
    }

    /// 热度代理：本地播放次数 + 最近播放时间（来自 play_history）。
    /// 私人音乐库没有互联网流行度，用「播放次数 / 收藏 / 评分 / 最近播放」作为候选排序依据。
    public func popularityScores(serverID: ServerID? = nil) throws -> [GlobalID: TrackPopularity] {
        let rows = try db.query("SELECT global_id, last_played, play_count FROM play_history")
        var result: [GlobalID: TrackPopularity] = [:]
        for row in rows {
            guard let idString = row["global_id"]?.string, let gid = GlobalID(idString) else { continue }
            if let serverID, gid.serverID != serverID { continue }
            let count = Int(row["play_count"]?.int ?? 0)
            var lastPlayedAt: Date?
            if let raw = row["last_played"]?.double, raw > 0 {
                lastPlayedAt = Date(timeIntervalSince1970: raw)
            }
            result[gid] = TrackPopularity(globalID: gid, playCount: count, lastPlayedAt: lastPlayedAt)
        }
        return result
    }

    // MARK: - 曲库分类索引（Agent 按需读取）

    /// 生成曲库索引：歌手 / 专辑 / 流派 / 语言 / 年代 / 收藏 / 最近播放 / 热门。
    /// 只含元数据（不含歌词、海报、流地址）。
    public func makeCatalogIndex(serverID: ServerID? = nil) throws -> CatalogIndex {
        let tracks = try allTracks(serverID: serverID, limit: 20000)
        let popularity = try popularityScores(serverID: serverID)
        let favoriteIDs = Set(try favoriteTrackIDs().filter { serverID == nil || $0.serverID == serverID })
        let recent = (try getRecentHistory(serverID: serverID, limit: 200)).map(\.globalID)
        let downloaded = Set(try getDownloadedTracks(serverID: serverID).map(\.globalID))

        func line(_ track: Track) -> CatalogTrackLine {
            let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            return CatalogTrackLine(
                id: gid.description,
                title: track.title,
                artist: track.artistName,
                album: track.albumTitle,
                year: track.year,
                genres: track.genres,
                language: track.language,
                duration: Int(track.duration),
                isFavorite: track.isFavorite || favoriteIDs.contains(gid),
                rating: track.rating,
                playCount: popularity[gid]?.playCount ?? 0,
                isDownloaded: downloaded.contains(gid)
            )
        }

        func normalized(_ name: String) -> String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased().split(whereSeparator: { $0.isWhitespace }).joined()
        }

        // 歌手 / 专辑 / 流派 / 语言 / 年代 聚合
        var artistAgg: [String: (name: String, albums: Set<String>, songs: Int)] = [:]
        var albumAgg: [String: (title: String, artist: String, year: Int?, songs: Int)] = [:]
        var genreAgg: [String: Int] = [:]
        var langAgg: [String: Int] = [:]
        var yearAgg: [Int: Int] = [:]
        for track in tracks {
            let aKey = normalized(track.artistName)
            let albumKey = "\(aKey)|\(normalized(track.albumTitle))"
            if artistAgg[aKey] == nil {
                artistAgg[aKey] = (name: track.artistName, albums: [], songs: 0)
            }
            artistAgg[aKey]!.albums.insert(albumKey)
            artistAgg[aKey]!.songs += 1

            if albumAgg[albumKey] == nil {
                albumAgg[albumKey] = (title: track.albumTitle, artist: track.artistName, year: track.year, songs: 0)
            }
            albumAgg[albumKey]!.songs += 1

            for genre in track.genres where !genre.trimmingCharacters(in: .whitespaces).isEmpty {
                genreAgg[genre, default: 0] += 1
            }
            if let language = track.language, !language.isEmpty {
                langAgg[language, default: 0] += 1
            }
            if let year = track.year {
                yearAgg[year, default: 0] += 1
            }
        }

        var artistEntries: [CatalogArtistIndexEntry] = []
        for entry in artistAgg.values {
            artistEntries.append(CatalogArtistIndexEntry(name: entry.name, albumCount: entry.albums.count, songCount: entry.songs))
        }
        let artists = artistEntries.sorted { a, b in
            a.songCount == b.songCount ? a.name < b.name : a.songCount > b.songCount
        }

        var albumEntries: [CatalogAlbumIndexEntry] = []
        for entry in albumAgg.values {
            albumEntries.append(CatalogAlbumIndexEntry(title: entry.title, artist: entry.artist, year: entry.year, songCount: entry.songs))
        }
        let albums = albumEntries.sorted { a, b in
            let ay = a.year ?? 9999
            let by = b.year ?? 9999
            return ay == by ? a.title < b.title : ay < by
        }

        var genreEntries: [CatalogGenreIndexEntry] = []
        for (name, count) in genreAgg {
            genreEntries.append(CatalogGenreIndexEntry(name: name, songCount: count))
        }
        let genres = genreEntries.sorted { a, b in
            a.songCount == b.songCount ? a.name < b.name : a.songCount > b.songCount
        }

        var languageEntries: [CatalogLanguageIndexEntry] = []
        for (language, count) in langAgg {
            languageEntries.append(CatalogLanguageIndexEntry(language: language, songCount: count))
        }
        let languages = languageEntries.sorted { a, b in
            a.songCount == b.songCount ? a.language < b.language : a.songCount > b.songCount
        }

        var yearEntries: [CatalogYearIndexEntry] = []
        for (year, count) in yearAgg {
            yearEntries.append(CatalogYearIndexEntry(year: year, songCount: count))
        }
        let years = yearEntries.sorted { $0.year < $1.year }

        let byID = Dictionary(uniqueKeysWithValues: tracks.map { (GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue).description, $0) })
        let recentLines = recent.compactMap { gid -> CatalogTrackLine? in byID[gid.description].map(line) }
        let favoritesLines = tracks.filter { $0.isFavorite || favoriteIDs.contains(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)) }
            .sorted { $0.title < $1.title }.prefix(500).map(line)

        let recentRank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
        let popularLines = tracks
            .sorted { lhs, rhs in
                let lg = GlobalID(serverID: lhs.serverID, remoteID: lhs.id.rawValue)
                let rg = GlobalID(serverID: rhs.serverID, remoteID: rhs.id.rawValue)
                func score(_ t: Track, _ gid: GlobalID) -> Int {
                    let recency = recentRank[gid].map { max(0, 20 - $0 / 20) } ?? 0
                    return (popularity[gid]?.playCount ?? 0) * 3
                        + ((t.isFavorite || favoriteIDs.contains(gid)) ? 2 : 0)
                        + (t.rating ?? 0) / 2 + recency
                }
                return score(lhs, lg) > score(rhs, rg)
            }
            .prefix(500)
            .map(line)

        return CatalogIndex(
            serverID: serverID?.rawValue,
            generatedAt: .now,
            songCount: tracks.count,
            artistCount: artists.count,
            albumCount: albums.count,
            artists: Array(artists.prefix(1000)),
            albums: Array(albums.prefix(1000)),
            genres: Array(genres.prefix(500)),
            languages: Array(languages.prefix(200)),
            years: Array(years.prefix(200)),
            favorites: favoritesLines,
            recent: recentLines,
            popular: popularLines
        )
    }

    /// 按分类取歌曲清单（供 Agent 按需注入对话）。
    /// category: artist / album / genre / language / year / favorites / recent / popular / all
    public func catalogTracks(
        serverID: ServerID? = nil,
        category: String,
        value: String? = nil,
        limit: Int = 100
    ) throws -> [CatalogTrackLine] {
        let safeLimit = min(max(limit, 1), 500)
        let tracks = try allTracks(serverID: serverID, limit: 20000)
        let popularity = try popularityScores(serverID: serverID)
        let favoriteIDs = Set(try favoriteTrackIDs().filter { serverID == nil || $0.serverID == serverID })
        let recent = (try getRecentHistory(serverID: serverID, limit: 300)).map(\.globalID)
        let downloaded = Set(try getDownloadedTracks(serverID: serverID).map(\.globalID))

        func line(_ track: Track) -> CatalogTrackLine {
            let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            return CatalogTrackLine(
                id: gid.description, title: track.title, artist: track.artistName, album: track.albumTitle,
                year: track.year, genres: track.genres, language: track.language,
                duration: Int(track.duration),
                isFavorite: track.isFavorite || favoriteIDs.contains(gid),
                rating: track.rating,
                playCount: popularity[gid]?.playCount ?? 0,
                isDownloaded: downloaded.contains(gid)
            )
        }

        let normalized = { (s: String) -> String in
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased().split(whereSeparator: { $0.isWhitespace }).joined()
        }
        let needle = value.map(normalized) ?? ""

        var matched: [Track]
        switch category.lowercased() {
        case "artist":
            matched = tracks.filter { needle.isEmpty || normalized($0.artistName).contains(needle) }
        case "album":
            matched = tracks.filter { needle.isEmpty || normalized($0.albumTitle).contains(needle) }
        case "genre":
            matched = tracks.filter { needle.isEmpty || $0.genres.contains { normalized($0).contains(needle) || needle.contains(normalized($0)) } }
        case "language":
            matched = tracks.filter { needle.isEmpty || ($0.language.map { normalized($0).contains(needle) || needle.contains(normalized($0)) } ?? false) }
        case "year":
            let year = value.flatMap(Int.init)
            matched = tracks.filter { $0.year == year }
        case "favorites":
            matched = tracks.filter { $0.isFavorite || favoriteIDs.contains(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)) }
        case "recent":
            let byID = Dictionary(uniqueKeysWithValues: tracks.map { (GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue), $0) })
            return recent.compactMap { byID[$0].map(line) }.prefix(safeLimit).map { $0 }
        case "popular":
            let recentRank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
            matched = tracks.sorted { lhs, rhs in
                let lg = GlobalID(serverID: lhs.serverID, remoteID: lhs.id.rawValue)
                let rg = GlobalID(serverID: rhs.serverID, remoteID: rhs.id.rawValue)
                func score(_ t: Track, _ gid: GlobalID) -> Int {
                    (popularity[gid]?.playCount ?? 0) * 3
                        + ((t.isFavorite || favoriteIDs.contains(gid)) ? 2 : 0)
                        + (t.rating ?? 0) / 2 + (recentRank[gid].map { max(0, 20 - $0 / 20) } ?? 0)
                }
                return score(lhs, lg) > score(rhs, rg)
            }
        default: // all
            matched = tracks
        }

        return matched.prefix(safeLimit).map(line)
    }
}
