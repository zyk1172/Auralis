import Domain
import Foundation
import MusicLibrary

/// 歌曲级“不喜欢”权威状态。
///
/// 语义：以后 Auralis 自动选歌 / 推荐 / 生成智能队列时不再主动推荐这首歌。
/// 它不是删除、不是隐藏搜索结果 / 专辑 / 歌单，也不禁止显式播放。
/// 身份一律使用 GlobalID（serverID + remoteID），两台服务器相同 remote TrackID 不串数据。
/// 属于私人用户状态，不是服务器曲目元数据；不修改 Track payload。
extension LocalCatalogStore {
    /// 设置 / 取消“不喜欢”。幂等；`value == true` 时重复设置不重复插入。
    /// - Parameters:
    ///   - source: 状态来源（例如 `user` / `migration:notInterestedFeedback`），仅诊断用途。
    public func setDisliked(_ globalID: GlobalID, value: Bool, source: String? = nil) throws {
        if value {
            try db.run(
                """
                INSERT INTO disliked_tracks (global_id, server_id, created_at, source)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(global_id) DO NOTHING
                """,
                [.text(globalID.description), .text(globalID.serverID.rawValue),
                 .real(Date.now.timeIntervalSince1970),
                 source.map(SQLiteValue.text) ?? .null]
            )
        } else {
            try db.run(
                "DELETE FROM disliked_tracks WHERE global_id = ?",
                [.text(globalID.description)]
            )
        }
    }

    /// 查询单曲是否“不喜欢”。
    public func isDisliked(_ globalID: GlobalID) throws -> Bool {
        try db.query(
            "SELECT 1 FROM disliked_tracks WHERE global_id = ? LIMIT 1",
            [.text(globalID.description)]
        ).isEmpty == false
    }

    /// 当前服务器（或全部服务器）的“不喜欢” GlobalID 集合。
    public func dislikedTrackIDs(serverID: ServerID? = nil) throws -> Set<GlobalID> {
        let rows: [[String: SQLiteValue]]
        if let serverID {
            rows = try db.query(
                "SELECT global_id FROM disliked_tracks WHERE server_id = ?",
                [.text(serverID.rawValue)]
            )
        } else {
            rows = try db.query("SELECT global_id FROM disliked_tracks")
        }
        return Set(rows.compactMap { row in
            row["global_id"]?.string.flatMap(GlobalID.init)
        })
    }

    /// 返回“不喜欢”的真实曲目（按设置时间倒序），`limit == nil` 时不限量。
    public func dislikedTracks(serverID: ServerID, limit: Int? = nil) throws -> [Track] {
        let ids = try dislikedTrackIDs(serverID: serverID)
        guard !ids.isEmpty else { return [] }
        let tracks = try allTracks(serverID: serverID, limit: 20_000)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map {
            (GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue), $0)
        })
        let ordered = try db.query(
            "SELECT global_id FROM disliked_tracks WHERE server_id = ? ORDER BY created_at DESC",
            [.text(serverID.rawValue)]
        ).compactMap { row -> Track? in
            guard let id = row["global_id"]?.string, let gid = GlobalID(id) else { return nil }
            return byID[gid]
        }
        if let limit, limit >= 0 {
            return Array(ordered.prefix(limit))
        }
        return ordered
    }

    /// 清理某个服务器的全部 dislike 状态（purge 时调用）。
    func purgeDislikedTracks(serverID: ServerID) throws {
        try db.run(
            "DELETE FROM disliked_tracks WHERE server_id = ?",
            [.text(serverID.rawValue)]
        )
    }
}
