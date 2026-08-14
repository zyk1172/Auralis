import AVFoundation
import Domain
import Foundation
import Testing
@testable import PlaybackEngine

/// 真实 AVFoundation（AVQueuePlayer）边界集成测试：本地生成极短无声 WAV，
/// 验证自然结束、prepared 无缝推进、prepared 失败兜底与 exactly-once 语义。
/// 这些测试在 macOS 上运行（AVFoundation 可用），不依赖网络。
/// 真实 AVFoundation 测试需要测试进程能驱动 AVPlayer 的 run loop；swift test 默认
/// 不进入会推进 AVQueuePlayer 的 run loop 模式（独立可执行 probe 已验证引擎的
/// AVQueuePlayer 用法能正常播完并触发 DidPlayToEnd）。因此在默认 CI 中跳过，
/// 通过 `AURALIS_RUN_AV_TESTS=1 swift test` 手动运行；最终真机/本机验收见
/// Docs/ManualValidation.md（MANUAL-VERIFY）。
@Suite("AVFoundationPlaybackEngine boundary", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AURALIS_RUN_AV_TESTS"] == "1"))
struct AVFoundationPlaybackEngineBoundaryTests {
    private func makeWAV(duration: TimeInterval, name: String) throws -> URL {
        let sampleRate = 44_100
        let frames = Int(duration * Double(sampleRate))
        let bytesPerSample = 2
        let dataSize = frames * bytesPerSample
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-boundary-\(name)-\(UUID().uuidString).wav")

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Array($0) })
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * bytesPerSample).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bytesPerSample).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(contentsOf: Data(repeating: 0, count: dataSize))
        try data.write(to: url)
        return url
    }

    private func track(_ id: String, url: URL) -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: "server",
            albumID: "album", artistID: "artist",
            title: id, artistName: "Artist", albumTitle: "Album", duration: 1,
            streamURL: url
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return await condition()
    }

    @Test("无预载项自然结束只触发一次 trackEndedHandler")
    @MainActor
    func naturalEndFiresTrackEndedOnce() async throws {
        let url = try makeWAV(duration: 0.3, name: "natural")
        let engine = AVFoundationPlaybackEngine()
        let ended = CountBox()
        await engine.setTrackEndedHandler { ended.increment() }
        let preparedBox = CountBox()
        await engine.setPreparedTrackStartedHandler { _ in preparedBox.increment() }

        try await engine.play(track: track("natural", url: url))
        let ok = await waitUntil { ended.count >= 1 }
        #expect(ok)
        // 再等一小段，确认不会重复触发。
        try? await Task.sleep(for: .milliseconds(600))
        #expect(ended.count == 1)
        #expect(preparedBox.count == 0)
    }

    @Test("prepared 推进触发 preparedStartedHandler 且不触发 trackEnded")
    @MainActor
    func preparedAdvanceFiresPreparedStartedExactlyOnce() async throws {
        let urlA = try makeWAV(duration: 0.3, name: "a")
        let urlB = try makeWAV(duration: 0.3, name: "b")
        let engine = AVFoundationPlaybackEngine()
        let ended = CountBox()
        await engine.setTrackEndedHandler { ended.increment() }
        let started = LockedStrings()
        await engine.setPreparedTrackStartedHandler { track in
            Task { @MainActor in started.append(track.id.rawValue) }
        }

        try await engine.play(track: track("a", url: urlA))
        await engine.prepareNext(track: track("b", url: urlB))
        let ok = await waitUntil { started.value.contains("b") }
        #expect(ok)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(started.value.filter { $0 == "b" }.count == 1)
        #expect(ended.count == 0)
    }

    @Test("连续 A→B→C 无缝推进，trackEnded 不触发")
    @MainActor
    func continuousABCNoTrackEnded() async throws {
        let urlA = try makeWAV(duration: 0.2, name: "a2")
        let urlB = try makeWAV(duration: 0.2, name: "b2")
        let urlC = try makeWAV(duration: 0.2, name: "c2")
        let engine = AVFoundationPlaybackEngine()
        let ended = CountBox()
        await engine.setTrackEndedHandler { ended.increment() }
        let started = LockedStrings()
        await engine.setPreparedTrackStartedHandler { track in
            Task { @MainActor in started.append(track.id.rawValue) }
        }

        try await engine.play(track: track("a2", url: urlA))
        await engine.prepareNext(track: track("b2", url: urlB))
        let bStarted = await waitUntil { started.value.contains("b2") }
        #expect(bStarted)
        // B 开始后再预载 C。
        await engine.prepareNext(track: track("c2", url: urlC))
        let cStarted = await waitUntil { started.value.contains("c2") }
        #expect(cStarted)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(ended.count == 0)
    }

    @Test("prepared item 推进前失败：被移除，当前曲目结束时只触发一次 trackEnded")
    @MainActor
    func preparedFailureFallbackFiresTrackEndedOnce() async throws {
        let urlA = try makeWAV(duration: 0.3, name: "a3")
        let engine = AVFoundationPlaybackEngine()
        let ended = CountBox()
        await engine.setTrackEndedHandler { ended.increment() }
        let started = LockedStrings()
        await engine.setPreparedTrackStartedHandler { track in
            Task { @MainActor in started.append(track.id.rawValue) }
        }

        try await engine.play(track: track("a3", url: urlA))
        // B 使用不存在的文件地址：prepared item 会在推进前失败并被移除。
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")
        await engine.prepareNext(track: track("b3", url: badURL))
        // 等 prepared 失败被处理，再等 A 自然结束。
        try? await Task.sleep(for: .milliseconds(500))
        let ok = await waitUntil { ended.count >= 1 }
        #expect(ok)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(ended.count == 1)
        #expect(started.value.isEmpty)
    }
}

/// 线程安全的计数器（测试辅助）。
private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }
}

/// 线程安全的 [String] 容器（测试辅助）。
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String] = []
    var value: [String] {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func append(_ element: String) {
        lock.lock(); defer { lock.unlock() }
        _value.append(element)
    }
}
