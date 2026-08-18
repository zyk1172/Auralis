import Combine
import Domain
import Foundation
import LocalCatalog

/// 播放队列展示状态：与高频播放状态（PlaybackStore）分离。
///
/// 队列可能包含上万首（如全库双击播放），更新只发布到这里——
/// 普通播放器控件（Floating / Mini / Expanded 主播放区）观察 PlaybackStore，
/// 不再因 queue 变化整体 invalidate。
@MainActor
public final class PlaybackQueuePresentationStore: ObservableObject {
    @Published public var tracks: [Track] = []
    /// 当前曲目在队列中的下标（O(1) 维护，由 AppModel 在队列/当前曲目变化时更新）。
    @Published public var currentIndex: Int?

    /// 队列修订号（O(1)），供需要 diff / 持久化判断的场景使用。
    public private(set) var revision: UInt64 = 0

    public init() {}

    /// 替换整个队列；只有内容实际变化才发布 + revision。
    public func replace(_ newTracks: [Track], currentTrackID: GlobalID?) {
        if tracks != newTracks {
            tracks = newTracks
            revision &+= 1
        }
        updateCurrentIndex(currentTrackID: currentTrackID)
    }

    /// 当前曲目变化时更新下标。
    public func updateCurrentIndex(currentTrackID: GlobalID?) {
        let newIndex: Int?
        if let currentTrackID, let idx = tracks.firstIndex(where: {
            GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue) == currentTrackID
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
