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

/// 一次 FTS 查询同时返回三类搜索结果，避免同一关键词重复执行三遍 MATCH。
public struct LocalCatalogSearchResults: Sendable, Equatable {
    public let tracks: [CatalogTrackSummary]
    public let albums: [CatalogAlbumSummary]
    public let artists: [CatalogArtistSummary]

    public init(
        tracks: [CatalogTrackSummary],
        albums: [CatalogAlbumSummary],
        artists: [CatalogArtistSummary]
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
    }
}

/// 指定服务器的完整 SQLite 目录快照。该 API 明确无数量上限；需要完整重建内存
/// catalog 的调用方统一使用它，避免各处悄悄写入 20,000 之类的截断值。
public struct LocalCatalogSnapshot: Sendable, Equatable {
    public let artists: [Artist]
    public let albums: [Album]
    public let tracks: [Track]

    public init(artists: [Artist], albums: [Album], tracks: [Track]) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
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

/// 一条开放语义标签（AI 自建）：只供历史数据解码使用。
@available(*, deprecated, message: "Open semantic tags are no longer produced; retained only for legacy decode")
public struct RecommendationIndexSemanticTag: Codable, Sendable, Hashable {
    public let value: String
    public let confidence: Double

    public init(value: String, confidence: Double) {
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
    }
}

/// Recommendation Index v3 live classification. This is deliberately a pure
/// fixed-taxonomy DTO: identity, fixed categorical dimensions, optional
/// numeric dimensions, and a safe confidence fallback. Unknown JSON keys are
/// ignored by Codable, so legacy `semanticTags`/`mode` output cannot affect the
/// live parser.
public struct RecommendationIndexClassification: Codable, Sendable, Hashable {
    public let id: String
    /// Canonical fixed-taxonomy IDs, for example "mood.sacred".
    public let moods: [String]
    public let scenes: [String]
    public let themes: [String]
    public let genres: [String]
    public let styles: [String]
    public let vocals: [String]
    public let instruments: [String]
    public let textures: [String]
    public let rhythms: [String]
    public let energy: Int?
    public let tempo: Int?
    public let acousticness: Int?
    public let danceability: Int?
    public let instrumentalness: Int?
    public let liveness: Int?
    public let speechiness: Int?
    public let valence: Int?
    public let complexity: Int?
    /// Confidence is not identity. Missing/null model output is safe as 0.5.
    public let confidence: Double

    private enum CodingKeys: String, CodingKey {
        case id, moods, scenes, themes, genres, styles, vocals, instruments, textures, rhythms
        case energy, tempo, acousticness, danceability, instrumentalness, liveness
        case speechiness, valence, complexity, confidence
    }

    public init(
        id: String,
        moods: [String] = [],
        scenes: [String] = [],
        energy: Int? = nil,
        tempo: Int? = nil,
        acousticness: Int? = nil,
        danceability: Int? = nil,
        vocals: [String] = [],
        textures: [String] = [],
        styles: [String] = [],
        confidence: Double = 0.5,
        themes: [String] = [],
        genres: [String] = [],
        instruments: [String] = [],
        rhythms: [String] = [],
        instrumentalness: Int? = nil,
        liveness: Int? = nil,
        speechiness: Int? = nil,
        valence: Int? = nil,
        complexity: Int? = nil
    ) {
        self.id = id
        self.moods = moods
        self.scenes = scenes
        self.themes = themes
        self.genres = genres
        self.styles = styles
        self.vocals = vocals
        self.instruments = instruments
        self.textures = textures
        self.rhythms = rhythms
        self.energy = energy
        self.tempo = tempo
        self.acousticness = acousticness
        self.danceability = danceability
        self.instrumentalness = instrumentalness
        self.liveness = liveness
        self.speechiness = speechiness
        self.valence = valence
        self.complexity = complexity
        self.confidence = Self.normalizedConfidence(confidence)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        moods = try Self.decodeStringArray(.moods, from: container)
        scenes = try Self.decodeStringArray(.scenes, from: container)
        themes = try Self.decodeStringArray(.themes, from: container)
        genres = try Self.decodeStringArray(.genres, from: container)
        styles = try Self.decodeStringArray(.styles, from: container)
        vocals = try Self.decodeStringArray(.vocals, from: container)
        instruments = try Self.decodeStringArray(.instruments, from: container)
        textures = try Self.decodeStringArray(.textures, from: container)
        rhythms = try Self.decodeStringArray(.rhythms, from: container)
        energy = try Self.decodeOptionalInteger(.energy, from: container)
        tempo = try Self.decodeOptionalInteger(.tempo, from: container)
        acousticness = try Self.decodeOptionalInteger(.acousticness, from: container)
        danceability = try Self.decodeOptionalInteger(.danceability, from: container)
        instrumentalness = try Self.decodeOptionalInteger(.instrumentalness, from: container)
        liveness = try Self.decodeOptionalInteger(.liveness, from: container)
        speechiness = try Self.decodeOptionalInteger(.speechiness, from: container)
        valence = try Self.decodeOptionalInteger(.valence, from: container)
        complexity = try Self.decodeOptionalInteger(.complexity, from: container)
        confidence = Self.decodeConfidence(from: container)
    }

    /// Non-strict OpenAI-compatible providers sometimes encode an integer as
    /// a quoted value. Accept that deterministic representation, while still
    /// surfacing floats, objects, arrays, and booleans as repairable shape
    /// errors instead of inventing a numeric value.
    private static func decodeOptionalInteger(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return nil }
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let raw = try? container.decode(String.self, forKey: key),
           let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: container.codingPath + [key],
                debugDescription: "\(key.stringValue) 必须是 integer、整数字符串或 null"
            )
        )
    }

    /// Confidence is advisory metadata, not an identity or coverage field.
    /// Providers commonly quote numbers or return an occasional out-of-range
    /// value; normalize those cases without making the whole item repairable.
    private static func decodeConfidence(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Double {
        guard container.contains(.confidence),
              (try? container.decodeNil(forKey: .confidence)) != true
        else { return 0.5 }

        if let value = try? container.decode(Double.self, forKey: .confidence) {
            return normalizedConfidence(value)
        }
        if let raw = try? container.decode(String.self, forKey: .confidence),
           let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return normalizedConfidence(value)
        }
        return 0.5
    }

    private static func normalizedConfidence(_ value: Double) -> Double {
        value.isFinite && (0...1).contains(value) ? value : 0.5
    }

    private static func decodeStringArray(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        guard container.contains(key) else { return [] }
        if try container.decodeNil(forKey: key) { return [] }

        if let values = try? container.decode([String].self, forKey: key) {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let scalar = try? container.decode(String.self, forKey: key) {
            let normalized = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? [] : [normalized]
        }

        throw DecodingError.typeMismatch(
            [String].self,
            DecodingError.Context(
                codingPath: container.codingPath + [key],
                debugDescription: "\(key.stringValue) 必须是 string 或 string[]"
            )
        )
    }
}

/// Historical v2 item DTO. It is intentionally separate from the v3 live
/// contract and is only an adapter surface for import/migration code.
public struct LegacyRecommendationIndexClassificationV2: Codable, Sendable, Hashable {
    public struct SemanticTagPayload: Codable, Sendable, Hashable {
        public let value: String
        public let confidence: Double

        public init(value: String, confidence: Double) {
            self.value = value
            self.confidence = confidence
        }
    }

    public let id: String
    public let moods: [String]
    public let scenes: [String]
    public let themes: [String]
    public let genres: [String]
    public let styles: [String]
    public let vocals: [String]
    public let instruments: [String]
    public let textures: [String]
    public let rhythms: [String]
    public let energy: Int?
    public let tempo: Int?
    public let acousticness: Int?
    public let danceability: Int?
    public let instrumentalness: Int?
    public let liveness: Int?
    public let speechiness: Int?
    public let valence: Int?
    public let complexity: Int?
    public let semanticTags: [SemanticTagPayload]
    public let mode: String
    public let confidence: Double

    private enum CodingKeys: String, CodingKey {
        case id, moods, scenes, themes, genres, styles, vocals, instruments, textures, rhythms
        case energy, tempo, acousticness, danceability, instrumentalness, liveness
        case speechiness, valence, complexity, semanticTags, mode, confidence
    }

    public init(
        id: String,
        moods: [String] = [],
        scenes: [String] = [],
        themes: [String] = [],
        genres: [String] = [],
        styles: [String] = [],
        vocals: [String] = [],
        instruments: [String] = [],
        textures: [String] = [],
        rhythms: [String] = [],
        energy: Int? = nil,
        tempo: Int? = nil,
        acousticness: Int? = nil,
        danceability: Int? = nil,
        instrumentalness: Int? = nil,
        liveness: Int? = nil,
        speechiness: Int? = nil,
        valence: Int? = nil,
        complexity: Int? = nil,
        semanticTags: [SemanticTagPayload] = [],
        mode: String = "full",
        confidence: Double = 0.5
    ) {
        self.id = id
        self.moods = moods
        self.scenes = scenes
        self.themes = themes
        self.genres = genres
        self.styles = styles
        self.vocals = vocals
        self.instruments = instruments
        self.textures = textures
        self.rhythms = rhythms
        self.energy = energy
        self.tempo = tempo
        self.acousticness = acousticness
        self.danceability = danceability
        self.instrumentalness = instrumentalness
        self.liveness = liveness
        self.speechiness = speechiness
        self.valence = valence
        self.complexity = complexity
        self.semanticTags = semanticTags
        self.mode = mode
        self.confidence = confidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        moods = try Self.decodeStringArray(.moods, from: container)
        scenes = try Self.decodeStringArray(.scenes, from: container)
        themes = try Self.decodeStringArray(.themes, from: container)
        genres = try Self.decodeStringArray(.genres, from: container)
        styles = try Self.decodeStringArray(.styles, from: container)
        vocals = try Self.decodeStringArray(.vocals, from: container)
        instruments = try Self.decodeStringArray(.instruments, from: container)
        textures = try Self.decodeStringArray(.textures, from: container)
        rhythms = try Self.decodeStringArray(.rhythms, from: container)
        energy = try container.decodeIfPresent(Int.self, forKey: .energy)
        tempo = try container.decodeIfPresent(Int.self, forKey: .tempo)
        acousticness = try container.decodeIfPresent(Int.self, forKey: .acousticness)
        danceability = try container.decodeIfPresent(Int.self, forKey: .danceability)
        instrumentalness = try container.decodeIfPresent(Int.self, forKey: .instrumentalness)
        liveness = try container.decodeIfPresent(Int.self, forKey: .liveness)
        speechiness = try container.decodeIfPresent(Int.self, forKey: .speechiness)
        valence = try container.decodeIfPresent(Int.self, forKey: .valence)
        complexity = try container.decodeIfPresent(Int.self, forKey: .complexity)
        semanticTags = try container.decodeIfPresent([SemanticTagPayload].self, forKey: .semanticTags) ?? []
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "full"
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }

    /// Explicit legacy-to-v3 projection. Semantic tags and mode are discarded.
    public var fixedTaxonomyClassification: RecommendationIndexClassification {
        RecommendationIndexClassification(
            id: id,
            moods: moods,
            scenes: scenes,
            energy: energy,
            tempo: tempo,
            acousticness: acousticness,
            danceability: danceability,
            vocals: vocals,
            textures: textures,
            styles: styles,
            confidence: confidence,
            themes: themes,
            genres: genres,
            instruments: instruments,
            rhythms: rhythms,
            instrumentalness: instrumentalness,
            liveness: liveness,
            speechiness: speechiness,
            valence: valence,
            complexity: complexity
        )
    }

    private static func decodeStringArray(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        guard container.contains(key) else { return [] }
        if try container.decodeNil(forKey: key) { return [] }
        if let values = try? container.decode([String].self, forKey: key) {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let scalar = try? container.decode(String.self, forKey: key) {
            let normalized = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? [] : [normalized]
        }
        throw DecodingError.typeMismatch(
            [String].self,
            DecodingError.Context(
                codingPath: container.codingPath + [key],
                debugDescription: "\(key.stringValue) 必须是 string 或 string[]"
            )
        )
    }
}

public struct RecommendationIndexStatus: Sendable, Hashable {
    public let totalTracks: Int
    public let indexedTracks: Int
    public let pendingTracks: Int
    public let rulesVersion: String
    /// 至少有一项固定 taxonomy 工作尚未完成的唯一歌曲数。
    public let pendingUniqueTracks: Int

    public init(
        totalTracks: Int,
        indexedTracks: Int,
        pendingTracks: Int,
        rulesVersion: String,
        pendingUniqueTracks: Int = 0
    ) {
        self.totalTracks = totalTracks
        self.indexedTracks = indexedTracks
        self.pendingTracks = pendingTracks
        self.rulesVersion = rulesVersion
        self.pendingUniqueTracks = pendingUniqueTracks
    }

    /// Legacy v2 projections. They are intentionally not stored in the v3
    /// status model and never participate in runtime completion or batching.
    @available(*, deprecated, message: "Open semantic tags are not part of Recommendation Index v3")
    public var semanticTagRulesVersion: Int { 0 }

    @available(*, deprecated, message: "Open semantic tags are not part of Recommendation Index v3")
    public var semanticTaggedTracks: Int { 0 }

    @available(*, deprecated, message: "Open semantic tags are not part of Recommendation Index v3")
    public var semanticProcessedTracks: Int { 0 }

    @available(*, deprecated, message: "Open semantic tags are not part of Recommendation Index v3")
    public var pendingSemanticTagTracks: Int { 0 }
}

public struct RecommendationIndexBatch: Sendable, Hashable {
    public let tracks: [CatalogTrackLine]
    /// 固定分类待处理歌曲数。
    public let pendingFixedTracks: Int
    /// 至少有一项工作尚未完成的唯一歌曲数（不重复计数）。
    public let pendingUniqueTracks: Int
    public let rulesVersion: String

    @available(*, deprecated, message: "Use pendingUniqueTracks")
    public var pendingTracks: Int { pendingUniqueTracks }

    /// Legacy v2 projection. The v3 runtime never reads this field.
    @available(*, deprecated, message: "Open semantic tags are not part of Recommendation Index v3")
    public var pendingSemanticTagTracks: Int { 0 }

    /// Legacy v2 projection. The v3 runtime has one fixed-taxonomy mode.
    @available(*, deprecated, message: "Recommendation Index v3 has one fixed-taxonomy classification mode")
    public var mode: String { pendingUniqueTracks == 0 ? "done" : "full" }

    public init(
        tracks: [CatalogTrackLine],
        pendingFixedTracks: Int,
        pendingUniqueTracks: Int,
        rulesVersion: String
    ) {
        self.tracks = tracks
        self.pendingFixedTracks = pendingFixedTracks
        self.pendingUniqueTracks = pendingUniqueTracks
        self.rulesVersion = rulesVersion
    }

    /// Source-compatible v2 initializer. Its semantic work and mode values
    /// are deliberately discarded instead of entering the v3 runtime state.
    @available(*, deprecated, message: "Use the fixed-taxonomy RecommendationIndexBatch initializer")
    public init(
        tracks: [CatalogTrackLine],
        pendingFixedTracks: Int,
        pendingSemanticTagTracks: Int,
        pendingUniqueTracks: Int,
        rulesVersion: String,
        mode: String = "full"
    ) {
        _ = (pendingSemanticTagTracks, mode)
        self.init(
            tracks: tracks,
            pendingFixedTracks: pendingFixedTracks,
            pendingUniqueTracks: pendingUniqueTracks,
            rulesVersion: rulesVersion
        )
    }
}

/// 一条已完成的推荐索引记录。仅含本地元数据和分类标签，不含歌词、路径或播放地址。
public struct RecommendationIndexIndexedTrack: Codable, Sendable, Hashable {
    public let track: CatalogTrackLine
    public let tags: [String: [String]]
    public let confidence: Double

    public init(track: CatalogTrackLine, tags: [String: [String]], confidence: Double) {
        self.track = track
        self.tags = tags
        self.confidence = confidence
    }
}

/// 推荐索引的一个可浏览分类（例如「场景 · 通勤」或「情绪 · 平静」）。
public struct RecommendationIndexCategory: Sendable, Hashable, Identifiable {
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

/// Structured Recommendation Index query used by Agent recommendation. Tags are
/// stable taxonomy IDs. Include is a hard filter; prefer is a ranking boost;
/// exclude removes or heavily penalizes matching tracks.
public struct RecommendationIndexQuery: Sendable, Hashable {
    public var includeTags: [String]
    public var preferTags: [String]
    public var excludeTags: [String]
    public var energyRange: ClosedRange<Int>?
    public var tempoRange: ClosedRange<Int>?
    public var danceabilityRange: ClosedRange<Int>?
    public var acousticnessRange: ClosedRange<Int>?
    public var instrumentalnessRange: ClosedRange<Int>?
    public var valenceRange: ClosedRange<Int>?
    public var limit: Int

    public init(
        includeTags: [String] = [],
        preferTags: [String] = [],
        excludeTags: [String] = [],
        energyRange: ClosedRange<Int>? = nil,
        tempoRange: ClosedRange<Int>? = nil,
        danceabilityRange: ClosedRange<Int>? = nil,
        acousticnessRange: ClosedRange<Int>? = nil,
        instrumentalnessRange: ClosedRange<Int>? = nil,
        valenceRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) {
        self.includeTags = includeTags
        self.preferTags = preferTags
        self.excludeTags = excludeTags
        self.energyRange = energyRange
        self.tempoRange = tempoRange
        self.danceabilityRange = danceabilityRange
        self.acousticnessRange = acousticnessRange
        self.instrumentalnessRange = instrumentalnessRange
        self.valenceRange = valenceRange
        self.limit = min(max(limit, 1), 200)
    }
}

/// Legacy open semantic-tag page compatibility surface. Fixed taxonomy v3
/// no longer exposes or produces dimension='tag' rows.
@available(*, deprecated, message: "Open semantic tags are no longer used")
public struct RecommendationIndexTagPage: Sendable, Hashable {
    public let items: [RecommendationIndexCategory]
    /// 下一页起始 offset；nil 表示没有更多。
    public let nextOffset: Int?
    public let hasMore: Bool

    public init(items: [RecommendationIndexCategory], nextOffset: Int?, hasMore: Bool) {
        self.items = items
        self.nextOffset = nextOffset
        self.hasMore = hasMore
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
