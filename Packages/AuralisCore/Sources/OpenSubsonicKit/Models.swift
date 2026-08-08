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
    let entry: [SongDTO]?
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
            artworkKey: value.coverArt
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
                channelCount: value.channelCount
            )
        )
    }

    func playlist(_ value: PlaylistDTO) -> Playlist {
        Playlist(
            id: PlaylistID(rawValue: value.id.value),
            serverID: serverID,
            name: value.name ?? value.id.value,
            trackIDs: (value.entry ?? []).map { TrackID(rawValue: $0.id.value) },
            comment: value.comment
        )
    }

    private func legacyID(prefix: String, value: String) -> String {
        "legacy-\(prefix):\(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))"
    }
}
