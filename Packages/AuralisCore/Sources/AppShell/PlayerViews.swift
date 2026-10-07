// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AVKit
import AgentKit
import DesignSystem
import Domain
import LocalCatalog
import MusicHaptics
import SwiftUI
import ThemeEngine
#if os(iOS)
import UIKit
#endif

/// 迷你播放条内部内容（不含背景与外壳）。iOS 双层 Dock 共用同一套布局，
/// 外层尺寸、玻璃材质与边距由调用方（BottomGlassBarShell）统一决定。
struct MiniPlayerContent: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject private var playbackStore: PlaybackStore
    /// canGoNext / canGoPrevious 由队列状态决定；只观察 AppModel/PlaybackStore
    /// 无法感知“当前歌曲不变但队列被追加/替换”的情况。
    @ObservedObject private var queueStore: PlaybackQueuePresentationStore
    let theme: BuiltInTheme
    var height: CGFloat = 56
    /// 展开态为 1；收拢为底部中间胶囊时连续收至 0。
    /// 这样同一根播放条仍保留曲目信息，只把前后切歌控制收起。
    var skipControlsVisibility: CGFloat = 1

    private var coverSize: CGFloat { min(42, max(36, height - 14)) }
    private var displayTitle: String {
        playbackStore.currentTrack.id.rawValue == "placeholder" ? String(localized: "音乐正在赶来喵", bundle: .module) : playbackStore.currentTrack.title
    }
    private var controlPresentation: PlaybackControlPresentation {
        PlaybackControlPresentation(state: playbackStore.state)
    }

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        height: CGFloat = 56,
        skipControlsVisibility: CGFloat = 1
    ) {
        self.model = model
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self._queueStore = ObservedObject(wrappedValue: model.queueStore)
        self.theme = theme
        self.height = height
        self.skipControlsVisibility = skipControlsVisibility
    }

    var body: some View {
        // 迷你播放条只保留封面、曲目信息与播放控制；进度仅在“正在播放”完整页提供。
        HStack(spacing: 0) {
            ArtworkView(
                title: playbackStore.currentTrack.albumTitle,
                artworkKey: playbackStore.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: coverSize,
                serverID: playbackStore.currentTrack.serverID,
                cornerRadius: 8
            )
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .lineLimit(1)
                Text(playbackStore.currentTrack.artistName)
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
                    PlaybackControlIndicator(
                        presentation: controlPresentation,
                        color: theme.colorTokens.primaryText.color,
                        fontSize: 17
                    )
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(controlPresentation.accessibilityLabel)

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
        switch playbackStore.state {
        case .playing: state = String(localized: "播放中", bundle: .module)
        case .paused: state = String(localized: "已暂停", bundle: .module)
        default: state = String(localized: "未播放", bundle: .module)
        }
        return String(localized: "\(playbackStore.currentTrack.title)，\(playbackStore.currentTrack.artistName)，\(state)", bundle: .module)
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
        .opacity(normalizedSkipControlsVisibility * (isEnabled ? 1 : 0.32))
        .scaleEffect(normalizedSkipControlsVisibility, anchor: systemImage == "backward.fill" ? .trailing : .leading)
        .disabled(!isEnabled || normalizedSkipControlsVisibility < 0.05)
        .allowsHitTesting(normalizedSkipControlsVisibility >= 0.05)
        .accessibilityHidden(normalizedSkipControlsVisibility < 0.05)
        .accessibilityLabel(accessibilityLabel)
    }

}

/// 紧凑 Dock 内的播放内容。与展开态保持相同的“两行曲目信息”层级：
/// 歌曲名 + 歌手始终存在，只收掉前后切歌按钮，避免终态切换时内容高度和重心跳变。
struct CompactMiniPlayerContent: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject private var playbackStore: PlaybackStore
    let theme: BuiltInTheme

    private var title: String {
        playbackStore.currentTrack.id.rawValue == "placeholder" ? String(localized: "音乐正在赶来喵", bundle: .module) : playbackStore.currentTrack.title
    }
    private var controlPresentation: PlaybackControlPresentation {
        PlaybackControlPresentation(state: playbackStore.state)
    }

    init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(
                title: playbackStore.currentTrack.albumTitle,
                artworkKey: playbackStore.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: 36,
                serverID: playbackStore.currentTrack.serverID,
                cornerRadius: 8
            )

            // 必须与展开态 MiniPlayerContent 保持相同的两行信息层级。
            // 之前紧凑终态只保留歌名，Morphing 完成切树时歌手行突然消失，
            // 导致文字块高度/视觉重心变化，看起来像 Dock 又缩了一次。
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .lineLimit(1)
                Text(playbackStore.currentTrack.artistName)
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityPlaybackLabel)

            Spacer(minLength: 4)

            Button(action: model.togglePlayback) {
                PlaybackControlIndicator(
                    presentation: controlPresentation,
                    color: theme.colorTokens.primaryText.color,
                    fontSize: 17
                )
                    .frame(width: 42, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controlPresentation.accessibilityLabel)

        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }

    private var accessibilityPlaybackLabel: String {
        let state: String
        switch playbackStore.state {
        case .playing: state = String(localized: "播放中", bundle: .module)
        case .paused: state = String(localized: "已暂停", bundle: .module)
        default: state = String(localized: "未播放", bundle: .module)
        }
        return String(
            localized: "\(playbackStore.currentTrack.title)，\(playbackStore.currentTrack.artistName)，\(state)",
            bundle: .module
        )
    }
}


/// iOS 正在播放页的响应式布局规则。只根据当前容器几何决定横/竖布局，
/// 不读取 UIDevice.orientation，因此旋转、iPad 分屏和台前调度都能随实际窗口实时重排。
struct NowPlayingLayoutPolicy: Sendable {
    static let minimumLandscapeWidth: CGFloat = 600

    static func usesLandscapeLayout(containerSize: CGSize) -> Bool {
        guard containerSize.width > 0, containerSize.height > 0 else { return false }
        return containerSize.width > containerSize.height
            && containerSize.width >= minimumLandscapeWidth
    }

    static func landscapeArtworkSide(containerSize: CGSize, isPad: Bool) -> CGFloat {
        let maximum: CGFloat = isPad ? 600 : 420
        let contentWidth = max(
            0,
            containerSize.width - 2 * landscapeHorizontalPadding(isPad: isPad)
                - landscapeColumnSpacing(isPad: isPad)
        )
        let widthShare = contentWidth * (isPad ? 0.50 : 0.48)
        // 顶部拖拽柄与页面内边距之外，封面上下至少各留 16pt。
        // 不强制 220pt 下限，避免短窗口 / 台前调度中封面顶到边框。
        let heightShare = max(0, containerSize.height - (isPad ? 64 : 48))
        return min(maximum, min(widthShare, heightShare))
    }

    static func landscapeHorizontalPadding(isPad: Bool) -> CGFloat {
        isPad ? 32 : 20
    }

    static func landscapeColumnSpacing(isPad: Bool) -> CGFloat {
        isPad ? 36 : 24
    }
}

/// 自动跟随只在用户放开滚动、惯性结束并短暂停留后恢复。
/// 程序触发的滚动动画不应被误判成手动浏览。
struct LyricsScrollFollowState {
    static let resumeDelay: Duration = .seconds(5)
    private(set) var isUserScrolling = false
    private(set) var isFollowingPlayback = true

    mutating func update(phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            isUserScrolling = true
            isFollowingPlayback = false
        case .idle, .animating:
            isUserScrolling = false
        @unknown default:
            break
        }
    }

    @discardableResult
    mutating func resumeFollowing() -> Bool {
        guard !isUserScrolling else { return false }
        isFollowingPlayback = true
        return true
    }
}


/// 歌词页 Chrome 使用和底部 Dock 相同的“终态吸附”思路：
/// 手势只决定显示/隐藏，不把每一像素位移映射到布局，避免歌词 ScrollView 卡顿。
struct LyricsChromePolicy: Sendable {
    static let autoHideDelay: Duration = .seconds(5)
    static let minimumVerticalSwipeDistance: CGFloat = 44

    /// 向上滑隐藏，向下滑显示；横向翻页和短划不改变 Chrome。
    static func terminalHidden(for translation: CGSize) -> Bool? {
        guard abs(translation.height) > abs(translation.width),
              abs(translation.height) >= minimumVerticalSwipeDistance
        else { return nil }
        return translation.height < 0
    }
}

enum LyricsChromeMotion {
    static let duration: TimeInterval = 0.42

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.16)
            : .smooth(duration: duration)
    }
}

/// 当前歌词的轻量逐字强调。歌词源目前只有“逐行”时间戳，因此不能伪装成
/// 真正的逐字 timing；这里仅在当前行与下一行之间做均匀插值。
struct LyricCharacterAnimationPolicy: Sendable {
    /// 当前句整体先轻微放大，唱过的字符累积保持 1.1×。
    static let currentLineBaseScale: CGFloat = 1.02
    static let maximumScale: CGFloat = 1.1
    static let fallbackLineScale: CGFloat = 1.06

    static func lineProgress(
        position: TimeInterval,
        lineStart: TimeInterval?,
        nextLineStart: TimeInterval?
    ) -> Double? {
        guard let lineStart,
              let nextLineStart,
              nextLineStart > lineStart
        else { return nil }
        return min(max((position - lineStart) / (nextLineStart - lineStart), 0), 1)
    }

    static func scale(
        unitIndex: Int,
        unitCount: Int,
        progress: Double?
    ) -> CGFloat {
        guard unitCount > 0 else { return 1 }
        guard let progress else { return fallbackLineScale }

        let lastIndex = max(unitCount - 1, 0)
        let cursor = progress * Double(lastIndex)
        // 后续字符连续放大；游标越过后保持最大比例，不再回落。
        let influence = min(max(1 + cursor - Double(unitIndex), 0), 1)
        return currentLineBaseScale
            + (maximumScale - currentLineBaseScale) * CGFloat(influence)
    }
}

/// 在原生 Text 已完成的排版上绘制逐字缩放，不创建逐字符子视图或重新测量换行。
/// 非当前行和当前行使用同一个 Text 布局，切换高亮时不会改变滚动内容高度。
private struct LyricCharacterRenderer: TextRenderer {
    let isActive: Bool
    let progress: Double?

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard isActive else {
            // 大多数可见歌词无需逐字绘制，保留原生整段文字的快速绘制路径。
            for line in layout {
                for run in line {
                    context.draw(run)
                }
            }
            return
        }
        let unitCount = layout.reduce(0) { count, line in
            count + line.reduce(0) { $0 + $1.count }
        }
        var unitIndex = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let scale = LyricCharacterAnimationPolicy.scale(
                        unitIndex: unitIndex,
                        unitCount: unitCount,
                        progress: progress
                    )
                    let bounds = slice.typographicBounds.rect
                    var glyphContext = context
                    glyphContext.translateBy(x: bounds.midX, y: bounds.midY)
                    glyphContext.scaleBy(x: scale, y: scale)
                    glyphContext.translateBy(x: -bounds.midX, y: -bounds.midY)
                    glyphContext.draw(slice, options: .disablesSubpixelQuantization)
                    unitIndex += 1
                }
            }
        }
    }
}


/// Apple Music 风格的播放态封面几何：播放时铺开，暂停/空闲时缩小。
/// 只做 render transform，不改变父级测量尺寸，因此标题和控制区不会随暂停跳位。
struct NowPlayingArtworkMotionPolicy: Sendable {
    static let pausedScale: CGFloat = 0.82
    static let activeScale: CGFloat = 1

    static func scale(for state: PlaybackState) -> CGFloat {
        switch PlaybackControlPresentation(state: state) {
        case .pause, .loading:
            activeScale
        case .play:
            pausedScale
        }
    }
}

/// 底部歌词 / 队列按钮采用 toggle 语义：当前已经打开时再点一次回到封面页。
struct NowPlayingPageTogglePolicy: Sendable {
    static func toggled(current: NowPlayingPage, target: NowPlayingPage) -> NowPlayingPage {
        current == target ? .player : target
    }
}

struct NowPlayingView: View {
    static let musicHapticsMenuIdentifier = "auralis.nowPlaying.musicHaptics"
    static let moreActionsButtonIdentifier = "auralis.nowPlaying.moreActions"
    @ObservedObject var model: AuralisAppModel
    @ObservedObject private var playbackStore: PlaybackStore
    @ObservedObject private var queueStore: PlaybackQueuePresentationStore
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var page = NowPlayingPage.player
    @State private var isPlaylistSheetPresented = false
    @State private var showsTrackInformation = false
    @State private var lyricScrollTarget: Int?
    @State private var lyricScrollFollow = LyricsScrollFollowState()
    @State private var lyricFollowResumeTask: Task<Void, Never>?
    @State private var pendingLyricsChromeHidden: Bool?
    @State private var lyricTimeline: [LyricsIndexResolver.TimedLine] = []
    /// PlaybackStore 为避免全局重绘只每 0.5s 发布一次 position。
    /// 歌词逐字动画在本地用时间锚点插值到约 30fps，不提高全局播放进度发布频率。
    @State private var lyricPositionAnchorDate = Date()
    @State private var lyricPositionAnchorValue: TimeInterval = 0
    /// 歌词页 5 秒无操作后进入沉浸态：保留歌曲名 + 歌手，其余 Chrome 向下收缩消失。
    @State private var lyricsChromeHidden = false
    @State private var lyricsChromeAutoHideTask: Task<Void, Never>?
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

    private var mainControlPresentation: PlaybackControlPresentation {
        PlaybackControlPresentation(state: playbackStore.state)
    }

    private var artworkPresentationScale: CGFloat {
        NowPlayingArtworkMotionPolicy.scale(for: playbackStore.state)
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

    private var isPad: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    private var nowPlayingContentMaxWidth: CGFloat {
        if isPad { return 900 }
        return horizontalSizeClass == .regular ? IOSLayoutMetrics.playerContentMaxWidth : .infinity
    }

    private func artworkSizeCap(for availableWidth: CGFloat) -> CGFloat {
        guard isPad else { return 350 }
        // iPad 不按具体型号分支，而按播放内容实际拿到的宽度连续缩放。
        // mini、分屏等窄窗口会自然靠近 350pt；大尺寸 iPad 最多放大到 460pt。
        return min(460, max(350, availableWidth * 0.58))
    }

    var body: some View {
        GeometryReader { outer in
            ZStack {
                LinearGradient(
                    colors: [theme.colorTokens.accent.color.opacity(0.42), theme.colorTokens.background.color, theme.colorTokens.accentSecondary.color.opacity(0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

#if os(iOS)
                if NowPlayingLayoutPolicy.usesLandscapeLayout(containerSize: outer.size) {
                    landscapeBody(in: outer.size)
                } else {
                    portraitBody
                }
#else
                portraitBody
#endif
            }
        }
        .foregroundStyle(theme.colorTokens.primaryText.color)
        .sheet(isPresented: $isPlaylistSheetPresented) {
            AddToPlaylistSheet(model: model, theme: theme, track: model.currentTrack)
        }
        .sheet(isPresented: $showsTrackInformation) {
            TrackInformationSheet(model: model, theme: theme, track: model.currentTrack)
        }
        // 切歌时旧歌曲的 pendingSeek 不能污染下一首歌（拖动中切歌保护）。
        .onChange(of: currentTrackIdentity) { _, _ in
            pendingSeek = nil
            resetLyricsScrollInteraction()
            if page == .lyrics {
                showLyricsChromeAndScheduleAutoHide()
            }
        }
        .onChange(of: page) { oldPage, newPage in
            if newPage == .lyrics {
                resetLyricsScrollInteraction()
                scrollToCurrentLyric(animated: false)
                syncLyricPositionAnchor()
                showLyricsChromeAndScheduleAutoHide()
            } else if oldPage == .lyrics {
                resetLyricsScrollInteraction()
                lyricsChromeAutoHideTask?.cancel()
                lyricsChromeAutoHideTask = nil
                lyricsChromeHidden = false
            }
        }
        .onChange(of: playbackStore.position) { _, newPosition in
            lyricPositionAnchorValue = newPosition
            lyricPositionAnchorDate = Date()
        }
        .onChange(of: playbackStore.state) { _, _ in
            syncLyricPositionAnchor()
        }
        .onAppear {
            syncLyricPositionAnchor()
        }
        .onDisappear {
            resetLyricsScrollInteraction()
            lyricsChromeAutoHideTask?.cancel()
            lyricsChromeAutoHideTask = nil
        }
    }

    private var portraitBody: some View {
        VStack(spacing: AuralisSpacing.medium) {
#if os(iOS)
            // 歌词沉浸态隐藏顶部 Chrome；向下滑后恢复。
            if !lyricsImmersiveMode {
                dismissHandle
                    .transition(lyricsChromeTransition)
            }
#else
            header
#endif
            GeometryReader { geo in
                playbackContent(in: geo)
            }
        }
        .padding(.horizontal, AuralisSpacing.large)
        .padding(.bottom, AuralisSpacing.large)
        .padding(.top, portraitTopPadding)
        // 900pt 只是大尺寸 iPad 的内容上限；较小 iPad、分屏和台前调度窗口
        // 会由 SwiftUI 根据实际可用宽度自然收缩，不依赖具体设备型号。
        .frame(maxWidth: nowPlayingContentMaxWidth)
    }

    private var portraitTopPadding: CGFloat {
#if os(iOS)
        2
#else
        AuralisSpacing.large
#endif
    }

    private var lyricsImmersiveMode: Bool {
        page == .lyrics && lyricsChromeHidden
    }

    private var lyricsChromeTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }

#if os(iOS)
    /// 横屏采用与 Apple Music 同类的左右双栏：封面固定在左，右侧承载播放信息、
    /// 歌词或队列。旋转时只重排视图，不重建播放状态、队列或当前页面选择。
    private func landscapeBody(in size: CGSize) -> some View {
        let artworkSide = NowPlayingLayoutPolicy.landscapeArtworkSide(
            containerSize: size,
            isPad: isPad
        )
        let horizontalPadding = NowPlayingLayoutPolicy.landscapeHorizontalPadding(isPad: isPad)
        let columnSpacing = NowPlayingLayoutPolicy.landscapeColumnSpacing(isPad: isPad)
        let compactLandscape = size.height < 460
        let controlsSpacing: CGFloat = compactLandscape ? 10 : 15
        let playButtonSize: CGFloat = compactLandscape ? 48 : 56

        return VStack(spacing: compactLandscape ? 2 : AuralisSpacing.xSmall) {
            if !lyricsImmersiveMode {
                dismissHandle
                    .transition(lyricsChromeTransition)
            }

            // 横屏骨架永远保持“左封面 + 右内容”，沉浸模式只隐藏 Chrome，
            // 不再删除封面或把歌词突然扩成全屏。
            HStack(spacing: columnSpacing) {
                landscapeArtwork(side: artworkSide)
                    .frame(width: artworkSide)
                    .frame(maxHeight: .infinity)

                VStack(spacing: compactLandscape ? 8 : AuralisSpacing.medium) {
                    landscapePageContent(
                        sectionSpacing: controlsSpacing,
                        playButtonSize: playButtonSize
                    )
                }
                .frame(maxWidth: 600, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(LyricsChromeMotion.animation(reduceMotion: reduceMotion), value: lyricsChromeHidden)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 2)
        .padding(.bottom, compactLandscape ? 6 : AuralisSpacing.small)
    }

    private func landscapeArtwork(side: CGFloat) -> some View {
        ZStack {
            NowPlayingArtworkGlowView(
                isPlaying: model.playbackState == .playing,
                artworkKey: model.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: side,
                serverID: model.currentTrack.serverID,
                maxCanvasSize: side * 1.16
            )
            ArtworkView(
                title: model.currentTrack.albumTitle,
                artworkKey: model.currentTrack.artworkKey,
                colors: theme.colorTokens,
                size: side,
                serverID: model.currentTrack.serverID
            )
            .shadow(color: Color.black.opacity(0.24), radius: 14, x: 0, y: 3)
        }
        .frame(width: side, height: side)
        .scaleEffect(artworkPresentationScale)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0),
            value: artworkPresentationScale
        )
        .accessibilityRepresentation {
            // 装饰光效和占位图中的外溢图形不能扩大封面本体的 VoiceOver 边界。
            Rectangle()
                .frame(width: side, height: side)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "专辑封面，\(model.currentTrack.albumTitle)", bundle: .module))
                .accessibilityIdentifier("auralis.nowPlaying.landscapeArtwork")
        }
    }

    @ViewBuilder
    private func landscapePageContent(
        sectionSpacing: CGFloat,
        playButtonSize: CGFloat
    ) -> some View {
        switch page {
        case .player:
            playbackControls(
                sectionSpacing: sectionSpacing,
                playButtonSize: playButtonSize
            )
            .frame(maxWidth: 560)
            .frame(maxHeight: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)

        case .lyrics:
            VStack(spacing: AuralisSpacing.small) {
                lyrics
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(lyricsChromeSwipeGesture)
                    .simultaneousGesture(lyricsActivityTapGesture)

                if lyricsImmersiveMode {
                    lyricsTrackIdentityHeader(showActions: false)
                        .frame(maxWidth: 560)
                } else {
                    nowPlayingBottomNavigation
                        .frame(maxWidth: 420)
                }
            }

        case .queue:
            VStack(spacing: AuralisSpacing.small) {
                queue
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                nowPlayingBottomNavigation
                    .frame(maxWidth: 420)
            }
        }
    }
#endif

#if os(iOS)
    /// Full-screen cover 不提供 sheet 自带的拖拽柄；在安全区内保留一个轻量入口，
    /// 向下拖动或轻点即可关闭，避免为了铺满状态栏而丢失原来的退出路径。
    private var dismissHandle: some View {
        Capsule(style: .continuous)
            .fill(theme.colorTokens.primaryText.color.opacity(0.34))
            .frame(width: 48, height: 5)
            // 只保留足够的手势命中高度，不再用 24pt 可见布局把横条向下推。
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(Rectangle())
            .onTapGesture {
                dismissNowPlaying()
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        guard value.translation.height > 60,
                              abs(value.translation.height) > abs(value.translation.width)
                        else { return }
                        dismissNowPlaying()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "关闭播放页", bundle: .module))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                dismissNowPlaying()
            }
    }

    private func dismissNowPlaying() {
        model.isNowPlayingPresented = false
        dismiss()
    }
#endif

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

    /// 三点菜单保持系统 Menu 的原生 Button 语义：不能从传输控制父层继承自定义 ButtonStyle。
    /// 会继续呈现 sheet 的动作等待系统 Menu 完成收起，避免 UIKit 同时 presentation 竞争。
    private var moreMenu: some View {
        Menu {
            Button(String(localized: "添加到歌单", bundle: .module)) {
                performAfterSystemMenuDismissal { isPlaylistSheetPresented = true }
            }
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
            Button(String(localized: "歌曲信息", bundle: .module)) {
                performAfterSystemMenuDismissal { showsTrackInformation = true }
            }
#if os(iOS)
            if MusicHapticsPlatformPolicy.isFeatureAvailable {
                Toggle(isOn: Binding(
                    get: { model.currentMusicHapticsEnabled },
                    set: { model.setCurrentTrackMusicHapticsEnabled($0) }
                )) {
                    Text(String(localized: "音乐震动", bundle: .module))
                }
                .accessibilityIdentifier(Self.musicHapticsMenuIdentifier)
            }
#endif
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        // `buttonStyle` is an environment value for descendant buttons.  The
        // former HapticBordered style therefore also reached the Menu actions
        // themselves.  Keep this system-composed control on native semantics.
        .buttonStyle(.automatic)
        .accessibilityLabel(String(localized: "更多操作", bundle: .module))
        .accessibilityIdentifier(Self.moreActionsButtonIdentifier)
    }

    /// 普通播放/队列保持完整底部控制；歌词页额外支持沉浸 Chrome：
    /// 5 秒无操作或向上滑后只保留歌曲名，其余控制向下收缩退出。
    private func playbackContent(in geo: GeometryProxy) -> some View {
        // iPhone 保持既有按高度收紧的规则；iPad 额外根据当前窗口宽度判断。
        // 因此 iPad mini、Split View、台前调度窄窗口都会自动进入更紧凑的控制区。
        let compactHeight = geo.size.height < 650
        let compactPadWidth = isPad && geo.size.width < 620
        let compactLayout = compactHeight || compactPadWidth
        // 去掉顶部重复标题后，把节省出的高度还给播放控制区。
        // 歌曲信息、进度、传输键、音量和底部状态之间保持更舒展的 Apple Music 式节奏。
        let sectionSpacing: CGFloat = compactLayout ? 14 : 20
        let playButtonSize: CGFloat = compactLayout ? 56 : 64
        let estimatedControlHeight: CGFloat = compactLayout ? 292 : 330
        let heroHeight = max(geo.size.height - estimatedControlHeight, 190)
        let maxArtworkSide = artworkSizeCap(for: geo.size.width)
        let artworkSide = min(maxArtworkSide, geo.size.width * 0.84, heroHeight * 0.88)
        // Glow 画布以封面为中心向外扩散；允许的最大值不超过页面可用高度，
        // 避免光效被 TabView 页面边缘裁成方框，同时封面本体尺寸不受影响。
        let glowCanvasSize = max(0, heroHeight - AuralisSpacing.medium * 2)

        return VStack(spacing: sectionSpacing) {
            TabView(selection: $page) {
                lyrics
                    .contentShape(Rectangle())
                    .simultaneousGesture(lyricsChromeSwipeGesture)
                    .simultaneousGesture(lyricsActivityTapGesture)
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

            Group {
                if page == .lyrics {
                    lyricsPlaybackChrome(
                        sectionSpacing: sectionSpacing,
                        playButtonSize: playButtonSize
                    )
                } else {
                    playbackControls(
                        sectionSpacing: sectionSpacing,
                        playButtonSize: playButtonSize
                    )
                }
            }
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
                .shadow(
                    color: Color.black.opacity(playbackStore.state == .playing ? 0.24 : 0.16),
                    radius: playbackStore.state == .playing ? 14 : 9,
                    x: 0,
                    y: 2
                )
            }
            // Apple Music：播放时封面舒展，暂停时明显缩小；scaleEffect 不改布局尺寸，
            // 因此下面歌曲信息不会跟着上下跳动。
            .scaleEffect(artworkPresentationScale)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0),
                value: artworkPresentationScale
            )
            Spacer(minLength: AuralisSpacing.xSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 与 main 分支播放控制区完全相同的歌曲信息位置。
    /// 沉浸态只隐藏左右按钮，歌曲名和歌手仍占据同一几何位置，不做二次搬家。
    private func lyricsTrackIdentityHeader(showActions: Bool) -> some View {
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
            .accessibilityIdentifier("auralis.nowPlaying.trackIdentity")

            HStack(spacing: 0) {
                dislikeButton
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
                    .accessibilityHidden(!showActions)
                Spacer(minLength: 0)
                favoriteButton
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
                    .accessibilityHidden(!showActions)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 歌词页完整态复用主分支歌曲信息位置；沉浸态保留歌曲名 + 歌手，
    /// 其余进度、控制、音量与状态向下收缩消失。
    private func lyricsPlaybackChrome(
        sectionSpacing: CGFloat,
        playButtonSize: CGFloat
    ) -> some View {
        VStack(spacing: sectionSpacing) {
            lyricsTrackIdentityHeader(showActions: !lyricsChromeHidden)

            if !lyricsChromeHidden {
                VStack(spacing: sectionSpacing) {
                    VStack(spacing: AuralisSpacing.xSmall) {
                        ThinSlider(
                            value: model.playbackProgress,
                            accent: theme.colorTokens.accent.color,
                            track: theme.colorTokens.separator.color.opacity(0.4),
                            thumb: Color.white,
                            onEditingChanged: { editing in
                                registerLyricsInteraction()
                                if !editing, let pending = pendingSeek {
                                    model.playbackProgress = pending
                                    pendingSeek = nil
                                }
                            },
                            onValueChanged: {
                                registerLyricsInteraction()
                                pendingSeek = $0
                            },
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
                    nowPlayingBottomNavigation
                }
                .transition(lyricsChromeTransition)
            }
        }
        .animation(LyricsChromeMotion.animation(reduceMotion: reduceMotion), value: lyricsChromeHidden)
        .simultaneousGesture(lyricsActivityTapGesture)
    }

    private var lyricsChromeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { _ in
                cancelLyricsChromeAutoHide()
            }
            .onEnded { value in
                guard page == .lyrics else { return }
                guard let shouldHide = LyricsChromePolicy.terminalHidden(for: value.translation) else {
                    scheduleLyricsChromeAutoHide()
                    return
                }
                // 等原生惯性滚动结束再改变可用高度，避免松手瞬间重排歌词。
                pendingLyricsChromeHidden = shouldHide
                if !lyricScrollFollow.isUserScrolling {
                    applyPendingLyricsChromeChange()
                }
            }
    }

    private func applyPendingLyricsChromeChange() {
        guard let shouldHide = pendingLyricsChromeHidden,
              !lyricScrollFollow.isUserScrolling else { return }
        pendingLyricsChromeHidden = nil
        if shouldHide {
            hideLyricsChrome()
        } else {
            showLyricsChromeAndScheduleAutoHide()
        }
    }

    private func cancelLyricsChromeAutoHide() {
        guard let task = lyricsChromeAutoHideTask else { return }
        task.cancel()
        lyricsChromeAutoHideTask = nil
    }

    private var lyricsActivityTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                registerLyricsInteraction()
            }
    }

    private func registerLyricsInteraction() {
        guard page == .lyrics else { return }
        if lyricsChromeHidden {
            // 沉浸态不因普通点击意外弹出；按要求只由“向下滑”恢复。
            return
        }
        scheduleLyricsChromeAutoHide()
    }

    private func hideLyricsChrome() {
        cancelLyricsChromeAutoHide()
        guard !lyricScrollFollow.isUserScrolling else {
            pendingLyricsChromeHidden = true
            return
        }
        guard !lyricsChromeHidden else { return }
        withAnimation(LyricsChromeMotion.animation(reduceMotion: reduceMotion)) {
            lyricsChromeHidden = true
        }
    }

    private func showLyricsChromeAndScheduleAutoHide() {
        lyricsChromeAutoHideTask?.cancel()
        lyricsChromeAutoHideTask = nil
        if lyricsChromeHidden {
            withAnimation(LyricsChromeMotion.animation(reduceMotion: reduceMotion)) {
                lyricsChromeHidden = false
            }
        }
        scheduleLyricsChromeAutoHide()
    }

    private func scheduleLyricsChromeAutoHide() {
        cancelLyricsChromeAutoHide()
        guard page == .lyrics, !lyricsChromeHidden, !lyricScrollFollow.isUserScrolling else { return }

        lyricsChromeAutoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: LyricsChromePolicy.autoHideDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, page == .lyrics, !lyricsChromeHidden else { return }
            hideLyricsChrome()
        }
    }

    private func playbackControls(sectionSpacing: CGFloat, playButtonSize: CGFloat) -> some View {
        VStack(spacing: sectionSpacing) {
            // 与歌词页共用同一歌曲信息布局，避免模式切换后标题位置漂移。
            lyricsTrackIdentityHeader(showActions: true)

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
            nowPlayingBottomNavigation
        }
    }

    private var favoriteButton: some View {
        Button {
            model.toggleFavorite(model.currentTrack)
        } label: {
            Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(model.currentTrack.isFavorite ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(HapticPlainButtonStyle())
        // 收藏落库/服务器同步通过异步 Task 更新状态，不能只依赖点击时的 withAnimation。
        .animation(AuralisMotion.micro(reduceMotion: reduceMotion), value: model.currentTrack.isFavorite)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(model.currentTrack.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
        .accessibilityIdentifier("auralis.nowPlaying.favorite")
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
        .animation(AuralisMotion.micro(reduceMotion: reduceMotion), value: isDisliked)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(isDisliked ? String(localized: "取消不喜欢", bundle: .module) : String(localized: "不喜欢", bundle: .module))
        .accessibilityHint(String(localized: "不喜欢的歌曲不会再出现在自动推荐中。", bundle: .module))
        .accessibilityValue(isDisliked ? String(localized: "已标记不喜欢", bundle: .module) : String(localized: "未标记不喜欢", bundle: .module))
        .accessibilityIdentifier("auralis.nowPlaying.dislike")
    }

    private func transportControls(playButtonSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 播放模式：单个按钮循环切换顺序、随机、列表循环和单曲循环。
            transportItem {
                Button {
                    withAnimation(AuralisMotion.micro(reduceMotion: reduceMotion)) {
                        model.cyclePlayMode()
                    }
                } label: {
                    Image(systemName: model.playMode.symbol)
                        .font(.title3)
                        .foregroundStyle(model.playMode == .list ? theme.colorTokens.secondaryText.color : theme.colorTokens.accent.color)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel(String(localized: "播放模式：\(model.playMode.title)", bundle: .module))
                .accessibilityIdentifier("auralis.nowPlaying.playMode")
            }
            transportItem {
                Button(action: model.previous) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HapticPlainButtonStyle())
                .disabled(!model.canGoPrevious)
                .opacity(model.canGoPrevious ? 1 : 0.32)
                .accessibilityLabel(String(localized: "上一首", bundle: .module))
                .accessibilityIdentifier("auralis.nowPlaying.previous")
            }
            transportItem {
                Button(action: model.togglePlayback) {
                    PlaybackControlIndicator(
                        presentation: mainControlPresentation,
                        color: theme.colorTokens.background.color,
                        fontSize: playButtonSize * 0.4
                    )
                    .frame(width: playButtonSize, height: playButtonSize)
                    .background(theme.colorTokens.accent.color)
                    .clipShape(Circle())
                    .scaleEffect(mainControlPresentation == .pause ? 1 : 0.97)
                }
                .buttonStyle(HapticPlainButtonStyle())
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0),
                    value: mainControlPresentation
                )
                .accessibilityLabel(mainControlPresentation.accessibilityLabel)
                .accessibilityIdentifier("auralis.nowPlaying.playPause")
            }
            transportItem {
                Button(action: model.next) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HapticPlainButtonStyle())
                .disabled(!model.canGoNext)
                // 自定义 HapticPlainButtonStyle 不会自动绘制 disabled 外观。
                // 必须明确变淡，否则“没有下一首”时看起来仍像一个可用按钮。
                .opacity(model.canGoNext ? 1 : 0.32)
                .accessibilityLabel(String(localized: "下一首", bundle: .module))
                .accessibilityIdentifier("auralis.nowPlaying.next")
            }
            transportItem {
                moreMenu
            }
        }
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

    /// Apple Music 式底部三入口：歌词 / AirPlay / 队列。
    /// 歌词与队列都是 toggle：再次点击当前入口回到封面页。
    private var nowPlayingBottomNavigation: some View {
        HStack(spacing: 0) {
            bottomNavigationButton(
                systemImage: page == .lyrics ? "quote.bubble.fill" : "quote.bubble",
                title: String(localized: "歌词", bundle: .module),
                identifier: "auralis.nowPlaying.lyrics",
                isSelected: page == .lyrics
            ) {
                setPageFromBottomNavigation(.lyrics)
            }

            Spacer(minLength: 0)

            RoutePickerView()
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(String(localized: "隔空播放", bundle: .module))
                .accessibilityIdentifier("auralis.nowPlaying.airPlay")

            Spacer(minLength: 0)

            bottomNavigationButton(
                systemImage: "list.bullet",
                title: String(localized: "队列", bundle: .module),
                identifier: "auralis.nowPlaying.queue",
                isSelected: page == .queue
            ) {
                setPageFromBottomNavigation(.queue)
            }
        }
        .frame(maxWidth: 420)
    }

    private func bottomNavigationButton(
        systemImage: String,
        title: String,
        identifier: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(
                    isSelected
                        ? theme.colorTokens.accent.color
                        : theme.colorTokens.secondaryText.color
                )
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
                .scaleEffect(isSelected ? 1.06 : 1)
        }
        .buttonStyle(HapticPlainButtonStyle())
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0),
            value: isSelected
        )
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(
            isSelected
                ? String(localized: "已打开", bundle: .module)
                : String(localized: "未打开", bundle: .module)
        )
    }

    private func setPageFromBottomNavigation(_ target: NowPlayingPage) {
        let next = NowPlayingPageTogglePolicy.toggled(current: page, target: target)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.34, extraBounce: 0)) {
            page = next
        }
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

    private func performAfterSystemMenuDismissal(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            // SwiftUI Menu 在 iOS 上由临时 presentation controller 承载。
            // 菜单 action 同一 turn 立即再呈现 sheet 会和它的 dismiss 竞争，
            // 表现为第一次点击被吃掉、需要重新打开菜单重复点击。
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            action()
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
            // 与“前往专辑/艺术家”一致，先完成 Now Playing/Menu 的退出，
            // 再切换 Assistant，避免 presentation tree 在同一帧竞争。
            try? await Task.sleep(for: .milliseconds(180))
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
        guard document.id == lyricTimelineID else { return nil }
        return LyricsIndexResolver.index(at: playbackStore.position, in: lyricTimeline)
    }

    private var lyricTimelineID: TrackID? {
        model.currentLyrics?.id
    }

    private func syncLyricPositionAnchor() {
        lyricPositionAnchorValue = playbackStore.position
        lyricPositionAnchorDate = Date()
    }

    private func resetLyricsScrollInteraction() {
        lyricFollowResumeTask?.cancel()
        lyricFollowResumeTask = nil
        lyricScrollFollow = LyricsScrollFollowState()
        pendingLyricsChromeHidden = nil
    }

    private func handleLyricsScrollPhase(_ phase: ScrollPhase) {
        let wasUserScrolling = lyricScrollFollow.isUserScrolling
        lyricScrollFollow.update(phase: phase)
        if lyricScrollFollow.isUserScrolling {
            lyricFollowResumeTask?.cancel()
            lyricFollowResumeTask = nil
            cancelLyricsChromeAutoHide()
        } else if phase == .idle, wasUserScrolling || !lyricScrollFollow.isFollowingPlayback {
            applyPendingLyricsChromeChange()
            scheduleLyricsChromeAutoHide()
            scheduleLyricFollowResume()
        }
    }

    private func scheduleLyricFollowResume() {
        lyricFollowResumeTask?.cancel()
        lyricFollowResumeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: LyricsScrollFollowState.resumeDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, page == .lyrics,
                  lyricScrollFollow.resumeFollowing() else { return }
            lyricFollowResumeTask = nil
            // 恢复时读最新高亮行，不能跳回拖动前缓存的歌词。
            scrollToCurrentLyric(animated: true)
        }
    }

    private func scrollToCurrentLyric(animated: Bool) {
        guard lyricScrollFollow.isFollowingPlayback,
              !lyricScrollFollow.isUserScrolling,
              let index = currentLyricIndex, lyricScrollTarget != index else { return }
        if reduceMotion || !animated {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                lyricScrollTarget = index
            }
        } else {
            withAnimation(.smooth(duration: 0.44, extraBounce: 0)) {
                lyricScrollTarget = index
            }
        }
    }

    /// PlaybackStore 只每 0.5 秒发布一次进度。逐字动画不能直接吃这个离散值，
    /// 否则会每半秒跳一两个字，看起来像“没有动画”。这里仅在歌词视图内部做时间插值。
    private func interpolatedLyricPosition(at date: Date) -> TimeInterval {
        guard playbackStore.state == .playing else {
            return playbackStore.position
        }
        let elapsed = min(max(date.timeIntervalSince(lyricPositionAnchorDate), 0), 0.75)
        return lyricPositionAnchorValue + elapsed * Double(model.playbackRate)
    }

    private func lyricLineView(
        document: LyricsDocument,
        index: Int,
        activeIndex: Int?
    ) -> some View {
        let line = document.lines[index]
        let isCurrent = index == activeIndex
        let nextStart = document.lines.dropFirst(index + 1).first { $0.startTime != nil }?.startTime
        let hasCharacterTiming = document.isSynced && LyricCharacterAnimationPolicy.lineProgress(
            position: playbackStore.position,
            lineStart: line.startTime,
            nextLineStart: nextStart
        ) != nil
        let animateCharacters = isCurrent && hasCharacterTiming && !reduceMotion
            && !lyricScrollFollow.isUserScrolling && page == .lyrics
            && playbackStore.state == .playing

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animateCharacters)) { context in
            let progress = hasCharacterTiming
                ? LyricCharacterAnimationPolicy.lineProgress(
                    position: interpolatedLyricPosition(at: context.date),
                    lineStart: line.startTime,
                    nextLineStart: nextStart
                )
                : nil
            Text(line.text)
                // 字重与换行保持稳定；高亮只改变绘制颜色与缩放。
                .font(.title2.weight(.bold))
                .textRenderer(LyricCharacterRenderer(isActive: isCurrent && !reduceMotion, progress: progress))
                .opacity(isCurrent ? 1 : 0.62)
                .foregroundStyle(
                    isCurrent
                        ? theme.colorTokens.accent.color
                        : theme.colorTokens.secondaryText.color
                )
                .multilineTextAlignment(.center)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("auralis.nowPlaying.lyric.\(index)")
        }
    }

    private var lyrics: some View {
        let activeIndex = currentLyricIndex
        return ScrollView {
            LazyVStack(alignment: .center, spacing: AuralisSpacing.large) {
                if let document = model.currentLyrics {
                    ForEach(document.lines.indices, id: \.self) { index in
                        lyricLineView(
                            document: document,
                            index: index,
                            activeIndex: activeIndex
                        )
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
            .scrollTargetLayout()
            .frame(maxWidth: 600, alignment: .center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AuralisSpacing.huge)
        }
        .scrollPosition(id: $lyricScrollTarget, anchor: .center)
        .accessibilityIdentifier("auralis.nowPlaying.lyricsScroll")
        .onScrollPhaseChange { _, phase in
            handleLyricsScrollPhase(phase)
        }
        .onChange(of: activeIndex) { _, _ in
            scrollToCurrentLyric(animated: true)
        }
        .task(id: model.currentLyrics?.id) {
            resetLyricsScrollInteraction()
            guard let document = model.currentLyrics else {
                lyricTimeline = []
                lyricScrollTarget = nil
                return
            }
            lyricTimeline = LyricsIndexResolver.timeline(for: document.lines)
            lyricScrollTarget = LyricsIndexResolver.index(at: playbackStore.position, in: lyricTimeline)
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

enum NowPlayingPage: String, CaseIterable, Identifiable {
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
    @State private var hapticsInfo: MusicHapticsAssetInfo?
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

    private var musicHapticsRequestID: String {
        "\(track.serverID.rawValue)|\(track.id.rawValue)|\(model.currentMusicHapticsEnabled)"
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
#if os(iOS)
                if MusicHapticsPlatformPolicy.isFeatureAvailable {
                    Section(String(localized: "音乐震动", bundle: .module)) {
                        if let hapticsInfo {
                            infoRow(
                                String(localized: "来源", bundle: .module),
                                hapticsOriginTitle(hapticsInfo.origin)
                            )
                            if let isrc = hapticsInfo.isrc, !isrc.isEmpty {
                                infoRow(String(localized: "ISRC", bundle: .module), isrc)
                            }
                            if let algorithm = hapticsInfo.algorithmVersion {
                                infoRow(String(localized: "算法", bundle: .module), algorithm)
                            }
                            if let coverage = hapticsInfo.coverage {
                                infoRow(
                                    String(localized: "覆盖率", bundle: .module),
                                    "\(Int((coverage * 100).rounded()))%"
                                )
                            }
                            infoRow(
                                String(localized: "状态", bundle: .module),
                                hapticsStateTitle(hapticsInfo)
                            )
                        } else {
                            HStack(spacing: AuralisSpacing.small) {
                                ProgressView()
                                Text(String(localized: "正在读取音乐震动状态…", bundle: .module))
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                        }
                    }
                }
#endif
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
            .task(id: musicHapticsRequestID) {
#if os(iOS)
                guard MusicHapticsPlatformPolicy.isFeatureAvailable else {
                    hapticsInfo = nil
                    return
                }
                hapticsInfo = nil
                let requestedIdentity = musicHapticsRequestID
                let info = await model.musicHapticsAssetInfo(for: track)
                guard !Task.isCancelled,
                      requestedIdentity == musicHapticsRequestID else { return }
                hapticsInfo = info
#else
                hapticsInfo = nil
#endif
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

    private func hapticsOriginTitle(_ origin: MusicHapticsAssetOrigin) -> String {
        switch origin {
        case .systemISRC:
            return String(localized: "ISRC 系统匹配", bundle: .module)
        case .algorithmGenerated:
            return String(localized: "Auralis 算法生成", bundle: .module)
        case .none:
            return String(localized: "暂无", bundle: .module)
        }
    }

    private func hapticsStateTitle(_ info: MusicHapticsAssetInfo) -> String {
        switch info.state {
        case .available:
            return info.isCurrentlyUsed
                ? String(localized: "当前使用", bundle: .module)
                : String(localized: "可用", bundle: .module)
        case .generating:
            return String(localized: "生成中", bundle: .module)
        case .disabled:
            return String(localized: "已关闭", bundle: .module)
        case .unavailable:
            return String(localized: "不可用", bundle: .module)
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
