#if os(macOS)
import SwiftUI
import ThemeEngine

/// Apple Music 式底部播放条：transport 组 / 曲目身份组 / 上下文控制组。
/// 高度约 78pt，系统 bar 背景；窄窗口用 ViewThatFits 降级隐藏次要内容。
struct MacPlayerBar: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onOpenNowPlaying: () -> Void = {}
    var onToggleLyrics: () -> Void = {}
    var onToggleQueue: () -> Void = {}

    @ObservedObject private var playbackStore: PlaybackStore
    @State private var isScrubbing = false
    @State private var scrubValue: TimeInterval = 0
    @State private var isVolumePopoverPresented = false

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        onOpenNowPlaying: @escaping () -> Void = {},
        onToggleLyrics: @escaping () -> Void = {},
        onToggleQueue: @escaping () -> Void = {}
    ) {
        self.model = model
        self.theme = theme
        self.onOpenNowPlaying = onOpenNowPlaying
        self.onToggleLyrics = onToggleLyrics
        self.onToggleQueue = onToggleQueue
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var hasTrack: Bool { model.hasCurrentTrack }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                fullLayout
                compactLayout
            }
            .frame(height: MacLayout.playerBarHeight)
        }
        .background(.bar)
    }

    // MARK: - 完整布局

    /// 三区稳定布局：LEFT / CENTER / RIGHT 各占一等宽，CENTER 真正居中。
    private var fullLayout: some View {
        HStack(spacing: 12) {
            HStack {
                transportGroup
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                trackIdentity
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer(minLength: 0)
                contextGroup
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 紧凑布局（窄窗口：隐藏时间文字 / 音量滑杆，保留 transport）

    private var compactLayout: some View {
        HStack(spacing: 12) {
            transportGroup
            Spacer(minLength: 8)
            trackIdentityCompact
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                favoriteButton
                lyricsButton
                queueButton
                volumeButton
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Transport

    private var transportGroup: some View {
        HStack(spacing: 14) {
            Button {
                model.setShuffle(!model.isShuffled)
            } label: {
                Image(systemName: model.isShuffled ? "shuffle" : "shuffle")
                    .foregroundStyle(model.isShuffled ? theme.colorTokens.accent.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(model.isShuffled ? "关闭随机播放" : "随机播放")
            .accessibilityLabel(model.isShuffled ? "关闭随机播放" : "随机播放")

            Button {
                if hasTrack { model.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoPrevious)
            .help("上一首")
            .accessibilityLabel("上一首")

            Button {
                if hasTrack { model.togglePlayback() }
            } label: {
                Image(systemName: model.playbackStore.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help("播放 / 暂停")
            .accessibilityLabel("播放 / 暂停")

            Button {
                if hasTrack { model.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoNext)
            .help("下一首")
            .accessibilityLabel("下一首")

            Button {
                model.cycleRepeatMode()
            } label: {
                Image(systemName: repeatSymbol)
                    .foregroundStyle(repeatActive ? theme.colorTokens.accent.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(repeatHelp)
            .accessibilityLabel(repeatHelp)
        }
    }

    private var repeatSymbol: String {
        switch model.repeatMode {
        case .one: "repeat.1"
        case .all: "repeat"
        case .off: "repeat"
        }
    }

    private var repeatActive: Bool { model.repeatMode != .off }

    private var repeatHelp: String {
        switch model.repeatMode {
        case .one: "单曲循环"
        case .all: "列表循环"
        case .off: "不循环"
        }
    }

    // MARK: - Track identity

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            Button(action: onOpenNowPlaying) {
                HStack(spacing: 10) {
                    ArtworkView(
                        title: model.currentTrack.albumTitle,
                        artworkKey: model.currentTrack.artworkKey,
                        colors: theme.colorTokens,
                        size: 46,
                        cornerRadius: 6
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasTrack ? model.currentTrack.title : "未在播放")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(hasTrack ? model.currentTrack.artistName : "选择歌曲开始播放")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help("打开正在播放")
            .accessibilityLabel("打开正在播放")

            VStack(spacing: 4) {
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
                HStack {
                    Text(MacFormat.time(progress))
                    Spacer()
                    Text("-" + MacFormat.time(max(0, duration - progress)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 200)
            }
            .frame(width: 200)
        }
    }

    private var trackIdentityCompact: some View {
        Button(action: onOpenNowPlaying) {
            HStack(spacing: 8) {
                ArtworkView(
                    title: model.currentTrack.albumTitle,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: 38,
                    cornerRadius: 6
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hasTrack ? model.currentTrack.title : "未在播放")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(hasTrack ? model.currentTrack.artistName : "选择歌曲")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasTrack)
        .help("打开正在播放")
    }

    // MARK: - Context controls

    private var contextGroup: some View {
        HStack(spacing: 14) {
            favoriteButton
            lyricsButton
            queueButton
            volumeButton
        }
    }

    private var favoriteButton: some View {
        Button {
            if hasTrack { model.toggleFavorite(model.currentTrack) }
        } label: {
            Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(model.currentTrack.isFavorite ? theme.colorTokens.accent.color : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!hasTrack)
        .help(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
        .accessibilityLabel(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
    }

    private var lyricsButton: some View {
        Button(action: onToggleLyrics) {
            Image(systemName: "quote.bubble")
        }
        .buttonStyle(.plain)
        .help("歌词")
        .accessibilityLabel("歌词")
    }

    private var queueButton: some View {
        Button(action: onToggleQueue) {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(.plain)
        .help("队列")
        .accessibilityLabel("队列")
    }

    private var volumeButton: some View {
        Button {
            isVolumePopoverPresented.toggle()
        } label: {
            Image(systemName: model.volume < 0.02 ? "speaker.slash" : "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .help("音量")
        .accessibilityLabel("音量")
        .popover(isPresented: $isVolumePopoverPresented, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { model.volume },
                    set: { model.setVolume($0) }
                ), in: 0...1)
                .frame(width: 180)
                Text("\(Int(model.volume * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }
}
#endif
