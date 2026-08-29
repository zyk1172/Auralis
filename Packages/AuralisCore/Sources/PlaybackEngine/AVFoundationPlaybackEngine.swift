import AVFoundation
import AudioToolbox
import Domain
import Foundation
import MusicHaptics
import Observability

/// 真实 AVFoundation 音频输出引擎。
/// 使用 AVPlayer 播放服务器流或本地缓存文件；进度、拖动、播完与播放失败
/// 都来自 AVPlayer 的真实状态。歌曲没有可用播放地址时抛出错误。
@MainActor
public final class AVFoundationPlaybackEngine: PlaybackControlling {
    private var avPlayer: AVQueuePlayer?
    private var playbackState: PlaybackState = .idle
    private var currentTrack: Track?
    private var volume: Float = 0.8
    private var replayGainSettings = ReplayGainSettings()
    public private(set) var replayGainAdjustment = ReplayGainAdjustment.disabled
    private var preparedItem: AVPlayerItem?
    private var preparedTrack: Track?
    private var preparedTrackStartedHandler: (@Sendable (Track) -> Void)?
    /// Optional, sidecar-only decoded PCM analysis for the current item.
    /// It is installed as an AVAudioMix tap and never owns the AVQueuePlayer.
    /// The plan is resolved by MusicHapticsCoordinator before play(); this
    /// engine only consumes that decision.
    private var pendingMusicHapticsPreparation: MusicHapticsPlaybackPreparation?
    private var activeMusicHapticsPreparation: MusicHapticsPlaybackPreparation?
    private var preparedMusicHapticsPreparation: MusicHapticsPlaybackPreparation?
    private var activeRealtimeFallbackPreparationID: UUID?
    private var currentTapSetupTask: Task<Void, Never>?
    private var preparedTapSetupTask: Task<Void, Never>?

    // MARK: - Observers
    private var endObserver: NSObjectProtocol?
    private var failedToPlayObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var trackEndedHandler: (@Sendable () -> Void)?
    /// 播放中途失败（流地址失效 / 解码失败 / 网络错误）时通知 AppModel 刷新并重试。
    private var playbackFailureHandler: (@Sendable () -> Void)?
    /// AVPlayer timeControlStatus transition callback for haptic scheduling
    /// and other sidecars that must follow the real player clock.
    private var playbackTimingHandler: (@Sendable (PlaybackTimingUpdate) -> Void)?
    /// 播放代际计数：快速切歌时被取代的旧 play() 任务不得再接管 AVPlayer/观察者（P1-7）。
    private var playGeneration = 0
    /// preparing 期间的暂停意图：AVPlayer 可能尚未创建，先记录，起播后立即生效（F13）。
    private var pauseRequestedDuringPreparing = false
    /// 同一 item 的失败去重：FailedToPlayToEndTime 通知与 status==.failed KVO 只上报一次（P2-3）。
    private var failureReported = false
    /// 缓冲停滞超时任务：进入 stalled 后 15 秒未恢复则按播放失败上报（P2-5）。
    private var stallTimeoutTask: Task<Void, Never>?
    /// 当前边界事件对应的 item：DidPlayToEnd 闭包必须校验事件 item 仍是当前观察
    /// 的 item，避免被移除观察者的迟到通知重复处理（exactly-once）。
    private var endObservedItem: AVPlayerItem?
    /// 当前 item 的真实总时长（秒），由 duration KVO 在 item 解析后写入一次。
    /// 播放页/控制中心以它为权威；不要在进度 tick 反复 asset.load(.duration)，
    /// 也不要把 seekableTimeRanges（可 seek 范围）当总时长。
    private var resolvedDuration: TimeInterval?
    private var durationObservation: NSKeyValueObservation?
    /// AVQueuePlayer.currentItem KVO：prepared item 成为 current 的权威事件。
    private var currentItemObservation: NSKeyValueObservation?
    /// prepared item 在推进前失败的观察（FailedToPlayToEndTime / status==.failed）。
    private var preparedItemFailureObserver: NSObjectProtocol?
    private var preparedItemStatusObservation: NSKeyValueObservation?
    /// 播放边界状态机：解决「DidPlayToEnd 与 currentItem 变化顺序不确定」导致的
    /// 双重推进 / 漏推进。同一个歌曲边界只允许完成一次。
    /// 播放边界确定性状态机（可独立测试；见 PlayerItemBoundaryCoordinator）。
    /// 解决「DidPlayToEnd 与 currentItem 变化顺序不确定」导致的双重推进/漏推进，
    /// 保证同一个歌曲边界 exactly-once。
    private var boundaryCoordinator = PlayerItemBoundaryCoordinator()
    /// 边界兜底：预载项在限定时间内未成为 current 时，只执行一次 trackEndedHandler。
    private var boundaryFallbackTask: Task<Void, Never>?
    private static let boundaryFallbackTimeout: Duration = .seconds(3)

    public init() {}

    public func state() -> PlaybackState { playbackState }

    /// Internal test seam for the audio-fidelity invariant. Music Haptics is
    /// a sidecar and must never replace the URL consumed by AVPlayer.
    var currentPlaybackURLForTesting: URL? {
        (avPlayer?.currentItem?.asset as? AVURLAsset)?.url
    }

    public func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        applyOutputVolume()
    }

    /// 当前保存的播放速度（0.5x–2.0x，夹取）。
    /// play()/resume() 每次新建或恢复 AVPlayer 时都会重新应用，避免
    /// 冷启动首次播放 / 换曲 / 暂停恢复 / 失败重试后悄悄回到 1.0×。
    private var playbackRate: Float = 1.0

    /// 播放速度：保存夹取值，并在正在播放时直接驱动 AVPlayer.rate。
    public func setRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 2.0)
        playbackRate = clamped
        if playbackState == .playing || playbackState == .buffering || playbackState == .stalled {
            avPlayer?.rate = clamped
        }
    }

    public func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) {
        trackEndedHandler = handler
    }

    /// 注册播放中途失败回调（AVPlayerItem failed / FailedToPlayToEndTime / stalled 超时）。
    public func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) {
        playbackFailureHandler = handler
    }

    public func setPlaybackTimingHandler(_ handler: (@Sendable (PlaybackTimingUpdate) -> Void)?) {
        playbackTimingHandler = handler
    }

    public func setPreparedTrackStartedHandler(_ handler: (@Sendable (Track) -> Void)?) {
        preparedTrackStartedHandler = handler
    }

    /// Must be called before `play(track:)`. The plan is already authoritative
    /// at this point; this method does not inspect the track or perform I/O.
    public func setMusicHapticsPlaybackPreparation(_ preparation: MusicHapticsPlaybackPreparation?) {
        if let previous = pendingMusicHapticsPreparation,
           previous.id != preparation?.id {
            previous.analysisSink?.finishPartial(reason: .preparationReplaced)
            previous.realtimeFallbackSink?.cancel()
            previous.lookaheadAnalyzer?.finishPartial(reason: .preparationReplaced)
        }
        pendingMusicHapticsPreparation = preparation
    }

    /// Installs a plan after the normal AVPlayer item has started.  AppShell
    /// uses this for interactive song selection so preference/system/sidecar
    /// resolution cannot sit between a tap and `player.play()`.  Prepared
    /// gapless items continue to use `setMusicHapticsPlaybackPreparation`,
    /// which installs their plan before queue insertion.
    public func installActiveMusicHapticsPlaybackPreparation(
        _ preparation: MusicHapticsPlaybackPreparation
    ) {
        guard let player = avPlayer,
              let item = player.currentItem
        else {
            // Keep the plan recoverable if a caller races the first item
            // creation; the next play call will consume it normally.
            pendingMusicHapticsPreparation = preparation
            return
        }
        guard activeMusicHapticsPreparation?.id != preparation.id else { return }
        pendingMusicHapticsPreparation = nil
        finishActiveMusicHaptics(reason: .preparationReplaced)
        activeMusicHapticsPreparation = preparation
        activeRealtimeFallbackPreparationID = nil
        if case .analyze = preparation.plan,
           let sink = preparation.analysisSink {
            scheduleTapSetup(
                for: item,
                sink: sink,
                isPrepared: false,
                generation: playGeneration
            )
        } else {
            logSkippedTapSetup(for: preparation.plan)
        }
    }

    public func configureReplayGain(_ settings: ReplayGainSettings) {
        replayGainSettings = settings
        updateReplayGain(for: currentTrack)
    }

    public func play(track: Track) async throws {
        CrashLog.shared.log("AVFoundationPlaybackEngine.play 开始: \(track.title)")
        playGeneration += 1
        let generation = playGeneration
        pauseRequestedDuringPreparing = false
        // A track switch is a checkpoint boundary, not an analysis failure.
        // Let the sidecar drain and persist its real ranges before the old
        // item is removed; never throw its already analyzed PCM away.
        finishActiveMusicHaptics(reason: .trackSwitch)
        finishPreparedMusicHaptics(reason: .preparationReplaced)
        cancelTapSetupTasks()
        // 复用 AVQueuePlayer：保留单一长期存在的 player，避免每次切歌销毁重建 CoreAudio 链路。
        // 仅清理旧 item/观察者，不销毁 player 本体。
        let stopStart = ContinuousClock.now
        let reusedPlayer = avPlayer
        if reusedPlayer != nil {
            // 轻量重置：保留 player 对象，清理旧状态
            failureReported = false
            cancelStallTimeout()
            cancelBoundaryFallback()
            boundaryCoordinator.reset()
            clearPreparedItemFailureObserver()
            resetDurationObservation()
            currentItemObservation?.invalidate()
            currentItemObservation = nil
            endObservedItem = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            if let failedToPlayObserver {
                NotificationCenter.default.removeObserver(failedToPlayObserver)
                self.failedToPlayObserver = nil
            }
            if let stalledObserver {
                NotificationCenter.default.removeObserver(stalledObserver)
                self.stalledObserver = nil
            }
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            reusedPlayer?.pause()
            reusedPlayer?.removeAllItems()
            preparedItem = nil
            preparedTrack = nil
        } else {
            // The preparation was resolved by AppModel before entering this
            // method. Keep that one pending plan while clearing the old
            // player; stopAll otherwise treats it as a user stop and cancels
            // the sidecar before AVPlayerItem is even created.
            stopAll(invalidateGeneration: false, preservePendingMusicHaptics: true)
        }
        let stopMs = durationMs(stopStart.duration(to: .now))
        AuralisLog.playback.debug("ENGINE_STOP_OLD_PLAYER_MS duration_ms=\(stopMs, privacy: .public) reused=\(reusedPlayer != nil, privacy: .public)")

        currentTrack = track
        setPlaybackState(.preparing)
        // AudioSession is owned by SystemMediaIntegrationController and is
        // configured/activated idempotently outside this per-track hot path.
        try Task.checkCancellation()
        guard generation == playGeneration else { return }

        guard let streamURL = track.streamURL else {
            setPlaybackState(.failed(.engineFailure("该歌曲没有可播放的地址")))
            AuralisLog.playback.error("无法播放 \(track.title)：缺少 streamURL")
            CrashLog.shared.log("错误: streamURL 为 nil")
            throw PlaybackError.engineFailure("该歌曲没有可播放的地址")
        }

        // 只记录脱敏后的地址（去掉查询串，查询串含认证参数）。
        CrashLog.shared.log("创建 AVPlayerItem，URL: \(Self.redactedURL(streamURL))")
        let itemStart = ContinuousClock.now
        // AVPlayerItem(url:) is intentionally created synchronously. Resolving
        // remote AVAsset tracks belongs to the asynchronous tap setup below;
        // it must not sit between a user tap and player.play().
        let item = AVPlayerItem(url: streamURL)
        let preparation = pendingMusicHapticsPreparation
        pendingMusicHapticsPreparation = nil
        activeMusicHapticsPreparation = preparation
        activeRealtimeFallbackPreparationID = nil
        let itemMs = durationMs(itemStart.duration(to: .now))
        AuralisLog.playback.debug("ENGINE_CREATE_ITEM_MS duration_ms=\(itemMs, privacy: .public)")
        let player: AVQueuePlayer
        let playerStart = ContinuousClock.now
        if let existing = reusedPlayer {
            player = existing
            player.automaticallyWaitsToMinimizeStalling = true
            guard player.canInsert(item, after: nil) else {
                finishActiveMusicHaptics(reason: .playbackFailure)
                setPlaybackState(.failed(.engineFailure("播放器无法插入当前歌曲")))
                throw PlaybackError.engineFailure("播放器无法插入当前歌曲")
            }
            player.insert(item, after: nil)
        } else {
            player = AVQueuePlayer(items: [item])
            player.automaticallyWaitsToMinimizeStalling = true
            self.avPlayer = player
        }
        let playerMs = durationMs(playerStart.duration(to: .now))
        AuralisLog.playback.debug("ENGINE_CREATE_PLAYER_MS duration_ms=\(playerMs, privacy: .public) reused=\(reusedPlayer != nil, privacy: .public)")

        // 快速切歌 / 任务取消：本代际已被更新的 play() 取代或被取消时直接放弃，
        // 不再把 avPlayer/观察者交给引擎，避免旧曲目 AVPlayer 覆盖新曲目（P1-7）。
        try Task.checkCancellation()
        guard generation == playGeneration else { return }
        // 缓冲等待期间流已失败（如立即 404）：status KVO 不会对已 failed 的 item 再次触发，
        // 主动检查一次，避免失败被掩盖成 buffering。
        if item.status == .failed {
            reportPlaybackFailure()
            return
        }
        self.avPlayer = player
        updateReplayGain(for: track)
        observeTrackEnd(for: item)
        observeItemFailure(for: item)
        observeTimeControl(for: player)
        observeCurrentItem(for: player)
        observeDuration(for: item)

        if let preparation,
           case .analyze = preparation.plan,
           let sink = preparation.analysisSink {
            scheduleTapSetup(for: item, sink: sink, isPrepared: false, generation: generation)
        } else {
            logSkippedTapSetup(for: preparation?.plan)
        }

        CrashLog.shared.log("调用 player.play()")
        let playStart = ContinuousClock.now
        player.play()
        let playMs = durationMs(playStart.duration(to: .now))
        AuralisLog.playback.debug("ENGINE_START_PLAY_MS duration_ms=\(playMs, privacy: .public)")
        // 新建或复用 AVPlayer 后立即应用保存的播放速度（setRate 可能发生在播放器创建前）。
        if playbackRate != 1.0 {
            player.rate = playbackRate
        }
        if pauseRequestedDuringPreparing {
            // preparing 期间已请求暂停：起播后立即生效（F13）。
            player.pause()
            setPlaybackState(.paused)
            pauseRequestedDuringPreparing = false
            CrashLog.shared.log("preparing 期间已请求暂停，播放已立即暂停")
            return
        }
        setPlaybackState(.playing)
        AuralisLog.playback.info("开始播放 \(track.title) · \(streamURL.isFileURL ? "本地缓存" : "服务器流式")音频")
        CrashLog.shared.log("播放状态已设为 .playing")
    }

    /// Inserts one next item into AVQueuePlayer. The system may buffer it while
    /// the current item plays and advances without a second player teardown.
    /// This is true preloading, but remote HTTP/codec behaviour remains
    /// best-effort seamless rather than a sample-perfect guarantee.
    public func prepareNext(track: Track?) {
        prepareNext(track: track, musicHapticsPreparation: nil)
    }

    /// Inserts a prepared item together with the already-resolved Haptics
    /// plan. Track metadata/tap setup can now be warmed while the current item
    /// plays, without changing the existing AVQueuePlayer boundary state.
    public func prepareNext(
        track: Track?,
        musicHapticsPreparation: MusicHapticsPlaybackPreparation?
    ) {
        // 边界未决（上一首已结束、正在等待 preloaded item 推进）时不允许替换
        // prepared item，避免 currentItem KVO 的匹配目标漂移导致漏过渡。
        if boundaryCoordinator.state == .waitingForPreparedAdvance { return }
        clearPreparedItemFailureObserver()
        finishPreparedMusicHaptics(reason: .preparationReplaced)
        preparedTapSetupTask?.cancel()
        preparedTapSetupTask = nil
        if let preparedItem, avPlayer?.items().contains(where: { $0 === preparedItem }) == true {
            avPlayer?.remove(preparedItem)
        }
        preparedItem = nil
        preparedTrack = nil

        guard let track, let url = track.streamURL, let player = avPlayer,
              player.currentItem != nil else { return }
        let item = AVPlayerItem(url: url)
        guard player.canInsert(item, after: nil) else { return }
        preparedItem = item
        preparedTrack = track
        preparedMusicHapticsPreparation = musicHapticsPreparation
        player.insert(item, after: nil)
        observePreparedItemFailure(for: item)
        if let preparation = musicHapticsPreparation,
           case .analyze = preparation.plan,
           let sink = preparation.analysisSink {
            scheduleTapSetup(for: item, sink: sink, isPrepared: true, generation: playGeneration)
        } else {
            logSkippedTapSetup(for: musicHapticsPreparation?.plan)
        }
    }

    // MARK: - Controls

    public func pause() {
        // preparing 阶段也允许暂停：记录暂停意图；AVPlayer 已创建则直接暂停（F13）。
        if playbackState == .preparing {
            pauseRequestedDuringPreparing = true
            avPlayer?.pause()
            return
        }
        guard playbackState == .playing || playbackState == .buffering || playbackState == .stalled else { return }
        cancelStallTimeout()
        avPlayer?.pause()
        activeMusicHapticsPreparation?.analysisSink?.pause()
        if let preparation = activeMusicHapticsPreparation,
           activeRealtimeFallbackPreparationID == preparation.id {
            preparation.realtimeFallbackSink?.pause()
        }
        setPlaybackState(.paused)
    }

    public func resume() throws {
        guard currentTrack != nil,
              let player = avPlayer,
              let item = player.currentItem,
              item.status != .failed
        else {
            throw PlaybackError.engineFailure("No playable current item")
        }
        cancelStallTimeout()
        player.play()
        // 暂停恢复后重新应用保存的播放速度。
        if playbackRate != 1.0 {
            player.rate = playbackRate
        }
        setPlaybackState(.playing)
    }

    public func stop() {
        stopAll()
        setPlaybackState(.idle)
        currentTrack = nil
    }

    /// 真实拖动：直接驱动 AVPlayer。
    public func seek(to position: TimeInterval) async {
        let time = CMTime(seconds: max(0, position), preferredTimescale: 600)
        await avPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        activeMusicHapticsPreparation?.analysisSink?.seek(to: position)
        if let preparation = activeMusicHapticsPreparation,
           activeRealtimeFallbackPreparationID == preparation.id {
            preparation.realtimeFallbackSink?.seek(to: position)
        }
    }

    private func setPlaybackState(_ state: PlaybackState) {
        playbackState = state
        let timingState: PlaybackTimingState? = switch state {
        case .buffering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .stalled: .stalled
        case .idle, .preparing, .failed: nil
        }
        guard let timingState else { return }
        playbackTimingHandler?(PlaybackTimingUpdate(
            state: timingState,
            position: currentPosition(),
            rate: playbackRate
        ))
    }

    /// AVPlayer 的真实播放位置（秒）。
    public func currentPosition() -> TimeInterval? {
        guard let seconds = avPlayer?.currentTime().seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// 当前 item 的真实总时长（秒）。
    ///
    /// 由 duration KVO 在 item 解析后写入一次并缓存；进度 tick 只读此缓存。
    /// 目录元数据 duration 可能比真实音频短/长，播放页/控制中心以此为准。
    /// 不使用 seekableTimeRanges（那是「可 seek 的范围」，不是媒体总时长）。
    public func currentDuration() async -> TimeInterval? {
        guard let resolvedDuration, resolvedDuration.isFinite, resolvedDuration > 0 else { return nil }
        return resolvedDuration
    }

    /// 安装 AVPlayerItem.duration KVO：duration 从 indefinite 变为有效值时写入缓存。
    /// 每个 item 只解析一次；prepared 过渡/stop 时由调用方重置。
    private func observeDuration(for item: AVPlayerItem) {
        durationObservation?.invalidate()
        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            Task { @MainActor [weak self] in
                self?.resolvedDuration = seconds
            }
        }
        // item 可能已 ready、duration 已有效：立即读一次（幂等，避免依赖 KVO 首帧）。
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 {
            resolvedDuration = seconds
        }
    }

    private func resetDurationObservation() {
        durationObservation?.invalidate()
        durationObservation = nil
        resolvedDuration = nil
    }

    private func stopAll(
        invalidateGeneration: Bool = true,
        preservePendingMusicHaptics: Bool = false
    ) {
        CrashLog.shared.log("AVFoundationPlaybackEngine.stopAll")
        if invalidateGeneration {
            // stop 可能发生在异步 AVFoundation 工作期间；让旧任务恢复后直接失效。
            playGeneration += 1
        }
        failureReported = false
        cancelStallTimeout()
        cancelBoundaryFallback()
        boundaryCoordinator.reset()
        clearPreparedItemFailureObserver()
        resetDurationObservation()
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        endObservedItem = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }
        if let stalledObserver {
            NotificationCenter.default.removeObserver(stalledObserver)
            self.stalledObserver = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        avPlayer?.pause()
        cancelTapSetupTasks()
        finishActiveMusicHaptics(reason: .stopped)
        finishPreparedMusicHaptics(reason: .preparationReplaced)
        if !preservePendingMusicHaptics {
            pendingMusicHapticsPreparation?.analysisSink?.cancel()
            pendingMusicHapticsPreparation?.realtimeFallbackSink?.cancel()
            pendingMusicHapticsPreparation = nil
        }
        avPlayer = nil
        preparedItem = nil
        preparedTrack = nil
    }

    /// 曲目自然播完：进入边界状态机。prepared item 存在时不立即回调 trackEnded，
    /// 而是等 `AVQueuePlayer.currentItem` KVO 确认推进；若推进已发生（E2 先于 E1）
    /// 则直接完成过渡。无预载项时直接回调 trackEndedHandler。
    private func observeTrackEnd(for item: AVPlayerItem) {
        let observedGeneration = playGeneration
        endObservedItem = item
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            // 同步校验事件 item（避免把非 Sendable 的 Notification 传入 Task）。
            let isExpectedItem = (notification.object as? AVPlayerItem) === item
            Task { @MainActor [weak self] in
                // 检查 observer 是否已被移除（快速切歌场景），并校验事件 item 仍是
                // 当前观察的 item（防止被移除观察者的迟到通知重复处理）。
                guard let self, self.endObserver != nil,
                      self.playGeneration == observedGeneration,
                      self.endObservedItem === item,
                      isExpectedItem else { return }
                self.handleItemDidPlayToEnd(item)
            }
        }
    }

    /// DidPlayToEnd 的确定性处理：不依赖 Task.yield 猜测 AVQueuePlayer 是否推进，
    /// 全部交给边界协调器决定（exactly-once）。
    private func handleItemDidPlayToEnd(_ item: AVPlayerItem) {
        // Natural end is the only path that promotes a complete timeline.
        // The coordinator receives the same idempotent completion through the
        // sink callback; a later queue transition may call finishPartial too.
        finishActiveMusicHaptics(reason: .naturalEnd)
        activeMusicHapticsPreparation = nil
        let hasPrepared = preparedItem != nil
            && avPlayer?.items().contains(where: { $0 === preparedItem }) == true
        let currentIsPrepared = avPlayer?.currentItem === preparedItem
        let actions = boundaryCoordinator.itemEnded(
            hasPrepared: hasPrepared,
            currentItemIsPrepared: currentIsPrepared
        )
        applyBoundaryActions(actions)
        if boundaryCoordinator.state == .waitingForPreparedAdvance {
            // 已进入等待推进：启动有界兜底（仅在真正等待时）。
            startBoundaryFallback()
        }
    }

    private func observeCurrentItem(for player: AVPlayer) {
        let observedGeneration = playGeneration
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, change in
            Task { @MainActor [weak self] in
                guard let self, self.currentItemObservation != nil,
                      self.playGeneration == observedGeneration,
                      self.avPlayer === player else { return }
                let newItem = change.newValue ?? player.currentItem
                guard let newItem else { return }
                let newItemIsPrepared = newItem === self.preparedItem && self.preparedItem != nil
                let actions = self.boundaryCoordinator.currentItemChanged(newItemIsPrepared: newItemIsPrepared)
                self.applyBoundaryActions(actions)
                // 非待决边界下的 currentItem 变化（首次 item / 队列编辑）不触发过渡。
            }
        }
    }

    /// 有界兜底：等待推进超时后仍未进入 prepared item，则移除该 item 并只回调一次
    /// trackEndedHandler，由 AppModel 按当前 repeat/shuffle 策略决定下一步。
    /// 仅在协调器仍处于 waiting 时生效（可取消、可去重）。
    private func startBoundaryFallback() {
        boundaryFallbackTask?.cancel()
        boundaryFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.boundaryFallbackTimeout)
            guard let self, !Task.isCancelled else { return }
            let actions = self.boundaryCoordinator.fallbackTick()
            self.applyBoundaryActions(actions)
        }
    }

    private func cancelBoundaryFallback() {
        boundaryFallbackTask?.cancel()
        boundaryFallbackTask = nil
    }

    /// 执行边界协调器输出的动作。每个动作都有幂等语义：
    /// - completeTransition：prepared 已成为 current，完成无缝过渡；
    /// - handleTrackEnded：交给 AppModel 决定 repeat/shuffle 下一步；
    /// - removePrepared：移除失效的 prepared item 并清空状态。
    private func applyBoundaryActions(_ actions: [PlayerItemBoundaryCoordinator.Action]) {
        for action in actions {
            switch action {
            case .completeTransition:
                if let preparedItem, let preparedTrack {
                    finishPreparedTransition(item: preparedItem, track: preparedTrack)
                }
            case .handleTrackEnded:
                trackEndedHandler?()
            case .removePrepared:
                if let preparedItem,
                   avPlayer?.items().contains(where: { $0 === preparedItem }) == true {
                    avPlayer?.remove(preparedItem)
                }
                preparedTapSetupTask?.cancel()
                preparedTapSetupTask = nil
                finishPreparedMusicHaptics(reason: .preparationReplaced)
                clearPreparedItemFailureObserver()
                preparedItem = nil
                preparedTrack = nil
            }
        }
    }

    /// prepared item 在成为 current 之前失败：移除它并清空 prepared 状态。
    /// 若当前正等待该 item 推进（上一首已结束），则按「未推进」兜底只触发一次
    /// trackEndedHandler；否则什么都不做（当前曲目结束时自然走无预载路径）。
    private func observePreparedItemFailure(for item: AVPlayerItem) {
        let observedGeneration = playGeneration
        preparedItemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.preparedItemFailureObserver != nil,
                      self.playGeneration == observedGeneration else { return }
                self.handlePreparedItemFailure(item)
            }
        }
        preparedItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.preparedItemStatusObservation != nil,
                      self.playGeneration == observedGeneration else { return }
                self.handlePreparedItemFailure(item)
            }
        }
    }

    private func clearPreparedItemFailureObserver() {
        if let preparedItemFailureObserver {
            NotificationCenter.default.removeObserver(preparedItemFailureObserver)
        }
        preparedItemFailureObserver = nil
        preparedItemStatusObservation?.invalidate()
        preparedItemStatusObservation = nil
    }

    private func handlePreparedItemFailure(_ item: AVPlayerItem) {
        guard preparedItem === item else { return }
        let actions = boundaryCoordinator.preparedFailed()
        applyBoundaryActions(actions)
    }

    /// AVQueuePlayer 已推进到 prepared item：只更新引擎/模型状态与观察者，
    /// 不重建播放器，避免破坏无缝衔接。
    private func finishPreparedTransition(item: AVPlayerItem, track: Track) {
        cancelBoundaryFallback()
        boundaryCoordinator.reset()
        // A prepared item can become current before the old item's end
        // notification arrives. Complete the old sidecar exactly once before
        // transferring the prepared sidecar to the active slot.
        currentTapSetupTask?.cancel()
        currentTapSetupTask = nil
        finishActiveMusicHaptics(reason: .naturalEnd)
        activeMusicHapticsPreparation = preparedMusicHapticsPreparation
        activeRealtimeFallbackPreparationID = nil
        preparedMusicHapticsPreparation = nil
        currentTapSetupTask = preparedTapSetupTask
        preparedTapSetupTask = nil
        clearPreparedItemFailureObserver()
        clearItemObservers()
        resetDurationObservation()
        preparedItem = nil
        preparedTrack = nil
        currentTrack = track
        failureReported = false
        updateReplayGain(for: track)
        observeTrackEnd(for: item)
        observeItemFailure(for: item)
        if let player = avPlayer { observeTimeControl(for: player) }
        observeDuration(for: item)
        // AVQueuePlayer 在 item 切换时可能回到默认 rate：无缝推进完成后幂等重应用一次。
        if playbackRate != 1.0 {
            avPlayer?.rate = playbackRate
        }
        setPlaybackState(avPlayer?.timeControlStatus == .playing ? .playing : .buffering)
        preparedTrackStartedHandler?(track)
    }

    private func clearItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedToPlayObserver { NotificationCenter.default.removeObserver(failedToPlayObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        endObserver = nil
        failedToPlayObserver = nil
        stalledObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        cancelStallTimeout()
    }

    private func updateReplayGain(for track: Track?) {
        replayGainAdjustment = ReplayGainCalculator.adjustment(
            metadata: track?.sourceInfo.replayGain,
            settings: replayGainSettings
        )
        applyOutputVolume()
    }

    private func applyOutputVolume() {
        // AVPlayer volume is limited to 0...1. Negative ReplayGain values are
        // applied exactly; positive gain uses the remaining user-volume
        // headroom and is clamped instead of pretending to provide DSP boost.
        avPlayer?.volume = min(max(volume * replayGainAdjustment.linearMultiplier, 0), 1)
    }

    /// 播放中途失败：AVPlayerItem.status == .failed 或 FailedToPlayToEndTime 通知。
    /// 只把「失败」事件抛给 AppModel（由其刷新流地址并重试 / 自动下一首），
    /// 不把错误细节（可能含 URL）写入日志。
    private func observeItemFailure(for item: AVPlayerItem) {
        let observedGeneration = playGeneration
        failedToPlayObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.failedToPlayObserver != nil,
                      self?.playGeneration == observedGeneration else { return }
                self?.reportPlaybackFailure()
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard self?.itemStatusObservation != nil,
                      self?.playGeneration == observedGeneration else { return }
                self?.reportPlaybackFailure()
            }
        }
        // 缓冲停滞（网络抖动/断流）：先标记 stalled，交给上层决定是否刷新 URL。
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.stalledObserver != nil,
                      self.playGeneration == observedGeneration else { return }
                // 失败态免疫（P1-6）：失败后晚到的 stall 通知不得把状态改回 stalled。
                if case .failed = self.playbackState { return }
                if self.playbackState != .paused {
                    self.setPlaybackState(.stalled)
                    self.startStallTimeout()
                }
            }
        }
    }

    /// 观察播放速率控制状态：缓冲中 / 恢复播放，供 UI 与诊断使用。
    private func observeTimeControl(for player: AVPlayer) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.timeControlObservation != nil,
                      self.avPlayer === player else { return }
                // 失败态免疫（P1-6）：失败后晚到的 KVO 回调不得把状态改回 buffering/playing。
                if case .failed = self.playbackState { return }
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    if self.playbackState != .paused {
                        self.setPlaybackState(.buffering)
                    }
                case .playing:
                    if self.playbackState != .paused {
                        self.setPlaybackState(.playing)
                    }
                    self.cancelStallTimeout()
                default:
                    // 进入 paused（或其它非播放状态）：stall 已恢复，取消超时避免误报失败（P2-5）。
                    self.cancelStallTimeout()
                }
            }
        }
    }

    private func reportPlaybackFailure() {
        // 同一 item 的 FailedToPlayToEndTime 通知与 status==.failed KVO 会各触发一次，
        // 去重避免重试预算被减半（P2-3）。
        guard !failureReported else { return }
        failureReported = true
        cancelStallTimeout()
        finishActiveMusicHaptics(reason: .playbackFailure)
        CrashLog.shared.log("播放中途失败（流地址失效/解码失败/网络错误），交由上层处理")
        playbackState = .failed(.engineFailure("播放中途失败"))
        playbackFailureHandler?()
    }

    /// 缓冲停滞超时：进入 stalled 后 15 秒内未恢复（未进入 playing/paused）则按播放失败上报（P2-5）。
    /// 恢复路径（playing/paused，含 resume）都会取消本任务；被取消则不报失败。
    private func startStallTimeout() {
        stallTimeoutTask?.cancel()
        stallTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            if self.playbackState == .playing || self.playbackState == .paused { return }
            self.reportPlaybackFailure()
        }
    }

    /// 取消缓冲停滞超时：进入 playing/paused 或 pause()/play()/stopAll() 时调用。
    private func cancelStallTimeout() {
        stallTimeoutTask?.cancel()
        stallTimeoutTask = nil
    }

    /// 脱敏 URL：去掉查询串（含认证参数）、userinfo 并掩码主机（私有 NAS 地址不得进日志/诊断）。
    /// 供 AppShell 等外部模块记录日志时复用（隐私：完整流地址不得进日志）。
    public static func redactedURL(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<?>"
        }
        let scheme = components.scheme ?? "https"
        let path = components.path.isEmpty ? "" : components.path
        return "\(scheme)://<host>\(path)"
    }

    private func durationMs(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }

    // MARK: - Music Haptics sidecar

    /// Resolves the audio track after normal playback has started. This task
    /// never creates another URL/asset stream: it only loads the track object
    /// belonging to the already inserted AVPlayerItem, then attaches one
    /// audio mix to that item.
    private func scheduleTapSetup(
        for item: AVPlayerItem,
        sink: any MusicHapticsAnalysisSink,
        isPrepared: Bool,
        generation: Int,
        planLabel: String = "analyze"
    ) {
        let setupStart = ContinuousClock.now
        let task = Task { @MainActor [weak self, item, sink] in
            let mix = await Self.makeAudioMix(for: item, sink: sink)
            guard !Task.isCancelled else { return }
            guard let self, self.playGeneration == generation else { return }

            let itemIsStillRelevant: Bool
            if isPrepared {
                itemIsStillRelevant = self.preparedItem === item
                    || self.avPlayer?.currentItem === item
            } else {
                itemIsStillRelevant = self.avPlayer?.currentItem === item
            }
            guard itemIsStillRelevant else { return }

            let attached: Bool
            if let mix {
                item.audioMix = mix
                sink.tapAttached()
                attached = true
            } else {
                attached = false
            }
            let setupMs = self.durationMs(setupStart.duration(to: .now))
            AuralisLog.playback.debug(
                "HAPTICS_TAP_SETUP_MS duration_ms=\(setupMs, privacy: .public) attached=\(attached, privacy: .public) prepared=\(isPrepared, privacy: .public) plan=\(planLabel, privacy: .public)"
            )
        }
        if isPrepared {
            preparedTapSetupTask = task
        } else {
            currentTapSetupTask = task
        }
    }

    private static func makeAudioMix(
        for item: AVPlayerItem,
        sink: any MusicHapticsAnalysisSink
    ) async -> AVAudioMix? {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        return MusicHapticsAudioTap.makeMix(track: track, sink: sink)
    }

    private func logSkippedTapSetup(for plan: MusicHapticsPlaybackPlan?) {
        let planKind = plan?.kind.rawValue ?? MusicHapticsPlanKind.disabled.rawValue
        AuralisLog.playback.debug(
            "HAPTICS_TAP_SETUP_MS duration_ms=0 attached=false skipped=true plan=\(planKind, privacy: .public)"
        )
    }

    private func cancelTapSetupTasks() {
        currentTapSetupTask?.cancel()
        currentTapSetupTask = nil
        preparedTapSetupTask?.cancel()
        preparedTapSetupTask = nil
    }

    private func finishActiveMusicHaptics(reason: MusicHapticsAnalysisFinishReason) {
        guard let preparation = activeMusicHapticsPreparation else { return }
        if reason == .naturalEnd {
            preparation.analysisSink?.finish()
        } else {
            preparation.analysisSink?.finishPartial(reason: reason)
        }
        if activeRealtimeFallbackPreparationID == preparation.id,
           let fallback = preparation.realtimeFallbackSink {
            if reason == .naturalEnd {
                fallback.finish()
            } else {
                fallback.finishPartial(reason: reason)
            }
        }
        preparation.lookaheadAnalyzer?.finishPartial(reason: reason)
        activeMusicHapticsPreparation = nil
        activeRealtimeFallbackPreparationID = nil
    }

    private func finishPreparedMusicHaptics(reason: MusicHapticsAnalysisFinishReason) {
        guard let preparation = preparedMusicHapticsPreparation else { return }
        preparation.analysisSink?.finishPartial(reason: reason)
        preparation.realtimeFallbackSink?.cancel()
        preparation.lookaheadAnalyzer?.finishPartial(reason: reason)
        preparedMusicHapticsPreparation = nil
    }

    /// Called only after the remote/local lookahead source has failed. The
    /// normal path never invokes this method, so successful lookahead and
    /// cached/system plans do not pay for an audio tap.
    public func activateMusicHapticsRealtimeFallback(
        preparationID: UUID,
        sink: any MusicHapticsAnalysisSink
    ) {
        guard let preparation = activeMusicHapticsPreparation,
              preparation.id == preparationID,
              let player = avPlayer,
              let item = player.currentItem,
              activeRealtimeFallbackPreparationID != preparationID
        else { return }
        activeRealtimeFallbackPreparationID = preparationID
        scheduleTapSetup(
            for: item,
            sink: sink,
            isPrepared: false,
            generation: playGeneration,
            planLabel: "realtime_fallback"
        )
    }
}

/// Bridges the retained callback context into the storage owned by an audio tap.
/// `MTAudioProcessingTapCallbacks.clientInfo` is only an input to `init`; the
/// processing callbacks must retrieve the same pointer from tap storage.
enum MusicHapticsAudioTapStorage {
    static func initialize(
        clientInfo: UnsafeMutableRawPointer?,
        tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) {
        tapStorageOut.pointee = clientInfo
    }

    static func object<T: AnyObject>(
        from storage: UnsafeMutableRawPointer?,
        as _: T.Type
    ) -> T? {
        guard let storage, Int(bitPattern: storage) != 0 else { return nil }
        return Unmanaged<T>.fromOpaque(storage).takeUnretainedValue()
    }

    static func releaseRetained<T: AnyObject>(
        from storage: UnsafeMutableRawPointer?,
        as _: T.Type
    ) {
        guard let storage, Int(bitPattern: storage) != 0 else { return }
        Unmanaged<T>.fromOpaque(storage).release()
    }
}

enum MusicHapticsAudioTap {
    final class Context: @unchecked Sendable {
        let sink: any MusicHapticsAnalysisSink
        var format: MusicHapticsPCMFormat?
        init(sink: any MusicHapticsAnalysisSink) { self.sink = sink }
    }

    static func makeCallbacks(
        sink: any MusicHapticsAnalysisSink
    ) -> (callbacks: MTAudioProcessingTapCallbacks, retainedContext: Unmanaged<Context>) {
        let context = Context(sink: sink)
        let retainedContext = Unmanaged.passRetained(context)
        let callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedContext.toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                MusicHapticsAudioTapStorage.initialize(
                    clientInfo: clientInfo,
                    tapStorageOut: tapStorageOut
                )
            },
            finalize: { tap in
                MusicHapticsAudioTapStorage.releaseRetained(
                    from: MTAudioProcessingTapGetStorage(tap),
                    as: Context.self
                )
            },
            prepare: { tap, _, processingFormat in
                guard let context = MusicHapticsAudioTapStorage.object(
                    from: MTAudioProcessingTapGetStorage(tap),
                    as: Context.self
                ) else { return }
                guard let format = MusicHapticsPCMBridge.makeFormat(from: processingFormat.pointee) else {
                    context.format = nil
                    context.sink.cancel()
                    return
                }
                context.format = format
                context.sink.begin(format: format)
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var localTimeRange = CMTimeRange.zero
                numberFramesOut.pointee = 0
                flagsOut.pointee = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &localTimeRange, numberFramesOut
                )
                guard status == noErr else { return }
                guard let context = MusicHapticsAudioTapStorage.object(
                    from: MTAudioProcessingTapGetStorage(tap),
                    as: Context.self
                ) else { return }
                guard let format = context.format else { return }
                let time = localTimeRange.start.seconds
                guard time.isFinite, time >= 0 else { return }
                let framesOut = Int(numberFramesOut.pointee)
                guard let payload = MusicHapticsPCMBridge.copyPayload(
                    from: bufferListInOut,
                    frameCount: framesOut,
                    format: format
                ) else { return }
                context.sink.consumePCM(payload, time: time, format: format, frameCount: framesOut)
            }
        )
        return (callbacks, retainedContext)
    }

    static func makeMix(track: AVAssetTrack, sink: any MusicHapticsAnalysisSink) -> AVAudioMix? {
        var callbacks: MTAudioProcessingTapCallbacks
        let retainedContext: Unmanaged<Context>
        (callbacks, retainedContext) = makeCallbacks(sink: sink)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            // No tap owns the retained context when creation fails, so balance
            // passRetained here. On success, finalize is the sole release site.
            retainedContext.release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
