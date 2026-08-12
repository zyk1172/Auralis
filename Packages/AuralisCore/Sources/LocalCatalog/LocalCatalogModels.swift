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

public struct CatalogRemoteProbeState: Sendable, Equatable {
    public let fingerprint: String?
    public let kind: String?
    public let lastProbedAt: Date?
    public let lastValidatedAt: Date?

    public init(fingerprint: String?, kind: String?, lastProbedAt: Date?, lastValidatedAt: Date?) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.lastProbedAt = lastProbedAt
        self.lastValidatedAt = lastValidatedAt
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

/// 一条开放语义标签（AI 自建）：value 为规范化的中文/常见英文标签，confidence 为模型置信度。
/// 标签数量没有硬上限；质量通过规范化、复用 canonical 与语义规则控制。
public struct RecommendationIndexV2SemanticTag: Codable, Sendable, Hashable {
    public let value: String
    public let confidence: Double

    public init(value: String, confidence: Double) {
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
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
    /// 开放语义标签（dimension = "tag"），不设数量上限。
    public let semanticTags: [RecommendationIndexV2SemanticTag]
    /// "full"=完整分类（固定维度 + 语义标签）；"semanticTagsOnly"=只补开放标签（不触碰旧固定维度）。
    public let mode: String
    public let confidence: Double

    private enum CodingKeys: String, CodingKey {
        case id, moods, scenes, energy, tempo, acousticness, danceability
        case vocals, textures, styles, semanticTags, mode, confidence
    }

    public init(
        id: String,
        moods: [String] = [],
        scenes: [String] = [],
        energy: Int = 3,
        tempo: Int = 3,
        acousticness: Int = 3,
        danceability: Int = 3,
        vocals: [String] = [],
        textures: [String] = [],
        styles: [String] = [],
        semanticTags: [RecommendationIndexV2SemanticTag] = [],
        mode: String = "full",
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
        self.semanticTags = semanticTags
        self.mode = mode
        self.confidence = confidence
    }

    /// 原生工具 Schema 只强制真实 ID 与能量值；其它维度允许模型按证据省略，
    /// 解码时使用与公开初始化器一致的安全默认值，而不是让整批写回失败。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        moods = try container.decodeIfPresent([String].self, forKey: .moods) ?? []
        scenes = try container.decodeIfPresent([String].self, forKey: .scenes) ?? []
        energy = try container.decodeIfPresent(Int.self, forKey: .energy) ?? 3
        tempo = try container.decodeIfPresent(Int.self, forKey: .tempo) ?? 3
        acousticness = try container.decodeIfPresent(Int.self, forKey: .acousticness) ?? 3
        danceability = try container.decodeIfPresent(Int.self, forKey: .danceability) ?? 3
        vocals = try container.decodeIfPresent([String].self, forKey: .vocals) ?? []
        textures = try container.decodeIfPresent([String].self, forKey: .textures) ?? []
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
        semanticTags = try container.decodeIfPresent([RecommendationIndexV2SemanticTag].self, forKey: .semanticTags) ?? []
        mode = (try container.decodeIfPresent(String.self, forKey: .mode)) ?? "full"
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }
}

public struct RecommendationIndexV2Status: Sendable, Hashable {
    public let totalTracks: Int
    public let indexedTracks: Int
    public let pendingTracks: Int
    public let rulesVersion: String
    public let semanticTagRulesVersion: Int
    /// 已有开放语义标签（dimension='tag'）的歌曲数。
    public let semanticTaggedTracks: Int
    /// 尚缺开放语义标签的歌曲数。
    public let pendingSemanticTagTracks: Int

    public init(
        totalTracks: Int,
        indexedTracks: Int,
        pendingTracks: Int,
        rulesVersion: String,
        semanticTagRulesVersion: Int = RecommendationIndexV2.semanticTagRulesVersion,
        semanticTaggedTracks: Int = 0,
        pendingSemanticTagTracks: Int = 0
    ) {
        self.totalTracks = totalTracks
        self.indexedTracks = indexedTracks
        self.pendingTracks = pendingTracks
        self.rulesVersion = rulesVersion
        self.semanticTagRulesVersion = semanticTagRulesVersion
        self.semanticTaggedTracks = semanticTaggedTracks
        self.pendingSemanticTagTracks = pendingSemanticTagTracks
    }
}

public struct RecommendationIndexV2Batch: Sendable, Hashable {
    public let tracks: [CatalogTrackLine]
    public let pendingTracks: Int
    public let rulesVersion: String
    /// 本批主要需要的工作：full=固定维度+开放标签；semanticTagsOnly=只补开放标签；
    /// mixed=混合。
    public let mode: String

    public init(tracks: [CatalogTrackLine], pendingTracks: Int, rulesVersion: String, mode: String = "full") {
        self.tracks = tracks
        self.pendingTracks = pendingTracks
        self.rulesVersion = rulesVersion
        self.mode = mode
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
