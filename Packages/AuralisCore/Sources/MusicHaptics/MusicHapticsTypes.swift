import Domain
import Foundation

public enum MusicHapticsPCMSampleType: String, Codable, Hashable, Sendable {
    case float32
    case int16
    case int24
    case int32
}

/// Describes the decoded PCM layout handed from an audio tap to the haptics
/// analyzer.  `bytesPerFrame` is the complete frame stride (all channels),
/// while `bytesPerSample` is the stride of one channel sample.  For
/// non-interleaved PCM, the payload is laid out as one complete channel plane
/// after another.
public struct MusicHapticsPCMFormat: Hashable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let sampleType: MusicHapticsPCMSampleType
    public let interleaved: Bool
    public let bytesPerFrame: Int
    public let bytesPerSample: Int
    public let isBigEndian: Bool

    public init?(
        sampleRate: Double,
        channels: Int,
        sampleType: MusicHapticsPCMSampleType,
        interleaved: Bool,
        bytesPerFrame: Int,
        bytesPerSample: Int,
        isBigEndian: Bool = false
    ) {
        guard sampleRate.isFinite, sampleRate > 0,
              channels > 0,
              bytesPerFrame > 0,
              bytesPerSample > 0,
              bytesPerFrame >= bytesPerSample * channels
        else { return nil }
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleType = sampleType
        self.interleaved = interleaved
        self.bytesPerFrame = bytesPerFrame
        self.bytesPerSample = bytesPerSample
        self.isBigEndian = isBigEndian
    }

    public var isValid: Bool {
        switch sampleType {
        case .float32: bytesPerSample == MemoryLayout<Float32>.size
        case .int16: bytesPerSample == MemoryLayout<Int16>.size
        case .int24: bytesPerSample == 3
        case .int32: bytesPerSample == MemoryLayout<Int32>.size
        }
    }
}

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
    /// Optional provenance from the external identity matcher. MusicHaptics
    /// keeps these as primitive values so the runtime does not depend on the
    /// LocalCatalog module, while diagnostics can still explain why an ISRC
    /// was or was not trusted.
    public var identityMatchMethod: String?
    public var identityMatchConfidence: Double?
    public var identityMatcherRevision: Int?

    public init(
        globalID: String? = nil,
        serverID: String? = nil,
        remoteID: String? = nil,
        isrc: String? = nil,
        recordingMBID: String? = nil,
        title: String,
        artist: String,
        album: String? = nil,
        durationMilliseconds: Int,
        identityMatchMethod: String? = nil,
        identityMatchConfidence: Double? = nil,
        identityMatcherRevision: Int? = nil
    ) {
        self.globalID = globalID
        self.serverID = serverID
        self.remoteID = remoteID
        self.isrc = Self.normalizedISRC(isrc)
        self.recordingMBID = Self.normalizedCode(recordingMBID)
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.identityMatchMethod = identityMatchMethod
        self.identityMatchConfidence = identityMatchConfidence
        self.identityMatcherRevision = identityMatcherRevision
    }

    public init(
        track: Track,
        isrc: String? = nil,
        recordingMBID: String? = nil,
        identityMatchMethod: String? = nil,
        identityMatchConfidence: Double? = nil,
        identityMatcherRevision: Int? = nil
    ) {
        self.init(
            globalID: "\(track.serverID.rawValue):\(track.id.rawValue)",
            serverID: track.serverID.rawValue,
            remoteID: track.id.rawValue,
            isrc: isrc,
            recordingMBID: recordingMBID,
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle,
            durationMilliseconds: Int((track.duration * 1_000).rounded()),
            identityMatchMethod: identityMatchMethod,
            identityMatchConfidence: identityMatchConfidence,
            identityMatcherRevision: identityMatcherRevision
        )
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

    private static func normalizedISRC(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.uppercased().unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90: return true
            default: return false
            }
        }
        guard scalars.count == 12,
              scalars.prefix(2).allSatisfy({ (65...90).contains($0.value) }),
              scalars.suffix(7).allSatisfy({ (48...57).contains($0.value) })
        else { return nil }
        return scalars.reduce(into: "") { result, scalar in
            result.unicodeScalars.append(scalar)
        }
    }
}

public enum TrackHapticsPreference: String, Codable, CaseIterable, Sendable {
    case inherit, enabled, disabled

    public func effective(globalEnabled: Bool) -> Bool {
        switch self { case .inherit: globalEnabled; case .enabled: true; case .disabled: false }
    }

    /// Converts the playback-page Boolean into the persisted three-state
    /// preference without losing inheritance when the requested value already
    /// matches the global setting.
    public static func preference(for desiredEnabled: Bool, globalEnabled: Bool) -> Self {
        desiredEnabled == globalEnabled
            ? .inherit
            : (desiredEnabled ? .enabled : .disabled)
    }
}

public enum MusicHapticsEventKind: String, Codable, Sendable { case transient, continuous }

/// Runtime state of the independent original-stream decoder. This is
/// diagnostic state only; it never controls or blocks AVPlayer.
public enum MusicHapticsRemoteDecoderState: String, Codable, Hashable, Sendable {
    case idle
    case opening
    case streaming
    case stalled
    case failed
    case complete
}

/// Which analysis source supplied the event currently preferred by the
/// scheduler. `.mixed` means the lookahead timeline and realtime tap have
/// both contributed non-overlapping coverage during the current playback.
public enum MusicHapticsEventSource: String, Codable, Hashable, Sendable {
    case none
    case remoteOriginal
    case realtimeTap
    case mixed
}

/// The mix and intensity models intentionally live in the data layer.  The
/// first v2 release only exposes `fullMix` to the runtime; `vocalsOnly` is
/// reserved until a reliable vocal-salience source exists.
public enum MusicHapticsMixMode: String, Codable, Hashable, Sendable {
    case fullMix
    case vocalsOnly
}

public enum MusicHapticsIntensity: String, Codable, CaseIterable, Hashable, Sendable {
    case light
    case medium
    case strong

    public var masterIntensity: Float {
        switch self {
        case .light: 0.72
        case .medium: 1.0
        case .strong: 1.12
        }
    }

    /// Fraction of low-energy events retained by the scheduler.  This is a
    /// deterministic class-aware filter, not random thinning.
    public var weakEventFloor: Float {
        switch self {
        case .light: 0.42
        case .medium: 0.18
        case .strong: 0.08
        }
    }

    public var continuousTextureScale: Float {
        switch self {
        case .light: 0.55
        case .medium: 1.0
        case .strong: 1.16
        }
    }
}

public enum MusicHapticsEventClass: String, Codable, Hashable, Sendable {
    case kick
    case bassAttack
    case snareClap
    case highPercussion
    case sustainedBass
    case buildTexture
    case climax
    case unknown

    public var deduplicationWindow: TimeInterval {
        switch self {
        case .kick, .bassAttack: 0.050
        case .snareClap: 0.040
        case .highPercussion: 0.028
        case .sustainedBass, .buildTexture, .climax, .unknown: 0.040
        }
    }
}

public struct MusicHapticsCurvePoint: Codable, Hashable, Sendable {
    public var timeOffset: TimeInterval
    public var intensity: Float
    public var sharpness: Float

    public init(timeOffset: TimeInterval, intensity: Float, sharpness: Float) {
        self.timeOffset = max(0, timeOffset.isFinite ? timeOffset : 0)
        self.intensity = min(max(intensity.isFinite ? intensity : 0, 0), 1)
        self.sharpness = min(max(sharpness.isFinite ? sharpness : 0, 0), 1)
    }
}

public struct MusicHapticsEvent: Codable, Hashable, Sendable {
    public var time: TimeInterval
    public var duration: TimeInterval?
    public var intensity: Float
    public var sharpness: Float
    public var kind: MusicHapticsEventKind
    public var classification: MusicHapticsEventClass
    /// Climax is a perceptual modifier, never an additional voice. The mixer
    /// applies this amount to the selected dominant transient.
    public var climaxAmount: Float
    public var curve: [MusicHapticsCurvePoint]

    public init(
        time: TimeInterval,
        duration: TimeInterval? = nil,
        intensity: Float,
        sharpness: Float,
        kind: MusicHapticsEventKind,
        classification: MusicHapticsEventClass = .unknown,
        climaxAmount: Float = 0,
        curve: [MusicHapticsCurvePoint] = []
    ) {
        self.time = max(0, time)
        self.duration = duration.map { max(0.02, min($0, 20)) }
        self.intensity = min(max(intensity.isFinite ? intensity : 0, 0), 1)
        self.sharpness = min(max(sharpness.isFinite ? sharpness : 0, 0), 1)
        self.kind = kind
        self.classification = classification
        self.climaxAmount = min(max(climaxAmount.isFinite ? climaxAmount : 0, 0), 1)
        self.curve = curve.sorted { $0.timeOffset < $1.timeOffset }
    }

    private enum CodingKeys: String, CodingKey {
        case time, duration, intensity, sharpness, kind, classification, climaxAmount, curve
    }

    /// v1 files did not contain event classes or curves.  Missing fields are
    /// deliberately treated as `.unknown`/empty so old files remain readable;
    /// the plan resolver still rejects their v1 algorithm version.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            time: try container.decode(TimeInterval.self, forKey: .time),
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration),
            intensity: try container.decode(Float.self, forKey: .intensity),
            sharpness: try container.decode(Float.self, forKey: .sharpness),
            kind: try container.decode(MusicHapticsEventKind.self, forKey: .kind),
            classification: try container.decodeIfPresent(MusicHapticsEventClass.self, forKey: .classification) ?? .unknown,
            climaxAmount: try container.decodeIfPresent(Float.self, forKey: .climaxAmount) ?? 0,
            curve: try container.decodeIfPresent([MusicHapticsCurvePoint].self, forKey: .curve) ?? []
        )
    }
}

public struct MusicHapticsTimeline: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public static let legacyAlgorithmVersion = "auralis-haptics-v1"
    /// Bump this whenever perceptual event selection or curve materialization
    /// changes. Stored timelines from an older algorithm deliberately become
    /// cache misses so playback cannot silently mix old and new tactile
    /// semantics.
    /// v2.5 isolates texture controls from attacks and makes low-power DSP
    /// adaptation track elapsed audio time. Reanalyze older cached timelines.
    public static let algorithmVersion = "auralis-haptics-v2.5"
    public var formatVersion: Int
    public var algorithmVersion: String
    public var identity: MusicHapticsIdentity
    public var duration: TimeInterval
    public var createdAt: Date
    public var analyzedDuration: TimeInterval
    public var analysisCoverage: Double
    public var events: [MusicHapticsEvent]
    public var mixMode: MusicHapticsMixMode
    public var tempoBPM: Double?
    public var beatConfidence: Double?
    public var beatPhase: Double?

    public init(
        identity: MusicHapticsIdentity,
        duration: TimeInterval,
        createdAt: Date = .now,
        analyzedDuration: TimeInterval,
        analysisCoverage: Double,
        events: [MusicHapticsEvent],
        formatVersion: Int = MusicHapticsTimeline.formatVersion,
        algorithmVersion: String = MusicHapticsTimeline.algorithmVersion,
        mixMode: MusicHapticsMixMode = .fullMix,
        tempoBPM: Double? = nil,
        beatConfidence: Double? = nil,
        beatPhase: Double? = nil
    ) {
        self.formatVersion = formatVersion
        self.algorithmVersion = algorithmVersion
        self.identity = identity
        self.duration = max(0, duration)
        self.createdAt = createdAt
        self.analyzedDuration = max(0, analyzedDuration)
        self.analysisCoverage = min(max(analysisCoverage, 0), 1)
        self.events = events.sorted { $0.time < $1.time }
        self.mixMode = mixMode
        self.tempoBPM = tempoBPM?.isFinite == true ? tempoBPM : nil
        self.beatConfidence = beatConfidence?.isFinite == true ? min(max(beatConfidence!, 0), 1) : nil
        self.beatPhase = beatPhase?.isFinite == true ? beatPhase : nil
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, algorithmVersion, identity, duration, createdAt
        case analyzedDuration, analysisCoverage, events
        case mixMode, tempoBPM, beatConfidence, beatPhase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identity: try container.decode(MusicHapticsIdentity.self, forKey: .identity),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now,
            analyzedDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .analyzedDuration) ?? 0,
            analysisCoverage: try container.decodeIfPresent(Double.self, forKey: .analysisCoverage) ?? 0,
            events: try container.decodeIfPresent([MusicHapticsEvent].self, forKey: .events) ?? [],
            formatVersion: try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion,
            algorithmVersion: try container.decodeIfPresent(String.self, forKey: .algorithmVersion) ?? Self.legacyAlgorithmVersion,
            mixMode: try container.decodeIfPresent(MusicHapticsMixMode.self, forKey: .mixMode) ?? .fullMix,
            tempoBPM: try container.decodeIfPresent(Double.self, forKey: .tempoBPM),
            beatConfidence: try container.decodeIfPresent(Double.self, forKey: .beatConfidence),
            beatPhase: try container.decodeIfPresent(Double.self, forKey: .beatPhase)
        )
    }

    /// A stored timeline is full only when its normalized coverage reaches the
    /// end of the recording. Do not promote a 95% checkpoint and lose the
    /// final uncovered region.
    public var isComplete: Bool {
        duration <= 0 || (analysisCoverage >= 0.999 && analyzedDuration >= duration - 0.02)
    }
}

public struct MusicHapticsUsage: Sendable, Equatable {
    public var transientBytes: Int64
    public var favoriteBytes: Int64
    public init(transientBytes: Int64 = 0, favoriteBytes: Int64 = 0) { self.transientBytes = transientBytes; self.favoriteBytes = favoriteBytes }
}

