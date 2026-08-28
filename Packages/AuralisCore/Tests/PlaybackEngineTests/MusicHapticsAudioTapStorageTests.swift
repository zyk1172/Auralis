import AVFoundation
import Foundation
import MusicHaptics
import Testing
@testable import PlaybackEngine

@Suite("Music Haptics audio tap storage")
struct MusicHapticsAudioTapStorageTests {
    @Test("init forwards clientInfo to tap storage")
    func initForwardsClientInfoToTapStorage() {
        let sink = NoopMusicHapticsSink()
        let callbackBundle = MusicHapticsAudioTap.makeCallbacks(sink: sink)
        var callbacks = callbackBundle.callbacks
        let retainedContext = callbackBundle.retainedContext

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )

        #expect(status == noErr)
        if let tap {
            let storage = MTAudioProcessingTapGetStorage(tap)
            #expect(Int(bitPattern: storage) == Int(bitPattern: retainedContext.toOpaque()))
        } else {
            // Mirror makeMix's failed-creation path so this test does not leak
            // the manually retained context if the platform rejects the tap.
            retainedContext.release()
        }
        tap = nil
    }

    @Test("storage round-trip keeps Context alive until the balancing release")
    func storageRoundTripBalancesRetain() {
        let deinitCount = LockedCount()
        var context: LifetimeProbe? = LifetimeProbe { deinitCount.increment() }
        let contextID = ObjectIdentifier(context!)
        let retainedContext = Unmanaged.passRetained(context!)
        context = nil

        var storage: UnsafeMutableRawPointer?
        MusicHapticsAudioTapStorage.initialize(
            clientInfo: retainedContext.toOpaque(),
            tapStorageOut: &storage
        )

        #expect(storage == retainedContext.toOpaque())
        #expect(
            ObjectIdentifier(
                MusicHapticsAudioTapStorage.object(from: storage, as: LifetimeProbe.self)!
            ) == contextID
        )
        #expect(deinitCount.value == 0)

        MusicHapticsAudioTapStorage.releaseRetained(from: storage, as: LifetimeProbe.self)
        #expect(deinitCount.value == 1)
    }

    @Test("null storage fails closed")
    func nullStorageFailsClosed() {
        #expect(MusicHapticsAudioTapStorage.object(from: nil, as: LifetimeProbe.self) == nil)
        MusicHapticsAudioTapStorage.releaseRetained(from: nil, as: LifetimeProbe.self)
    }
}

private final class NoopMusicHapticsSink: MusicHapticsAnalysisSink, @unchecked Sendable {
    func begin(format: MusicHapticsPCMFormat) {}
    func consumePCM(_ bytes: Data, time: TimeInterval, format: MusicHapticsPCMFormat, frameCount: Int) {}
    func pause() {}
    func seek(to position: TimeInterval) {}
    func finish() {}
    func cancel() {}
}

private final class LifetimeProbe: @unchecked Sendable {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}
