#if os(macOS)
import DesignSystem
import Domain
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
}

/// macOS 侧边栏导航项（独立于 iOS 的 AppSection）。
enum MacNavItem: Hashable, Identifiable {
    case home
    case recentlyPlayed
    case recentlyAdded
    case library(MacLibraryScope)
    case favorites
    case playlists
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
        case .playlists: "playlists"
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
        case .playlists: "我的歌单"
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
        case .playlists: "music.note.list"
        case .search: "magnifyingglass"
        case .assistant: "sparkles"
        case .downloads: "arrow.down.circle"
        case .server: "server.rack"
        }
    }
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

/// macOS 主窗口：资料库侧边栏、主内容、按需检查器，以及固定在底部的桌面播放控制条。
/// 设置通过独立设置窗口打开；检查器只通过工具栏按钮或选中/播放上下文显示。
struct MacAuralisRootView: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @State private var selection: MacNavItem? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    @State private var inspectorTab: MacInspector.InspectorTab = .queue
    @State private var selectedTracks: Set<TrackID> = []
    @State private var sidebarSearch = ""
    @State private var isSidebarSearchPresented = false

    private var theme: BuiltInTheme { themeStore.current }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } content: {
            ZStack(alignment: .topTrailing) {
                content
                    .padding(.top, isShowingAlbumDetail ? 0 : 42)
                if !isShowingAlbumDetail {
                    contentActionBar
                }
            }
                .navigationTitle(selection?.title ?? "澜音")
                .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        } detail: {
            if showInspector {
                MacInspector(model: model, theme: theme, initialTab: inspectorTab, onTabChange: { inspectorTab = $0 })
                    .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 380)
            }
        }
        // 这个 macOS Beta 会强制为 NavigationSplitView 注入一枚纵向 sidebarToggle，
        // 即使使用 `.toolbar(removing:)` 也无法移除。隐藏系统窗口工具栏，改由内容区
        // 自己的无边框操作条承接控制，避免出现不对称的标题栏胶囊按钮。
        .toolbarVisibility(.hidden, for: .windowToolbar)
        // 桌面播放器固定在窗口底部，避免把歌曲信息、进度与播放键挤进狭窄的标题栏。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacDesktopPlayerBar(model: model, theme: theme)
        }
        // Mac 端此前缺少这些 presentation，状态会被写入却没有界面承接。
        .sheet(isPresented: $model.isNowPlayingPresented) {
            NowPlayingView(model: model, theme: theme)
                .frame(minWidth: 640, minHeight: 680)
        }
        .sheet(isPresented: $model.shouldPresentServerSetup) {
            ServerConnectionSheet(model: model, theme: theme)
                .frame(minWidth: 560, minHeight: 500)
        }
        .sheet(item: browseDestinationSheetBinding) { destination in
            BrowseDetailSheet(destination: destination, model: model, theme: theme)
                .frame(minWidth: 640, minHeight: 560)
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil { model.browseDestination = nil }
            if newValue == .server { showInspector = false }
            if newValue == .search { sidebarSearch = model.macSearchQuery }
        }
        .onChange(of: selectedTracks) { _, newValue in
            if !newValue.isEmpty { showInspector = true }
        }
        .onChange(of: model.currentTrack.id) { _, _ in
            if model.currentTrack.id.rawValue != "placeholder" { showInspector = true }
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
            model.isNowPlayingPresented = true
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
        // 空格播放/暂停：仅在未编辑文本时响应（TextField 聚焦时不会到达这里）。
        .onKeyPress(.space) {
            model.togglePlayback()
            return .handled
        }
    }

    /// 专辑在 Mac 主内容区内导航，保留与 Apple Music 相同的「网格 → 专辑详情」层级；
    /// 其余临时浏览目标仍采用已有的通用弹窗，避免影响 iOS 路由。
    private var browseDestinationSheetBinding: Binding<BrowseDestination?> {
        Binding(
            get: {
                guard !model.shouldPresentServerSetup, let destination = model.browseDestination else { return nil }
                if case .album = destination { return nil }
                return destination
            },
            set: { model.browseDestination = $0 }
        )
    }

    private var isShowingAlbumDetail: Bool {
        if case .album = model.browseDestination { return true }
        return false
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
                sidebarItem(.playlists)
            }
            Section("实用工具") {
                sidebarItem(.downloads)
                sidebarItem(.assistant)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacServerStatusEntry(model: model, theme: theme) {
                selection = .server
                showInspector = false
            }
        }
    }

    @ViewBuilder
    private func sidebarItem(_ item: MacNavItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
    }

    // MARK: - 内容路由

    @ViewBuilder
    private var content: some View {
        if case let .album(album) = model.browseDestination {
            MacAlbumDetailPage(album: album, model: model, theme: theme) {
                model.browseDestination = nil
            }
        } else {
            switch selection {
            case .home:
                MacHomePage(model: model, theme: theme, selection: $selectedTracks) {
                    selection = .server
                    showInspector = false
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
            case .playlists:
                MacPlaylistPage(model: model, theme: theme)
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

    // MARK: - 内容区操作条

    private var contentActionBar: some View {
        HStack(spacing: 2) {
            MacToolbarIconButton(symbol: "sidebar.left", help: "显示或隐藏侧边栏") {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            MacToolbarIconButton(symbol: "text.quote", help: "歌词") {
                inspectorTab = .lyrics
                showInspector = true
            }
            MacToolbarIconButton(symbol: "list.bullet", help: "播放队列") {
                inspectorTab = .queue
                showInspector = true
            }
            Menu {
                Button("显示或隐藏检查器") { showInspector.toggle() }
                Button("音频输出…") { openAudioOutput() }
                Divider()
                Button("设置…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.primary)
            .help("更多")
        }
        .padding(.top, 7)
        .padding(.trailing, 12)
    }

    private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func openAudioOutput() {
        // macOS 没有与 iOS 等价的系统输出选择器；打开系统声音偏好设置。
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 侧边栏底部服务器状态入口（紧凑）：名称 + 在线状态 + 同步状态。
private struct MacServerStatusEntry: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let onTap: () -> Void
    @State private var hovering = false

    private var isOnline: Bool {
        if case .connected = model.serverConnectionState { return true }
        if case .connecting = model.serverConnectionState { return true }
        return false
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOnline ? theme.colorTokens.success.color : theme.colorTokens.warning.color)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.catalog.activeAccount?.displayName ?? "未连接服务器")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? theme.colorTokens.surface.color.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onHover { hovering = $0 }
    }

    private var statusLine: String {
        switch model.serverConnectionState {
        case .idle: "未添加服务器"
        case .connecting(let stage): stage.title
        case let .connected(_, type, version, count):
            ([type, version].compactMap { $0 }.joined(separator: " · ") + " · \(count) 首")
        case .failed: "连接失败"
        }
    }
}

/// 固定在窗口底部的桌面播放条。
/// 让播放信息、进度和核心控制拥有稳定的水平空间，而不是与窗口工具栏的系统按钮争抢位置。
private struct MacDesktopPlayerBar: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    private var hasTrack: Bool { model.currentTrack.id.rawValue != "placeholder" }
    private var duration: TimeInterval { max(model.currentTrack.duration, 1) }

    var body: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { model.playbackPosition },
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
                    if hasTrack { model.isNowPlayingPresented = true }
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
                        .frame(maxWidth: 260, alignment: .leading)
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
                    .disabled(!hasTrack || !model.hasPrevious)
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
                    .disabled(!hasTrack || !model.hasNext)
                    .help("下一首（Command-Right）")
                }

                Spacer(minLength: 20)

                HStack(spacing: 14) {
                    MacVolumeControl(model: model, theme: theme)
                    HStack(spacing: 8) {
                        Text(Self.timeText(model.playbackPosition))
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

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 工具栏中的图标操作固定为同一触控尺寸；没有默认边框，悬停时才给出轻微背景。
private struct MacToolbarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// 顶部工具栏播放器控制区（视觉中心）：空状态与播放状态保持基本尺寸，避免重排。
private struct MacToolbarPlayback: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var hovering = false

    private var isPlaying: Bool { model.currentTrack.id.rawValue != "placeholder" }
    private var duration: TimeInterval { model.currentTrack.duration > 0 ? model.currentTrack.duration : 1 }

    var body: some View {
        HStack(spacing: 10) {
            // 上一首
            Button {
                if isPlaying { model.previous() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!isPlaying)
            .help("上一首（Command-Left）")

            // 播放 / 暂停
            Button {
                if isPlaying { model.togglePlayback() }
            } label: {
                Image(systemName: isPlaying ? (model.playbackState == .playing ? "pause.fill" : "play.fill") : "play.fill")
                    .font(.title2)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!isPlaying)
            .help("播放 / 暂停（Space）")

            // 下一首
            Button {
                if isPlaying { model.next() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!isPlaying)
            .help("下一首（Command-Right）")

            Divider().frame(height: 28)

            if isPlaying {
                // 当前歌曲信息（可点击打开正在播放）
                Button {
                    model.isNowPlayingPresented = true
                } label: {
                    HStack(spacing: 8) {
                        ArtworkView(title: model.currentTrack.albumTitle,
                                    artworkKey: model.currentTrack.artworkKey,
                                    colors: theme.colorTokens, size: 40, cornerRadius: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.currentTrack.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                            Text(model.currentTrack.artistName)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(hovering ? theme.colorTokens.surface.color.opacity(0.6) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("打开正在播放")
                .onHover { hovering = $0 }

                // 进度（可拖动）
                VStack(spacing: 2) {
                    Slider(value: Binding(
                        get: { model.playbackPosition },
                        set: { model.seek(toProgress: $0 / duration) }
                    ), in: 0...duration)
                    .frame(width: 160)
                    .controlSize(.mini)
                    HStack {
                        Text(Self.timeText(model.playbackPosition))
                        Spacer()
                        Text(Self.timeText(model.currentTrack.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            } else {
                // 空状态：保留播放器区域基本尺寸
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.colorTokens.surface.color.opacity(0.5))
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未在播放")
                            .font(.callout)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                        Text("从左侧选择一首歌曲开始")
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.secondaryText.color.opacity(0.7))
                    }
                    .frame(width: 180, alignment: .leading)
                }
                .frame(height: 48)
            }
        }
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
