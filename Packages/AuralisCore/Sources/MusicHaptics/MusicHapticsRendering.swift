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
    static func isStructuralAttack(_ event: MusicHapticsEvent) -> Bool {
        event.kind == .transient && (event.isRhythmicPulse
            || ((event.classification == .kick || event.classification == .snareClap
                 || event.classification == .bassAttack) && event.intensity >= 0.5))
    }

    static func shouldKeep(_ event: MusicHapticsEvent, intensity: MusicHapticsIntensity) -> Bool {
        // Light means less force, not missing every second beat. Continuous
        // bodies carry the pulse metadata too, but are not separate attacks.
        if event.isRhythmicPulse { return event.intensity >= 0.03 }
        let floor = intensity.weakEventFloor
        switch event.classification {
        case .kick, .bassAttack, .snareClap, .climax: return event.intensity >= floor * 0.65
        case .highPercussion: return event.intensity >= (intensity == .light ? 0.48 : floor)
        case .sustainedBass, .buildTexture: return event.intensity >= (intensity == .light ? 0.30 : floor)
        case .unknown: return event.intensity >= floor
        }
    }

    static func events(
        _ input: [MusicHapticsEvent],
        style: MusicHapticsStyle,
        precedingAttacks: [TimeInterval] = []
    ) -> [MusicHapticsEvent] {
        let attacks = Array(Set(precedingAttacks + input.filter(isStructuralAttack).map(\.time))).sorted()
        return input.map { original in
            var event = original
            if event.kind == .transient {
                if !event.isRhythmicPulse, event.classification == .highPercussion, style == .rhythm {
                    event.intensity *= 0.72
                }
                return event
            }
            guard let duration = event.duration else { return event }
            let gain: Float = style == .rhythm ? 0.38 : 0.85
            var offsets = [TimeInterval(0), duration] + event.curve.map(\.timeOffset)
            let first = lowerBound(attacks, event.time - 0.10)
            for attack in attacks.dropFirst(first).prefix(while: { $0 <= event.time + duration + 0.02 }) {
                offsets += [-0.012, 0, 0.045, 0.090].map { attack - event.time + $0 }
            }
            let points = Array(Set(offsets.filter { $0 >= 0 && $0 <= duration })).sorted().map { offset in
                let point = curvePoint(in: original, at: offset)
                let time = event.time + offset
                let index = lowerBound(attacks, time)
                var duck: Float = 1
                if index < attacks.count { duck = min(duck, duckGain(time - attacks[index])) }
                if index > 0 { duck = min(duck, duckGain(time - attacks[index - 1])) }
                return MusicHapticsCurvePoint(timeOffset: offset, intensity: point.intensity * gain * duck,
                                             sharpness: point.sharpness)
            }
            event.intensity *= gain
            event.curve = points
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
        for (left, right) in zip(points, points.dropFirst()) where offset <= right.timeOffset {
            let fraction = Float((offset - left.timeOffset) / max(0.000001, right.timeOffset - left.timeOffset))
            return .init(timeOffset: offset, intensity: left.intensity + (right.intensity - left.intensity) * fraction,
                         sharpness: left.sharpness + (right.sharpness - left.sharpness) * fraction)
        }
        return .init(timeOffset: offset, intensity: last.intensity, sharpness: last.sharpness)
    }

    private static func duckGain(_ offset: TimeInterval) -> Float {
        if offset < -0.012 || offset >= 0.090 { return 1 }
        if offset < 0 { return 1 - Float((offset + 0.012) / 0.012) * 0.70 }
        if offset <= 0.045 { return 0.30 }
        return 0.30 + Float((offset - 0.045) / 0.045) * 0.70
    }

    private static func lowerBound(_ sorted: [TimeInterval], _ time: TimeInterval) -> Int {
        var lower = 0
        var upper = sorted.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sorted[middle] < time { lower = middle + 1 } else { upper = middle }
        }
        return lower
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
