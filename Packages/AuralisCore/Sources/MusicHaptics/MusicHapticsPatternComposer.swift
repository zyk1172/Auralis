// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Core Haptics dynamic controls affect every event in their pattern. Keep
/// attacks and unmodulated events out of texture patterns, and put overlapping
/// textures in separate lanes. The mixer normally produces just one texture
/// lane; interval partitioning also handles imported timelines correctly.
enum MusicHapticsPatternComposer {
    static func usesAbsoluteCurve(_ event: MusicHapticsEvent) -> Bool {
        event.kind == .continuous && event.curve.count >= 2
    }

    static func layers(for events: [MusicHapticsEvent]) -> [[MusicHapticsEvent]] {
        var unmodulated: [MusicHapticsEvent] = []
        var textures: [[MusicHapticsEvent]] = []
        var laneEnds: [TimeInterval] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            guard usesAbsoluteCurve(event) else {
                unmodulated.append(event)
                continue
            }
            let end = event.time + (event.duration ?? 0)
            if let lane = laneEnds.firstIndex(where: { $0 <= event.time }) {
                textures[lane].append(event)
                laneEnds[lane] = end
            } else {
                textures.append([event])
                laneEnds.append(end)
            }
        }
        return (unmodulated.isEmpty ? [] : [unmodulated]) + textures
    }

    static func baseParameters(
        for event: MusicHapticsEvent,
        intensity: MusicHapticsIntensity
    ) -> (intensity: Float, sharpness: Float) {
        // Intensity control multiplies the base, while sharpness control adds
        // to it. Curves already contain absolute perceptual values, so apply
        // them over neutral bases, and apply the user's gain only once.
        if usesAbsoluteCurve(event) { return (1, 0) }
        return (scaledIntensity(event.intensity, continuous: event.kind == .continuous, intensity: intensity), event.sharpness)
    }

    static func scaledIntensity(
        _ value: Float,
        continuous: Bool,
        intensity: MusicHapticsIntensity
    ) -> Float {
        let textureScale = continuous ? intensity.continuousTextureScale : 1
        return min(1, max(0, value * intensity.masterIntensity * textureScale))
    }
}
