// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

public struct MusicHapticsRenderConfiguration: Equatable, Sendable {
    public var style: MusicHapticsStyle
    public var intensity: MusicHapticsIntensity

    public init(style: MusicHapticsStyle = .rhythm, intensity: MusicHapticsIntensity = .medium) {
        self.style = style
        self.intensity = intensity
    }
}

/// Render-time choices do not invalidate analysis or bake user preferences
/// into the cache. Attacks and textures are still materialized in separate
/// Core Haptics patterns so a texture control cannot attenuate a drum.
enum MusicHapticsRendering {
    static func shouldKeep(_ event: MusicHapticsEvent, intensity: MusicHapticsIntensity) -> Bool {
        // The mixer already applies noise/density controls. Intensity changes
        // force, not which musical layers survive. Curved textures may start
        // quietly and grow, so test their peak rather than just the base.
        max(event.intensity, event.curve.map(\.intensity).max() ?? 0) >= intensity.weakEventFloor
    }

    static func events(
        _ input: [MusicHapticsEvent],
        style: MusicHapticsStyle
    ) -> [MusicHapticsEvent] {
        input.map { original in
            // Both styles preserve the original envelope, timbre and timing.
            // Clear rhythm adds a bounded accent using the pulse's remaining
            // headroom; it never makes room by carving holes in other layers.
            guard style == .rhythm, original.kind == .transient, original.isRhythmicPulse else { return original }
            var event = original
            event.intensity += (1 - event.intensity) * 0.12
            return event
        }
    }

    static func curvePoint(in event: MusicHapticsEvent, at offset: TimeInterval) -> MusicHapticsCurvePoint {
        let points = event.curve
        guard let first = points.first, let last = points.last else {
            return .init(timeOffset: offset, intensity: event.intensity, sharpness: event.sharpness)
        }
        if offset <= first.timeOffset {
            return .init(timeOffset: offset, intensity: first.intensity, sharpness: first.sharpness)
        }
        if offset < last.timeOffset {
            var lower = 1
            var upper = points.count - 1
            while lower < upper {
                let middle = (lower + upper) / 2
                if points[middle].timeOffset < offset { lower = middle + 1 } else { upper = middle }
            }
            let left = points[lower - 1]
            let right = points[lower]
            let fraction = Float((offset - left.timeOffset) / max(0.000001, right.timeOffset - left.timeOffset))
            return .init(timeOffset: offset, intensity: left.intensity + (right.intensity - left.intensity) * fraction,
                         sharpness: left.sharpness + (right.sharpness - left.sharpness) * fraction)
        }
        return .init(timeOffset: offset, intensity: last.intensity, sharpness: last.sharpness)
    }
}

/// A position is paired with the monotonic time at which it was sampled.
/// Async analysis delivery must not reuse a 250 ms-old UI/player position.
public struct MusicHapticsPlaybackClock: Sendable {
    public let position: TimeInterval
    public let uptime: TimeInterval
    public let rate: Double

    public init(position: TimeInterval, uptime: TimeInterval, rate: Double) {
        self.position = max(0, position.isFinite ? position : 0)
        self.uptime = uptime.isFinite ? uptime : 0
        self.rate = min(2, max(0.5, rate.isFinite ? rate : 1))
    }

    public func position(at now: TimeInterval, playing: Bool) -> TimeInterval {
        guard playing, now.isFinite, now >= uptime else { return position }
        // Stop trusting extrapolation after a missed clock interval. State
        // transitions and fresh AVPlayer samples remain authoritative.
        return position + min(1, now - uptime) * rate
    }
}
