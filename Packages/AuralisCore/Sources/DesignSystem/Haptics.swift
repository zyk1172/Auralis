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
