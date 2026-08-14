import Foundation
import SwiftUI

public struct ColorToken: Codable, Hashable, Sendable {
    public let hex: String
    public init(_ hex: String) { self.hex = hex }

    public var color: Color {
        Color(hex: hex)
    }

    /// WCAG sRGB 相对亮度。主题和会在渐变页面上使用此值做可读性回归测试，
    /// 避免把浅色背景和浅色前景组合后才在运行时发现按钮、文字不可见。
    public var relativeLuminance: Double {
        let rgb = rgbComponents
        return 0.2126 * linearized(rgb.red)
            + 0.7152 * linearized(rgb.green)
            + 0.0722 * linearized(rgb.blue)
    }

    /// 与另一主题色的 WCAG 对比度（1:1 至 21:1）。
    public func contrastRatio(against other: ColorToken) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private var rgbComponents: (red: Double, green: Double, blue: Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let shift = cleaned.count == 8 ? 8 : 0
        return (
            Double((value >> (16 + shift)) & 0xFF) / 255,
            Double((value >> (8 + shift)) & 0xFF) / 255,
            Double((value >> shift) & 0xFF) / 255
        )
    }

    private func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

public struct ThemeColors: Codable, Hashable, Sendable {
    public let background: ColorToken
    public let elevated: ColorToken
    public let surface: ColorToken
    public let primaryText: ColorToken
    public let secondaryText: ColorToken
    public let accent: ColorToken
    public let accentSecondary: ColorToken
    public let success: ColorToken
    public let warning: ColorToken
    public let error: ColorToken
    public let separator: ColorToken

    public init(
        background: ColorToken,
        elevated: ColorToken,
        surface: ColorToken,
        primaryText: ColorToken,
        secondaryText: ColorToken,
        accent: ColorToken,
        accentSecondary: ColorToken,
        success: ColorToken,
        warning: ColorToken,
        error: ColorToken,
        separator: ColorToken
    ) {
        self.background = background
        self.elevated = elevated
        self.surface = surface
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.accentSecondary = accentSecondary
        self.success = success
        self.warning = warning
        self.error = error
        self.separator = separator
    }
}

public struct ThemeTypography: Codable, Hashable, Sendable {
    public let displayWeight: Font.WeightToken
    public let bodyWeight: Font.WeightToken
    public let usesMonospacedMetrics: Bool
    public init(displayWeight: Font.WeightToken, bodyWeight: Font.WeightToken, usesMonospacedMetrics: Bool = false) {
        self.displayWeight = displayWeight
        self.bodyWeight = bodyWeight
        self.usesMonospacedMetrics = usesMonospacedMetrics
    }
}

extension Font {
    public enum WeightToken: String, Codable, Hashable, Sendable {
        case regular
        case medium
        case semibold
        case bold

        public var value: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }
}

public enum ThemeMaterialStyle: String, Codable, Hashable, Sendable {
    case solid
    case subtleGlass
    case luminousGlass
    case paper
}

public struct ThemeMaterials: Codable, Hashable, Sendable {
    public let navigation: ThemeMaterialStyle
    public let floatingControls: ThemeMaterialStyle
    public let opacity: Double
    public init(navigation: ThemeMaterialStyle, floatingControls: ThemeMaterialStyle, opacity: Double) {
        self.navigation = navigation
        self.floatingControls = floatingControls
        self.opacity = opacity
    }
}

public enum ArtworkStyle: String, Codable, Hashable, Sendable {
    case softShadow
    case crisp
    case framed
    case luminous
}

public struct MotionTokens: Codable, Hashable, Sendable {
    public let standardDuration: Double
    public let ambientDuration: Double
    public let glowIntensity: Double
    public init(standardDuration: Double, ambientDuration: Double, glowIntensity: Double) {
        self.standardDuration = standardDuration
        self.ambientDuration = ambientDuration
        self.glowIntensity = glowIntensity
    }
}

public enum VisualizerStyle: String, Codable, Hashable, Sendable {
    case fluidBars
    case lineSpectrum
    case vuMeter
    case minimal
    case disabled
}

public protocol AuralisTheme: Sendable {
    var id: String { get }
    var name: String { get }
    var colorScheme: ColorScheme { get }
    var colorTokens: ThemeColors { get }
    var typography: ThemeTypography { get }
    var materials: ThemeMaterials { get }
    var artworkStyle: ArtworkStyle { get }
    var motion: MotionTokens { get }
    var visualizer: VisualizerStyle { get }
}

public enum AuralisSpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 20
    public static let xLarge: CGFloat = 28
    public static let huge: CGFloat = 40
}

public enum AuralisRadius {
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 14
    public static let large: CGFloat = 22
    public static let artwork: CGFloat = 18
}

extension Color {
    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        switch cleaned.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        default:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
