import Domain
import Foundation

/// Navidrome 的 ID 字段有时返回 Int（如 `"id": 1`），有时返回 String。
/// 这个类型兼容两种 JSON 值，统一解码成 String。
struct FlexibleString: Decodable, Hashable, Sendable {
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            value = String(d)
        } else {
            value = ""
        }
    }
}

public struct OpenSubsonicServerInfo: Codable, Hashable, Sendable {
    public let protocolVersion: String?
    public let serverType: String?
    public let serverVersion: String?
    public let isOpenSubsonic: Bool

    public init(
        protocolVersion: String? = nil,
        serverType: String? = nil,
        serverVersion: String? = nil,
        isOpenSubsonic: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.serverType = serverType
        self.serverVersion = serverVersion
        self.isOpenSubsonic = isOpenSubsonic
    }
}

public struct OpenSubsonicMusicFolder: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct OpenSubsonicArtistDetail: Hashable, Sendable {
    public let artist: Artist
    public let albums: [Album]

    public init(artist: Artist, albums: [Album]) {
        self.artist = artist
        self.albums = albums
    }
}

public struct OpenSubsonicAlbumDetail: Hashable, Sendable {
    public let album: Album
    public let tracks: [Track]

    public init(album: Album, tracks: [Track]) {
        self.album = album
        self.tracks = tracks
    }
}

public struct OpenSubsonicStarred: Hashable, Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let tracks: [Track]

    public init(artists: [Artist], albums: [Album], tracks: [Track]) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }
}

public struct OpenSubsonicSearchResult: Hashable, Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let tracks: [Track]

    public init(artists: [Artist], albums: [Album], tracks: [Track]) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }
}

public struct OpenSubsonicPlaylistDetail: Hashable, Sendable {
    public let playlist: Playlist
    public let tracks: [Track]

    public init(playlist: Playlist, tracks: [Track]) {
        self.playlist = playlist
        self.tracks = tracks
    }
}

public struct OpenSubsonicPlayQueue: Hashable, Sendable {
    public let tracks: [Track]
    public let currentTrackID: TrackID?
    public let positionMilliseconds: Int?

    public init(tracks: [Track], currentTrackID: TrackID?, positionMilliseconds: Int?) {
        self.tracks = tracks
        self.currentTrackID = currentTrackID
        self.positionMilliseconds = positionMilliseconds
    }
}

public enum OpenSubsonicAlbumListType: String, CaseIterable, Sendable {
    case random
    case newest
    case highest
    case frequent
    case recent
    case alphabeticalByName
    case alphabeticalByArtist
    case starred
    case byYear
    case byGenre
}

public enum OpenSubsonicFavoriteTarget: Hashable, Sendable {
    case track(TrackID)
    case album(AlbumID)
    case artist(ArtistID)

    var parameter: OpenSubsonicParameter {
        switch self {
        case let .track(id): .init("id", id.rawValue)
        case let .album(id): .init("albumId", id.rawValue)
        case let .artist(id): .init("artistId", id.rawValue)
        }
    }
}

struct OpenSubsonicEnvelope: Decodable {
    let response: OpenSubsonicResponseDTO

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct OpenSubsonicResponseDTO: Decodable {
    let status: String?
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: OpenSubsonicErrorDTO?
    let openSubsonicExtensions: [OpenSubsonicExtension]?
    let musicFolders: MusicFoldersDTO?
    let artists: ArtistsDTO?
    let artist: ArtistDTO?
    let album: AlbumDTO?
    let song: SongDTO?
    let genres: GenresDTO?
    let albumList2: AlbumsDTO?
    let randomSongs: SongsDTO?
    let starred2: SearchCollectionDTO?
    let searchResult3: SearchCollectionDTO?
    let playlists: PlaylistsDTO?
    let playlist: PlaylistDTO?
    let lyricsList: LyricsListDTO?
    let lyrics: LyricsDTO?
    let playQueue: PlayQueueDTO?
    let similarSongs2: SongsDTO?
}

struct OpenSubsonicErrorDTO: Decodable {
    let code: Int
    let message: String?
    let helpUrl: String?

    var domainValue: OpenSubsonicServerError {
        OpenSubsonicServerError(
            code: code,
            message: message ?? "Server request failed",
            helpURL: helpUrl.flatMap(URL.init(string:))
        )
    }
}

struct MusicFoldersDTO: Decodable {
    let musicFolder: [MusicFolderDTO]?
}

struct MusicFolderDTO: Decodable {
    let id: FlexibleString
    let name: String
}

struct ArtistsDTO: Decodable {
    let ignoredArticles: String?
    let index: [ArtistIndexDTO]?
}

struct ArtistIndexDTO: Decodable {
    let name: String?
    let artist: [ArtistDTO]?
}

struct ArtistDTO: Decodable {
    let id: FlexibleString
    let name: String?
    let albumCount: Int?
    let coverArt: String?
    let album: [AlbumDTO]?
    let starred: String?
    let userRating: Int?
}

struct AlbumDTO: Decodable {
    let id: FlexibleString
    let name: String?
    let title: String?
    let album: String?
    let artist: String?
    let artistId: FlexibleString?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let songCount: Int?
    let song: [SongDTO]?
    let starred: String?
    let userRating: Int?
}

struct SongDTO: Decodable {
    let id: FlexibleString
    let title: String?
    let name: String?
    let artist: String?
    let artistId: FlexibleString?
    let album: String?
    let albumId: FlexibleString?
    let duration: Double?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let genres: [ItemGenreDTO]?
    let coverArt: String?
    let suffix: String?
    let contentType: String?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let starred: String?
    let userRating: Int?
    let replayGain: ReplayGainDTO?
}

struct ReplayGainDTO: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
    let baseGain: Double?
    let fallbackGain: Double?
}

struct ItemGenreDTO: Decodable {
    let name: String?
    let value: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let string = try? single.decode(String.self) {
            name = string
            value = string
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
    }

    var displayValue: String? { name ?? value }
}

struct GenresDTO: Decodable {
    let genre: [GenreDTO]?
}

struct GenreDTO: Decodable {
    let songCount: Int?
    let albumCount: Int?
    let value: String

    enum CodingKeys: String, CodingKey {
        case songCount
        case albumCount
        case value
    }
}

struct AlbumsDTO: Decodable {
    let album: [AlbumDTO]?
}

struct SongsDTO: Decodable {
    let song: [SongDTO]?
}

struct SearchCollectionDTO: Decodable {
    let artist: [ArtistDTO]?
    let album: [AlbumDTO]?
    let song: [SongDTO]?
}

struct PlaylistsDTO: Decodable {
    let playlist: [PlaylistDTO]?
}

struct PlaylistDTO: Decodable {
    let id: FlexibleString
    let name: String?
    let comment: String?
    /// Subsonic `playlist` 条目的必填/常用元数据。getPlaylists 的真实歌单由
    /// Navidrome / gonic / Ampache 等主流实现返回时总是携带这些字段
    /// （gonic 的 getPlaylists 不含 `duration`），用于识别「分组/文件夹」伪歌单。
    let songCount: Int?
    let created: String?
    let changed: String?
    let entry: [SongDTO]?
}

extension PlaylistDTO {
    /// 在整批 `getPlaylists` 条目里，是否应把该条目当作「分组/文件夹」伪歌单过滤掉。
    ///
    /// 协议事实：Subsonic 的 `playlist` 条目必含 `songCount`/`duration`/`created`/`changed`
    /// 等必填字段；「分组/文件夹（playlist folders）」并不是 Subsonic/OpenSubsonic
    /// 协议的一部分（OpenSubsonic 提案 #14/#75 尚未标准化，Navidrome 亦未实现），
    /// 标准服务器不会在 `getPlaylists` 里返回它们。但个别服务器/代理会把文件夹当作
    /// 伪歌单返回，通常表现为：只有 `id`/`name`（缺失真实歌单的必填元数据），或
    /// 带有歌单字段但没有任何曲目且名称符合文件夹命名。
    ///
    /// 过滤规则（保守，优先保真实歌单，尤其用户手动创建的真实空歌单）：
    /// 1. 结构规则：仅当响应中「确实存在」携带必填元数据的条目（说明服务器按规范给
    ///    真实歌单带 `songCount`/`created`/`changed`）时才生效——此时三者全缺的条目
    ///    不是真实歌单，直接丢弃。若整个响应都没有这些字段（极小众服务器只返回
    ///    id/name/comment），则不适用结构规则，避免误杀真实歌单。
    /// 2. 命名规则：仅当「没有曲目（entry 缺失/为空 且 songCount<=0）且名称命中文件夹
    ///    特征词（中文「分组/文件夹」子串；拉丁 folder/group 整词）」时才丢弃，避免
    ///    误伤带曲目的真实歌单（如 "Group Therapy"）与名称不含特征词的真实空歌单。
    ///
    /// 已知局限：若用户恰好把一个「真实空歌单」命名为 分组/文件夹/folder/group，
    /// 会被当成文件夹过滤——此类名称与文件夹本身无法可靠区分，属保守取舍。
    static func isFolderLike(_ item: PlaylistDTO, among items: [PlaylistDTO]) -> Bool {
        let serverEmitsPlaylistMetadata = items.contains {
            $0.songCount != nil || $0.created != nil || $0.changed != nil
        }
        if serverEmitsPlaylistMetadata {
            let hasNoSongCount = item.songCount == nil
            let hasNoCreated = item.created == nil
            let hasNoChanged = item.changed == nil
            if hasNoSongCount && hasNoCreated && hasNoChanged {
                return true
            }
        }
        // 命名规则：没有曲目（无 entry 且 songCount<=0）才考虑名称特征，避免误伤带曲目歌单。
        let hasTracks = !(item.entry?.isEmpty ?? true) || (item.songCount ?? 0) > 0
        if hasTracks {
            return false
        }
        return Self.matchesFolderName(item.name ?? "")
    }

    private static func matchesFolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("分组") || trimmed.contains("文件夹") {
            return true
        }
        let tokens = trimmed.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }
        return tokens.contains {
            $0 == "folder" || $0 == "folders" || $0 == "group" || $0 == "groups"
        }
    }
}

struct LyricsDTO: Decodable {
    let artist: String?
    let title: String?
    let value: String?
}

struct LyricsListDTO: Decodable {
    let structuredLyrics: [StructuredLyricsDTO]?
}

struct StructuredLyricsDTO: Decodable {
    let displayArtist: String?
    let displayTitle: String?
    let lang: String?
    let synced: Bool?
    let line: [LyricLineDTO]?
}

struct LyricLineDTO: Decodable {
    let start: Int?
    let value: String
}

struct PlayQueueDTO: Decodable {
    let entry: [SongDTO]?
    let current: String?
    let position: Int?
}

struct OpenSubsonicDomainMapper: Sendable {
    let serverID: ServerID

    func artist(_ value: ArtistDTO) -> Artist {
        Artist(
            id: ArtistID(rawValue: value.id.value),
            serverID: serverID,
            name: value.name ?? value.id.value,
            albumCount: value.albumCount ?? value.album?.count ?? 0,
            artworkKey: value.coverArt
        )
    }

    func album(_ value: AlbumDTO) -> Album {
        let title = value.name ?? value.album ?? value.title ?? value.id.value
        let artistName = value.artist ?? ""
        return Album(
            id: AlbumID(rawValue: value.id.value),
            serverID: serverID,
            artistID: ArtistID(rawValue: value.artistId?.value ?? legacyID(prefix: "artist", value: artistName)),
            title: title,
            artistName: artistName,
            year: value.year,
            genre: value.genre,
            artworkKey: value.coverArt,
            songCount: value.songCount
        )
    }

    func track(_ value: SongDTO) -> Track {
        let artistName = value.artist ?? ""
        let albumTitle = value.album ?? ""
        let nestedGenres = value.genres?.compactMap(\.displayValue) ?? []
        let genres = nestedGenres.isEmpty ? value.genre.map { [$0] } ?? [] : nestedGenres

        return Track(
            id: TrackID(rawValue: value.id.value),
            serverID: serverID,
            albumID: AlbumID(rawValue: value.albumId?.value ?? legacyID(prefix: "album", value: albumTitle)),
            artistID: ArtistID(rawValue: value.artistId?.value ?? legacyID(prefix: "artist", value: artistName)),
            title: value.title ?? value.name ?? value.id.value,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: value.duration ?? 0,
            trackNumber: value.track,
            discNumber: value.discNumber,
            year: value.year,
            genres: genres,
            isFavorite: value.starred != nil,
            rating: value.userRating,
            artworkKey: value.coverArt,
            sourceInfo: AudioSourceInfo(
                codec: value.suffix ?? value.contentType,
                bitDepth: value.bitDepth,
                sampleRate: value.samplingRate,
                bitRate: value.bitRate,
                channelCount: value.channelCount,
                replayGain: value.replayGain.map {
                    ReplayGainMetadata(
                        trackGainDB: $0.trackGain,
                        albumGainDB: $0.albumGain,
                        trackPeak: $0.trackPeak,
                        albumPeak: $0.albumPeak,
                        baseGainDB: $0.baseGain,
                        fallbackGainDB: $0.fallbackGain
                    )
                }
            )
        )
    }

    func playlist(_ value: PlaylistDTO) -> Playlist {
        Playlist(
            id: PlaylistID(rawValue: value.id.value),
            serverID: serverID,
            name: value.name ?? value.id.value,
            trackIDs: (value.entry ?? []).map { TrackID(rawValue: $0.id.value) },
            comment: value.comment,
            modifiedAt: playlistChangedDate(value.changed)
        )
    }

    /// OpenSubsonic 的 playlist.changed 是 ISO-8601 字符串。少数服务器会省略
    /// 小数秒，因此同时尝试带/不带小数秒的标准格式；无法解析时保留 nil，
    /// 合并逻辑将安全地回退到服务器数据而不是猜测一个时间。
    private func playlistChangedDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func legacyID(prefix: String, value: String) -> String {
        "legacy-\(prefix):\(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))"
    }
}
