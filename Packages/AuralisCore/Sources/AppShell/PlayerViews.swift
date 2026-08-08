import AVKit
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

struct MiniPlayer: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var height: CGFloat = 50
    @Environment(\.auralisReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            capsuleBackground
            MiniPlayerContent(model: model, theme: theme, height: height)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { model.isNowPlayingPresented = true }
        .accessibilityElement(children: .contain)
    }

    private var capsuleBackground: some View {
        Group {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.colorTokens.elevated.color)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(theme.colorTokens.elevated.color.opacity(theme.materials.opacity))
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.colorTokens.separator.color.opacity(0.28), lineWidth: 0.5)
        )
        .shadow(
            color: Color.black.opacity(reduceTransparency ? 0.08 : 0.16),
            radius: 16,
            x: 0,
            y: 6
        )
    }

    private var cornerRadius: CGFloat { max(height / 2, 20) }
}

/// 迷你播放条内部内容（不含背景与外壳）。iOS 双层 Dock 与桌面版共用同一套布局，
/// 外层尺寸、玻璃材质与边距由调用方（BottomGlassBarShell / MiniPlayer）统一决定。
struct MiniPlayerContent: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var height: CGFloat = 56

    private var coverSize: CGFloat { min(42, max(36, height - 14)) }

    var body: some View {
        ZStack(alignment: .top) {
            // 主行：封面 + 信息 + 操作，整体在 56pt 内垂直居中
            HStack(spacing: 0) {
                // 封面，圆角 8
                ArtworkView(
                    title: model.currentTrack.albumTitle,
                    artworkKey: model.currentTrack.artworkKey,
                    colors: theme.colorTokens,
                    size: coverSize,
                    cornerRadius: 8
                )
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)

                // 歌曲信息，最多一行，尾部截断
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentTrack.title)
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

                // 上一首 / 播放(暂停) / 下一首，点击区域 ≥ 44×44，三者等权对称
                HStack(spacing: 4) {
                    Button(action: model.previous) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                    }
                    .disabled(!model.hasPrevious)
                    .accessibilityLabel("上一首")

                    Button(action: model.togglePlayback) {
                        Image(systemName: model.playbackState == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                    }
                    .accessibilityLabel(model.playbackState == .playing ? "暂停" : "播放")

                    Button(action: model.next) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                    }
                    .disabled(!model.hasNext)
                    .accessibilityLabel("下一首")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)

            // 顶部 2pt 进度条，作为覆盖层不挤压主行垂直居中
            progressLine
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }

    /// VoiceOver 播放状态描述：歌曲 + 艺术家 + 播放状态。
    private var accessibilityPlaybackLabel: String {
        let state: String
        switch model.playbackState {
        case .playing: state = "播放中"
        case .paused: state = "已暂停"
        default: state = "未播放"
        }
        return "\(model.currentTrack.title)，\(model.currentTrack.artistName)，\(state)"
    }

    /// 胶囊内部顶部的 2pt 进度条，不超出卡片。
    private var progressLine: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.colorTokens.separator.color.opacity(0.35))
                Capsule()
                    .fill(theme.colorTokens.accent.color)
                    .frame(width: max(0, proxy.size.width * model.playbackProgress))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

struct NowPlayingView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = NowPlayingPage.player
    @State private var isPlaylistSheetPresented = false
    /// 拖动进度条时暂存的 seek 目标：松手才真正 seek（Apple Music 行为）。
    @State private var pendingSeek: Double?
#if os(iOS)
    @State private var queueEditMode = EditMode.inactive
#endif

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
                Picker("播放页面", selection: $page) {
                    ForEach(NowPlayingPage.allCases) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                TabView(selection: $page) {
                    lyrics.tag(NowPlayingPage.lyrics)
                    player.tag(NowPlayingPage.player)
                    queue.tag(NowPlayingPage.queue)
                }
#if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
#else
                .tabViewStyle(.automatic)
#endif
                .frame(maxHeight: .infinity)
            }
            .padding(AuralisSpacing.large)
        }
        .foregroundStyle(theme.colorTokens.primaryText.color)
        .sheet(isPresented: $isPlaylistSheetPresented) {
            AddToPlaylistSheet(model: model, theme: theme, track: model.currentTrack)
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
            .accessibilityLabel("关闭")
#endif
            Spacer(minLength: 0)
            VStack {
                Text("正在播放").font(.caption.weight(.semibold))
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

    /// 右上角“三个点”更多操作菜单：放在播放控制区（原队列按钮位置）。
    private var moreMenu: some View {
        Menu {
            Button { model.setShuffle(!model.isShuffled) } label: {
                Label(model.isShuffled ? "关闭随机播放" : "随机播放",
                      systemImage: model.isShuffled ? "shuffle.circle.fill" : "shuffle")
            }
            Divider()
            Button { isPlaylistSheetPresented = true } label: {
                Label("添加到歌单", systemImage: "text.badge.plus")
            }
            if model.isDownloading(model.currentTrack) {
                let progress = model.downloadingProgress[model.currentTrack.id] ?? 0
                Button(role: .destructive) { model.cancelDownload(model.currentTrack) } label: {
                    Label("取消下载（\(Int(progress * 100))%）", systemImage: "xmark.circle")
                }
            } else if model.isDownloaded(model.currentTrack) {
                Button(role: .destructive) { model.removeDownload(model.currentTrack) } label: {
                    Label("删除本地缓存", systemImage: "trash")
                }
            } else {
                Button { model.download(model.currentTrack) } label: {
                    Label("下载到本地", systemImage: "arrow.down.circle")
                }
            }
            Divider()
            Button { model.skipBackward() } label: { Label("后退 15 秒", systemImage: "gobackward.15") }
            Button { model.skipForward() } label: { Label("快进 30 秒", systemImage: "goforward.30") }
            Button(role: .destructive) { model.stopPlayback() } label: { Label("停止播放", systemImage: "stop.fill") }
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        model.setPlaybackRate(Float(speed))
                    } label: {
                        if abs(model.playbackRate - Float(speed)) < 0.01 {
                            Label("\(speed, specifier: "%.2g")x", systemImage: "checkmark")
                        } else {
                            Text("\(speed, specifier: "%.2g")x")
                        }
                    }
                }
            } label: {
                Label("播放速度 \(model.playbackRate, specifier: "%.2g")x", systemImage: "speedometer")
            }
            Divider()
            Button { page = .lyrics } label: { Label("查看歌词", systemImage: "quote.bubble") }
            Button {
                dismiss()
                model.selectedSection = .settings
            } label: {
                Label("前往设置", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(HapticBorderedButtonStyle())
        .accessibilityLabel("更多操作")
    }

    private var player: some View {
        GeometryReader { geo in
            let compactHeight = geo.size.height < 720
            // 封面宽度不超过可用宽度的 72%，大屏最多 300pt，小屏再缩小，
            // 保证左右有明显边距，且不会压住进度条或标题。
            let artworkSide = min(
                compactHeight ? 240 : 300,
                geo.size.width * 0.72
            )
            let sectionSpacing: CGFloat = compactHeight ? AuralisSpacing.medium : AuralisSpacing.large
            let playButtonSize: CGFloat = compactHeight ? 56 : 72

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: sectionSpacing) {
                    // 封面后方叠加播放态动态光效（呼吸光晕 + 间歇波纹），不遮挡封面。
                    ZStack {
                        NowPlayingArtworkGlowView(
                            isPlaying: model.playbackState == .playing,
                            artworkKey: model.currentTrack.artworkKey,
                            title: model.currentTrack.albumTitle,
                            colors: theme.colorTokens,
                            size: artworkSide
                        )
                        ArtworkView(
                            title: model.currentTrack.albumTitle,
                            artworkKey: model.currentTrack.artworkKey,
                            colors: theme.colorTokens,
                            size: artworkSide
                        )
                        .shadow(
                            color: theme.colorTokens.accent.color.opacity(theme.motion.glowIntensity),
                            radius: compactHeight ? 20 : 28
                        )
                    }

                    // 歌曲信息与收藏按钮在同一行，收藏按钮不单独悬浮在封面外
                    HStack(alignment: .center, spacing: AuralisSpacing.medium) {
                        VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                            Text(model.currentTrack.title)
                                .font(.title2.bold())
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                                .lineLimit(1)
                            Text(model.currentTrack.artistName)
                                .font(.title3)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(nowPlayingAccessibilityLabel)
                        Spacer(minLength: AuralisSpacing.small)
                        favoriteButton
                    }
                    .frame(maxWidth: 520)

                    // 进度条位于歌曲信息下方，左右留出边距（Apple Music 风格细轨道）
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
                            onValueChanged: { pendingSeek = $0 }
                        )
                        .accessibilityLabel("播放进度")
                        .accessibilityValue(Text(formatDuration(model.playbackPosition)))
                        HStack {
                            Text(formatDuration(model.playbackPosition))
                            Spacer()
                            Text("-" + formatDuration(max(model.currentTrack.duration - model.playbackPosition, 0)))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }

                    // 播放控制：循环 | 上一首 | 播放 | 下一首 | 队列
                    transportControls(playButtonSize: playButtonSize)

                    // 音量
                    volumeControl

                    // 音质 + AirPlay（AirPlay 限制为普通按钮尺寸）
                    bottomInfo
                }
                .frame(maxWidth: 560)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AuralisSpacing.large)
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
        .accessibilityLabel(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
    }

    private func transportControls(playButtonSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 播放模式：单个按钮循环切换「列表顺序 → 随机播放 → 循环播放」。
            transportItem {
                Button(action: model.cyclePlayMode) {
                    Image(systemName: model.playMode.symbol)
                        .font(.title3)
                        .foregroundStyle(model.playMode == .list ? theme.colorTokens.secondaryText.color : theme.colorTokens.accent.color)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel("播放模式：\(model.playMode.title)")
            }
            transportItem {
                Button(action: model.previous) {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .disabled(!model.hasPrevious)
                .accessibilityLabel("上一首")
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
                .accessibilityLabel(model.playbackState == .playing ? "暂停" : "播放")
            }
            transportItem {
                Button(action: model.next) {
                    Image(systemName: "forward.fill").font(.title2)
                }
                .disabled(!model.canGoNext)
                .accessibilityLabel("下一首")
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
                onValueChanged: { model.setVolume(Float($0)) }
            )
            .accessibilityLabel("音量")
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .frame(maxWidth: 420)
    }

    private var bottomInfo: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Label(model.currentTrack.effectiveCodec?.uppercased() ?? "未知", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Spacer()
            RoutePickerView()
                .frame(width: 28, height: 28)
                .accessibilityLabel("AirPlay 输出设备")
        }
        .frame(maxWidth: 420)
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
        case .playing: state = "播放中"
        case .paused: state = "已暂停"
        default: state = "未播放"
        }
        return "\(model.currentTrack.title)，\(model.currentTrack.artistName)，专辑 \(model.currentTrack.albumTitle)，\(state)"
    }

    /// 当前应高亮的歌词行：仅对带时间轴的同步歌词按播放位置计算。
    private var currentLyricIndex: Int? {
        guard let document = model.currentLyrics, document.isSynced else { return nil }
        let position = model.playbackPosition
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: AuralisSpacing.large) {
                    if let document = model.currentLyrics {
                        ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = index == currentLyricIndex
                            Text(line.text)
                                .font(.title2.weight(isCurrent ? .bold : .medium))
                                .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .id(index)
                        }
                    } else {
                        AuralisEmptyState(icon: "quote.bubble", title: "暂无歌词", message: "服务器没有返回歌词，稍后可从本地文件或 MusicBrainz 候选补全。", colors: theme.colorTokens)
                    }
                }
                .frame(maxWidth: 600, alignment: .center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AuralisSpacing.huge)
            }
            .onChange(of: currentLyricIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private var queue: some View {
        List {
            ForEach(model.queue) { track in
                TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectAndPlay(track) }
            }
#if os(iOS)
            .onDelete { model.removeFromQueue(atOffsets: $0) }
            .onMove { model.moveQueue(from: $0, to: $1) }
#endif
        }
        .scrollContentBackground(.hidden)
#if os(iOS)
        .environment(\.editMode, $queueEditMode)
        .overlay(alignment: .topTrailing) {
            if !model.queue.isEmpty {
                Button(queueEditMode.isEditing ? "完成" : "编辑") {
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
        case .lyrics: String(localized: "歌词")
        case .player: String(localized: "正在播放")
        case .queue: String(localized: "队列")
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
                        title: "还没有歌单",
                        message: "在服务器上创建歌单后，这里会列出所有可选歌单。",
                        colors: theme.colorTokens
                    )
                } else {
                    List(model.catalog.playlists) { playlist in
                        HStack {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(theme.colorTokens.accent.color)
                            VStack(alignment: .leading) {
                                Text(playlist.name)
                                    .foregroundStyle(theme.colorTokens.primaryText.color)
                                Text("\(playlist.trackIDs.count) 首")
                                    .font(.caption)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                            Spacer()
                            if feedback == playlist.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.colorTokens.success.color)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { add(to: playlist) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("添加到歌单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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
private struct ThinSlider: View {
    let value: Double
    let accent: Color
    let track: Color
    let thumb: Color
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

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
    }
}
