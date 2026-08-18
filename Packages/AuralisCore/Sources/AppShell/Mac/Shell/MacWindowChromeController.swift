#if os(macOS)
import AppKit

/// Mac 主窗口 chrome 的唯一所有者。
///
/// 标题显示分两个不同层次：
/// - SwiftUI toolbar title：由 `MacMusicShell.toolbar(removing: .title)` 处理
///   （Expanded 时移除 SwiftUI 自动生成的 default toolbar title/subtitle item，
///   normal 时传 nil 恢复页面标题）。这是「左上角出现 Auralis」的真正来源。
/// - AppKit native title：本控制器负责。`titleVisibility = .hidden` 在普通资料库
///   与 Expanded Player 都保持（内容区用 `navigationTitle` 显示页面标题，不需要
///   原生窗口标题再显示一次）。窗口语义标题 `window.title` 由 SwiftUI WindowGroup
///   管理（品牌名 `Auralis`），本控制器不修改它。
///
/// 本控制器只在 expanded / normal 之间切换：
/// - expanded：原生 traffic lights 隐藏、titlebar 透明；
/// - normal：原生 traffic lights 恢复、titlebar 不透明；
/// - 两种模式 titleVisibility 都是 .hidden。
///
/// 幂等写入：仅在实际属性与目标不一致时才修改；不做轮询 / KVO / Timer，
/// 也不修改 `window.title`，因此不存在「SwiftUI 写标题 → 我们再清掉」的竞争，
/// “Auralis 忽隐忽现”从状态模型上消失。
@MainActor
public final class MacWindowChromeController {
    private weak var window: NSWindow?
    private var isExpanded = false

    public init() {}

    /// 绑定/更新窗口引用（Expanded 的桥接视图进入/离开窗口时调用）。
    /// 传 nil 时保留最近一次非空窗口，避免收起播放器后丢失引用。
    public func attach(_ window: NSWindow?) {
        if let window { self.window = window }
        apply()
    }

    /// 设置展开状态并幂等应用。状态未变化也会调用 apply()，
    /// 用于在窗口出现时确保 titleVisibility 一直保持 hidden。
    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        apply()
    }

    /// 幂等应用：仅在属性与目标不一致时写入，正确状态下零开销。
    private func apply() {
        guard let window = window ?? NSApp.keyWindow else { return }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        let trafficTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in trafficTypes {
            let button = window.standardWindowButton(type)
            let hidden = isExpanded
            if (button?.isHidden ?? false) != hidden {
                button?.isHidden = hidden
            }
        }
        if window.titlebarAppearsTransparent != isExpanded {
            window.titlebarAppearsTransparent = isExpanded
        }
    }
}
#endif
