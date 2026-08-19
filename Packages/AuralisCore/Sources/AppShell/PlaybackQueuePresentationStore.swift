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

    /// 当前曲目变化时更新下标（按 GlobalID 匹配歌曲；重复歌曲取第一个匹配）。
    public func updateCurrentIndex(currentTrackID: GlobalID?) {
        let newIndex: Int?
        if let currentTrackID, let idx = entries.firstIndex(where: {
            GlobalID(serverID: $0.track.serverID, remoteID: $0.track.id.rawValue) == currentTrackID
        }) {
            newIndex = idx
        } else {
            newIndex = nil
        }
        if currentIndex != newIndex {
            currentIndex = newIndex
        }
    }
}
