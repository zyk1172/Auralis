import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 打开系统的「本地网络」隐私设置。
///
/// macOS 没有公开 API 可以主动弹出授权框或查询授权状态：
/// - 首次连接局域网地址时，系统会自动弹出「本地网络」授权框（前提：Info.plist
///   已声明 NSLocalNetworkUsageDescription 且 App 已签名并启用 App Sandbox）；
/// - 一旦之前被拒绝过（或描述后加导致系统记住了拒绝状态），系统不会再弹窗，
///   只能跳转到「系统设置 → 隐私与安全性 → 本地网络」手动打开。
///
/// 这里提供一键跳转，尽量打开「本地网络」精确面板，失败时回退到「隐私与安全性」。
public enum PlatformLocalNetworkSettings {
    /// 打开本地网络设置面板。必须在主线程调用。
    @MainActor
    public static func open() {
#if os(macOS)
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
#elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
#endif
    }
}
