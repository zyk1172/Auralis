#if os(macOS)
import SwiftUI
import ThemeEngine

/// 独立 MiniPlayer 窗口（Window → 迷你播放器）。
/// 完整模式：封面 + 标题/艺术家 + 进度 + 两排控制（含音量±）；
/// Compact（隐藏封面）独立布局，不再复用完整模式 UI，保证 140pt 高度不裁切。
public struct MacMiniPlayerView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @AppStorage("auralis.miniplayer.hideArtwork") private var hideArtwork = false

    @ObservedObject private var playbackStore: PlaybackStore
    @State private var isVolumePopoverPresented = false

    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        self.model = model
        self.theme = themeStore.current
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var hasTrack: Bool { model.hasCurrentTrack }
    private var duration: TimeInterval { max(model.effectivePlaybackDuration, 1) }

    public var body: some View {
        Group {
            if hideArtwork {
                compactPlayer
            } else {
                artworkPlayer
            }
        }
        .background(.regularMaterial)
        .background(MacMiniWindowAttacher(coordinator: .shared))
    }

    // MARK: - 完整模式（封面 + 信息 + 进度 + 两排控制）

    private var artworkPlayer: some View {
        VStack(spacing: MacUIVisualTokens.MiniPlayer.contentSpacing) {
            ArtworkView(
                title: model.currentTrack.albumTitle,
                artworkKey: model.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: MacUIVisualTokens.MiniPlayer.artworkSize,
                cornerRadius: MacUIVisualTokens.MiniPlayer.artworkCornerRadius
            )
            .frame(width: MacUIVisualTokens.MiniPlayer.artworkSize, height: MacUIVisualTokens.MiniPlayer.artworkSize)
            .accessibilityLabel("封面")

            infoBlock

            progressSlider

            // 8 个按钮两排：每排 4 个 + Spacer 均分，每个固定 32×28 hit target。
            VStack(spacing: 9) {
                HStack {
                    previousButton
                    Spacer()
                    playButton
                    Spacer()
                    nextButton
                    Spacer()
                    favoriteButton
                }
                HStack {
                    volumeDownButton
                    Spacer()
                    volumeUpButton
                    Spacer()
                    artworkToggleButton
                    Spacer()
                    returnMainButton
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: MacUIVisualTokens.MiniPlayer.windowWidth, height: MacUIVisualTokens.MiniPlayer.windowHeight)
    }

    // MARK: - Compact 模式（独立布局，不裁切）

    private var compactPlayer: some View {
        VStack(spacing: 8) {
            // 第一行：歌名/歌手 + 显示封面 + 返回主窗口
            HStack(spacing: 8) {
                infoBlock
                Spacer(minLength: 4)
                artworkToggleButton
                returnMainButton
            }
            // 第二行：进度
            progressSlider
            // 第三行：上一首/播放/下一首/收藏/音量（音量 = 单按钮 + popover Slider）
            HStack {
                previousButton
                Spacer()
                playButton
                Spacer()
                nextButton
                Spacer()
                favoriteButton
                Spacer()
                volumeButton
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: MacUIVisualTokens.MiniPlayer.compactWindowWidth, height: MacUIVisualTokens.MiniPlayer.compactWindowHeight)
    }

    // MARK: - 复用子视图

    private var infoBlock: some View {
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
    }

    private var progressSlider: some View {
        MacPlaybackSlider(
            value: playbackStore.position,
            minValue: 0,
            maxValue: duration,
            isEnabled: hasTrack,
            onCommit: { model.seek(toProgress: min(1, max(0, $0 / duration))) }
        )
        .controlSize(.mini)
    }

    private var previousButton: some View {
        Button {
            model.previous()
        } label: {
            Image(systemName: "backward.fill")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .disabled(!model.canGoPrevious)
        .accessibilityLabel("上一首")
    }

    private var playButton: some View {
        Button {
            model.togglePlayback()
        } label: {
            Image(systemName: model.playbackStore.state == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .medium))
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .disabled(!hasTrack)
        .accessibilityLabel("播放 / 暂停")
    }

    private var nextButton: some View {
        Button {
            model.next()
        } label: {
            Image(systemName: "forward.fill")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .disabled(!model.canGoNext)
        .accessibilityLabel("下一首")
    }

    private var favoriteButton: some View {
        Button {
            model.toggleFavorite(model.currentTrack)
        } label: {
            Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .disabled(!hasTrack)
        .accessibilityLabel(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
    }

    /// Compact 专用：单个音量按钮 + popover Slider（不再放音量-/音量+ 两个按钮）。
    private var volumeButton: some View {
        Button {
            isVolumePopoverPresented.toggle()
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help("音量")
        .accessibilityLabel("音量")
        .popover(isPresented: $isVolumePopoverPresented, arrowEdge: .bottom) {
            Slider(
                value: Binding(
                    get: { Double(model.volume) },
                    set: { model.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .frame(width: 120)
            .padding(12)
            .accessibilityLabel("音量")
        }
    }

    private var volumeDownButton: some View {
        Button {
            model.setVolume(max(0, model.volume - 0.05))
        } label: {
            Image(systemName: "speaker.slash")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help("音量 -")
        .accessibilityLabel("音量减小")
    }

    private var volumeUpButton: some View {
        Button {
            model.setVolume(min(1, model.volume + 0.05))
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help("音量 +")
        .accessibilityLabel("音量增加")
    }

    private var artworkToggleButton: some View {
        Button {
            hideArtwork.toggle()
        } label: {
            Image(systemName: hideArtwork ? "rectangle" : "rectangle.fill")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help(hideArtwork ? "显示封面" : "隐藏封面")
        .accessibilityLabel(hideArtwork ? "显示封面" : "隐藏封面")
    }

    private var returnMainButton: some View {
        Button {
            MacWindowVisibilityCoordinator.shared.restoreMainPlayer(expandPlayer: true)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help("返回正在播放")
        .accessibilityLabel("返回正在播放")
    }
}

/// MiniPlayer 窗口注册：把窗口引用交给全局窗口协调器，
/// 使「主窗口 ↔ 迷你播放器」双向切换与 Dock 恢复可以工作。
private struct MacMiniWindowAttacher: NSViewRepresentable {
    let coordinator: MacWindowVisibilityCoordinator

    func makeNSView(context: Context) -> NSView {
        RegistrationView(coordinator: coordinator)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class RegistrationView: NSView {
        let coordinator: MacWindowVisibilityCoordinator

        init(coordinator: MacWindowVisibilityCoordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let currentWindow = window
            let coordinator = coordinator
            // 用 DispatchQueue.main.async 保证下一 RunLoop 注册：
            // registerMiniWindow → completeMiniPresentation → @Published mode
            // 绝不能发生在 SwiftUI view update transaction 内。
            // （Task { @MainActor } 不保证下一 RunLoop，已弃用。）
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    coordinator.registerMiniWindow(currentWindow)
                }
            }
        }
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
