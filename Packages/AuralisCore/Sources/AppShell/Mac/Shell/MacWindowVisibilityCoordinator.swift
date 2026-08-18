#if os(macOS)
import AppKit
import SwiftUI

/// Mac 窗口模式协调器：负责「主窗口 / 迷你播放器」之间的双向切换。
///
/// 这是 Application Window Coordinator——「当前 App 是 Main 还是 Mini 模式」是
/// 全局状态，因此使用 `shared` 单例是合理的（与 per-window 的
/// `MacWindowChromeController` 不同）。
///
/// 职责：
/// - 主窗口 / Mini 窗口注册（窗口出现时由各自的 NSViewRepresentable 注册）；
/// - `requestMiniPlayer`：真正「切换到迷你播放器」——先确保 Mini Scene 已创建，
///   再隐藏主窗口，避免出现「多开一个窗口、主窗口还在」的半成品状态；
/// - `restoreMainPlayer`：从 Mini 返回主窗口（可选展开播放器），供 Mini 内按钮
///   与 Dock 图标点击（applicationShouldHandleReopen）共用。
@MainActor
public final class MacWindowVisibilityCoordinator: ObservableObject {
    public static let shared = MacWindowVisibilityCoordinator()

    public enum Mode: Sendable {
        case main
        case mini
    }

    @Published public private(set) var mode: Mode = .main

    private weak var mainWindow: NSWindow?
    private weak var miniWindow: NSWindow?

    private var pendingMiniPresentation = false

    public init() {}

    public func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindow = window
    }

    public func registerMiniWindow(_ window: NSWindow?) {
        guard let window else { return }
        miniWindow = window

        if pendingMiniPresentation {
            completeMiniPresentation()
        }
    }

    /// 切换到迷你播放器。第一次使用时会先要求 SwiftUI 创建 Mini Scene。
    public func requestMiniPlayer(openMiniWindow: () -> Void) {
        pendingMiniPresentation = true
        // 第一次使用 MiniPlayer 时先要求 SwiftUI 创建 Scene。
        openMiniWindow()

        if miniWindow != nil {
            completeMiniPresentation()
        }
    }

    private func completeMiniPresentation() {
        guard let mainWindow,
              let miniWindow
        else {
            return
        }

        pendingMiniPresentation = false
        mode = .mini

        miniWindow.makeKeyAndOrderFront(nil)

        // Mini 已经可见后再隐藏主窗口。
        mainWindow.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    /// 从 Mini 返回主窗口。`expandPlayer` 为 true 时同时展开 Expanded Player
    /// （用于 Mini 内「返回正在播放」）。
    public func restoreMainPlayer(expandPlayer: Bool) {
        guard let mainWindow else {
            return
        }

        mode = .main

        mainWindow.makeKeyAndOrderFront(nil)
        miniWindow?.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)

        if expandPlayer {
            NotificationCenter.default.post(
                name: MacCommand.revealNowPlaying,
                object: nil
            )
        }
    }
}
#endif
