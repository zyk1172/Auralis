#if os(macOS)
import Domain
import DesignSystem
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 全屏沉浸播放器（独立窗口承载，进入系统全屏）。
/// 全窗口 Artwork 派生背景；前景超大封面 + 右侧同步歌词（如有）；底部最小控制。
/// 不显示公开评价 / 技术参数。
public struct MacFullScreenPlayerView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var ambienceImage: PlatformImage?
    @State private var window: NSWindow?

    public init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self.theme = theme
    }

    private var track: Track { model.currentTrack }
    private var lyrics: LyricsDocument? { model.currentLyrics }

    public var body: some View {
        ZStack {
            background
            HStack(alignment: .center, spacing: 40) {
                Spacer(minLength: 20)
                artwork
                if hasSyncedLyrics {
                    lyricsPane
                        .frame(maxWidth: 420)
                }
                Spacer(minLength: 20)
            }
            VStack {
                Spacer()
                bottomControls
            }
        }
        .onAppear {
            // 先呈现 Player 内容，下一 runloop 再进入系统全屏。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                window?.toggleFullScreen(nil)
            }
        }
        .background(WindowAccessor { window = $0 })
        .task(id: track.id.rawValue) {
            ambienceImage = model.artworkImage(key: track.artworkKey, targetPixelSize: 640)
        }
        .navigationTitle("全屏播放")
    }

    private var hasSyncedLyrics: Bool {
        (lyrics?.lines.contains { $0.startTime != nil } ?? false)
    }

    // MARK: - 背景（整窗 Artwork 派生，无可见矩形边界）

    private var background: some View {
        ZStack {
            if let ambienceImage {
                Image(platformImage: ambienceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 90)
                    .saturation(0.75)
                    .opacity(0.4)
                    .clipped()
            } else {
                LinearGradient(colors: [.black, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var artwork: some View {
        ArtworkView(
            title: track.albumTitle,
            artworkKey: track.artworkKey,
            colors: theme.colorTokens,
            size: 420,
            cornerRadius: 20
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .accessibilityLabel("\(track.albumTitle) 封面")
    }

    // MARK: - 歌词

    private var lyricsPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array((lyrics?.lines ?? []).enumerated()), id: \.element.id) { index, line in
                        let isCurrent = currentLyricIndex == index
                        Text(line.text)
                            .font(.system(size: isCurrent ? 22 : 17, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .accessibilityValue(isCurrent ? "当前歌词" : "")
                    }
                }
                .padding(20)
            }
            .onChange(of: currentLyricIndex) { _, index in
                if let index {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private var currentLyricIndex: Int? {
        guard let lines = lyrics?.lines else { return nil }
        let position = model.playbackStore.position
        var index: Int?
        for (i, line) in lines.enumerated() {
            if let start = line.startTime, start <= position + 0.15 { index = i }
        }
        return index
    }

    // MARK: - 底部控制

    private var bottomControls: some View {
        VStack(spacing: 10) {
            Text(track.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(track.artistName)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            HStack(spacing: 26) {
                Button {
                    model.setShuffle(!model.isShuffled)
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(model.isShuffled ? theme.colorTokens.accent.color : .white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("随机播放")

                Button {
                    model.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoPrevious)
                .accessibilityLabel("上一首")

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.playbackStore.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasCurrentTrack)
                .accessibilityLabel("播放 / 暂停")

                Button {
                    model.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoNext)
                .accessibilityLabel("下一首")

                Button {
                    model.toggleFavorite(track)
                } label: {
                    Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18))
                        .foregroundStyle(track.isFavorite ? theme.colorTokens.accent.color : .white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(track.isFavorite ? "取消收藏" : "收藏")
            }
        }
        .padding(.bottom, 40)
    }
}

/// 捕获承载视图的 NSWindow（用于进入全屏）。
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
