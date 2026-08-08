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

/// macOS 主窗口：顶部三区工具栏 + 可收起侧边栏 + 主内容 + 按需检查器。
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
    @State private var showSidebar = true

    private var theme: BuiltInTheme { themeStore.current }
    private var colors: ThemeColors { theme.colorTokens }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } content: {
            content
                .navigationTitle(selection?.title ?? "澜音")
                .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        } detail: {
            if showInspector, inspectorContextAvailable {
                MacInspector(model: model, theme: theme, initialTab: inspectorTab, onTabChange: { inspectorTab = $0 })
                    .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 380)
            }
        }
        // 移除系统自动 sidebar toggle，统一使用我们自己的一个按钮（避免两个重复按钮）。
        .toolbar(removing: .sidebarToggle)
        .toolbar { toolbarContent }
        .onChange(of: selection) { _, newValue in
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
            if selection == .search { /* 结果页实时刷新 */ }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacCommandNotification.search)) { _ in
            selection = .search
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

    private var inspectorContextAvailable: Bool {
        selection != .server
            && (model.currentTrack.id.rawValue != "placeholder" || !selectedTracks.isEmpty)
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 紧凑侧边栏搜索框（Apple Music 风格），结果进入搜索页。
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                TextField("搜索", text: $sidebarSearch)
                    .textFieldStyle(.plain)
                    .onSubmit { selection = .search }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.colorTokens.surface.color.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 10)

            List(selection: $selection) {
                Section("资料库") {
                    MacSidebarRow(item: .home, selection: $selection, theme: theme)
                    MacSidebarRow(item: .recentlyPlayed, selection: $selection, theme: theme)
                    MacSidebarRow(item: .recentlyAdded, selection: $selection, theme: theme)
                    ForEach(MacLibraryScope.allCases) { scope in
                        MacSidebarRow(item: .library(scope), selection: $selection, theme: theme)
                    }
                }
                Section("收藏与歌单") {
                    MacSidebarRow(item: .favorites, selection: $selection, theme: theme)
                    MacSidebarRow(item: .playlists, selection: $selection, theme: theme)
                }
                Section("工具") {
                    MacSidebarRow(item: .assistant, selection: $selection, theme: theme)
                    MacSidebarRow(item: .downloads, selection: $selection, theme: theme)
                }
            }
            .listStyle(.sidebar)

            // 底部紧凑服务器状态入口（点击进入服务器管理）。
            MacServerStatusEntry(model: model, theme: theme) {
                selection = .server
                showInspector = false
            }
        }
    }

    // MARK: - 内容路由

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            MacHomePage(model: model, theme: theme, selection: $selectedTracks)
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

    // MARK: - 顶部工具栏（三区）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 左区：侧边栏切换（唯一一个）+ 返回 + 前进
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("显示或隐藏侧边栏（Command-Option-S）")
            Button {
                selection = .home
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("返回首页")
            Button {
                selection = .home
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("前进")
        }
        // 中区：完整播放器控制区（视觉中心）
        ToolbarItem(placement: .principal) {
            MacToolbarPlayback(model: model, theme: theme)
        }
        // 右区：音量 / 搜索 / 歌词 / 队列 / 更多
        ToolbarItemGroup(placement: .primaryAction) {
            MacVolumeControl(model: model, theme: theme)
            Button {
                selection = .search
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("搜索（Command-F）")
            Button {
                inspectorTab = .lyrics
                showInspector = true
            } label: {
                Image(systemName: "text.quote")
            }
            .help("歌词")
            Button {
                inspectorTab = .queue
                showInspector = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .help("播放队列")
            Menu {
                Button("显示或隐藏检查器") { showInspector.toggle() }
                Button("音频输出…") { openAudioOutput() }
                Divider()
                Button("设置…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("更多")
        }
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

/// 侧边栏行：悬停高亮 + 选中强调色（图标弱化，突出文字层级）。
private struct MacSidebarRow: View {
    let item: MacNavItem
    @Binding var selection: MacNavItem?
    let theme: BuiltInTheme
    @State private var hovering = false

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(
                        selection == item
                        ? theme.colorTokens.accent.color
                        : theme.colorTokens.secondaryText.color
                    )
                    .frame(width: 18)
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selection == item
            ? theme.colorTokens.accent.color.opacity(0.16)
            : (hovering ? theme.colorTokens.surface.color.opacity(0.5) : Color.clear)
        )
        .onHover { hovering = $0 }
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
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering ? theme.colorTokens.surface.color.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(8)
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
            .frame(width: 80)
            .controlSize(.mini)
        }
        .help("音量")
    }
}
#endif
