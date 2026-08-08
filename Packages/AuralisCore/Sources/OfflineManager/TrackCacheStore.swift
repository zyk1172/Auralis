import Domain
import Foundation

/// 歌曲本地缓存：把服务器音频完整下载到 Application Support/Auralis/TrackCache，
/// 索引持久化在同级 index.json。已缓存的歌曲优先用本地文件播放。
///
/// 多服务器隔离（P0-1）：所有键均使用「serverID:trackID」组合键（`TrackCacheID`），
/// 与 `LocalCatalog.GlobalID` 的 `description`（"serverID:trackID"）完全一致。
/// 文件名带服务器前缀，避免两台服务器同 ID 曲目串库（错曲离线播放 / 误判已下载 / 误删对方文件）。
public actor TrackCacheStore {
    /// 歌曲缓存的服务器作用域组合键：`serverID:trackID`。
    ///
    /// OfflineManager 只依赖 Domain（无法引用 LocalCatalog 的 GlobalID），
    /// 因此用 ServerID+TrackID 表达等价组合键；`description` 与
    /// `GlobalID(serverID:remoteID:).description` 逐字节一致。
    public struct TrackCacheID: Hashable, Sendable, CustomStringConvertible {
        public let serverID: ServerID
        public let trackID: TrackID

        public init(serverID: ServerID, trackID: TrackID) {
            self.serverID = serverID
            self.trackID = trackID
        }

        public var description: String { "\(serverID.rawValue):\(trackID.rawValue)" }
    }

    private let directory: URL
    private let indexURL: URL
    /// 组合键描述（"serverID:trackID"）→ 缓存文件名
    private var index: [String: String] = [:]

    public init(directory: URL? = nil) {
        let manager = FileManager.default
        let base = directory ?? {
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.temporaryDirectory
            return support.appendingPathComponent("Auralis/TrackCache", isDirectory: true)
        }()
        self.directory = base
        self.indexURL = base.appendingPathComponent("index.json")
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            // 旧格式（裸 trackID，无冒号）无法归属服务器，启动时直接丢弃，
            // 与 playCounts 旧数据迁移策略一致，避免残留裸键被新服务器误用。
            let filtered = decoded.filter { $0.key.contains(":") }
            index = filtered
            if filtered.count != decoded.count,
               let migrated = try? JSONEncoder().encode(filtered) {
                try? migrated.write(to: indexURL, options: .atomic)
            }
        } else if manager.fileExists(atPath: indexURL.path) {
            // 更早版本 index.json 是 [TrackID: String]（JSON 数组形式），同样无法归属
            // 服务器 → 整体丢弃并落回空索引。
            index = [:]
            if let migrated = try? JSONEncoder().encode([String: String]()) {
                try? migrated.write(to: indexURL, options: .atomic)
            }
        }
    }

    /// 已缓存且文件存在时返回本地文件 URL。
    public func cachedFileURL(for id: TrackCacheID) -> URL? {
        guard let name = index[id.description] else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isCached(_ id: TrackCacheID) -> Bool {
        cachedFileURL(for: id) != nil
    }

    public func cachedTrackIDs() -> Set<TrackCacheID> {
        Set(index.keys.compactMap { key in
            guard let separator = key.firstIndex(of: ":") else { return nil }
            return TrackCacheID(
                serverID: ServerID(rawValue: String(key[key.startIndex..<separator])),
                trackID: TrackID(rawValue: String(key[key.index(after: separator)...]))
            )
        }.filter { cachedFileURL(for: $0) != nil })
    }

    /// 写入音频数据并更新索引。codec 用于推导文件扩展名，保证 AVPlayer 能识别格式。
    public func store(data: Data, for id: TrackCacheID, codec: String?) throws -> URL {
        let name = "\(Self.safeFileName(id)).\(Self.fileExtension(codec: codec))"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        index[id.description] = name
        try persistIndex()
        return url
    }

    /// 把已下载到临时位置的音频文件移入缓存目录并登记索引（原子移动）。
    public func moveDownloadedFile(at sourceURL: URL, for id: TrackCacheID, codec: String?) throws -> URL {
        let name = "\(Self.safeFileName(id)).\(Self.fileExtension(codec: codec))"
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        index[id.description] = name
        try persistIndex()
        return destination
    }

    public func remove(for id: TrackCacheID) throws {
        guard let name = index[id.description] else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        index[id.description] = nil
        try persistIndex()
    }

    /// 按服务器删除该服务器的全部音频缓存（删除服务器 / 清理本地数据用）。
    /// 服务器前缀即 "serverID:"。
    public func removeAll(forServer serverID: ServerID) {
        let prefix = serverID.rawValue + ":"
        let keys = index.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys {
            if let name = index[key] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            index[key] = nil
        }
        try? persistIndex()
    }

    /// 缓存总大小（字节），供设置页展示。
    public func totalBytes() -> Int64 {
        index.keys.reduce(into: Int64(0)) { total, key in
            guard let separator = key.firstIndex(of: ":"),
                  let url = cachedFileURL(for: TrackCacheID(
                      serverID: ServerID(rawValue: String(key[key.startIndex..<separator])),
                      trackID: TrackID(rawValue: String(key[key.index(after: separator)...]))
                  )),
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            else { return }
            total += size
        }
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    /// 组合键描述含 ":" 等路径不友好字符，统一做安全化处理：非字母数字替换为 "_"，
    /// 例如 "srv1:track/1" → "srv1_track_1"。
    private static func safeFileName(_ id: TrackCacheID) -> String {
        id.description.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private static func fileExtension(codec: String?) -> String {
        switch codec?.lowercased() {
        case "flac": return "flac"
        case "aac", "m4a": return "m4a"
        case "ogg", "opus": return "ogg"
        case "wav": return "wav"
        case "aiff", "aif": return "aiff"
        case "alac": return "m4a"
        default: return "mp3"
        }
    }
}
