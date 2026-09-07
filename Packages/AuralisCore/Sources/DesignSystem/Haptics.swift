import SwiftUI

#if os(iOS)
import UIKit

@MainActor
private final class HapticFeedbackPool {
    static let shared = HapticFeedbackPool()

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    func prepare() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        rigid.prepare()
        soft.prepare()
        selection.prepare()
        notification.prepare()
    }

    func impact(_ style: HapticImpact, intensity: Double) {
        let generator: UIImpactFeedbackGenerator = switch style {
        case .light: light
        case .medium: medium
        case .heavy: heavy
        case .rigid: rigid
        case .soft: soft
        }
        generator.prepare()
        generator.impactOccurred(intensity: CGFloat(min(max(intensity, 0), 1)))
    }

    func selectionChanged() {
        selection.prepare()
        selection.selectionChanged()
    }

    func notificationOccurred(_ type: HapticNotification) {
        notification.prepare()
        notification.notificationOccurred(type.uiType)
    }
}
#endif

/// 全局触感反馈封装。iOS 设备上有真实震动；macOS 与其它平台为空操作，
/// 因此调用点无需任何平台判断。
public enum Haptics {
    /// Warm the reusable UIKit feedback generators during app/session startup.
    /// This keeps the first interaction out of the generator construction path.
    @MainActor
    public static func prepare() {
        #if os(iOS)
        HapticFeedbackPool.shared.prepare()
        #endif
    }

    /// 按下反馈：轻微冲击，适合按钮点击（轻）。
    @MainActor
    public static func impact(_ style: HapticImpact = .light, intensity: Double = 1.0) {
        #if os(iOS)
        Task { @MainActor in
            // The button action wins this MainActor turn. Tactile feedback is
            // best-effort and may arrive one yield later, so a play tap can
            // enter the audio path before UIKit prepares/fires the generator.
            await Task.yield()
            HapticFeedbackPool.shared.impact(style, intensity: intensity)
        }
        #endif
    }

    /// 选择反馈：适合值变化、切换等「选中」语义（缓）。
    @MainActor
    public static func selection() {
        #if os(iOS)
        Task { @MainActor in
            await Task.yield()
            HapticFeedbackPool.shared.selectionChanged()
        }
        #endif
    }

    /// 通知反馈：成功 / 警告 / 错误（急）。
    @MainActor
    public static func notification(_ type: HapticNotification) {
        #if os(iOS)
        Task { @MainActor in
            await Task.yield()
            HapticFeedbackPool.shared.notificationOccurred(type)
        }
        #endif
    }
}

public enum HapticImpact: Sendable {
    case light, medium, heavy, rigid, soft

    #if os(iOS)
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        case .rigid: .rigid
        case .soft: .soft
        }
    }
    #endif
}

public enum HapticNotification: Sendable {
    case success, warning, error

    #if os(iOS)
    var uiType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
    #endif
}

// MARK: - 全局按钮样式（轻重缓急）

/// 自定义 ButtonStyle 里禁止再对 `configuration.label` 写 `.buttonStyle(...)`。
/// `configuration.label` 已经不是外层 Button 本身；继续写 ButtonStyle 不会给当前按钮
/// 补上系统外观，反而会把样式环境传播给 label 子树。`Menu` / `contextMenu` / Picker
/// 这类复合系统控件会临时创建内部 Button，继承到该环境后可能出现一次点击不触发、
/// 必须重复点击的命中问题。触感样式只负责触感，系统/调用点负责视觉样式。

/// 默认轻触（轻）：作为根视图的兜底样式，对未显式设置样式的按钮生效。
public struct HapticButtonStyle: ButtonStyle, Sendable {
    public var impact: HapticImpact

    public init(impact: HapticImpact = .light) {
        self.impact = impact
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(impact)
                }
            }
    }
}

/// 主操作（重）：触发重冲击。视觉外观由调用点提供，不向 label 子树传播 ButtonStyle。
public struct HapticProminentButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.heavy)
                }
            }
    }
}

/// 次级操作（缓）：触发柔和冲击。视觉外观由调用点提供，不污染 Menu 的内部按钮环境。
public struct HapticBorderedButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.soft)
                }
            }
    }
}

/// 朴素按钮（轻）：保留调用点自己的外观，只附加轻微冲击。
/// 特别注意：列表行经常附带 `contextMenu`，这里不能再向 label 子树写 `.plain`。
public struct HapticPlainButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.light)
                }
            }
    }
}

/// 无边框按钮（轻）：只附加触感，不向复合控件子树传播 ButtonStyle。
public struct HapticBorderlessButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.light)
                }
            }
    }
}

/// 破坏性操作（急）：触发错误通知震动；视觉外观由调用点提供。
public struct HapticDestructiveButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.notification(.error)
                }
            }
    }
}
