import Combine
import DesignSystem
import SwiftUI

public struct BuiltInTheme: AuralisTheme, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let colorScheme: ColorScheme
    public let colorTokens: ThemeColors
    public let typography: ThemeTypography
    public let materials: ThemeMaterials
    public let artworkStyle: ArtworkStyle
    public let motion: MotionTokens
    public let visualizer: VisualizerStyle

    public init(
        id: String,
        name: String,
        colorScheme: ColorScheme,
        colorTokens: ThemeColors,
        typography: ThemeTypography,
        materials: ThemeMaterials,
        artworkStyle: ArtworkStyle,
        motion: MotionTokens,
        visualizer: VisualizerStyle
    ) {
        self.id = id
        self.name = name
        self.colorScheme = colorScheme
        self.colorTokens = colorTokens
        self.typography = typography
        self.materials = materials
        self.artworkStyle = artworkStyle
        self.motion = motion
        self.visualizer = visualizer
    }
}

public enum BuiltInThemes {
    public static let all: [BuiltInTheme] = [
        theme("aurora-glass", "极光玻璃", .dark, colors("07131D", "102435", "193247", "F5FBFF", "A9C5D6", "50D5C8", "8D7CF4", "5DD39E", "F6C85F", "FF6B7A", "315166"), .luminousGlass, .softShadow, .init(standardDuration: 0.34, ambientDuration: 18, glowIntensity: 0.42), .fluidBars),
        theme("midnight-oled", "午夜 OLED", .dark, colors("000000", "080808", "121212", "FFFFFF", "9A9A9A", "D8FF4F", "7A8BFF", "64D98B", "FFC857", "FF5C73", "242424"), .solid, .crisp, .init(standardDuration: 0.22, ambientDuration: 30, glowIntensity: 0.08), .minimal),
        theme("analog-hifi", "模拟 Hi-Fi", .dark, colors("17120F", "251B16", "33251D", "F4E6CE", "BFAE94", "C79655", "8E5B3A", "80B192", "D2A44B", "D86F5D", "574236"), .subtleGlass, .framed, .init(standardDuration: 0.28, ambientDuration: 24, glowIntensity: 0.18), .vuMeter),
        theme("cyber-pulse", "赛博脉冲", .dark, colors("070A19", "10152A", "141C38", "F5F7FF", "A5ADCE", "38E3FF", "A559FF", "51DF9B", "FFD15A", "FF5678", "283760"), .subtleGlass, .luminous, .init(standardDuration: 0.24, ambientDuration: 12, glowIntensity: 0.36), .lineSpectrum),
        theme("minimal-paper", "极简纸张", .light, colors("F4F1EA", "FFFDF8", "EAE5DB", "211F1B", "6F6A61", "294B72", "B96545", "2D7A55", "A16916", "B23B42", "D2CDC4"), .paper, .crisp, .init(standardDuration: 0.2, ambientDuration: 30, glowIntensity: 0), .minimal),
        theme("album-adaptive", "专辑自适应", .dark, colors("101319", "1B202A", "252C38", "FAFBFF", "B8C0CF", "E7854F", "5FA6A1", "61C48D", "F0B85A", "F36C75", "394355"), .luminousGlass, .softShadow, .init(standardDuration: 0.5, ambientDuration: 16, glowIntensity: 0.3), .fluidBars),
        theme("neon-city", "霓虹都市", .dark, colors("100817", "1C102B", "27183B", "FFF7FF", "C5AFCB", "FF4FA3", "5D74FF", "56D89B", "FFAA4A", "FF5C6A", "482957"), .luminousGlass, .luminous, .init(standardDuration: 0.28, ambientDuration: 10, glowIntensity: 0.4), .lineSpectrum),
        theme("zen-nature", "禅意自然", .light, colors("E9EEE8", "F7F7F0", "DDE6DE", "1D2B24", "637168", "3D7055", "A7835D", "3C8160", "B68436", "B44F4F", "C7D1C9"), .paper, .softShadow, .init(standardDuration: 0.42, ambientDuration: 22, glowIntensity: 0.1), .minimal),
        // 灵感来自网易云音乐：标志性「云村红」与黑胶唱机的深夜氛围
        theme("cloud-village-red", "云村红", .light, colors("FFFFFF", "FAFAFA", "F3F3F3", "1A1A1A", "8C8C8C", "EC4141", "FF9D9D", "34A853", "F5A623", "E64545", "E8E8E8"), .paper, .crisp, .init(standardDuration: 0.24, ambientDuration: 26, glowIntensity: 0.06), .minimal),
        theme("vinyl-night", "黑胶之夜", .dark, colors("121212", "1E1E1E", "292929", "FFFFFF", "9C9C9C", "EC4141", "8E354A", "5DD39E", "F6C85F", "FF6B7A", "383838"), .subtleGlass, .framed, .init(standardDuration: 0.3, ambientDuration: 20, glowIntensity: 0.22), .fluidBars),
        theme("peach-mist", "蜜桃粉雾", .light, colors("FFF7F8", "FFFFFF", "FBE9EC", "33242A", "9A7F88", "FF5C8A", "FFA8C5", "3C8160", "C98A2B", "D84C5F", "F0D8DE"), .paper, .softShadow, .init(standardDuration: 0.3, ambientDuration: 24, glowIntensity: 0.08), .minimal),
        theme("deep-sea-blue", "深海蓝调", .dark, colors("0B1622", "12202F", "1A2B3D", "F0F6FC", "93A8BC", "4FA3FF", "38E3FF", "51DF9B", "FFD15A", "FF5678", "2A3D52"), .subtleGlass, .luminous, .init(standardDuration: 0.28, ambientDuration: 18, glowIntensity: 0.3), .lineSpectrum),
    ]

    private static func theme(
        _ id: String,
        _ name: String,
        _ scheme: ColorScheme,
        _ colors: ThemeColors,
        _ material: ThemeMaterialStyle,
        _ artwork: ArtworkStyle,
        _ motion: MotionTokens,
        _ visualizer: VisualizerStyle
    ) -> BuiltInTheme {
        BuiltInTheme(
            id: id,
            name: name,
            colorScheme: scheme,
            colorTokens: colors,
            typography: .init(displayWeight: .bold, bodyWeight: .regular, usesMonospacedMetrics: visualizer == .vuMeter),
            materials: .init(navigation: material, floatingControls: material, opacity: material == .solid ? 1 : 0.82),
            artworkStyle: artwork,
            motion: motion,
            visualizer: visualizer
        )
    }

    private static func colors(
        _ background: String,
        _ elevated: String,
        _ surface: String,
        _ primaryText: String,
        _ secondaryText: String,
        _ accent: String,
        _ accentSecondary: String,
        _ success: String,
        _ warning: String,
        _ error: String,
        _ separator: String
    ) -> ThemeColors {
        ThemeColors(
            background: .init(background), elevated: .init(elevated), surface: .init(surface),
            primaryText: .init(primaryText), secondaryText: .init(secondaryText), accent: .init(accent),
            accentSecondary: .init(accentSecondary), success: .init(success), warning: .init(warning),
            error: .init(error), separator: .init(separator)
        )
    }
}

@MainActor
public final class ThemeStore: ObservableObject {
    @Published public private(set) var selectedID: String
    public let themes: [BuiltInTheme]
    private let defaults: UserDefaults
    private static let defaultsKey = "auralis.selected-theme"

    public init(defaults: UserDefaults = .standard, themes: [BuiltInTheme] = BuiltInThemes.all) {
        self.defaults = defaults
        self.themes = themes
        let stored = defaults.string(forKey: Self.defaultsKey)
        self.selectedID = themes.contains(where: { $0.id == stored }) ? (stored ?? themes[0].id) : themes[0].id
    }

    public var current: BuiltInTheme {
        themes.first(where: { $0.id == selectedID }) ?? themes[0]
    }

    public func select(id: String) {
        guard themes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id, forKey: Self.defaultsKey)
    }
}
