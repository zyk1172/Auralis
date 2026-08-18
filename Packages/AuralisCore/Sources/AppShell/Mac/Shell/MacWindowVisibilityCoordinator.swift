#if os(macOS)
import AppKit
import QuartzCore
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

    /// Main ↔ Mini 窗口切换动画时长。只做轻微 frame 缩放 + alpha 交叉，
    /// 不把 1280×820 主窗口真正一路 resize 到 Mini 尺寸，避免复杂 UI 重排。
    private let switchDuration: TimeInterval = 0.24

    /// 系统「减少动态效果」开启时不做窗口动画，直接切换。
    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private weak var mainWindow: NSWindow?
    private weak var miniWindow: NSWindow?

    private var pendingMiniPresentation = false

    public init() {}

    public func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindow = window

        // Main 稍晚注册（updateNSView 时 view.window 可能为 nil，直到
        // viewDidMoveToWindow 才真正就绪）时，若切换已 pending 且 Mini 已存在，
        // 继续完成切换，避免一直卡在「Mini 已显示、Main 未隐藏」。
        if pendingMiniPresentation,
           miniWindow != nil {
            completeMiniPresentation()
        }
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

        if reduceMotionEnabled {
            miniWindow.makeKeyAndOrderFront(nil)
            // Mini 已经可见后再隐藏主窗口。
            mainWindow.orderOut(nil)
        } else {
            animateMainToMini(main: mainWindow, mini: miniWindow)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// 从 Mini 返回主窗口。`expandPlayer` 为 true 时同时展开 Expanded Player
    /// （用于 Mini 内「返回正在播放」）。
    public func restoreMainPlayer(expandPlayer: Bool) {
        guard let mainWindow else {
            return
        }

        mode = .main

        if let miniWindow, !reduceMotionEnabled {
            animateMiniToMain(mini: miniWindow, main: mainWindow)
        } else {
            mainWindow.makeKeyAndOrderFront(nil)
            miniWindow?.orderOut(nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        if expandPlayer {
            NotificationCenter.default.post(
                name: MacCommand.revealNowPlaying,
                object: nil
            )
        }
    }

    // MARK: - 窗口切换动画

    /// Main → Mini：主窗口轻微缩小淡出，Mini 放大就位。
    private func animateMainToMini(main: NSWindow, mini: NSWindow) {
        let mainFrame = main.frame
        let miniFrame = mini.frame
        let reducedMainFrame = mainFrame.insetBy(
            dx: mainFrame.width * 0.025,
            dy: mainFrame.height * 0.025
        )
        let enlargedMiniFrame = miniFrame.insetBy(
            dx: -miniFrame.width * 0.04,
            dy: -miniFrame.height * 0.04
        )

        mini.alphaValue = 0
        mini.setFrame(enlargedMiniFrame, display: false)
        mini.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = switchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            main.animator().alphaValue = 0
            main.animator().setFrame(reducedMainFrame, display: true)
            mini.animator().alphaValue = 1
            mini.animator().setFrame(miniFrame, display: true)
        } completionHandler: {
            Task { @MainActor in
                main.orderOut(nil)
                // 恢复标准状态，下一次打开不能继承动画 frame。
                main.setFrame(mainFrame, display: false)
                main.alphaValue = 1
                mini.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Mini → Main：反向——Mini 轻微放大淡出，主窗口缩小就位放大。
    private func animateMiniToMain(mini: NSWindow, main: NSWindow) {
        let mainFrame = main.frame
        let miniFrame = mini.frame
        let reducedMainFrame = mainFrame.insetBy(
            dx: mainFrame.width * 0.025,
            dy: mainFrame.height * 0.025
        )
        let enlargedMiniFrame = miniFrame.insetBy(
            dx: -miniFrame.width * 0.04,
            dy: -miniFrame.height * 0.04
        )

        main.alphaValue = 0
        main.setFrame(reducedMainFrame, display: false)
        main.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = switchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mini.animator().alphaValue = 0
            mini.animator().setFrame(enlargedMiniFrame, display: true)
            main.animator().alphaValue = 1
            main.animator().setFrame(mainFrame, display: true)
        } completionHandler: {
            Task { @MainActor in
                mini.orderOut(nil)
                mini.setFrame(miniFrame, display: false)
                mini.alphaValue = 1
                main.makeKeyAndOrderFront(nil)
            }
        }
    }
}
#endif
