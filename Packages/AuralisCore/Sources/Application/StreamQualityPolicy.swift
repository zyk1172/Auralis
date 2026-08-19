import Foundation
import Network

/// 轻量网络路径跟踪：供流质量策略判断当前是否蜂窝网络。
/// 线程安全单例，NWPathMonitor 在专用队列上运行。
/// 网络接口类型（尽力而为，供诊断与流质量策略使用）。
public enum NetworkInterfaceType: Sendable {
    case wifi
    case cellular
    case ethernet
    case other
    case unknown
}

public final class NetworkPath: @unchecked Sendable {
    public static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "auralis.networkpath")
    private let lock = NSLock()
    private var _isCellular = false
    private var _interfaceType: NetworkInterfaceType = .unknown

    /// 当前是否使用蜂窝网络（无法判断时返回 false，即按 Wi-Fi/原始质量处理）。
    public var isCellular: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCellular
    }

    /// 当前活跃接口类型（monitor 已 start，实时更新；无法判断时为 .unknown）。
    public var interfaceType: NetworkInterfaceType {
        lock.lock()
        defer { lock.unlock() }
        return _interfaceType
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._isCellular = path.usesInterfaceType(.cellular)
            if path.usesInterfaceType(.wifi) {
                self._interfaceType = .wifi
            } else if path.usesInterfaceType(.cellular) {
                self._interfaceType = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                self._interfaceType = .ethernet
            } else if path.status == .satisfied {
                self._interfaceType = .other
            } else {
                self._interfaceType = .unknown
            }
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}

/// 流质量策略：把设置页的「Wi-Fi 优先原始音质 / 蜂窝允许转码」实时应用到流地址。
/// 设置值通过 UserDefaults 闭包读取，用户在设置页修改后无需重启即可生效。
/// - Wi-Fi：highQualityOnWiFi=true 时原始质量；否则限制码率以节省带宽。
/// - 蜂窝：cellularTranscodingAllowed=true 时转码为 MP3（320kbps 上限）；否则原始质量。
public struct StreamQualityPolicy: Sendable {
    public static let highQualityWiFiKey = "auralis.audio.highQualityWiFi"
    public static let cellularTranscodingKey = "auralis.audio.cellularTranscoding"

    public var highQualityOnWiFi: @Sendable () -> Bool
    public var cellularTranscodingAllowed: @Sendable () -> Bool
    public var isCellular: @Sendable () -> Bool

    public init(
        highQualityOnWiFi: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.object(forKey: StreamQualityPolicy.highQualityWiFiKey) as? Bool ?? true
        },
        cellularTranscodingAllowed: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.object(forKey: StreamQualityPolicy.cellularTranscodingKey) as? Bool ?? true
        },
        isCellular: @escaping @Sendable () -> Bool = { NetworkPath.shared.isCellular }
    ) {
        self.highQualityOnWiFi = highQualityOnWiFi
        self.cellularTranscodingAllowed = cellularTranscodingAllowed
        self.isCellular = isCellular
    }

    /// 需要限制的码率上限；nil 表示服务器原始质量。
    public var maxBitRate: Int? {
        if isCellular() {
            return cellularTranscodingAllowed() ? 320 : nil
        }
        return highQualityOnWiFi() ? nil : 320
    }

    /// 需要转码的目标格式；仅在限制码率时生效。
    public var format: String? {
        maxBitRate == nil ? nil : "mp3"
    }
}