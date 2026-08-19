@testable import LocalCatalog
import Domain
import Foundation
import Testing

/// R03：catalog_entity_relations 迁移 v1→v2 升级回归。
///
/// v1（第二轮 7e3e06b6）用「名称猜测」回填 gid 并把 migration version 写成 1；
/// v2 必须对**已经运行过 v1 的老库**执行 payload authoritative repair——
/// payload decode 成功就用真实 albumID/artistID 强制覆盖（含 v1 填错的非 NULL 值）。
/// 本测试构造一个 v1 状态库（version=1 + 两个同名专辑被错误绑定），
/// 打开新版 LocalCatalogStore 后断言 version=2 且 gid 被真实 ID 修正。
struct EntityRelationMigrationV2Tests {
    private let serverID = ServerID(rawValue: "srv")

    private func makeV1Catalog() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityRelationMigrationV2.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("catalog.sqlite")
        let db = try SQLiteDatabase(url: url)
        // 与正式 schema 兼容的 v1 表（v1 迁移后已含 album_gid/artist_gid 列）。
        try db.exec("""
        CREATE TABLE tracks (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            title TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            album_title TEXT NOT NULL,
            album_gid TEXT,
            artist_gid TEXT,
            duration REAL NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE albums (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            artist_name TEXT NOT NULL,
            artist_gid TEXT,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE artists (
            global_id TEXT PRIMARY KEY,
            server_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE catalog_migrations (
            key TEXT PRIMARY KEY,
            version INTEGER NOT NULL,
            applied_at REAL NOT NULL
        );
        """)
        return url
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// 构造 v1 库：两个同名专辑 + 一条被 v1 名称猜测错误绑定的 track。
    /// track 的 payload 真实 albumID 指向 album-real-2，但 album_gid 被错误填成
    /// album-real-1（v1「名称 + 艺术家名 LIMIT 1」可能选到前者）。
    private func seedV1Catalog(at url: URL) throws {
        let db = try SQLiteDatabase(url: url)
        let gid1 = GlobalID(serverID: serverID, remoteID: "album-real-1").description
        let gid2 = GlobalID(serverID: serverID, remoteID: "album-real-2").description
        let now = Date().timeIntervalSince1970

        // 两个同名专辑（同艺术家同名），真实 ID 不同。
        let album1 = Album(
            id: AlbumID(rawValue: "album-real-1"),
            serverID: serverID,
            artistID: ArtistID(rawValue: "artist-real"),
            title: "Same Album",
            artistName: "Artist",
            year: nil,
            genre: nil,
            artworkKey: nil,
            songCount: nil
        )
        let album2 = Album(
            id: AlbumID(rawValue: "album-real-2"),
            serverID: serverID,
            artistID: ArtistID(rawValue: "artist-real"),
            title: "Same Album",
            artistName: "Artist",
            year: nil,
            genre: nil,
            artworkKey: nil,
            songCount: nil
        )
        try db.run(
            "INSERT INTO albums (global_id, server_id, remote_id, name, artist_name, artist_gid, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(gid1), .text(serverID.rawValue), .text("album-real-1"), .text("Same Album"), .text("Artist"),
             .text(GlobalID(serverID: serverID, remoteID: "artist-real").description),
             .text(try encode(album1)), .real(now)]
        )
        try db.run(
            "INSERT INTO albums (global_id, server_id, remote_id, name, artist_name, artist_gid, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(gid2), .text(serverID.rawValue), .text("album-real-2"), .text("Same Album"), .text("Artist"),
             .text(GlobalID(serverID: serverID, remoteID: "artist-real").description),
             .text(try encode(album2)), .real(now)]
        )

        // track 的真实 albumID 是 album-real-2；v1 名称猜测错误填成 gid1。
        let track = Track(
            id: TrackID(rawValue: "track-1"),
            serverID: serverID,
            albumID: AlbumID(rawValue: "album-real-2"),
            artistID: ArtistID(rawValue: "artist-real"),
            title: "Track One",
            artistName: "Artist",
            albumTitle: "Same Album",
            duration: 210
        )
        try db.run(
            "INSERT INTO tracks (global_id, server_id, remote_id, title, artist_name, album_title, album_gid, artist_gid, duration, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(GlobalID(serverID: serverID, remoteID: "track-1").description),
             .text(serverID.rawValue), .text("track-1"), .text("Track One"), .text("Artist"),
             .text("Same Album"), .text(gid1), .text(GlobalID(serverID: serverID, remoteID: "artist-real").description),
             .real(210), .text(try encode(track)), .real(now)]
        )

        // 模拟第二轮已应用的 v1 迁移。
        try db.run(
            "INSERT INTO catalog_migrations (key, version, applied_at) VALUES (?, ?, ?)",
            [.text("catalog_entity_relations"), .integer(1), .real(now)]
        )
    }

    private func query(_ url: URL, _ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        let db = try SQLiteDatabase(url: url)
        return try db.query(sql, bindings)
    }

    @Test("v1 老库升级：payload 真实 AlbumID 覆盖名称猜测的错误绑定，version 升到 2")
    func v1CatalogUpgradesToV2WithAuthoritativeRepair() async throws {
        let url = try makeV1Catalog()
        try seedV1Catalog(at: url)

        // 打开新版 LocalCatalogStore：init 即执行 v1→v2 迁移。
        _ = try LocalCatalogStore(url: url)

        // version 必须前进到 2。
        let version = try query(url, "SELECT version FROM catalog_migrations WHERE key = ?", [.text("catalog_entity_relations")])
            .first?["version"]?.int
        #expect(version == 2, "v1 库必须被升级到 v2，payload repair 才真正执行")

        // track.album_gid 必须被 payload 中真实 albumID（album-real-2）修正。
        let rows = try query(url, "SELECT album_gid, artist_gid FROM tracks WHERE remote_id = ?", [.text("track-1")])
        #expect(rows.count == 1)
        #expect(rows.first?["album_gid"]?.string == GlobalID(serverID: serverID, remoteID: "album-real-2").description,
                "v1 名称猜测的错误绑定必须被 payload 真实 ID 覆盖")
        #expect(rows.first?["artist_gid"]?.string == GlobalID(serverID: serverID, remoteID: "artist-real").description)
    }

    @Test("v1 老库升级：payload 无法 decode 的行保留 v1 名称猜测结果")
    func v1CatalogUpgradeKeepsUnparsablePayloadRows() async throws {
        let url = try makeV1Catalog()
        try seedV1Catalog(at: url)
        // 再塞一条 payload 损坏的 track（旧格式/坏 JSON），v1 已填 album_gid。
        let db = try SQLiteDatabase(url: url)
        try db.run(
            "INSERT INTO tracks (global_id, server_id, remote_id, title, artist_name, album_title, album_gid, artist_gid, duration, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text("srv:track-broken"), .text("srv"), .text("track-broken"), .text("Broken"), .text("Artist"),
             .text("Same Album"), .text("srv:album-real-1"), .text("srv:artist-real"),
             .real(200), .text("{not valid json"), .real(Date().timeIntervalSince1970)]
        )

        _ = try LocalCatalogStore(url: url)

        // decode 失败 → 该行保留 v1 值，不被清空。
        let rows = try query(url, "SELECT album_gid FROM tracks WHERE remote_id = ?", [.text("track-broken")])
        #expect(rows.first?["album_gid"]?.string == "srv:album-real-1")
    }

    @Test("全新库（version 0）直接一次到位到 v2：payload 精确回填生效")
    func freshCatalogEndsAtV2() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityRelationMigrationV2Fresh.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("catalog.sqlite")

        _ = try LocalCatalogStore(url: url)

        let version = try query(url, "SELECT version FROM catalog_migrations WHERE key = ?", [.text("catalog_entity_relations")])
            .first?["version"]?.int
        #expect(version == 2)
    }
}
