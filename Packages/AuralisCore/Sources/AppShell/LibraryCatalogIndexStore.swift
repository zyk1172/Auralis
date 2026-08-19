import Domain
import Foundation
import LocalCatalog

/// 曲库分类索引的本地文件维护（供 Agent 按需读取，避免每次把全部元数据塞进对话）。
///
/// 同步完成后刷新，把曲库元数据按分类拆成多个小文件：
/// meta.json / artists.json / albums.json / genres.json / languages.json / years.json
/// / favorites.json / recent.json / popular.json / tracks.json
/// 每个文件只含元数据（ID/标题/歌手/专辑/年份/流派/语言/时长/收藏/评分/播放次数），
/// **不含歌词、海报、流地址**。
@MainActor
public final class LibraryCatalogIndexStore {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Auralis/library-catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 重新生成并落盘全部分类索引。
    public func refresh(serverID: ServerID?, catalog: LocalCatalogStore) async throws {
        let index = try await catalog.makeCatalogIndex(serverID: serverID)
        try writeJSON(index, to: directoryURL.appendingPathComponent("meta.json"))
        try writeJSON(index.artists, to: directoryURL.appendingPathComponent("artists.json"))
        try writeJSON(index.albums, to: directoryURL.appendingPathComponent("albums.json"))
        try writeJSON(index.genres, to: directoryURL.appendingPathComponent("genres.json"))
        try writeJSON(index.languages, to: directoryURL.appendingPathComponent("languages.json"))
        try writeJSON(index.years, to: directoryURL.appendingPathComponent("years.json"))
        try writeJSON(index.favorites, to: directoryURL.appendingPathComponent("favorites.json"))
        try writeJSON(index.recent, to: directoryURL.appendingPathComponent("recent.json"))
        try writeJSON(index.popular, to: directoryURL.appendingPathComponent("popular.json"))
        // tracks.json：按标题排序的全量紧凑索引（供需要全库的场合）。
        let all = try await catalog.catalogTracks(serverID: serverID, category: "all", limit: 5000)
        try writeJSON(all, to: directoryURL.appendingPathComponent("tracks.json"))
    }

    /// 读取某个分类文件（Agent 工具实际读 SQLite 保持最新；此文件用于离线快照/审计）。
    public func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        let url = directoryURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}