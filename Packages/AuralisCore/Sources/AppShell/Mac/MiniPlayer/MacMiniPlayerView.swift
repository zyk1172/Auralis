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
    private var duration: TimeInterval { max(model.effectivePlaybackDuration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }

    public var body: some View {
        VStack(spacing: MacUIVisualTokens.MiniPlayer.contentSpacing) {
            if !hideArtwork {
                ArtworkView(
                    title: model.currentTrack.albumTitle,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: MacUIVisualTokens.MiniPlayer.artworkSize,
                    cornerRadius: MacUIVisualTokens.MiniPlayer.artworkCornerRadius
                )
                .frame(width: MacUIVisualTokens.MiniPlayer.artworkSize, height: MacUIVisualTokens.MiniPlayer.artworkSize)
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

            HStack(spacing: MacUIVisualTokens.MiniPlayer.controlSpacing) {
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
        .frame(width: hideArtwork ? MacUIVisualTokens.MiniPlayer.compactWindowWidth : MacUIVisualTokens.MiniPlayer.windowWidth, height: hideArtwork ? MacUIVisualTokens.MiniPlayer.compactWindowHeight : MacUIVisualTokens.MiniPlayer.windowHeight)
        .background(.regularMaterial)
    }
}
// MARK: - 窗口场景包装（注入共享环境）

/// 迷你播放器窗口内容：注入 artworkStore / themeStore 环境。
public struct MacMiniPlayerWindow: View {
    @ObservedObject public var themeStore: ThemeStore
    public init(themeStore: ThemeStore) {
        self.themeStore = themeStore
    }
    public var body: some View {
        MacMiniPlayerView(model: .shared, themeStore: themeStore)
            .environment(\.artworkStore, AuralisAppModel.shared.artworkStore)
            .environmentObject(themeStore)
            .tint(themeStore.current.colorTokens.accent.color)
            .preferredColorScheme(themeStore.current.colorScheme)
    }
}
#endif
