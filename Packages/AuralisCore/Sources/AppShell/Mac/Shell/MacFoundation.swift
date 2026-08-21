#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI

extension Track {
    /// SwiftUI 列表和队列的稳定身份必须包含服务器，不能只用会跨库冲突的 TrackID。
    var macGlobalID: GlobalID {
        GlobalID(serverID: serverID, remoteID: id.rawValue)
    }
}

extension Artist {
    /// SwiftUI 列表和网格的稳定身份必须包含服务器：
    /// 跨服务器相同 ArtistID 会共用 Identifiable.id，导致 ForEach 重复身份崩溃。
    var macGlobalID: GlobalID {
        GlobalID(serverID: serverID, remoteID: id.rawValue)
    }
}

extension Album {
    /// SwiftUI 列表和网格的稳定身份必须包含服务器：
    /// 跨服务器相同 AlbumID 会共用 Identifiable.id，导致 ForEach 重复身份崩溃。
    var macGlobalID: GlobalID {
        GlobalID(serverID: serverID, remoteID: id.rawValue)
    }
}

// MARK: - 键盘命令广播（App 菜单 → 主窗口）

/// macOS 键盘命令广播名称。所有 Toolbar / PlayerBar 动作都必须能通过 Menu Bar 触发，
/// 这里提供唯一的广播通道。
public enum MacCommand {
    public static let search = Notification.Name("auralis.mac.command.search")
    public static let revealNowPlaying = Notification.Name("auralis.mac.command.revealNowPlaying")
    public static let toggleSidebar = Notification.Name("auralis.mac.command.toggleSidebar")
    public static let toggleLyrics = Notification.Name("auralis.mac.command.toggleLyrics")
    public static let toggleQueue = Notification.Name("auralis.mac.command.toggleQueue")
    public static let toggleInspector = Notification.Name("auralis.mac.command.toggleInspector")
    public static let previous = Notification.Name("auralis.mac.command.previous")
    public static let next = Notification.Name("auralis.mac.command.next")
    public static let togglePlay = Notification.Name("auralis.mac.command.togglePlay")
    public static let toggleShuffle = Notification.Name("auralis.mac.command.toggleShuffle")
    public static let cycleRepeat = Notification.Name("auralis.mac.command.cycleRepeat")
    /// object = Track：对指定歌曲发起歌曲鉴赏（切换到 AI 助手并调用 music_appreciate）。
    public static let songAppreciation = Notification.Name("auralis.mac.command.songAppreciation")
    /// object = Track：打开该歌曲的 Get Info（含公开音乐资料）。
    public static let showTrackInformation = Notification.Name("auralis.mac.command.showTrackInformation")
    public static let showFullScreenPlayer = Notification.Name("auralis.mac.command.showFullScreenPlayer")
    public static let showMiniPlayer = Notification.Name("auralis.mac.command.showMiniPlayer")
    public static let newPlaylist = Notification.Name("auralis.mac.command.newPlaylist")
}

// MARK: - 主内容导航

/// Sidebar 一级目的地。与可推入的 Detail Route 分离：
/// 一级页面切换 selection、清空 path；实体详情才 push。
enum MacSidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case search
    case home
    case recentlyPlayed
    case recentlyAdded
    case songs
    case albums
    case artists
    case genres
    case favorites
    case disliked
    case downloads
    case playlists
    case categories
    case assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: String(localized: "搜索", bundle: .module)
        case .home: String(localized: "首页", bundle: .module)
        case .recentlyPlayed: String(localized: "最近播放", bundle: .module)
        case .recentlyAdded: String(localized: "最近添加", bundle: .module)
        case .songs: String(localized: "歌曲", bundle: .module)
        case .albums: String(localized: "专辑", bundle: .module)
        case .artists: String(localized: "艺术家", bundle: .module)
        case .genres: String(localized: "流派", bundle: .module)
        case .favorites: String(localized: "收藏歌曲", bundle: .module)
        case .disliked: String(localized: "不喜欢", bundle: .module)
        case .downloads: String(localized: "下载", bundle: .module)
        case .playlists: String(localized: "播放列表", bundle: .module)
        case .categories: String(localized: "分类", bundle: .module)
        case .assistant: String(localized: "AI 助手", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .recentlyPlayed: "clock"
        case .recentlyAdded: "tray.and.arrow.down"
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "person.2"
        case .genres: "music.quarternote.3"
        case .favorites: "heart"
        case .disliked: "heart.slash"
        case .downloads: "arrow.down.circle"
        case .playlists: "music.note.list"
        case .categories: "square.grid.2x2"
        case .assistant: "sparkles"
        }
    }
}

/// 详情路由的实体身份：serverID + remoteID。
/// Navigation path 只保存身份，不保存旧 model snapshot；
/// 渲染时从当前 Catalog 解析最新实体。
struct MacEntityRouteID: Hashable, Codable {
    let serverID: ServerID
    let remoteID: String
}

enum MacDetailRoute: Hashable {
    case album(MacEntityRouteID)
    case artist(MacEntityRouteID)
    case playlist(MacEntityRouteID)
    case genre(String)
    case recommendationCategory(RecommendationIndexV2Category)
}

/// 页面发起的统一导航目标。
enum MacNavigationTarget: Hashable {
    case sidebar(MacSidebarDestination)
    case detail(MacDetailRoute)
}

/// 主内容导航状态机：一级 selection + 可推入 path。
/// 独立成可测试类型；Shell 持有并双向绑定。
@MainActor
final class MacNavigationModel: ObservableObject {
    @Published var selection: MacSidebarDestination? = .home
    @Published var path: [MacDetailRoute] = []
    /// 搜索状态的唯一事实源（Search Text + Presentation）。
    @Published var searchQuery = ""
    @Published var isSearchPresented = false
    /// 退出搜索后恢复的一级目的地。
    var searchReturnDestination: MacSidebarDestination? = nil

    var isSearching: Bool {
        isSearchPresented || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 点击最近搜索词：直接写入搜索词并打开搜索（不写第二份状态）。
    func selectRecentSearch(_ term: String) {
        searchQuery = term
        isSearchPresented = true
    }

    /// 一级页面：切换 selection，清空 path。
    func selectSidebar(_ destination: MacSidebarDestination) {
        selection = destination
        path.removeAll()
        searchReturnDestination = destination
    }

    /// 实体详情：push 到主内容栈，不改一级 selection。
    func push(_ route: MacDetailRoute) {
        path.append(route)
    }

    /// 统一入口：一级 vs 详情。
    func navigate(_ target: MacNavigationTarget) {
        switch target {
        case let .sidebar(destination):
            selectSidebar(destination)
        case let .detail(route):
            push(route)
        }
    }

    func back() {
        if !path.isEmpty { path.removeLast() }
    }
}

// MARK: - 布局 / 排版常量

/// 布局 / 排版常量：统一收敛到 MacUIVisualTokens（见 MacUIVisualTokens.swift）。
/// 历史误导常量（playerBarHeight=78 / contentMaxWidth / sidebarIdeal/Min/Max）已删除，
/// 避免与真实页面（Floating Player 68pt、响应式网格）不一致。

enum MacFormat {
    static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func durationSum(_ tracks: [Track]) -> String {
        let total = tracks.reduce(0) { $0 + $1.duration }
        return time(total)
    }

    static func codec(_ track: Track) -> String? {
        track.effectiveCodec?.uppercased()
    }
}

// MARK: - 资料库查询助手（只读，供 Mac 页面复用，不复制业务逻辑）
// AppModel 是 MainActor 隔离的，查询函数必须在 MainActor 上执行。

@MainActor
enum MacLibraryQuery {
    /// 专辑曲目，按 disc/track 排序。
    /// 使用 LibraryStore 的 tracksByAlbum 派生索引（O(1) 取桶），只对结果做小规模排序，
    /// 不再每次全库 filter。
    static func albumTracks(_ album: Album, model: AuralisAppModel) -> [Track] {
        model.libraryStore.tracks(album: album)
            .sorted { lhs, rhs in
                let l = (lhs.discNumber ?? 1, lhs.trackNumber ?? Int.max)
                let r = (rhs.discNumber ?? 1, rhs.trackNumber ?? Int.max)
                if l.0 != r.0 { return l.0 < r.0 }
                if l.1 != r.1 { return l.1 < r.1 }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// 艺术家专辑，按年份倒序（无年份排后）。
    /// 使用 LibraryStore 的 albumsByArtist 派生索引（O(1) 取桶），只对结果做小规模排序，
    /// 不再每次全库 filter。
    static func artistAlbums(_ artist: Artist, model: AuralisAppModel) -> [Album] {
        model.libraryStore.albums(artist: artist)
            .sorted { lhs, rhs in
                let ly = lhs.year ?? Int.min
                let ry = rhs.year ?? Int.min
                if ly != ry { return ly > ry }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// 艺术家曲目。使用 LibraryStore 的 tracksByArtist 派生索引（O(1) 取桶），
    /// 不再每次全库 filter。
    static func artistTracks(_ artist: Artist, model: AuralisAppModel) -> [Track] {
        model.libraryStore.tracks(artist: artist)
    }

    /// 歌单曲目（按歌单内顺序，本地缺歌则跳过）。
    static func playlistTracks(_ playlist: Playlist, model: AuralisAppModel) -> [Track] {
        playlist.trackIDs.compactMap { id in
            model.track(for: GlobalID(serverID: playlist.serverID, remoteID: id.rawValue))
        }
    }

    /// 流派专辑：按 (serverID, albumID) 双键过滤，避免跨服务器 albumID 串库。
    static func genreAlbums(_ genre: Genre, model: AuralisAppModel) -> [Album] {
        let tracks = model.tracks(for: genre)
        let identities = Set(tracks.map { AlbumRouteIdentity(serverID: $0.serverID, remoteID: $0.albumID.rawValue) })
        return model.catalog.albums.filter {
            identities.contains(AlbumRouteIdentity(serverID: $0.serverID, remoteID: $0.id.rawValue))
        }
    }
}

// MARK: - 右侧面板模式

enum MacRightPanelMode: String, Hashable {
    case lyrics
    case queue
}

// MARK: - 导航便捷构造（页面内保持简短调用）

extension MacNavigationTarget {
    static func album(_ album: Album) -> MacNavigationTarget {
        .detail(.album(MacEntityRouteID(serverID: album.serverID, remoteID: album.id.rawValue)))
    }
    static func artist(_ artist: Artist) -> MacNavigationTarget {
        .detail(.artist(MacEntityRouteID(serverID: artist.serverID, remoteID: artist.id.rawValue)))
    }
    static func playlist(_ playlist: Playlist) -> MacNavigationTarget {
        .detail(.playlist(MacEntityRouteID(serverID: playlist.serverID, remoteID: playlist.id.rawValue)))
    }
    static func genre(_ genre: Genre) -> MacNavigationTarget {
        .detail(.genre(genre.name))
    }
}

// MARK: - 播放器展示状态（Round-4 同窗口展开）

/// Expanded Player 的右侧上下文（歌词/队列）展示状态。
/// 展开/收起本身不再是 AppModel/PresentationState 的状态：
/// 主界面（NavigationSplitView/NavigationStack/libraryUI）从窗口创建到关闭
/// **永远保持挂载**，播放器只是其上的 transient overlay（由 MacMusicShell 的
/// playerOverlayMounted / playerOverlayVisible 驱动），因此不再有
/// library/expanding/expanded/collapsing 四阶段挂载/卸载逻辑。
@MainActor
final class MacPlayerPresentationState: ObservableObject {
    @Published var context: MacExpandedPlayerContext = .none

    func resetContext() {
        context = .none
    }

    func toggleContext(_ tapped: MacExpandedPlayerContext) {
        context = context.toggled(tapped)
    }
}

/// Expanded Player 右侧上下文：无 / 歌词 / 队列。
enum MacExpandedPlayerContext: Hashable {
    case none
    case lyrics
    case queue

    /// 点当前激活按钮 → 关闭；点另一个 → 切换。
    func toggled(_ tapped: MacExpandedPlayerContext) -> MacExpandedPlayerContext {
        self == tapped ? .none : tapped
    }
}

/// 歌词加载状态：区分 加载中 / 可用 / 确实无 / 错误，避免把加载中误判为无歌词。
enum MacLyricsPresentationState: Equatable {
    case loading
    case available(LyricsDocument)
    case unavailable
    case error(String)
}


// MARK: - Expanded Player 几何度量（REFERENCE_B）

enum MacFullPlayerMetrics {
    static func playerColumnWidth(window: CGSize) -> CGFloat {
        let t = MacUIVisualTokens.ExpandedPlayer.self
        return min(t.playerColumnMax, max(t.playerColumnMin, window.width * t.playerColumnWidthRatio))
    }
    static func artworkSize(window: CGSize) -> CGFloat {
        let t = MacUIVisualTokens.ExpandedPlayer.self
        // 最大（播放态）封面与标题、进度条、Transport 共用同一条控制轨；
        // 仅在矮窗口时按高度限幅，暂停时由 View 的 scaleEffect 视觉收拢，
        // 不改变这里的布局占位。
        let widthBased = playerColumnWidth(window: window) * t.artworkToColumnRatio
        let heightBased = window.height * t.artworkHeightRatio
        return min(t.artworkMax, max(t.artworkMin, min(widthBased, heightBased)))
    }
    static func leftMargin(window: CGSize) -> CGFloat { window.width * MacUIVisualTokens.ExpandedPlayer.leftMarginRatio }
    static func topY(window: CGSize) -> CGFloat {
        // 封面、歌名、进度与运输控制是一组，按整组高度居中，而不是只把封面
        // 放到中部再把控制区向下堆叠。这个估值覆盖 artwork 以下的固定间距、
        // 双行歌曲资料、进度以及 transport，因而不同窗口高度仍保持视觉中心。
        let artwork = artworkSize(window: window)
        let controlsBelowArtwork: CGFloat = 232
        return max(64, min(150, (window.height - artwork - controlsBelowArtwork) / 2))
    }
    static func contextTopY(window: CGSize) -> CGFloat {
        let t = MacUIVisualTokens.ExpandedPlayer.self
        return max(t.contextTopInsetMin, min(t.contextTopInsetMax, window.height * t.contextTopInsetRatio))
    }
    static func horizontalGap(window: CGSize) -> CGFloat {
        let t = MacUIVisualTokens.ExpandedPlayer.self
        return max(t.horizontalGapMin, window.width * t.horizontalGapRatio)
    }
    static func transportWidth(window: CGSize) -> CGFloat { playerColumnWidth(window: window) }
}

#endif
