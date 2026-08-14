import AVFoundation
import Domain
import Foundation
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

    // MARK: - Observers
    private var endObserver: NSObjectProtocol?
    private var failedToPlayObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var trackEndedHandler: (@Sendable () -> Void)?
    /// 播放中途失败（流地址失效 / 解码失败 / 网络错误）时通知 AppModel 刷新并重试。
    private var playbackFailureHandler: (@Sendable () -> Void)?
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

    public func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        applyOutputVolume()
    }

    /// 播放速度：直接驱动 AVPlayer.rate（0.5x–2.0x，夹取）。
    public func setRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 2.0)
        avPlayer?.rate = clamped
    }

    public func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) {
        trackEndedHandler = handler
    }

    /// 注册播放中途失败回调（AVPlayerItem failed / FailedToPlayToEndTime / stalled 超时）。
    public func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) {
        playbackFailureHandler = handler
    }

    public func setPreparedTrackStartedHandler(_ handler: (@Sendable (Track) -> Void)?) {
        preparedTrackStartedHandler = handler
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
        stopAll()

        currentTrack = track
        playbackState = .preparing
        CrashLog.shared.log("配置 AVAudioSession...")
        await configureSession()

        guard let streamURL = track.streamURL else {
            playbackState = .failed(.engineFailure("该歌曲没有可播放的地址"))
            AuralisLog.playback.error("无法播放 \(track.title)：缺少 streamURL")
            CrashLog.shared.log("错误: streamURL 为 nil")
            throw PlaybackError.engineFailure("该歌曲没有可播放的地址")
        }

        // 只记录脱敏后的地址（去掉查询串，查询串含认证参数）。
        CrashLog.shared.log("创建 AVPlayerItem，URL: \(Self.redactedURL(streamURL))")
        let item = AVPlayerItem(url: streamURL)
        let player = AVQueuePlayer(items: [item])
        player.automaticallyWaitsToMinimizeStalling = true

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

        CrashLog.shared.log("调用 player.play()")
        player.play()
        if pauseRequestedDuringPreparing {
            // preparing 期间已请求暂停：起播后立即生效（F13）。
            player.pause()
            playbackState = .paused
            pauseRequestedDuringPreparing = false
            CrashLog.shared.log("preparing 期间已请求暂停，播放已立即暂停")
            return
        }
        playbackState = .playing
        AuralisLog.playback.info("开始播放 \(track.title) · \(streamURL.isFileURL ? "本地缓存" : "服务器流式")音频")
        CrashLog.shared.log("播放状态已设为 .playing")
    }

    /// Inserts one next item into AVQueuePlayer. The system may buffer it while
    /// the current item plays and advances without a second player teardown.
    /// This is true preloading, but remote HTTP/codec behaviour remains
    /// best-effort seamless rather than a sample-perfect guarantee.
    public func prepareNext(track: Track?) {
        // 边界未决（上一首已结束、正在等待 preloaded item 推进）时不允许替换
        // prepared item，避免 currentItem KVO 的匹配目标漂移导致漏过渡。
        if boundaryCoordinator.state == .waitingForPreparedAdvance { return }
        clearPreparedItemFailureObserver()
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
        player.insert(item, after: nil)
        observePreparedItemFailure(for: item)
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
        playbackState = .paused
    }

    public func resume() throws {
        guard currentTrack != nil else {
            throw PlaybackError.engineFailure("No current track")
        }
        cancelStallTimeout()
        avPlayer?.play()
        playbackState = .playing
    }

    public func stop() {
        stopAll()
        playbackState = .idle
        currentTrack = nil
    }

    /// 真实拖动：直接驱动 AVPlayer。
    public func seek(to position: TimeInterval) async {
        let time = CMTime(seconds: max(0, position), preferredTimescale: 600)
        await avPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// AVPlayer 的真实播放位置（秒）。
    public func currentPosition() -> TimeInterval? {
        guard let seconds = avPlayer?.currentTime().seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// 当前 item 的真实时长（秒）：优先 seekableTimeRanges（渐进式 HTTP 流可给出已确定时长），
    /// 其次异步读取 asset.duration（本地文件/已知时长流）。目录元数据 duration 可能比真实
    /// 音频短/长，播放页进度条与控制中心应以此为准（RC 真机反馈）。
    public func currentDuration() async -> TimeInterval? {
        guard let item = avPlayer?.currentItem else { return nil }
        if let last = item.seekableTimeRanges.last {
            let end = last.timeRangeValue.end.seconds
            if end.isFinite, end > 0 { return end }
        }
        if let duration = try? await item.asset.load(.duration),
           duration.seconds.isFinite, duration.seconds > 0 {
            return duration.seconds
        }
        return nil
    }

    private func stopAll() {
        CrashLog.shared.log("AVFoundationPlaybackEngine.stopAll")
        failureReported = false
        cancelStallTimeout()
        cancelBoundaryFallback()
        boundaryCoordinator.reset()
        clearPreparedItemFailureObserver()
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
        clearPreparedItemFailureObserver()
        clearItemObservers()
        preparedItem = nil
        preparedTrack = nil
        currentTrack = track
        failureReported = false
        updateReplayGain(for: track)
        observeTrackEnd(for: item)
        observeItemFailure(for: item)
        if let player = avPlayer { observeTimeControl(for: player) }
        playbackState = avPlayer?.timeControlStatus == .playing ? .playing : .buffering
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
                    self.playbackState = .stalled
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
                        self.playbackState = .buffering
                    }
                case .playing:
                    if self.playbackState != .paused {
                        self.playbackState = .playing
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

    // MARK: - Session

    private func configureSession() async {
        #if os(iOS)
        do {
            // 主线程 + 异步 API：避免同步 setActive 在主线程触发 UI 卡顿告警（AVAudioSession_iOS.mm:978）
            try await performAudioSession(category: .playback, active: true)
        } catch {
            AuralisLog.playback.error("AVAudioSession 配置失败：\(error.localizedDescription)")
        }
        #endif
    }
}

/// AVAudioSession 必须在主线程调用（内部 dispatch_assert_queue 断言，
/// 后台线程调用会触发 _dispatch_assert_queue_fail + FIGApplicationStateMonitor 分配失败 err=-19431）。
/// AVFoundationPlaybackEngine 已是 @MainActor，play() → configureSession() 本就在主线程；
/// 但同步 setActive 在主线程会触发 UI 卡顿告警（AVAudioSession_iOS.mm:978），
/// 因此走下方本文件的 performAudioSession 异步 API。

#if os(iOS)
/// 本目标内的 AVAudioSession 配置：在主线程用**异步** activate/deactivate API，
/// 既满足 AVAudioSession 的主线程要求，又不阻塞 UI（避免 AVAudioSession_iOS.mm:978 告警）。
private func performAudioSession(
    category: AVAudioSession.Category? = nil,
    mode: AVAudioSession.Mode = .default,
    active: Bool? = nil,
    options: AVAudioSession.SetActiveOptions = []
) async throws {
    let session = AVAudioSession.sharedInstance()
    // allowAirPlay / allowBluetooth：保证隔空播放、蓝牙耳机等路由下后台音频不被中断。
    if let category {
        do {
            try session.setCategory(category, mode: mode, options: [.allowAirPlay, .allowBluetoothHFP])
        } catch {
            // 个别系统/外设组合会拒绝某个选项（OSStatus -50 paramErr）：
            // 降级为不带选项也要把分类配上，避免配置失败影响播放。
            try session.setCategory(category, mode: mode)
        }
    }
    if let active {
        if active {
            // 激活：异步 API 自 iOS 15 可用——激活在每次起播都会调用，同步 setActive
            // 会在主线程阻塞到音频服务响应（mediaserverd 异常时可达数秒），
            // 是「System gesture gate timed out」卡顿的主要来源，必须走异步。
            if #available(iOS 27, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion: @Sendable (Bool, Error?) -> Void = { success, error in
                        if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error
                                ?? PlaybackSessionError(kind: .activation))
                        }
                    }
                    session.activate(options: [], completionHandler: completion)
                }
            } else {
                // iOS 15–26：setActive 是同步调用，官方明确警告主线程调用会阻塞 UI
                // （AVAudioSession_iOS.mm:978）；派发到后台队列执行并等待，主线程不被卡。
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let optionsCopy = options
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try session.setActive(true, options: optionsCopy)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } else {
            // 挂起：异步 deactivate 仅 iOS 27+ 可用；iOS 15–26 退回同步（用户主动暂停/停止时触发，频率低）。
            if #available(iOS 27, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion: @Sendable (Bool, Error?) -> Void = { success, error in
                        if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error
                                ?? PlaybackSessionError(kind: .deactivation))
                        }
                    }
                    let deactivationOptions = AVAudioSessionDeactivationOptions(rawValue: options.rawValue)
                    session.deactivate(options: deactivationOptions, completionHandler: completion)
                }
            } else {
                // iOS 15–26：挂起同样挪到后台队列，避免主线程阻塞。
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let optionsCopy = options
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try session.setActive(false, options: optionsCopy)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
}

private struct PlaybackSessionError: Error, CustomStringConvertible {
    enum Kind { case activation, deactivation }
    let kind: Kind
    var description: String {
        switch kind {
        case .activation: return "AVAudioSession 激活失败"
        case .deactivation: return "AVAudioSession 挂起失败"
        }
    }
}
#endif
