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
    /// "serverID:trackID" → 标记为「确认无歌词」的时间（负缓存）。
    /// 带时间戳：超限裁剪时按最旧优先（确定性 FIFO），而不是从无序 Set 随机裁掉刚插入的条目。
    private var misses: [String: Date] = [:]
    private var didLoad = false
    /// 歌词缓存总字节预算：超过后按文件大小从大到小淘汰（P2-1，RC 边界策略）。
    private static let maxTotalBytes: Int64 = 64 * 1024 * 1024
    /// 负缓存条目上限：超过后裁剪，避免无限增长（再超出的曲目会重新向服务器确认一次）。
    private static let maxMissesCount = 20_000
    /// 歌词文件大小账本：文件名 → 字节数（排除 misses.json）。首次需要时全量扫描，
    /// 之后每次 store/delete 只做 O(1) 增量维护，不再每次写歌词都扫目录。
    private var fileSizes: [String: Int64] = [:]
    /// 歌词文件总字节（与 fileSizes 保持一致；nil = 尚未建立索引）。
    private var knownTotalBytes: Int64?

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
        return misses[Self.key(serverID, trackID)] != nil
    }

    /// 写入歌词。
    public func store(_ document: LyricsDocument, forServer serverID: ServerID, trackID: TrackID) {
        guard let data = try? encoder.encode(document) else { return }
        let url = directory.appendingPathComponent(Self.fileName(serverID: serverID, trackID: trackID))
        // 写失败（磁盘满 / 权限 / atomic replace 失败）直接返回：账本必须与磁盘一致，
        // 不能因为 try? 吞掉错误就把从未落盘的文件计入 fileSizes / knownTotalBytes。
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        // O(1) 账本维护：先确保索引已建立，再按 data.count 增量更新。
        ensureIndexLoadedIfNeeded()
        let name = url.lastPathComponent
        let newSize = Int64(data.count)
        let oldSize = fileSizes[name] ?? 0
        fileSizes[name] = newSize
        knownTotalBytes = (knownTotalBytes ?? 0) + newSize - oldSize
        loadMissesIfNeeded()
        if misses.removeValue(forKey: Self.key(serverID, trackID)) != nil { persistMisses() }
        evictIfNeeded()
    }

    /// 记录「服务器没有这首歌的歌词」。
    public func markMissing(serverID: ServerID, trackID: TrackID) {
        loadMissesIfNeeded()
        let key = Self.key(serverID, trackID)
        guard misses[key] == nil else { return }
        misses[key] = .now
        pruneMissesIfNeeded()
        persistMisses()
    }

    /// Migrates pre-GlobalID lyric documents and negative-cache keys into the
    /// last active server namespace. The document payload retains TrackID, so
    /// legacy filenames can be identified without guessing or discarding data.
    public func migrateLegacyEntries(to serverID: ServerID) {
        loadMissesIfNeeded()
        let legacyMisses = misses.filter { !$0.key.contains(":") }
        if !legacyMisses.isEmpty {
            for remoteID in legacyMisses.keys where !remoteID.isEmpty {
                misses[Self.key(serverID, TrackID(rawValue: remoteID))] = .now
            }
            for key in legacyMisses.keys {
                misses.removeValue(forKey: key)
            }
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
        // 迁移直接搬移/删除了文件，账本已失真：重置为未初始化，下次按需全量重建。
        fileSizes = [:]
        knownTotalBytes = nil
    }

    /// R09：把旧版有损文件名（safeEncode，非字母数字 → `_`，存在碰撞）迁移到
    /// 无损 percent-encoding 文件名。旧文件名格式为 `\(serverID)_\(safeEncode(trackID)).json`：
    /// serverID 是 `server-<hex>`（全字母数字，safeEncode 无损）可从文件名前缀还原；
    /// trackID 从 payload 的 LyricsDocument 恢复。完全不携带 serverID 的更旧文件
    /// 归属 `activeServerID`（与 migrateLegacyEntries 一致）。
    public func migrateLegacyFilenames(to activeServerID: ServerID) {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for source in entries where source.pathExtension == "json" && source.lastPathComponent != "misses.json" {
            let name = source.lastPathComponent
            // 新格式文件名以 "serverID:" 开头（冒号保留），跳过。
            if name.contains(":") { continue }
            guard let data = try? Data(contentsOf: source),
                  let document = try? decoder.decode(LyricsDocument.self, from: data)
            else { continue }
            let serverID: ServerID
            if name.hasPrefix("server-"), let underscore = name.firstIndex(of: "_") {
                serverID = ServerID(rawValue: String(name[name.startIndex..<underscore]))
            } else {
                serverID = activeServerID
            }
            let destination = directory.appendingPathComponent(Self.fileName(serverID: serverID, trackID: document.trackID))
            if destination.lastPathComponent == name { continue }
            if !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: source, to: destination)
            } else {
                // 新名已存在（碰撞遗留的覆盖数据以新名为准），删除旧名。
                try? manager.removeItem(at: source)
            }
        }
        fileSizes = [:]
        knownTotalBytes = nil
    }

    // MARK: - 边界策略（P2-1）

    /// 首次需要容量信息时全量扫描一次，之后 store/删除走增量维护。
    private func ensureIndexLoadedIfNeeded() {
        guard knownTotalBytes == nil else { return }
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var total: Int64 = 0
        var sizes: [String: Int64] = [:]
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".json"), name != "misses.json" else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            sizes[name] = size
            total += size
        }
        fileSizes = sizes
        knownTotalBytes = total
    }

    /// 超过总字节预算时，按文件大小从大到小淘汰，直到低于预算。
    /// 正常路径 O(1)：先查账本，未超预算直接返回，不再扫目录。
    private func evictIfNeeded() {
        guard let knownTotalBytes, knownTotalBytes > Self.maxTotalBytes else { return }
        let manager = FileManager.default
        let candidates = fileSizes
            .filter { $0.key != "misses.json" }
            .sorted { $0.value > $1.value }
        var total = knownTotalBytes
        var index = 0
        while total > Self.maxTotalBytes, index < candidates.count {
            let name = candidates[index].key
            let size = candidates[index].value
            let url = directory.appendingPathComponent(name)
            do {
                try manager.removeItem(at: url)
                // 只有真正删除成功才更新账本；失败保留账目，下次淘汰重试。
                fileSizes[name] = nil
                total -= size
            } catch {
                // 删除失败：不扣减账本，继续尝试下一个候选。
            }
            index += 1
        }
        self.knownTotalBytes = total
    }

    /// 负缓存条目超限时裁剪一半（确定性 FIFO：按标记时间从最旧开始裁，
    /// 不再从无序 Set 随机裁掉刚插入的条目）。丢失的负缓存只意味着重新确认一次。
    private func pruneMissesIfNeeded() {
        guard misses.count > Self.maxMissesCount else { return }
        let keepCount = Self.maxMissesCount / 2
        let oldest = misses.sorted { $0.value < $1.value }
        for pair in oldest.prefix(misses.count - keepCount) {
            misses.removeValue(forKey: pair.key)
        }
    }

    // MARK: - 统计与清理

    public func totalBytes() -> Int64 {
        // 索引已初始化直接返回账本，不再扫目录。
        if let knownTotalBytes { return knownTotalBytes }
        ensureIndexLoadedIfNeeded()
        return knownTotalBytes ?? 0
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
        misses = [:]
        didLoad = true
        fileSizes = [:]
        knownTotalBytes = 0
    }

    /// 按服务器清理该服务器的歌词文件与负缓存条目（删除服务器 / 清理本地数据用）。
    /// 服务器前缀即 "serverID:"（percent-encoding 保留该前缀，可按前缀匹配清理）。
    public func removeAll(forServer serverID: ServerID) {
        let manager = FileManager.default
        let encodedPrefix = serverID.rawValue + ":"
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name != "misses.json",
                      name.hasPrefix(encodedPrefix),
                      name.hasSuffix(".json")
                else { continue }
                if (try? manager.removeItem(at: entry)) != nil {
                    // 只有真正删除成功才更新账本。
                    if let size = fileSizes.removeValue(forKey: name) {
                        knownTotalBytes = (knownTotalBytes ?? 0) - size
                    }
                }
            }
        }
        let prefix = serverID.rawValue + ":"
        loadMissesIfNeeded()
        let stale = misses.filter { $0.key.hasPrefix(prefix) }
        if !stale.isEmpty {
            for key in stale.keys {
                misses.removeValue(forKey: key)
            }
            persistMisses()
        }
    }

    // MARK: - 内部

    private func loadMissesIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: missesURL) else { return }
        // 新格式：[String: Date]（key → 标记时间）。兼容旧格式 Set<String>。
        if let decoded = try? decoder.decode([String: Date].self, from: data) {
            misses = decoded
            return
        }
        if let legacy = try? decoder.decode(Set<String>.self, from: data) {
            // Keep legacy bare IDs dormant until the last active server is known;
            // migration then assigns the only provenance older versions retained.
            misses = Dictionary(uniqueKeysWithValues: legacy.map { ($0, Date.now) })
        }
    }

    private func persistMisses() {
        guard let data = try? encoder.encode(misses) else { return }
        try? data.write(to: missesURL, options: .atomic)
    }

    /// 组合键含 ":" 与可能的路径字符，统一做安全化处理（非字母数字替换为 "_"）。
    /// R09 起新写入使用无损 percent-encoding（fileName），本函数仅用于识别
    /// 历史 safeEncode 文件名（迁移时判断旧格式）。
    private static func fileName(serverID: ServerID, trackID: TrackID) -> String {
        // R09：无损 percent-encoding——不同键绝不映射到同一文件名（safeEncode 会把
        // a/b、a:b、a?b 都变成 a_b 导致互相覆盖）。保留字母数字与 -._~:，
        // 服务器前缀 "serverID:" 仍可经前缀匹配用于按服务器清理。
        let key = Self.key(serverID, trackID)
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~:"))
        let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return encoded + ".json"
    }

    private static func safeEncode(_ string: String) -> String {
        string.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }
}
