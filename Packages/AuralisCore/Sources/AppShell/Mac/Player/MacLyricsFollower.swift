#if os(macOS)
import Combine
import Domain
import Foundation

/// 将高频播放位置转换成低频歌词状态。
///
/// PlaybackStore 仍然可以每 0.5 秒更新位置，但歌词界面只在 activeIndex
/// 真正变化时收到发布。时间轴先缓存为有序数组，再用二分查找定位当前行，
/// 避免把进度时钟直接绑定到歌词列表的 SwiftUI 重绘。
@MainActor
final class MacLyricsFollower: ObservableObject {
    @Published private(set) var activeIndex: Int?

    private let playbackStore: PlaybackStore
    private var positionCancellable: AnyCancellable?
    private var boundLyricsID: TrackID?
    private var timeline: [LyricsIndexResolver.TimedLine] = []
    private var leadTime: TimeInterval = 0

    init(playbackStore: PlaybackStore) {
        self.playbackStore = playbackStore
    }

    func bind(lyrics: LyricsDocument, leadTime: TimeInterval = 0.15) {
        guard boundLyricsID != lyrics.id || self.leadTime != leadTime else { return }

        boundLyricsID = lyrics.id
        self.leadTime = leadTime
        timeline = LyricsIndexResolver.timeline(for: lyrics.lines)
        activeIndex = LyricsIndexResolver.index(at: playbackStore.position, in: timeline, leadTime: leadTime)

        positionCancellable?.cancel()
        let boundTimeline = timeline
        let boundLeadTime = leadTime
        positionCancellable = playbackStore.$position
            .map { position in
                LyricsIndexResolver.index(at: position, in: boundTimeline, leadTime: boundLeadTime)
            }
            .removeDuplicates()
            .sink { [weak self] index in
                self?.activeIndex = index
            }
    }

    func reset() {
        positionCancellable?.cancel()
        positionCancellable = nil
        boundLyricsID = nil
        timeline = []
        activeIndex = nil
    }

}
#endif
