#if os(macOS)
import os

/// 轻量 UI 动作日志（Debug 构建启用，Release 不输出），供真机点击验收时核对业务结果。
/// 只记录关键动作，不 spam。
enum MacUITrace {
    private static let log = Logger(subsystem: "com.auralis.player.macos", category: "ui")

    static func action(_ name: StaticString, _ detail: String = "") {
        #if DEBUG
        if detail.isEmpty {
            log.debug("action \(String(describing: name), privacy: .public)")
        } else {
            log.debug("action \(String(describing: name), privacy: .public) — \(detail, privacy: .public)")
        }
        #endif
    }
}
#endif
