#if os(macOS)
@preconcurrency import AppKit
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 主窗口 Shell（Round-4）：
/// 普通资料库 UI + 同一窗口内的 Expanded Player 覆盖（不新建 Full Player 窗口）。
/// 展开/收起只改 presentation state，不改 navigation selection / path / scroll / search。
/// 主窗口 chrome 的**唯一**状态 writer：
/// - 进入窗口时只把窗口交给唯一所有者（attach）；
/// - 展开状态完全由 `isExpanded` 驱动，updateNSView 幂等写入
///   `setExpanded(isExpanded)`。
/// 不再有第二个 writer（旧的 MacExpandedWindowChrome 已删除），
/// 避免 SwiftUI 重挂载/窗口重排时普通与展开两个附着器互相写回。
private struct MacWindowAttacher: NSViewRepresentable {
    let isExpanded: Bool
    let windowCoordinator: MacWindowVisibilityCoordinator

    func makeNSView(context: Context) -> AttacherView {
        AttacherView(windowCoordinator: windowCoordinator)
    }
    func updateNSView(_ view: AttacherView, context: Context) {
        // 由 AttacherView 自己做 last-write-wins 合并：快速开关播放器时
        // updateNSView 可能被高频调用，只保留最后一次 expanded 值，
        // 合并到下一轮 MainActor 执行（避免每个 Task 各写一次窗口属性）。
        view.scheduleApply(expanded: isExpanded)
    }
    final class AttacherView: NSView {
        let controller = MacWindowChromeController()
        let windowCoordinator: MacWindowVisibilityCoordinator
        private var pendingExpanded = false
        private var applyScheduled = false

        init(windowCoordinator: MacWindowVisibilityCoordinator) {
            self.windowCoordinator = windowCoordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        /// 记录最新状态并合并到下一轮 MainActor 执行：
        /// - 不在 SwiftUI 视图更新事务内同步修改 NSWindow 属性（避免
        ///   "Publishing changes from within view updates is not allowed"）；
        /// - 同一 run loop 内多次调用只执行一次 apply（last-write-wins）。
        func scheduleApply(expanded: Bool) {
            pendingExpanded = expanded
            guard !applyScheduled else { return }
            applyScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyScheduled = false
                    self.controller.attach(self.window)
                    self.controller.setExpanded(self.pendingExpanded)
                    self.windowCoordinator.registerMainWindow(self.window)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // NSView 挂载是真正可靠的窗口就绪信号（updateNSView 可能在
            // view.window == nil 时先跑），这里同样注册 chrome 与主窗口。
            scheduleApply(expanded: pendingExpanded)
        }
    }
}

@MainActor
private final class MacFullscreenTransitionCoordinator: ObservableObject {
    /// 仅在 MainActor 上读写（observeExit / cancelPendingExit）；
    /// deinit 中移除 observer 是 NSNotificationCenter 推荐的兜底清理，
    /// removeObserver(_:) 线程安全，故用 nonisolated(unsafe) 声明。
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    func observeExit(of window: NSWindow, action: @escaping @MainActor () -> Void) {
        cancelPendingExit()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 退出全屏是一次性状态转换，回调一到就注销，避免重复收播放器。
                self.cancelPendingExit()
                action()
            }
        }
    }

    func cancelPendingExit() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

public struct MacMusicShell: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var settingsRouter: MacSettingsRouter

    @StateObject private var navigation = MacNavigationModel()
    @StateObject private var sidebarPrefs = MacSidebarPreferences()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedTracks: Set<GlobalID> = []
    @State private var rightPanelMode: MacRightPanelMode = .queue
    @State private var showRightPanel = false
    @State private var getInfoTrack: Track?
    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""

    @StateObject private var playerState = MacPlayerPresentationState()
    @StateObject private var fullscreenCoordinator = MacFullscreenTransitionCoordinator()
    /// 播放器覆盖层是否已挂载（transient overlay，libraryUI 永不卸载）。
    @State private var playerOverlayMounted = false
    /// 覆盖层前景是否可见（由 Shell 驱动动画，Expanded 内部不自行 withAnimation）。
    @State private var playerOverlayVisible = false
    /// 播放器挂载期间压住 library 的 toolbar title；关闭动画完成前绝不恢复。
    @State private var suppressLibraryToolbar = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: BuiltInTheme { themeStore.current }

    public init(model: AuralisAppModel, themeStore: ThemeStore, settingsRouter: MacSettingsRouter = MacSettingsRouter()) {
        self.model = model
        self.themeStore = themeStore
        self.settingsRouter = settingsRouter
    }

    public var body: some View {
        attachLifecycle(attachModals(contents))
            .background(MacWindowAttacher(isExpanded: playerOverlayMounted, windowCoordinator: .shared))
    }

    private var contents: some View {
        ZStack {
            // 主界面（NavigationSplitView / NavigationStack / libraryUI）从窗口创建到关闭
            // **永远保持挂载**，展开/关闭播放器绝不重建导航树——这消灭：
            // 1) 首页标题闪现；2) NavigationRequestObserver 同帧重建；3) sheet/搜索/滚动
            // /selection 因播放器切换被重新挂载。
            libraryUI
                .allowsHitTesting(!playerOverlayMounted)
                .accessibilityHidden(playerOverlayMounted)

            if playerOverlayMounted {
                MacExpandedPlayerView(
                    model: model,
                    theme: theme,
                    context: $playerState.context,
                    isVisible: playerOverlayVisible,
                    onCollapse: collapseExpandedPlayer,
                    onOpenMiniPlayer: switchToMiniPlayer
                )
                .zIndex(100)
            }
        }
        // Expanded Player 只隔离 library 的 toolbar **内容**，不隐藏 window chrome：
        // libraryUI 必须保持挂载（导航 / 滚动 / 搜索状态不重建），expanded 时用
        // removing(.title) 移除 SwiftUI 自动生成的页面标题 item（左上角
        // 「Auralis / 页面标题」的来源）。**绝不能对整个 .windowToolbar 用 .hidden**——
        // 真机回归证明：SwiftUI 隐藏 windowToolbar 会连带隐藏 titlebar 上的系统
        // 红黄绿窗口控制按钮（81cc91b4 曾改用 .hidden，导致窗口控制点消失）。
        // Mac 平台无任何自定义 ToolbarItem 注册（仅 iOS 视图有），sidebarToggle
        // 已在 sidebar 上无条件移除，因此恢复 .automatic 不会让 library 内容透出。
        //
        // normal 状态同样 .automatic：NavigationStack 页面标题与工具栏正常显示。
        .toolbar(
            removing: suppressLibraryToolbar
                ? ToolbarDefaultItemKind.title
                : nil
        )
        .toolbarVisibility(.automatic, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 用户选择主题后，主窗口、AI 助手与每个资料库目的地共享同一套色彩和控件强调色。
        .tint(theme.colorTokens.accent.color)
        .preferredColorScheme(theme.colorScheme)
        // 环境注入放到 ZStack 层：libraryUI 与同窗口 Expanded Player 都能继承
        // ArtworkStore / ThemeStore（否则 Expanded 内的 ArtworkView 强解包崩溃）。
        .environment(\.artworkStore, model.artworkStore)
        .environmentObject(themeStore)
    }

    // MARK: - 普通资料库 UI

    private var libraryUI: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(
                model: model,
                prefs: sidebarPrefs,
                selection: $navigation.selection,
                theme: theme,
                onOpenAssistantPlayer: { expandCurrentWindowPlayer() }
            )
            // 顶部不留按钮：移除系统 Hide Sidebar 按钮。必须挂在 sidebar 视图上
            // 才生效（挂 NavigationSplitView 整体不生效——macOS 已知行为）。
            // 菜单栏「显示」里的显示/隐藏侧边栏仍可用（AuralisMacApp CommandMenu）。
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // 不能把播放条挂在页面内容的 safeAreaInset 上：空态 VStack 会给它一个
            // 非窗口高度，导致下载/不喜欢等页面的播放条上跳。这里由 detail 的
            // GeometryReader 提供稳定窗口坐标，内容仅预留播放器所占底部空间。
            GeometryReader { geo in
                // 窗口极窄或 GeometryReader 首帧给出 0/极小宽度时，
                // “宽度 - 2*inset” 会变成负数，.frame(width:) 会报
                // “Invalid frame dimension (negative or non-finite)”。用 max(0, _) 夹住。
                let playerWidth = min(
                    MacUIVisualTokens.FloatingPlayer.maxWidth,
                    max(0, geo.size.width - 2 * MacUIVisualTokens.FloatingPlayer.horizontalInset)
                )
                ZStack {
                    NavigationStack(path: $navigation.path) {
                        detailContent
                            .navigationDestination(for: MacDetailRoute.self) { route in
                                detailRouteView(route)
                            }
                    }
                    .navigationTitle(currentTitle)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear
                            .frame(height: playerDockReservedHeight)
                            .accessibilityHidden(true)
                    }
                    .inspector(isPresented: $showRightPanel) {
                        MacRightPanel(model: model, theme: theme, mode: rightPanelMode)
                    }

                    // 播放条用明确坐标严格水平居中：不再依赖 ZStack alignment +
                    // padding + maxWidth 间接推算（父容器 proposal 改变时会左右漂移）。
                    playerBar
                        .frame(width: playerWidth)
                        .position(
                            x: geo.size.width / 2,
                            y: geo.size.height
                                - MacUIVisualTokens.FloatingPlayer.bottomInset
                                - MacUIVisualTokens.FloatingPlayer.height / 2
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var playerDockReservedHeight: CGFloat {
        // AI 页不再在 detail 内渲染播放条：封面球已固定在 sidebar 底部，输入栏
        // 可以与普通播放条共享窗口底部基线，不被旧的预留高度抬起。
        if navigation.selection == .assistant { return 0 }
        return MacUIVisualTokens.FloatingPlayer.height
            + MacUIVisualTokens.FloatingPlayer.topInset
            + MacUIVisualTokens.FloatingPlayer.bottomInset
    }

    @ViewBuilder
    private var playerBar: some View {
        if navigation.selection == .assistant {
            EmptyView()
        } else {
            MacFloatingPlayerBar(
                model: model,
                theme: theme,
                onOpenFullPlayer: { expandCurrentWindowPlayer() },
                onOpenMiniPlayer: switchToMiniPlayer,
                onToggleLyrics: { toggleRightPanel(.lyrics) },
                onToggleQueue: { toggleRightPanel(.queue) }
            )
        }
    }

    // MARK: - 主窗口 ↔ 迷你播放器切换

    /// 统一切换到迷你播放器：隐藏主窗口、显示 Mini，由窗口协调器管理生命周期。
    private func switchToMiniPlayer() {
        MacWindowVisibilityCoordinator.shared.requestMiniPlayer {
            openWindow(id: MacWindowID.miniPlayer)
        }
    }

    // MARK: - 播放器展开 / 收起（同窗口）

    private func expandCurrentWindowPlayer(fullscreen: Bool = false) {
        guard !playerOverlayMounted else {
            if fullscreen { enterSystemFullscreenIfNeeded() }
            return
        }
        MacUITrace.action("expandPlayer", "fullscreen=\(fullscreen) track=\(model.currentTrack.serverID):\(model.currentTrack.id.rawValue)")
        // 先挂载覆盖层并压住 library toolbar title；下一 RunLoop 再开始前景动画，
        // 保证「第 N 帧已挂载但前景在起始位置、第 N+1 帧开始动画」，动画明显且
        // 背景始终满屏（不露白条）。libraryUI 始终在底层，绝不重建。
        playerState.resetContext()
        suppressLibraryToolbar = true
        playerOverlayMounted = true
        DispatchQueue.main.async {
            withAnimation(
                reduceMotion ? .easeOut(duration: 0.14) : .spring(duration: 0.34, bounce: 0.05)
            ) {
                playerOverlayVisible = true
            }
        }
        if fullscreen {
            enterSystemFullscreenIfNeeded()
        }
    }

    private func collapseExpandedPlayer() {
        guard playerOverlayMounted else { return }
        MacUITrace.action("collapsePlayer")
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            collapseAfterLeavingFullscreen(window: window)
        } else {
            dismissOverlay()
        }
    }

    /// 关闭覆盖层：前景淡出动画完成后才卸载 Expanded、恢复 library toolbar title。
    /// 关闭动画完成之前绝不恢复 toolbar title（避免「首页」标题闪现）。
    private func dismissOverlay() {
        withAnimation(
            reduceMotion ? .easeOut(duration: 0.14) : .easeInOut(duration: 0.22)
        ) {
            playerOverlayVisible = false
        } completion: {
            Task { @MainActor in
                playerOverlayMounted = false
                suppressLibraryToolbar = false
            }
        }
    }

    /// 退出系统全屏后收播放器：监听真正的 `didExitFullScreenNotification`，
    /// 不依赖固定 0.35s 魔法延迟（Reduce Motion / 系统负载 / 多显示器都会改变动画时长）。
    private func collapseAfterLeavingFullscreen(window: NSWindow) {
        fullscreenCoordinator.observeExit(of: window) {
            self.dismissOverlay()
        }
        window.toggleFullScreen(nil)
    }

    private func enterSystemFullscreenIfNeeded() {
        guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: - 主内容（普通模式）

    @ViewBuilder
    private var detailContent: some View {
        switch navigation.selection {
        case .search:
            MacSearchView(model: model, theme: theme, onNavigate: navigate)
        case .home:
            if model.catalog.activeServerID == nil {
                MacServerEmptyState {
                    settingsRouter.selection = .server
                    openSettings()
                }
            } else {
                MacHomeView(model: model, theme: theme, onNavigate: navigate)
            }
        case .recentlyPlayed:
            MacTrackCollectionView(
                title: "最近播放", tracks: model.recentlyPlayedTracks,
                model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate,
                contentRevision: model.recentlyPlayedRevision
            )
        case .recentlyAdded:
            MacTrackCollectionView(
                title: "最近添加", tracks: model.recentlyAddedTracks,
                model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate
            )
        case .songs:
            MacSongsView(model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
        case .albums:
            MacAlbumsView(model: model, theme: theme, onNavigate: navigate)
        case .artists:
            MacArtistsView(model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
        case .genres:
            MacGenresView(model: model, theme: theme, onNavigate: navigate)
        case .favorites:
            MacTrackCollectionView(
                title: "收藏歌曲", tracks: model.favoriteTracks,
                model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate,
                contentRevision: model.favoritesRevision
            )
        case .disliked:
            MacDislikedView(model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
        case .downloads:
            MacMusicDownloadsView(model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
        case .playlists:
            MacPlaylistListView(model: model, theme: theme, onNavigate: navigate)
        case .categories:
            MacV2CategoriesView(model: model, theme: theme, onNavigate: navigate)
        case .assistant:
            AssistantView(model: model, theme: theme)
        case nil:
            ContentUnavailableView("选择一个项目", systemImage: "music.note.list",
                                   description: Text("从左侧选择资料库或工具开始"))
        }
    }

    @ViewBuilder
    private func detailRouteView(_ route: MacDetailRoute) -> some View {
        switch route {
        case let .album(id):
            if let album = resolveAlbum(id) {
                MacAlbumView(album: album, model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
            } else {
                ContentUnavailableView("专辑不可用", systemImage: "square.stack", description: Text("这张专辑不在当前资料库中。"))
            }
        case let .artist(id):
            if let artist = resolveArtist(id) {
                MacArtistView(artist: artist, model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
            } else {
                ContentUnavailableView("艺术家不可用", systemImage: "person.2", description: Text("这位艺术家不在当前资料库中。"))
            }
        case let .playlist(id):
            if let playlist = resolvePlaylist(id) {
                MacPlaylistView(playlist: playlist, model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
            } else {
                ContentUnavailableView("歌单不可用", systemImage: "music.note.list", description: Text("这个歌单不在当前资料库中。"))
            }
        case let .genre(name):
            if let genre = model.catalog.genres.first(where: { $0.name == name }) {
                MacGenreView(genre: genre, model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate)
            } else {
                ContentUnavailableView("流派不可用", systemImage: "music.quarternote.3", description: Text("这个流派不在当前资料库中。"))
            }
        case let .recommendationCategory(category):
            MacV2CategoryTracksView(category: category, model: model, theme: theme, onNavigate: navigate)
        }
    }

    private var currentTitle: String {
        if let route = navigation.path.last {
            switch route {
            case let .album(id): return resolveAlbum(id)?.title ?? "专辑"
            case let .artist(id): return resolveArtist(id)?.name ?? "艺术家"
            case let .playlist(id): return resolvePlaylist(id)?.name ?? "播放列表"
            case let .genre(name): return name
            case let .recommendationCategory(category): return category.macCategoryTitle
            }
        }
        return navigation.selection?.title ?? "Auralis"
    }

    private func resolveAlbum(_ id: MacEntityRouteID) -> Album? {
        model.catalog.albums.first { $0.serverID == id.serverID && $0.id.rawValue == id.remoteID }
    }
    private func resolveArtist(_ id: MacEntityRouteID) -> Artist? {
        model.catalog.artists.first { $0.serverID == id.serverID && $0.id.rawValue == id.remoteID }
    }
    private func resolvePlaylist(_ id: MacEntityRouteID) -> Playlist? {
        model.catalog.playlists.first { $0.serverID == id.serverID && $0.id.rawValue == id.remoteID }
    }

    private func navigate(_ target: MacNavigationTarget) {
        navigation.navigate(target)
    }

    // MARK: - 输入态

    private var isTypingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        return (responder as? NSTextField)?.isEditable == true
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func toggleRightPanel(_ mode: MacRightPanelMode) {
        if showRightPanel && rightPanelMode == mode {
            MacUITrace.action("closeRightPanel")
            showRightPanel = false
        } else {
            MacUITrace.action("openRightPanel", mode.rawValue)
            rightPanelMode = mode
            showRightPanel = true
        }
    }

    private func presentDiagnostics() {
        MacUITrace.action("openServerSettings", "fromPlaybackError")
        settingsRouter.selection = .server
        openSettings()
    }

    private func beginSongAppreciation(_ track: Track) {
        navigation.selectSidebar(.assistant)
        if model.assistantIsRunning { model.cancelAssistant() }
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue).description
        Task { @MainActor in
            _ = await model.agentCoordinator.newSession()
            model.agentCoordinator.send(
                "请调用 music_appreciate，专业鉴赏《\(track.title)》—\(track.artistName)（trackID: \(gid)），并按应用规定的鉴赏格式输出，区分已核验事实、专业听感与大众评价。",
                intent: .musicAppreciation
            )
        }
    }

    // MARK: - 修饰器拆分

    private func attachModals(_ view: some View) -> some View {
        view
            .sheet(item: $getInfoTrack) { track in
                MacTrackInfoSheet(model: model, theme: theme, track: track)
            }
            .alert("播放失败", isPresented: .init(
                get: { model.playbackError != nil },
                set: { if !$0 { model.dismissPlaybackError() } }
            )) {
                Button("好") { model.dismissPlaybackError() }
                if model.playbackError != nil {
                    Button("重试") { model.retryPlayback() }
                    Button("停止") { model.stopPlayback() }
                    Button("查看诊断", role: .none) { presentDiagnostics() }
                }
            } message: {
                Text(model.playbackError?.localizedDescription ?? "未知错误")
            }
            .alert("新建播放列表", isPresented: $isCreatingPlaylist) {
                TextField("播放列表名称", text: $newPlaylistName)
                Button("创建") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newPlaylistName = ""
                    guard !name.isEmpty else { return }
                    Task { _ = await model.createPlaylist(named: name) }
                }
                Button("取消", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("创建一个新的播放列表。")
            }
    }

    private func attachLifecycle(_ view: some View) -> some View {
        view
            .task { await model.restorePersistedLibrary() }
            .onOpenURL { model.handleIncomingURL($0) }
            .onContinueUserActivity("INPlayMediaIntent") { model.handleSiriUserActivity($0) }
            .onChange(of: navigation.selection) { _, _ in
                // path 的唯一 writer 是 MacNavigationModel.selectSidebar()，
                // 这里只清选中行，不再重复 removeAll（避免同帧多次导航写入）。
                selectedTracks = []
            }
            .onChange(of: selectedTracks) { _, newValue in
                if !newValue.isEmpty { showRightPanel = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.search)) { _ in
                guard !isTypingText else { return }
                navigation.selectSidebar(.search)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.revealNowPlaying)) { _ in
                guard !isTypingText else { return }
                expandCurrentWindowPlayer()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleSidebar)) { _ in
                guard !isTypingText else { return }
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleLyrics)) { _ in
                guard !isTypingText else { return }
                toggleRightPanel(.lyrics)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleQueue)) { _ in
                guard !isTypingText else { return }
                toggleRightPanel(.queue)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleInspector)) { _ in
                guard !isTypingText else { return }
                showRightPanel.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.previous)) { _ in
                guard !isTypingText else { return }
                model.previous()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.next)) { _ in
                guard !isTypingText else { return }
                model.next()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.togglePlay)) { _ in
                guard !isTypingText else { return }
                model.togglePlayback()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleShuffle)) { _ in
                guard !isTypingText else { return }
                model.setShuffle(!model.isShuffled)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.cycleRepeat)) { _ in
                guard !isTypingText else { return }
                model.cycleRepeatMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.songAppreciation)) { note in
                guard !isTypingText else { return }
                guard let track = note.object as? Track else { return }
                beginSongAppreciation(track)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.showTrackInformation)) { note in
                guard !isTypingText else { return }
                guard let track = note.object as? Track else { return }
                getInfoTrack = track
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.showFullScreenPlayer)) { _ in
                guard !isTypingText else { return }
                expandCurrentWindowPlayer(fullscreen: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.showMiniPlayer)) { _ in
                guard !isTypingText else { return }
                // 走统一切换入口，与点击播放页 Mini 按钮同一套 Main ↔ Mini 生命周期。
                switchToMiniPlayer()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.newPlaylist)) { _ in
                guard !isTypingText else { return }
                newPlaylistName = ""
                isCreatingPlaylist = true
            }
            // Space / Return / ← / → / Esc：输入框内放行。
            .onKeyPress(.space) {
                if isTypingText { return .ignored }
                model.togglePlayback()
                return .handled
            }
            .onKeyPress(.return) {
                if isTypingText { return .ignored }
                if let gid = selectedTracks.first, let track = model.track(for: gid) {
                    model.selectAndPlay(track)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.leftArrow) {
                if isTypingText { return .ignored }
                if model.hasCurrentTrack {
                    model.previous()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.rightArrow) {
                if isTypingText { return .ignored }
                if model.hasCurrentTrack {
                    model.next()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.escape) {
                if isTypingText { return .ignored }
                if playerOverlayMounted {
                    collapseExpandedPlayer()
                    return .handled
                }
                return .ignored
            }
    }
}

/// App 窗口 ID：主窗口为唯一 Window，MiniPlayer 为独立窗口。
public enum MacWindowID {
    /// 唯一主窗口。Auralis 是「主界面 ↔ MiniPlayer」单主窗口模型，
    /// 不用 WindowGroup（避免出现多个主窗口与单例 coordinator 矛盾）。
    public static let main = "auralis-main"
    public static let miniPlayer = "auralis.miniplayer"
}

/// 首页空态（未连接服务器）：原生提示 + 打开服务器设置。
struct MacServerEmptyState: View {
    let onOpenSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("尚未连接音乐服务器", systemImage: "server.rack")
        } description: {
            Text("连接 Navidrome 或其他 OpenSubsonic 服务器后，你的音乐资料库会显示在这里。")
        } actions: {
            Button("打开服务器设置", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}
#endif
