import Domain
import Foundation
import MediaPlayer

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

    private var started = false

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
        remoteCommands.register(handlers: handlers)
        interruptions.start(
            onBegan: onInterruptionBegan ?? { handlers.onPause() },
            onShouldResume: onInterruptionShouldResume ?? { handlers.onPlay() }
        )
        routes.start(
            onOutputDetached: onOutputDetached ?? { handlers.onPause() },
            onRouteChanged: onRouteChanged ?? {}
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
            queueCount: queueCount
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
        nowPlaying.clear()
        let coordinator = audioSession
        Task { await coordinator.deactivate() }
    }
}
