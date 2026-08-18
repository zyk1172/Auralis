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

            // 8 个按钮两排排布：220pt 控制区塞不下单排 8 个按钮（会裁切），
            // 每排 4 个 + Spacer 均分，每个按钮固定 32×28 hit target。
            VStack(spacing: 9) {
                HStack {
                    Button {
                        model.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 28)
                    .disabled(!model.canGoPrevious)
                    .accessibilityLabel("上一首")

                    Spacer()

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

                    Spacer()

                    Button {
                        model.next()
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 28)
                    .disabled(!model.canGoNext)
                    .accessibilityLabel("下一首")

                    Spacer()

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
                HStack {
                    Button {
                        model.setVolume(max(0, model.volume - 0.05))
                    } label: {
                        Image(systemName: "speaker.slash")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 28)
                    .help("音量 -")
                    .accessibilityLabel("音量减小")

                    Spacer()

                    Button {
                        model.setVolume(min(1, model.volume + 0.05))
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 28)
                    .help("音量 +")
                    .accessibilityLabel("音量增加")

                    Spacer()

                    Button {
                        hideArtwork.toggle()
                    } label: {
                        Image(systemName: hideArtwork ? "rectangle" : "rectangle.fill")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 28)
                    .help(hideArtwork ? "显示封面" : "隐藏封面")
                    .accessibilityLabel(hideArtwork ? "显示封面" : "隐藏封面")

                    Spacer()

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
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: hideArtwork ? MacUIVisualTokens.MiniPlayer.compactWindowWidth : MacUIVisualTokens.MiniPlayer.windowWidth, height: hideArtwork ? MacUIVisualTokens.MiniPlayer.compactWindowHeight : MacUIVisualTokens.MiniPlayer.windowHeight)
        .background(.regularMaterial)
        .background(MacMiniWindowAttacher(coordinator: .shared))
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
            // NSView 挂载发生在 SwiftUI 更新事务内，推迟到下一轮 MainActor 执行。
            Task { @MainActor in
                coordinator.registerMiniWindow(currentWindow)
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
