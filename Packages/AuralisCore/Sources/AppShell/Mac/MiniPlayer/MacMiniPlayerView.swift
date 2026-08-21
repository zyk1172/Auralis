#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 独立 MiniPlayer 窗口（Window → 迷你播放器）。
/// 完整模式：顶部三态内容面板（封面 / 歌词 / 队列）+ 标题/艺术家 + 进度 +
/// 两排控制（歌词、队列、切换小号、返回主窗口）；
/// Compact（隐藏封面）独立布局，不再复用完整模式 UI，保证 140pt 高度不裁切。
public struct MacMiniPlayerView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @AppStorage("auralis.miniplayer.hideArtwork") private var hideArtwork = false

    @ObservedObject private var playbackStore: PlaybackStore
    @ObservedObject private var queueStore: PlaybackQueuePresentationStore
    @State private var isVolumePopoverPresented = false

    /// 大号 Mini Player 顶部内容面板的三态：封面 / 歌词 / 队列。
    /// 切换只发生在面板内部（固定 220×220），不改变窗口尺寸。
    private enum MacMiniPlayerContentMode: Equatable {
        case artwork
        case lyrics
        case queue
    }

    @State private var contentMode: MacMiniPlayerContentMode = .artwork
    @State private var lyricsState: MacLyricsPresentationState = .loading

    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        self.model = model
        self.theme = themeStore.current
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self._queueStore = ObservedObject(wrappedValue: model.queueStore)
    }

    private var hasTrack: Bool { model.hasCurrentTrack }
    private var duration: TimeInterval { max(model.effectivePlaybackDuration, 1) }
    private var trackGlobalID: String { "\(model.currentTrack.serverID):\(model.currentTrack.id.rawValue)" }

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

    // MARK: - 完整模式（三态内容面板 + 信息 + 进度 + 两排控制）

    private var artworkPlayer: some View {
        VStack(spacing: MacUIVisualTokens.MiniPlayer.contentSpacing) {
            miniHeroContent(size: MacUIVisualTokens.MiniPlayer.artworkSize)

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
                    lyricsButton
                    Spacer()
                    queueButton
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
        // 歌词只在用户切到歌词模式后才读取（缓存或服务器）；切歌或切回封面/队列时
        // task id 变化自动取消旧请求，旧歌曲的异步结果不会覆盖新歌状态。
        .task(id: "\(trackGlobalID)|\(contentMode)") {
            guard contentMode == .lyrics else { return }
            await loadLyricsForMiniPlayer()
        }
    }

    // MARK: - 顶部三态内容面板

    /// 大封面区域统一外壳：三种模式共用完全相同的 frame 与圆角，切换只在面板内部
    /// 发生，不会引起窗口、歌名、进度条或按钮布局跳动。
    @ViewBuilder
    private func miniHeroContent(size: CGFloat) -> some View {
        Group {
            switch contentMode {
            case .artwork:
                artworkContent(size: size)
            case .lyrics:
                lyricsContent(size: size)
            case .queue:
                queueContent(size: size)
            }
        }
        .frame(width: size, height: size)
        // 歌词 / 队列使用与 Mini Player 协调的 surface 底色；封面模式时被图片覆盖。
        .background(theme.colorTokens.surface.color.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: MacUIVisualTokens.MiniPlayer.artworkCornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.20), value: contentMode)
    }

    /// 封面模式：直接复用原有大号封面实现（artworkKey / ArtworkStore / ImagePipeline
    /// / 圆角 / 比例完全不变，只是提取为独立子视图）。
    private func artworkContent(size: CGFloat) -> some View {
        ArtworkView(
            title: model.currentTrack.albumTitle,
            artworkKey: model.currentTrack.artworkKey,
            colors: theme.colorTokens,
            size: size,
            serverID: model.currentTrack.serverID,
            cornerRadius: MacUIVisualTokens.MiniPlayer.artworkCornerRadius
        )
        .accessibilityLabel(String(localized: "封面", bundle: .module))
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
    }

    // MARK: - 歌词模式

    @ViewBuilder
    private func lyricsContent(size: CGFloat) -> some View {
        Group {
            switch lyricsState {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.colorTokens.accent.color)
                    Text(String(localized: "正在加载歌词…", bundle: .module))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .available(lyrics) where !lyrics.lines.isEmpty:
                if lyrics.isSynced && lyrics.lines.contains(where: { $0.startTime != nil }) {
                    syncedLyricsView(lyrics, size: size)
                } else {
                    plainLyricsView(lyrics)
                }
            case .available:
                emptyLyricsView
            case .unavailable:
                emptyLyricsView
            case .error:
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "歌词加载失败", bundle: .module))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text(String(localized: "暂无歌词", bundle: .module))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 同步歌词：当前行垂直居中且最醒目，上下行作为上下文，随播放进度自动滚动。
    /// 滚动只在「当前行下标真正变化」时触发一次——position 每秒更新几十次，
    /// 但 ScrollView 只跨句时滚动，避免每帧 scrollTo。
    private func syncedLyricsView(_ lyrics: LyricsDocument, size: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    // 顶部/底部留出半屏空间，保证首行和末行也能滚动到垂直居中。
                    Color.clear.frame(height: max(12, size / 2 - 18))
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let isCurrent = activeLyricIndex == index
                        Text(line.text)
                            .font(.system(size: isCurrent ? 19 : 15, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? theme.colorTokens.primaryText.color : theme.colorTokens.secondaryText.color)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .opacity(isCurrent ? 1 : 0.55)
                            .id(index)
                    }
                    Color.clear.frame(height: max(12, size / 2 - 18))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .onChange(of: activeLyricIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            // 首次出现定位：视图创建时若已经处于歌词中段（activeLyricIndex 非 nil），
            // onChange 不会为初始值执行，先无动画定位到当前行；后续跨行仍走上面的
            // 0.22s 动画。切歌时 task id 变化，重新定位到新歌当前行。
            .task(id: trackGlobalID) {
                guard let index = activeLyricIndex else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    /// 纯文本歌词（无逐行时间戳）：不伪造同步，静态居中文本，由用户手动滚动。
    private func plainLyricsView(_ lyrics: LyricsDocument) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(16)
        }
    }

    /// 同步歌词的当前行：遍历时间戳，position 落在哪个区间就是哪一行。
    private var activeLyricIndex: Int? {
        guard case let .available(lyrics) = lyricsState else { return nil }
        guard lyrics.isSynced, lyrics.lines.contains(where: { $0.startTime != nil }) else { return nil }
        let position = playbackStore.position
        var index: Int?
        for (i, line) in lyrics.lines.enumerated() {
            if let start = line.startTime, start <= position + 0.15 { index = i }
        }
        return index
    }

    /// 歌词加载只在 contentMode == .lyrics 时触发；切歌后旧任务被 .task(id:) 取消，
    /// 这里再用 trackGlobalID + contentMode 双保险，防止旧歌曲异步结果覆盖新歌状态。
    private func loadLyricsForMiniPlayer() async {
        let requestedTrackID = trackGlobalID
        lyricsState = .loading
        let lyrics = await model.loadLyrics(for: model.currentTrack)
        guard requestedTrackID == trackGlobalID, contentMode == .lyrics else { return }
        if let lyrics, !lyrics.lines.isEmpty {
            lyricsState = .available(lyrics)
        } else {
            lyricsState = .unavailable
        }
    }

    // MARK: - 队列模式

    /// 当前曲目开始的队列片段（当前曲目 + 后续，最多 20 首）。
    /// 绝不把上万首全库队列一次性渲染进 220×220 面板。
    /// R05：返回带独立 UUID 身份的 QueueEntry，重复歌曲可安全渲染。
    private var miniQueueSlice: [QueueEntry] {
        let entries = queueStore.entries
        guard let currentIndex = queueStore.currentIndex, entries.indices.contains(currentIndex) else {
            return Array(entries.prefix(20))
        }
        return Array(entries[currentIndex..<min(currentIndex + 20, entries.count)])
    }

    @ViewBuilder
    private func queueContent(size: CGFloat) -> some View {
        let entries = miniQueueSlice
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(String(localized: "队列为空", bundle: .module))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { relativeIndex, entry in
                        miniQueueRow(entry.track, relativeIndex: relativeIndex, entryID: entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
    }

    private func miniQueueRow(_ queueTrack: Track, relativeIndex: Int, entryID: UUID) -> some View {
        let isCurrent = queueTrack.macGlobalID == model.currentTrack.macGlobalID
        return Button {
            // R05：按队列项 UUID 播放——重复歌曲点第二个 A 就播第二个 A。
            model.playQueueEntry(id: entryID)
        } label: {
            HStack(spacing: 8) {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.colorTokens.accent.color)
                        .frame(width: 16)
                } else {
                    Text("\(relativeIndex + 1)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(queueTrack.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                        .lineLimit(1)
                    Text(queueTrack.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? theme.colorTokens.accent.color.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "播放《\(queueTrack.title)》，艺术家 \(queueTrack.artistName)", bundle: .module))
    }

    // MARK: - 模式切换

    private func toggleContentMode(_ target: MacMiniPlayerContentMode) {
        withAnimation(.easeInOut(duration: 0.20)) {
            contentMode = contentMode == target ? .artwork : target
        }
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
            Text(hasTrack ? model.currentTrack.title : String(localized: "未在播放", bundle: .module))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(hasTrack ? model.currentTrack.artistName : String(localized: "选择歌曲开始播放", bundle: .module))
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
        .accessibilityLabel(String(localized: "上一首", bundle: .module))
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
        .accessibilityLabel(String(localized: "播放 / 暂停", bundle: .module))
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
        .accessibilityLabel(String(localized: "下一首", bundle: .module))
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
        .accessibilityLabel(model.currentTrack.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
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
        .help(String(localized: "音量", bundle: .module))
        .accessibilityLabel(String(localized: "音量", bundle: .module))
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
            .accessibilityLabel(String(localized: "音量", bundle: .module))
        }
    }

    /// 大号 Mini 第二排：歌词按钮。点击在 歌词 ↔ 封面 之间切换。
    private var lyricsButton: some View {
        Button {
            toggleContentMode(.lyrics)
        } label: {
            Image(systemName: contentMode == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                .foregroundStyle(contentMode == .lyrics ? theme.colorTokens.accent.color : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help(String(localized: "歌词", bundle: .module))
        .accessibilityLabel(String(localized: "歌词", bundle: .module))
    }

    /// 大号 Mini 第二排：队列按钮。点击在 队列 ↔ 封面 之间切换。
    private var queueButton: some View {
        Button {
            toggleContentMode(.queue)
        } label: {
            Image(systemName: "music.note.list")
                .foregroundStyle(contentMode == .queue ? theme.colorTokens.accent.color : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help(String(localized: "队列", bundle: .module))
        .accessibilityLabel(String(localized: "队列", bundle: .module))
    }

    private var artworkToggleButton: some View {
        Button {
            hideArtwork.toggle()
        } label: {
            Image(systemName: hideArtwork ? "rectangle" : "rectangle.fill")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help(hideArtwork ? String(localized: "显示封面", bundle: .module) : String(localized: "隐藏封面", bundle: .module))
        .accessibilityLabel(hideArtwork ? String(localized: "显示封面", bundle: .module) : String(localized: "隐藏封面", bundle: .module))
    }

    private var returnMainButton: some View {
        Button {
            MacWindowVisibilityCoordinator.shared.restoreMainPlayer(expandPlayer: true)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .help(String(localized: "返回正在播放", bundle: .module))
        .accessibilityLabel(String(localized: "返回正在播放", bundle: .module))
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
