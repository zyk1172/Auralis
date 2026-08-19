import Domain
import Foundation
import LocalCatalog

/// apply() 派生任务的纯计算结果：完全 Sendable，可在非主线程后台构建。
struct LibraryDerivedSnapshot: Sendable {
    let tracker: LibraryAddedTracker
    let addedDatesChanged: Bool
    let randomTracks: [Track]
}

/// 大资料库 apply 派生构建器：library-added 对齐 + 随机音乐采样。
/// 全部为纯函数计算（不触碰任何 MainActor 状态），调用方负责在主线程应用结果。
/// 这样大库的 O(N) 遍历/采样不再阻塞首屏之后的 UI 主执行器。
enum LibraryDerivedBuilder {
    static func build(
        tracks: [Track],
        serverID: ServerID,
        dislikedTrackIDs: Set<GlobalID>,
        tracker: LibraryAddedTracker,
        now: Date = .now
    ) -> LibraryDerivedSnapshot {
        var tracker = tracker
        let addedDatesChanged = tracker.reconcile(tracks: tracks, serverID: serverID, now: now)
        // 随机音乐：从资料库随机采样（排除「不喜欢」），采样一次后保持稳定，
        // 避免界面频繁重排；换一批由 regenerateRandomMusic 另行触发。
        let randomTracks = Array(tracks
            .filter { track in
                !dislikedTrackIDs.contains(GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
            }
            .shuffled()
            .prefix(18))
        return LibraryDerivedSnapshot(
            tracker: tracker,
            addedDatesChanged: addedDatesChanged,
            randomTracks: randomTracks
        )
    }
}