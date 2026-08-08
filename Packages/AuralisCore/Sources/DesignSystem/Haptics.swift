import SwiftUI

#if os(iOS)
import UIKit
#endif

/// 全局触感反馈封装。iOS 设备上有真实震动；macOS 与其它平台为空操作，
/// 因此调用点无需任何平台判断。
public enum Haptics {
    /// 按下反馈：轻微冲击，适合按钮点击（轻）。
    @MainActor
    public static func impact(_ style: HapticImpact = .light, intensity: Double = 1.0) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: style.uiStyle).impactOccurred(intensity: CGFloat(intensity))
        #endif
    }

    /// 选择反馈：适合值变化、切换等「选中」语义（缓）。
    @MainActor
    public static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// 通知反馈：成功 / 警告 / 错误（急）。
    @MainActor
    public static func notification(_ type: HapticNotification) {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(type.uiType)
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

/// 主操作（重）：包装 .borderedProminent 外观并触发重冲击，用于播放、发送、确认等关键动作。
public struct HapticProminentButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.borderedProminent)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.heavy)
                }
            }
    }
}

/// 次级操作（缓）：包装 .bordered 外观并触发柔和冲击，用于一般次要按钮。
public struct HapticBorderedButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.bordered)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.soft)
                }
            }
    }
}

/// 朴素按钮（轻）：替代 .buttonStyle(.plain)，保留无外观并触发轻微冲击，用于列表行与图标按钮。
public struct HapticPlainButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.plain)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.light)
                }
            }
    }
}

/// 无边框按钮（轻）：替代 .buttonStyle(.borderless)，触发轻微冲击。
public struct HapticBorderlessButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.borderless)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.impact(.light)
                }
            }
    }
}

/// 破坏性操作（急）：触发错误通知震动，强调这是不可逆的危险操作。
public struct HapticDestructiveButtonStyle: ButtonStyle, Sendable {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.bordered)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.notification(.error)
                }
            }
    }
}
