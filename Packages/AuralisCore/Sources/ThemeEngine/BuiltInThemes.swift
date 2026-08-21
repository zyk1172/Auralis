import Combine
import DesignSystem
import SwiftUI

public struct BuiltInTheme: AuralisTheme, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// 设置页使用的简短视觉说明，帮助用户按材质与氛围选择，而不只看主题名称。
    public let summary: String
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
        summary: String = "",
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
        self.summary = summary
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
        theme("aurora-glass", "极光玻璃", "青绿极光、柔和景深与玻璃层次", .dark, colors("07131D", "102435", "193247", "F5FBFF", "A9C5D6", "50D5C8", "8D7CF4", "5DD39E", "F6C85F", "FF6B7A", "315166"), .luminousGlass, .softShadow, .init(standardDuration: 0.34, ambientDuration: 18, glowIntensity: 0.42), .fluidBars),
        theme("midnight-oled", "午夜 OLED", "纯黑、省电、干净且克制", .dark, colors("000000", "080808", "121212", "FFFFFF", "9A9A9A", "D8FF4F", "7A8BFF", "64D98B", "FFC857", "FF5C73", "242424"), .solid, .crisp, .init(standardDuration: 0.22, ambientDuration: 30, glowIntensity: 0.08), .minimal),
        theme("analog-hifi", "模拟 Hi-Fi", "胡桃木色、框装封面与暖色氛围", .dark, colors("17120F", "251B16", "33251D", "F4E6CE", "BFAE94", "C79655", "8E5B3A", "80B192", "D2A44B", "D86F5D", "574236"), .subtleGlass, .framed, .init(standardDuration: 0.28, ambientDuration: 24, glowIntensity: 0.18), .vuMeter),
        theme("minimal-paper", "极简纸张", "暖白纸面、墨色排版与低动态", .light, colors("F4F1EA", "FFFDF8", "EAE5DB", "211F1B", "6F6A61", "294B72", "B96545", "2D7A55", "A16916", "B23B42", "D2CDC4"), .paper, .crisp, .init(standardDuration: 0.2, ambientDuration: 30, glowIntensity: 0), .minimal),
        theme("neon-city", "霓虹都市", "洋红与靛蓝交错的夜间霓虹", .dark, colors("100817", "1C102B", "27183B", "FFF7FF", "C5AFCB", "FF4FA3", "5D74FF", "56D89B", "FFAA4A", "FF5C6A", "482957"), .luminousGlass, .luminous, .init(standardDuration: 0.28, ambientDuration: 10, glowIntensity: 0.4), .lineSpectrum),
        theme("zen-nature", "禅意自然", "鼠尾草绿、自然纸感与慢节奏", .light, colors("E9EEE8", "F7F7F0", "DDE6DE", "1D2B24", "637168", "3D7055", "A7835D", "3C8160", "B68436", "B44F4F", "C7D1C9"), .paper, .softShadow, .init(standardDuration: 0.42, ambientDuration: 22, glowIntensity: 0.1), .minimal),
        // 灵感来自网易云音乐：标志性「云村红」与黑胶唱机的深夜氛围
        theme("cloud-village-red", "云村红", "明亮中性色与标志性音乐红", .light, colors("FFFFFF", "FAFAFA", "F3F3F3", "1A1A1A", "737373", "EC4141", "B83242", "237A43", "9B6500", "C9303E", "D8D8D8"), .subtleGlass, .crisp, .init(standardDuration: 0.24, ambientDuration: 26, glowIntensity: 0.06), .minimal),
        theme("vinyl-night", "黑胶之夜", "炭黑唱片、酒红点缀与沉稳氛围", .dark, colors("121212", "1E1E1E", "292929", "FFFFFF", "9C9C9C", "EC4141", "8E354A", "5DD39E", "F6C85F", "FF6B7A", "383838"), .subtleGlass, .framed, .init(standardDuration: 0.3, ambientDuration: 20, glowIntensity: 0.22), .fluidBars),
        theme("peach-mist", "蜜桃粉雾", "轻盈粉雾、柔光玻璃与舒缓色调", .light, colors("FFF7F8", "FFFFFF", "FBE9EC", "33242A", "826873", "C92E63", "A33E78", "2F7454", "986313", "B93249", "E4C8CF"), .luminousGlass, .softShadow, .init(standardDuration: 0.3, ambientDuration: 24, glowIntensity: 0.12), .fluidBars),
        // 新增三套结构上真正不同的视觉语言：暖色唱片室、冷色透明镜片、深绿终端。
        theme("solar-studio", "日光唱片室", "奶油日光、框装唱片与暖调纸感", .light, colors("F9E4BF", "FFF5E4", "EAC89C", "2F211B", "705446", "B83C28", "2F6685", "2B704A", "855B0B", "A72C35", "C9A878"), .paper, .framed, .init(standardDuration: 0.32, ambientDuration: 28, glowIntensity: 0.04), .vuMeter),
        theme("polar-frost", "冰川透镜", "冰蓝透明层、锐利封面与冷调玻璃", .light, colors("EAF4FA", "F8FCFF", "D7EAF5", "15252F", "526A78", "176DA3", "5661A8", "24734E", "8A5C00", "B22E47", "B8D1DE"), .luminousGlass, .crisp, .init(standardDuration: 0.26, ambientDuration: 20, glowIntensity: 0.16), .lineSpectrum),
        theme("forest-terminal", "森林终端", "深绿单色界面与实体面板", .dark, colors("061711", "0C241A", "123226", "E8F5EC", "9BB9A6", "4BE28A", "E2B84B", "5CDB95", "F0C85A", "FF7581", "28513B"), .solid, .framed, .init(standardDuration: 0.18, ambientDuration: 32, glowIntensity: 0.05), .vuMeter),
    ]

    /// 已合并主题与早期公开 ID 的兼容映射。旧偏好与旧备份会迁移到最接近的
    /// 现有视觉语言，而不是因为 ID 被移除而突然回到第一个主题。
    public static let legacyIDMappings: [String: String] = [
        "album-adaptive": "aurora-glass",
        "cyber-pulse": "neon-city",
        "deep-sea-blue": "aurora-glass",
        "adaptive": "aurora-glass",
        "aurora": "aurora-glass",
        "cyber": "neon-city",
        "midnight": "midnight-oled",
        "neon": "neon-city",
        "paper": "minimal-paper",
        "zen": "zen-nature",
    ]

    public static func canonicalID(for id: String) -> String {
        legacyIDMappings[id] ?? id
    }

    private static func theme(
        _ id: String,
        _ name: String,
        _ summary: String,
        _ scheme: ColorScheme,
        _ colors: ThemeColors,
        _ material: ThemeMaterialStyle,
        _ artwork: ArtworkStyle,
        _ motion: MotionTokens,
        _ visualizer: VisualizerStyle
    ) -> BuiltInTheme {
        BuiltInTheme(
            id: id,
            name: String(localized: String.LocalizationValue(name), bundle: .module),
            summary: String(localized: String.LocalizationValue(summary), bundle: .module),
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
        precondition(!themes.isEmpty, "ThemeStore 至少需要一个主题")
        self.defaults = defaults
        self.themes = themes
        let stored = defaults.string(forKey: Self.defaultsKey)
        let resolved = stored.flatMap { storedID -> String? in
            let canonicalID = BuiltInThemes.canonicalID(for: storedID)
            // 默认目录优先迁移到规范 ID；自定义主题目录若只提供旧 ID，仍保持兼容。
            return [canonicalID, storedID].first { candidate in
                themes.contains(where: { $0.id == candidate })
            }
        } ?? themes[0].id
        self.selectedID = resolved
        if stored != nil, stored != resolved {
            defaults.set(resolved, forKey: Self.defaultsKey)
        }
    }

    public var current: BuiltInTheme {
        themes.first(where: { $0.id == selectedID }) ?? themes[0]
    }

    public func select(id: String) {
        let canonicalID = BuiltInThemes.canonicalID(for: id)
        guard let resolved = [canonicalID, id].first(where: { candidate in
            themes.contains(where: { $0.id == candidate })
        }) else { return }
        selectedID = resolved
        defaults.set(resolved, forKey: Self.defaultsKey)
    }
}
