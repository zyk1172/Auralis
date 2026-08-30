import Domain
import Foundation
import MediaPlayer
#if os(iOS)
import AVFoundation
#endif

/// 系统媒体集成总控：音频会话、Now Playing、远程命令、中断与路由。
/// AppModel 在播放状态变化时调用 update* 系列方法；
/// 远程命令经 handlers 回调进 AppModel。
@MainActor
public final class SystemMediaIntegrationController {
    public let audioSession = AudioSessionCoordinator()
    public let nowPlaying = NowPlayingCoordinator()
    public let remoteCommands = RemoteCommandCoordinator()
    public let interruptions = AudioInterruptionCoordinator()
    public let routes = AudioRouteCoordinator()

    /// Internal visibility supports lifecycle regression tests without making
    /// startup state part of the public media-control API.
    private(set) var started = false
    /// Verified metadata for the current item.  It is retained across normal
    /// track/progress snapshot refreshes, rather than being tied to a haptics
    /// coordinator callback.
    private var internationalStandardRecordingCode: String?
#if os(iOS)
    private var mediaServicesResetObserver: NSObjectProtocol?
#endif

    public init() {}

    /// 启动集成：配置音频会话、注册远程命令、监听中断与路由。
    /// 可选的 onInterruptionBegan / onInterruptionShouldResume / onOutputDetached 用于
    /// 区分「系统中断暂停」与「用户暂停」，从而正确记录停止原因；缺省时复用远程命令回调。
    public func start(
        handlers: RemoteCommandHandlers,
        onInterruptionBegan: (@MainActor @Sendable () -> Void)? = nil,
        onInterruptionShouldResume: (@MainActor @Sendable () -> Void)? = nil,
        onOutputDetached: (@MainActor @Sendable () -> Void)? = nil,
        onRouteChanged: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !started else { return }
        started = true
        let coordinator = audioSession
        Task { await coordinator.configure() }
#if os(iOS)
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
            self.mediaServicesResetObserver = nil
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioSession.invalidateForSystemAudioEvent()
                await self.audioSession.activate()
            }
        }
#endif
        remoteCommands.register(handlers: handlers)
        let interruptionBegan = onInterruptionBegan ?? { handlers.onPause() }
        let interruptionShouldResume = onInterruptionShouldResume ?? { handlers.onPlay() }
        let outputDetached = onOutputDetached ?? { handlers.onPause() }
        let routeChanged = onRouteChanged ?? {}
        interruptions.start(
            onBegan: { [weak self] in
                self?.audioSession.invalidateForSystemAudioEvent()
                interruptionBegan()
            },
            onShouldResume: interruptionShouldResume
        )
        routes.start(
            onOutputDetached: { [weak self] in
                self?.audioSession.invalidateForSystemAudioEvent()
                outputDetached()
            },
            onRouteChanged: { [weak self] in
                self?.audioSession.invalidateForSystemAudioEvent()
                routeChanged()
            }
        )
    }

    /// 切歌 / 开始播放：完整刷新 Now Playing 信息。
    public func trackChanged(
        _ track: Track,
        position: TimeInterval,
        isPlaying: Bool,
        artworkData: Data?,
        queueIndex: Int? = nil,
        queueCount: Int? = nil,
        rate: Float? = nil,
        duration: TimeInterval? = nil
    ) {
        let coordinator = audioSession
        Task { await coordinator.activate() }
        nowPlaying.update(NowPlayingSnapshot(
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle,
            duration: duration ?? track.duration,
            elapsed: position,
            rate: rate ?? (isPlaying ? 1 : 0),
            artworkData: artworkData,
            queueIndex: queueIndex,
            queueCount: queueCount,
            internationalStandardRecordingCode: internationalStandardRecordingCode
        ))
    }

    /// 播放 / 暂停切换：刷新速率与系统播放状态。
    public func playbackStateChanged(isPlaying: Bool, position: TimeInterval, rate: Float? = nil) {
        nowPlaying.updateProgress(elapsed: position, rate: rate ?? (isPlaying ? 1 : 0))
        if isPlaying {
            let coordinator = audioSession
            Task { await coordinator.activate() }
        }
    }

    /// 拖动进度后同步。
    public func seekCompleted(position: TimeInterval, isPlaying: Bool, rate: Float? = nil) {
        nowPlaying.updateProgress(elapsed: position, rate: rate ?? (isPlaying ? 1 : 0))
    }

    public func setInternationalStandardRecordingCode(_ isrc: String?) {
        internationalStandardRecordingCode = isrc
        nowPlaying.setInternationalStandardRecordingCode(isrc)
    }

    /// 封面异步加载完成后补一次刷新。
    public func artworkLoaded(_ data: Data, position: TimeInterval, isPlaying: Bool) {
        guard var snapshot = nowPlaying.current else { return }
        snapshot.artworkData = data
        snapshot.elapsed = position
        snapshot.rate = isPlaying ? 1 : 0
        nowPlaying.update(snapshot)
    }

    /// 随机/循环状态回写到远程命令中心。
    public func modeChanged(isShuffled: Bool, repeatMode: RepeatMode) {
        remoteCommands.syncState(isShuffled: isShuffled, repeatMode: repeatMode)
    }

    /// 队列或当前项变化后同步锁屏/耳机上一首、下一首的可用性。
    public func queueCapabilitiesChanged(canPrevious: Bool, canNext: Bool) {
        remoteCommands.syncQueueAvailability(canPrevious: canPrevious, canNext: canNext)
    }

    /// 停止播放或退出服务器：清理 Now Playing 与音频会话。
    public func stop() {
        // `start()` owns observer registration. A complete stop/start cycle
        // must therefore reopen that gate; otherwise media-services resets,
        // interruptions and route changes are never registered again.
        started = false
        internationalStandardRecordingCode = nil
        nowPlaying.clear()
        // Remote/interruption/route observers belong to the app-lifetime
        // integration, not to the current playback item.  AppModel calls
        // stop() for user stop, queue exhaustion, sleep timer, and server
        // removal, then may resume playback without calling start() again.
        // Keep those observers installed so controls continue to work.
        let coordinator = audioSession
        Task { await coordinator.deactivate() }
    }
}
