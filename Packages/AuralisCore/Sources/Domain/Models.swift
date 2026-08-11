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
    /// 局域网优先地址。始终保留用户填写的内网入口，切换网络后可重新优先使用它。
    public var baseURL: URL?
    /// 内网不可用时使用的外网入口；缺省时保持单地址的既有行为。
    public var externalBaseURL: URL?
    public var username: String?
    public var credentialReference: String?

    public init(
        id: ServerID,
        displayName: String,
        baseURL: URL? = nil,
        externalBaseURL: URL? = nil,
        username: String? = nil,
        credentialReference: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.externalBaseURL = externalBaseURL
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
    /// OpenSubsonic ReplayGain metadata. All values are optional because legacy
    /// Subsonic servers and files without tags legitimately omit them.
    public var replayGain: ReplayGainMetadata?

    public init(codec: String? = nil, bitDepth: Int? = nil, sampleRate: Int? = nil, bitRate: Int? = nil, channelCount: Int? = nil, replayGain: ReplayGainMetadata? = nil) {
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.channelCount = channelCount
        self.replayGain = replayGain
    }

    /// 服务器返回的格式描述（suffix 或 MIME）规整为短名：小写并去掉 "audio/" 前缀。
    /// 例如 "audio/mpeg" → "mpeg"、"FLAC" → "flac"；空值返回 nil。
    public var normalizedCodec: String? {
        guard let raw = codec, !raw.isEmpty else { return nil }
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("audio/") ? String(lower.dropFirst("audio/".count)) : lower
    }
}

/// ReplayGain values exposed by OpenSubsonic's `Child.replayGain` object.
/// Gain values are dB; peaks are positive linear full-scale ratios.
public struct ReplayGainMetadata: Codable, Hashable, Sendable {
    public var trackGainDB: Double?
    public var albumGainDB: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?
    public var baseGainDB: Double?
    public var fallbackGainDB: Double?

    public init(
        trackGainDB: Double? = nil,
        albumGainDB: Double? = nil,
        trackPeak: Double? = nil,
        albumPeak: Double? = nil,
        baseGainDB: Double? = nil,
        fallbackGainDB: Double? = nil
    ) {
        self.trackGainDB = trackGainDB
        self.albumGainDB = albumGainDB
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
        self.baseGainDB = baseGainDB
        self.fallbackGainDB = fallbackGainDB
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

/// 同一录音在资料库中可能有多个编码或不同规格的版本。Agent 生成推荐、智能队列时
/// 以这个规则合并，确保高质量音源优先命中，而不会把同一首歌反复塞进结果。
public enum TrackQuality {
    /// 标题、艺人和时长共同构成保守的“同一录音”键。
    /// 时长按 8 秒分桶，容忍不同服务器写入的微小尾部时长差异，避免仅凭歌名误合并翻唱。
    public static func recordingKey(for track: Track) -> String {
        let durationBucket = max(0, Int((track.duration / 8).rounded()))
        return "\(normalized(track.title))|\(normalized(track.artistName))|\(durationBucket)"
    }

    /// 保留原有推荐顺序，但每个录音只保留一个版本；质量相同时才考虑收藏、评分。
    public static func deduplicatedPreferringQuality(_ tracks: [Track]) -> [Track] {
        var result: [Track] = []
        var indexByRecording: [String: Int] = [:]

        for track in tracks {
            let key = recordingKey(for: track)
            if let index = indexByRecording[key] {
                if isPreferred(track, over: result[index]) {
                    result[index] = track
                }
            } else {
                indexByRecording[key] = result.count
                result.append(track)
            }
        }
        return result
    }

    /// DSD > 无损 PCM > 有损；同一档内按位深、采样率、码率和声道数比较。
    public static func isPreferred(_ candidate: Track, over current: Track) -> Bool {
        let candidateScore = score(candidate)
        let currentScore = score(current)
        if candidateScore != currentScore { return candidateScore > currentScore }
        if candidate.isFavorite != current.isFavorite { return candidate.isFavorite }
        if candidate.rating != current.rating { return (candidate.rating ?? 0) > (current.rating ?? 0) }
        return candidate.id.rawValue.localizedStandardCompare(current.id.rawValue) == .orderedAscending
    }

    public static func score(_ track: Track) -> Int64 {
        let codecTier: Int64
        switch track.sourceInfo.normalizedCodec {
        case "dsf", "dff": codecTier = 7
        case "wav", "aiff", "aif": codecTier = 6
        case "flac", "alac", "ape", "wv": codecTier = 5
        case "opus": codecTier = 3
        case "aac", "m4a", "mp4", "ogg", "vorbis": codecTier = 2
        case "mp3", "mpeg": codecTier = 1
        default: codecTier = 0
        }
        let bitDepth = Int64(min(max(track.sourceInfo.bitDepth ?? 0, 0), 64))
        let sampleRate = Int64(min(max(track.sourceInfo.sampleRate ?? 0, 0), 768_000))
        let bitRate = Int64(min(max(track.sourceInfo.bitRate ?? 0, 0), 20_000_000))
        let channels = Int64(min(max(track.sourceInfo.channelCount ?? 0, 0), 16))
        return codecTier * 1_000_000_000_000
            + bitDepth * 1_000_000_000
            + sampleRate * 1_000
            + bitRate
            + channels
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
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
    /// 歌单内容或元数据最后一次修改的时间。由 OpenSubsonic 的 `changed` 提供；
    /// 本地成功编辑后也会立即标记，用于下一次同步的 LWW（最新修改优先）合并。
    public var modifiedAt: Date?

    public init(
        id: PlaylistID,
        serverID: ServerID,
        name: String,
        trackIDs: [TrackID],
        comment: String? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.trackIDs = trackIDs
        self.comment = comment
        self.modifiedAt = modifiedAt
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
