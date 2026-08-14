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

    public struct CachedTrackEntry: Hashable, Sendable, Identifiable {
        public var id: TrackCacheID { cacheID }
        public let cacheID: TrackCacheID
        public let byteCount: Int64
        public let modifiedAt: Date

        public init(cacheID: TrackCacheID, byteCount: Int64, modifiedAt: Date) {
            self.cacheID = cacheID
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
        }
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
            // Preserve legacy bare TrackID entries until the app supplies the
            // last active server. Silently deleting downloaded audio would be
            // irreversible and violates the GlobalID migration contract.
            index = decoded
        } else if manager.fileExists(atPath: indexURL.path) {
            // 更早版本 index.json 是 [TrackID: String]（JSON 数组形式），同样无法归属
            // 服务器 → 整体丢弃并落回空索引。
            index = [:]
            if let migrated = try? JSONEncoder().encode([String: String]()) {
                try? migrated.write(to: indexURL, options: .atomic)
            }
        }
    }

    /// One-time migration for pre-GlobalID cache indexes. The last active
    /// server is the only provenance older builds persisted; entries remain
    /// dormant until that namespace is known and are never assigned to a
    /// newly-added unrelated server.
    public func migrateLegacyEntries(to serverID: ServerID) {
        let legacyKeys = index.keys.filter { !$0.contains(":") }
        guard !legacyKeys.isEmpty else { return }
        for remoteID in legacyKeys {
            let globalKey = TrackCacheID(
                serverID: serverID,
                trackID: TrackID(rawValue: remoteID)
            ).description
            if index[globalKey] == nil { index[globalKey] = index[remoteID] }
            index[remoteID] = nil
        }
        try? persistIndex()
    }

    /// 已缓存且文件存在时返回本地文件 URL。
    public func cachedFileURL(for id: TrackCacheID) -> URL? {
        guard let name = index[id.description] else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 文件被外部清理后立即修复索引；否则 UI 会永久保留一个幽灵下载记录。
            index[id.description] = nil
            try? persistIndex()
            return nil
        }
        return url
    }

    public func isCached(_ id: TrackCacheID) -> Bool {
        cachedFileURL(for: id) != nil
    }

    public func cachedTrackIDs() -> Set<TrackCacheID> {
        Set(cachedEntries().map(\.cacheID))
    }

    /// 下载页所需的真实磁盘信息。读取时顺手剔除失效索引，大小与日期均来自文件系统，
    /// 不依赖可能过期的内存估算。
    public func cachedEntries() -> [CachedTrackEntry] {
        var result: [CachedTrackEntry] = []
        var staleKeys: [String] = []
        for (key, name) in index {
            guard let cacheID = Self.cacheID(from: key) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let fileSize = values.fileSize
            else {
                staleKeys.append(key)
                continue
            }
            result.append(CachedTrackEntry(
                cacheID: cacheID,
                byteCount: Int64(fileSize),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        if !staleKeys.isEmpty {
            for key in staleKeys { index[key] = nil }
            try? persistIndex()
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 写入音频数据并更新索引。codec 用于推导文件扩展名，保证 AVPlayer 能识别格式。
    public func store(data: Data, for id: TrackCacheID, codec: String?) throws -> URL {
        guard !data.isEmpty else { throw TrackCacheError.emptyFile }
        try ensureDirectory()
        let name = Self.uniqueFileName(id: id, codec: codec)
        let url = directory.appendingPathComponent(name)
        let previousName = index[id.description]
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        index[id.description] = name
        do {
            try persistIndex()
        } catch {
            index[id.description] = previousName
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        removeReplacedFile(previousName, keeping: name)
        return url
    }

    /// 把已下载到临时位置的音频文件移入缓存目录并登记索引（原子移动）。
    public func moveDownloadedFile(at sourceURL: URL, for id: TrackCacheID, codec: String?) throws -> URL {
        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard sourceSize > 0 else { throw TrackCacheError.emptyFile }
        try ensureDirectory()
        let name = Self.uniqueFileName(id: id, codec: codec)
        let destination = directory.appendingPathComponent(name)
        let previousName = index[id.description]
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        index[id.description] = name
        do {
            try persistIndex()
        } catch {
            index[id.description] = previousName
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        removeReplacedFile(previousName, keeping: name)
        return destination
    }

    public func remove(for id: TrackCacheID) throws {
        guard let name = index[id.description] else { return }
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let previousName = index[id.description]
        index[id.description] = nil
        do {
            try persistIndex()
        } catch {
            index[id.description] = previousName
            throw error
        }
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

    /// 清空所有用户主动下载的音频。调用方需先取消活动任务，防止清空后后台任务又写回。
    public func removeAll() throws {
        let previousIndex = index
        for name in Set(index.values) {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        index = [:]
        do {
            try persistIndex()
        } catch {
            index = previousIndex
            throw error
        }
    }

    /// 缓存总大小（字节），供设置页展示。
    public func totalBytes() -> Int64 {
        cachedEntries().reduce(into: Int64(0)) { $0 += $1.byteCount }
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeReplacedFile(_ previousName: String?, keeping currentName: String) {
        guard let previousName, previousName != currentName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(previousName))
    }

    private static func cacheID(from description: String) -> TrackCacheID? {
        guard let separator = description.firstIndex(of: ":") else { return nil }
        return TrackCacheID(
            serverID: ServerID(rawValue: String(description[..<separator])),
            trackID: TrackID(rawValue: String(description[description.index(after: separator)...]))
        )
    }

    /// 旧实现把所有非字母数字都变成 `_`，`track/a` 与 `track?a` 会落到同一个文件并互相覆盖。
    /// 文件名现在使用可读前缀 + FNV-1a + UUID；真正身份仍由 index 的完整 GlobalID 决定。
    private static func uniqueFileName(id: TrackCacheID, codec: String?) -> String {
        let readable = id.trackID.rawValue.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
            .prefix(32)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.description.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(readable)-\(String(hash, radix: 16))-\(UUID().uuidString).\(fileExtension(codec: codec))"
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

public enum TrackCacheError: Error, Equatable, Sendable {
    case emptyFile
}
