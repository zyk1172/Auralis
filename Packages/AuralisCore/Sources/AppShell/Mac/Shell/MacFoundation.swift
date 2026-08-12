#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI

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
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "搜索"
        case .home: "首页"
        case .recentlyPlayed: "最近播放"
        case .recentlyAdded: "最近添加"
        case .songs: "歌曲"
        case .albums: "专辑"
        case .artists: "艺术家"
        case .genres: "流派"
        case .favorites: "收藏歌曲"
        case .disliked: "不喜欢"
        case .downloads: "下载"
        case .playlists: "播放列表"
        case .categories: "分类"
        case .assistant: "AI 助手"
        case .server: "服务器"
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
        case .server: "server.rack"
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

/// Apple Music 式密度：内容层保持平、无 Card dashboard。
enum MacLayout {
    public static let sidebarIdeal: CGFloat = 240
    public static let sidebarMin: CGFloat = 200
    public static let sidebarMax: CGFloat = 300
    public static let pageTitleSize: CGFloat = 30
    public static let sectionTitleSize: CGFloat = 21
    public static let artworkGridGap: CGFloat = 20
    public static let artworkCornerRadius: CGFloat = 10
    public static let albumArtworkSize: CGFloat = 168
    public static let contentMaxWidth: CGFloat = 1200
    public static let playerBarHeight: CGFloat = 78
}

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
    static func albumTracks(_ album: Album, model: AuralisAppModel) -> [Track] {
        model.catalog.tracks
            .filter { $0.albumID == album.id && $0.serverID == album.serverID }
            .sorted { lhs, rhs in
                let l = (lhs.discNumber ?? 1, lhs.trackNumber ?? Int.max)
                let r = (rhs.discNumber ?? 1, rhs.trackNumber ?? Int.max)
                if l.0 != r.0 { return l.0 < r.0 }
                if l.1 != r.1 { return l.1 < r.1 }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// 艺术家专辑，按年份倒序（无年份排后）。
    static func artistAlbums(_ artist: Artist, model: AuralisAppModel) -> [Album] {
        model.catalog.albums
            .filter { $0.artistID == artist.id && $0.serverID == artist.serverID }
            .sorted { lhs, rhs in
                let ly = lhs.year ?? Int.min
                let ry = rhs.year ?? Int.min
                if ly != ry { return ly > ry }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// 艺术家曲目。
    static func artistTracks(_ artist: Artist, model: AuralisAppModel) -> [Track] {
        model.catalog.tracks
            .filter { $0.artistID == artist.id && $0.serverID == artist.serverID }
    }

    /// 歌单曲目（按歌单内顺序，本地缺歌则跳过）。
    static func playlistTracks(_ playlist: Playlist, model: AuralisAppModel) -> [Track] {
        playlist.trackIDs.compactMap { id in
            model.catalog.tracks.first { $0.id == id && $0.serverID == playlist.serverID }
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

#endif
