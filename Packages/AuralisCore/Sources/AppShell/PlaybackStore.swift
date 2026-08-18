import Combine
import Domain
import Foundation

/// High-frequency playback presentation state.
///
/// Keeping the half-second position tick outside `AuralisAppModel` prevents
/// every screen observing the global model from being invalidated while a song
/// is playing. Views that render elapsed time observe this store directly.
@MainActor
public final class PlaybackStore: ObservableObject {
    @Published public var currentTrack: Track
    @Published public var state: PlaybackState
    @Published public var position: TimeInterval
    // 队列已拆到 PlaybackQueuePresentationStore：上万首队列更新不再让
    // 所有观察本 store 的播放器控件一起 invalidate。

    public init(
        currentTrack: Track,
        state: PlaybackState = .paused,
        position: TimeInterval = 0
    ) {
        self.currentTrack = currentTrack
        self.state = state
        self.position = position
    }
}
