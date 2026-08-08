import Domain
import Foundation

public struct CacheEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: TrackID
    public var byteCount: Int64
    public var lastAccessedAt: Date
    public var isPinned: Bool

    public init(id: TrackID, byteCount: Int64, lastAccessedAt: Date, isPinned: Bool = false) {
        self.id = id
        self.byteCount = byteCount
        self.lastAccessedAt = lastAccessedAt
        self.isPinned = isPinned
    }
}

public enum CacheEvictionPolicy {
    public static func evictions(entries: [CacheEntry], currentBytes: Int64, targetBytes: Int64) -> [CacheEntry] {
        guard currentBytes > targetBytes else { return [] }
        var bytesToFree = currentBytes - targetBytes
        var selected: [CacheEntry] = []
        for entry in entries.filter({ !$0.isPinned }).sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            selected.append(entry)
            bytesToFree -= entry.byteCount
            if bytesToFree <= 0 { break }
        }
        return selected
    }
}

public actor DownloadStateStore {
    private var records: [TrackID: DownloadRecord] = [:]
    public init() {}
    public func update(_ record: DownloadRecord) { records[record.trackID] = record }
    public func record(for trackID: TrackID) -> DownloadRecord? { records[trackID] }
    public func all() -> [DownloadRecord] { Array(records.values) }
}
