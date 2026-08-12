#if os(macOS)
import SwiftUI
import ThemeEngine

/// 独立 MiniPlayer 窗口（Window → 迷你播放器）。
/// Expanded：封面 + 标题/艺术家 + 进度 + 控制 + 音量；可「隐藏封面」切换 Compact。
public struct MacMiniPlayerView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @AppStorage("auralis.miniplayer.hideArtwork") private var hideArtwork = false

    @ObservedObject private var playbackStore: PlaybackStore
    @State private var isScrubbing = false
    @State private var scrubValue: TimeInterval = 0

    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        self.model = model
        self.theme = themeStore.current
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var hasTrack: Bool { model.hasCurrentTrack }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }

    public var body: some View {
        VStack(spacing: 10) {
            if !hideArtwork {
                ArtworkView(
                    title: model.currentTrack.albumTitle,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: 220,
                    cornerRadius: 12
                )
                .frame(width: 220, height: 220)
                .accessibilityLabel("封面")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(hasTrack ? model.currentTrack.title : "未在播放")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(hasTrack ? model.currentTrack.artistName : "选择歌曲开始播放")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Slider(
                value: Binding(
                    get: { progress },
                    set: { isScrubbing = true; scrubValue = $0 }
                ),
                in: 0...duration,
                onEditingChanged: { editing in
                    if !editing {
                        model.seek(toProgress: scrubValue / duration)
                        isScrubbing = false
                    }
                }
            )
            .controlSize(.mini)
            .disabled(!hasTrack)

            HStack(spacing: 18) {
                Button {
                    model.previous()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoPrevious)
                .accessibilityLabel("上一首")

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.playbackStore.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!hasTrack)
                .accessibilityLabel("播放 / 暂停")

                Button {
                    model.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoNext)
                .accessibilityLabel("下一首")

                Button {
                    model.toggleFavorite(model.currentTrack)
                } label: {
                    Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .disabled(!hasTrack)
                .accessibilityLabel(model.currentTrack.isFavorite ? "取消收藏" : "收藏")

                Button {
                    model.setVolume(min(1, model.volume + 0.05))
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .help("音量 +")
                .accessibilityLabel("音量增加")

                Button {
                    model.setVolume(max(0, model.volume - 0.05))
                } label: {
                    Image(systemName: "speaker.slash")
                }
                .buttonStyle(.plain)
                .help("音量 -")
                .accessibilityLabel("音量减小")

                Button {
                    hideArtwork.toggle()
                } label: {
                    Image(systemName: hideArtwork ? "rectangle" : "rectangle.fill")
                }
                .buttonStyle(.plain)
                .help(hideArtwork ? "显示封面" : "隐藏封面")
                .accessibilityLabel(hideArtwork ? "显示封面" : "隐藏封面")
            }
        }
        .padding(16)
        .frame(width: hideArtwork ? 300 : 252, height: hideArtwork ? 120 : 380)
        .background(.regularMaterial)
    }
}
#endif
