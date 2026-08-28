import Foundation

public enum MusicHapticsSource: Sendable, Equatable {
    case none
    case system
    case custom
    case analyzing
}

/// The one decision made for a track before its AVPlayerItem is created.
/// A plan is descriptive only; the PlaybackEngine decides how to attach the
/// already-created sidecar without delaying audio startup.
public enum MusicHapticsPlanKind: String, Codable, Hashable, Sendable {
    case disabled
    case system
    case custom
    case analyze
    case analyzeLookahead
}

public enum MusicHapticsAnalysisFinishReason: String, Codable, Hashable, Sendable {
    case naturalEnd
    case trackSwitch
    case stopped
    case playbackFailure
    case preparationReplaced
}

/// Codable representation of a real analyzed interval.  Unlike a single
/// maximum position, this preserves holes caused by seeking, buffering or a
/// track switch.
public struct MusicHapticsTimeRange: Codable, Hashable, Sendable {
    public let lowerBound: TimeInterval
    public let upperBound: TimeInterval

    public init(lowerBound: TimeInterval, upperBound: TimeInterval) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var duration: TimeInterval { max(0, upperBound - lowerBound) }
}

public struct MusicHapticsPartialCheckpoint: Codable, Hashable, Sendable {
    public static let formatVersion = 1

    public let formatVersion: Int
    public let identity: MusicHapticsIdentity
    public let algorithmVersion: String
    public let duration: TimeInterval
    public let analyzedRanges: [MusicHapticsTimeRange]
    public let events: [MusicHapticsEvent]
    public let coverage: Double
    public let updatedAt: Date
    public let mixMode: MusicHapticsMixMode?
    public let tempoBPM: Double?
    public let beatConfidence: Double?
    public let beatPhase: Double?

    private enum CodingKeys: String, CodingKey {
        case formatVersion, identity, algorithmVersion, duration
        case analyzedRanges, events, coverage, updatedAt
        case mixMode, tempoBPM, beatConfidence, beatPhase
    }

    public init(
        identity: MusicHapticsIdentity,
        algorithmVersion: String = MusicHapticsTimeline.algorithmVersion,
        duration: TimeInterval,
        analyzedRanges: [MusicHapticsTimeRange],
        events: [MusicHapticsEvent],
        coverage: Double? = nil,
        updatedAt: Date = .now,
        formatVersion: Int = Self.formatVersion,
        mixMode: MusicHapticsMixMode? = .fullMix,
        tempoBPM: Double? = nil,
        beatConfidence: Double? = nil,
        beatPhase: Double? = nil
    ) {
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        self.formatVersion = formatVersion
        self.identity = identity
        self.algorithmVersion = algorithmVersion
        self.duration = safeDuration
        self.analyzedRanges = Self.normalize(analyzedRanges, duration: safeDuration)
        self.events = events
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= safeDuration }
            .sorted { $0.time < $1.time }
        let calculatedCoverage = safeDuration > 0
            ? min(1, self.analyzedRanges.reduce(0) { $0 + $1.duration } / safeDuration)
            : 0
        let suppliedCoverage = min(max(coverage ?? calculatedCoverage, 0), 1)
        // Real ranges are authoritative. A stale/corrupt caller-provided
        // value may conservatively lower coverage, but can never promote a
        // checkpoint beyond the bytes that were actually analyzed.
        self.coverage = min(calculatedCoverage, suppliedCoverage)
        self.updatedAt = updatedAt
        self.mixMode = mixMode
        self.tempoBPM = tempoBPM?.isFinite == true ? tempoBPM : nil
        self.beatConfidence = beatConfidence?.isFinite == true ? min(max(beatConfidence!, 0), 1) : nil
        self.beatPhase = beatPhase?.isFinite == true ? beatPhase : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identity: try container.decode(MusicHapticsIdentity.self, forKey: .identity),
            algorithmVersion: try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
                ?? MusicHapticsTimeline.legacyAlgorithmVersion,
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
            analyzedRanges: try container.decodeIfPresent([MusicHapticsTimeRange].self, forKey: .analyzedRanges) ?? [],
            events: try container.decodeIfPresent([MusicHapticsEvent].self, forKey: .events) ?? [],
            coverage: try container.decodeIfPresent(Double.self, forKey: .coverage),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now,
            formatVersion: try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion,
            mixMode: try container.decodeIfPresent(MusicHapticsMixMode.self, forKey: .mixMode),
            tempoBPM: try container.decodeIfPresent(Double.self, forKey: .tempoBPM),
            beatConfidence: try container.decodeIfPresent(Double.self, forKey: .beatConfidence),
            beatPhase: try container.decodeIfPresent(Double.self, forKey: .beatPhase)
        )
    }

    public var analyzedDuration: TimeInterval {
        analyzedRanges.reduce(0) { $0 + $1.duration }
    }

    public var isComplete: Bool { coverage >= 0.95 }

    public var isCurrentAlgorithm: Bool {
        formatVersion == Self.formatVersion
            && algorithmVersion == MusicHapticsTimeline.algorithmVersion
    }

    /// Returns the first real uncovered position. Ranges after this position
    /// remain meaningful holes and are never collapsed into a max position.
    public var firstUnanalyzedPosition: TimeInterval {
        var cursor: TimeInterval = 0
        for range in analyzedRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > cursor { return cursor }
            cursor = max(cursor, range.upperBound)
        }
        return min(duration, cursor)
    }

    public func timeline() -> MusicHapticsTimeline {
        MusicHapticsTimeline(
            identity: identity,
            duration: duration,
            createdAt: updatedAt,
            analyzedDuration: analyzedDuration,
            analysisCoverage: coverage,
            events: events,
            algorithmVersion: algorithmVersion,
            mixMode: mixMode ?? .fullMix,
            tempoBPM: tempoBPM,
            beatConfidence: beatConfidence,
            beatPhase: beatPhase
        )
    }

    /// Merges two checkpoints for the same recording without collapsing their
    /// coverage to a single high-water mark. This is used when rapid A→B→A
    /// switching lets completion callbacks reach the Store out of order.
    public func merged(with other: MusicHapticsPartialCheckpoint) -> MusicHapticsPartialCheckpoint {
        guard algorithmVersion == other.algorithmVersion,
              identity.matchConfidence(with: other.identity) >= 0.82
        else { return other }

        let mergedIdentity = other.identity
        let mergedAlgorithmVersion = other.algorithmVersion
        let mergedDuration = max(duration, other.duration)
        let mergedRanges = analyzedRanges + other.analyzedRanges
        let mergedEvents = MusicHapticsEventDeduplicator.merge(events + other.events)
        let mergedMixMode = other.mixMode ?? mixMode
        let mergedTempo = other.tempoBPM ?? tempoBPM
        let mergedBeatConfidence = other.beatConfidence ?? beatConfidence
        let mergedBeatPhase = other.beatPhase ?? beatPhase
        let mergedUpdatedAt = max(updatedAt, other.updatedAt)
        let mergedFormatVersion = max(formatVersion, other.formatVersion)

        return MusicHapticsPartialCheckpoint(
            identity: mergedIdentity,
            algorithmVersion: mergedAlgorithmVersion,
            duration: mergedDuration,
            analyzedRanges: mergedRanges,
            events: mergedEvents,
            updatedAt: mergedUpdatedAt,
            formatVersion: mergedFormatVersion,
            mixMode: mergedMixMode,
            tempoBPM: mergedTempo,
            beatConfidence: mergedBeatConfidence,
            beatPhase: mergedBeatPhase
        )
    }

    private static func normalize(
        _ input: [MusicHapticsTimeRange],
        duration: TimeInterval
    ) -> [MusicHapticsTimeRange] {
        var result: [MusicHapticsTimeRange] = []
        for range in input {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { continue }
            let lower = min(max(range.lowerBound, 0), duration)
            let upper = min(max(range.upperBound, 0), duration)
            guard upper > lower else { continue }
            var merged = MusicHapticsTimeRange(lowerBound: lower, upperBound: upper)
            var next: [MusicHapticsTimeRange] = []
            for existing in result.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if existing.upperBound < merged.lowerBound || merged.upperBound < existing.lowerBound {
                    next.append(existing)
                } else {
                    merged = MusicHapticsTimeRange(
                        lowerBound: min(existing.lowerBound, merged.lowerBound),
                        upperBound: max(existing.upperBound, merged.upperBound)
                    )
                }
            }
            next.append(merged)
            result = next.sorted { $0.lowerBound < $1.lowerBound }
        }
        return result
    }
}

public struct MusicHapticsAnalysisRequest: Codable, Hashable, Sendable {
    public let identity: MusicHapticsIdentity
    public let favorite: Bool
    public let duration: TimeInterval
    public let partial: MusicHapticsPartialCheckpoint?
    public let analysisSource: MusicHapticsAnalysisSource
    public let warmupDeadline: Duration

    public init(
        identity: MusicHapticsIdentity,
        favorite: Bool,
        duration: TimeInterval,
        partial: MusicHapticsPartialCheckpoint? = nil,
        analysisSource: MusicHapticsAnalysisSource = .realtimeTap,
        warmupDeadline: Duration = .milliseconds(350)
    ) {
        self.identity = identity
        self.favorite = favorite
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.partial = partial
        self.analysisSource = analysisSource
        self.warmupDeadline = warmupDeadline
    }

    private enum CodingKeys: String, CodingKey {
        case identity, favorite, duration, partial, warmupDeadline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identity: try container.decode(MusicHapticsIdentity.self, forKey: .identity),
            favorite: try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false,
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
            partial: try container.decodeIfPresent(MusicHapticsPartialCheckpoint.self, forKey: .partial),
            // Analysis sources are process-lifetime inputs.  A decoded plan
            // must fall back to a fresh upper-layer source instead of ever
            // reconstructing a stale URL or credential-bearing stream.
            analysisSource: .realtimeTap,
            warmupDeadline: try container.decodeIfPresent(Duration.self, forKey: .warmupDeadline) ?? .milliseconds(350)
        )
    }
}

public enum MusicHapticsPlaybackPlan: Codable, Hashable, Sendable {
    case disabled
    case system
    case custom(MusicHapticsTimeline)
    case analyze(MusicHapticsAnalysisRequest)
    case analyzeLookahead(MusicHapticsAnalysisRequest)

    public var kind: MusicHapticsPlanKind {
        switch self {
        case .disabled: .disabled
        case .system: .system
        case .custom: .custom
        case .analyze: .analyze
        case .analyzeLookahead: .analyzeLookahead
        }
    }

    public var identity: MusicHapticsIdentity? {
        switch self {
        case .disabled, .system: nil
        case let .custom(timeline): timeline.identity
        case let .analyze(request): request.identity
        case let .analyzeLookahead(request): request.identity
        }
    }
}

public struct MusicHapticsSystemAvailability: Codable, Hashable, Sendable {
    public let hasISRC: Bool
    public let active: Bool
    public let timelineAvailable: Bool

    public init(hasISRC: Bool, active: Bool, timelineAvailable: Bool) {
        self.hasISRC = hasISRC
        self.active = active
        self.timelineAvailable = timelineAvailable
    }

    public var canUseTimeline: Bool { hasISRC && active && timelineAvailable }
}

public struct MusicHapticsAnalysisSnapshot: Hashable, Sendable {
    public var tapAttached: Bool
    public var pcmFormat: MusicHapticsPCMFormat?
    public var analyzedRanges: [MusicHapticsTimeRange]
    public var coverage: Double
    public var eventCount: Int
    public var droppedFrames: Int
    public var finishReason: MusicHapticsAnalysisFinishReason?
    public var analysisMode: MusicHapticsAnalysisMode
    /// Requested server-side transcode ceiling only; never a URL or token.
    public var analysisStreamBitrate: Int?
    public var analysisPosition: TimeInterval
    public var analysisSpeedX: Double
    public var tempoBPM: Double?
    public var beatConfidence: Double
    public var transientCount: Int
    public var continuousCount: Int
    public var mixerDiagnostics: MusicHapticsMixerDiagnostics

    public init(
        tapAttached: Bool = false,
        pcmFormat: MusicHapticsPCMFormat? = nil,
        analyzedRanges: [MusicHapticsTimeRange] = [],
        coverage: Double = 0,
        eventCount: Int = 0,
        droppedFrames: Int = 0,
        finishReason: MusicHapticsAnalysisFinishReason? = nil,
        analysisMode: MusicHapticsAnalysisMode = .realtimeTap,
        analysisStreamBitrate: Int? = nil,
        analysisPosition: TimeInterval = 0,
        analysisSpeedX: Double = 0,
        tempoBPM: Double? = nil,
        beatConfidence: Double = 0,
        transientCount: Int = 0,
        continuousCount: Int = 0,
        mixerDiagnostics: MusicHapticsMixerDiagnostics = .init()
    ) {
        self.tapAttached = tapAttached
        self.pcmFormat = pcmFormat
        self.analyzedRanges = analyzedRanges
        self.coverage = min(max(coverage, 0), 1)
        self.eventCount = max(0, eventCount)
        self.droppedFrames = max(0, droppedFrames)
        self.finishReason = finishReason
        self.analysisMode = analysisMode
        self.analysisStreamBitrate = analysisStreamBitrate.map { max(1, $0) }
        self.analysisPosition = max(0, analysisPosition)
        self.analysisSpeedX = max(0, analysisSpeedX)
        self.tempoBPM = tempoBPM
        self.beatConfidence = min(max(beatConfidence, 0), 1)
        self.transientCount = max(0, transientCount)
        self.continuousCount = max(0, continuousCount)
        self.mixerDiagnostics = mixerDiagnostics
    }
}

public struct MusicHapticsAnalysisResult: Hashable, Sendable {
    public let checkpoint: MusicHapticsPartialCheckpoint
    public let timeline: MusicHapticsTimeline?
    public let snapshot: MusicHapticsAnalysisSnapshot
    public let finishReason: MusicHapticsAnalysisFinishReason

    public init(
        checkpoint: MusicHapticsPartialCheckpoint,
        timeline: MusicHapticsTimeline?,
        snapshot: MusicHapticsAnalysisSnapshot,
        finishReason: MusicHapticsAnalysisFinishReason
    ) {
        self.checkpoint = checkpoint
        self.timeline = timeline
        self.snapshot = snapshot
        self.finishReason = finishReason
    }

    public var isComplete: Bool { timeline != nil }
}

public extension MusicHapticsTimeline {
    /// Density is intentionally diagnostic only.  It makes sparse output
    /// visible instead of silently presenting a low-event recording as healthy.
    var eventDensity: Double {
        guard duration > 0 else { return 0 }
        return Double(events.count) / duration
    }

    var timelineSuspiciouslySparse: Bool {
        duration > 120 && events.count < max(8, Int(duration / 30))
    }
}
