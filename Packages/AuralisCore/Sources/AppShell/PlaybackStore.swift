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
    @Published public var queue: [Track]

    public init(
        currentTrack: Track,
        state: PlaybackState = .paused,
        position: TimeInterval = 0,
        queue: [Track] = []
    ) {
        self.currentTrack = currentTrack
        self.state = state
        self.position = position
        self.queue = queue
    }
}
