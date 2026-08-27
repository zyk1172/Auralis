import Domain
import Foundation

/// Privacy-safe identity used to bind a timeline to the correct recording.
public struct MusicHapticsIdentity: Codable, Hashable, Sendable {
    public var globalID: String?
    public var serverID: String?
    public var remoteID: String?
    public var isrc: String?
    public var recordingMBID: String?
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMilliseconds: Int

    public init(globalID: String? = nil, serverID: String? = nil, remoteID: String? = nil, isrc: String? = nil, recordingMBID: String? = nil, title: String, artist: String, album: String? = nil, durationMilliseconds: Int) {
        self.globalID = globalID
        self.serverID = serverID
        self.remoteID = remoteID
        self.isrc = Self.normalizedCode(isrc)
        self.recordingMBID = Self.normalizedCode(recordingMBID)
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMilliseconds = max(0, durationMilliseconds)
    }

    public init(track: Track, isrc: String? = nil, recordingMBID: String? = nil) {
        self.init(globalID: "\(track.serverID.rawValue):\(track.id.rawValue)", serverID: track.serverID.rawValue, remoteID: track.id.rawValue, isrc: isrc, recordingMBID: recordingMBID, title: track.title, artist: track.artistName, album: track.albumTitle, durationMilliseconds: Int((track.duration * 1_000).rounded()))
    }

    public var stableKey: String {
        if let isrc { return "isrc:\(isrc)" }
        if let recordingMBID { return "mbid:\(recordingMBID)" }
        if let globalID { return "gid:\(globalID)" }
        return "meta:\(Self.normalized(title))|\(Self.normalized(artist))|\(durationMilliseconds)"
    }

    public func matchConfidence(with candidate: MusicHapticsIdentity) -> Double {
        guard durationIsCompatible(with: candidate) else { return 0 }
        if let isrc, isrc == candidate.isrc { return 1 }
        if let recordingMBID, recordingMBID == candidate.recordingMBID { return 0.98 }
        if let globalID, globalID == candidate.globalID { return 0.96 }
        guard Self.normalized(title) == Self.normalized(candidate.title), Self.normalized(artist) == Self.normalized(candidate.artist) else { return 0 }
        return album.map(Self.normalized) == candidate.album.map(Self.normalized) ? 0.90 : 0.82
    }

    public func durationIsCompatible(with candidate: MusicHapticsIdentity) -> Bool {
        let larger = max(durationMilliseconds, candidate.durationMilliseconds)
        return larger == 0 || abs(durationMilliseconds - candidate.durationMilliseconds) <= max(2_000, Int(Double(larger) * 0.01))
    }

    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func normalizedCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return result.isEmpty ? nil : result
    }
}

public enum TrackHapticsPreference: String, Codable, CaseIterable, Sendable {
    case inherit, enabled, disabled

    public func effective(globalEnabled: Bool) -> Bool {
        switch self { case .inherit: globalEnabled; case .enabled: true; case .disabled: false }
    }
}

public enum MusicHapticsEventKind: String, Codable, Sendable { case transient, continuous }

public struct MusicHapticsEvent: Codable, Hashable, Sendable {
    public var time: TimeInterval
    public var duration: TimeInterval?
    public var intensity: Float
    public var sharpness: Float
    public var kind: MusicHapticsEventKind

    public init(time: TimeInterval, duration: TimeInterval? = nil, intensity: Float, sharpness: Float, kind: MusicHapticsEventKind) {
        self.time = max(0, time)
        self.duration = duration.map { max(0.02, min($0, 20)) }
        self.intensity = min(max(intensity, 0), 1)
        self.sharpness = min(max(sharpness, 0), 1)
        self.kind = kind
    }
}

public struct MusicHapticsTimeline: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public static let algorithmVersion = "auralis-haptics-v1"
    public var formatVersion: Int
    public var algorithmVersion: String
    public var identity: MusicHapticsIdentity
    public var duration: TimeInterval
    public var createdAt: Date
    public var analyzedDuration: TimeInterval
    public var analysisCoverage: Double
    public var events: [MusicHapticsEvent]

    public init(identity: MusicHapticsIdentity, duration: TimeInterval, createdAt: Date = .now, analyzedDuration: TimeInterval, analysisCoverage: Double, events: [MusicHapticsEvent], formatVersion: Int = MusicHapticsTimeline.formatVersion, algorithmVersion: String = MusicHapticsTimeline.algorithmVersion) {
        self.formatVersion = formatVersion
        self.algorithmVersion = algorithmVersion
        self.identity = identity
        self.duration = max(0, duration)
        self.createdAt = createdAt
        self.analyzedDuration = max(0, analyzedDuration)
        self.analysisCoverage = min(max(analysisCoverage, 0), 1)
        self.events = events.sorted { $0.time < $1.time }
    }

    public var isComplete: Bool { analysisCoverage >= 0.95 }
}

public struct MusicHapticsUsage: Sendable, Equatable {
    public var transientBytes: Int64
    public var favoriteBytes: Int64
    public init(transientBytes: Int64 = 0, favoriteBytes: Int64 = 0) { self.transientBytes = transientBytes; self.favoriteBytes = favoriteBytes }
}
