// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import Foundation
import Testing
@testable import PlaybackEngine

@Suite("Real engine async protocol witnesses", .serialized)
@MainActor
struct PlaybackProtocolWitnessTests {
    private func track(_ id: String) -> Track {
        Track(id: TrackID(rawValue: id), serverID: "server", albumID: "album", artistID: "artist",
              title: id, artistName: "Artist", albumTitle: "Album", duration: 60,
              sourceInfo: .init(replayGain: .init(trackGainDB: -6)),
              streamURL: URL(fileURLWithPath: "/auralis-witness-\(id).wav"))
    }

    @Test("Async callback registration and rate reach the real engine")
    func timingAndRate() async throws {
        let engine = AVFoundationPlaybackEngine()
        let controller: any PlaybackControlling = engine
        let events = WitnessTiming()
        await controller.setPlaybackTimingHandler { events.append($0) }
        await controller.setRate(1.5)
        try await controller.play(track: track("timing"))
        #expect(!events.values.isEmpty)
        #expect(events.values.allSatisfy { $0.rate == 1.5 })
        await controller.stop()
    }

    @Test("Async ReplayGain configuration affects actual output adjustment")
    func replayGain() async throws {
        let engine = AVFoundationPlaybackEngine()
        let controller: any PlaybackControlling = engine
        await controller.configureReplayGain(.init(mode: .track))
        try await controller.play(track: track("gain"))
        #expect(engine.replayGainAdjustment.source == .track)
        #expect(abs(engine.replayGainAdjustment.requestedGainDB + 6) < 0.001)
        await controller.stop()
    }

    @Test("Async preparation and position do not use protocol defaults")
    func preparedItemAndPosition() async throws {
        let engine = AVFoundationPlaybackEngine()
        let controller: any PlaybackControlling = engine
        try await controller.play(track: track("current"))
        #expect(await controller.currentPosition() != nil)
        let next = track("next")
        await controller.prepareNext(track: next)
        #expect(engine.preparedPlaybackURLForTesting == next.streamURL)
        await controller.prepareNext(track: nil)
        #expect(engine.preparedPlaybackURLForTesting == nil)
        await controller.stop()
    }
}

private final class WitnessTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [PlaybackTimingUpdate] = []
    var values: [PlaybackTimingUpdate] { lock.withLock { updates } }
    func append(_ update: PlaybackTimingUpdate) { lock.withLock { updates.append(update) } }
}
