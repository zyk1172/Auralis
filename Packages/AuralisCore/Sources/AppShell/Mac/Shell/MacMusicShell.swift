#if os(macOS)
import AppKit
import LocalCatalog
import SwiftUI
import ThemeEngine
import Domain

/// Apple Music 式 macOS 主窗口 Shell：
/// 系统 Sidebar + 主内容 NavigationStack + 右侧歌词/队列面板 + 底部 Apple Music 式播放条。
/// 不隐藏系统窗口 chrome，不伪造 Toolbar，内容层不使用主题色大面积涂底。
public struct MacMusicShell: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore

    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        self.model = model
        self.themeStore = themeStore
    }

    @State private var selection: MacRoute? = .home
    @State private var path: [MacRoute] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedTracks: Set<GlobalID> = []
    @State private var rightPanelMode: MacRightPanelMode = .queue
    @State private var showRightPanel = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var getInfoTrack: Track?

    private var theme: BuiltInTheme { themeStore.current }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearchFocused
    }

    public var body: some View {
        attachLifecycle(attachModals(content))
    }

    /// sheet + 播放失败 alert（单独表达式，降低类型检查复杂度）。
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

    /// 生命周期 + 命令通知 + Space 键（单独表达式）。
    private func attachLifecycle(_ view: some View) -> some View {
        view
            .task { await model.restorePersistedLibrary() }
            .onOpenURL { model.handleIncomingURL($0) }
            .onContinueUserActivity("INPlayMediaIntent") { model.handleSiriUserActivity($0) }
            .onChange(of: selection) { _, _ in
                selectedTracks = []
                path = []
            }
            .onChange(of: selectedTracks) { _, newValue in
                if !newValue.isEmpty { showRightPanel = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.search)) { _ in
                isSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: MacCommand.revealNowPlaying)) { _ in
                if !path.contains(.nowPlaying) {
                    path.append(.nowPlaying)
                }
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
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            // Space 播放/暂停唯一入口；输入框内放行。
            .onKeyPress(.space) {
                if isTypingText { return .ignored }
                model.togglePlayback()
                return .handled
            }
    }

    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(model: model, selection: $selection)
        } detail: {
            NavigationStack(path: $path) {
                detailContent
                    .navigationDestination(for: MacRoute.self) { route in
                        routeView(route)
                    }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    searchField
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
                MacRightPanel(model: model, theme: theme, mode: $rightPanelMode)
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
        .environment(model.artworkStore)
        .environmentObject(themeStore)
        .tint(theme.colorTokens.accent.color)
        .preferredColorScheme(themeStore.current.colorScheme)
    }

    // MARK: - 输入态判断

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
        // 播放失败诊断：跳转服务器页（连接诊断入口）。
        selection = .server
    }

    // MARK: - 内容

    @ViewBuilder
    private var detailContent: some View {
        if isSearching {
            MacSearchView(model: model, theme: theme, query: searchText, onNavigate: push)
        } else {
            switch selection {
            case .home:
                MacHomeView(model: model, theme: theme, onNavigate: push)
            case .recentlyPlayed:
                MacTrackCollectionView(
                    title: "最近播放",
                    tracks: model.recentlyPlayedTracks,
                    model: model, theme: theme,
                    selection: $selectedTracks, onNavigate: push
                )
            case .recentlyAdded:
                MacTrackCollectionView(
                    title: "最近添加",
                    tracks: model.recentlyAddedTracks,
                    model: model, theme: theme,
                    selection: $selectedTracks, onNavigate: push
                )
            case .songs:
                MacSongsView(model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case .albums:
                MacAlbumsView(model: model, theme: theme, onNavigate: push)
            case .artists:
                MacArtistsView(model: model, theme: theme, onNavigate: push)
            case .genres:
                MacGenresView(model: model, theme: theme, onNavigate: push)
            case .favorites:
                MacTrackCollectionView(
                    title: "收藏歌曲",
                    tracks: model.favoriteTracks,
                    model: model, theme: theme,
                    selection: $selectedTracks, onNavigate: push
                )
            case .disliked:
                MacDislikedView(model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case .downloads:
                MacMusicDownloadsView(model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case .playlists:
                MacPlaylistListView(model: model, theme: theme, onNavigate: push)
            case .categories:
                MacV2CategoriesView(model: model, theme: theme, onNavigate: push)
            case .assistant:
                AssistantView(model: model, theme: theme)
            case .server:
                MacServerPage(model: model, theme: theme)
            case let .playlist(playlist):
                MacPlaylistView(playlist: playlist, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case let .album(album):
                MacAlbumView(album: album, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case let .artist(artist):
                MacArtistView(artist: artist, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case let .genre(genre):
                MacGenreView(genre: genre, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
            case .nowPlaying:
                MacNowPlayingView(model: model, theme: theme)
            case nil:
                ContentUnavailableView("选择一个项目", systemImage: "music.note.list",
                                       description: Text("从左侧选择资料库或工具开始"))
            }
        }
    }

    @ViewBuilder
    private func routeView(_ route: MacRoute) -> some View {
        switch route {
        case let .album(album):
            MacAlbumView(album: album, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
        case let .artist(artist):
            MacArtistView(artist: artist, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
        case let .genre(genre):
            MacGenreView(genre: genre, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
        case let .playlist(playlist):
            MacPlaylistView(playlist: playlist, model: model, theme: theme, selection: $selectedTracks, onNavigate: push)
        case .nowPlaying:
            MacNowPlayingView(model: model, theme: theme)
        default:
            detailContent
        }
    }

    private func push(_ route: MacRoute) {
        path.append(route)
    }

    /// 对指定歌曲发起歌曲鉴赏：切换到 AI 助手并调用 music_appreciate。
    private func beginSongAppreciation(_ track: Track) {
        selection = .assistant
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

    // MARK: - Toolbar 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索歌曲、专辑、艺术家和歌单", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .frame(width: 220)
                .accessibilityLabel("搜索")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif
