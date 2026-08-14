#if os(macOS)
import AppKit
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 主窗口 Shell（Round-4）：
/// 普通资料库 UI + 同一窗口内的 Expanded Player 覆盖（不新建 Full Player 窗口）。
/// 展开/收起只改 presentation state，不改 navigation selection / path / scroll / search。
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
    }

    private var contents: some View {
        ZStack {
            // 展开页不保留资料库 View 本身，避免其 NavigationSplitView 自动生成的
            // Hide Sidebar、页面标题和“编辑首页”等 toolbar item 泄漏进 titlebar。
            // navigation / sidebar 偏好均由 MacMusicShell 的 StateObject 持有，收起时
            // 会恢复原 selection/path，而不是重建导航状态。
            if !playerState.isExpanded {
                libraryUI
            }

            if playerState.isExpanded {
                MacExpandedPlayerView(
                    model: model,
                    theme: theme,
                    context: $playerState.context,
                    onCollapse: collapseExpandedPlayer,
                    onOpenMiniPlayer: { openWindow(id: MacWindowID.miniPlayer) }
                )
                .zIndex(100)
                // 展开页内部负责统一的封面/背景/控制层进入动画；外层只做淡出，
                // 避免 ArtworkView 与页面容器各自执行不同的 move transition。
                .transition(.opacity)
            }
        }
        // 展开页不能隐藏整个 window toolbar：那会连同 macOS 的红/黄/绿
        // traffic lights 一起移除。保留透明 titlebar，资料库的内容由展开层覆盖。
        .toolbarVisibility(.automatic, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 用户选择主题后，主窗口、AI 助手与每个资料库目的地共享同一套色彩和控件强调色。
        .tint(theme.colorTokens.accent.color)
        .preferredColorScheme(theme.colorScheme)
        // 环境注入放到 ZStack 层：libraryUI 与同窗口 Expanded Player 都能继承
        // ArtworkStore / ThemeStore（否则 Expanded 内的 ArtworkView 强解包崩溃）。
        .environment(model.artworkStore)
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
        } detail: {
            // 不能把播放条挂在页面内容的 safeAreaInset 上：空态 VStack 会给它一个
            // 非窗口高度，导致下载/不喜欢等页面的播放条上跳。这里由 detail 的
            // GeometryReader 提供稳定窗口坐标，内容仅预留播放器所占底部空间。
            GeometryReader { _ in
                ZStack(alignment: .bottom) {
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

                    playerBar
                        .padding(.horizontal, MacUIVisualTokens.FloatingPlayer.horizontalInset)
                        .padding(.bottom, MacUIVisualTokens.FloatingPlayer.bottomInset)
                        .padding(.top, MacUIVisualTokens.FloatingPlayer.topInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                onOpenMiniPlayer: { openWindow(id: MacWindowID.miniPlayer) },
                onToggleLyrics: { toggleRightPanel(.lyrics) },
                onToggleQueue: { toggleRightPanel(.queue) }
            )
        }
    }

    // MARK: - 播放器展开 / 收起（同窗口）

    private func expandCurrentWindowPlayer(fullscreen: Bool = false) {
        guard !playerState.isExpanded else {
            if fullscreen { enterSystemFullscreenIfNeeded() }
            return
        }
        MacUITrace.action("expandPlayer", "fullscreen=\(fullscreen) track=\(model.currentTrack.serverID):\(model.currentTrack.id.rawValue)")
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.0)) {
            playerState.expand()
        }
        if fullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                enterSystemFullscreenIfNeeded()
            }
        }
    }

    private func collapseExpandedPlayer() {
        guard playerState.isExpanded else { return }
        MacUITrace.action("collapsePlayer")
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.0)) {
                    playerState.collapse()
                }
                DispatchQueue.main.async { restoreTrafficLights() }
            }
        } else {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.0)) {
                playerState.collapse()
            }
            DispatchQueue.main.async { restoreTrafficLights() }
        }
    }

    private func enterSystemFullscreenIfNeeded() {
        guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func restoreTrafficLights() {
        guard let window = NSApp.keyWindow else { return }
        // 离开展开页后恢复原生 traffic lights 与普通资料库 titlebar。
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
            window.standardWindowButton(button)?.isHidden = false
        }
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
                model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate
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
                model: model, theme: theme, selection: $selectedTracks, onNavigate: navigate
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
        return navigation.selection?.title ?? "澜音"
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
                selectedTracks = []
                navigation.path.removeAll()
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
                openWindow(id: MacWindowID.miniPlayer)
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
                if playerState.isExpanded {
                    collapseExpandedPlayer()
                    return .handled
                }
                return .ignored
            }
    }
}

/// 独立窗口 ID（仅 MiniPlayer）。
public enum MacWindowID {
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
