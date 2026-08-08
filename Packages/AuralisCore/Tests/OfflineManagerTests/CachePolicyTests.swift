import Domain
import Foundation
import OfflineManager
import Testing

@Test("Cache eviction skips pinned downloads and removes oldest entries first")
func cacheEviction() {
    let entries = [
        CacheEntry(id: "old", byteCount: 40, lastAccessedAt: Date(timeIntervalSince1970: 1)),
        CacheEntry(id: "pinned", byteCount: 80, lastAccessedAt: Date(timeIntervalSince1970: 0), isPinned: true),
        CacheEntry(id: "new", byteCount: 50, lastAccessedAt: Date(timeIntervalSince1970: 2)),
    ]
    let selected = CacheEvictionPolicy.evictions(entries: entries, currentBytes: 170, targetBytes: 120)
    #expect(selected.map(\.id) == ["old", "new"])
    #expect(!selected.contains { $0.id == "pinned" })
}
