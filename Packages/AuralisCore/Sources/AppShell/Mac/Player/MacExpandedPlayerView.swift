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
    /// 让背景、封面和控制器作为一个 presentation layer 同步进入，避免封面先闪现。
    @State private var isPresentationVisible = false

    @ObservedObject private var playbackStore: PlaybackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    private var isPlaying: Bool { playbackStore.state == .playing }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let artwork = MacFullPlayerMetrics.artworkSize(window: size)
            let playerWidth = MacFullPlayerMetrics.playerColumnWidth(window: size)
            let hasContext = context != .none
            let playerLeading = hasContext
                ? MacFullPlayerMetrics.leftMargin(window: size)
                : max(0, (size.width - playerWidth) / 2)
            let contextLeading = playerLeading + playerWidth + MacFullPlayerMetrics.horizontalGap(window: size)

            ZStack {
                background

                // Music.app 的左侧是固定宽度的「播放轨道」：封面居中，标题、进度和运输控制
                // 左右对齐。队列/歌词是另一条更靠上的右轨，不能与封面同一顶部基线。
                playerColumn(artworkSize: artwork, columnWidth: playerWidth)
                    .frame(width: playerWidth, alignment: .leading)
                    .padding(.leading, playerLeading)
                    .padding(.top, MacFullPlayerMetrics.topY(window: size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if hasContext {
                    rightContext(artworkSize: artwork)
                        .padding(.leading, contextLeading)
                        .padding(.trailing, max(36, size.width * 0.04))
                        .padding(.top, MacFullPlayerMetrics.contextTopY(window: size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }

                // Glass Capsules（只对内容命中）
                topLeftGlass
                topRightVolumeGlass
                bottomRightContextGlass
            }
            .animation(.easeInOut(duration: 0.25), value: context)
            // 整个 Expanded Player 作为一层淡入并向上就位；ArtworkView 的异步图片
            // 也会受同一个 opacity/offset 约束，不会比背景与控制器先出现。
            .opacity(isPresentationVisible ? 1 : 0)
            .offset(y: isPresentationVisible ? 0 : 46)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.30)) {
                    isPresentationVisible = true
                }
            }
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

    private func playerColumn(artworkSize: CGFloat, columnWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(
                title: track.albumTitle,
                artworkKey: track.artworkKey,
                colors: theme.colorTokens,
                size: artworkSize,
                cornerRadius: MacUIVisualTokens.ExpandedPlayer.artworkCornerRadius
            )
            .frame(maxWidth: .infinity)
            // Apple Music 的呼吸式反馈：播放时封面铺满轨道，暂停时收拢。
            // 参考 Music.app：暂停封面约为播放态的 73%，而不是轻微缩小。
            .scaleEffect(isPlaying ? 1 : 0.73)
            .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.16), value: isPlaying)
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .accessibilityLabel("\(track.albumTitle) 封面")

            Spacer().frame(height: 26)  // trackInfo 上间距（保留）

            trackInfoRow

            Spacer().frame(height: MacUIVisualTokens.ExpandedPlayer.columnBlockSpacing)

            progressView(width: columnWidth)

            Spacer().frame(height: 28)  // progress→transport 间距（保留）

            transport(width: columnWidth)

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

    private func transport(width: CGFloat) -> some View {
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
        .frame(width: width)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            HStack(spacing: 14) {
                queueModePill(title: "自动连播", systemImage: "infinity")
                queueModePill(title: "交叉渐入渐出", systemImage: "shuffle")
            }
            .padding(.bottom, 28)

            HStack {
                Text("继续播放")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                if !model.upcomingTracks.isEmpty {
                    Button("清除") { model.clearUpcoming() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.pink.opacity(0.9))
                }
            }
            .padding(.bottom, 14)
            Divider().overlay(.white.opacity(0.22))
            if model.upcomingTracks.isEmpty {
                VStack {
                    Spacer()
                    Text("队列中无音乐。")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MacUIVisualTokens.ExpandedPlayer.queueRowSpacing) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func queueModePill(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.60))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(.white.opacity(0.08), in: Capsule())
            .accessibilityLabel(title)
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
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("收起播放器")
                        .accessibilityLabel("收起播放器")
                        Button(action: onOpenMiniPlayer) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 16, weight: .semibold))
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
                        Slider(value: Binding(
                            get: { model.volume },
                            set: { model.setVolume($0) }
                        ), in: 0...1)
                        .controlSize(.small)
                        .frame(width: MacUIVisualTokens.ExpandedPlayer.topRightGlassWidth)
                        .accessibilityLabel("音量")
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.85))
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
