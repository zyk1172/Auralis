#if os(macOS)
import AppKit
import Domain
import DesignSystem
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 全屏播放器几何度量（REFERENCE_B：1536×1050 → Artwork ≈475，左距 ≈130，顶 ≈173）。
enum MacFullPlayerMetrics {
    static func artworkSize(window: CGSize) -> CGFloat {
        min(500, max(300, min(window.width * 0.31, window.height * 0.46)))
    }
    static func leftMargin(window: CGSize) -> CGFloat { window.width * 0.085 }
    static func topY(window: CGSize) -> CGFloat { window.height * 0.165 }
    static func rightColumnWidth(window: CGSize) -> CGFloat {
        min(560, max(440, window.width * 0.34))
    }
    static func horizontalGap(window: CGSize) -> CGFloat { max(52, window.width * 0.035) }
    static func transportWidth(window: CGSize) -> CGFloat { artworkSize(window: window) }
}

/// Full Player 右侧上下文：歌词 / 队列。
enum MacFullPlayerContext: Hashable {
    case lyrics
    case queue
}

/// Apple Music macOS 27 Full Screen Player（REFERENCE_B）：
/// 全窗 Artwork ambience + 左列（Artwork→TrackInfo→Progress→Transport）+ 常驻右区（Lyrics/Queue）
/// + 三组 Floating Glass Capsule（左上窗口控制 / 右上音量 / 右下歌词-队列）。
public struct MacFullScreenPlayerView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var ambienceImage: PlatformImage?
    @State private var window: NSWindow?
    @State private var didRequestFullscreen = false
    @State private var context: MacFullPlayerContext = .lyrics
    @State private var isScrubbing = false
    @State private var scrubValue: TimeInterval = 0

    @ObservedObject private var playbackStore: PlaybackStore

    public init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self.theme = theme
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var track: Track { model.currentTrack }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let artwork = MacFullPlayerMetrics.artworkSize(window: size)
            let leftX = MacFullPlayerMetrics.leftMargin(window: size)
            let topY = MacFullPlayerMetrics.topY(window: size)

            ZStack {
                background
                HStack(alignment: .top, spacing: MacFullPlayerMetrics.horizontalGap(window: size)) {
                    leftColumn(artworkSize: artwork)
                        .frame(width: artwork)
                    rightContext(artworkSize: artwork)
                        .frame(width: MacFullPlayerMetrics.rightColumnWidth(window: size))
                    Spacer(minLength: 0)
                }
                .padding(.leading, leftX)
                .padding(.top, topY)

                topLeftGlass
                topRightVolumeGlass
                bottomRightContextGlass
            }
        }
        .background(WindowAccessor { window = $0 })
        .background(MacFullPlayerWindowConfigurator())
        .onAppear {
            enterFullScreenIfNeeded()
        }
        .task(id: track.id.rawValue) {
            ambienceImage = model.artworkImage(key: track.artworkKey, targetPixelSize: 720)
            model.ensureLyricsLoadedForCurrentTrack()
        }
    }

    // MARK: - 背景（全窗 Artwork ambience）

    private var background: some View {
        ZStack {
            if let ambienceImage {
                Image(platformImage: ambienceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 100)
                    .saturation(0.72)
                    .scaleEffect(1.15)
                    .clipped()
            } else {
                LinearGradient(colors: [.black, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(0.30)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - 左列

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(
                title: track.albumTitle,
                artworkKey: track.artworkKey,
                colors: theme.colorTokens,
                size: artworkSize,
                cornerRadius: 14
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .accessibilityLabel("\(track.albumTitle) 封面")

            Spacer().frame(height: 26)

            trackInfoRow

            Spacer().frame(height: 24)

            progressView(width: artworkSize)

            Spacer().frame(height: 28)

            transport(artworkSize: artworkSize)

            Spacer(minLength: 0)
        }
    }

    private var trackInfoRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(track.artistName) — \(track.albumTitle)")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.toggleFavorite(track)
            } label: {
                Image(systemName: track.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 20))
                    .foregroundStyle(track.isFavorite ? MacMediaAccent.color : .white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(track.isFavorite ? "取消收藏" : "收藏")
            .accessibilityLabel(track.isFavorite ? "取消收藏" : "收藏")
            Menu {
                if model.hasCurrentTrack {
                    let disliked = model.isDisliked(model.currentTrack)
                    Button(disliked ? "取消不喜欢" : "不喜欢") {
                        model.setDisliked(model.currentTrack, value: !disliked, source: "full-player")
                    }
                    Button("歌曲信息") {
                        NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: model.currentTrack)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多")
        }
    }

    private func progressView(width: CGFloat) -> some View {
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
            .controlSize(.small)
            .tint(.white.opacity(0.7))
            .accessibilityLabel("播放进度")
            HStack {
                Text(MacFormat.time(progress))
                Spacer()
                Text("-" + MacFormat.time(max(0, duration - progress)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(width: width)
    }

    private func transport(artworkSize: CGFloat) -> some View {
        HStack {
            Button {
                model.setShuffle(!model.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(model.isShuffled ? MacMediaAccent.color : .white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("随机播放")
            Spacer()
            Button {
                model.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoPrevious)
            .accessibilityLabel("上一首")
            Spacer()
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.playbackStore.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasCurrentTrack)
            .accessibilityLabel("播放 / 暂停")
            Spacer()
            Button {
                model.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoNext)
            .accessibilityLabel("下一首")
            Spacer()
            Button {
                model.cycleRepeatMode()
            } label: {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20))
                    .foregroundStyle(model.repeatMode != .off ? MacMediaAccent.color : .white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("循环模式")
        }
        .frame(width: artworkSize)
    }

    // MARK: - 右区（Lyrics / Queue 常驻）

    private func rightContext(artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch context {
            case .lyrics: lyricsPane
            case .queue: queuePane
            }
        }
    }

    private var lyricsPane: some View {
        Group {
            if let lines = model.currentLyrics?.lines, !lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = currentLyricIndex == index
                                Text(line.text)
                                    .font(.system(size: isCurrent ? 29 : 23, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.55))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let start = line.startTime {
                                            model.seek(toProgress: min(1, max(0, start / duration)))
                                        }
                                    }
                                    .id(index)
                                    .accessibilityValue(isCurrent ? "当前歌词" : "")
                            }
                        }
                        .padding(.vertical, 18)
                    }
                    .onChange(of: currentLyricIndex) { _, index in
                        guard let index else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Text("无可用歌词")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("此歌曲没有任何可用的歌词。")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var currentLyricIndex: Int? {
        guard let lines = model.currentLyrics?.lines else { return nil }
        let position = playbackStore.position
        var index: Int?
        for (i, line) in lines.enumerated() {
            if let start = line.startTime, start <= position + 0.15 { index = i }
        }
        return index
    }

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("待播队列")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.hasCurrentTrack {
                        queueRow(model.currentTrack, isCurrent: true)
                    }
                    ForEach(Array(model.upcomingTracks.enumerated()), id: \.element.id) { offset, track in
                        queueRow(track, isCurrent: false)
                            .contextMenu {
                                Button("立即播放") { model.selectAndPlay(track) }
                                Button("从队列移除") {
                                    let real = (model.currentQueueIndex ?? -1) + 1 + offset
                                    model.removeFromQueue(atOffsets: IndexSet([real]))
                                }
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func queueRow(_ queueTrack: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            ArtworkView(title: queueTrack.albumTitle, artworkKey: queueTrack.artworkKey, colors: theme.colorTokens, size: 42, cornerRadius: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(queueTrack.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.8))
                    .lineLimit(1)
                Text(queueTrack.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Glass Capsules

    private var topLeftGlass: some View {
        VStack {
            HStack(spacing: 14) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("关闭全屏播放器")
                .accessibilityLabel("关闭全屏播放器")
                Button(action: openMiniPlayer) {
                    Image(systemName: "pip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("切换迷你播放器")
                .accessibilityLabel("切换迷你播放器")
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(GlassControlGroup { EmptyView() })
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 20)
        .padding(.top, 14)
    }

    private var topRightVolumeGlass: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                Slider(value: Binding(
                    get: { model.volume },
                    set: { model.setVolume($0) }
                ), in: 0...1)
                .controlSize(.small)
                .frame(width: 150)
                .accessibilityLabel("音量")
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(GlassControlGroup { EmptyView() })
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 20)
        .padding(.top, 14)
    }

    private var bottomRightContextGlass: some View {
        VStack {
            Spacer()
            HStack(spacing: 22) {
                Button {
                    context = .lyrics
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 16))
                        .foregroundStyle(context == .lyrics ? MacMediaAccent.color : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("歌词")
                .accessibilityLabel("歌词")
                Button {
                    context = .queue
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16))
                        .foregroundStyle(context == .queue ? MacMediaAccent.color : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("队列")
                .accessibilityLabel("队列")
            }
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(GlassControlGroup { EmptyView() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Window 控制

    private func enterFullScreenIfNeeded() {
        guard !didRequestFullscreen else { return }
        didRequestFullscreen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window else { return }
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    private func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { window.close() }
        } else {
            window.close()
        }
    }

    private func openMiniPlayer() {
        NotificationCenter.default.post(name: MacCommand.showMiniPlayer, object: nil)
    }
}

/// 捕获承载视图的 NSWindow。
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 只作用于 Full Screen Player 窗口：透明 titlebar + 隐藏标题 + fullSizeContentView。
private struct MacFullPlayerWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
// MARK: - 窗口场景包装（注入共享环境，避免独立窗口缺 ArtworkStore/ThemeStore 崩溃）

/// 全屏播放器窗口内容：注入 artworkStore / themeStore 环境。
public struct MacFullScreenPlayerWindow: View {
    @ObservedObject public var themeStore: ThemeStore
    public init(themeStore: ThemeStore) {
        self.themeStore = themeStore
    }
    public var body: some View {
        MacFullScreenPlayerView(model: .shared, theme: themeStore.current)
            .environment(AuralisAppModel.shared.artworkStore)
            .environmentObject(themeStore)
            .tint(themeStore.current.colorTokens.accent.color)
            .preferredColorScheme(themeStore.current.colorScheme)
    }
}
#endif
