#if os(macOS)
import AppKit
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
    /// 外部（MacMusicShell）进入 collapsing 阶段的信号：触发本页退场动画。
    let isCollapsing: Bool
    /// 入场动画完成回调：外部据此把 phase 从 .expanding 推到 .expanded（移除底层 library）。
    let onExpandComplete: () -> Void
    /// 退场动画完成回调：外部据此把 phase 从 .collapsing 推到 .library（移除 Expanded、恢复标题）。
    let onCollapseComplete: () -> Void

    @State private var ambienceImage: PlatformImage?
    @State private var lyricsState: MacLyricsPresentationState = .loading
    @State private var isScrubbing = false
    @State private var scrubValue: TimeInterval = 0
    /// 页面出现/消失动画：背景只淡入淡出（不参与缩放，绝不留白边），
    /// 前景内容（封面/标题/进度/控制）做 0.96 → 1.0 缩放 + 淡入淡出。
    @State private var presentationVisible = false

    @ObservedObject private var playbackStore: PlaybackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        context: Binding<MacExpandedPlayerContext>,
        onCollapse: @escaping () -> Void,
        onOpenMiniPlayer: @escaping () -> Void,
        isCollapsing: Bool = false,
        onExpandComplete: @escaping () -> Void = {},
        onCollapseComplete: @escaping () -> Void = {}
    ) {
        self.model = model
        self.theme = theme
        self._context = context
        self.onCollapse = onCollapse
        self.onOpenMiniPlayer = onOpenMiniPlayer
        self.isCollapsing = isCollapsing
        self.onExpandComplete = onExpandComplete
        self.onCollapseComplete = onCollapseComplete
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    private var track: Track { model.currentTrack }
    private var duration: TimeInterval { max(model.effectivePlaybackDuration, 1) }
    private var progress: TimeInterval { isScrubbing ? scrubValue : playbackStore.position }
    private var trackGlobalID: String { "\(track.serverID):\(track.id.rawValue)" }
    private var isPlaying: Bool { playbackStore.state == .playing }
    /// 展开播放页只从 ThemeColors 取前景色。背景可以是浅色渐变、封面氛围图或深色
    /// 主题，但文字和按钮不能再假设它一定是黑底。
    private var palette: MacExpandedPlayerPalette {
        .init(colors: theme.colorTokens, colorScheme: theme.colorScheme)
    }

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
                // 背景从第一帧铺满窗口，只做淡入淡出，**不参与缩放**：
                // 缩放背景会在顶部露出窗口/toolbar 底色（白条）。
                background
                    .opacity(presentationVisible ? 1 : 0)

                // 前景播放内容（封面/标题/进度/控制/歌词/队列）做 0.96 → 1.0 缩放 + 淡入。
                playerColumn(artworkSize: artwork, columnWidth: playerWidth)
                    .frame(width: playerWidth, alignment: .leading)
                    .padding(.leading, playerLeading)
                    .padding(.top, MacFullPlayerMetrics.topY(window: size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scaleEffect(presentationVisible ? 1 : 0.96, anchor: .bottom)
                    .opacity(presentationVisible ? 1 : 0)

                if hasContext {
                    rightContext(artworkSize: artwork)
                        .padding(.leading, contextLeading)
                        .padding(.trailing, max(36, size.width * 0.04))
                        .padding(.top, MacFullPlayerMetrics.contextTopY(window: size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                        .scaleEffect(presentationVisible ? 1 : 0.96, anchor: .bottom)
                        .opacity(presentationVisible ? 1 : 0)
                }

                // Glass Capsules（只对内容命中）
            }
            .overlay(alignment: .topLeading) { topTrafficLights }
            .overlay(alignment: .topLeading) { topLeftGlass }
            .overlay(alignment: .topTrailing) { topRightVolumeGlass }
            .overlay(alignment: .bottomTrailing) { bottomRightContextGlass }
            .animation(.easeInOut(duration: 0.25), value: context)
        }
        // 页面出现/消失动画：入场由 onAppear 驱动，退场由外部 isCollapsing 信号驱动；
        // 动画 completion 通过回调通知 Shell 推进 phase（不用 Task.sleep 魔法延迟）。
        .onAppear {
            guard !presentationVisible else { return }
            withAnimation(
                reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.38, bounce: 0.06),
                completionCriteria: .logicallyComplete
            ) {
                presentationVisible = true
            } completion: {
                Task { @MainActor in onExpandComplete() }
            }
        }
        .onChange(of: isCollapsing) { _, newValue in
            guard newValue, presentationVisible else { return }
            withAnimation(
                reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.32, bounce: 0),
                completionCriteria: .logicallyComplete
            ) {
                presentationVisible = false
            } completion: {
                Task { @MainActor in onCollapseComplete() }
            }
        }
        // 窗口 chrome（traffic lights / titlebar 透明 / titleVisibility）由
        // MacMusicShell 的 MacWindowAttacher(isExpanded:) 唯一写入（P2-1），
        // 展开页不再持有第二个 chrome writer。
        .task(id: trackGlobalID) {
            ambienceImage = model.artworkImage(key: track.artworkKey, targetPixelSize: 720)
            lyricsState = .loading
        }
        // 歌词属于右侧按需 context。只看封面或队列时不竞争磁盘/网络；切到歌词
        // 后才读取缓存或服务器，歌曲变化时 task id 会自动取消旧请求。
        .task(id: "\(trackGlobalID)|\(String(describing: context))") {
            guard context == .lyrics else { return }
            await loadLyrics()
        }
    }

    // MARK: - 背景

    private var background: some View {
        let colors = theme.colorTokens
        let isLight = theme.colorScheme == .light
        return ZStack {
            // 播放页的底色始终来自当前主题，而不是固定灰黑。三段渐变建立 Apple
            // Music 式由顶向下的景深；两层低饱和主题强调光让不同主题仍保有识别度。
            LinearGradient(
                colors: [
                    colors.background.color,
                    colors.elevated.color,
                    colors.surface.color.opacity(isLight ? 0.82 : 0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [colors.accent.color.opacity(0.30), colors.accent.color.opacity(0.08), .clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 880
            )
            RadialGradient(
                colors: [colors.accentSecondary.color.opacity(0.24), colors.accentSecondary.color.opacity(0.05), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 940
            )
            if let ambienceImage, model.currentTrack.artworkKey != nil {
                Image(platformImage: ambienceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 108)
                    .saturation(0.84)
                    .scaleEffect(1.15)
                    .clipped()
                    .opacity(isLight ? 0.12 : 0.28)
                    .blendMode(.softLight)
            }
            // 这是可读性层，而不是固定灰蒙版：浅色主题保留足够亮度让深色
            // ThemeColors 前景清晰；深色主题压住封面氛围图后仍使用浅色前景。
            LinearGradient(
                colors: isLight
                    ? [.white.opacity(0.18), .white.opacity(0.38)]
                    : [.black.opacity(0.12), .black.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )
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
            // frame 始终是播放态的最大尺寸：暂停只改变视觉层，标题/进度/控制
            // 不会因 Artwork 尺寸变化而重新排版。
            .frame(width: artworkSize, height: artworkSize)
            .frame(maxWidth: .infinity, alignment: .center)
            // Music.app 式呼吸反馈：播放时几乎填满控制轨，暂停从中心收拢。
            .scaleEffect(
                isPlaying ? 1 : MacUIVisualTokens.ExpandedPlayer.pausedArtworkScale,
                anchor: .center
            )
            .animation(reduceMotion ? nil : .spring(duration: 0.30, bounce: 0.08), value: isPlaying)
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
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                Text("\(track.artistName) — \(track.albumTitle)")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.toggleFavorite(track)
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20))
                    .foregroundStyle(track.isFavorite ? palette.accent : palette.control)
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
                    .foregroundStyle(palette.control)
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
            .tint(palette.accent)
            .accessibilityLabel("播放进度")
            HStack {
                Text(MacFormat.time(progress))
                Spacer()
                Text("-" + MacFormat.time(max(0, duration - progress)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.secondary)
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
                    .foregroundStyle(model.isShuffled ? palette.accent : palette.control)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("随机播放")
            Spacer()
            Button {
                model.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(palette.primary)
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
                    .foregroundStyle(palette.primary)
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
                    .foregroundStyle(palette.primary)
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
                    .foregroundStyle(model.repeatMode != .off ? palette.accent : palette.control)
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
                    ProgressView().controlSize(.small).tint(palette.accent)
                    Text("正在加载歌词…")
                        .font(.body)
                        .foregroundStyle(palette.secondary)
                    Spacer()
                }
            case let .available(lyrics) where !lyrics.lines.isEmpty:
                let activeIndex = currentLyricIndex
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .center, spacing: MacUIVisualTokens.ExpandedPlayer.lyricsLineGap) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = activeIndex == index
                                Text(line.text)
                                    .font(.system(size: isCurrent ? MacUIVisualTokens.Typography.lyricActive : MacUIVisualTokens.Typography.lyricInactive, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? palette.primary : palette.lyricInactive)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
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
                        .foregroundStyle(palette.primary)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(palette.secondary)
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
                .foregroundStyle(palette.primary)
            Text("此歌曲没有任何可用的歌词。")
                .font(.body)
                .foregroundStyle(palette.secondary)
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
                Text("继续播放")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primary)
                Spacer()
                if !model.upcomingTracks.isEmpty {
                    Button("清除") { model.clearUpcoming() }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.destructive)
                }
            }
            .padding(.bottom, 14)
            Divider().overlay(palette.separator)
            if model.upcomingTracks.isEmpty {
                VStack {
                    Spacer()
                    Text("队列中无音乐。")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MacUIVisualTokens.ExpandedPlayer.queueRowSpacing) {
                        ForEach(Array(model.upcomingTracks.enumerated()), id: \.element.macGlobalID) { offset, queueTrack in
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

    private func queueRow(_ queueTrack: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            ArtworkView(title: queueTrack.albumTitle, artworkKey: queueTrack.artworkKey, colors: theme.colorTokens, size: 42, cornerRadius: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(queueTrack.title)
                    .font(.system(size: MacUIVisualTokens.Typography.queueTrackTitle, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? palette.primary : palette.control)
                    .lineLimit(1)
                Text(queueTrack.artistName)
                    .font(.system(size: MacUIVisualTokens.Typography.queueTrackSubtitle))
                    .foregroundStyle(palette.secondary)
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

    /// Expanded Player 自己承载三个窗口控制点，和左右胶囊共用相同 38pt 高度与
    /// 8pt 顶部基线；不再让 AppKit toolbar 在异步 layout 后把它们弹回旧位置。
    private var topTrafficLights: some View {
        HStack(spacing: 10) {
            trafficLight(color: .red) { NSApp.keyWindow?.performClose(nil) }
            trafficLight(color: .yellow) { NSApp.keyWindow?.miniaturize(nil) }
            trafficLight(color: .green) { NSApp.keyWindow?.zoom(nil) }
        }
        .frame(height: MacUIVisualTokens.ExpandedPlayer.topLeftGlassHeight)
        .padding(.leading, 16)
        .padding(.top, MacUIVisualTokens.ExpandedPlayer.topLeftGlassPaddingT)
        .ignoresSafeArea(edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("窗口控制")
    }

    private func trafficLight(color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var topLeftGlass: some View {
        MacGlassCapsule(colorScheme: theme.colorScheme) {
            HStack(spacing: MacUIVisualTokens.ExpandedPlayer.topRightControlSpacing) {
                Button(action: onCollapse) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.control)
                }
                .buttonStyle(.plain)
                .help("收起播放器")
                .accessibilityLabel("收起播放器")
                Button(action: onOpenMiniPlayer) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.control)
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
        // 胶囊属于 titlebar 控件，不能被安全区向下推到内容区。
        .ignoresSafeArea(edges: .top)
    }

    private var topRightVolumeGlass: some View {
        MacGlassCapsule(colorScheme: theme.colorScheme) {
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
                    .foregroundStyle(palette.control)
            }
            .padding(.horizontal, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingH)
            .frame(height: MacUIVisualTokens.ExpandedPlayer.topRightGlassHeight)
        }
        .padding(.trailing, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingR)
        .padding(.top, MacUIVisualTokens.ExpandedPlayer.topRightGlassPaddingT)
        // 与左侧胶囊一起进入 titlebar；背景不再覆盖系统 traffic lights。
        .ignoresSafeArea(edges: .top)
    }

    private var bottomRightContextGlass: some View {
        MacGlassCapsule(colorScheme: theme.colorScheme) {
            HStack(spacing: 22) {
                Button {
                    MacUITrace.action("toggleLyrics", "from=\(String(describing: context))")
                    context = context == .lyrics ? .none : .lyrics
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 16))
                        .foregroundStyle(context == .lyrics ? palette.accent : palette.control)
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
                        .foregroundStyle(context == .queue ? palette.accent : palette.control)
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

    // MARK: - 加载

    private func loadLyrics() async {
        lyricsState = .loading
        let expectedID = trackGlobalID
        if let lyrics = await model.loadLyrics(for: track) {
            guard expectedID == trackGlobalID, !Task.isCancelled else { return }
            lyricsState = .available(lyrics)
        } else {
            guard expectedID == trackGlobalID, !Task.isCancelled else { return }
            lyricsState = .unavailable
        }
    }
}

/// 主题感知的播放页前景色。把这层集中在这里，播放页今后即使叠加更亮的主题
/// 渐变或封面氛围图，也不会悄悄回退成「白色文字／按钮」的固定假设。
private struct MacExpandedPlayerPalette {
    let primary: Color
    let secondary: Color
    let control: Color
    let lyricInactive: Color
    let accent: Color
    let destructive: Color
    let separator: Color

    init(colors: ThemeColors, colorScheme: ColorScheme) {
        primary = colors.primaryText.color
        secondary = colors.secondaryText.color
        control = colorScheme == .light
            ? colors.primaryText.color.opacity(0.82)
            : colors.primaryText.color.opacity(0.86)
        lyricInactive = colorScheme == .light
            ? colors.secondaryText.color.opacity(0.86)
            : colors.secondaryText.color.opacity(0.78)
        accent = colors.accent.color
        destructive = colors.error.color
        separator = colors.separator.color.opacity(colorScheme == .light ? 0.72 : 0.84)
    }
}

#endif
