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

    public init(
        identity: MusicHapticsIdentity,
        algorithmVersion: String = MusicHapticsTimeline.algorithmVersion,
        duration: TimeInterval,
        analyzedRanges: [MusicHapticsTimeRange],
        events: [MusicHapticsEvent],
        coverage: Double? = nil,
        updatedAt: Date = .now,
        formatVersion: Int = Self.formatVersion
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
    }

    public var analyzedDuration: TimeInterval {
        analyzedRanges.reduce(0) { $0 + $1.duration }
    }

    public var isComplete: Bool { coverage >= 0.95 }

    public func timeline() -> MusicHapticsTimeline {
        MusicHapticsTimeline(
            identity: identity,
            duration: duration,
            createdAt: updatedAt,
            analyzedDuration: analyzedDuration,
            analysisCoverage: coverage,
            events: events
        )
    }

    /// Merges two checkpoints for the same recording without collapsing their
    /// coverage to a single high-water mark. This is used when rapid A→B→A
    /// switching lets completion callbacks reach the Store out of order.
    public func merged(with other: MusicHapticsPartialCheckpoint) -> MusicHapticsPartialCheckpoint {
        guard algorithmVersion == other.algorithmVersion,
              identity.matchConfidence(with: other.identity) >= 0.82
        else { return other }

        var mergedEvents = events + other.events
        mergedEvents.sort { $0.time < $1.time }
        var thinned: [MusicHapticsEvent] = []
        for event in mergedEvents {
            guard let previous = thinned.last, event.time - previous.time < 0.16 else {
                thinned.append(event)
                continue
            }
            if event.intensity > previous.intensity {
                thinned[thinned.count - 1] = event
            }
        }

        return MusicHapticsPartialCheckpoint(
            identity: other.identity,
            algorithmVersion: other.algorithmVersion,
            duration: max(duration, other.duration),
            analyzedRanges: analyzedRanges + other.analyzedRanges,
            events: thinned,
            updatedAt: max(updatedAt, other.updatedAt),
            formatVersion: max(formatVersion, other.formatVersion)
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

    public init(
        identity: MusicHapticsIdentity,
        favorite: Bool,
        duration: TimeInterval,
        partial: MusicHapticsPartialCheckpoint? = nil
    ) {
        self.identity = identity
        self.favorite = favorite
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.partial = partial
    }
}

public enum MusicHapticsPlaybackPlan: Codable, Hashable, Sendable {
    case disabled
    case system
    case custom(MusicHapticsTimeline)
    case analyze(MusicHapticsAnalysisRequest)

    public var kind: MusicHapticsPlanKind {
        switch self {
        case .disabled: .disabled
        case .system: .system
        case .custom: .custom
        case .analyze: .analyze
        }
    }

    public var identity: MusicHapticsIdentity? {
        switch self {
        case .disabled, .system: nil
        case let .custom(timeline): timeline.identity
        case let .analyze(request): request.identity
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

    public init(
        tapAttached: Bool = false,
        pcmFormat: MusicHapticsPCMFormat? = nil,
        analyzedRanges: [MusicHapticsTimeRange] = [],
        coverage: Double = 0,
        eventCount: Int = 0,
        droppedFrames: Int = 0,
        finishReason: MusicHapticsAnalysisFinishReason? = nil
    ) {
        self.tapAttached = tapAttached
        self.pcmFormat = pcmFormat
        self.analyzedRanges = analyzedRanges
        self.coverage = min(max(coverage, 0), 1)
        self.eventCount = max(0, eventCount)
        self.droppedFrames = max(0, droppedFrames)
        self.finishReason = finishReason
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
    /// Density is intentionally diagnostic only.  The v1 algorithm remains
    /// unchanged in this PR; this makes sparse output visible for a later DSP
    /// revision instead of silently presenting it as healthy.
    var eventDensity: Double {
        guard duration > 0 else { return 0 }
        return Double(events.count) / duration
    }

    var timelineSuspiciouslySparse: Bool {
        duration > 120 && events.count < max(8, Int(duration / 30))
    }
}
