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

    /// 窗口切换状态机：防止快速连续点 Main/Mini 时两个 0.24s 动画重叠。
    private enum Transition {
        case idle
        case toMini
        case toMain
    }

    @Published public private(set) var mode: Mode = .main
    private var transition: Transition = .idle
    /// 动画进行中收到的反向请求（如 toMini 动画期间用户点 Dock 要回 Main）：
    /// 动画完成后接力执行，不吞掉用户最后一次操作。
    private var requestedModeAfterTransition: Mode?

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
        // 已在 Mini 且无进行中切换：直接置前即可（幂等）。
        if mode == .mini,
           transition == .idle {
            miniWindow?.makeKeyAndOrderFront(nil)
            return
        }

        // 切换动画进行中：记录待执行的模式，动画完成后接力，不吞用户最后一次操作。
        guard transition == .idle else {
            requestedModeAfterTransition = .mini
            return
        }

        // 请求一开始就进入 transition：避免「pending 置位但 transition 仍 idle」
        // 的空窗期——Mini Window 创建期间用户点 Dock 恢复时，旧 Mini 请求
        // 可能在注册完成后反扑、重新隐藏主窗口。
        transition = .toMini
        pendingMiniPresentation = true
        // 第一次使用 MiniPlayer 时先要求 SwiftUI 创建 Scene。
        openMiniWindow()

        if miniWindow != nil {
            completeMiniPresentation()
        }
    }

    private func completeMiniPresentation() {
        // 只有仍处于「请求中」才继续：restoreMainPlayer 取消 pending 后，
        // 迟到的 Mini 注册不应再自动完成切换（防止旧请求反扑）。
        guard transition == .toMini,
              pendingMiniPresentation,
              let mainWindow,
              let miniWindow
        else {
            return
        }

        pendingMiniPresentation = false

        if reduceMotionEnabled {
            mode = .mini
            transition = .idle
            miniWindow.makeKeyAndOrderFront(nil)
            // Mini 已经可见后再隐藏主窗口。
            mainWindow.orderOut(nil)
        } else {
            // 动画期间 transition 非 idle，阻止新的切换；完成后落 mode + idle。
            animateMainToMini(main: mainWindow, mini: miniWindow)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// 从 Mini 返回主窗口。`expandPlayer` 为 true 时同时展开 Expanded Player
    /// （用于 Mini 内「返回正在播放」）。
    ///
    /// 返回是否由本协调器处理了恢复：
    /// - `true`：主窗口存在且已恢复（调用方不应再让 AppKit 执行默认 reopen）；
    /// - `false`：没有可恢复的主窗口（调用方应交给系统默认行为）。
    @discardableResult
    public func restoreMainPlayer(expandPlayer: Bool) -> Bool {
        guard let mainWindow else {
            return false
        }

        // Mini 还在等待 Window 创建（transition == .toMini 且 pending）：
        // 用户现在明确要求 Main，取消尚未真正执行的 Mini 请求，防止
        // 迟到的 Mini 注册再反扑隐藏主窗口。
        if transition == .toMini,
           pendingMiniPresentation {
            pendingMiniPresentation = false
            transition = .idle
            mode = .main
            mainWindow.makeKeyAndOrderFront(nil)
            miniWindow?.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            if expandPlayer { revealNowPlaying() }
            return true
        }

        // 已在 Main 且无进行中切换：直接置前即可（幂等，例如 Mini 曾打开过
        // 但用户已回到主窗口后点击 Dock，不应再跑一次 Mini → Main 动画）。
        if mode == .main,
           transition == .idle {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if expandPlayer { revealNowPlaying() }
            return true
        }

        // 切换动画进行中：记录待执行的模式，动画完成后接力，不吞用户最后一次操作。
        guard transition == .idle else {
            requestedModeAfterTransition = .main
            return true
        }

        if let miniWindow, !reduceMotionEnabled {
            transition = .toMain
            animateMiniToMain(mini: miniWindow, main: mainWindow)
        } else {
            mode = .main
            transition = .idle
            mainWindow.makeKeyAndOrderFront(nil)
            miniWindow?.orderOut(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        if expandPlayer { revealNowPlaying() }
        return true
    }

    private func revealNowPlaying() {
        NotificationCenter.default.post(
            name: MacCommand.revealNowPlaying,
            object: nil
        )
    }

    /// 动画完成后的接力：执行动画期间记录的反向请求（.main → 回主窗口，
    /// .mini → 再去迷你播放器），保证用户最后一次操作不被吞掉。
    private func settleRequestedMode() {
        guard let requested = requestedModeAfterTransition else { return }
        requestedModeAfterTransition = nil
        switch requested {
        case .main:
            _ = restoreMainPlayer(expandPlayer: false)
        case .mini:
            requestMiniPlayer(openMiniWindow: { miniWindow?.makeKeyAndOrderFront(nil) })
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
                // coordinator 是 shared 单例，强捕获无生命周期风险。
                self.mode = .mini
                self.transition = .idle
                self.settleRequestedMode()
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
                // coordinator 是 shared 单例，强捕获无生命周期风险。
                self.mode = .main
                self.transition = .idle
                self.settleRequestedMode()
            }
        }
    }
}
#endif
