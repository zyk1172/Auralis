import Foundation
#if canImport(Network)
import Network
#endif

#if DEBUG
/// NWConnection 本地网络探测结果（仅 DEBUG 诊断用，不参与正式请求）。
///
/// 用途：定位 macOS「本地网络」权限链路。URLSession 只给出笼统的 -1009，
/// 用 NWConnection 直接观察连接状态机，尤其区分：
/// - `.waiting` + `unsatisfiedReason == .localNetworkDenied` → 本地网络隐私被拦截
/// - `.ready` → 本地网络 TCP 可达
struct LocalNetworkProbeResult: Sendable, Equatable {
    enum State: String, Sendable {
        case ready = "ready"
        case waiting = "waiting"
        case timedOut = "timedOut"
        case failed = "failed"
        case cancelled = "cancelled"
    }

    var state: State
    /// 最后一次 `.waiting` 的 unsatisfiedReason 字符串（如 "localNetworkDenied"）。
    var unsatisfiedReason: String?
    var errorDescription: String?
    var timestamp: Date

    /// 是否明确被本地网络隐私拦截。
    var isLocalNetworkDenied: Bool {
        unsatisfiedReason?.contains("localNetworkDenied") == true
    }
}
#endif

#if DEBUG
/// 仅 DEBUG 的 TCP 连通性 / 本地网络权限探测。
enum LocalNetworkProbe {
    /// 对 `host:port` 建立 NWConnection TCP 连接，观察状态机直到 ready / failed /
    /// cancelled / 超时。若期间出现 `.waiting(localNetworkDenied)` 且最终未 ready，
    /// 结果会保留该 unsatisfiedReason，供 UI 明确显示 DENIED / BLOCKED。
    static func probe(host: String, port: UInt16, timeout: TimeInterval = 10) async -> LocalNetworkProbeResult {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return LocalNetworkProbeResult(
                state: .failed,
                unsatisfiedReason: nil,
                errorDescription: "端口非法：\(port)",
                timestamp: .now
            )
        }
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let box = ProbeBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                box.handle(state, connection: connection)
            }
            connection.start(queue: .global(qos: .userInitiated))
            box.scheduleTimeout(after: timeout)
        }
    }
}

/// 状态盒：NWConnection 回调可能在不同队列触发，这里加锁保证结果只提交一次。
/// `NWConnection` 本身不是 Sendable，但所有访问都被限制在回调内部，
/// 跨线程只传递已序列化后的字符串结果。
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var continuation: CheckedContinuation<LocalNetworkProbeResult, Never>?
    private var timer: DispatchSourceTimer?
    private var lastWaitingReason: String?
    private var lastWaitingError: String?

    init(continuation: CheckedContinuation<LocalNetworkProbeResult, Never>) {
        self.continuation = continuation
    }

    func handle(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .preparing, .setup:
            return
        case .waiting(let error):
            // 记录等待原因，不立即结束：用户若在探测窗口内允许授权，连接会转为 ready。
            let reason: String
            if let path = connection.currentPath {
                reason = Self.describe(path.unsatisfiedReason)
            } else {
                reason = "unsatisfied"
            }
            lock.lock()
            lastWaitingReason = reason
            lastWaitingError = error.localizedDescription
            lock.unlock()
            return
        case .ready:
            finish(LocalNetworkProbeResult(
                state: .ready,
                unsatisfiedReason: nil,
                errorDescription: nil,
                timestamp: .now
            ))
            connection.cancel()
        case .failed(let error):
            finish(LocalNetworkProbeResult(
                state: .failed,
                unsatisfiedReason: nil,
                errorDescription: error.localizedDescription,
                timestamp: .now
            ))
            connection.cancel()
        case .cancelled:
            finish(LocalNetworkProbeResult(
                state: .cancelled,
                unsatisfiedReason: nil,
                errorDescription: nil,
                timestamp: .now
            ))
        @unknown default:
            return
        }
    }

    func scheduleTimeout(after interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let (reason, waitingError) = self.snapshot()
            self.finish(LocalNetworkProbeResult(
                state: .timedOut,
                unsatisfiedReason: reason,
                errorDescription: waitingError ?? "探测超时（\(Int(interval))s）",
                timestamp: .now
            ))
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func snapshot() -> (String?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastWaitingReason, lastWaitingError)
    }

    private func finish(_ result: LocalNetworkProbeResult) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let cont = continuation
        continuation = nil
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        cont?.resume(returning: result)
    }

    private static func describe(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: return "notAvailable"
        case .cellularDenied: return "cellularDenied"
        case .wifiDenied: return "wifiDenied"
        case .localNetworkDenied: return "localNetworkDenied"
        case .vpnInactive: return "vpnInactive"
        @unknown default: return "unknown(\(String(describing: reason)))"
        }
    }
}
#endif
