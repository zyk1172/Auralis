#if os(macOS)
import AppKit
import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 键盘命令广播名称（App 菜单命令 → 主窗口）。
public enum MacCommandNotification {
    public static let search = Notification.Name("auralis.mac.command.search")
    public static let revealNowPlaying = Notification.Name("auralis.mac.command.revealNowPlaying")
    public static let toggleSidebar = Notification.Name("auralis.mac.command.toggleSidebar")
    public static let toggleInspector = Notification.Name("auralis.mac.command.toggleInspector")
    public static let previous = Notification.Name("auralis.mac.command.previous")
    public static let next = Notification.Name("auralis.mac.command.next")
    public static let togglePlay = Notification.Name("auralis.mac.command.togglePlay")
    /// object = Track：对指定歌曲发起歌曲鉴赏（切换到 AI 助手并调用 music_appreciate）。
    public static let songAppreciation = Notification.Name("auralis.mac.command.songAppreciation")
    /// object = Track：在检查器中打开该歌曲的“详情”页。
    public static let showTrackInformation = Notification.Name("auralis.mac.command.showTrackInformation")
}

enum MacLibraryScope: String, CaseIterable, Hashable, Identifiable {
    case songs, albums, artists, genres
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: "歌曲"
        case .albums: "专辑"
        case .artists: "艺术家"
        case .genres: "流派"
        }
    }
    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "person.2"
        case .genres: "music.quarternote.3"
        }
    }
}

/// macOS 侧边栏导航项（独立于 iOS 的 AppSection）。
enum MacNavItem: Hashable, Identifiable {
    case home
    case recentlyPlayed
    case recentlyAdded
    case library(MacLibraryScope)
    case favorites
    case disliked
    case playlists
    case categories
    case search
    case assistant
    case downloads
    case server

    var id: String { stableID }
    var stableID: String {
        switch self {
        case .home: "home"
        case .recentlyPlayed: "recentlyPlayed"
        case .recentlyAdded: "recentlyAdded"
        case let .library(scope): "library.\(scope.rawValue)"
        case .favorites: "favorites"
        case .disliked: "disliked"
        case .playlists: "playlists"
        case .categories: "categories"
        case .search: "search"
        case .assistant: "assistant"
        case .downloads: "downloads"
        case .server: "server"
        }
    }

    var title: String {
        switch self {
        case .home: "首页"
        case .recentlyPlayed: "最近播放"
        case .recentlyAdded: "最近添加"
        case let .library(scope): scope.title
        case .favorites: "收藏歌曲"
        case .disliked: "不喜欢"
        case .playlists: "我的歌单"
        case .categories: "分类"
        case .search: "搜索"
        case .assistant: "AI 助手"
        case .downloads: "下载"
        case .server: "服务器"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recentlyPlayed: "clock"
        case .recentlyAdded: "tray.and.arrow.down"
        case let .library(scope): scope.symbol
        case .favorites: "heart"
        case .disliked: "heart.slash"
        case .playlists: "music.note.list"
        case .categories: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .assistant: "sparkles"
        case .downloads: "arrow.down.circle"
        case .server: "server.rack"
        }
    }
}

/// 主内容区正常导航路由：专辑 / 艺术家 / 流派 / 歌单 / 正在播放。
/// 由主内容 NavigationStack 承接，不再用通用 Sheet。
enum MacContentRoute: Hashable {
    case album(Album)
    case artist(Artist)
    case genre(Genre)
    case playlist(Playlist)
    case nowPlaying
}

/// macOS 主窗口：系统 Sidebar + 主内容 NavigationStack + 真正 SwiftUI Inspector，
/// 以及固定在底部的桌面播放控制条。
struct MacAuralisRootView: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @State private var selection: MacNavItem? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    @State private var inspectorTab: MacInspector.InspectorTab = .queue
    @State private var selectedTracks: Set<GlobalID> = []
    @State private var sidebarSearch = ""
    @State private var isSidebarSearchPresented = false
    @State private var path: [MacContentRoute] = []

    private var theme: BuiltInTheme { themeStore.current }

    /// 当前是否有文本输入框正在编辑（NSTextField 的 field editor 是 NSTextView）。
    /// Space 在输入时必须是空格，不能触发播放/暂停。
    private var isTypingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        return (responder as? NSTextField)?.isEditable == true
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } detail: {
            NavigationStack(path: $path) {
                content
                    .navigationDestination(for: MacContentRoute.self) { route in
                        routeView(route)
                    }
            }
            .navigationTitle(selection?.title ?? "澜音")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("检查器", systemImage: "sidebar.right")
                    }
                    .help("显示或隐藏检查器（Command-Option-I）")
                }
            }
            .inspector(isPresented: $showInspector) {
                MacInspector(
                    model: model,
                    theme: theme,
                    initialTab: inspectorTab,
                    onTabChange: { inspectorTab = $0 },
                    selectedTracks: selectedTracks
                )
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        }
        // 桌面播放器固定在窗口底部，提供持久 transport；主内容页不再复制大号控制。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacDesktopPlayerBar(model: model, theme: theme)
        }
        // 只保留真正临时的系统弹窗：首次服务器配置。
        .sheet(isPresented: $model.shouldPresentServerSetup) {
            ServerConnectionSheet(model: model, theme: theme)
                .frame(minWidth: 560, minHeight: 500)
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil { model.browseDestination = nil }
            if newValue == .search {
                sidebarSearch = model.macSearchQuery
                isSidebarSearchPresented = true
            }
        }
        .onChange(of: model.browseDestination) { _, destination in
            guard let destination else { return }
            let route: MacContentRoute? = switch destination {
            case let .album(album): .album(album)
            case let .artist(artist): .artist(artist)
            case let .genre(genre): .genre(genre)
            case let .playlist(playlist): .playlist(playlist)
            default: nil
            }
            if let route {
                path.append(route)
                model.browseDestination = nil
            }
        }
        .onChange(of: selectedTracks) { _, newValue in
            if !newValue.isEmpty { showInspector = true }
        }
        .onChange(of: sidebarSearch) { _, newValue in
            model.macSearchQuery = newValue
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selection = .search
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.search)) { _ in
            selection = .search
            isSidebarSearchPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.revealNowPlaying)) { _ in
            path.append(.nowPlaying)
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.toggleInspector)) { _ in
            showInspector.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.toggleSidebar)) { _ in
            withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.previous)) { _ in
            model.previous()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.next)) { _ in
            model.next()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.togglePlay)) { _ in
            model.togglePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.songAppreciation)) { note in
            guard let track = note.object as? Track else { return }
            beginSongAppreciation(track)
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.showTrackInformation)) { note in
            guard let track = note.object as? Track else { return }
            let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
            selectedTracks = [gid]
            inspectorTab = .details
            showInspector = true
        }
        // Space 播放/暂停唯一入口：根视图 .onKeyPress(.space)。
        // 菜单不再注册裸 Space 快捷键；输入框内由 isTypingText 放行，空格正常输入。
        .onKeyPress(.space) {
            if isTypingText { return .ignored }
            model.togglePlayback()
            return .handled
        }
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

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: $selection) {
            Section("浏览") {
                sidebarItem(.home)
                sidebarItem(.recentlyPlayed)
                sidebarItem(.recentlyAdded)
            }
            Section("资料库") {
                ForEach(MacLibraryScope.allCases) { scope in
                    sidebarItem(.library(scope))
                }
                sidebarItem(.favorites)
                sidebarItem(.disliked)
                sidebarItem(.playlists)
                sidebarItem(.categories)
            }
            Section("实用工具") {
                sidebarItem(.downloads)
                sidebarItem(.assistant)
                sidebarItem(.server)
            }
        }
        .listStyle(.sidebar)
        .searchable(
            text: $sidebarSearch,
            isPresented: $isSidebarSearchPresented,
            placement: .sidebar,
            prompt: "搜索"
        )
        .onSubmit(of: .text) {
            selection = .search
        }
    }

    @ViewBuilder
    private func sidebarItem(_ item: MacNavItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
    }

    // MARK: - 内容路由

    @ViewBuilder
    private func routeView(_ route: MacContentRoute) -> some View {
        switch route {
        case let .album(album):
            MacAlbumDetailPage(album: album, model: model, theme: theme) {
                if !path.isEmpty { path.removeLast() }
            }
        case let .artist(artist):
            MacArtistDetailPage(artist: artist, model: model, theme: theme, selection: $selectedTracks)
        case let .genre(genre):
            MacGenreDetailPage(genre: genre, model: model, theme: theme, selection: $selectedTracks)
        case let .playlist(playlist):
            MacPlaylistDetailPage(playlist: playlist, model: model, theme: theme, selection: $selectedTracks)
        case .nowPlaying:
            MacNowPlayingPage(model: model, theme: theme)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            MacHomePage(model: model, theme: theme, selection: $selectedTracks) {
                selection = .server
            }
        case .recentlyPlayed:
            MacTrackListPage(title: "最近播放", tracks: model.recentlyPlayedTracks,
                             selection: $selectedTracks, model: model, theme: theme)
        case .recentlyAdded:
            MacTrackListPage(title: "最近添加", tracks: Array(model.recentlyAddedTracks.prefix(300)),
                             selection: $selectedTracks, model: model, theme: theme)
        case let .library(scope):
            MacLibraryPage(scope: scope, model: model, theme: theme, selection: $selectedTracks)
        case .favorites:
            MacTrackListPage(title: "收藏歌曲", tracks: model.favoriteTracks,
                             selection: $selectedTracks, model: model, theme: theme)
        case .disliked:
            MacDislikedPage(model: model, theme: theme, selection: $selectedTracks)
        case .playlists:
            MacPlaylistPage(model: model, theme: theme)
        case .categories:
            MacV2CategoriesPage(model: model, theme: theme, selection: $selectedTracks)
        case .search:
            MacSearchPage(model: model, theme: theme, query: sidebarSearch, selection: $selectedTracks)
        case .assistant:
            AssistantView(model: model, theme: theme)
        case .downloads:
            MacDownloadsPage(model: model, theme: theme)
        case .server:
            MacServerPage(model: model, theme: theme)
        case nil:
            ContentUnavailableView("选择一个项目", systemImage: "music.note.list",
                                   description: Text("从左侧选择资料库或工具开始"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 固定在窗口底部的桌面播放条。
/// 播放信息、进度与核心控制拥有稳定的水平空间；Previous/Next 使用统一 capability。
private struct MacDesktopPlayerBar: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject private var playbackStore: PlaybackStore
    let theme: BuiltInTheme

    init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self.theme = theme
    }

    private var hasTrack: Bool { model.currentTrack.id.rawValue != "placeholder" }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }
    private var currentGID: GlobalID? {
        hasTrack ? GlobalID(serverID: model.currentTrack.serverID, remoteID: model.currentTrack.id.rawValue) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { playbackStore.position },
                    set: { model.seek(toProgress: $0 / duration) }
                ),
                in: 0...duration
            )
            .controlSize(.mini)
            .tint(theme.colorTokens.accent.color)
            .disabled(!hasTrack)
            .padding(.horizontal, 14)
            .padding(.top, 5)

            HStack(spacing: AuralisSpacing.medium) {
                Button {
                    if hasTrack { pathlessOpenNowPlaying() }
                } label: {
                    HStack(spacing: 10) {
                        ArtworkView(
                            title: model.currentTrack.albumTitle,
                            artworkKey: model.currentTrack.artworkKey,
                            colors: theme.colorTokens,
                            size: 44,
                            cornerRadius: 8
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hasTrack ? model.currentTrack.title : "尚未选择歌曲")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(hasTrack ? model.currentTrack.artistName : "从资料库开始播放")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        .frame(maxWidth: 200, alignment: .leading)
                        // 当前歌曲的私人状态：不喜欢 / 收藏（不进入 transport 三键）。
                        if currentGID != nil {
                            HStack(spacing: 8) {
                                Button {
                                    model.toggleDisliked(model.currentTrack)
                                } label: {
                                    Image(systemName: model.isDisliked(model.currentTrack) ? "heart.slash.fill" : "heart.slash")
                                        .foregroundStyle(model.isDisliked(model.currentTrack) ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                                }
                                .buttonStyle(.plain)
                                .help(model.isDisliked(model.currentTrack) ? "取消不喜欢" : "不喜欢")
                                .accessibilityLabel(model.isDisliked(model.currentTrack) ? "取消不喜欢" : "不喜欢")

                                Button {
                                    model.toggleFavorite(model.currentTrack)
                                } label: {
                                    Image(systemName: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                                        .foregroundStyle(model.currentTrack.isFavorite ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
                                }
                                .buttonStyle(.plain)
                                .help(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
                                .accessibilityLabel(model.currentTrack.isFavorite ? "取消收藏" : "收藏")
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!hasTrack)
                .help("打开正在播放")

                Spacer(minLength: 20)

                HStack(spacing: 12) {
                    Button { if hasTrack { model.previous() } } label: {
                        Image(systemName: "backward.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canGoPrevious)
                    .help("上一首（Command-Left）")

                    Button { if hasTrack { model.togglePlayback() } } label: {
                        Image(systemName: model.playbackState == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(theme.colorTokens.accent.color, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasTrack)
                    .help("播放 / 暂停（Space）")

                    Button { if hasTrack { model.next() } } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canGoNext)
                    .help("下一首（Command-Right）")
                }

                Spacer(minLength: 20)

                HStack(spacing: 14) {
                    MacVolumeControl(model: model, theme: theme)
                    HStack(spacing: 8) {
                        Text(Self.timeText(playbackStore.position))
                        Text("/")
                            .foregroundStyle(theme.colorTokens.secondaryText.color.opacity(0.6))
                        Text(Self.timeText(model.currentTrack.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .frame(minWidth: 92, alignment: .trailing)
                }
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, 8)
        }
        .frame(height: 82)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.colorTokens.separator.color.opacity(0.45))
                .frame(height: 0.5)
        }
    }

    /// 打开正在播放页：通过浏览入口（revealNowPlaying 命令同路径）。
    private func pathlessOpenNowPlaying() {
        NotificationCenter.default.post(name: MacCommandNotification.revealNowPlaying, object: nil)
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 工具栏音量控制。
private struct MacVolumeControl: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.volume < 0.02 ? "speaker.slash" : "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Slider(value: Binding(
                get: { model.volume },
                set: { model.setVolume($0) }
            ), in: 0...1)
            .frame(width: 72)
            .controlSize(.mini)
        }
        .help("音量")
    }
}
#endif
