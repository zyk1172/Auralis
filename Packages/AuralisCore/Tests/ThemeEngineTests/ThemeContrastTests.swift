import DesignSystem
import Testing
import ThemeEngine

@Suite("Theme contrast")
struct ThemeContrastTests {
    /// 展开播放页会从 background/elevated/surface 组成主题渐变；主前景必须在每一个
    /// 基色层之上均满足正文级对比度，不能再依赖白色图标恰好落在深色区域。
    @Test("每个内置主题的主前景对渐变基色至少 4.5:1")
    func primaryTextRemainsReadableAcrossGradientBaseColors() {
        for theme in BuiltInThemes.all {
            let colors = theme.colorTokens
            for background in [colors.background, colors.elevated, colors.surface] {
                #expect(
                    colors.primaryText.contrastRatio(against: background) >= 4.5,
                    "\(theme.name) 的主前景在渐变基色上对比度不足"
                )
            }
        }
    }

    @Test("每个内置主题的次前景对所有基色至少 3:1")
    func secondaryTextRemainsDiscoverable() {
        for theme in BuiltInThemes.all {
            let colors = theme.colorTokens
            for background in [colors.background, colors.elevated, colors.surface] {
                #expect(
                    colors.secondaryText.contrastRatio(against: background) >= 3.0,
                    "\(theme.name) 的次前景在渐变基色上对比度不足"
                )
            }
        }
    }

    /// 强调色会直接用于按钮、选中态图标、进度条与焦点边框；按非文本控件标准，
    /// 它在可能承载控件的三层背景上都不能低于 3:1。
    @Test("每个内置主题的交互强调色对所有基色至少 3:1")
    func accentControlsRemainDiscoverableAcrossSurfaces() {
        for theme in BuiltInThemes.all {
            let colors = theme.colorTokens
            for background in [colors.background, colors.elevated, colors.surface] {
                #expect(
                    colors.accent.contrastRatio(against: background) >= 3.0,
                    "\(theme.name) 的交互强调色在控件背景上对比度不足"
                )
            }
        }
    }
}
