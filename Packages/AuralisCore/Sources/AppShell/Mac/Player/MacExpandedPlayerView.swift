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
    /// 前景是否可见：由 MacMusicShell 驱动（playerOverlayVisible），
    /// 本页**不在 onAppear 里自行 withAnimation**——保证动画从外部明确开始。
    let isVisible: Bool

    @State private var ambienceImage: PlatformImage?
    @State private var lyricsState: MacLyricsPresentationState = .loading

    @ObservedObject private var playbackStore: PlaybackStore
    @ObservedObject private var queueStore: PlaybackQueuePresentationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        context: Binding<MacExpandedPlayerContext>,
        isVisible: Bool,
        onCollapse: @escaping () -> Void,
        onOpenMiniPlayer: @escaping () -> Void
    ) {
        self.model = model
        self.theme = theme
        self._context = context
        self.isVisible = isVisible
        self.onCollapse = onCollapse
        self.onOpenMiniPlayer = onOpenMiniPlayer
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self._queueStore = ObservedObject(wrappedValue: model.queueStore)
    }

    private var track: Track { model.currentTrack }
    private var duration: TimeInterval { max(model.effectivePlaybackDuration, 1) }
    private var trackGlobalID: String { "\(track.serverID):\(track.id.rawValue)" }
    private var isPlaying: Bool { playbackStore.state == .playing }
    // MARK: - 进度条 scrub 状态（回归修复：拖动中滑块与时间文字必须一致）
    /// 用户是否正在拖动进度条。拖动中滑块与时间文字显示 scrubValue，
    /// 不跟随实际播放 position；松手后 seek 一次。
    @State private var isScrubbing = false
    /// 拖动中 NSSlider 上报的当前值（秒）。
    @State private var scrubValue: Double = 0
    /// 开始拖动时的歌曲时长快照（拖动中切歌场景自洽）。
    @State private var scrubDuration: Double = 0
    /// 进度条显示值：拖动中 = scrubValue，否则 = 实际播放位置。
    private var displayedProgress: Double {
        isScrubbing ? scrubValue : playbackStore.position
    }
    /// 剩余时间显示：拖动中用 scrubDuration 快照，否则用实时 duration。
    private var displayedRemaining: Double {
        isScrubbing ? max(0, scrubDuration - scrubValue) : max(0, duration - playbackStore.position)
    }
    /// 待播队列（当前曲目之后的队列项），由 queueStore 提供，随队列/当前曲目变化更新。
    /// R05：返回带独立 UUID 身份的 QueueEntry，重复歌曲可安全渲染与移除。
    /// 返回 `ArraySlice`，**不复制**——队列上万首时避免 `Array(dropFirst)` 全量拷贝。
    private var queueStoreUpcomingEntries: ArraySlice<QueueEntry> {
        queueStore.entries(after: queueStore.currentIndex)
    }
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
                // 背景从第一帧铺满窗口：始终 opacity 1、不缩放、不 offset，
                // 任何时刻都不露出窗口/toolbar 底色（白条）。
                background

                // 前景播放内容（封面/标题/进度/控制/歌词/队列）：
                // 由外部 isVisible 驱动 offset + scale + opacity，动画在 Shell 侧开启。
                playerColumn(artworkSize: artwork, columnWidth: playerWidth)
                    .frame(width: playerWidth, alignment: .leading)
                    .padding(.leading, playerLeading)
                    .padding(.top, MacFullPlayerMetrics.topY(window: size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(y: isVisible ? 0 : (reduceMotion ? 0 : 36))
                    .scaleEffect(isVisible ? 1 : (reduceMotion ? 1 : 0.97), anchor: .bottom)
                    .opacity(isVisible ? 1 : 0)

                if hasContext {
                    rightContext(artworkSize: artwork)
                        .padding(.leading, contextLeading)
                        .padding(.trailing, max(36, size.width * 0.04))
                        .padding(.top, MacFullPlayerMetrics.contextTopY(window: size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                        .offset(y: isVisible ? 0 : (reduceMotion ? 0 : 36))
                        .scaleEffect(isVisible ? 1 : (reduceMotion ? 1 : 0.97), anchor: .bottom)
                        .opacity(isVisible ? 1 : 0)
                }

                // Glass Capsules（只对内容命中）
            }
            .overlay(alignment: .topLeading) {
                topLeftGlass.opacity(isVisible ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                topRightVolumeGlass.opacity(isVisible ? 1 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                bottomRightContextGlass.opacity(isVisible ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: context)
            // 页面出现/消失动画完全由 MacMusicShell 的 playerOverlayVisible 驱动，
            // 本页不在 onAppear 里自行 withAnimation。
        }
        // 窗口 chrome（traffic lights / titlebar 透明 / titleVisibility）由
        // MacMusicShell 的 MacWindowAttacher(isExpanded:) 唯一写入（P2-1），
        // 展开页不再持有第二个 chrome writer。
        .task(id: trackGlobalID) {
            // R01：当前曲目封面必须按 currentTrack.serverID 取（播 A 浏览 B 时
            // ambience 背景仍是 A 的封面），不能回落到浏览服务器的同名封面。
            ambienceImage = model.artworkImage(key: track.artworkKey, targetPixelSize: 720, serverID: track.serverID)
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
                serverID: track.serverID,
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
            .accessibilityLabel(String(localized: "\(track.albumTitle) 封面", bundle: .module))

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
            .help(track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
            .accessibilityLabel(track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
            Menu {
                if model.hasCurrentTrack {
                    let disliked = model.isDisliked(model.currentTrack)
                    Button(disliked ? String(localized: "取消不喜欢", bundle: .module) : String(localized: "不喜欢", bundle: .module)) {
                        model.setDisliked(model.currentTrack, value: !disliked, source: "expanded-player")
                    }
                    Button(String(localized: "歌曲信息", bundle: .module)) {
                        NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: model.currentTrack)
                    }
                    Button(String(localized: "歌曲鉴赏", bundle: .module)) {
                        NotificationCenter.default.post(name: MacCommand.songAppreciation, object: model.currentTrack)
                    }
                    if model.isDownloaded(model.currentTrack) {
                        Button(String(localized: "删除下载", bundle: .module), role: .destructive) { model.removeDownload(model.currentTrack) }
                    } else {
                        Button(String(localized: "下载", bundle: .module)) { model.download(model.currentTrack) }
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
            .help(String(localized: "更多", bundle: .module))
            .accessibilityLabel(String(localized: "更多", bundle: .module))
        }
    }

    private func progressView(width: CGFloat) -> some View {
        VStack(spacing: 4) {
            MacPlaybackSlider(
                // 拖动中显示 scrubValue（不跳回实际 position），时间文字同步显示拖动位置。
                value: displayedProgress,
                minValue: 0,
                maxValue: duration,
                isEnabled: model.hasCurrentTrack,
                onScrubStart: {
                    scrubDuration = duration
                    isScrubbing = true
                },
                onScrubChange: { scrubValue = $0 },
                onCommit: { value in
                    isScrubbing = false
                    model.seek(toProgress: min(1, max(0, value / duration)))
                }
            )
            // 切歌重建 NSSlider 与 Coordinator：不继承上一首歌的滑块内部状态，
            // onCommit 闭包也随重建捕获新 duration（回归修复）。
            .id(trackGlobalID)
            .controlSize(.small)
            .tint(palette.accent)
            .accessibilityLabel(String(localized: "播放进度", bundle: .module))
            HStack {
                Text(MacFormat.time(displayedProgress))
                Spacer()
                Text("-" + MacFormat.time(displayedRemaining))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.secondary)
        }
        .frame(width: width)
        // 切歌瞬间若正在拖动：强制结束 scrub（.id 重建只重置控件，@State 需显式清）。
        .onChange(of: trackGlobalID) {
            isScrubbing = false
            scrubValue = 0
            scrubDuration = duration
        }
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
            .accessibilityLabel(String(localized: "随机播放", bundle: .module))
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
            .accessibilityLabel(String(localized: "上一首", bundle: .module))
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
            .accessibilityLabel(String(localized: "播放 / 暂停", bundle: .module))
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
            .accessibilityLabel(String(localized: "下一首", bundle: .module))
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
            .help(String(localized: "循环模式", bundle: .module))
            .accessibilityLabel(String(localized: "循环模式", bundle: .module))
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
                    Text(String(localized: "正在加载歌词…", bundle: .module))
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
                                    // 活跃状态只改变绘制，不改变 LazyVStack 的行高；否则
                                    // scrollTo 动画与字号驱动的重排会在每次换句时相互抢占。
                                    .font(.system(size: MacUIVisualTokens.Typography.lyricActive, weight: isCurrent ? .semibold : .regular))
                                    .scaleEffect(
                                        isCurrent
                                            ? 1
                                            : MacUIVisualTokens.Typography.lyricInactive / MacUIVisualTokens.Typography.lyricActive
                                    )
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
                                    .accessibilityValue(isCurrent ? String(localized: "当前歌词", bundle: .module) : "")
                                    .animation(.easeInOut(duration: 0.16), value: isCurrent)
                            }
                        }
                        .padding(.vertical, 18)
                    }
                    .onChange(of: activeIndex) { _, index in
                        guard let index else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .task(id: "\(trackGlobalID)|\(lyrics.id)") {
                        guard let activeIndex else { return }
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            case .available:
                unavailableView
            case .unavailable:
                unavailableView
            case let .error(message):
                VStack(spacing: 8) {
                    Spacer()
                    Text(String(localized: "歌词加载失败", bundle: .module))
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
            Text(String(localized: "无可用歌词", bundle: .module))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primary)
            Text(String(localized: "此歌曲没有任何可用的歌词。", bundle: .module))
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
                Text(String(localized: "继续播放", bundle: .module))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primary)
                Spacer()
                if !queueStoreUpcomingEntries.isEmpty {
                    Button(String(localized: "清除", bundle: .module)) { model.clearUpcoming() }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.destructive)
                }
            }
            .padding(.bottom, 14)
            Divider().overlay(palette.separator)
            if queueStoreUpcomingEntries.isEmpty {
                VStack {
                    Spacer()
                    Text(String(localized: "队列中无音乐。", bundle: .module))
                        .font(.system(size: 16))
                        .foregroundStyle(palette.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MacUIVisualTokens.ExpandedPlayer.queueRowSpacing) {
                        ForEach(queueStoreUpcomingEntries) { entry in
                            let queueTrack = entry.track
                            queueRow(queueTrack, isCurrent: false, entryID: entry.id)
                                .contextMenu {
                                    Button(String(localized: "立即播放", bundle: .module)) { model.playQueueEntry(id: entry.id) }
                                    Button(String(localized: "从队列移除", bundle: .module)) { model.removeQueueEntry(id: entry.id) }
                                }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func queueRow(_ queueTrack: Track, isCurrent: Bool, entryID: UUID) -> some View {
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
            // R05：按队列项 UUID 播放——重复歌曲点第二个 A 就播第二个 A。
            model.playQueueEntry(id: entryID)
        }
    }

    // MARK: - Glass Capsules（.overlay(alignment:) 定位，避免整屏透明容器吞点击）

    /// 窗口控制（关闭 / 最小化 / 缩放）由系统 standard window buttons 提供，
    /// 保留在 titlebar 默认左上角位置（见 MacWindowChromeController），
    /// 本页不再自绘红黄绿交通灯，也不操作 NSApp.keyWindow。

    private var topLeftGlass: some View {
        MacGlassCapsule(colorScheme: theme.colorScheme) {
            HStack(spacing: MacUIVisualTokens.ExpandedPlayer.topRightControlSpacing) {
                Button(action: onCollapse) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.control)
                }
                .buttonStyle(.plain)
                .help(String(localized: "收起播放器", bundle: .module))
                .accessibilityLabel(String(localized: "收起播放器", bundle: .module))
                Button(action: onOpenMiniPlayer) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.control)
                }
                .buttonStyle(.plain)
                .help(String(localized: "切换迷你播放器", bundle: .module))
                .accessibilityLabel(String(localized: "切换迷你播放器", bundle: .module))
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
                .accessibilityLabel(String(localized: "音量", bundle: .module))
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
                .help(String(localized: "歌词", bundle: .module))
                .accessibilityLabel(String(localized: "歌词", bundle: .module))
                Button {
                    MacUITrace.action("toggleQueue", "from=\(String(describing: context))")
                    context = context == .queue ? .none : .queue
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16))
                        .foregroundStyle(context == .queue ? palette.accent : palette.control)
                }
                .buttonStyle(.plain)
                .help(String(localized: "队列", bundle: .module))
                .accessibilityLabel(String(localized: "队列", bundle: .module))
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
