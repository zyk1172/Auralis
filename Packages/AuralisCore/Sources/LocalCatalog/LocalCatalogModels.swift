import Domain
import Foundation
import MusicLibrary

/// 本地目录支持同步的实体种类。
public enum CatalogEntityKind: String, Codable, CaseIterable, Sendable, Hashable {
    case server
    case artist
    case album
    case track
    case genre
    case playlist
    case lyric
    case classification
}

/// 下载状态机。
public enum DownloadStateValue: String, Codable, Sendable, Hashable {
    case none
    case downloading
    case cached
    case failed
}

/// 单服务器目录的同步状态（供 UI 展示，不涉及完整记录）。
public struct CatalogSyncStatus: Sendable, Hashable {
    public let serverID: ServerID
    public let mode: LibrarySyncMode?
    public let isRunning: Bool
    public let isStale: Bool
    public let lastCompletedAt: Date?
    public let lastProcessedCount: Int
    public let nextRetryAt: Date?

    public init(
        serverID: ServerID,
        mode: LibrarySyncMode? = nil,
        isRunning: Bool = false,
        isStale: Bool = false,
        lastCompletedAt: Date? = nil,
        lastProcessedCount: Int = 0,
        nextRetryAt: Date? = nil
    ) {
        self.serverID = serverID
        self.mode = mode
        self.isRunning = isRunning
        self.isStale = isStale
        self.lastCompletedAt = lastCompletedAt
        self.lastProcessedCount = lastProcessedCount
        self.nextRetryAt = nextRetryAt
    }
}

/// 本地目录中保存的一首歌曲的轻量摘要，供 Agent 卡片与列表使用。
public struct CatalogTrackSummary: Sendable, Hashable, Identifiable {
    public var id: GlobalID { globalID }
    public let globalID: GlobalID
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let duration: TimeInterval
    public let isFavorite: Bool
    public let userRating: Int
    public let isDownloaded: Bool

    public init(
        globalID: GlobalID,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        isFavorite: Bool,
        userRating: Int,
        isDownloaded: Bool
    ) {
        self.globalID = globalID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.isFavorite = isFavorite
        self.userRating = userRating
        self.isDownloaded = isDownloaded
    }
}

/// 本地目录专辑摘要。
public struct CatalogAlbumSummary: Sendable, Hashable, Identifiable {
    public var id: GlobalID { globalID }
    public let globalID: GlobalID
    public let title: String
    public let artistName: String
    public let songCount: Int

    public init(globalID: GlobalID, title: String, artistName: String, songCount: Int) {
        self.globalID = globalID
        self.title = title
        self.artistName = artistName
        self.songCount = songCount
    }
}

/// 本地目录艺术家摘要。
public struct CatalogArtistSummary: Sendable, Hashable, Identifiable {
    public var id: GlobalID { globalID }
    public let globalID: GlobalID
    public let name: String
    public let albumCount: Int

    public init(globalID: GlobalID, name: String, albumCount: Int) {
        self.globalID = globalID
        self.name = name
        self.albumCount = albumCount
    }
}

/// 曲库索引：按分类拆分，供 Agent 按需读取，避免每次把全部元数据塞进对话。
/// 只含元数据（ID/标题/歌手/专辑/年份/流派/语言/时长/收藏/评分/播放次数），
/// **不含歌词、海报、流地址**。
public struct CatalogTrackLine: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let year: Int?
    public let genres: [String]
    public let language: String?
    public let duration: Int
    public let isFavorite: Bool
    public let rating: Int?
    public let playCount: Int
    public let isDownloaded: Bool

    public init(
        id: String, title: String, artist: String, album: String,
        year: Int?, genres: [String], language: String?, duration: Int,
        isFavorite: Bool, rating: Int?, playCount: Int, isDownloaded: Bool
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genres = genres
        self.language = language
        self.duration = duration
        self.isFavorite = isFavorite
        self.rating = rating
        self.playCount = playCount
        self.isDownloaded = isDownloaded
    }
}

/// 推荐索引 V2 由已配置的 Agent 模型写入的多维标签。
/// 这些标签只基于曲目元数据，不保存歌词、文件路径或播放地址。
public struct RecommendationIndexV2Classification: Codable, Sendable, Hashable {
    public let id: String
    public let moods: [String]
    public let scenes: [String]
    public let energy: Int
    public let tempo: Int
    public let acousticness: Int
    public let danceability: Int
    public let vocals: [String]
    public let textures: [String]
    public let styles: [String]
    public let confidence: Double

    public init(
        id: String,
        moods: [String] = [],
        scenes: [String] = [],
        energy: Int,
        tempo: Int = 3,
        acousticness: Int = 3,
        danceability: Int = 3,
        vocals: [String] = [],
        textures: [String] = [],
        styles: [String] = [],
        confidence: Double = 0.5
    ) {
        self.id = id
        self.moods = moods
        self.scenes = scenes
        self.energy = energy
        self.tempo = tempo
        self.acousticness = acousticness
        self.danceability = danceability
        self.vocals = vocals
        self.textures = textures
        self.styles = styles
        self.confidence = confidence
    }
}

public struct RecommendationIndexV2Status: Sendable, Hashable {
    public let totalTracks: Int
    public let indexedTracks: Int
    public let pendingTracks: Int
    public let rulesVersion: String

    public init(totalTracks: Int, indexedTracks: Int, pendingTracks: Int, rulesVersion: String) {
        self.totalTracks = totalTracks
        self.indexedTracks = indexedTracks
        self.pendingTracks = pendingTracks
        self.rulesVersion = rulesVersion
    }
}

public struct RecommendationIndexV2Batch: Sendable, Hashable {
    public let tracks: [CatalogTrackLine]
    public let pendingTracks: Int
    public let rulesVersion: String

    public init(tracks: [CatalogTrackLine], pendingTracks: Int, rulesVersion: String) {
        self.tracks = tracks
        self.pendingTracks = pendingTracks
        self.rulesVersion = rulesVersion
    }
}

/// 一条已完成的推荐索引 V2 记录。仅含本地元数据和分类标签，不含歌词、路径或播放地址。
public struct RecommendationIndexV2IndexedTrack: Codable, Sendable, Hashable {
    public let track: CatalogTrackLine
    public let tags: [String: [String]]
    public let confidence: Double

    public init(track: CatalogTrackLine, tags: [String: [String]], confidence: Double) {
        self.track = track
        self.tags = tags
        self.confidence = confidence
    }
}

/// 推荐索引 V2 的一个可浏览分类（例如「场景 · 通勤」或「情绪 · 平静」）。
public struct RecommendationIndexV2Category: Sendable, Hashable, Identifiable {
    public let dimension: String
    public let value: String
    public let trackCount: Int

    public var id: String { "\(dimension):\(value)" }

    public init(dimension: String, value: String, trackCount: Int) {
        self.dimension = dimension
        self.value = value
        self.trackCount = trackCount
    }
}

public struct CatalogArtistIndexEntry: Codable, Sendable, Hashable {
    public let name: String
    public let albumCount: Int
    public let songCount: Int
}

public struct CatalogAlbumIndexEntry: Codable, Sendable, Hashable {
    public let title: String
    public let artist: String
    public let year: Int?
    public let songCount: Int
}

public struct CatalogGenreIndexEntry: Codable, Sendable, Hashable {
    public let name: String
    public let songCount: Int
}

public struct CatalogLanguageIndexEntry: Codable, Sendable, Hashable {
    public let language: String
    public let songCount: Int
}

public struct CatalogYearIndexEntry: Codable, Sendable, Hashable {
    public let year: Int
    public let songCount: Int
}

/// 全部分类的索引汇总（用于落盘与快速浏览）。
public struct CatalogIndex: Codable, Sendable {
    public let serverID: String?
    public let generatedAt: Date
    public let songCount: Int
    public let artistCount: Int
    public let albumCount: Int
    public let artists: [CatalogArtistIndexEntry]
    public let albums: [CatalogAlbumIndexEntry]
    public let genres: [CatalogGenreIndexEntry]
    public let languages: [CatalogLanguageIndexEntry]
    public let years: [CatalogYearIndexEntry]
    public let favorites: [CatalogTrackLine]
    public let recent: [CatalogTrackLine]
    public let popular: [CatalogTrackLine]

    public init(
        serverID: String?, generatedAt: Date, songCount: Int, artistCount: Int, albumCount: Int,
        artists: [CatalogArtistIndexEntry], albums: [CatalogAlbumIndexEntry],
        genres: [CatalogGenreIndexEntry], languages: [CatalogLanguageIndexEntry],
        years: [CatalogYearIndexEntry], favorites: [CatalogTrackLine],
        recent: [CatalogTrackLine], popular: [CatalogTrackLine]
    ) {
        self.serverID = serverID
        self.generatedAt = generatedAt
        self.songCount = songCount
        self.artistCount = artistCount
        self.albumCount = albumCount
        self.artists = artists
        self.albums = albums
        self.genres = genres
        self.languages = languages
        self.years = years
        self.favorites = favorites
        self.recent = recent
        self.popular = popular
    }
}

/// 单曲热度代理（本地播放次数 + 最近播放时间）。
public struct TrackPopularity: Sendable, Hashable {
    public let globalID: GlobalID
    public let playCount: Int
    public let lastPlayedAt: Date?

    public init(globalID: GlobalID, playCount: Int, lastPlayedAt: Date?) {
        self.globalID = globalID
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
    }
}

/// 本地目录歌单摘要（含曲目顺序）。
public struct CatalogPlaylistSummary: Sendable, Hashable, Identifiable {
    public var id: GlobalID { globalID }
    public let globalID: GlobalID
    public let name: String
    public let trackIDs: [GlobalID]
    public let isReadOnly: Bool
    public let modifiedAt: Date?

    public init(
        globalID: GlobalID,
        name: String,
        trackIDs: [GlobalID],
        isReadOnly: Bool,
        modifiedAt: Date? = nil
    ) {
        self.globalID = globalID
        self.name = name
        self.trackIDs = trackIDs
        self.isReadOnly = isReadOnly
        self.modifiedAt = modifiedAt
    }
}
