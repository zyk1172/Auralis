// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 应用内统一的音乐库快照：真实服务器目录作为持久事实，本地文件通过
/// `LocalCatalogOverlay` 在读取边界叠加。`auralis-local` 不是 ServerAccount，
/// 因此服务器连接、凭据和 OpenSubsonic 写操作仍只针对真实服务器。
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
        let local = LocalCatalogOverlay.snapshot()
        self.account = account
        self.artists = LocalCatalogOverlay.mergedArtists(remote: artists, local: local)
        self.albums = LocalCatalogOverlay.mergedAlbums(remote: albums, local: local)
        self.tracks = LocalCatalogOverlay.mergedTracks(remote: tracks, local: local)
        self.genres = LocalCatalogOverlay.mergedGenres(remote: genres, local: local)
        self.playlists = playlists
        self.history = history
        self.downloads = downloads
        self.lyrics = LocalCatalogOverlay.mergedLyrics(remote: lyrics, local: local)
        self.recommendations = recommendations
    }
}

extension LibraryCatalog {
    /// 空 catalog，App 启动时未连接服务器使用。即使未连接服务器，只要本地 overlay
    /// 已恢复，普通资料库 / 搜索仍可看到真实本地音乐。
    public static var empty: LibraryCatalog {
        LibraryCatalog(
            account: ServerAccount(id: "local", displayName: String(localized: "未连接服务器", bundle: .module)),
            artists: [], albums: [], tracks: [], genres: [], playlists: [],
            history: [], downloads: [], lyrics: [:], recommendations: []
        )
    }

    /// 占位账户的 ID，表示「尚未连接任何服务器」。它与本地实体 namespace
    /// `auralis-local` 不同，不能把两者混为同一个服务器。
    public static let placeholderServerID = ServerID(rawValue: "local")

    /// 是否已连接到真实服务器（而非占位账户）。
    public var isConnected: Bool { account.id != Self.placeholderServerID }

    /// 当前活跃服务器 ID；未连接时为 nil。多服务器隔离校验都应基于它。
    public var activeServerID: ServerID? { isConnected ? account.id : nil }

    /// 当前活跃服务器账户；未连接时为 nil。
    public var activeAccount: ServerAccount? { isConnected ? account : nil }
}
