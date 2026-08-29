import Domain
import SwiftUI

/// Presentation shared by the expanded and compact mini players.
///
/// `buffering` and `stalled` still represent a user-requested playback
/// session, so their control remains pause-shaped while the spinner explains
/// why audio is temporarily quiet. `preparing` uses the same loading surface;
/// idle, paused and failed states are actionable play states.
enum PlaybackControlPresentation: Equatable {
    case play
    case pause
    case loading

    init(state: PlaybackState) {
        switch state {
        case .playing:
            self = .pause
        case .preparing, .buffering, .stalled:
            self = .loading
        case .idle, .paused, .failed:
            self = .play
        }
    }

    var systemImage: String {
        self == .pause ? "pause.fill" : "play.fill"
    }

    var isLoading: Bool { self == .loading }

    var accessibilityLabel: String {
        switch self {
        case .play: String(localized: "播放", bundle: .module)
        case .pause: String(localized: "暂停", bundle: .module)
        case .loading: String(localized: "正在加载", bundle: .module)
        }
    }
}

/// Keeps the loading affordance visually consistent without duplicating the
/// state mapping in either mini-player layout.
struct PlaybackControlIndicator: View {
    let presentation: PlaybackControlPresentation
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: presentation.systemImage)
                .font(.system(size: fontSize, weight: .semibold))
                .opacity(presentation.isLoading ? 0.35 : 1)
            if presentation.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            }
        }
        .foregroundStyle(color)
    }
}
