import Foundation

/// 应用内统一的音乐库快照：连接服务器后被服务器数据填充。
public struct LibraryCatalog: Sendable {
    public let account: ServerAccount
    public let artists: [Artist]
    public let albums: [Album]
    public var tracks: [Track]
    /// 流派可在后台增量刷新时就地合并（服务器 getGenres 与曲目标签两套来源），
    /// 因此声明为 var，避免为了改一个字段而重建整个 catalog。
    public var genres: [Genre]
    public var playlists: [Playlist]
    public let history: [PlayHistory]
    public let downloads: [DownloadRecord]
    public var lyrics: [TrackID: LyricsDocument]
    public let recommendations: [RecommendationResult]

    public init(
        account: ServerAccount,
        artists: [Artist],
        albums: [Album],
        tracks: [Track],
        genres: [Genre],
        playlists: [Playlist],
        history: [PlayHistory],
        downloads: [DownloadRecord],
        lyrics: [TrackID: LyricsDocument],
        recommendations: [RecommendationResult]
    ) {
        self.account = account
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.genres = genres
        self.playlists = playlists
        self.history = history
        self.downloads = downloads
        self.lyrics = lyrics
        self.recommendations = recommendations
    }
}

extension LibraryCatalog {
    /// 空 catalog，App 启动时未连接服务器使用。连接成功后替换为服务器数据。
    public static let empty = LibraryCatalog(
        account: ServerAccount(id: "local", displayName: "未连接服务器"),
        artists: [], albums: [], tracks: [], genres: [], playlists: [],
        history: [], downloads: [], lyrics: [:], recommendations: []
    )

    /// 占位账户的 ID，表示「尚未连接任何服务器」。
    public static let placeholderServerID = ServerID(rawValue: "local")

    /// 是否已连接到真实服务器（而非占位账户）。
    public var isConnected: Bool { account.id != Self.placeholderServerID }

    /// 当前活跃服务器 ID；未连接时为 nil。多服务器隔离校验都应基于它。
    public var activeServerID: ServerID? { isConnected ? account.id : nil }

    /// 当前活跃服务器账户；未连接时为 nil。
    public var activeAccount: ServerAccount? { isConnected ? account : nil }
}
