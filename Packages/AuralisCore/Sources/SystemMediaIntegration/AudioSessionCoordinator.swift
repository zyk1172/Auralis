import Domain
import Foundation
import Observability
#if os(iOS)
import AVFoundation
#endif

internal enum AudioSessionRequest: Sendable, Equatable {
    case configurePlayback
    case activate
    case deactivate
}

internal typealias AudioSessionOperation = @MainActor @Sendable (AudioSessionRequest) async throws -> Void

/// 音频会话协调（仅 iOS/iPadOS；macOS 无 AVAudioSession 播放会话概念）。
/// - 使用 .playback 分类，保证锁屏与后台继续播放。
/// - 播放开始前激活会话，停止后按策略挂起。
@MainActor
public final class AudioSessionCoordinator {
    public private(set) var isActive = false
    private var isConfigured = false
    private var configurationTask: Task<Bool, Never>?
    private var configurationTaskID = 0
    private var activationTask: Task<Bool, Never>?
    private var activationTaskID = 0
    private var configurationAttemptCount = 0
    private var lastConfigurationError: String?
    private var configurationGeneration = 0
    private let sessionOperation: AudioSessionOperation?

    public init() {
        #if os(iOS)
        sessionOperation = { request in
            switch request {
            case .configurePlayback:
                try await performAudioSession(category: .playback)
            case .activate:
                try await performAudioSession(active: true)
            case .deactivate:
                try await performAudioSession(active: false, options: .notifyOthersOnDeactivation)
            }
        }
        #else
        sessionOperation = nil
        #endif
    }

    internal init(sessionOperation: @escaping AudioSessionOperation) {
        self.sessionOperation = sessionOperation
    }

    /// 配置 .playback 分类。成功后复用；失败时下一次调用会重新尝试。
    /// 注意：AVAudioSession 必须在主线程调用，本类型已是 @MainActor，直接执行。
    @discardableResult
    public func configure() async -> Bool {
        guard sessionOperation != nil else { return true }

        if isConfigured {
            logConfiguration(
                duration: .zero,
                skipped: true,
                active: isActive,
                operation: "configure"
            )
            return true
        }

        if let configurationTask {
            let success = await configurationTask.value
            logConfiguration(
                duration: .zero,
                skipped: true,
                active: isActive,
                operation: "configure_wait"
            )
            return success
        }

        configurationAttemptCount += 1
        let generation = configurationGeneration
        configurationTaskID &+= 1
        let taskID = configurationTaskID
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self, let sessionOperation = self.sessionOperation else { return false }
            let startedAt = ContinuousClock.now
            do {
                try await sessionOperation(.configurePlayback)
                guard self.configurationGeneration == generation else {
                    self.isConfigured = false
                    self.isActive = false
                    self.lastConfigurationError = "系统音频事件使本次配置失效"
                    self.logConfiguration(
                        duration: self.durationMs(startedAt.duration(to: .now)),
                        skipped: false,
                        active: false,
                        operation: "configure_invalidated"
                    )
                    return false
                }
                self.isConfigured = true
                self.lastConfigurationError = nil
                self.logConfiguration(
                    duration: self.durationMs(startedAt.duration(to: .now)),
                    skipped: false,
                    active: self.isActive,
                    operation: "configure"
                )
                return true
            } catch {
                self.isConfigured = false
                self.isActive = false
                self.lastConfigurationError = error.localizedDescription
                AuralisLog.playback.error("音频会话配置分类失败：\(error.localizedDescription)")
                self.logConfiguration(
                    duration: self.durationMs(startedAt.duration(to: .now)),
                    skipped: false,
                    active: false,
                    operation: "configure"
                )
                return false
            }
        }
        configurationTask = task
        let success = await task.value
        if configurationTaskID == taskID {
            configurationTask = nil
        }
        return success
    }

    /// 播放开始前激活音频会话。必须在主线程（本类型已是 @MainActor）。
    public func activate() async {
        guard let sessionOperation else { return }

        if let activationTask {
            _ = await activationTask.value
            return
        }

        activationTaskID &+= 1
        let taskID = activationTaskID
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performActivation(sessionOperation: sessionOperation)
        }
        activationTask = task
        _ = await task.value
        if activationTaskID == taskID {
            activationTask = nil
        }
    }

    /// Attempts one activation transition at a time. A system audio event can
    /// invalidate either the configuration or the activation while its async
    /// operation is suspended, so both phases validate the same generation.
    /// The bounded retry prevents a continuously unstable audio service from
    /// creating an unbounded activation loop.
    private func performActivation(sessionOperation: AudioSessionOperation) async -> Bool {
        for attempt in 0..<2 {
            let generation = configurationGeneration
            let configured = await configure()
            guard configured,
                  isConfigured,
                  generation == configurationGeneration
            else {
                if attempt == 0, generation != configurationGeneration {
                    continue
                }
                isActive = false
                logConfiguration(
                    duration: .zero,
                    skipped: false,
                    active: false,
                    operation: "activate_unconfigured"
                )
                return false
            }

            guard !isActive else {
                logConfiguration(
                    duration: .zero,
                    skipped: true,
                    active: true,
                    operation: "activate"
                )
                return true
            }

            let startedAt = ContinuousClock.now
            do {
                try await sessionOperation(.activate)
            } catch {
                isConfigured = false
                isActive = false
                lastConfigurationError = error.localizedDescription
                AuralisLog.playback.error("音频会话激活失败：\(error.localizedDescription)")
                logConfiguration(
                    duration: durationMs(startedAt.duration(to: .now)),
                    skipped: false,
                    active: false,
                    operation: "activate"
                )
                if attempt == 0, generation != configurationGeneration {
                    continue
                }
                return false
            }

            guard generation == configurationGeneration, isConfigured else {
                isActive = false
                lastConfigurationError = "系统音频事件使本次激活失效"
                logConfiguration(
                    duration: durationMs(startedAt.duration(to: .now)),
                    skipped: false,
                    active: false,
                    operation: "activate_invalidated"
                )
                if attempt == 0 {
                    continue
                }
                return false
            }

            isActive = true
            logConfiguration(
                duration: durationMs(startedAt.duration(to: .now)),
                skipped: false,
                active: true,
                operation: "activate"
            )
            return true
        }

        return false
    }

    /// 停止播放时挂起会话，把音频焦点还给系统。必须在主线程（本类型已是 @MainActor）。
    public func deactivate() async {
        guard let sessionOperation else { return }

        guard isActive else {
            logConfiguration(
                duration: .zero,
                skipped: true,
                active: false,
                operation: "deactivate"
            )
            return
        }
        let startedAt = ContinuousClock.now
        do {
            try await sessionOperation(.deactivate)
            logConfiguration(
                duration: durationMs(startedAt.duration(to: .now)),
                skipped: false,
                active: false,
                operation: "deactivate"
            )
        } catch {
            AuralisLog.playback.error("音频会话挂起失败：\(error.localizedDescription)")
            logConfiguration(
                duration: durationMs(startedAt.duration(to: .now)),
                skipped: false,
                active: true,
                operation: "deactivate"
            )
            return
        }
        isActive = false
    }

    /// Route/interruption/media-service events can invalidate the underlying
    /// AVAudioSession outside this object's control. The next activation may
    /// configure it once again; ordinary track switches never call this.
    public func invalidateForSystemAudioEvent() {
        // Do not cancel a checked continuation inside an in-flight async
        // activation/configuration. Let the owning transition settle so its
        // generation check can discard the result and retry if appropriate.
        configurationGeneration &+= 1
        isConfigured = false
        isActive = false
    }

    /// AVAudioSession 必须在主线程调用（内部 dispatch_assert_queue 断言，
    /// 后台线程会触发 _dispatch_assert_queue_fail + err=-19431）。
    /// AudioSessionCoordinator 已是 @MainActor，configure/activate/deactivate 调用本就在主线程，
    /// 但系统明确警告：从主线程调用*同步* setActive 会阻塞 UI（AVAudioSession_iOS.mm:978）。
    /// 因此一律走异步 activate/deactivate API（见模块内 performAudioSession）。
    private func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func logConfiguration(
        duration: Double,
        skipped: Bool,
        active: Bool,
        operation: String
    ) {
        let lastError = lastConfigurationError ?? "none"
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let actualCategory = session.category.rawValue
        let actualMode = session.mode.rawValue
        let routeOutputs = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        AuralisLog.playback.debug(
            "ENGINE_CONFIG_SESSION_MS duration_ms=\(duration, privacy: .public) operation=\(operation, privacy: .public) skipped=\(skipped, privacy: .public) active=\(active, privacy: .public) configured=\(self.isConfigured, privacy: .public) configuration_in_flight=\(self.configurationTask != nil, privacy: .public) activation_in_flight=\(self.activationTask != nil, privacy: .public) configuration_attempt_count=\(self.configurationAttemptCount, privacy: .public) last_configuration_error=\(lastError, privacy: .public) actual_category=\(actualCategory, privacy: .public) actual_mode=\(actualMode, privacy: .public) secondary_audio_silenced=\(session.secondaryAudioShouldBeSilencedHint, privacy: .public) route_outputs=\(routeOutputs, privacy: .public)"
        )
        #else
        AuralisLog.playback.debug(
            "ENGINE_CONFIG_SESSION_MS duration_ms=\(duration, privacy: .public) operation=\(operation, privacy: .public) skipped=\(skipped, privacy: .public) active=\(active, privacy: .public) configured=\(self.isConfigured, privacy: .public) configuration_in_flight=\(self.configurationTask != nil, privacy: .public) activation_in_flight=\(self.activationTask != nil, privacy: .public) configuration_attempt_count=\(self.configurationAttemptCount, privacy: .public) last_configuration_error=\(lastError, privacy: .public)"
        )
        #endif
    }
}

#if os(iOS)
/// 模块内共享：在主线程用**异步** API 激活/挂起 AVAudioSession。
/// 同步 setActive 在 iOS 上会从主线程触发
/// "This method can lead to UI unresponsiveness if called on the main thread"（AVAudioSession_iOS.mm:978）。
/// 改用 activateWithOptions / deactivateWithOptions 的异步 completionHandler 形式（iOS 27+），
/// 既满足 AVAudioSession 的主线程要求，又不阻塞 UI；iOS 18–26 退回同步 setActive。
internal func performAudioSession(
    category: AVAudioSession.Category? = nil,
    mode: AVAudioSession.Mode = .default,
    active: Bool? = nil,
    options: AVAudioSession.SetActiveOptions = []
) async throws {
    let session = AVAudioSession.sharedInstance()
    // 只使用与 category 合法匹配的 options。allowBluetoothHFP 只能用于
    // .record / .playAndRecord；搭配 .playback 会返回 OSStatus -50 (paramErr)。
    if let category {
        try session.setCategory(category, mode: mode, options: categoryOptions(for: category))
        guard session.category.rawValue == category.rawValue else {
            throw AudioSessionError(kind: .configuration)
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
                                ?? AudioSessionError(kind: .activation))
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
                                ?? AudioSessionError(kind: .deactivation))
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

/// 每个分类允许的路由选项：allowBluetoothHFP 只能用于 .record / .playAndRecord，
/// 搭配 .playback 会返回 OSStatus -50（paramErr）；其余分类不附加任何选项。
private func categoryOptions(for category: AVAudioSession.Category) -> AVAudioSession.CategoryOptions {
    switch category {
    case .playback:
        return [.allowAirPlay]
    case .playAndRecord:
        return [.allowAirPlay, .allowBluetoothHFP]
    default:
        return []
    }
}

private struct AudioSessionError: Error, CustomStringConvertible {
    enum Kind { case configuration, activation, deactivation }
    let kind: Kind
    var description: String {
        switch kind {
        case .configuration: return "AVAudioSession 分类配置未生效"
        case .activation: return "AVAudioSession 激活失败"
        case .deactivation: return "AVAudioSession 挂起失败"
        }
    }
}
#endif

/// 电话/ Siri 等音频中断处理：中断开始暂停，结束后按系统建议恢复。
@MainActor
public final class AudioInterruptionCoordinator {
    private var observer: NSObjectProtocol?
    private var onInterruptionBegan: () -> Void = {}
    private var onInterruptionShouldResume: () -> Void = {}

    public init() {}

    /// 决策逻辑提取为纯函数，便于测试。
    public static func shouldResume(options: UInt) -> Bool {
        #if os(iOS)
        AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
        #else
        false
        #endif
    }

    public func start(onBegan: @escaping () -> Void, onShouldResume: @escaping () -> Void) {
        stop()
        onInterruptionBegan = onBegan
        onInterruptionShouldResume = onShouldResume
        #if os(iOS)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            let kind: InterruptionKind = (type == .began) ? .began : .ended
            let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handle(type: kind, options: options)
            }
        }
        #endif
    }

    func handle(type: InterruptionKind, options: UInt) {
        switch type {
        case .began:
            onInterruptionBegan()
        case .ended:
            if Self.shouldResume(options: options) { onInterruptionShouldResume() }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// 与平台解耦的中断类型，便于跨平台编译与测试。
    public enum InterruptionKind: Sendable {
        case began
        case ended
    }
}

/// 输出路由变化处理：拔掉耳机（旧输出设备不可用）时自动暂停。
@MainActor
public final class AudioRouteCoordinator {
    private var observer: NSObjectProtocol?
    private var onOutputDetached: () -> Void = {}
    private var onRouteChanged: () -> Void = {}

    public init() {}

    /// 决策逻辑提取为纯函数，便于测试。
    public static func shouldPause(reason: UInt) -> Bool {
        #if os(iOS)
        AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable
        #else
        false
        #endif
    }

    public static func shouldReactivate(reason: UInt) -> Bool {
        #if os(iOS)
        let value = AVAudioSession.RouteChangeReason(rawValue: reason)
        return value == .newDeviceAvailable || value == .routeConfigurationChange
            || value == .categoryChange || value == .override
        #else
        false
        #endif
    }

    public func start(
        onOutputDetached: @escaping () -> Void,
        onRouteChanged: @escaping () -> Void = {}
    ) {
        stop()
        self.onOutputDetached = onOutputDetached
        self.onRouteChanged = onRouteChanged
        #if os(iOS)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            Task { @MainActor [weak self] in
                self?.handle(reason: reason)
            }
        }
        #endif
    }

    func handle(reason: UInt) {
        if Self.shouldPause(reason: reason) {
            onOutputDetached()
        } else if Self.shouldReactivate(reason: reason) {
            // 新设备（蓝牙/AirPlay/有线）接入后重新激活会话，确保后台持续输出。
            onRouteChanged()
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
