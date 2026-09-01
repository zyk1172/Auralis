import Foundation

public enum MusicHapticsSource: Sendable, Equatable {
    case none
    case system
    case custom
    case analyzing
}

/// The one decision made for a track before its AVPlayerItem is created.
/// A plan is descriptive only; the PlaybackEngine decides how to attach the
/// optional realtime analysis tap without replacing the authoritative item.
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
    /// PCM timestamps can differ by a few microseconds at buffer boundaries.
    /// Treat a small gap as adjacency so coverage does not fragment merely
    /// because two decoders rounded the same boundary differently.
    public static let adjacencyTolerance: TimeInterval = 0.020
    /// A short final tail is held to a stricter standard than a PCM buffer
    /// boundary.  This keeps ordinary callback rounding from fragmenting
    /// ranges while ensuring an actually missing tail is still resumed.
    public static let completionTolerance: TimeInterval = 0.002

    public let lowerBound: TimeInterval
    public let upperBound: TimeInterval

    public init(lowerBound: TimeInterval, upperBound: TimeInterval) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var duration: TimeInterval { max(0, upperBound - lowerBound) }
}

public struct MusicHapticsPartialCheckpoint: Codable, Hashable, Sendable {
    public static let formatVersion = 2

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
    /// Byte/packet anchors captured by the incremental decoder. They are
    /// advisory: a decoder may fall back to a safe keyframe/header restart,
    /// but a resumed session never re-runs DSP for an already covered range.
    public let decoderResumePoints: [MusicHapticsDecoderResumePoint]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, identity, algorithmVersion, duration
        case analyzedRanges, events, coverage, updatedAt
        case mixMode, tempoBPM, beatConfidence, beatPhase, decoderResumePoints
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
        beatPhase: Double? = nil,
        decoderResumePoints: [MusicHapticsDecoderResumePoint] = []
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
        self.decoderResumePoints = Self.normalizeResumePoints(decoderResumePoints, duration: safeDuration)
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
            beatPhase: try container.decodeIfPresent(Double.self, forKey: .beatPhase),
            decoderResumePoints: try container.decodeIfPresent([MusicHapticsDecoderResumePoint].self, forKey: .decoderResumePoints) ?? []
        )
    }

    public var analyzedDuration: TimeInterval {
        analyzedRanges.reduce(0) { $0 + $1.duration }
    }

    /// Promotion requires the complete normalized range, not an arbitrary
    /// percentage. A near-complete checkpoint is still partial so a later
    /// playback can analyze the real uncovered tail instead of silently
    /// dropping it from the persisted timeline.
    public var isComplete: Bool {
        duration <= 0 || (
            uncoveredRanges.isEmpty
                && coverage >= 0.999
                && analyzedDuration >= duration - MusicHapticsTimeRange.completionTolerance
        )
    }

    public var isCurrentAlgorithm: Bool {
        formatVersion == Self.formatVersion
            && algorithmVersion == MusicHapticsTimeline.algorithmVersion
    }

    /// The complement of `analyzedRanges`, preserving every interior hole.
    /// This is the range list a resumed decoder should use instead of a single
    /// first-unanalysed high-water mark.
    public var uncoveredRanges: [MusicHapticsTimeRange] {
        guard duration > 0 else { return [] }
        var cursor: TimeInterval = 0
        var result: [MusicHapticsTimeRange] = []
        for range in analyzedRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > cursor + MusicHapticsTimeRange.adjacencyTolerance {
                result.append(MusicHapticsTimeRange(lowerBound: cursor, upperBound: range.lowerBound))
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < duration - MusicHapticsTimeRange.completionTolerance {
            result.append(MusicHapticsTimeRange(lowerBound: cursor, upperBound: duration))
        }
        return result
    }

    public func resumePoint(for range: MusicHapticsTimeRange) -> MusicHapticsDecoderResumePoint? {
        decoderResumePoints
            .filter { $0.position <= range.lowerBound + MusicHapticsTimeRange.adjacencyTolerance }
            .max { $0.position < $1.position }
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

    /// Rehydrates already analyzed event ranges into scheduler windows. A
    /// partial checkpoint is not eligible for the `.custom` plan, but its
    /// existing events are still authoritative for the covered playback
    /// interval while the decoder fills the remaining holes.
    public func analysisWindows(
        sourceMode: MusicHapticsAnalysisMode
    ) -> [MusicHapticsAnalysisWindow] {
        analyzedRanges.compactMap { range in
            let events = events.filter { event in
                let eventEnd = event.time + (event.duration ?? 0)
                if event.kind == .transient {
                    return event.time >= range.lowerBound && event.time < range.upperBound
                }
                return eventEnd > range.lowerBound && event.time < range.upperBound
            }
            guard !events.isEmpty else { return nil }
            return MusicHapticsAnalysisWindow(
                startTime: range.lowerBound,
                endTime: range.upperBound,
                analysisPosition: range.upperBound,
                events: events,
                coverage: coverage,
                analysisSpeedX: 0,
                tempoBPM: tempoBPM,
                beatConfidence: beatConfidence ?? 0,
                sourceMode: sourceMode,
                eventCount: events.count,
                transientCount: events.filter { $0.kind == .transient }.count,
                continuousCount: events.filter { $0.kind == .continuous }.count
            )
        }
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
        let mergedResumePoints = decoderResumePoints + other.decoderResumePoints
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
            beatPhase: mergedBeatPhase,
            decoderResumePoints: mergedResumePoints
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
                if existing.upperBound + MusicHapticsTimeRange.adjacencyTolerance < merged.lowerBound
                    || merged.upperBound + MusicHapticsTimeRange.adjacencyTolerance < existing.lowerBound {
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

    private static func normalizeResumePoints(
        _ input: [MusicHapticsDecoderResumePoint],
        duration: TimeInterval
    ) -> [MusicHapticsDecoderResumePoint] {
        var byPosition: [Int64: MusicHapticsDecoderResumePoint] = [:]
        for point in input {
            guard point.position.isFinite, point.position >= 0,
                  point.position <= duration,
                  point.byteOffset >= 0,
                  point.packetIndex >= 0
            else { continue }
            let key = Int64((point.position * 1_000).rounded())
            if let existing = byPosition[key], existing.byteOffset >= point.byteOffset { continue }
            byPosition[key] = point
        }
        return byPosition.values.sorted { $0.position < $1.position }
    }
}

/// A safe-to-persist byte/packet anchor emitted by the original-stream
/// incremental decoder. No URL or response header is stored here. `byteOffset`
/// is a best-effort range anchor; the decoder may move to an earlier packet or
/// keyframe when the format requires preroll.
public struct MusicHapticsDecoderResumePoint: Codable, Hashable, Sendable {
    public let position: TimeInterval
    public let byteOffset: Int64
    public let packetIndex: Int64

    public init(position: TimeInterval, byteOffset: Int64, packetIndex: Int64) {
        self.position = max(0, position.isFinite ? position : 0)
        self.byteOffset = max(0, byteOffset)
        self.packetIndex = max(0, packetIndex)
    }
}

public struct MusicHapticsAnalysisRequest: Codable, Hashable, Sendable {
    /// Shared short preparation budget.  It is used by both lookahead
    /// warm-up diagnostics and the AppShell identity-priority analysis; public
    /// metadata must never become an unbounded playback dependency.
    public static let defaultWarmupDeadline: Duration = .milliseconds(350)

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
        warmupDeadline: Duration = Self.defaultWarmupDeadline
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
            warmupDeadline: try container.decodeIfPresent(Duration.self, forKey: .warmupDeadline) ?? Self.defaultWarmupDeadline
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

/// User-facing provenance for the asset actually selected for a track. This
/// is intentionally separate from `MusicHapticsPlanKind` and diagnostic
/// reason strings so UI code never has to infer product meaning from runtime
/// implementation details.
public enum MusicHapticsAssetOrigin: String, Codable, Hashable, Sendable {
    case systemISRC
    case algorithmGenerated
    case none
}

public enum MusicHapticsAssetState: String, Codable, Hashable, Sendable {
    case available
    case generating
    case disabled
    case unavailable
}

public struct MusicHapticsAssetInfo: Codable, Hashable, Sendable {
    public let origin: MusicHapticsAssetOrigin
    public let state: MusicHapticsAssetState
    public let isrc: String?
    public let algorithmVersion: String?
    public let coverage: Double?
    public let isCurrentlyUsed: Bool

    public init(
        origin: MusicHapticsAssetOrigin,
        state: MusicHapticsAssetState,
        isrc: String? = nil,
        algorithmVersion: String? = nil,
        coverage: Double? = nil,
        isCurrentlyUsed: Bool = false
    ) {
        self.origin = origin
        self.state = state
        self.isrc = isrc
        self.algorithmVersion = algorithmVersion
        self.coverage = coverage.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        self.isCurrentlyUsed = isCurrentlyUsed
    }
}

public struct MusicHapticsAnalysisSnapshot: Hashable, Sendable {
    public var tapAttached: Bool
    public var pcmFormat: MusicHapticsPCMFormat?
    public var analyzedRanges: [MusicHapticsTimeRange]
    public var coverage: Double
    public var eventCount: Int
    public var droppedFrames: Int
    public var droppedAudioDuration: TimeInterval
    public var finishReason: MusicHapticsAnalysisFinishReason?
    public var analysisMode: MusicHapticsAnalysisMode
    public var analysisPosition: TimeInterval
    public var analysisSpeedX: Double
    public var remoteAnalysisPosition: TimeInterval
    public var realtimeAnalysisPosition: TimeInterval
    public var remoteAnalysisSpeedX: Double
    public var realtimeAnalysisSpeedX: Double
    public var remoteDecoderState: MusicHapticsRemoteDecoderState
    public var currentEventSource: MusicHapticsEventSource
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
        droppedAudioDuration: TimeInterval = 0,
        finishReason: MusicHapticsAnalysisFinishReason? = nil,
        analysisMode: MusicHapticsAnalysisMode = .realtimeTap,
        analysisPosition: TimeInterval = 0,
        analysisSpeedX: Double = 0,
        remoteAnalysisPosition: TimeInterval = 0,
        realtimeAnalysisPosition: TimeInterval = 0,
        remoteAnalysisSpeedX: Double = 0,
        realtimeAnalysisSpeedX: Double = 0,
        remoteDecoderState: MusicHapticsRemoteDecoderState = .idle,
        currentEventSource: MusicHapticsEventSource = .none,
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
        self.droppedAudioDuration = max(0, droppedAudioDuration.isFinite ? droppedAudioDuration : 0)
        self.finishReason = finishReason
        self.analysisMode = analysisMode
        self.analysisPosition = max(0, analysisPosition)
        self.analysisSpeedX = max(0, analysisSpeedX)
        self.remoteAnalysisPosition = max(0, remoteAnalysisPosition)
        self.realtimeAnalysisPosition = max(0, realtimeAnalysisPosition)
        self.remoteAnalysisSpeedX = max(0, remoteAnalysisSpeedX)
        self.realtimeAnalysisSpeedX = max(0, realtimeAnalysisSpeedX)
        self.remoteDecoderState = remoteDecoderState
        self.currentEventSource = currentEventSource
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
