#if os(macOS)
import Domain
import DesignSystem
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 同窗口 Expanded Player（Round-4）：
/// 覆盖同一主窗口，不新建窗口；三状态 context = none/lyrics/queue。
/// context=none 时播放器列水平居中；打开歌词/队列时平滑左移 + 右侧 context 淡入。
struct MacExpandedPlayerView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var context: MacExpandedPlayerContext
    let onCollapse: () -> Void
    let onOpenMiniPlayer: () -> Void

    @State private var ambienceImage: PlatformImage?
    @State private var lyricsState: MacLyricsPresentationState = .loading
    @State private var isScrubbing = false
    @State private var scrubValue: TimeInterval = 0

    @ObservedObject private var playbackStore: PlaybackStore

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        context: Binding<MacExpandedPlayerContext>,
        onCollapse: @escaping () -> Void,
        onOpenMiniPlayer: @escaping () -> Void
    ) {
        self.model = model
        self.theme = theme
        self._context = context
        self.onCollapse = onCollapse
        self.onOpenMiniPlayer = onOpenMiniPlayer
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var track: Track { model.currentTrack }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }
    private var trackGlobalID: String { "\(track.serverID):\(track.id.rawValue)" }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let artwork = MacFullPlayerMetrics.artworkSize(window: size)
            let hasContext = context != .none
            let leading = hasContext ? MacFullPlayerMetrics.leftMargin(window: size) : max(0, (size.width - artwork) / 2)

            ZStack {
                background

                HStack(alignment: .top, spacing: MacFullPlayerMetrics.horizontalGap(window: size)) {
                    playerColumn(artworkSize: artwork)
                        .frame(width: artwork)
                    if hasContext {
                        rightContext(artworkSize: artwork)
                            .frame(width: MacFullPlayerMetrics.rightColumnWidth(window: size))
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, leading)
                .padding(.top, MacFullPlayerMetrics.topY(window: size))

                // Glass Capsules（只对内容命中）
                topLeftGlass
                topRightVolumeGlass
                bottomRightContextGlass
            }
            .animation(.easeInOut(duration: 0.25), value: context)
        }
        .task(id: trackGlobalID) {
            ambienceImage = model.artworkImage(key: track.artworkKey, targetPixelSize: 720)
            await loadLyrics()
        }
        .onChange(of: trackGlobalID) { _, _ in
            Task { await loadLyrics() }
        }
    }

    // MARK: - 背景

    private var background: some View {
        ZStack {
            if let ambienceImage, model.currentTrack.artworkKey != nil {
                Image(platformImage: ambienceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 100)
                    .saturation(0.72)
                    .scaleEffect(1.15)
                    .clipped()
            } else {
                LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(0.30)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - 播放器列

    private func playerColumn(artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(
                title: track.albumTitle,
                artworkKey: track.artworkKey,
                colors: theme.colorTokens,
                size: artworkSize,
                cornerRadius: MacUIVisualTokens.ExpandedPlayer.artworkCornerRadius
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .accessibilityLabel("\(track.albumTitle) 封面")

            Spacer().frame(height: 26)  // trackInfo 上间距（保留）

            trackInfoRow

            Spacer().frame(height: MacUIVisualTokens.ExpandedPlayer.columnBlockSpacing)

            progressView(width: artworkSize)

            Spacer().frame(height: 28)  // progress→transport 间距（保留）

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
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
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
                        model.setDisliked(model.currentTrack, value: !disliked, source: "expanded-player")
                    }
                    Button("歌曲信息") {
                        NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: model.currentTrack)
                    }
                    Button("歌曲鉴赏") {
                        NotificationCenter.default.post(name: MacCommand.songAppreciation, object: model.currentTrack)
                    }
                    if model.isDownloaded(model.currentTrack) {
                        Button("删除下载", role: .destructive) { model.removeDownload(model.currentTrack) }
                    } else {
                        Button("下载") { model.download(model.currentTrack) }
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
                MacUITrace.action("cycleRepeat", "mode=\(model.repeatMode.rawValue)")
            } label: {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20))
                    .foregroundStyle(model.repeatMode != .off ? MacMediaAccent.color : .white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("循环模式")
            .accessibilityLabel("循环模式")
        }
        .frame(width: artworkSize)
    }

    // MARK: - 右侧 Context

    private func rightContext(artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch context {
            case .none:
                EmptyView()
            case .lyrics:
                lyricsPane
            case .queue:
                queuePane
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var lyricsPane: some View {
        Group {
            switch lyricsState {
            case .loading:
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView().controlSize(.small).tint(.white)
                    Text("正在加载歌词…")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
            case let .available(lyrics) where !lyrics.lines.isEmpty:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: MacUIVisualTokens.ExpandedPlayer.lyricsLineGap) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = currentLyricIndex == index
                                Text(line.text)
                                    .font(.system(size: isCurrent ? MacUIVisualTokens.Typography.lyricActive : MacUIVisualTokens.Typography.lyricInactive, weight: isCurrent ? .semibold : .regular))
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
            case .available:
                unavailableView
            case .unavailable:
                unavailableView
            case let .error(message):
                VStack(spacing: 8) {
                    Spacer()
                    Text("歌词加载失败")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var unavailableView: some View {
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

    private var currentLyricIndex: Int? {
        guard case let .available(lyrics) = lyricsState else { return nil }
        let position = playbackStore.position
        var index: Int?
        for (i, line) in lyrics.lines.enumerated() {
            if let start = line.startTime, start <= position + 0.15 { index = i }
        }
        return index
    }

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待播队列")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if !model.upcomingTracks.isEmpty {
                    Button("清除") { model.clearUpcoming() }
                        .buttonStyle(.link)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: MacUIVisualTokens.ExpandedPlayer.queueRowSpacing) {
                    if model.hasCurrentTrack {
                        queueRow(model.currentTrack, isCurrent: true)
                    }
                    ForEach(Array(model.upcomingTracks.enumerated()), id: \.element.id) { offset, queueTrack in
                        queueRow(queueTrack, isCurrent: false)
                            .contextMenu {
                                Button("立即播放") { model.selectAndPlay(queueTrack) }
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
                    .font(.system(size: MacUIVisualTokens.Typography.queueTrackTitle, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.8))
                    .lineLimit(1)
                Text(queueTrack.artistName)
                    .font(.system(size: MacUIVisualTokens.Typography.queueTrackSubtitle))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .onTapGesture(count: 2) {
            model.selectAndPlay(queueTrack)
        }
    }

    // MARK: - Glass Capsules（.overlay(alignment:) 定位，避免整屏透明容器吞点击）

    private var topLeftGlass: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                MacGlassCapsule {
                    HStack(spacing: MacUIVisualTokens.ExpandedPlayer.topRightControlSpacing) {
                        Button(action: onCollapse) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("收起播放器")
                        .accessibilityLabel("收起播放器")
                        Button(action: onOpenMiniPlayer) {
                            Image(systemName: "pip")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("切换迷你播放器")
                        .accessibilityLabel("切换迷你播放器")
                    }
                    .padding(.horizontal, MacUIVisualTokens.ExpandedPlayer.topLeftGlassPaddingH)
                    .frame(height: MacUIVisualTokens.ExpandedPlayer.topLeftGlassHeight)
                }
                .padding(.leading, MacUIVisualTokens.ExpandedPlayer.topLeftGlassPaddingL)
                .padding(.top, MacUIVisualTokens.ExpandedPlayer.topLeftGlassPaddingT)
            }
    }

    private var topRightVolumeGlass: some View {
        Color.clear
            .overlay(alignment: .topTrailing) {
                MacGlassCapsule {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.85))
                        Slider(value: Binding(
                            get: { model.volume },
                            set: { model.setVolume($0) }
                        ), in: 0...1)
                        .controlSize(.small)
                        .frame(width: MacUIVisualTokens.ExpandedPlayer.topRightGlassWidth)
                        .accessibilityLabel("音量")
                    }
                    .padding(.horizontal, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingH)
                    .frame(height: MacUIVisualTokens.ExpandedPlayer.topRightGlassHeight)
                }
                .padding(.trailing, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingR)
                .padding(.top, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingT)
            }
    }

    private var bottomRightContextGlass: some View {
        Color.clear
            .overlay(alignment: .bottomTrailing) {
                MacGlassCapsule {
                    HStack(spacing: 22) {
                        Button {
                            MacUITrace.action("toggleLyrics", "from=\(String(describing: context))")
                            context = context == .lyrics ? .none : .lyrics
                        } label: {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 16))
                                .foregroundStyle(context == .lyrics ? MacMediaAccent.color : .white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("歌词")
                        .accessibilityLabel("歌词")
                        Button {
                            MacUITrace.action("toggleQueue", "from=\(String(describing: context))")
                            context = context == .queue ? .none : .queue
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 16))
                                .foregroundStyle(context == .queue ? MacMediaAccent.color : .white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("队列")
                        .accessibilityLabel("队列")
                    }
                    .padding(.horizontal, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingH)
                    .frame(height: MacUIVisualTokens.ExpandedPlayer.topRightGlassHeight)
                }
                .padding(.trailing, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingR)
                .padding(.bottom, 20)
            }
    }

    // MARK: - 加载

    private func loadLyrics() async {
        lyricsState = .loading
        model.ensureLyricsLoadedForCurrentTrack()
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let lyrics = model.currentLyrics {
            lyricsState = .available(lyrics)
        } else {
            lyricsState = .unavailable
        }
    }
}
#endif
