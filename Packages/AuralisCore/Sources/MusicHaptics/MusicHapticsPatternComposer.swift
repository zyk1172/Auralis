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

    /// A Core Haptics transient is an impulse; its model `duration` is not
    /// consumed by `.hapticTransient`. Translate the perceptual body budget of
    /// low/mid-frequency attacks into a short unmodulated continuous event so
    /// kick/bass/snare weight reaches the Taptic Engine instead of remaining
    /// dead metadata. High percussion intentionally stays transient-only.
    static func expandedEvents(for events: [MusicHapticsEvent]) -> [MusicHapticsEvent] {
        events.flatMap { event -> [MusicHapticsEvent] in
            guard let body = transientBody(for: event) else { return [event] }
            return [event, body]
        }
    }

    static func layers(for events: [MusicHapticsEvent]) -> [[MusicHapticsEvent]] {
        var unmodulated: [MusicHapticsEvent] = []
        var textures: [[MusicHapticsEvent]] = []
        var laneEnds: [TimeInterval] = []
        for event in expandedEvents(for: events).sorted(by: { $0.time < $1.time }) {
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
        return (
            scaledIntensity(
                event.intensity,
                continuous: event.kind == .continuous,
                intensity: intensity
            ),
            event.sharpness
        )
    }

    static func scaledIntensity(
        _ value: Float,
        continuous: Bool,
        intensity: MusicHapticsIntensity
    ) -> Float {
        let textureScale = continuous ? intensity.continuousTextureScale : 1
        return min(1, max(0, value * intensity.masterIntensity * textureScale))
    }

    private static func transientBody(for event: MusicHapticsEvent) -> MusicHapticsEvent? {
        guard event.kind == .transient,
              let perceptualDuration = event.duration,
              perceptualDuration >= 0.025,
              event.intensity >= 0.18
        else { return nil }

        let delay: TimeInterval
        let bodyDuration: TimeInterval
        let intensityScale: Float
        let sharpnessScale: Float
        let sharpnessCeiling: Float

        switch event.classification {
        case .kick:
            delay = 0.004
            bodyDuration = min(0.060, max(0.028, perceptualDuration * 0.62))
            intensityScale = 0.30
            sharpnessScale = 0.72
            sharpnessCeiling = 0.22
        case .bassAttack:
            delay = 0.005
            bodyDuration = min(0.075, max(0.032, perceptualDuration * 0.70))
            intensityScale = 0.25
            sharpnessScale = 0.72
            sharpnessCeiling = 0.24
        case .snareClap:
            delay = 0.003
            bodyDuration = min(0.040, max(0.020, perceptualDuration * 0.50))
            intensityScale = 0.16
            sharpnessScale = 0.68
            sharpnessCeiling = 0.46
        case .highPercussion, .climax, .sustainedBass, .buildTexture, .unknown:
            return nil
        }

        return MusicHapticsEvent(
            time: event.time + delay,
            duration: bodyDuration,
            intensity: min(0.34, event.intensity * intensityScale),
            sharpness: min(sharpnessCeiling, event.sharpness * sharpnessScale),
            kind: .continuous,
            classification: event.classification
        )
    }
}
