#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import AppShell

/// Expanded Player 窗口 chrome 的窗口级测试：直接创建真实 `NSWindow`，
/// 应用 normal / expanded / normal 状态，验证属性（可自动验证，不需要真机）。
///
/// 标题显示分两个层次，本 Suite 只覆盖 AppKit 层：
/// - SwiftUI default toolbar title：由 `MacMusicShell.toolbar(removing: .title)`
///   （`ToolbarDefaultItemKind.title`）处理——Expanded 时移除、normal 时恢复。
///   创建裸 `NSWindow` 无法驱动 SwiftUI toolbar，因此本 Suite 无法验证该层。
/// - AppKit native title：本 Suite 验证。`titleVisibility` 在 normal 与 expanded
///   都保持 `.hidden`；`window.title` 允许保留语义标题 `Auralis`，不显示即可。
///
/// 设计契约：
/// - expanded：titlebar 透明；系统交通灯（关闭/最小化/缩放）保持可见，
///   不随 expanded 隐藏（HIG 禁止自绘/隐藏系统窗口控制按钮）；
/// - normal：titlebar 不透明；
/// - 两种模式 titleVisibility 都是 `.hidden`；
/// - 不做轮询 / KVO / Timer / 修改 window.title。
@Suite("Mac expanded window chrome")
struct MacExpandedChromeTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        return window
    }

    @Test("进入窗口即隐藏 titleVisibility，不显示原生窗口标题")
    @MainActor
    func attachHidesTitleVisibility() {
        let window = makeWindow()
        let controller = MacWindowChromeController()
        controller.attach(window)
        #expect(window.titleVisibility == .hidden)
    }

    @Test("normal：titleVisibility hidden、traffic lights 显示、titlebar 不透明")
    @MainActor
    func normalModeChrome() {
        let window = makeWindow()
        let controller = MacWindowChromeController()
        controller.attach(window)
        controller.setExpanded(false)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent == false)
        let trafficTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in trafficTypes {
            #expect(window.standardWindowButton(type)?.isHidden == false)
        }
    }

    @Test("expanded：titleVisibility 仍 hidden、系统交通灯保持可见、titlebar 透明")
    @MainActor
    func expandedModeChrome() {
        let window = makeWindow()
        let controller = MacWindowChromeController()
        controller.attach(window)
        controller.setExpanded(true)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent == true)
        // 系统交通灯不随 expanded 隐藏（HIG：不使用自绘/隐藏替代系统窗口控制）。
        let trafficTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in trafficTypes {
            #expect(window.standardWindowButton(type)?.isHidden == false)
        }
    }

    @Test("normal → expanded → normal 连续切换，native titleVisibility 全程 hidden")
    @MainActor
    func toggleCycleKeepsNativeTitleVisibilityHidden() {
        let window = makeWindow()
        let controller = MacWindowChromeController()
        controller.attach(window)
        for _ in 0..<30 {
            controller.setExpanded(true)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent == true)
            controller.setExpanded(false)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent == false)
        }
        // AppKit 层允许 NSWindow 保留语义 title。
        // Expanded Player 的 SwiftUI toolbar title item 由
        // MacMusicShell.toolbar(removing: .title) 单独处理。
        // 此测试只验证 AppKit fallback。
        window.title = "Auralis"
        controller.setExpanded(false)
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "Auralis")
    }

    @Test("状态已正确时幂等：不改变任何属性（零 titlebar 重排）")
    @MainActor
    func applyIsIdempotent() {
        let window = makeWindow()
        let controller = MacWindowChromeController()
        controller.attach(window)
        controller.setExpanded(true)
        // 手动“破坏”后再次 setExpanded(true) 应恢复；正确状态下重复调用不改值。
        window.titlebarAppearsTransparent = false
        controller.setExpanded(true)
        #expect(window.titlebarAppearsTransparent == true)
        controller.setExpanded(true) // 幂等
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.titleVisibility == .hidden)
    }

    @Test("attach(nil) 保留最近窗口引用，收起后仍能恢复 traffic lights")
    @MainActor
    func attachNilKeepsWindowReference() {
        let window = makeWindow()
        let controller = MacWindowChromeController()
        controller.attach(window)
        controller.setExpanded(true)
        // 收起：Expanded 桥接视图被移除 → attach(nil)。
        controller.attach(nil)
        controller.setExpanded(false)
        // 仍能恢复（弱引用窗口存活时）。
        #expect(window.titlebarAppearsTransparent == false)
        let trafficTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in trafficTypes {
            #expect(window.standardWindowButton(type)?.isHidden == false)
        }
        #expect(window.titleVisibility == .hidden)
    }
}
#endif
