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
@MainActor
public final class PlaybackQueuePresentationStore: ObservableObject {
    @Published public var entries: [QueueEntry] = []
    /// 当前曲目在队列中的下标（O(1) 维护，由 AppModel 在队列/当前曲目变化时更新）。
    @Published public var currentIndex: Int?
    /// 当前队列项身份（R05）：currentIndex 的权威来源。队列推进（next / previous /
    /// 自动 advance）与显式播放队列项都直接设置它，**绝不从歌曲 TrackID 反推**——
    /// 否则 [A, B, A] 中播放第二个 A 时，currentIndex 会回退到第一个 A，
    /// 导致下一首/Upcoming/删除后续/shuffle 全部围绕错误下标计算。
    @Published public private(set) var currentEntryID: UUID?

    /// 队列修订号（O(1)），供需要 diff / 持久化判断的场景使用。
    public private(set) var revision: UInt64 = 0

    public init() {}

    /// 兼容读取：队列中的歌曲数组（含重复项，顺序与 entries 一致）。
    public var tracks: [Track] { entries.map(\.track) }

    public var currentTrack: Track? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex].track
    }

    /// 替换整个队列（每首新 entry，独立 UUID；允许重复歌曲）。
    /// 只有内容实际变化才发布 + revision。
    public func replace(_ newTracks: [Track], currentTrackID: GlobalID?) {
        replace(entries: newTracks.map { QueueEntry(track: $0) }, currentTrackID: currentTrackID)
    }

    /// 用已有 entry（保留 UUID，恢复会话时用）替换整个队列。
    public func replace(entries newEntries: [QueueEntry], currentTrackID: GlobalID?) {
        if entries != newEntries {
            entries = newEntries
            revision &+= 1
        }
        updateCurrentIndex(currentTrackID: currentTrackID)
    }

    /// 追加歌曲到队尾（每首新 entry；重复歌曲成为独立队列项）。
    public func append(_ newTracks: [Track], currentTrackID: GlobalID?) {
        guard !newTracks.isEmpty else { return }
        entries.append(contentsOf: newTracks.map { QueueEntry(track: $0) })
        revision &+= 1
        updateCurrentIndex(currentTrackID: currentTrackID)
    }

    /// 下一首播放：插入到当前曲目之后（新 entry，不移除已存在的同名歌曲）。
    public func playNext(_ track: Track, currentTrackID: GlobalID?) {
        let insertion = min((currentIndex ?? -1) + 1, entries.count)
        entries.insert(QueueEntry(track: track), at: insertion)
        revision &+= 1
        updateCurrentIndex(currentTrackID: currentTrackID)
    }

    /// 按队列项 id 移除（重复歌曲只移除指定那一项）。
    @discardableResult
    public func remove(entryID: UUID, currentTrackID: GlobalID?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        entries.remove(at: index)
        revision &+= 1
        updateCurrentIndex(currentTrackID: currentTrackID)
        return true
    }

    /// 移除指定下标起的所有后续项（清空待播队列，保留当前曲目）。
    public func removeUpcoming(from index: Int, currentTrackID: GlobalID?) {
        guard index + 1 < entries.count else { return }
        entries.removeSubrange((index + 1)...)
        revision &+= 1
        updateCurrentIndex(currentTrackID: currentTrackID)
    }

    /// 移动 entries（SwiftUI onMove；按 entry id 移动，重复歌曲互不干扰）。
    public func move(from offsets: IndexSet, to destination: Int, currentTrackID: GlobalID?) {
        let moving = offsets.sorted().compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        entries.removeAll { movingIDs.contains($0.id) }
        let insertion = min(max(0, destination - offsets.filter { $0 < destination }.count), entries.count)
        entries.insert(contentsOf: moving, at: insertion)
        revision &+= 1
        updateCurrentIndex(currentTrackID: currentTrackID)
    }

    // MARK: - 当前项定位（R05：index-based）

    /// 播放队列中的指定项（用户点击队列、列表循环绕回等）。
    /// 以队列项 UUID 定位；找不到返回 nil（调用方自行处理）。
    @discardableResult
    public func play(entryID: UUID) -> Track? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        setCurrent(entryID: entryID, index: index)
        return entries[index].track
    }

    /// 队列推进到下一首（next / 自动 advance）。返回新队列项曲目；
    /// 物理越界返回 nil（循环绕回由调用方处理）。
    public func advanceForward() -> Track? {
        guard let currentIndex, entries.indices.contains(currentIndex + 1) else { return nil }
        let index = currentIndex + 1
        setCurrent(entryID: entries[index].id, index: index)
        return entries[index].track
    }

    /// 队列回退到上一首（previous）。物理越界返回 nil。
    public func advanceBackward() -> Track? {
        guard let currentIndex, entries.indices.contains(currentIndex - 1) else { return nil }
        let index = currentIndex - 1
        setCurrent(entryID: entries[index].id, index: index)
        return entries[index].track
    }

    /// 当前曲目变化时维护下标（R05）：
    /// - `currentEntryID` 仍指向 entries 中同一首歌（next/advance 已显式推进）→ 保持不变；
    /// - `currentEntryID` 失效或指向不同歌曲（外部直接换歌 / 队列被整体替换）→
    ///   回退按 GlobalID 匹配第一个（显式点歌的合理语义）；
    /// - 匹配不到 → 置空。
    public func updateCurrentIndex(currentTrackID: GlobalID?) {
        if let currentEntryID,
           let idx = entries.firstIndex(where: { $0.id == currentEntryID }),
           let currentTrackID,
           GlobalID(serverID: entries[idx].track.serverID, remoteID: entries[idx].track.id.rawValue) == currentTrackID {
            setCurrent(entryID: currentEntryID, index: idx)
            return
        }
        if let currentTrackID,
           let idx = entries.firstIndex(where: {
               GlobalID(serverID: $0.track.serverID, remoteID: $0.track.id.rawValue) == currentTrackID
           }) {
            setCurrent(entryID: entries[idx].id, index: idx)
        } else {
            setCurrent(entryID: nil, index: nil)
        }
    }

    private func setCurrent(entryID: UUID?, index: Int?) {
        if currentEntryID != entryID { currentEntryID = entryID }
        if currentIndex != index { currentIndex = index }
    }
}