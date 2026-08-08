import Domain
import Foundation
import MediaPlayer
import SystemMediaIntegration
import Testing

@Test("Now Playing info dictionary carries metadata without artwork")
@MainActor
func nowPlayingInfoDictionary() {
    let snapshot = NowPlayingSnapshot(title: "歌名", artist: "歌手", album: "专辑", duration: 210, elapsed: 12, rate: 1)
    let info = NowPlayingCoordinator.infoDictionary(for: snapshot)

    #expect((info[MPMediaItemPropertyTitle] as? String) == "歌名")
    #expect((info[MPMediaItemPropertyArtist] as? String) == "歌手")
    #expect((info[MPMediaItemPropertyAlbumTitle] as? String) == "专辑")
    let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double
    #expect(duration == 210)
    let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
    #expect(elapsed == 12)
    let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Float
    #expect(rate == 1)
    #expect(info[MPMediaItemPropertyArtwork] == nil)
}

@Test("Now Playing update stores the current snapshot")
@MainActor
func nowPlayingUpdate() {
    let coordinator = NowPlayingCoordinator()
    let snapshot = NowPlayingSnapshot(title: "T", artist: "A", album: "B", duration: 100, elapsed: 0, rate: 0)
    coordinator.update(snapshot)
    #expect(coordinator.current == snapshot)
}

@Test("Now Playing progress updates elapsed and rate")
@MainActor
func nowPlayingProgress() {
    let coordinator = NowPlayingCoordinator()
    let snapshot = NowPlayingSnapshot(title: "T", artist: "A", album: "B", duration: 100, elapsed: 0, rate: 0)
    coordinator.update(snapshot)
    coordinator.updateProgress(elapsed: 42, rate: 1.5)
    #expect(coordinator.current?.elapsed == 42)
    #expect(abs((coordinator.current?.rate ?? 0) - 1.5) < 0.001)
}

@Test("Now Playing clear resets the snapshot")
@MainActor
func nowPlayingClear() {
    let coordinator = NowPlayingCoordinator()
    coordinator.update(NowPlayingSnapshot(title: "T", artist: "A", album: "B", duration: 100, elapsed: 0, rate: 0))
    coordinator.clear()
    #expect(coordinator.current == nil)
}

// MARK: - Remote commands

private final class CommandProbe: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case play, pause, toggle, previous, next, seek(TimeInterval), shuffle(Bool), repeatMode(RepeatMode)
    }
    private let lock = NSLock()
    private var events: [Event] = []
    func record(_ event: Event) { lock.withLock { events.append(event) } }
    func all() -> [Event] { lock.withLock { events } }
}

@Test("Remote commands dispatch to the registered handlers")
@MainActor
func remoteCommandDispatch() async {
    let probe = CommandProbe()
    let handlers = RemoteCommandHandlers(
        onPlay: { probe.record(.play) },
        onPause: { probe.record(.pause) },
        onToggle: { probe.record(.toggle) },
        onPrevious: { probe.record(.previous) },
        onNext: { probe.record(.next) },
        onSeek: { probe.record(.seek($0)) },
        onShuffle: { probe.record(.shuffle($0)) },
        onRepeatMode: { probe.record(.repeatMode($0)) }
    )
    let coordinator = RemoteCommandCoordinator()
    coordinator.register(handlers: handlers)

    coordinator.handle(.play)
    coordinator.handle(.pause)
    coordinator.handle(.togglePlayPause)
    coordinator.handle(.previousTrack)
    coordinator.handle(.nextTrack)
    coordinator.handle(.seek(30))
    coordinator.handle(.shuffle(true))
    coordinator.handle(.repeatMode(.one))

    try? await Task.sleep(nanoseconds: 50_000_000)
    let events = await probe.all()
    #expect(events.contains(.play))
    #expect(events.contains(.pause))
    #expect(events.contains(.toggle))
    #expect(events.contains(.previous))
    #expect(events.contains(.next))
    #expect(events.contains(.seek(30)))
    #expect(events.contains(.shuffle(true)))
    #expect(events.contains(.repeatMode(.one)))
}

@Test("Repeat mode mapping round-trips")
@MainActor
func repeatModeMapping() {
    #expect(RemoteCommandCoordinator.repeatMode(from: .all) == .all)
    #expect(RemoteCommandCoordinator.repeatMode(from: .one) == .one)
    #expect(RemoteCommandCoordinator.repeatMode(from: .off) == .off)
    #expect(RemoteCommandCoordinator.repeatType(from: .all) == .all)
    #expect(RemoteCommandCoordinator.repeatType(from: .one) == .one)
    #expect(RemoteCommandCoordinator.repeatType(from: .off) == .off)
}
