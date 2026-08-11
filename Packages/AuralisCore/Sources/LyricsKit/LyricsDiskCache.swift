import Domain
import Foundation

/// 歌词磁盘缓存。
///
/// 解决「每次打开 App、每次切歌都要重新向服务器要一次歌词」的问题：
/// - 命中的歌词以 JSON 落盘，冷启动后直接读本地，零网络请求。
/// - 同时记录「该曲目服务器确认没有歌词」的负缓存，避免每次启动都重复空跑一遍请求。
/// - 独立目录，可在设置页单独统计与清理。
///
/// 多服务器隔离（P0-2）：所有键使用「serverID:trackID」（与
/// `LocalCatalog.GlobalID` 的 `description` 完全一致），文件名带服务器前缀；
/// misses 负缓存同样按服务器隔离，避免 A 服务器「确认无歌词」后
/// B 服务器同 ID 曲目永久不再请求歌词。
public actor LyricsDiskCache {
    private let directory: URL
    private let missesURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// "serverID:trackID" → 已确认无歌词（负缓存）。
    private var misses: Set<String> = []
    private var didLoad = false

    public init(directory: URL? = nil) {
        let manager = FileManager.default
        let base = directory ?? {
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.temporaryDirectory
            return support.appendingPathComponent("Auralis/LyricsCache", isDirectory: true)
        }()
        self.directory = base
        self.missesURL = base.appendingPathComponent("misses.json")
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private static func key(_ serverID: ServerID, _ trackID: TrackID) -> String {
        "\(serverID.rawValue):\(trackID.rawValue)"
    }

    // MARK: - 读写

    /// 读取缓存歌词；未缓存返回 nil。
    public func document(forServer serverID: ServerID, trackID: TrackID) -> LyricsDocument? {
        let url = directory.appendingPathComponent(Self.fileName(serverID: serverID, trackID: trackID))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LyricsDocument.self, from: data)
    }

    /// 该曲目是否已确认无歌词（避免重复请求）。
    public func isKnownMissing(serverID: ServerID, trackID: TrackID) -> Bool {
        loadMissesIfNeeded()
        return misses.contains(Self.key(serverID, trackID))
    }

    /// 写入歌词。
    public func store(_ document: LyricsDocument, forServer serverID: ServerID, trackID: TrackID) {
        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.fileName(serverID: serverID, trackID: trackID)), options: .atomic)
        loadMissesIfNeeded()
        if misses.remove(Self.key(serverID, trackID)) != nil { persistMisses() }
    }

    /// 记录「服务器没有这首歌的歌词」。
    public func markMissing(serverID: ServerID, trackID: TrackID) {
        loadMissesIfNeeded()
        guard misses.insert(Self.key(serverID, trackID)).inserted else { return }
        persistMisses()
    }

    /// Migrates pre-GlobalID lyric documents and negative-cache keys into the
    /// last active server namespace. The document payload retains TrackID, so
    /// legacy filenames can be identified without guessing or discarding data.
    public func migrateLegacyEntries(to serverID: ServerID) {
        loadMissesIfNeeded()
        let legacyMisses = misses.filter { !$0.contains(":") }
        if !legacyMisses.isEmpty {
            for remoteID in legacyMisses where !remoteID.isEmpty {
                misses.insert(Self.key(serverID, TrackID(rawValue: remoteID)))
            }
            misses.subtract(legacyMisses)
            persistMisses()
        }

        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for source in entries where source.pathExtension == "json" && source.lastPathComponent != "misses.json" {
            guard let data = try? Data(contentsOf: source),
                  let document = try? decoder.decode(LyricsDocument.self, from: data),
                  source.lastPathComponent == Self.safeEncode(document.trackID.rawValue) + ".json"
            else { continue }
            let destination = directory.appendingPathComponent(Self.fileName(serverID: serverID, trackID: document.trackID))
            if !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: source, to: destination)
            } else {
                try? manager.removeItem(at: source)
            }
        }
    }

    // MARK: - 统计与清理

    public func totalBytes() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// 已缓存歌词的曲目数（不含 misses.json 本身）。
    public func documentCount() -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "json" && $0.lastPathComponent != "misses.json" }.count
    }

    public func clear() {
        let manager = FileManager.default
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries { try? manager.removeItem(at: entry) }
        }
        misses = []
        didLoad = true
    }

    /// 按服务器清理该服务器的歌词文件与负缓存条目（删除服务器 / 清理本地数据用）。
    /// 服务器前缀即 "serverID:"。
    public func removeAll(forServer serverID: ServerID) {
        let manager = FileManager.default
        let encodedPrefix = Self.safeEncode(serverID.rawValue + ":")
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name != "misses.json",
                      name.hasPrefix(encodedPrefix),
                      name.hasSuffix(".json")
                else { continue }
                try? manager.removeItem(at: entry)
            }
        }
        let prefix = serverID.rawValue + ":"
        loadMissesIfNeeded()
        let stale = misses.filter { $0.hasPrefix(prefix) }
        if !stale.isEmpty {
            misses.subtract(stale)
            persistMisses()
        }
    }

    // MARK: - 内部

    private func loadMissesIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: missesURL),
              let decoded = try? decoder.decode(Set<String>.self, from: data)
        else { return }
        // Keep legacy bare IDs dormant until the last active server is known;
        // migration then assigns the only provenance older versions retained.
        misses = decoded
    }

    private func persistMisses() {
        guard let data = try? encoder.encode(misses) else { return }
        try? data.write(to: missesURL, options: .atomic)
    }

    /// 组合键含 ":" 与可能的路径字符，统一做安全化处理（非字母数字替换为 "_"）。
    private static func fileName(serverID: ServerID, trackID: TrackID) -> String {
        "\(safeEncode(key(serverID, trackID))).json"
    }

    private static func safeEncode(_ string: String) -> String {
        string.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }
}
