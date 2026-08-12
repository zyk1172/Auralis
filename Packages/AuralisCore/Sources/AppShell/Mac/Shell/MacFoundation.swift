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
}

// MARK: - 主内容路由

/// Apple Music 式导航：Sidebar 一级目的地 + 主内容可推入的详情路由。
enum MacRoute: Hashable, Identifiable {
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
    case playlist(Playlist)
    case album(Album)
    case artist(Artist)
    case genre(Genre)
    case nowPlaying

    var id: String {
        switch self {
        case .home: "home"
        case .recentlyPlayed: "recentlyPlayed"
        case .recentlyAdded: "recentlyAdded"
        case .songs: "songs"
        case .albums: "albums"
        case .artists: "artists"
        case .genres: "genres"
        case .favorites: "favorites"
        case .disliked: "disliked"
        case .downloads: "downloads"
        case .playlists: "playlists"
        case .categories: "categories"
        case .assistant: "assistant"
        case .server: "server"
        case let .playlist(p): "playlist:\(p.serverID):\(p.id)"
        case let .album(a): "album:\(a.serverID):\(a.id)"
        case let .artist(a): "artist:\(a.serverID):\(a.id)"
        case let .genre(g): "genre:\(g.id)"
        case .nowPlaying: "nowPlaying"
        }
    }

    var title: String {
        switch self {
        case .home: "首页"
        case .recentlyPlayed: "最近播放"
        case .recentlyAdded: "最近添加"
        case .songs: "歌曲"
        case .albums: "专辑"
        case .artists: "艺术家"
        case .genres: "流派"
        case .favorites: "收藏"
        case .disliked: "不喜欢"
        case .downloads: "下载"
        case .playlists: "播放列表"
        case .categories: "分类"
        case .assistant: "AI 助手"
        case .server: "服务器"
        case let .playlist(p): p.name
        case let .album(a): a.title
        case let .artist(a): a.name
        case let .genre(g): g.name
        case .nowPlaying: "正在播放"
        }
    }

    var symbol: String {
        switch self {
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
        case .playlist: "music.note.list"
        case .album: "square.stack"
        case .artist: "person.2"
        case .genre: "music.quarternote.3"
        case .nowPlaying: "play.circle"
        }
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
}

// MARK: - 右侧面板模式

enum MacRightPanelMode: String, Hashable {
    case lyrics
    case queue
}
#endif
