import Domain
import Foundation
import PlaybackEngine
import Testing

@Suite("ReplayGain calculation")
struct ReplayGainTests {
    @Test("Off never changes volume even when metadata exists")
    func off() {
        let metadata = ReplayGainMetadata(trackGainDB: -8, trackPeak: 0.9)
        let value = ReplayGainCalculator.adjustment(metadata: metadata, settings: .init(mode: .off))
        #expect(value == .disabled)
    }

    @Test("Track mode converts dB to a linear multiplier")
    func trackGainConversion() {
        let metadata = ReplayGainMetadata(trackGainDB: -6)
        let value = ReplayGainCalculator.adjustment(metadata: metadata, settings: .init(mode: .track))
        #expect(value.source == .track)
        #expect(abs(Double(value.linearMultiplier) - 0.501187) < 0.0001)
    }

    @Test("Album mode selects album gain and peak")
    func albumMode() {
        let metadata = ReplayGainMetadata(
            trackGainDB: -2,
            albumGainDB: -8,
            trackPeak: 0.7,
            albumPeak: 0.9
        )
        let value = ReplayGainCalculator.adjustment(metadata: metadata, settings: .init(mode: .album))
        #expect(value.source == .album)
        #expect(abs(value.requestedGainDB - -8) < 0.0001)
    }

    @Test("Missing requested gain uses the server fallback")
    func fallback() {
        let metadata = ReplayGainMetadata(fallbackGainDB: -7)
        let value = ReplayGainCalculator.adjustment(metadata: metadata, settings: .init(mode: .track))
        #expect(value.source == .fallback)
        #expect(abs(value.requestedGainDB - -7) < 0.0001)
    }

    @Test("Missing and invalid data does not fake normalization")
    func missingAndInvalid() {
        let missing = ReplayGainCalculator.adjustment(metadata: nil, settings: .init(mode: .track))
        let invalid = ReplayGainCalculator.adjustment(
            metadata: .init(trackGainDB: .nan, trackPeak: -1),
            settings: .init(mode: .track)
        )
        #expect(missing.source == .missing)
        #expect(missing.linearMultiplier == 1)
        #expect(invalid.source == .missing)
        #expect(invalid.linearMultiplier == 1)
    }

    @Test("Peak protection caps positive gain")
    func peakProtection() {
        let metadata = ReplayGainMetadata(trackGainDB: 6, trackPeak: 0.8)
        let value = ReplayGainCalculator.adjustment(
            metadata: metadata,
            settings: .init(mode: .track, peakProtection: true)
        )
        #expect(value.peakLimited)
        #expect(abs(Double(value.linearMultiplier) - 1.25) < 0.0001)
    }

    @Test("Zero gain remains unity and preamp is included")
    func zeroAndPreamp() {
        let zero = ReplayGainCalculator.adjustment(
            metadata: .init(trackGainDB: 0),
            settings: .init(mode: .track)
        )
        let preamp = ReplayGainCalculator.adjustment(
            metadata: .init(trackGainDB: -3, baseGainDB: 1),
            settings: .init(mode: .track, preampDB: -2)
        )
        #expect(zero.linearMultiplier == 1)
        #expect(abs(preamp.requestedGainDB - -4) < 0.0001)
    }
}
