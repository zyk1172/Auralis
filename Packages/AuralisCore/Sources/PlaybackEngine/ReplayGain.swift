import Domain
import Foundation

public struct ReplayGainAdjustment: Equatable, Sendable {
    public enum Source: String, Sendable {
        case disabled
        case track
        case album
        case fallback
        case missing
    }

    public var source: Source
    public var requestedGainDB: Double
    public var appliedGainDB: Double
    public var linearMultiplier: Float
    public var peakLimited: Bool

    public init(
        source: Source,
        requestedGainDB: Double,
        appliedGainDB: Double,
        linearMultiplier: Float,
        peakLimited: Bool
    ) {
        self.source = source
        self.requestedGainDB = requestedGainDB
        self.appliedGainDB = appliedGainDB
        self.linearMultiplier = linearMultiplier
        self.peakLimited = peakLimited
    }

    public static let disabled = ReplayGainAdjustment(
        source: .disabled,
        requestedGainDB: 0,
        appliedGainDB: 0,
        linearMultiplier: 1,
        peakLimited: false
    )
}

/// Pure ReplayGain calculation. This is deliberately separate from AVFoundation
/// so conversion, missing-data and peak-protection behaviour remain testable.
public enum ReplayGainCalculator {
    public static func adjustment(
        metadata: ReplayGainMetadata?,
        settings: ReplayGainSettings
    ) -> ReplayGainAdjustment {
        guard settings.mode != .off else { return .disabled }
        guard let metadata else {
            return .init(source: .missing, requestedGainDB: 0, appliedGainDB: 0, linearMultiplier: 1, peakLimited: false)
        }

        let selected: (Double?, Double?, ReplayGainAdjustment.Source)
        switch settings.mode {
        case .off:
            return .disabled
        case .track:
            selected = (finite(metadata.trackGainDB), validPeak(metadata.trackPeak), .track)
        case .album:
            selected = (finite(metadata.albumGainDB), validPeak(metadata.albumPeak), .album)
        }

        let directGain = selected.0
        let fallback = finite(metadata.fallbackGainDB)
        guard let contentGain = directGain ?? fallback else {
            return .init(source: .missing, requestedGainDB: 0, appliedGainDB: 0, linearMultiplier: 1, peakLimited: false)
        }

        let source: ReplayGainAdjustment.Source = directGain == nil ? .fallback : selected.2
        let baseGain = finite(metadata.baseGainDB) ?? 0
        let requestedDB = min(max(contentGain + baseGain + settings.preampDB, -60), 24)
        var multiplier = pow(10, requestedDB / 20)
        var peakLimited = false

        if settings.peakProtection, let peak = selected.1 {
            let maximum = 1 / peak
            if multiplier > maximum {
                multiplier = maximum
                peakLimited = true
            }
        }

        guard multiplier.isFinite, multiplier > 0 else {
            return .init(source: .missing, requestedGainDB: 0, appliedGainDB: 0, linearMultiplier: 1, peakLimited: false)
        }
        let appliedDB = 20 * log10(multiplier)
        return .init(
            source: source,
            requestedGainDB: requestedDB,
            appliedGainDB: appliedDB,
            linearMultiplier: Float(multiplier),
            peakLimited: peakLimited
        )
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func validPeak(_ value: Double?) -> Double? {
        guard let value = finite(value), value > 0 else { return nil }
        return value
    }
}
