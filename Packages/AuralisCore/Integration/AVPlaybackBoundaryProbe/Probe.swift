// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation
import PlaybackEngine

/// A standalone process owns the main run loop for real AVPlayer integration.
/// Keeps AVFoundation event delivery independent of the unit-test runner.
@main
struct AVPlaybackBoundaryProbe {
    static func main() {
        Task { @MainActor in
            do {
                try await run()
                print("AV playback boundaries: 5 checks passed")
                exit(0)
            } catch {
                print("AV playback boundary failure: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    enum Failure: Error { case boundary(String) }

    @MainActor
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.boundary(message) }
    }

    @MainActor
    private static func wait(_ condition: () -> Bool, seconds: Double = 8) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func track(_ id: String, seconds: Double) throws -> Track {
            let url = directory.appendingPathComponent(id + ".wav")
            let frames = Int(seconds * 44_100)
            let byteCount = frames * 2
            var data = Data()
            func append<T>(_ value: T) { var copy = value; withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) } }
            data.append(Data("RIFF".utf8)); append(UInt32(36 + byteCount).littleEndian)
            data.append(Data("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
            append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
            append(UInt32(44_100).littleEndian); append(UInt32(88_200).littleEndian)
            append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
            data.append(Data("data".utf8)); append(UInt32(byteCount).littleEndian)
            data.append(Data(repeating: 0, count: byteCount)); try data.write(to: url)
            return Track(id: TrackID(rawValue: id), serverID: "probe", albumID: "album", artistID: "artist",
                         title: id, artistName: "Artist", albumTitle: "Album", duration: seconds, streamURL: url)
        }

        do {
            let engine = AVFoundationPlaybackEngine()
            let events = Events()
            engine.setTrackEndedHandler { events.end() }
            try await engine.play(track: track("natural", seconds: 0.3))
            try require(await wait { events.ended == 1 }, "natural end never arrived")
            try await Task.sleep(for: .milliseconds(150))
            try require(events.ended == 1, "natural end fired more than once")
            engine.stop()
        }
        do {
            let engine = AVFoundationPlaybackEngine()
            let events = Events()
            engine.setPlaybackTimingHandler { update in
                if !update.isStateTransition, let position = update.position { events.position(position) }
            }
            try await engine.play(track: track("timing", seconds: 2))
            try require(await wait({ events.positions.count >= 2 }, seconds: 4), "periodic timing never arrived")
            let positions = events.positions
            try require((positions.last ?? 0) > (positions.first ?? 0), "timing position did not advance")
            engine.stop()
        }
        do {
            let engine = AVFoundationPlaybackEngine()
            let events = Events()
            engine.setTrackEndedHandler { events.end() }
            engine.setPreparedTrackStartedHandler { events.start($0.id.rawValue) }
            try await engine.play(track: track("prepared-a", seconds: 0.3))
            engine.prepareNext(track: try track("prepared-b", seconds: 1))
            try require(await wait { events.started.contains("prepared-b") }, "prepared item did not start")
            try require(events.started.filter { $0 == "prepared-b" }.count == 1 && events.ended == 0,
                        "prepared transition violated exactly-once semantics")
            engine.stop()
        }
        do {
            let engine = AVFoundationPlaybackEngine()
            let events = Events()
            engine.setTrackEndedHandler { events.end() }
            engine.setPreparedTrackStartedHandler { events.start($0.id.rawValue) }
            try await engine.play(track: track("abc-a", seconds: 0.3))
            engine.prepareNext(track: try track("abc-b", seconds: 0.6))
            try require(await wait { events.started.contains("abc-b") }, "A to B did not advance")
            engine.prepareNext(track: try track("abc-c", seconds: 1))
            try require(await wait { events.started.contains("abc-c") }, "B to C did not advance")
            try require(events.ended == 0, "prepared chain emitted a natural-end event")
            engine.stop()
        }
        do {
            let engine = AVFoundationPlaybackEngine()
            let events = Events()
            engine.setTrackEndedHandler { events.end() }
            engine.setPreparedTrackStartedHandler { events.start($0.id.rawValue) }
            try await engine.play(track: track("failed-a", seconds: 0.6))
            var invalid = try track("failed-b", seconds: 1)
            try FileManager.default.removeItem(at: invalid.streamURL!)
            invalid.streamURL = directory.appendingPathComponent("missing.wav")
            engine.prepareNext(track: invalid)
            try require(await wait { events.ended == 1 }, "failed prepared item suppressed natural end")
            try await Task.sleep(for: .milliseconds(150))
            try require(events.ended == 1 && events.started.isEmpty, "failed prepared item started or duplicated end")
            engine.stop()
        }
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var endCount = 0
    private var starts: [String] = []
    private var timing: [Double] = []
    var ended: Int { lock.withLock { endCount } }
    var started: [String] { lock.withLock { starts } }
    var positions: [Double] { lock.withLock { timing } }
    func end() { lock.withLock { endCount += 1 } }
    func start(_ id: String) { lock.withLock { starts.append(id) } }
    func position(_ value: Double) { lock.withLock { timing.append(value) } }
}
