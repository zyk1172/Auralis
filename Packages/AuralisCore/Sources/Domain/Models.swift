import Foundation

public struct ServerID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct ArtistID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct AlbumID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct TrackID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct PlaylistID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct ServerAccount: Codable, Hashable, Sendable, Identifiable {
    public let id: ServerID
    public var displayName: String
    public var baseURL: URL?
    public var username: String?
    public var credentialReference: String?

    public init(
        id: ServerID,
        displayName: String,
        baseURL: URL? = nil,
        username: String? = nil,
        credentialReference: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.username = username
        self.credentialReference = credentialReference
    }
}

public struct Artist: Codable, Hashable, Sendable, Identifiable {
    public let id: ArtistID
    public let serverID: ServerID
    public var name: String
    public var albumCount: Int
    public var artworkKey: String?

    public init(id: ArtistID, serverID: ServerID, name: String, albumCount: Int, artworkKey: String? = nil) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.albumCount = albumCount
        self.artworkKey = artworkKey
    }
}

public struct Album: Codable, Hashable, Sendable, Identifiable {
    public let id: AlbumID
    public let serverID: ServerID
    public let artistID: ArtistID
    public var title: String
    public var artistName: String
    public var year: Int?
    public var genre: String?
    public var artworkKey: String?
    /// 服务器报告的专辑曲目数（getAlbumList2 的 songCount）。
    /// 用于轻量比对「网络曲目总数 vs 本地目录曲目数」，判断是否需要重新同步。
    public var songCount: Int?

    public init(
        id: AlbumID,
        serverID: ServerID,
        artistID: ArtistID,
        title: String,
        artistName: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkKey: String? = nil,
        songCount: Int? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.artistID = artistID
        self.title = title
        self.artistName = artistName
        self.year = year
        self.genre = genre
        self.artworkKey = artworkKey
        self.songCount = songCount
    }
}

public struct AudioSourceInfo: Codable, Hashable, Sendable {
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var bitRate: Int?
    public var channelCount: Int?

    public init(codec: String? = nil, bitDepth: Int? = nil, sampleRate: Int? = nil, bitRate: Int? = nil, channelCount: Int? = nil) {
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.channelCount = channelCount
    }

    /// 服务器返回的格式描述（suffix 或 MIME）规整为短名：小写并去掉 "audio/" 前缀。
    /// 例如 "audio/mpeg" → "mpeg"、"FLAC" → "flac"；空值返回 nil。
    public var normalizedCodec: String? {
        guard let raw = codec, !raw.isEmpty else { return nil }
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("audio/") ? String(lower.dropFirst("audio/".count)) : lower
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable {
    public let id: TrackID
    public let serverID: ServerID
    public let albumID: AlbumID
    public let artistID: ArtistID
    public var title: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genres: [String]
    public var language: String?
    public var isFavorite: Bool
    public var rating: Int?
    public var artworkKey: String?
    public var sourceInfo: AudioSourceInfo
    public var streamURL: URL?

    public init(
        id: TrackID,
        serverID: ServerID,
        albumID: AlbumID,
        artistID: ArtistID,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genres: [String] = [],
        language: String? = nil,
        isFavorite: Bool = false,
        rating: Int? = nil,
        artworkKey: String? = nil,
        sourceInfo: AudioSourceInfo = .init(),
        streamURL: URL? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.albumID = albumID
        self.artistID = artistID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genres = genres
        self.language = language
        self.isFavorite = isFavorite
        self.rating = rating
        self.artworkKey = artworkKey
        self.sourceInfo = sourceInfo
        self.streamURL = streamURL
    }

    /// 实际播放/解码的格式（考虑服务器转码与本地缓存）：
    /// - 远程流且流地址带 `format` 参数（蜂窝转码 / 码率限制）→ 返回该转码格式；
    /// - 本地缓存文件（streamURL 为 file URL）→ 返回原始格式（缓存的是原始文件）；
    /// - 其它情况 → 返回原始格式。
    public var effectiveCodec: String? {
        if let streamURL, !streamURL.isFileURL,
           let components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
           let format = components.queryItems?.first(where: { $0.name == "format" })?.value,
           !format.isEmpty {
            return format.lowercased()
        }
        return sourceInfo.normalizedCodec
    }
}

public struct Genre: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name.lowercased() }
    public var name: String
    public var songCount: Int
    public init(name: String, songCount: Int) {
        self.name = name
        self.songCount = songCount
    }
}

public struct Playlist: Codable, Hashable, Sendable, Identifiable {
    public let id: PlaylistID
    public let serverID: ServerID
    public var name: String
    public var trackIDs: [TrackID]
    public var comment: String?

    public init(id: PlaylistID, serverID: ServerID, name: String, trackIDs: [TrackID], comment: String? = nil) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.trackIDs = trackIDs
        self.comment = comment
    }
}

public struct PlayHistory: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let trackID: TrackID
    public var playedAt: Date
    public var completionRatio: Double
    public var wasSkipped: Bool
    public init(id: UUID = UUID(), trackID: TrackID, playedAt: Date, completionRatio: Double, wasSkipped: Bool) {
        self.id = id
        self.trackID = trackID
        self.playedAt = playedAt
        self.completionRatio = completionRatio
        self.wasSkipped = wasSkipped
    }
}

public enum DownloadStatus: String, Codable, Hashable, Sendable {
    case notDownloaded
    case queued
    case downloading
    case downloaded
    case failed
}

public struct DownloadRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: TrackID { trackID }
    public let trackID: TrackID
    public var status: DownloadStatus
    public var progress: Double
    public var byteCount: Int64
    public init(trackID: TrackID, status: DownloadStatus, progress: Double, byteCount: Int64) {
        self.trackID = trackID
        self.status = status
        self.progress = progress
        self.byteCount = byteCount
    }
}

public struct TimedLyricLine: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var startTime: TimeInterval?
    public var text: String
    public var translation: String?
    public init(id: UUID = UUID(), startTime: TimeInterval? = nil, text: String, translation: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.text = text
        self.translation = translation
    }
}

public struct LyricsDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: TrackID { trackID }
    public let trackID: TrackID
    public var language: String?
    public var lines: [TimedLyricLine]
    public var isSynced: Bool
    public init(trackID: TrackID, language: String? = nil, lines: [TimedLyricLine], isSynced: Bool) {
        self.trackID = trackID
        self.language = language
        self.lines = lines
        self.isSynced = isSynced
    }
}

public enum MetadataSource: String, Codable, Hashable, Sendable {
    case server
    case musicBrainz
    case coverArtArchive
    case user
    case artificialIntelligence
}

public struct MetadataOverlay: Codable, Hashable, Sendable, Identifiable {
    public var id: TrackID { trackID }
    public let trackID: TrackID
    public var correctedTitle: String?
    public var correctedArtist: String?
    public var correctedAlbum: String?
    public var albumArtist: String?
    public var releaseYear: Int?
    public var discNumber: Int?
    public var trackNumber: Int?
    public var genres: [String]
    public var moods: [String]
    public var language: String?
    public var composer: String?
    public var lyricist: String?
    public var musicBrainzRecordingID: String?
    public var musicBrainzReleaseID: String?
    public var confidence: Double
    public var provenance: [MetadataSource]

    public init(
        trackID: TrackID,
        correctedTitle: String? = nil,
        correctedArtist: String? = nil,
        correctedAlbum: String? = nil,
        albumArtist: String? = nil,
        releaseYear: Int? = nil,
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        genres: [String] = [],
        moods: [String] = [],
        language: String? = nil,
        composer: String? = nil,
        lyricist: String? = nil,
        musicBrainzRecordingID: String? = nil,
        musicBrainzReleaseID: String? = nil,
        confidence: Double,
        provenance: [MetadataSource]
    ) {
        self.trackID = trackID
        self.correctedTitle = correctedTitle
        self.correctedArtist = correctedArtist
        self.correctedAlbum = correctedAlbum
        self.albumArtist = albumArtist
        self.releaseYear = releaseYear
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.genres = genres
        self.moods = moods
        self.language = language
        self.composer = composer
        self.lyricist = lyricist
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.confidence = confidence
        self.provenance = provenance
    }
}

public struct RecommendationResult: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var explanation: String
    public var trackIDs: [TrackID]
    public var filters: [String]
    public init(id: UUID = UUID(), title: String, explanation: String, trackIDs: [TrackID], filters: [String]) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.trackIDs = trackIDs
        self.filters = filters
    }
}

public struct AudioRouteSnapshot: Codable, Hashable, Sendable {
    public var source: String?
    public var serverMode: String?
    public var decodedFormat: String?
    public var outputRoute: String?
    public var replayGain: String?
    public init(source: String? = nil, serverMode: String? = nil, decodedFormat: String? = nil, outputRoute: String? = nil, replayGain: String? = nil) {
        self.source = source
        self.serverMode = serverMode
        self.decodedFormat = decodedFormat
        self.outputRoute = outputRoute
        self.replayGain = replayGain
    }
}

public enum PlaybackError: Error, Codable, Hashable, Sendable {
    case networkUnavailable
    case unsupportedFormat(String)
    case authorizationFailed
    case engineFailure(String)
}

public enum PlaybackState: Codable, Hashable, Sendable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case stalled
    case failed(PlaybackError)
}

/// 最近一次播放停止的原因（诊断与后台播放审计用）。
/// 区分用户操作、队列结束、服务器/网络/流/解码、系统中断、设备断开、进程终止等场景。
public enum PlaybackStopReason: String, Codable, Hashable, Sendable, CaseIterable {
    case unknown
    case userPaused
    case userStopped
    case queueEnded
    case serverDisconnected
    case networkInterrupted
    case streamExpired
    case decodeFailed
    case audioSessionInterrupted
    case outputDisconnected
    case playerReleased
    case processTerminated

    public var title: String {
        switch self {
        case .unknown: String(localized: "未知")
        case .userPaused: String(localized: "用户主动暂停")
        case .userStopped: String(localized: "用户主动停止")
        case .queueEnded: String(localized: "播放队列结束")
        case .serverDisconnected: String(localized: "服务器连接中断")
        case .networkInterrupted: String(localized: "网络中断")
        case .streamExpired: String(localized: "流地址失效")
        case .decodeFailed: String(localized: "音频解码失败")
        case .audioSessionInterrupted: String(localized: "音频会话中断")
        case .outputDisconnected: String(localized: "输出设备断开")
        case .playerReleased: String(localized: "播放器对象被释放")
        case .processTerminated: String(localized: "App 进程被系统终止")
        }
    }
}

public struct ServerCapabilities: Codable, Hashable, Sendable {
    public var supportsStructuredLyrics: Bool
    public var supportsSonicSimilarity: Bool
    public var supportsIndexedQueue: Bool
    public var supportsPlaybackReport: Bool
    public var supportsTranscoding: Bool
    public var supportsTranscodeOffset: Bool
    public var supportsAPIKeyAuthentication: Bool

    public init(
        supportsStructuredLyrics: Bool = false,
        supportsSonicSimilarity: Bool = false,
        supportsIndexedQueue: Bool = false,
        supportsPlaybackReport: Bool = false,
        supportsTranscoding: Bool = false,
        supportsTranscodeOffset: Bool = false,
        supportsAPIKeyAuthentication: Bool = false
    ) {
        self.supportsStructuredLyrics = supportsStructuredLyrics
        self.supportsSonicSimilarity = supportsSonicSimilarity
        self.supportsIndexedQueue = supportsIndexedQueue
        self.supportsPlaybackReport = supportsPlaybackReport
        self.supportsTranscoding = supportsTranscoding
        self.supportsTranscodeOffset = supportsTranscodeOffset
        self.supportsAPIKeyAuthentication = supportsAPIKeyAuthentication
    }
}
