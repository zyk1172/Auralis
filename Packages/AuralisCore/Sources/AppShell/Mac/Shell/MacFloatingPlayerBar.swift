#if os(macOS)
import SwiftUI
import ThemeEngine

/// Apple Music macOS 27 式悬浮播放器（REFERENCE_A）：
/// 只位于 Main Content 上方、水平居中、Liquid Glass 胶囊；不覆盖 Sidebar、不是全宽底部条。
struct MacFloatingPlayerBar: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onOpenFullPlayer: () -> Void = {}
    var onOpenMiniPlayer: () -> Void = {}
    var onToggleLyrics: () -> Void = {}
    var onToggleQueue: () -> Void = {}

    @ObservedObject private var playbackStore: PlaybackStore
    @State private var isScrubbing = false
    @State private var scrubValue: TimeInterval = 0
    @State private var isVolumePopoverPresented = false

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        onOpenFullPlayer: @escaping () -> Void = {},
        onOpenMiniPlayer: @escaping () -> Void = {},
        onToggleLyrics: @escaping () -> Void = {},
        onToggleQueue: @escaping () -> Void = {}
    ) {
        self.model = model
        self.theme = theme
        self.onOpenFullPlayer = onOpenFullPlayer
        self.onOpenMiniPlayer = onOpenMiniPlayer
        self.onToggleLyrics = onToggleLyrics
        self.onToggleQueue = onToggleQueue
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var hasTrack: Bool { model.hasCurrentTrack }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }

    var body: some View {
        GlassControlGroup {
            GeometryReader { geo in
                let sideWidth = min(230, max(180, geo.size.width * 0.23))
                HStack(spacing: 10) {
                    HStack {
                        transportGroup
                        Spacer(minLength: 0)
                    }
                    .frame(width: sideWidth)

                    HStack(spacing: 12) {
                        trackIdentity
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        contextGroup
                    }
                    .frame(width: sideWidth)
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 70)
        }
        .frame(maxWidth: 960)
    }

    // MARK: - Transport（LEFT）

    private var transportGroup: some View {
        HStack(spacing: 14) {
            Button {
                model.setShuffle(!model.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(model.isShuffled ? MacMediaAccent.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(model.isShuffled ? "关闭随机播放" : "随机播放")
            .accessibilityLabel("随机播放")

            Button {
                if hasTrack { model.previous() }
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoPrevious)
            .help("上一首")
            .accessibilityLabel("上一首")

            Button {
                if hasTrack { model.togglePlayback() }
            } label: {
                Image(systemName: model.playbackStore.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help("播放 / 暂停")
            .accessibilityLabel("播放 / 暂停")

            Button {
                if hasTrack { model.next() }
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoNext)
            .help("下一首")
            .accessibilityLabel("下一首")

            Button {
                model.cycleRepeatMode()
            } label: {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(model.repeatMode != .off ? MacMediaAccent.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(repeatHelp)
            .accessibilityLabel(repeatHelp)
        }
    }

    private var repeatHelp: String {
        switch model.repeatMode {
        case .one: "单曲循环"
        case .all: "列表循环"
        case .off: "不循环"
        }
    }

    // MARK: - Track identity（CENTER）

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            Button(action: onOpenFullPlayer) {
                ArtworkView(
                    title: model.currentTrack.albumTitle,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: 44,
                    cornerRadius: 6
                )
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help("全屏播放器")
            .accessibilityLabel("全屏播放器")
            .contextMenu {
                Button("全屏播放器") { onOpenFullPlayer() }
                Button("迷你播放器") { onOpenMiniPlayer() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(hasTrack ? model.currentTrack.title : "未在播放")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(hasTrack ? model.currentTrack.artistName : "选择歌曲开始播放")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
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
                .accessibilityLabel("播放进度")
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    // MARK: - Context（RIGHT）

    private var contextGroup: some View {
        HStack(spacing: 12) {
            Button {
                if hasTrack { model.toggleFavorite(model.currentTrack) }
            } label: {
                Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(model.currentTrack.isFavorite ? MacMediaAccent.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
            .accessibilityLabel(model.currentTrack.isFavorite ? "取消收藏" : "收藏")

            Button(action: onToggleLyrics) {
                Image(systemName: "quote.bubble")
            }
            .buttonStyle(.plain)
            .help("歌词")
            .accessibilityLabel("歌词")

            Button(action: onToggleQueue) {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.plain)
            .help("队列")
            .accessibilityLabel("队列")

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
                    .frame(width: 160)
                    Text("\(Int(model.volume * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            Menu {
                if hasTrack {
                    let disliked = model.isDisliked(model.currentTrack)
                    Button(disliked ? "取消不喜欢" : "不喜欢") {
                        model.setDisliked(model.currentTrack, value: !disliked, source: "player-more")
                    }
                    Button("歌曲信息") {
                        NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: model.currentTrack)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多")
            .disabled(!hasTrack)
        }
    }
}
#endif
