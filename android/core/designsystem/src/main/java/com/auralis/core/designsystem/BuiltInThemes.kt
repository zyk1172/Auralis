package com.auralis.core.designsystem

import androidx.compose.ui.graphics.Color

/**
 * 12 个内置主题。**逐值搬运自 `ThemeEngine/BuiltInThemes.swift`**，不是重新配色。
 *
 * 规则（与 Swift `theme()` 工厂一致）：
 * - `materials.navigation == materials.floatingControls`，Opacity = solid→1.0，其它→0.82；
 * - `typography.displayWeight = Bold`、`bodyWeight = Regular`；
 * - `typography.usesMonospacedMetrics = (visualizer == VuMeter)`。
 */
object BuiltInThemes {

    val auroraGlass = theme(
        id = "aurora-glass",
        name = "极光玻璃",
        scheme = AuralisColorScheme.Dark,
        material = AuralisMaterialStyle.LuminousGlass,
        artwork = AuralisArtworkStyle.SoftShadow,
        standard = 0.34,
        ambient = 18.0,
        glow = 0.42,
        visualizer = AuralisVisualizerStyle.FluidBars,
        background = "#07131D",
        elevated = "#102435",
        surface = "#193247",
        primaryText = "#F5FBFF",
        secondaryText = "#A9C5D6",
        accent = "#50D5C8",
        accentSecondary = "#8D7CF4",
        success = "#5DD39E",
        warning = "#F6C85F",
        error = "#FF6B7A",
        separator = "#315166",
    )

    val midnightOled = theme(
        id = "midnight-oled",
        name = "午夜 OLED",
        scheme = AuralisColorScheme.Dark,
        material = AuralisMaterialStyle.Solid,
        artwork = AuralisArtworkStyle.Crisp,
        standard = 0.22,
        ambient = 30.0,
        glow = 0.08,
        visualizer = AuralisVisualizerStyle.Minimal,
        background = "#000000",
        elevated = "#080808",
        surface = "#121212",
        primaryText = "#FFFFFF",
        secondaryText = "#9A9A9A",
        accent = "#D8FF4F",
        accentSecondary = "#7A8BFF",
        success = "#64D98B",
        warning = "#FFC857",
        error = "#FF5C73",
        separator = "#242424",
    )

    val analogHifi = theme(
        id = "analog-hifi",
        name = "模拟 Hi-Fi",
        scheme = AuralisColorScheme.Dark,
        material = AuralisMaterialStyle.SubtleGlass,
        artwork = AuralisArtworkStyle.Framed,
        standard = 0.28,
        ambient = 24.0,
        glow = 0.18,
        visualizer = AuralisVisualizerStyle.VuMeter,
        background = "#17120F",
        elevated = "#251B16",
        surface = "#33251D",
        primaryText = "#F4E6CE",
        secondaryText = "#BFAE94",
        accent = "#C79655",
        accentSecondary = "#8E5B3A",
        success = "#80B192",
        warning = "#D2A44B",
        error = "#D86F5D",
        separator = "#574236",
    )

    val minimalPaper = theme(
        id = "minimal-paper",
        name = "极简纸张",
        scheme = AuralisColorScheme.Light,
        material = AuralisMaterialStyle.Paper,
        artwork = AuralisArtworkStyle.Crisp,
        standard = 0.20,
        ambient = 30.0,
        glow = 0.0,
        visualizer = AuralisVisualizerStyle.Minimal,
        background = "#F4F1EA",
        elevated = "#FFFDF8",
        surface = "#EAE5DB",
        primaryText = "#211F1B",
        secondaryText = "#6F6A61",
        accent = "#294B72",
        accentSecondary = "#B96545",
        success = "#2D7A55",
        warning = "#A16916",
        error = "#B23B42",
        separator = "#D2CDC4",
    )

    val neonCity = theme(
        id = "neon-city",
        name = "霓虹都市",
        scheme = AuralisColorScheme.Dark,
        material = AuralisMaterialStyle.LuminousGlass,
        artwork = AuralisArtworkStyle.Luminous,
        standard = 0.28,
        ambient = 10.0,
        glow = 0.40,
        visualizer = AuralisVisualizerStyle.LineSpectrum,
        background = "#100817",
        elevated = "#1C102B",
        surface = "#27183B",
        primaryText = "#FFF7FF",
        secondaryText = "#C5AFCB",
        accent = "#FF4FA3",
        accentSecondary = "#5D74FF",
        success = "#56D89B",
        warning = "#FFAA4A",
        error = "#FF5C6A",
        separator = "#482957",
    )

    val zenNature = theme(
        id = "zen-nature",
        name = "禅意自然",
        scheme = AuralisColorScheme.Light,
        material = AuralisMaterialStyle.Paper,
        artwork = AuralisArtworkStyle.SoftShadow,
        standard = 0.42,
        ambient = 22.0,
        glow = 0.10,
        visualizer = AuralisVisualizerStyle.Minimal,
        background = "#E9EEE8",
        elevated = "#F7F7F0",
        surface = "#DDE6DE",
        primaryText = "#1D2B24",
        secondaryText = "#637168",
        accent = "#3D7055",
        accentSecondary = "#A7835D",
        success = "#3C8160",
        warning = "#B68436",
        error = "#B44F4F",
        separator = "#C7D1C9",
    )

    val cloudVillageRed = theme(
        id = "cloud-village-red",
        name = "云村红",
        scheme = AuralisColorScheme.Light,
        material = AuralisMaterialStyle.SubtleGlass,
        artwork = AuralisArtworkStyle.Crisp,
        standard = 0.24,
        ambient = 26.0,
        glow = 0.06,
        visualizer = AuralisVisualizerStyle.Minimal,
        background = "#FFFFFF",
        elevated = "#FAFAFA",
        surface = "#F3F3F3",
        primaryText = "#1A1A1A",
        secondaryText = "#737373",
        accent = "#EC4141",
        accentSecondary = "#B83242",
        success = "#237A43",
        warning = "#9B6500",
        error = "#C9303E",
        separator = "#D8D8D8",
    )

    val vinylNight = theme(
        id = "vinyl-night",
        name = "黑胶之夜",
        scheme = AuralisColorScheme.Dark,
        material = AuralisMaterialStyle.SubtleGlass,
        artwork = AuralisArtworkStyle.Framed,
        standard = 0.30,
        ambient = 20.0,
        glow = 0.22,
        visualizer = AuralisVisualizerStyle.FluidBars,
        background = "#121212",
        elevated = "#1E1E1E",
        surface = "#292929",
        primaryText = "#FFFFFF",
        secondaryText = "#9C9C9C",
        accent = "#EC4141",
        accentSecondary = "#8E354A",
        success = "#5DD39E",
        warning = "#F6C85F",
        error = "#FF6B7A",
        separator = "#383838",
    )

    val peachMist = theme(
        id = "peach-mist",
        name = "蜜桃粉雾",
        scheme = AuralisColorScheme.Light,
        material = AuralisMaterialStyle.LuminousGlass,
        artwork = AuralisArtworkStyle.SoftShadow,
        standard = 0.30,
        ambient = 24.0,
        glow = 0.12,
        visualizer = AuralisVisualizerStyle.FluidBars,
        background = "#FFF7F8",
        elevated = "#FFFFFF",
        surface = "#FBE9EC",
        primaryText = "#33242A",
        secondaryText = "#826873",
        accent = "#C92E63",
        accentSecondary = "#A33E78",
        success = "#2F7454",
        warning = "#986313",
        error = "#B93249",
        separator = "#E4C8CF",
    )

    val solarStudio = theme(
        id = "solar-studio",
        name = "日光唱片室",
        scheme = AuralisColorScheme.Light,
        material = AuralisMaterialStyle.Paper,
        artwork = AuralisArtworkStyle.Framed,
        standard = 0.32,
        ambient = 28.0,
        glow = 0.04,
        visualizer = AuralisVisualizerStyle.VuMeter,
        background = "#F9E4BF",
        elevated = "#FFF5E4",
        surface = "#EAC89C",
        primaryText = "#2F211B",
        secondaryText = "#705446",
        accent = "#B83C28",
        accentSecondary = "#2F6685",
        success = "#2B704A",
        warning = "#855B0B",
        error = "#A72C35",
        separator = "#C9A878",
    )

    val polarFrost = theme(
        id = "polar-frost",
        name = "冰川透镜",
        scheme = AuralisColorScheme.Light,
        material = AuralisMaterialStyle.LuminousGlass,
        artwork = AuralisArtworkStyle.Crisp,
        standard = 0.26,
        ambient = 20.0,
        glow = 0.16,
        visualizer = AuralisVisualizerStyle.LineSpectrum,
        background = "#EAF4FA",
        elevated = "#F8FCFF",
        surface = "#D7EAF5",
        primaryText = "#15252F",
        secondaryText = "#526A78",
        accent = "#176DA3",
        accentSecondary = "#5661A8",
        success = "#24734E",
        warning = "#8A5C00",
        error = "#B22E47",
        separator = "#B8D1DE",
    )

    val forestTerminal = theme(
        id = "forest-terminal",
        name = "森林终端",
        scheme = AuralisColorScheme.Dark,
        material = AuralisMaterialStyle.Solid,
        artwork = AuralisArtworkStyle.Framed,
        standard = 0.18,
        ambient = 32.0,
        glow = 0.05,
        visualizer = AuralisVisualizerStyle.VuMeter,
        background = "#061711",
        elevated = "#0C241A",
        surface = "#123226",
        primaryText = "#E8F5EC",
        secondaryText = "#9BB9A6",
        accent = "#4BE28A",
        accentSecondary = "#E2B84B",
        success = "#5CDB95",
        warning = "#F0C85A",
        error = "#FF7581",
        separator = "#28513B",
    )

    val all: List<AuralisTheme> = listOf(
        auroraGlass,
        midnightOled,
        analogHifi,
        minimalPaper,
        neonCity,
        zenNature,
        cloudVillageRed,
        vinylNight,
        peachMist,
        solarStudio,
        polarFrost,
        forestTerminal,
    )

    val default: AuralisTheme get() = auroraGlass

    fun byId(id: String?): AuralisTheme {
        val canonical = canonicalId(id) ?: return default
        return all.firstOrNull { it.id == canonical } ?: default
    }

    /** Apple `legacyIDMappings`：旧主题 ID 迁移到最接近的现视觉语言。 */
    private val legacyIdMappings = mapOf(
        "album-adaptive" to "aurora-glass",
        "cyber-pulse" to "neon-city",
        "deep-sea-blue" to "aurora-glass",
        "adaptive" to "aurora-glass",
        "aurora" to "aurora-glass",
        "cyber" to "neon-city",
        "midnight" to "midnight-oled",
        "neon" to "neon-city",
        "paper" to "minimal-paper",
        "zen" to "zen-nature",
    )

    fun canonicalId(id: String?): String? {
        val raw = id ?: return null
        return if (all.any { it.id == raw }) raw else legacyIdMappings[raw]
    }

    @Suppress("LongParameterList")
    private fun theme(
        id: String,
        name: String,
        scheme: AuralisColorScheme,
        material: AuralisMaterialStyle,
        artwork: AuralisArtworkStyle,
        standard: Double,
        ambient: Double,
        glow: Double,
        visualizer: AuralisVisualizerStyle,
        background: String,
        elevated: String,
        surface: String,
        primaryText: String,
        secondaryText: String,
        accent: String,
        accentSecondary: String,
        success: String,
        warning: String,
        error: String,
        separator: String,
    ): AuralisTheme = AuralisTheme(
        id = id,
        name = name,
        colorScheme = scheme,
        colors = AuralisColors(
            background = Color.fromHex(background),
            elevated = Color.fromHex(elevated),
            surface = Color.fromHex(surface),
            primaryText = Color.fromHex(primaryText),
            secondaryText = Color.fromHex(secondaryText),
            accent = Color.fromHex(accent),
            accentSecondary = Color.fromHex(accentSecondary),
            success = Color.fromHex(success),
            warning = Color.fromHex(warning),
            error = Color.fromHex(error),
            separator = Color.fromHex(separator),
        ),
        typography = AuralisTypography(
            displayWeight = AuralisFontWeight.Bold,
            bodyWeight = AuralisFontWeight.Regular,
            usesMonospacedMetrics = visualizer == AuralisVisualizerStyle.VuMeter,
        ),
        materials = AuralisMaterials(
            navigation = material,
            floatingControls = material,
            opacity = if (material == AuralisMaterialStyle.Solid) 1f else 0.82f,
        ),
        artworkStyle = artwork,
        motion = AuralisMotionTokens(
            standardDurationSeconds = standard,
            ambientDurationSeconds = ambient,
            glowIntensity = glow,
        ),
        visualizer = visualizer,
    )
}
