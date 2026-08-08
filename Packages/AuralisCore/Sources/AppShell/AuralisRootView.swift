import DesignSystem
import Domain
import SwiftUI
import ThemeEngine
#if os(iOS)
import CoreSpotlight
import UIKit
#endif

public struct AuralisRootView: View {
    @StateObject private var model: AuralisAppModel
    @StateObject private var themeStore: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        // 使用共享实例：快捷指令 / Siri 等系统入口与界面操作同一个播放服务。
        _model = StateObject(wrappedValue: AuralisAppModel.shared)
        _themeStore = StateObject(wrappedValue: ThemeStore())
    }

    public var body: some View {
        Group {
#if os(macOS)
            MacAuralisRootView(model: model, themeStore: themeStore)
#elseif os(iOS)
            if horizontalSizeClass == .compact {
                CompactShell(model: model, themeStore: themeStore)
            } else {
                DesktopShell(model: model, themeStore: themeStore)
            }
#endif
        }
        .environmentObject(model)
        .environment(model.artworkStore)
        .environmentObject(themeStore)
        .preferredColorScheme(themeStore.current.colorScheme)
        .tint(themeStore.current.colorTokens.accent.color)
        .buttonStyle(HapticButtonStyle())
        .animation(reduceMotion ? nil : .easeInOut(duration: themeStore.current.motion.standardDuration), value: themeStore.selectedID)
        .environment(\.auralisReduceTransparency, reduceTransparency)
        .task { await model.restorePersistedLibrary() }
        .onOpenURL { url in
            model.handleIncomingURL(url)
        }
        .onContinueUserActivity("INPlayMediaIntent") { userActivity in
            model.handleSiriUserActivity(userActivity)
        }
#if os(iOS)
        .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
            if let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                model.handleSpotlightIdentifier(identifier)
            }
        }
#endif
        .onContinueUserActivity("com.auralis.player.playback") { userActivity in
            model.handleHandoffActivity(userActivity)
        }
    }
}

#if os(iOS)
/// 底部双层 Dock 两控件共享的可见高度（迷你播放条与主菜单栏完全一致）。
/// 之前 72pt 太大、占用过多纵向空间，现统一收小到 56pt。
let bottomBarHeight: CGFloat = 56
/// 两控件之间的固定间距（与 BottomDock 的 VStack spacing 同源）。
let dockSpacing: CGFloat = 8
/// Dock 整体的底部内边距（与 BottomDock 的 .padding(.bottom) 同源）。
let dockBottomPadding: CGFloat = 6

private struct CompactShell: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore

    var body: some View {
        NavigationStack {
            SectionContent(section: model.selectedSection, model: model, themeStore: themeStore)
                .navigationTitle(model.selectedSection.title)
                // 顶部标题用系统大标题：字体大、与正文内容有明显区分（Apple Music 风格）。
                // 导航栏背景与页面背景同色：大标题下方不再出现与背景割裂的浅色圆角空条。
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(themeStore.current.colorTokens.background.color, for: .navigationBar)
        }
        .overlay(alignment: .bottom) {
            dockOverlay
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .environment(\.bottomDockReservedHeight, dockReservedHeight)
        .sheet(isPresented: nowPlayingBinding) {
            NowPlayingView(model: model, theme: themeStore.current)
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $model.shouldPresentServerSetup) {
            ServerConnectionSheet(model: model, theme: themeStore.current)
        }
        .sheet(item: browseDestinationBinding) { destination in
            BrowseDetailSheet(destination: destination, model: model, theme: themeStore.current)
        }
        .alert("播放失败", isPresented: .init(
            get: { model.playbackError != nil },
            set: { if !$0 { model.dismissPlaybackError() } }
        )) {
            Button("重试") { model.retryPlayback() }
            if model.hasNext {
                Button("下一首") { model.next() }
            }
            Button("确定") { model.dismissPlaybackError() }
        } message: {
            if let error = model.playbackError {
                switch error {
                case .networkUnavailable:
                    Text("网络不可用，请检查网络连接")
                case .unsupportedFormat(let format):
                    Text("不支持的音频格式：\(format)")
                case .authorizationFailed:
                    Text("授权失败，请检查登录状态")
                case .engineFailure(let message):
                    Text(message)
                }
            }
        }
    }

    /// 底部 Dock 真正占用的纵向高度（统一来源）：
    /// 直接从 BottomDock 的同一套布局参数读取实际高度与间距，
    /// 供各页面用完全相同的数字预留底部空间，避免每个页面写不一致的固定 padding。
    private var dockReservedHeight: CGFloat {
        let tabBarStack = bottomBarHeight + dockBottomPadding
        if model.selectedSection == .assistant {
            return bottomBarHeight + dockSpacing + tabBarStack
        }
        let hasMini = model.isMiniPlayerVisible && model.selectedSection != .settings
        return hasMini ? (bottomBarHeight + dockSpacing + tabBarStack) : tabBarStack
    }

    /// 悬浮在屏幕底部的 Dock 覆盖层（自身不预留内容空间，由各页面自行避让）。
    /// 助手页只渲染主菜单栏（输入框由助手页自身管理，独立响应键盘）；
    /// 其它页面渲染「迷你播放条 + 主菜单栏」。键盘不推动该覆盖层，由系统键盘自然覆盖。
    @ViewBuilder
    private var dockOverlay: some View {
        if model.selectedSection == .assistant {
            BottomGlassBarShell {
                MainTabBarContent(model: model, theme: themeStore.current)
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarHeight)
            .padding(.horizontal, 16)
            .padding(.bottom, dockBottomPadding)
        } else {
            BottomDock(model: model, theme: themeStore.current)
        }
    }
    /// 互斥呈现：服务器配置弹窗优先；正在播放 / 浏览详情不会与它同时弹出，
    /// 避免 UIKit "Attempt to present … which is already presenting …" 冲突导致卡顿。
    private var nowPlayingBinding: Binding<Bool> {
        Binding(
            get: { model.isNowPlayingPresented && !model.shouldPresentServerSetup },
            set: { newValue in
                if !newValue {
                    model.isNowPlayingPresented = false
                } else if !model.shouldPresentServerSetup {
                    model.isNowPlayingPresented = true
                }
            }
        )
    }

    private var browseDestinationBinding: Binding<BrowseDestination?> {
        Binding(
            get: { model.shouldPresentServerSetup ? nil : model.browseDestination },
            set: { model.browseDestination = $0 }
        )
    }
}

/// 双层悬浮液态玻璃 Dock：迷你播放条 + 主菜单栏。
/// 两者放进同一个父级 VStack(spacing: 8) 统一管理，共用同一宽度来源与玻璃外壳，
/// 保证等宽、等高（bottomBarHeight）、等圆角、8pt 间距，且只有一次 safeAreaInset。

private struct BottomDock: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        VStack(spacing: dockSpacing) {
            if model.isMiniPlayerVisible && model.selectedSection != .settings {
                BottomGlassBarShell {
                    MiniPlayerContent(model: model, theme: theme, height: bottomBarHeight)
                }
                .frame(maxWidth: .infinity)
                .frame(height: bottomBarHeight)
                .contentShape(Rectangle())
                .onTapGesture { model.isNowPlayingPresented = true }
                .accessibilityElement(children: .contain)
            }

            BottomGlassBarShell {
                MainTabBarContent(model: model, theme: theme)
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, dockBottomPadding)
    }
}

/// AI 助手输入框（iOS，渲染在助手页底部安全区，取代迷你播放条的位置）。
/// 与迷你播放条共用 BottomGlassBarShell、同一高度与材质；点击发送 / 运行时切换为停止。
/// 焦点由调用方通过 `focus` 传入（助手页用 @FocusState 管理），便于页面在发送 / 点击空白时收起键盘。
struct DockAssistantInputBar: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var focus: FocusState<Bool>.Binding

    var body: some View {
        BottomGlassBarShell {
            HStack(alignment: .center, spacing: AuralisSpacing.medium) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .frame(width: 22, height: 22)
                TextField("描述你想听的音乐，或让我帮你操作", text: $model.assistantDraft)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .onSubmit { model.sendAssistantMessage(); focus.wrappedValue = false }
                Button {
                    if model.assistantIsRunning {
                        model.cancelAssistant()
                    } else {
                        model.sendAssistantMessage()
                        focus.wrappedValue = false
                    }
                } label: {
                    Image(systemName: model.assistantIsRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel(model.assistantIsRunning ? "停止" : "发送")
                .frame(width: 32, height: 32)
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: bottomBarHeight)
        // 与迷你播放条使用完全相同的左右边距（16pt），保证两态 frame 一致、不铺满屏幕。
        .padding(.horizontal, 16)
    }
}

/// 公共液态玻璃外壳：统一负责背景材质、玻璃折射、圆角、边缘高光与阴影。
/// 迷你播放条与主菜单栏都通过它绘制外轮廓，保证尺寸与材质完全一致。
/// 材质使用系统原生液态玻璃（glassEffect），边缘仅保留极细的高光描边，
/// 不再用不透明白色粗描边，整体更接近苹果标准工具栏质感。
struct BottomGlassBarShell<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.auralisReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: bottomBarHeight, maxHeight: bottomBarHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: bottomBarHeight / 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: bottomBarHeight / 2, style: .continuous)
                    .stroke(Color.white.opacity(reduceTransparency ? 0.10 : 0.08), lineWidth: 0.5)
            )
            .shadow(
                color: Color.black.opacity(reduceTransparency ? 0.08 : 0.14),
                radius: 12, x: 0, y: 6
            )
    }
}

/// 主菜单栏内部内容：五个主入口等分宽度，图标与文字居中，
/// 选中高亮仅存在于栏内，不改变栏的整体宽度与高度。
private struct MainTabBarContent: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { section in
                Button {
                    model.selectedSection = section
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 19, weight: .medium))
                        Text(section.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .foregroundStyle(
                        model.selectedSection == section
                        ? theme.colorTokens.accent.color
                        : theme.colorTokens.secondaryText.color
                    )
                    // 选中态：液态玻璃高亮胶囊（半透明白） + 强调色图标，符合 iOS 26 玻璃工具栏观感。
                    .background(
                        model.selectedSection == section
                        ? AnyShapeStyle(.white.opacity(0.20))
                        : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
#endif

private struct DesktopShell: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore

    var body: some View {
        NavigationSplitView {
            List {
                // 参照 Apple Music：侧边栏按「资料库 / 工具」分组，选中项用强调色胶囊高亮。
                Section("资料库") {
                    desktopRow(.home)
                    desktopRow(.library)
                    desktopRow(.search)
                }
                Section("工具") {
                    desktopRow(.assistant)
                    desktopRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("澜音")
            .safeAreaInset(edge: .bottom) {
                ServerStatus(model: model, theme: themeStore.current)
            }
        } content: {
            SectionContent(section: model.selectedSection, model: model, themeStore: themeStore)
                .navigationTitle(model.selectedSection.title)
                // 宽屏（Mac / iPad 横屏）内容居中，避免页面被拉成一条横贯的宽条。
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            InspectorView(model: model, theme: themeStore.current)
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            if model.isMiniPlayerVisible && model.selectedSection != .assistant && model.selectedSection != .settings {
                MiniPlayer(model: model, theme: themeStore.current)
            }
        }
        .sheet(isPresented: nowPlayingBinding) {
            NowPlayingView(model: model, theme: themeStore.current)
                #if os(iOS)
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
                #endif
                .frame(minWidth: 620, minHeight: 680)
        }
        .sheet(isPresented: $model.shouldPresentServerSetup) {
            ServerConnectionSheet(model: model, theme: themeStore.current)
        }
        .sheet(item: browseDestinationBinding) { destination in
            BrowseDetailSheet(destination: destination, model: model, theme: themeStore.current)
        }
        .alert("播放失败", isPresented: .init(
            get: { model.playbackError != nil },
            set: { if !$0 { model.dismissPlaybackError() } }
        )) {
            Button("重试") { model.retryPlayback() }
            if model.hasNext {
                Button("下一首") { model.next() }
            }
            Button("确定") { model.dismissPlaybackError() }
        } message: {
            if let error = model.playbackError {
                switch error {
                case .networkUnavailable:
                    Text("网络不可用，请检查网络连接")
                case .unsupportedFormat(let format):
                    Text("不支持的音频格式：\(format)")
                case .authorizationFailed:
                    Text("授权失败，请检查登录状态")
                case .engineFailure(let message):
                    Text(message)
                }
            }
        }
    }

    /// 侧边栏行：图标 + 文字，选中时强调色胶囊高亮。
    private func desktopRow(_ section: AppSection) -> some View {
        Button {
            model.selectedSection = section
        } label: {
            Label(section.title, systemImage: section.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 3)
        }
        .buttonStyle(HapticPlainButtonStyle())
        .listRowBackground(
            section == model.selectedSection
            ? themeStore.current.colorTokens.accent.color.opacity(0.16)
            : Color.clear
        )
    }

    /// 互斥呈现：服务器配置弹窗优先；正在播放 / 浏览详情不会与它同时弹出，
    /// 避免 UIKit "Attempt to present … which is already presenting …" 冲突导致卡顿。
    private var nowPlayingBinding: Binding<Bool> {
        Binding(
            get: { model.isNowPlayingPresented && !model.shouldPresentServerSetup },
            set: { newValue in
                if !newValue {
                    model.isNowPlayingPresented = false
                } else if !model.shouldPresentServerSetup {
                    model.isNowPlayingPresented = true
                }
            }
        )
    }

    private var browseDestinationBinding: Binding<BrowseDestination?> {
        Binding(
            get: { model.shouldPresentServerSetup ? nil : model.browseDestination },
            set: { model.browseDestination = $0 }
        )
    }

}
private struct SectionContent: View {
    let section: AppSection
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.bottomDockReservedHeight) private var reservedHeight

    var body: some View {
        page
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 助手页由 AssistantView 自己管理输入框 + 主菜单栏的避让，这里不重复预留。
                if section != .assistant {
                    Color.clear.frame(height: reservedHeight)
                }
            }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .home:
            HomeView(model: model, theme: themeStore.current)
        case .library:
            LibraryView(model: model, theme: themeStore.current)
        case .assistant:
            AssistantView(model: model, theme: themeStore.current)
        case .search:
            SearchView(model: model, theme: themeStore.current)
        case .settings:
            SettingsView(model: model, themeStore: themeStore)
        }
    }
}

private struct AuralisReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var auralisReduceTransparency: Bool {
        get { self[AuralisReduceTransparencyKey.self] }
        set { self[AuralisReduceTransparencyKey.self] = newValue }
    }
}

/// 底部 Dock 真实占用的纵向高度。由各页面读取，作为底部 safe area inset 的统一来源，
/// 让首页 / 设置 / 音乐库 / 搜索 / 助手页用同一套数字避让悬浮控件（macOS 不渲染 Dock，默认 0）。
private struct BottomDockReservedHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomDockReservedHeight: CGFloat {
        get { self[BottomDockReservedHeightKey.self] }
        set { self[BottomDockReservedHeightKey.self] = newValue }
    }
}

/// 浏览详情弹窗：专辑/艺术家/歌单/收藏/最常听的歌曲清单。
/// 先展示清单，点选单曲才播放；顶部提供「播放全部」作为显式的整列播放入口。
private struct BrowseDetailSheet: View {
    let destination: BrowseDestination
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var isConfirmingDownload = false
    @Environment(\.dismiss) private var dismiss

    private var tracks: [Track] {
        switch destination {
        case let .album(album):
            return model.catalog.tracks.filter { $0.albumID == album.id }
        case let .artist(artist):
            return model.catalog.tracks.filter { $0.artistID == artist.id }
        case let .playlist(playlist):
            // 优先使用从服务器拉取的完整曲目
            if let loaded = model.playlistTracks[playlist.id], !loaded.isEmpty {
                return loaded
            }
            return playlist.trackIDs.compactMap { id in model.catalog.tracks.first { $0.id == id } }
            case .favorites:
                return model.homeFavoriteTracks
            case .mostPlayed:
                return model.homeMostPlayedTracks
            case .playlists:
                return []
            case let .genre(genre):
                let local = model.tracks(for: genre)
                return local.isEmpty ? (model.genreTracks ?? []) : local
            case .random:
                return model.randomTracks
            case .recentlyPlayed:
                return model.homeRecentlyPlayedTracks
            case .recentlyAdded:
                return Array(model.homeRecentlyAddedTracks.prefix(200))
            case .longUnplayed:
                return model.homeLongUnplayedTracks
            case .neverPlayed:
                return model.homeNeverPlayedTracks
            case .favoriteRandom:
                return model.homeFavoriteRandomTracks
            case .downloads:
                return model.downloadedTracks
            case .topArtists, .topAlbums:
                return []
        }
    }

    private var title: String {
        switch destination {
        case let .album(album): album.title
        case let .artist(artist): artist.name
        case let .playlist(playlist): playlist.name
        case .playlists: "歌单"
        case .favorites: "收藏"
        case .mostPlayed: "最常听"
        case let .genre(genre): GenreLocalization.displayName(for: genre.name)
        case .random: "随机音乐"
        case .recentlyPlayed: "最近播放"
        case .recentlyAdded: "最近添加"
        case .longUnplayed: "很久没听"
        case .neverPlayed: "从未播放"
        case .favoriteRandom: "收藏里随便听"
        case .topArtists: "常听艺术家"
        case .topAlbums: "常听专辑"
        case .downloads: "下载"
        }
    }

    private var subtitle: String {
        switch destination {
        case let .album(album): "\(album.artistName) · \(tracks.count) 首"
        case .artist: "\(tracks.count) 首歌曲"
        case let .playlist(playlist): playlist.comment ?? "\(tracks.count) 首歌曲"
        case .playlists: "\(model.catalog.playlists.count) 个歌单"
        case .favorites: "\(tracks.count) 首喜爱的歌曲"
        case .mostPlayed: "按你的播放次数排序"
        case let .genre(genre): "\(tracks.count) 首 · 按流派「\(GenreLocalization.displayName(for: genre.name))」筛选"
        case .random: "点右上角「换一批」可重新随机"
        case .recentlyPlayed: "\(tracks.count) 首 · 最近播放过的歌曲"
        case .recentlyAdded: "\(tracks.count) 首 · 最近同步进来的歌曲"
        case .longUnplayed: "\(tracks.count) 首 · 播放过但最近没听的歌曲"
        case .neverPlayed: "\(tracks.count) 首 · 还没播放过的歌曲"
        case .favoriteRandom: "点右上角「换一批」可重新随机"
        case .topArtists: "按真实播放次数统计的艺术家"
        case .topAlbums: "按真实播放次数统计的专辑"
        case .downloads: "\(tracks.count) 首 · 已下载到本地的歌曲"
        }
    }

    private var artworkKey: String? {
        switch destination {
        case let .album(album): album.artworkKey
        case let .artist(artist): artist.artworkKey
        default: nil
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if isRandomDestination {
                            Button {
                                regenerateCurrentSample()
                            } label: {
                                Label("换一批", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .onAppear {
            if case let .playlist(playlist) = destination {
                model.loadPlaylistTracks(playlistID: playlist.id)
            } else if case let .genre(genre) = destination, model.tracks(for: genre).isEmpty {
                // 本地按流派筛选为空时，从服务器按流派拉取真实歌曲
                // （Navidrome 等服务器 getGenres 常为空，但按流派列专辑可用）。
                model.loadGenreTracks(genre)
            }
        }
        .confirmationDialog(
            "下载 \(tracks.count) 首歌曲？",
            isPresented: $isConfirmingDownload,
            titleVisibility: .visible
        ) {
            Button("开始下载") {
                model.downloadAll(tracks)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("预计约 \(estimatedSizeMB(tracks.count)) MB，下载到本地后可离线播放。已下载的歌曲会自动跳过。")
        }
    }

    private func estimatedSizeMB(_ count: Int) -> Int {
        // 按平均 8 MB/首估算（原始 FLAC 更大、MP3 更小），仅用于下载前容量提示。
        Int((Double(count) * 8 / 1024).rounded())
    }

    @ViewBuilder
    private var content: some View {
        if case .playlists = destination {
            playlistList
        } else if case .topArtists = destination {
            artistList
        } else if case .topAlbums = destination {
            albumList
        } else if isGenreLoading {
            ProgressView("正在从服务器加载「\(currentGenreName)」歌曲…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            AuralisEmptyState(
                icon: "music.note",
                title: "暂无歌曲",
                message: emptyMessage,
                colors: theme.colorTokens
            )
        } else {
            trackList
        }
    }

    /// 流派详情正在从服务器加载（本地筛选为空且尚未返回结果）。
    private var isGenreLoading: Bool {
        if case let .genre(genre) = destination,
           model.tracks(for: genre).isEmpty,
           model.loadingGenre?.name == genre.name,
           model.genreTracks == nil {
            return true
        }
        return false
    }

    private var currentGenreName: String {
        if case let .genre(genre) = destination { return genre.name }
        return ""
    }

    private var emptyMessage: String {
        switch destination {
        case .favorites: "在播放页或歌曲菜单中点心形收藏后，会出现在这里。"
        case .mostPlayed: "播放过的歌曲会按次数统计在这里。"
        case .longUnplayed: "播放过的歌曲会先出现在「最近播放」，过一段时间没听就会回到这里。"
        case .neverPlayed: "还没有播放记录时，这里暂时为空。"
        case .favoriteRandom: "收藏里的歌曲会随机出现在这里。"
        case .downloads: "下载到本地的歌曲会出现在这里。"
        case .topArtists: "播放过的歌曲会按艺术家统计在这里。"
        case .topAlbums: "播放过的歌曲会按专辑统计在这里。"
        default: "这个清单里暂时没有歌曲。"
        }
    }

    private var trackList: some View {
        List {
            Section {
                HStack(spacing: AuralisSpacing.medium) {
                    ArtworkView(title: title, artworkKey: artworkKey, colors: theme.colorTokens, size: 88)
                    VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                        HStack(spacing: AuralisSpacing.small) {
                            Button {
                                playAll()
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(HapticProminentButtonStyle())
                            .disabled(tracks.isEmpty)
                            Button {
                                isConfirmingDownload = true
                            } label: {
                                Label("下载", systemImage: "arrow.down.circle")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(HapticBorderedButtonStyle())
                            .disabled(tracks.isEmpty)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, AuralisSpacing.xSmall)
            }
            Section("歌曲") {
                ForEach(tracks) { track in
                    TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.queue = model.uniquedTracks(tracks)
                            model.selectAndPlay(track)
                            dismiss()
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    /// 歌单总览：点选进入歌单内的歌曲清单。
    private var playlistList: some View {
        List(model.catalog.playlists) { playlist in
            NavigationLink {
                PlaylistTracksView(playlist: playlist, model: model, theme: theme)
            } label: {
                HStack(spacing: AuralisSpacing.medium) {
                    if let coverKey = playlistCoverKey(model, playlist) {
                        ArtworkView(title: playlist.name, artworkKey: coverKey, colors: theme.colorTokens, size: 40, cornerRadius: 8)
                    } else {
                        Image(systemName: "music.note.list")
                            .font(.title3)
                            .foregroundStyle(theme.colorTokens.accent.color)
                            .frame(width: 40, height: 40)
                            .background(theme.colorTokens.surface.color)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading) {
                        Text(playlist.name)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// 随机类浏览页（随机音乐 / 收藏里随便听）：右上角「换一批」本地重采样，不发网络请求。
    private var isRandomDestination: Bool {
        if case .random = destination { return true }
        if case .favoriteRandom = destination { return true }
        return false
    }

    private func regenerateCurrentSample() {
        if case .favoriteRandom = destination {
            model.regenerateFavoriteRandomMusic()
        } else {
            model.regenerateRandomMusic()
        }
    }

    /// 常听艺术家列表：按真实播放次数降序，点选进入艺术家详情。
    private var artistList: some View {
        List(model.homeTopArtists) { artist in
            Button {
                dismiss()
                model.browseDestination = .artist(artist)
            } label: {
                HStack(spacing: AuralisSpacing.medium) {
                    ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: theme.colorTokens, size: 44, cornerRadius: AuralisRadius.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text("\(model.homeTopArtistPlayCounts[artist.id] ?? 0) 次播放")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
            }
            .buttonStyle(HapticPlainButtonStyle())
        }
        .listStyle(.plain)
    }

    /// 常听专辑列表：按真实播放次数降序，点选进入专辑详情。
    private var albumList: some View {
        List(model.homeTopAlbums) { album in
            Button {
                dismiss()
                model.browseDestination = .album(album)
            } label: {
                HStack(spacing: AuralisSpacing.medium) {
                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: 44, cornerRadius: AuralisRadius.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text(album.artistName)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                            .lineLimit(1)
                        Text("\(model.homeTopAlbumPlayCounts[album.id] ?? 0) 次播放")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
            }
            .buttonStyle(HapticPlainButtonStyle())
        }
        .listStyle(.plain)
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        model.queue = tracks
        model.selectAndPlay(first)
        dismiss()
    }
}

/// 歌单内的歌曲清单（从歌单总览推入）。
/// getPlaylists（复数）只返回歌单元数据不含曲目，必须调 getPlaylist（单数）才有完整 entry。
private struct PlaylistTracksView: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    private var tracks: [Track] {
        // 优先使用从服务器拉取的完整曲目；回退到 catalog 中已缓存的匹配
        if let loaded = model.playlistTracks[playlist.id], !loaded.isEmpty {
            return loaded
        }
        return playlist.trackIDs.compactMap { id in model.catalog.tracks.first { $0.id == id } }
    }

    private var isLoading: Bool {
        model.loadingPlaylistIDs.contains(playlist.id)
    }

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isDeleting = false
    @State private var isDuplicating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView("正在加载歌单…")
            } else if tracks.isEmpty {
                AuralisEmptyState(
                    icon: "music.note.list",
                    title: "歌单暂无歌曲",
                    message: "服务器上这个歌单里还没有添加歌曲。",
                    colors: theme.colorTokens
                )
            } else {
                List {
                    ForEach(tracks) { track in
                        TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.queue = model.uniquedTracks(tracks)
                                model.selectAndPlay(track)
                            }
                    }
                    .onDelete { offsets in
                        // 滑动删除：把服务器歌单里的对应曲目移除（同步到服务器 + 本地目录）。
                        let indices = Array(offsets)
                        Task { _ = await model.removeFromPlaylist(id: playlist.id, atIndices: indices) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = playlist.name
                        isRenaming = true
                    } label: { Label("重命名", systemImage: "pencil") }
                    Button {
                        isDuplicating = true
                        Task {
                            _ = await model.duplicatePlaylist(id: playlist.id)
                            isDuplicating = false
                        }
                    } label: { Label(isDuplicating ? "复制中…" : "复制歌单", systemImage: "plus.square.on.square") }
                    .disabled(isDuplicating)
                    Button {
                        Task { await model.removeDuplicateSongs(from: playlist.id) }
                    } label: { Label("去重歌曲", systemImage: "sparkles") }
                    Button(role: .destructive) {
                        isDeleting = true
                    } label: { Label("删除歌单", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("歌单操作")
            }
        }
        .alert("重命名歌单", isPresented: $isRenaming) {
            TextField("歌单名称", text: $renameText)
            Button("保存") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    Task { _ = await model.renamePlaylist(id: playlist.id, to: name) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("修改将同步到服务器。")
        }
        .confirmationDialog("删除歌单「\(playlist.name)」？", isPresented: $isDeleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    _ = await model.deletePlaylist(id: playlist.id)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务器上的歌单也会被删除，此操作不可撤销。")
        }
        .onAppear { model.loadPlaylistTracks(playlistID: playlist.id) }
    }
}


/// 歌单封面：取歌单内第一首歌曲的封面（同一专辑多首歌曲共享封面）。
@MainActor
private func playlistCoverKey(_ model: AuralisAppModel, _ playlist: Playlist) -> String? {
    guard let firstID = playlist.trackIDs.first else { return nil }
    return model.catalog.tracks.first { $0.id == firstID }?.artworkKey
}
