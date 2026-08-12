#if os(macOS)
import AppKit
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 主窗口 Shell：系统 Sidebar + 主内容 NavigationStack + 右侧 Lyrics/Queue 面板
/// + 底部播放条。搜索使用系统 `.searchable`；外观跟随系统（不强制 Theme color scheme）。
public struct MacMusicShell: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore

    @StateObject private var navigation = MacNavigationModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedTracks: Set<GlobalID> = []
    @State private var rightPanelMode: MacRightPanelMode = .queue
    @State private var showRightPanel = false
    @State private var getInfoTrack: Track?

    @Environment(\.openWindow) private var openWindow

    private var theme: BuiltInTheme { themeStore.current }

    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        self.model = model
        self.themeStore = themeStore
    }

    public var body: some View {
        attachLifecycle(attachModals(content))
    }

    // MARK: - 主内容

    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(model: model, selection: $navigation.selection) { playlist in
                navigation.push(.playlist(MacEntityRouteID(serverID: playlist.serverID, remoteID: playlist.id.rawValue)))
            }
        } detail: {
            NavigationStack(path: $navigation.path) {
                detailContent
                    .navigationDestination(for: MacDetailRoute.self) { route in
                        detailRouteView(route)
                    }
            }
            .navigationTitle(currentTitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        toggleRightPanel(.lyrics)
                    } label: {
                        Image(systemName: "quote.bubble")
                    }
                    .help("歌词")
                    .accessibilityLabel("歌词")
                    Button {
                        toggleRightPanel(.queue)
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help("队列")
                    .accessibilityLabel("队列")
                }
            }
            .inspector(isPresented: $showRightPanel) {
                MacRightPanel(model: model, theme: theme, mode: rightPanelMode)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacPlayerBar(
                model: model,
                theme: theme,
                onOpenNowPlaying: { post(MacCommand.revealNowPlaying) },
                onToggleLyrics: { toggleRightPanel(.lyrics) },
                onToggleQueue: { toggleRightPanel(.queue) }
            )
        }
        .searchable(
            text: $navigation.searchQuery,
            isPresented: $navigation.isSearchPresented,
            placement: .toolbar,
            prompt: "搜索歌曲、专辑、艺术家和歌单"
        )
        .onSubmit(of: .search) {
            let trimmed = navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                model.recordSearch(trimmed)
            }
        }
        .environment(model.artworkStore)
        .environmentObject(themeStore)
    }

    // MARK: - 内容路由

    @ViewBuilder
    private var detailContent: some View {
        if navigation.isSearching {
            MacSearchView(
                model: model,
                theme: theme,
                query: navigation.searchQuery,
                onNavigate: navigate,
                onSelectRecent: { term in
                    navigation.selectRecentSearch(term)
                }
            )
        } else {
            sidebarContent(navigation.selection)
        }
    }

    @ViewBuilder
    private func sidebarContent(_ selection: MacSidebarDestination?) -> some View {
        switch selection {
        case .home:
            MacHomeView(model: model, theme: theme, onNavigate: navigate)
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
            MacArtistsView(model: model, theme: theme, onNavigate: navigate)
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
        case .server:
            MacServerPage(model: model, theme: theme)
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
        case .nowPlaying:
            MacNowPlayingView(model: model, theme: theme)
        }
    }

    private var currentTitle: String {
        if let route = navigation.path.last {
            switch route {
            case .nowPlaying: return "正在播放"
            case let .album(id): return resolveAlbum(id)?.title ?? "专辑"
            case let .artist(id): return resolveArtist(id)?.name ?? "艺术家"
            case let .playlist(id): return resolvePlaylist(id)?.name ?? "播放列表"
            case let .genre(name): return name
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
            showRightPanel = false
        } else {
            rightPanelMode = mode
            showRightPanel = true
        }
    }

    private func presentDiagnostics() {
        navigation.selectSidebar(.server)
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

    // MARK: - 修饰器拆分（降低类型检查复杂度）

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
                if let error = model.playbackError {
                    Button("重试") { model.retryPlayback() }
                    Button("停止") { model.stopPlayback() }
                    Button("查看诊断", role: .none) { presentDiagnostics() }
                }
            } message: {
                Text(model.playbackError.map { "\($0)" } ?? "未知错误")
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
                // 用户点击 Sidebar 一级项：退出搜索，恢复普通内容。
                if navigation.isSearching {
                    navigation.isSearchPresented = false
                    navigation.searchQuery = ""
                }
            }
            .onChange(of: selectedTracks) { _, newValue in
                if !newValue.isEmpty { showRightPanel = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.search)) { _ in
                navigation.isSearchPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.revealNowPlaying)) { _ in
                navigation.push(.nowPlaying)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleSidebar)) { _ in
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleLyrics)) { _ in
                toggleRightPanel(.lyrics)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleQueue)) { _ in
                toggleRightPanel(.queue)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleInspector)) { _ in
                showRightPanel.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.previous)) { _ in
                model.previous()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.next)) { _ in
                model.next()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.togglePlay)) { _ in
                model.togglePlayback()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.toggleShuffle)) { _ in
                model.setShuffle(!model.isShuffled)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.cycleRepeat)) { _ in
                model.cycleRepeatMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.songAppreciation)) { note in
                guard let track = note.object as? Track else { return }
                beginSongAppreciation(track)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.showTrackInformation)) { note in
                guard let track = note.object as? Track else { return }
                getInfoTrack = track
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.showFullScreenPlayer)) { _ in
                openWindow(id: MacWindowID.fullScreenPlayer)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.showMiniPlayer)) { _ in
                openWindow(id: MacWindowID.miniPlayer)
            }
            .onChange(of: navigation.isSearchPresented) { _, presented in
                if presented {
                    navigation.searchReturnDestination = navigation.selection
                }
            }
            // Space / Return / ← / →：输入框内放行；其余状态播放控制。
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
    }
}

/// 独立窗口 ID（MiniPlayer / Full Screen Player）。
public enum MacWindowID {
    public static let miniPlayer = "auralis.miniplayer"
    public static let fullScreenPlayer = "auralis.fullscreenplayer"
}
#endif
