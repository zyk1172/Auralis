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
/// - expanded：titlebar 透明（系统 traffic lights 保持在默认左上角，不隐藏）；
/// - normal：titlebar 不透明；
/// - 两种模式 titleVisibility 都是 .hidden。
///
/// 窗口控制按钮（关闭 / 最小化 / 缩放）始终使用系统 standard window buttons，
/// 不做自绘替代，也不通过 NSApp.keyWindow 操作窗口（多窗口时 keyWindow 不可靠）。
///
/// 对三个系统按钮做**整组位置校正**（layoutTrafficLights）：
/// macOS 默认的 traffic lights 位置视觉上过于靠近顶部边缘，且 SwiftUI window
/// toolbar 布局还会把它们推到错误的垂直基线。因此无论 normal 还是 expanded，
/// 都把 close / miniaturize / zoom 作为一个整体对齐到统一中心线
/// （MacUIVisualTokens.WindowChrome.controlCenterFromTop = 28pt）——
/// 保持横向顺序与相对间距、只修垂直。播放页左右胶囊（topLeft/RightGlass）也
/// 微调到同一中心线，整条主窗口所有页面的顶部控件在一条水平线上。
/// 事件驱动（首次显示 / 切换 / resize / 成为 key / 全屏进出），不做轮询。
///
/// 幂等写入：仅在实际属性与目标不一致时才修改；不做轮询 / KVO / Timer，
/// 也不修改 `window.title`，因此不存在「SwiftUI 写标题 → 我们再清掉」的竞争，
/// “Auralis 忽隐忽现”从状态模型上消失。
@MainActor
public final class MacWindowChromeController {
    private weak var window: NSWindow?
    private var isExpanded = false
    /// 布局相关通知 observer（resize / 全屏进出），窗口切换时重建。
    private nonisolated(unsafe) var trafficLightObservers: [NSObjectProtocol] = []
    private nonisolated(unsafe) weak var observedWindow: NSWindow?

    public init() {}

    deinit {
        // removeObserver 线程安全；deinit 是 nonisolated，直接读 nonisolated(unsafe) 存储。
        for observer in trafficLightObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 绑定/更新窗口引用（Expanded 的桥接视图进入/离开窗口时调用）。
    /// 传 nil 时保留最近一次非空窗口，避免收起播放器后丢失引用。
    public func attach(_ window: NSWindow?) {
        if let window {
            self.window = window
            installTrafficLightObservers(for: window)
        }
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
        // 不再猜 NSApp.keyWindow：App 现在有 Main / Mini / Settings 多个窗口，
        // keyWindow 可能不是主窗口。本控制器只属于 Main Attacher。
        guard let window else { return }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        // 系统 close / miniaturize / zoom 按钮始终保持可见（不随 expanded 隐藏），
        // 避免自绘交通灯替代系统窗口控制（HIG 明确禁止自定义窗口控制按钮）。
        if window.titlebarAppearsTransparent != isExpanded {
            window.titlebarAppearsTransparent = isExpanded
        }
        layoutTrafficLights()
    }

    // MARK: - Traffic lights 整组位置校正

    /// 把三个系统窗口按钮（close / miniaturize / zoom）作为**一组**校正：
    /// - 无论 normal / expanded，都把整组中心对齐到距 container 顶部 28pt 的
    ///   统一中心线（与播放页左右胶囊的 28pt 中心线重合）；
    /// - 只动 y，保持系统横向顺序、间距与靠左位置，不改尺寸；
    /// - 幂等：与目标差异超过容差才写入；三个按钮必须在同一 container 才操作。
    /// internal：didResize / didBecomeKey / 全屏进出通知回调与回归测试共用同一入口。
    func layoutTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview,
              mini.superview === container,
              zoom.superview === container
        else { return }

        let targetCenterFromTop = MacUIVisualTokens.WindowChrome.controlCenterFromTop
        // AppKit 普通 NSView 坐标系从底部向上；container 是 flipped 时从顶部向下。
        let targetCenterY: CGFloat
        if container.isFlipped {
            targetCenterY = targetCenterFromTop
        } else {
            targetCenterY = container.bounds.maxY - targetCenterFromTop
        }
        let currentCenterY = close.frame.midY
        let dy = targetCenterY - currentCenterY
        guard abs(dy) > MacUIVisualTokens.WindowChrome.trafficLightVerticalTolerance else { return }
        for button in [close, mini, zoom] {
            var frame = button.frame
            frame.origin.y += dy
            button.frame = frame
        }
    }

    /// 安装布局通知（窗口首次显示 / resize / 全屏进出后系统可能重排 traffic lights）。
    /// 事件驱动、幂等：仅当绑定窗口变化时重建 observer。
    private func installTrafficLightObservers(for window: NSWindow) {
        guard observedWindow !== window else { return }
        removeTrafficLightObservers()
        observedWindow = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        trafficLightObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.layoutTrafficLights()
                }
            }
        }
    }

    private func removeTrafficLightObservers() {
        for observer in trafficLightObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        trafficLightObservers = []
        observedWindow = nil
    }
}
#endif
