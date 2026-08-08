import ActivityKit
import Domain
import SwiftUI
import WidgetKit

@main
struct AuralisLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AuralisPlaybackLiveActivity()
        AuralisNowPlayingWidget()
    }
}

/// 播放中的 Live Activity（灵动岛 + 锁屏实时活动）。
/// 仅展示歌曲名称 / 艺术家 / 进度 / 播放状态，不含服务器地址、凭据或文件路径。
struct AuralisPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLiveActivityView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(
                        value: context.state.duration > 0
                            ? min(max(context.state.position / context.state.duration, 0), 1)
                            : 0
                    )
                    .tint(.white)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}

/// 锁屏 / 灵动岛展开的内容视图（文本 + 进度，不联网取封面，避免跨进程凭据）。
struct PlaybackLiveActivityView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [.accentColor, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
        }
        .padding()
    }
}
