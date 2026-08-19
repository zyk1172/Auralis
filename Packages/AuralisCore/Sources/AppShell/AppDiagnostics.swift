import Foundation
#if os(macOS)
import Security
#endif

/// DEBUG 网络诊断：用于排查 macOS「本地网络」权限链路。
/// 只读取客观事实（Bundle ID / Target / 沙盒 / 描述文案 / 签名 entitlement），不伪造权限状态。
enum AppDiagnostics {
    /// 当前运行 App 的 Bundle Identifier。
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "未知"
    }

    /// 当前运行形态：原生 macOS / iOS（与「Designed for iPad / Catalyst」区分）。
    static var targetKind: String {
        #if os(macOS)
        return String(localized: "原生 macOS（AuralisMac target）", bundle: .module)
        #else
        return "iOS"
        #endif
    }

    /// App Sandbox 是否启用：沙盒 App 会注入 APP_SANDBOX_CONTAINER_ID 环境变量（公开可查）。
    static var isAppSandboxEnabled: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// 最终 Info.plist 是否声明了 NSLocalNetworkUsageDescription。
    static var localNetworkUsageDescription: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
    }

    /// 当前签名是否包含 com.apple.security.network.client（Outgoing Connections）。
    /// 用 dlsym 取私有 SecTask 函数（仅 DEBUG 构建，避免引用私有头文件；Release 返回 false）。
    static var hasNetworkClientEntitlement: Bool {
        #if DEBUG && os(macOS)
        typealias SecTaskCopyValueFn = @convention(c) (CFTypeRef?, CFString, UnsafeMutablePointer<CFError?>?) -> CFTypeRef?
        typealias SecTaskCreateFromSelfFn = @convention(c) (CFError?) -> CFTypeRef?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let copySym = dlsym(handle, "SecTaskCopyValueForEntitlement"),
              let createSym = dlsym(handle, "SecTaskCreateFromSelf")
        else { return false }
        let copyFn = unsafeBitCast(copySym, to: SecTaskCopyValueFn.self)
        let createFn = unsafeBitCast(createSym, to: SecTaskCreateFromSelfFn.self)
        guard let task = createFn(nil) else { return false }
        let value = copyFn(task, "com.apple.security.network.client" as CFString, nil)
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
        #else
        return false
        #endif
    }
}