import Domain
import Foundation
import Observability
#if os(iOS)
import AVFoundation
#endif

/// 音频会话协调（仅 iOS/iPadOS；macOS 无 AVAudioSession 播放会话概念）。
/// - 使用 .playback 分类，保证锁屏与后台继续播放。
/// - 播放开始前激活会话，停止后按策略挂起。
@MainActor
public final class AudioSessionCoordinator {
    public private(set) var isActive = false

    public init() {}

    /// 配置 .playback 分类。App 启动或首次播放前调用一次即可。
    /// 注意：AVAudioSession 必须在主线程调用，本类型已是 @MainActor，直接执行。
    public func configure() async {
        #if os(iOS)
        do {
            try await performSession(category: .playback)
        } catch {
            // 配置失败不致命：记录并继续，播放仍可能在前台工作
            AuralisLog.playback.error("音频会话配置分类失败：\(error.localizedDescription)")
        }
        #endif
    }

    /// 播放开始前激活音频会话。必须在主线程（本类型已是 @MainActor）。
    public func activate() async {
        #if os(iOS)
        do {
            try await performSession(active: true)
            isActive = true
        } catch {
            AuralisLog.playback.error("音频会话激活失败：\(error.localizedDescription)")
        }
        #endif
    }

    /// 停止播放时挂起会话，把音频焦点还给系统。必须在主线程（本类型已是 @MainActor）。
    public func deactivate() async {
        #if os(iOS)
        do {
            try await performSession(active: false, options: .notifyOthersOnDeactivation)
        } catch {
            AuralisLog.playback.error("音频会话挂起失败：\(error.localizedDescription)")
        }
        #endif
        isActive = false
    }

    #if os(iOS)
    /// AVAudioSession 必须在主线程调用（内部 dispatch_assert_queue 断言，
    /// 后台线程会触发 _dispatch_assert_queue_fail + err=-19431）。
    /// AudioSessionCoordinator 已是 @MainActor，configure/activate/deactivate 调用本就在主线程，
    /// 但系统明确警告：从主线程调用*同步* setActive 会阻塞 UI（AVAudioSession_iOS.mm:978）。
    /// 因此一律走异步 activate/deactivate API（见模块内 performAudioSession）。
    private func performSession(
        category: AVAudioSession.Category? = nil,
        mode: AVAudioSession.Mode = .default,
        active: Bool? = nil,
        options: AVAudioSession.SetActiveOptions = []
    ) async throws {
        try await performAudioSession(category: category, mode: mode, active: active, options: options)
    }
    #endif
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
    // allowAirPlay / allowBluetooth 让音频在隔空播放、蓝牙耳机等路由下也能持续，
    // 避免后台或外设切换时音频会话被系统挂起导致 App 被回收。
    // 注意：不要用已废弃的 allowBluetoothHFP，搭配 .playback 分类会返回 OSStatus -50（paramErr）。
    if let category {
        do {
            try session.setCategory(category, mode: mode, options: [.allowAirPlay, .allowBluetooth])
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

private struct AudioSessionError: Error, CustomStringConvertible {
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
