import AVKit
import AgentKit
import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 迷你播放条内部内容（不含背景与外壳）。iOS 双层 Dock 共用同一套布局，
/// 外层尺寸、玻璃材质与边距由调用方（BottomGlassBarShell）统一决定。
struct MiniPlayerContent: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var height: CGFloat = 56
    /// 展开态为 1；收拢为底部中间胶囊时连续收至 0。
    /// 这样同一根播放条仍保留曲目信息，只把前后切歌控制收起。
    var skipControlsVisibility: CGFloat = 1

    private var coverSize: CGFloat { min(42, max(36, height - 14)) }
    private var displayTitle: String {
        model.currentTrack.id.rawValue == "placeholder" ? String(localized: "音乐正在赶来喵", bundle: .module) : model.currentTrack.title
    }

    var body: some View {
        // 迷你播放条只保留封面、曲目信息与播放控制；进度仅在“正在播放”完整页提供。
        HStack(spacing: 0) {
            ArtworkView(
                title: model.currentTrack.albumTitle,
                artworkKey: model.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: coverSize,
                serverID: model.currentTrack.serverID,
                cornerRadius: 8
            )
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .lineLimit(1)
                Text(model.currentTrack.artistName)
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityPlaybackLabel)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                skipControl(
                    systemImage: "backward.fill",
                    action: model.previous,
                    isEnabled: model.canGoPrevious,
                    accessibilityLabel: String(localized: "上一首", bundle: .module)
                )

                Button(action: model.togglePlayback) {
                    Image(systemName: model.playbackState == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                }
                .accessibilityLabel(model.playbackState == .playing ? String(localized: "暂停", bundle: .module) : String(localized: "播放", bundle: .module))

                skipControl(
                    systemImage: "forward.fill",
                    action: model.next,
                    isEnabled: model.canGoNext,
                    accessibilityLabel: String(localized: "下一首", bundle: .module)
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    /// VoiceOver 播放状态描述：歌曲 + 艺术家 + 播放状态。
    private var accessibilityPlaybackLabel: String {
        let state: String
        switch model.playbackState {
        case .playing: state = String(localized: "播放中", bundle: .module)
        case .paused: state = String(localized: "已暂停", bundle: .module)
        default: state = String(localized: "未播放", bundle: .module)
        }
        return String(localized: "\(model.currentTrack.title)，\(model.currentTrack.artistName)，\(state)", bundle: .module)
    }

    private var normalizedSkipControlsVisibility: CGFloat {
        min(max(skipControlsVisibility, 0), 1)
    }

    private func skipControl(
        systemImage: String,
        action: @escaping () -> Void,
        isEnabled: Bool,
        accessibilityLabel: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(theme.colorTokens.primaryText.color)
        }
        .frame(width: 44 * normalizedSkipControlsVisibility, height: 44)
        .opacity(normalizedSkipControlsVisibility)
        .scaleEffect(normalizedSkipControlsVisibility, anchor: systemImage == "backward.fill" ? .trailing : .leading)
        .disabled(!isEnabled || normalizedSkipControlsVisibility < 0.05)
        .allowsHitTesting(normalizedSkipControlsVisibility >= 0.05)
        .accessibilityHidden(normalizedSkipControlsVisibility < 0.05)
        .accessibilityLabel(accessibilityLabel)
    }

}

/// 紧凑 Dock 内的播放内容。与展开态共用真实播放状态与操作，但缩为单行，
/// 让首页入口和 AI 助手入口保持独立的圆形触控区域。
struct CompactMiniPlayerContent: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    private var title: String {
        model.currentTrack.id.rawValue == "placeholder" ? String(localized: "音乐正在赶来喵", bundle: .module) : model.currentTrack.title
    }

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(
                title: model.currentTrack.albumTitle,
                artworkKey: model.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: 36,
                serverID: model.currentTrack.serverID,
                cornerRadius: 8
            )

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.colorTokens.primaryText.color)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: model.togglePlayback) {
                Image(systemName: model.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 44)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.playbackState == .playing ? String(localized: "暂停", bundle: .module) : String(localized: "播放", bundle: .module))

        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

struct NowPlayingView: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject private var playbackStore: PlaybackStore
    @ObservedObject private var queueStore: PlaybackQueuePresentationStore
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var page = NowPlayingPage.player
    @State private var isPlaylistSheetPresented = false
    @State private var showsMoreActions = false
    @State private var showsAudioTechnicalInfo = false
    @State private var showsTrackInformation = false
    /// 拖动进度条时暂存的 seek 目标：松手才真正 seek（Apple Music 行为）。
    @State private var pendingSeek: Double?
#if os(iOS)
    @State private var queueEditMode = EditMode.inactive
#endif

    /// 跨服务器稳定的当前曲目身份：不同服务器可能复用相同 remote TrackID，
    /// 切歌清 pendingSeek 时必须按 serverID + trackID 双键判断。
    private var currentTrackIdentity: String {
        "\(model.currentTrack.serverID.rawValue):\(model.currentTrack.id.rawValue)"
    }

    /// 拖动中的 UI 显示位置：pendingSeek 是 0...1 比例，换算成秒；
    /// 未拖动时显示真实播放位置，保证松手前文字与滑块同步。
    private var displayedPlaybackPosition: TimeInterval {
        Self.displayedPlaybackPosition(
            pendingSeek: pendingSeek,
            actualPosition: playbackStore.position,
            duration: model.effectivePlaybackDuration
        )
    }

    /// 纯函数：供 UI 显示与回归测试共用。
    static func displayedPlaybackPosition(
        pendingSeek: Double?,
        actualPosition: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        if let pendingSeek {
            return min(max(pendingSeek, 0), 1) * duration
        }
        return actualPosition
    }

    init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self._queueStore = ObservedObject(wrappedValue: model.queueStore)
        self.theme = theme
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.colorTokens.accent.color.opacity(0.42), theme.colorTokens.background.color, theme.colorTokens.accentSecondary.color.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: AuralisSpacing.large) {
                header
                Picker(String(localized: "播放页面", bundle: .module), selection: $page) {
                    ForEach(NowPlayingPage.allCases) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                GeometryReader { geo in
                    playbackContent(in: geo)
                }
            }
            .padding(AuralisSpacing.large)
            // iPad 宽屏可读宽度：内容居中并限宽（IOSLayoutMetrics.playerContentMaxWidth），
            // 避免整页被拉成一条横贯全屏的宽条；iPhone 紧凑布局保持原样（不限宽）。
            // 这是同一 View 的局部宽度自适应，不切换 UI 架构。
            .frame(maxWidth: horizontalSizeClass == .regular ? IOSLayoutMetrics.playerContentMaxWidth : .infinity)
        }
        .foregroundStyle(theme.colorTokens.primaryText.color)
        .sheet(isPresented: $isPlaylistSheetPresented) {
            AddToPlaylistSheet(model: model, theme: theme, track: model.currentTrack)
        }
        .sheet(isPresented: $showsTrackInformation) {
            TrackInformationSheet(model: model, theme: theme, track: model.currentTrack)
        }
        .confirmationDialog(String(localized: "更多操作", bundle: .module), isPresented: $showsMoreActions, titleVisibility: .visible) {
            Button(String(localized: "添加到歌单", bundle: .module)) { isPlaylistSheetPresented = true }
            if model.isDownloading(model.currentTrack) {
                let progress = model.downloadingProgress[model.currentTrack.id] ?? 0
                Button(
                    String(localized: "取消下载（\(Int(progress * 100))%）", bundle: .module),
                    role: .destructive
                ) {
                    model.cancelDownload(model.currentTrack)
                }
            } else if model.isDownloaded(model.currentTrack) {
                Button(String(localized: "删除下载", bundle: .module), role: .destructive) { model.removeDownload(model.currentTrack) }
            } else {
                Button(String(localized: "下载到本地", bundle: .module)) { model.download(model.currentTrack) }
            }
            Button(String(localized: "前往专辑", bundle: .module)) { openCurrentAlbum() }
                .disabled(currentAlbum == nil)
            Button(String(localized: "前往艺术家", bundle: .module)) { openCurrentArtist() }
                .disabled(currentArtist == nil)
            Button(String(localized: "由此继续播放", bundle: .module)) { continueWithSimilarQueue() }
            Button(String(localized: "歌曲鉴赏", bundle: .module)) { appreciateCurrentSong() }
            Button(String(localized: "歌曲信息", bundle: .module)) { showsTrackInformation = true }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        }
        // 切歌时旧歌曲的 pendingSeek 不能污染下一首歌（拖动中切歌保护）。
        .onChange(of: currentTrackIdentity) { _, _ in
            pendingSeek = nil
        }
    }

    private var header: some View {
        HStack {
#if os(iOS)
            // iOS：全屏弹窗支持下拉关闭，不显示返回按钮。
#else
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
            }
            .buttonStyle(HapticBorderedButtonStyle())
            .accessibilityLabel(String(localized: "关闭", bundle: .module))
#endif
            Spacer(minLength: 0)
            VStack {
                Text(String(localized: "正在播放", bundle: .module)).font(.caption.weight(.semibold))
                Text(model.currentTrack.albumTitle)
                    .font(.caption2)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
#if os(iOS)
            // 右侧无内容，保持标题居中；更多操作已移到播放控制区。
#else
            Color.clear.frame(width: 28, height: 28)
#endif
        }
    }

    /// “更多”必须单击即展开；不用 Menu，避免在自定义按钮样式层级里退化为长按菜单。
    private var moreMenu: some View {
        Button {
            showsMoreActions = true
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HapticBorderedButtonStyle())
        .accessibilityLabel(String(localized: "更多操作", bundle: .module))
    }

    /// 三个页面只替换上方内容区；曲目信息、进度和控制区始终是同一套视图固定在底部。
    /// 这样切到歌词 / 队列时不会把整个播放界面换走，布局也不会上下跳动。
    private func playbackContent(in geo: GeometryProxy) -> some View {
        let compactHeight = geo.size.height < 650
        let sectionSpacing: CGFloat = compactHeight ? 10 : 15
        let playButtonSize: CGFloat = compactHeight ? 56 : 64
        let estimatedControlHeight: CGFloat = compactHeight ? 264 : 294
        let heroHeight = max(geo.size.height - estimatedControlHeight, 190)
        // 保留海报主体感，但四周留出明确呼吸空间，避免贴近分段控件和曲目信息。
        let artworkSide = min(350, geo.size.width * 0.84, heroHeight * 0.88)
        // Glow 画布以封面为中心向外扩散；允许的最大值不超过页面可用高度，
        // 避免光效被 TabView 页面边缘裁成方框，同时封面本体尺寸不受影响。
        let glowCanvasSize = max(0, heroHeight - AuralisSpacing.medium * 2)

        return VStack(spacing: sectionSpacing) {
            TabView(selection: $page) {
                lyrics
                    .tag(NowPlayingPage.lyrics)
                artworkHero(side: artworkSide, compactHeight: compactHeight, glowCanvasSize: glowCanvasSize)
                    .tag(NowPlayingPage.player)
                queue
                    .tag(NowPlayingPage.queue)
            }
#if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
#else
            .tabViewStyle(.automatic)
#endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            playbackControls(sectionSpacing: sectionSpacing, playButtonSize: playButtonSize)
                .frame(maxWidth: 560)
                // 控制区贴近可用区域底部，不再用下方 Spacer 把它悬在页面中间。
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AuralisSpacing.medium)
    }

    /// 上方海报区：在分段控件以下的空白区居中，保留轻微下移以强化上下留白。
    private func artworkHero(side: CGFloat, compactHeight: Bool, glowCanvasSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: AuralisSpacing.medium)
            ZStack {
                NowPlayingArtworkGlowView(
                    isPlaying: model.playbackState == .playing,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: side,
                    serverID: model.currentTrack.serverID,
                    maxCanvasSize: glowCanvasSize
                )
                // 封面本体只保留轻微中性黑色阴影负责层级；彩色环境光全部由
                // NowPlayingArtworkGlowView（真实封面模糊副本）承担，避免三套光叠加。
                ArtworkView(
                    title: model.currentTrack.albumTitle,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: side,
                    serverID: model.currentTrack.serverID
                )
                .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 2)
            }
            Spacer(minLength: AuralisSpacing.xSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playbackControls(sectionSpacing: CGFloat, playButtonSize: CGFloat) -> some View {
        VStack(spacing: sectionSpacing) {
            // 标题和艺术家始终以整行中心为基准；超长内容只从头到尾慢速移动一次。
            // 左右各预留 56pt 对称安全区：长标题滚动时不会滑到不喜欢/收藏按钮下面，
            // 也不会把歌名从屏幕中心推走。
            ZStack {
                VStack(spacing: AuralisSpacing.xSmall) {
                    OneShotMarqueeText(
                        text: model.currentTrack.title,
                        font: .title2.bold(),
                        color: theme.colorTokens.primaryText.color,
                        height: 30
                    )
                    OneShotMarqueeText(
                        text: model.currentTrack.artistName,
                        font: .subheadline,
                        color: theme.colorTokens.secondaryText.color,
                        height: 22
                    )
                }
                .padding(.horizontal, 56)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(nowPlayingAccessibilityLabel)

                // 不喜欢（左）与收藏（右）严格镜像：距屏幕边缘一致、frame 一致、
                // 命中区域一致、symbol 大小一致；标题以屏幕中心为基准独立居中。
                HStack(spacing: 0) {
                    dislikeButton
                    Spacer(minLength: 0)
                    favoriteButton
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: AuralisSpacing.xSmall) {
                ThinSlider(
                    value: model.playbackProgress,
                    accent: theme.colorTokens.accent.color,
                    track: theme.colorTokens.separator.color.opacity(0.4),
                    thumb: Color.white,
                    onEditingChanged: { editing in
                        if !editing, let pending = pendingSeek {
                            model.playbackProgress = pending
                            pendingSeek = nil
                        }
                    },
                    onValueChanged: { pendingSeek = $0 },
                    // VoiceOver 单次步进约 ±5 秒（0...1 fraction 空间）。
                    accessibilityStep: min(1, 5 / max(model.effectivePlaybackDuration, 1))
                )
                .accessibilityLabel(String(localized: "播放进度", bundle: .module))
                .accessibilityValue(Text("\(formatDuration(displayedPlaybackPosition)) / \(formatDuration(model.effectivePlaybackDuration))"))
                HStack {
                    Text(formatDuration(displayedPlaybackPosition))
                    Spacer()
                    Text("-" + formatDuration(max(model.effectivePlaybackDuration - displayedPlaybackPosition, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            }

            transportControls(playButtonSize: playButtonSize)
            volumeControl
            bottomInfo
        }
    }

    private var favoriteButton: some View {
        Button { model.toggleFavorite(model.currentTrack) } label: {
            Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(model.currentTrack.isFavorite ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(HapticPlainButtonStyle())
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(model.currentTrack.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
    }

    /// “不喜欢”按钮：与收藏按钮严格镜像。只影响未来自动推荐，
    /// 点击不跳歌、不改变队列、不暂停。
    private var dislikeButton: some View {
        let isDisliked = model.isDisliked(model.currentTrack)
        return Button {
            model.toggleDisliked(model.currentTrack)
        } label: {
            Image(systemName: isDisliked ? "heart.slash.fill" : "heart.slash")
                .font(.title3)
                .foregroundStyle(isDisliked ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(HapticPlainButtonStyle())
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(isDisliked ? String(localized: "取消不喜欢", bundle: .module) : String(localized: "不喜欢", bundle: .module))
        .accessibilityHint(String(localized: "不喜欢的歌曲不会再出现在自动推荐中。", bundle: .module))
        .accessibilityValue(isDisliked ? String(localized: "已标记不喜欢", bundle: .module) : String(localized: "未标记不喜欢", bundle: .module))
    }

    private func transportControls(playButtonSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 播放模式：单个按钮循环切换顺序、随机、列表循环和单曲循环。
            transportItem {
                Button {
                    // 只保留很短的状态过渡，避免默认符号替换动画显得迟缓。
                    withAnimation(.linear(duration: 0.12)) { model.cyclePlayMode() }
                } label: {
                    Image(systemName: model.playMode.symbol)
                        .font(.title3)
                        .foregroundStyle(model.playMode == .list ? theme.colorTokens.secondaryText.color : theme.colorTokens.accent.color)
                        .contentTransition(.identity)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "播放模式：\(model.playMode.title)", bundle: .module))
            }
            transportItem {
                Button(action: model.previous) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!model.canGoPrevious)
                .accessibilityLabel(String(localized: "上一首", bundle: .module))
            }
            transportItem {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.playbackState == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: playButtonSize * 0.4, weight: .bold))
                        .frame(width: playButtonSize, height: playButtonSize)
                        .background(theme.colorTokens.accent.color)
                        .foregroundStyle(theme.colorTokens.background.color)
                        .clipShape(Circle())
                }
                .accessibilityLabel(model.playbackState == .playing ? String(localized: "暂停", bundle: .module) : String(localized: "播放", bundle: .module))
            }
            transportItem {
                Button(action: model.next) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!model.canGoNext)
                .accessibilityLabel(String(localized: "下一首", bundle: .module))
            }
            transportItem {
                moreMenu
            }
        }
        .buttonStyle(HapticPlainButtonStyle())
    }

    private var volumeControl: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            ThinSlider(
                value: Double(model.volume),
                accent: theme.colorTokens.accent.color,
                track: theme.colorTokens.separator.color.opacity(0.4),
                thumb: Color.white,
                onEditingChanged: { _ in },
                onValueChanged: { model.setVolume(Float($0)) },
                // VoiceOver 单次步进 ±5%。
                accessibilityStep: 0.05
            )
            .accessibilityLabel(String(localized: "音量", bundle: .module))
            .accessibilityValue(Text("\(Int(model.volume * 100))%"))
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .frame(maxWidth: 420)
    }

    private var bottomInfo: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showsAudioTechnicalInfo.toggle() }
            } label: {
                Label(audioTechnicalLabel, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .buttonStyle(HapticPlainButtonStyle())
            .accessibilityLabel(String(localized: "音频格式，点击切换采样率", bundle: .module))
            Spacer()
            RoutePickerView()
                .frame(width: 44, height: 44)
                .accessibilityLabel(String(localized: "AirPlay 输出设备", bundle: .module))
        }
        .frame(maxWidth: 420)
    }

    private var audioTechnicalLabel: String {
        guard showsAudioTechnicalInfo else {
            return model.currentTrack.effectiveCodec?.uppercased() ?? String(localized: "未知", bundle: .module)
        }
        let info = model.currentTrack.sourceInfo
        let sampleRate = info.sampleRate.map { "\($0 / 1_000) kHz" } ?? String(localized: "采样率未知", bundle: .module)
        if let bitDepth = info.bitDepth { return "\(bitDepth)-bit · \(sampleRate)" }
        return sampleRate
    }


    /// 传输区按钮的等宽容器，保证五键严格对称。
    private func transportItem<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
    }

    /// VoiceOver 播放状态描述（含专辑与状态）。
    private var nowPlayingAccessibilityLabel: String {
        let state: String
        switch model.playbackState {
        case .playing: state = String(localized: "播放中", bundle: .module)
        case .paused: state = String(localized: "已暂停", bundle: .module)
        default: state = String(localized: "未播放", bundle: .module)
        }
        return String(localized: "\(model.currentTrack.title)，\(model.currentTrack.artistName)，专辑 \(model.currentTrack.albumTitle)，\(state)", bundle: .module)
    }

    private var currentAlbum: Album? {
        model.catalog.albums.first {
            $0.id == model.currentTrack.albumID && $0.serverID == model.currentTrack.serverID
        }
    }

    private var currentArtist: Artist? {
        model.catalog.artists.first {
            $0.id == model.currentTrack.artistID && $0.serverID == model.currentTrack.serverID
        }
    }

    private func openCurrentAlbum() {
        guard let album = currentAlbum else { return }
        openLibraryDestination(.album(album))
    }

    private func openCurrentArtist() {
        guard let artist = currentArtist else { return }
        openLibraryDestination(.artist(artist))
    }

    private func openLibraryDestination(_ destination: BrowseDestination) {
        dismiss()
        model.isNowPlayingPresented = false
        Task { @MainActor in
            // 先让播放页完成关闭，再呈现资料库详情，避免同一时刻竞争两个 sheet。
            try? await Task.sleep(for: .milliseconds(180))
            model.selectTopLevelSection(.library)
            model.browseDestination = destination
        }
    }

    /// 后台创建独立会话，要求 Agent 真实查询相似曲目并只调用一次 queue_replace。
    private func continueWithSimilarQueue() {
        let track = model.currentTrack
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue).description
        Task { @MainActor in
            if model.assistantIsRunning { model.cancelAssistant() }
            _ = await model.agentCoordinator.newSession()
            model.agentCoordinator.send(
                "以当前歌曲《\(track.title)》—\(track.artistName)（trackID: \(globalID)）为种子，调用 library_get_similar_songs 查找相似歌曲，去重并优先保留高质量版本，生成约 20 首队列；最后只调用一次 queue_replace 替换当前播放队列并开始播放。不要只输出文字建议。",
                intent: .musicDiscovery
            )
        }
    }

    /// 歌曲鉴赏必须进入一个干净的新会话，并明确调用现有 music_appreciate 工具。
    private func appreciateCurrentSong() {
        let track = model.currentTrack
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue).description
        dismiss()
        model.isNowPlayingPresented = false
        Task { @MainActor in
            if model.assistantIsRunning { model.cancelAssistant() }
            _ = await model.agentCoordinator.newSession()
            model.selectTopLevelSection(.assistant)
            model.agentCoordinator.send(
                "请调用 music_appreciate，专业鉴赏《\(track.title)》—\(track.artistName)（trackID: \(globalID)），并按应用规定的鉴赏格式输出，区分已核验事实、专业听感与大众评价。",
                intent: .musicAppreciation
            )
        }
    }

    /// 当前应高亮的歌词行：仅对带时间轴的同步歌词按播放位置计算。
    private var currentLyricIndex: Int? {
        guard let document = model.currentLyrics, document.isSynced else { return nil }
        let position = playbackStore.position
        var result: Int?
        for (index, line) in document.lines.enumerated() {
            guard let start = line.startTime else { continue }
            if start <= position {
                result = index
            } else {
                break
            }
        }
        return result
    }

    private var lyrics: some View {
        let activeIndex = currentLyricIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: AuralisSpacing.large) {
                    if let document = model.currentLyrics {
                        ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = index == activeIndex
                            Text(line.text)
                                .font(.title3.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .animation(.easeInOut(duration: 0.16), value: isCurrent)
                                .id(index)
                        }
                    } else {
                        AuralisEmptyState(
                            icon: "quote.bubble",
                            title: String(localized: "暂无歌词", bundle: .module),
                            message: String(localized: "服务器没有返回歌词，稍后可从本地文件或 MusicBrainz 候选补全。", bundle: .module),
                            colors: theme.colorTokens
                        )
                    }
                }
                .frame(maxWidth: 600, alignment: .center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AuralisSpacing.huge)
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .task(id: model.currentLyrics?.id) {
                guard let activeIndex else { return }
                proxy.scrollTo(activeIndex, anchor: .center)
            }
        }
    }

    private var queue: some View {
        List {
            // R05：队列项身份 = entry.id（UUID），重复歌曲可安全渲染。
            ForEach(queueStore.entries) { entry in
                let track = entry.track
                Button {
                    // R05：按队列项 UUID 播放——重复歌曲点第二个 A 就播第二个 A。
                    model.playQueueEntry(id: entry.id)
                } label: {
                    TrackRow(track: track, isCurrent: track.isSame(as: model.currentTrack), theme: theme)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(HapticPlainButtonStyle())
                    .accessibilityLabel(String(localized: "播放《\(track.title)》，艺术家 \(track.artistName)", bundle: .module))
                    .listRowBackground(Color.clear)
            }
#if os(iOS)
            .onDelete { model.removeFromQueue(atOffsets: $0) }
            .onMove { model.moveQueue(from: $0, to: $1) }
#endif
        }
        .scrollContentBackground(.hidden)
        .background(theme.colorTokens.surface.color.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.large, style: .continuous))
#if os(iOS)
        .environment(\.editMode, $queueEditMode)
        .overlay(alignment: .topTrailing) {
            if !model.queue.isEmpty {
                Button(queueEditMode.isEditing ? String(localized: "完成", bundle: .module) : String(localized: "编辑", bundle: .module)) {
                    withAnimation { queueEditMode = queueEditMode.isEditing ? .inactive : .active }
                }
                .font(.caption.weight(.semibold))
                .padding(6)
                .background(theme.colorTokens.surface.color)
                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
                .padding(.top, 4)
            }
        }
#endif
    }
}

private enum NowPlayingPage: String, CaseIterable, Identifiable {
    case lyrics, player, queue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyrics: String(localized: "歌词", bundle: .module)
        case .player: String(localized: "正在播放", bundle: .module)
        case .queue: String(localized: "队列", bundle: .module)
        }
    }
}

private struct MarqueeTextWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeIdentity: Hashable {
    let text: String
    let textWidth: Int
    let containerWidth: Int
}

/// 播放页标题是否需要跑马灯的纯布局规则，独立出来避免把“略微可缩放显示”的
/// 名称误判为溢出。测试覆盖正常、临界和真实超宽三种情况。
struct MarqueeLayoutPolicy: Sendable {
    static let minimumScaleFactor: CGFloat = 0.86

    static func shouldScroll(textWidth: CGFloat, containerWidth: CGFloat) -> Bool {
        guard containerWidth > 0 else { return false }
        return textWidth > containerWidth / minimumScaleFactor
    }
}

/// 只在内容溢出时从开头慢速移动到末尾一次，停在末尾，不循环也不来回闪动。
private struct OneShotMarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var travel: CGFloat = 0

    var body: some View {
        // GeometryReader 先接受父级给出的有限宽度，内部的 fixedSize 文本只能在这个
        // 裁剪窗口里移动，绝不能再参与父级横向测量、把整张播放页撑宽。
        GeometryReader { proxy in
            let containerWidth = max(proxy.size.width, 1)
            // 最多允许轻微缩小到 86%。能完整容纳的标题保持静止；只有连轻微缩小
            // 也放不下的内容才滚动，避免短歌名等待很久才进入可视区域。
            let canFitWithoutScrolling = !MarqueeLayoutPolicy.shouldScroll(
                textWidth: textWidth,
                containerWidth: containerWidth
            )
            let overflow = canFitWithoutScrolling ? 0 : max(textWidth - containerWidth, 0)
            let identity = MarqueeIdentity(
                text: text,
                textWidth: Int(textWidth.rounded()),
                containerWidth: Int(containerWidth.rounded())
            )

            ZStack(alignment: overflow > 1 ? .leading : .center) {
                if canFitWithoutScrolling {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(MarqueeLayoutPolicy.minimumScaleFactor)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: -min(travel, overflow))
                }
            }
            .frame(width: containerWidth, height: height, alignment: overflow > 1 ? .leading : .center)
            // 用背景中的固有尺寸文本做判断；background 不参与父级尺寸计算，既能得到
            // 完整文字宽度，也不会再次把播放页横向撑开。
            .background {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(
                                key: MarqueeTextWidthPreferenceKey.self,
                                value: textProxy.size.width
                            )
                        }
                    }
            }
            .clipped()
            .task(id: identity) {
                var resetTransaction = Transaction(animation: nil)
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) { travel = 0 }
                guard overflow > 1, !reduceMotion else { return }
                try? await Task.sleep(for: .milliseconds(1_600))
                guard !Task.isCancelled else { return }
                // 约每秒 10pt；只从头到尾走一遍，完成后停在末尾。
                withAnimation(.linear(duration: max(9, Double(overflow / 10)))) {
                    travel = overflow
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipped()
        .onPreferenceChange(MarqueeTextWidthPreferenceKey.self) { textWidth = $0 }
    }
}

/// 歌曲信息页的公开音乐资料状态。它只负责把偏好和三个来源的独立结果折叠成
/// 用户可理解的页面状态；关闭来源不会被误报成“暂无数据”。
enum ExternalMusicInformationViewState: Equatable {
    case disabled
    case loading
    case available
    case noData
    case failed
    case rateLimited
    case unavailable

    static func resolve(
        preferences: ExternalMusicPreferences,
        isLoading: Bool,
        metrics: CommunityMusicMetrics?
    ) -> Self {
        let enabledSources = CommunityMusicSource.allCases.filter(preferences.isEnabled)
        guard preferences.enabled, !enabledSources.isEmpty else { return .disabled }
        if isLoading { return .loading }
        guard let metrics else { return .failed }

        let statuses = enabledSources.compactMap { metrics.value(for: $0)?.status }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == .disabled }) { return .disabled }
        if statuses.contains(.available) { return .available }
        if statuses.contains(.loading) { return .loading }
        if statuses.contains(.rateLimited) { return .rateLimited }
        if statuses.contains(.unavailable) { return .unavailable }
        if statuses.contains(.failed) { return .failed }
        return .noData
    }
}

/// 播放页“歌曲信息”：仅展示真实本地目录与播放状态，不暴露流地址或凭据。
private struct TrackInformationSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var externalResult: AgentExternalMusicResult?
    @State private var isLoadingExternalData = true
    // AppStorage 只负责让打开中的信息页在设置变化时立即重算；权限判定的唯一模型仍是
    // ExternalMusicPreferences，网络层还会执行同一份 gating。
    @AppStorage(ExternalMusicPreferences.Keys.enabled) private var externalMusicEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.musicBrainz) private var musicBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.critiqueBrainz) private var critiqueBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.listenBrainz) private var listenBrainzEnabled = true

    private var externalMusicPreferences: ExternalMusicPreferences {
        ExternalMusicPreferences.current()
    }

    private var externalMusicViewState: ExternalMusicInformationViewState {
        .resolve(
            preferences: externalMusicPreferences,
            isLoading: isLoadingExternalData,
            metrics: externalResult?.metrics
        )
    }

    private var externalMusicRequestID: String {
        [
            track.serverID.rawValue,
            track.id.rawValue,
            externalMusicEnabled.description,
            musicBrainzEnabled.description,
            critiqueBrainzEnabled.description,
            listenBrainzEnabled.description,
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "基本信息", bundle: .module)) {
                    infoRow(String(localized: "歌曲", bundle: .module), track.title)
                    infoRow(String(localized: "艺术家", bundle: .module), track.artistName)
                    infoRow(String(localized: "专辑", bundle: .module), track.albumTitle)
                    infoRow(String(localized: "时长", bundle: .module), formatDuration(track.duration))
                    infoRow(String(localized: "年份", bundle: .module), track.year.map(String.init) ?? String(localized: "未知", bundle: .module))
                    infoRow(String(localized: "流派", bundle: .module), track.genres.isEmpty ? String(localized: "未知", bundle: .module) : track.genres.joined(separator: "、"))
                    infoRow(String(localized: "语言", bundle: .module), track.language ?? String(localized: "未知", bundle: .module))
                }
                Section(String(localized: "曲目位置", bundle: .module)) {
                    infoRow(String(localized: "碟片", bundle: .module), track.discNumber.map(String.init) ?? String(localized: "未知", bundle: .module))
                    infoRow(String(localized: "曲目", bundle: .module), track.trackNumber.map(String.init) ?? String(localized: "未知", bundle: .module))
                }
                Section(String(localized: "音频质量", bundle: .module)) {
                    infoRow(String(localized: "格式", bundle: .module), track.effectiveCodec?.uppercased() ?? String(localized: "未知", bundle: .module))
                    infoRow(String(localized: "采样率", bundle: .module), track.sourceInfo.sampleRate.map { "\($0) Hz" } ?? String(localized: "未知", bundle: .module))
                    infoRow(String(localized: "位深", bundle: .module), track.sourceInfo.bitDepth.map { "\($0) bit" } ?? String(localized: "未知", bundle: .module))
                    infoRow(String(localized: "码率", bundle: .module), track.sourceInfo.bitRate.map { "\($0) kbps" } ?? String(localized: "未知", bundle: .module))
                    infoRow(String(localized: "声道", bundle: .module), track.sourceInfo.channelCount.map { "\($0)" } ?? String(localized: "未知", bundle: .module))
                }
                Section(String(localized: "状态", bundle: .module)) {
                    infoRow(String(localized: "收藏", bundle: .module), track.isFavorite ? String(localized: "已收藏", bundle: .module) : String(localized: "未收藏", bundle: .module))
                    infoRow(String(localized: "评分", bundle: .module), track.rating.map { "\($0)/5" } ?? String(localized: "未评分", bundle: .module))
                    infoRow(String(localized: "播放次数", bundle: .module), String(localized: "\(model.playCounts[track.id] ?? 0) 次", bundle: .module))
                    infoRow(String(localized: "本地下载", bundle: .module), model.isDownloaded(track) ? String(localized: "已下载", bundle: .module) : String(localized: "未下载", bundle: .module))
                    infoRow(String(localized: "歌词", bundle: .module), model.currentLyrics == nil ? String(localized: "无", bundle: .module) : String(localized: "已获取", bundle: .module))
                }
                Section(String(localized: "大众评价", bundle: .module)) {
                    switch externalMusicViewState {
                    case .disabled:
                        Text(String(localized: "公开音乐数据已关闭。", bundle: .module))
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    case .loading:
                        HStack(spacing: AuralisSpacing.small) {
                            ProgressView()
                            Text(String(localized: "正在按需查询公开音乐资料…", bundle: .module))
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                    case .available:
                        if let result = externalResult {
                            communitySourceLink(.musicBrainz, result: result, preferences: externalMusicPreferences)
                            communitySourceLink(.critiqueBrainz, result: result, preferences: externalMusicPreferences)
                            communitySourceLink(.listenBrainz, result: result, preferences: externalMusicPreferences)
                        }
                        Text(String(localized: "各来源含义不同，评分、评论数和收听量不会合并为综合分。", bundle: .module))
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    case .noData:
                        Text(String(localized: "暂无可核验的大众评价数据。", bundle: .module))
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    case .failed:
                        Text(String(localized: "公开音乐数据暂时不可用。", bundle: .module))
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    case .rateLimited:
                        Text(String(localized: "公开音乐数据请求过于频繁，请稍后再试。", bundle: .module))
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    case .unavailable:
                        Text(String(localized: "公开音乐数据暂时不可用，请检查网络连接。", bundle: .module))
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.colorTokens.background.color)
            .navigationTitle(String(localized: "歌曲信息", bundle: .module))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成", bundle: .module)) { dismiss() }
                }
            }
            .task(id: externalMusicRequestID) {
                externalResult = nil
                let preferences = externalMusicPreferences
                let hasEnabledSource = CommunityMusicSource.allCases.contains(where: preferences.isEnabled)
                guard preferences.enabled, hasEnabledSource else {
                    isLoadingExternalData = false
                    return
                }
                isLoadingExternalData = true
                let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
                externalResult = await model.musicEnrichment.enrich(track: track, globalID: globalID)
                isLoadingExternalData = false
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 540)
#endif
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AuralisSpacing.medium) {
            Text(label)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Spacer(minLength: AuralisSpacing.medium)
            Text(value)
                .foregroundStyle(theme.colorTokens.primaryText.color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func communitySourceLink(
        _ source: CommunityMusicSource,
        result: AgentExternalMusicResult,
        preferences: ExternalMusicPreferences
    ) -> some View {
        if preferences.isEnabled(source) {
            let metric = result.metrics.value(for: source)
            NavigationLink {
                CommunityMusicDetailView(source: source, result: result, theme: theme)
            } label: {
                HStack(spacing: AuralisSpacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceTitle(source))
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        if let metric {
                            Text(sourceSummary(metric))
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: AuralisSpacing.small)
                }
            }
        }
    }

    private func sourceSummary(_ metric: CommunityMusicMetric) -> String {
        switch metric.status {
        case .available:
            switch metric.source {
            case .musicBrainz:
                if let rating = metric.rating, let count = metric.ratingCount {
                    return String(format: String(localized: "%.1f / 5 · %d 次评分", bundle: .module), rating, count)
                }
                return String(localized: "有评分数据", bundle: .module)
            case .critiqueBrainz:
                var parts: [String] = []
                if let rating = metric.rating, let count = metric.ratingCount {
                    parts.append(String(format: String(localized: "%.1f / 5 · %d 次评分", bundle: .module), rating, count))
                }
                if let reviews = metric.reviewCount { parts.append(String(localized: "\(reviews) 篇评论", bundle: .module)) }
                return parts.isEmpty ? String(localized: "有评论数据", bundle: .module) : parts.joined(separator: " · ")
            case .listenBrainz:
                var parts: [String] = []
                if let listens = metric.listenCount { parts.append(String(localized: "\(listens) 次收听", bundle: .module)) }
                if let listeners = metric.listenerCount { parts.append(String(localized: "\(listeners) 位听众", bundle: .module)) }
                return parts.isEmpty ? String(localized: "有收听数据", bundle: .module) : parts.joined(separator: " · ")
            }
        case .noData, .notSupported:
            return String(localized: "暂无数据", bundle: .module)
        case .failed:
            return String(localized: "查询失败", bundle: .module)
        case .rateLimited:
            return String(localized: "请求过于频繁", bundle: .module)
        case .unavailable:
            return String(localized: "暂时不可用", bundle: .module)
        case .disabled, .loading:
            return ""
        }
    }

    private func sourceTitle(_ source: CommunityMusicSource) -> String {
        switch source {
        case .musicBrainz: "MusicBrainz"
        case .critiqueBrainz: "CritiqueBrainz"
        case .listenBrainz: "ListenBrainz"
        }
    }

}


/// 添加到歌单弹窗：列出服务器歌单，点选即追加当前歌曲。
struct AddToPlaylistSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.catalog.playlists.isEmpty {
                    AuralisEmptyState(
                        icon: "music.note.list",
                        title: String(localized: "还没有歌单", bundle: .module),
                        message: String(localized: "在服务器上创建歌单后，这里会列出所有可选歌单。", bundle: .module),
                        colors: theme.colorTokens
                    )
                } else {
                    List(model.catalog.playlists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(theme.colorTokens.accent.color)
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                }
                                Spacer()
                                if feedback == playlist.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(theme.colorTokens.success.color)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel(String(localized: "添加到歌单《\(playlist.name)》", bundle: .module))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "添加到歌单", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭", bundle: .module)) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 360)
        #endif
    }

    private func add(to playlist: Playlist) {
        Task {
            let succeeded = await model.addToPlaylist(playlist, track: track)
            if succeeded {
                feedback = playlist.name
                try? await Task.sleep(for: .milliseconds(500))
                dismiss()
            } else {
                feedback = nil
            }
        }
    }
}

/// 跨平台 AVRoutePickerView 包装，让 SwiftUI 能使用系统 AirPlay 路由选择器。
private struct RoutePickerView: View {
    var body: some View {
        #if os(macOS)
        RoutePickerRepresentable()
        #else
        RoutePickerRepresentable()
        #endif
    }
}

#if os(macOS)
private struct RoutePickerRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif


/// Apple Music 风格细滑杆：3pt 圆角轨道 + 高亮填充 + 小圆点滑块。
/// 拖动时滑块放大并实时显示拖动值；松手后由 onEditingChanged(false) 决定提交时机。
/// 提供 VoiceOver adjustable 步进：自绘控件必须支持系统 Slider 同等的上/下滑调整。
private struct ThinSlider: View {
    let value: Double
    let accent: Color
    let track: Color
    let thumb: Color
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void
    /// VoiceOver 单次步进的 fraction（0...1）。进度条传入 5s/时长，音量传入 0.05。
    let accessibilityStep: Double

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = isDragging ? dragValue : min(max(value, 0), 1)
            let thumbSize: CGFloat = isDragging ? 16 : 9
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .frame(height: 3)
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, width * fraction), height: 3)
                Circle()
                    .fill(thumb)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(isDragging ? 0.3 : 0.15), radius: isDragging ? 3 : 1.5, y: 1)
                    .offset(x: max(0, min(width - thumbSize, width * fraction - thumbSize / 2)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let v = min(max(gesture.location.x / width, 0), 1)
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        dragValue = v
                        onValueChanged(v)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        // VoiceOver：上/下滑调整，语义与系统 Slider 一致。
        // 与拖动路径共用同一提交语义（onEditingChanged(true) → onValueChanged → onEditingChanged(false)），
        // 进度条调用端会在 onEditingChanged(false) 时提交 pendingSeek，不会触发两套 seek。
        .accessibilityAdjustableAction { direction in
            let current = isDragging ? dragValue : min(max(value, 0), 1)
            let next: Double
            switch direction {
            case .increment:
                next = min(1, current + accessibilityStep)
            case .decrement:
                next = max(0, current - accessibilityStep)
            @unknown default:
                return
            }
            onEditingChanged(true)
            onValueChanged(next)
            onEditingChanged(false)
        }
    }
}
