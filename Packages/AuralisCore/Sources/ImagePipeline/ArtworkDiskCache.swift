import CryptoKit
import Foundation

/// 封面图磁盘缓存。
///
/// 解决「每次打开 App 都要把所有封面重新从服务器下载一遍」的问题：
/// - 首次下载后按 `封面Key@像素尺寸` 落盘，之后冷启动直接读本地文件，零网络请求。
/// - 独立于音频缓存（TrackCache）与元数据目录（catalog.sqlite），可单独统计与清理。
/// - 采用 LRU：超出容量预算时按最近访问时间淘汰最旧的文件。
public actor ArtworkDiskCache {
    /// 默认容量预算 256 MB，足够容纳数千张列表封面 + 数百张大图。
    public static let defaultBudget: Int64 = 256 * 1024 * 1024

    private let directory: URL
    private let budget: Int64
    /// 进程内已知的文件大小（避免每次读磁盘属性）。
    private var sizes: [String: Int64] = [:]
    /// 最近访问时间，用于 LRU。
    private var accessedAt: [String: Date] = [:]
    private var didLoadIndex = false
    /// 后台索引维护任务（首次 store 后触发一次），不占用前台 actor 太久。
    private var maintenanceTask: Task<Void, Never>?

    public init(directory: URL? = nil, budget: Int64 = ArtworkDiskCache.defaultBudget) {
        let manager = FileManager.default
        let base = directory ?? {
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.temporaryDirectory
            return support.appendingPathComponent("Auralis/ArtworkCache", isDirectory: true)
        }()
        self.directory = base
        self.budget = budget
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - 读写

    /// 读取缓存的封面数据；不存在时返回 nil。
    ///
    /// 前台快路径：**不**先做全目录 LRU 索引扫描（冷启动时若已有数千张封面，
    /// 全量 `loadIndexIfNeeded()` 会挡住当前真正需要的那张封面）。
    /// 直接读目标文件；全量索引只交给统计 / 清理 / 淘汰等后台路径。
    public func data(for key: String) -> Data? {
        let name = Self.fileName(for: key)
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        sizes[name] = Int64(data.count)
        accessedAt[name] = Date()
        return data
    }

    /// 写入封面数据并在超预算时做一次 LRU 淘汰。
    ///
    /// 前台快路径：**不**在这里同步做全目录索引扫描（扫描与 `data(for:)` 同 actor，
    /// 会挡住后续封面读取）。写文件 + 更新内存后，排一个低优先级后台任务做
    /// 索引合并与淘汰；目录遍历在 `Task.detached` 中进行，不占用 cache actor。
    public func store(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        let name = Self.fileName(for: key)
        let url = directory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        sizes[name] = Int64(data.count)
        accessedAt[name] = Date()
        scheduleMaintenanceIfNeeded()
    }

    // MARK: - 统计与清理

    /// 缓存总大小（字节），供设置页展示。
    public func totalBytes() -> Int64 {
        loadIndexIfNeeded()
        return sizes.values.reduce(0, +)
    }

    /// 已缓存的封面文件数量。
    public func fileCount() -> Int {
        loadIndexIfNeeded()
        return sizes.count
    }

    /// 清空全部封面缓存（只删本机文件，服务器不受影响）。
    public func clear() {
        let manager = FileManager.default
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries { try? manager.removeItem(at: entry) }
        }
        sizes = [:]
        accessedAt = [:]
        didLoadIndex = true
    }

    // MARK: - 内部

    /// 首次访问时扫描目录，重建大小与访问时间索引。
    private func loadIndexIfNeeded() {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let name = entry.lastPathComponent
            sizes[name] = Int64(values?.fileSize ?? 0)
            accessedAt[name] = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
        }
    }

    /// store 后排一个后台维护任务。
    ///
    /// 关键原则：**目录全扫描进程生命周期最多一次**。首次 store 时 detached 扫描
    /// 建索引；之后 `didLoadIndex == true`，后续 store 只基于内存 sizes/accessedAt
    /// 做 LRU 淘汰，绝不再扫目录。
    private func scheduleMaintenanceIfNeeded() {
        guard maintenanceTask == nil else { return }

        if didLoadIndex {
            maintenanceTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.evictIfNeeded()
                await self.clearMaintenanceTask()
            }
            return
        }

        let directory = self.directory
        maintenanceTask = Task(priority: .utility) { [weak self] in
            let index = await Task.detached(priority: .utility) {
                ArtworkDiskCache.scanIndex(directory: directory)
            }.value
            guard let self else { return }
            await self.applyInitialIndex(index)
            await self.clearMaintenanceTask()
        }
    }

    /// 维护任务结束：清空标记，允许后续再次调度。
    private func clearMaintenanceTask() {
        maintenanceTask = nil
    }

    /// 在 detached 任务中遍历缓存目录（真正慢的部分，不占 actor）。
    private nonisolated static func scanIndex(
        directory: URL
    ) -> [String: (fileSize: Int64, accessDate: Date)] {
        var result: [String: (fileSize: Int64, accessDate: Date)] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return result }
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let name = entry.lastPathComponent
            result[name] = (
                fileSize: Int64(values?.fileSize ?? 0),
                accessDate: values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
            )
        }
        return result
    }

    /// 初次全量扫描结果合并进 actor 索引（进程生命周期内只执行一次），并做一次预算淘汰。
    ///
    /// 合并时不覆盖扫描期间已被前台 data(for:)/store 更新过的条目：
    /// - 大小：已存在则保留内存值（前台刚写入的文件更准）；
    /// - 访问时间：取两者较新，避免把前台刚读过的封面标记成旧条目被误淘汰。
    private func applyInitialIndex(_ index: [String: (fileSize: Int64, accessDate: Date)]) {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        for (name, entry) in index {
            sizes[name] = sizes[name] ?? entry.fileSize
            accessedAt[name] = max(accessedAt[name] ?? .distantPast, entry.accessDate)
        }
        evictIfNeeded()
    }

    /// 超过预算时按最近访问时间从旧到新删除，直到降到预算的 80%。
    private func evictIfNeeded() {
        var total = sizes.values.reduce(0, +)
        guard total > budget else { return }
        let target = Int64(Double(budget) * 0.8)
        let ordered = sizes.keys.sorted { (accessedAt[$0] ?? .distantPast) < (accessedAt[$1] ?? .distantPast) }
        for name in ordered {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            total -= sizes[name] ?? 0
            sizes[name] = nil
            accessedAt[name] = nil
        }
    }

    /// 封面 Key 可能含 `/`、`:` 等非法字符，统一散列成定长文件名。
    private static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }
}
