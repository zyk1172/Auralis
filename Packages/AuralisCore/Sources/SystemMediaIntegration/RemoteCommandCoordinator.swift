import Domain
import Foundation
import MediaPlayer

/// 远程命令的抽象，便于脱离 MPRemoteCommandCenter 测试。
public enum RemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case previousTrack
    case nextTrack
    case seek(TimeInterval)
    case shuffle(Bool)
    case repeatMode(RepeatMode)
}

/// 远程命令回调。由 AppModel 提供，所有回调在主 actor 执行。
public struct RemoteCommandHandlers: Sendable {
    public var onPlay: @MainActor @Sendable () -> Void
    public var onPause: @MainActor @Sendable () -> Void
    public var onToggle: @MainActor @Sendable () -> Void
    public var onPrevious: @MainActor @Sendable () -> Void
    public var onNext: @MainActor @Sendable () -> Void
    public var onSeek: @MainActor @Sendable (TimeInterval) -> Void
    public var onShuffle: @MainActor @Sendable (Bool) -> Void
    public var onRepeatMode: @MainActor @Sendable (RepeatMode) -> Void

    public init(
        onPlay: @escaping @MainActor @Sendable () -> Void = {},
        onPause: @escaping @MainActor @Sendable () -> Void = {},
        onToggle: @escaping @MainActor @Sendable () -> Void = {},
        onPrevious: @escaping @MainActor @Sendable () -> Void = {},
        onNext: @escaping @MainActor @Sendable () -> Void = {},
        onSeek: @escaping @MainActor @Sendable (TimeInterval) -> Void = { _ in },
        onShuffle: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        onRepeatMode: @escaping @MainActor @Sendable (RepeatMode) -> Void = { _ in }
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onToggle = onToggle
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onSeek = onSeek
        self.onShuffle = onShuffle
        self.onRepeatMode = onRepeatMode
    }
}

/// 把系统远程命令（控制中心、锁屏、耳机线控、媒体键）映射到应用内播放控制。
@MainActor
public final class RemoteCommandCoordinator {
    private var handlers = RemoteCommandHandlers()

    public init() {}

    /// 命令分发入口。MP 事件与测试都走这里。
    public func handle(_ command: RemoteCommand) {
        switch command {
        case .play: handlers.onPlay()
        case .pause: handlers.onPause()
        case .togglePlayPause: handlers.onToggle()
        case .previousTrack: handlers.onPrevious()
        case .nextTrack: handlers.onNext()
        case let .seek(position): handlers.onSeek(position)
        case let .shuffle(enabled): handlers.onShuffle(enabled)
        case let .repeatMode(mode): handlers.onRepeatMode(mode)
        }
    }

    /// 注册到 MPRemoteCommandCenter。
    public func register(handlers: RemoteCommandHandlers) {
        self.handlers = handlers
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.dispatch(.play)
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatch(.pause)
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatch(.togglePlayPause)
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatch(.previousTrack)
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatch(.nextTrack)
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.dispatch(.seek(event.positionTime))
            return .success
        }
        center.changeShuffleModeCommand.isEnabled = true
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            self?.dispatch(.shuffle(event.shuffleType != .off))
            return .success
        }
        center.changeRepeatModeCommand.isEnabled = true
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            self?.dispatch(.repeatMode(Self.repeatMode(from: event.repeatType)))
            return .success
        }
    }

    /// 把应用内状态回写到远程命令中心（随机/循环按钮高亮）。
    public func syncState(isShuffled: Bool, repeatMode: RepeatMode) {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = Self.repeatType(from: repeatMode)
    }

    private func dispatch(_ command: RemoteCommand) {
        // MPRemoteCommandCenter 的 target 在非隔离闭包中回调，跳到主 actor 处理。
        Task { @MainActor [weak self] in
            self?.handle(command)
        }
    }

    public static func repeatMode(from type: MPRepeatType) -> RepeatMode {
        switch type {
        case .all: .all
        case .one: .one
        default: .off
        }
    }

    public static func repeatType(from mode: RepeatMode) -> MPRepeatType {
        switch mode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }
}
