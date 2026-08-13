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
        MacGlassCapsule {
            GeometryReader { geo in
                let sideWidth = min(MacUIVisualTokens.FloatingPlayer.sideMaxWidth, max(MacUIVisualTokens.FloatingPlayer.sideMinWidth, geo.size.width * 0.23))
                HStack(spacing: MacUIVisualTokens.FloatingPlayer.sectionSpacing) {
                    HStack {
                        transportGroup
                        Spacer(minLength: 0)
                    }
                    .frame(width: sideWidth)

                    HStack(spacing: MacUIVisualTokens.FloatingPlayer.identitySpacing) {
                        trackIdentity
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        contextGroup
                    }
                    .frame(width: sideWidth)
                }
                .padding(.horizontal, MacUIVisualTokens.FloatingPlayer.innerHorizontalPadding)
            }
            .frame(height: MacUIVisualTokens.FloatingPlayer.height)
        }
        .frame(maxWidth: MacUIVisualTokens.FloatingPlayer.maxWidth)
        // 注意：不要在这里给整条胶囊挂 .onTapGesture —— macOS 上祖先 TapGesture
        // 会与内部 Button/Menu/Slider 的命中测试冲突，导致循环/随机/切歌按钮偶发点不动。
        // “点击身份区展开播放器”已收敛到 trackIdentity 内的按钮（见下方）。
    }

    // MARK: - Transport（LEFT）

    private var transportGroup: some View {
        HStack(spacing: MacUIVisualTokens.FloatingPlayer.controlSpacing) {
            Button {
                model.setShuffle(!model.isShuffled)
                MacUITrace.action("toggleShuffle", "enabled=\(model.isShuffled)")
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
                MacUITrace.action("cycleRepeat", "mode=\(model.repeatMode.rawValue)")
            } label: {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(model.repeatMode != .off ? MacMediaAccent.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(repeatHelp)
            .accessibilityLabel("循环模式")
            .accessibilityValue(repeatHelp)
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
                    size: MacUIVisualTokens.FloatingPlayer.artworkSize,
                    cornerRadius: MacUIVisualTokens.FloatingPlayer.artworkCornerRadius
                )
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
            .help("展开播放器")
            .accessibilityLabel("展开播放器")
            .contextMenu {
                Button("展开播放器") { onOpenFullPlayer() }
                Button("迷你播放器") { onOpenMiniPlayer() }
            }

            // 标题 / 艺术家：点击展开播放器（Apple Music 同款交互）。
            // 文本单独成 Button，避免整条 capsule 的 TapGesture 干扰旁边的传输控制按钮。
            VStack(alignment: .leading, spacing: 2) {
                Button(action: onOpenFullPlayer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasTrack ? model.currentTrack.title : "未在播放")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(hasTrack ? model.currentTrack.artistName : "选择歌曲开始播放")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasTrack)
                .help("展开播放器")
                .accessibilityLabel("展开播放器")

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
            .frame(maxWidth: MacUIVisualTokens.FloatingPlayer.titleMaxWidth, alignment: .leading)
        }
    }

    // MARK: - Context（RIGHT）

    private var contextGroup: some View {
        HStack(spacing: MacUIVisualTokens.FloatingPlayer.contextSpacing) {
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
                VStack(spacing: MacUIVisualTokens.FloatingPlayer.volumePopoverContentSpacing) {
                    Slider(value: Binding(
                        get: { model.volume },
                        set: { model.setVolume($0) }
                    ), in: 0...1)
                    .frame(width: MacUIVisualTokens.FloatingPlayer.volumePopoverWidth)
                    Text("\(Int(model.volume * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(MacUIVisualTokens.FloatingPlayer.volumePopoverPadding)
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
