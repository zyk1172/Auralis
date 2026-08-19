import Domain
import Foundation

/// 歌单 / 流派的本地缓存。
///
/// 曲目、专辑、艺术家已由 `AuralisPersisting` 快照持久化，但歌单与流派此前
/// 只存在于内存里——每次冷启动都要在 `restoreLastConnection()` 里同步等待
/// 服务器的 `getPlaylists` + `getGenres` 两个网络请求才能出界面。
///
/// 这里把它们按服务器落盘：启动时直接读本地立即出界面，联网后再后台增量刷新。
public actor LibraryAuxiliaryCache {
    /// 一台服务器的辅助数据快照。
    public struct Snapshot: Codable, Sendable {
        public var playlists: [Playlist]
        public var genres: [Genre]
        /// 服务器上已收藏（star）的单曲 ID，保证冷启动后收藏状态与服务器一致。
        /// 字段为可选以兼容旧版本缓存文件（缺键时按无收藏处理）。
        public var favoriteTrackIDs: [String]?
        public var updatedAt: Date

        public init(
            playlists: [Playlist],
            genres: [Genre],
            favoriteTrackIDs: [String]? = nil,
            updatedAt: Date = Date()
        ) {
            self.playlists = playlists
            self.genres = genres
            self.favoriteTrackIDs = favoriteTrackIDs
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case playlists
            case genres
            case favoriteTrackIDs
            case updatedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            playlists = try container.decode([Playlist].self, forKey: .playlists)
            genres = try container.decode([Genre].self, forKey: .genres)
            favoriteTrackIDs = try container.decodeIfPresent([String].self, forKey: .favoriteTrackIDs)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(playlists, forKey: .playlists)
            try container.encode(genres, forKey: .genres)
            try container.encode(favoriteTrackIDs ?? [], forKey: .favoriteTrackIDs)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        let manager = FileManager.default
        let base = directory ?? {
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.temporaryDirectory
            return support.appendingPathComponent("Auralis/AuxCache", isDirectory: true)
        }()
        self.directory = base
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func snapshot(serverID: ServerID) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(for: serverID)) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public func save(
        playlists: [Playlist],
        genres: [Genre],
        favoriteTrackIDs: [String]? = nil,
        serverID: ServerID
    ) {
        let snapshot = Snapshot(
            playlists: playlists,
            genres: genres,
            favoriteTrackIDs: favoriteTrackIDs,
            updatedAt: Date()
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url(for: serverID), options: .atomic)
    }

    /// 仅更新收藏 ID 集合，保留已缓存的歌单与流派（收藏变更后即时落盘）。
    public func updateFavorites(_ ids: [String], serverID: ServerID) {
        var snapshot = snapshot(serverID: serverID) ?? Snapshot(playlists: [], genres: [])
        snapshot.favoriteTrackIDs = ids
        snapshot.updatedAt = Date()
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url(for: serverID), options: .atomic)
    }

    /// 仅更新歌单，保留已缓存的收藏与流派（歌单编辑成功后即时落盘）。
    public func updatePlaylists(_ playlists: [Playlist], serverID: ServerID) {
        var snapshot = snapshot(serverID: serverID) ?? Snapshot(playlists: [], genres: [])
        snapshot.playlists = playlists
        snapshot.updatedAt = Date()
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url(for: serverID), options: .atomic)
    }

    /// 上次辅助数据同步时间，供设置页展示。
    public func lastUpdatedAt(serverID: ServerID) -> Date? {
        snapshot(serverID: serverID)?.updatedAt
    }

    public func purge(serverID: ServerID) {
        try? FileManager.default.removeItem(at: url(for: serverID))
    }

    private func url(for serverID: ServerID) -> URL {
        let safe = serverID.rawValue.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return directory.appendingPathComponent("aux-\(safe).json")
    }
}