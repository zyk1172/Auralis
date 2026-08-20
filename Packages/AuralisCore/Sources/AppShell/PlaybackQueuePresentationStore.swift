import Combine
import Domain
import Foundation
import LocalCatalog

/// 播放队列展示状态：与高频播放状态（PlaybackStore）分离。
///
/// 队列可能包含上万首（如全库双击播放），更新只发布到这里——
/// 普通播放器控件（Floating / Mini / Expanded 主播放区）观察 PlaybackStore，
/// 不再因 queue 变化整体 invalidate。
///
/// R05：队列项身份是 `QueueEntry.id`（UUID），与歌曲身份（Track）分离。
/// 同一首歌允许出现多次，每次都是独立队列项；currentIndex 定位的是队列项下标，
/// 而不是按歌曲 ID 匹配。
///
/// 性能约束（P0）：队列规模可达 10000+，所有变更必须避免在 MainActor 上做
/// O(N) 的 Track 复制 / QueueEntry 创建 / UUID 生成。重活由 `PreparedQueue.prepare`
/// 在后台线程一次性完成（去重 + entry 创建 + selected index + persistence ID），
/// MainActor 只调用 `installPreparedQueue(_:)` 安装已经准备好的结果。
/// 队列内容访问（count / first / index / contains）全部走 O(1) 或轻量扫描，
/// 不得触发 `tracks`（完整 [Track] 快照）。
@MainActor
public final class PlaybackQueuePresentationStore: ObservableObject {
    /// 队列项（带独立 UUID 身份）。`private(set)`：外部只读，写入统一走 Store 方法，
    /// 每次**逻辑变更**只 `objectWillChange.send()` 一次（不再用 @Published 逐属性发布）。
    public private(set) var entries: [QueueEntry] = []
    /// 当前曲目在队列中的下标（O(1) 维护，由 AppModel 在队列/当前曲目变化时更新）。
    public private(set) var currentIndex: Int?
    /// 当前队列项身份（R05）：currentIndex 的权威来源。队列推进（next / previous /
    /// 自动 advance）与显式播放队列项都直接设置它，**绝不从歌曲 TrackID 反推**——
    /// 否则 [A, B, A] 中播放第二个 A 时，currentIndex 会回退到第一个 A，
    /// 导致下一首/Upcoming/删除后续/shuffle 全部围绕错误下标计算。
    public private(set) var currentEntryID: UUID?

    /// 队列修订号（O(1)），供需要 diff / 持久化判断的场景使用。
    public private(set) var revision: UInt64 = 0

    /// 持久化用 track id 快照（与 entries 一一对应，按顺序）。
    /// 播放会话持久化直接读取，禁止再 `entries.map(\.track.id.rawValue)`。
    public private(set) var persistenceTrackIDs: [String] = []

    public init() {}

    // MARK: - O(1) / 轻量访问（禁止在播放热路径使用 `tracks`）

    /// 队列项数（O(1)）。播放热路径取 count 必须用这里，不得走 `tracks`。
    public var count: Int { entries.count }

    public var isEmpty: Bool { entries.isEmpty }

    public var firstTrack: Track? { entries.first?.track }

    public var lastTrack: Track? { entries.last?.track }

    /// O(1) 下标访问，越界返回 nil。
    public func track(at index: Int) -> Track? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index].track
    }

    /// 按 GlobalID 判断队列是否包含某首歌（O(N)，但只比较 entry，不复制 Track）。
    /// 不得先 `entries.map(\.track)` 再 contains。
    public func contains(globalID: GlobalID) -> Bool {
        entries.contains {
            GlobalID(serverID: $0.track.serverID, remoteID: $0.track.id.rawValue) == globalID
        }
    }

    /// 当前曲目之后（含无当前项时的全部）的队列项切片——返回 `ArraySlice`，
    /// 不复制；SwiftUI `ForEach` 可直接消费其中 Identifiable 的 `QueueEntry`。
    public func entries(after index: Int?) -> ArraySlice<QueueEntry> {
        guard let index else { return entries[...] }
        let start = min(index + 1, entries.endIndex)
        return entries[start...]
    }

    /// 兼容读取：队列中的歌曲数组（含重复项，顺序与 entries 一致）。
    /// ⚠️ 完整数组快照，会创建 [Track]（10000 首时成本可观）。
    /// 仅用于「确实需要完整数组」的兼容场景；播放热路径（count / first /
    /// index / contains / next / persistence）禁止使用，改用上面的 O(1) API。
    public var tracks: [Track] { entries.map(\.track) }

    public var currentTrack: Track? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex].track
    }

    // MARK: - 单次发布变更

    /// 每次**逻辑变更**只触发一次 `objectWillChange`：先发布，再执行实际 mutation。
    /// 私有 helper（`updateCurrentIndexImpl` / `setCurrentImpl`）不自行发布，
    /// 由调用它们的公共方法统一在本闭包内执行。
    @inline(__always)
    private func mutate(_ block: () -> Void) {
        objectWillChange.send()
        block()
        #if DEBUG
        // 队列项与持久化 ID 必须逐项对齐，否则会话恢复会错位。
        assert(entries.count == persistenceTrackIDs.count, "entries/persistenceTrackIDs count drift: \(entries.count) vs \(persistenceTrackIDs.count)")
        #endif
    }

    // MARK: - 后台预构建队列

    /// 已在后台构建完成的队列快照（去重 + QueueEntry + currentIndex + persistence IDs）。
    /// `Sendable`：可在 detached 任务间传递；安装时只做赋值，不再扫描。
    public struct PreparedQueue: Sendable {
        public let entries: [QueueEntry]
        public let currentIndex: Int?
        public let currentEntryID: UUID?
        public let persistenceTrackIDs: [String]

        public init(
            entries: [QueueEntry],
            currentIndex: Int?,
            currentEntryID: UUID?,
            persistenceTrackIDs: [String]
        ) {
            self.entries = entries
            self.currentIndex = currentIndex
            self.currentEntryID = currentEntryID
            self.persistenceTrackIDs = persistenceTrackIDs
        }
    }

    /// 纯函数：在后台一次性完成「去重 → QueueEntry 创建 → selected index 定位
    /// → persistence ID 快照」。不得在 MainActor 调用。
    ///
    /// 单趟实现：`CatalogEntityUniquing.uniquedTracks` 会额外产生一份中间 [Track]，
    /// 这里直接融合去重进同一循环，避免第二份 10000 Track 临时数组。
    public nonisolated static func prepare(
        tracks: [Track],
        selectedTrackID: GlobalID
    ) -> PreparedQueue {
        var entries: [QueueEntry] = []
        entries.reserveCapacity(tracks.count)

        var persistenceTrackIDs: [String] = []
        persistenceTrackIDs.reserveCapacity(tracks.count)

        var seen = Set<GlobalID>()
        var selectedIndex: Int?

        for track in tracks {
            let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            guard seen.insert(gid).inserted else { continue }

            let index = entries.count
            let entry = QueueEntry(track: track)
            entries.append(entry)
            persistenceTrackIDs.append(track.id.rawValue)

            if selectedIndex == nil, gid == selectedTrackID {
                selectedIndex = index
            }
        }

        let entryID = selectedIndex.flatMap {
            entries.indices.contains($0) ? entries[$0].id : nil
        }

        return PreparedQueue(
            entries: entries,
            currentIndex: selectedIndex,
            currentEntryID: entryID,
            persistenceTrackIDs: persistenceTrackIDs
        )
    }

    /// 安装后台预构建的队列：MainActor 只做赋值，不再 map / firstIndex / contains /
    /// 生成 UUID / 构建 persistence ID。一次 `objectWillChange`。
    public func installPreparedQueue(_ prepared: PreparedQueue) {
        mutate {
            entries = prepared.entries
            persistenceTrackIDs = prepared.persistenceTrackIDs
            currentIndex = prepared.currentIndex
            currentEntryID = prepared.currentEntryID
            revision &+= 1
        }
    }

    // MARK: - 队列变更

    /// 替换整个队列（每首新 entry，独立 UUID；允许重复歌曲）。
    /// 只有内容实际变化才发布 + revision。
    public func replace(_ newTracks: [Track], currentTrackID: GlobalID?) {
        replace(entries: newTracks.map { QueueEntry(track: $0) }, currentTrackID: currentTrackID)
    }

    /// 用已有 entry（保留 UUID，恢复会话时用）替换整个队列。
    public func replace(entries newEntries: [QueueEntry], currentTrackID: GlobalID?) {
        mutate {
            if entries != newEntries {
                entries = newEntries
                persistenceTrackIDs = newEntries.map { $0.track.id.rawValue }
                revision &+= 1
            }
            updateCurrentIndexImpl(currentTrackID: currentTrackID)
        }
    }

    /// 追加歌曲到队尾（每首新 entry；重复歌曲成为独立队列项）。
    public func append(_ newTracks: [Track], currentTrackID: GlobalID?) {
        guard !newTracks.isEmpty else { return }
        mutate {
            entries.append(contentsOf: newTracks.map { QueueEntry(track: $0) })
            persistenceTrackIDs.append(contentsOf: newTracks.map { $0.id.rawValue })
            revision &+= 1
            updateCurrentIndexImpl(currentTrackID: currentTrackID)
        }
    }

    /// 下一首播放：插入到当前曲目之后（新 entry，不移除已存在的同名歌曲）。
    public func playNext(_ track: Track, currentTrackID: GlobalID?) {
        mutate {
            let insertion = min((currentIndex ?? -1) + 1, entries.count)
            let entry = QueueEntry(track: track)
            entries.insert(entry, at: insertion)
            persistenceTrackIDs.insert(track.id.rawValue, at: insertion)
            revision &+= 1
            updateCurrentIndexImpl(currentTrackID: currentTrackID)
        }
    }

    /// 单曲插入到队首（selectAndPlay 在大队列尚未安装时的临时占位）。
    /// 若插入的恰好是当前播放歌曲，直接定位到 index 0，避免 firstIndex 全队列扫描。
    public func insertAtFront(_ track: Track, currentTrackID: GlobalID?) {
        mutate {
            let entry = QueueEntry(track: track)
            entries.insert(entry, at: 0)
            persistenceTrackIDs.insert(track.id.rawValue, at: 0)
            revision &+= 1
            let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            if currentTrackID == gid {
                currentIndex = 0
                currentEntryID = entry.id
            } else {
                updateCurrentIndexImpl(currentTrackID: currentTrackID)
            }
        }
    }

    /// 按队列项 id 移除（重复歌曲只移除指定那一项）。
    @discardableResult
    public func remove(entryID: UUID, currentTrackID: GlobalID?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        mutate {
            entries.remove(at: index)
            persistenceTrackIDs.remove(at: index)
            revision &+= 1
            updateCurrentIndexImpl(currentTrackID: currentTrackID)
        }
        return true
    }

    /// 移除指定下标起的所有后续项（清空待播队列，保留当前曲目）。
    public func removeUpcoming(from index: Int, currentTrackID: GlobalID?) {
        guard index + 1 < entries.count else { return }
        mutate {
            entries.removeSubrange((index + 1)...)
            persistenceTrackIDs.removeSubrange((index + 1)...)
            revision &+= 1
            updateCurrentIndexImpl(currentTrackID: currentTrackID)
        }
    }

    /// 移动 entries（SwiftUI onMove；按 entry id 移动，重复歌曲互不干扰）。
    public func move(from offsets: IndexSet, to destination: Int, currentTrackID: GlobalID?) {
        let moving = offsets.sorted().compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        // 同步迁移 persistence IDs，保持与 entries 逐项对齐。
        let movingTrackIDs = offsets.sorted().compactMap {
            entries.indices.contains($0) ? persistenceTrackIDs[$0] : nil
        }
        mutate {
            entries.removeAll { movingIDs.contains($0.id) }
            persistenceTrackIDs.removeAll { movingTrackIDs.contains($0) }
            let insertion = min(max(0, destination - offsets.filter { $0 < destination }.count), entries.count)
            entries.insert(contentsOf: moving, at: insertion)
            persistenceTrackIDs.insert(contentsOf: movingTrackIDs, at: insertion)
            revision &+= 1
            updateCurrentIndexImpl(currentTrackID: currentTrackID)
        }
    }

    // MARK: - 当前项定位（R05：index-based）

    /// 播放队列中的指定项（用户点击队列、列表循环绕回等）。
    /// 以队列项 UUID 定位；找不到返回 nil（调用方自行处理）。
    @discardableResult
    public func play(entryID: UUID) -> Track? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        mutate { setCurrentImpl(entryID: entryID, index: index) }
        return entries[index].track
    }

    /// 队列推进到下一首（next / 自动 advance）。返回新队列项曲目；
    /// 物理越界返回 nil（循环绕回由调用方处理）。
    public func advanceForward() -> Track? {
        guard let currentIndex, entries.indices.contains(currentIndex + 1) else { return nil }
        let index = currentIndex + 1
        mutate { setCurrentImpl(entryID: entries[index].id, index: index) }
        return entries[index].track
    }

    /// 队列回退到上一首（previous）。物理越界返回 nil。
    public func advanceBackward() -> Track? {
        guard let currentIndex, entries.indices.contains(currentIndex - 1) else { return nil }
        let index = currentIndex - 1
        mutate { setCurrentImpl(entryID: entries[index].id, index: index) }
        return entries[index].track
    }

    /// 当前曲目变化时维护下标（R05）：
    /// - `currentEntryID` 仍指向 entries 中同一首歌（next/advance 已显式推进）→ 保持不变；
    /// - `currentEntryID` 失效或指向不同歌曲（外部直接换歌 / 队列被整体替换）→
    ///   回退按 GlobalID 匹配第一个（显式点歌的合理语义）；
    /// - 匹配不到 → 置空。
    public func updateCurrentIndex(currentTrackID: GlobalID?) {
        mutate { updateCurrentIndexImpl(currentTrackID: currentTrackID) }
    }

    private func updateCurrentIndexImpl(currentTrackID: GlobalID?) {
        if let currentEntryID,
           let idx = entries.firstIndex(where: { $0.id == currentEntryID }),
           let currentTrackID,
           GlobalID(serverID: entries[idx].track.serverID, remoteID: entries[idx].track.id.rawValue) == currentTrackID {
            setCurrentImpl(entryID: currentEntryID, index: idx)
            return
        }
        if let currentTrackID,
           let idx = entries.firstIndex(where: {
               GlobalID(serverID: $0.track.serverID, remoteID: $0.track.id.rawValue) == currentTrackID
           }) {
            setCurrentImpl(entryID: entries[idx].id, index: idx)
        } else {
            setCurrentImpl(entryID: nil, index: nil)
        }
    }

    private func setCurrentImpl(entryID: UUID?, index: Int?) {
        currentEntryID = entryID
        currentIndex = index
    }
}
