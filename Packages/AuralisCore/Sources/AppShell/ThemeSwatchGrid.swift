import DesignSystem
import SwiftUI
import ThemeEngine

/// 主题色板网格：展示当前主题的 8 个核心色 Token（含文字色），比只显示 3 个圆点更直观。
struct ThemeSwatchGrid: View {
    let colors: ThemeColors
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.small) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AuralisSpacing.small), count: 4), spacing: AuralisSpacing.small) {
                swatch(colors.background.color, label: "背景")
                swatch(colors.elevated.color, label: "浮层")
                swatch(colors.surface.color, label: "表面")
                swatch(colors.accent.color, label: "强调")
                swatch(colors.accentSecondary.color, label: "辅强调")
                swatch(colors.success.color, label: "成功")
                swatch(colors.warning.color, label: "警告")
                swatch(colors.error.color, label: "错误")
            }
            Text(name)
                .font(.caption)
                .foregroundStyle(colors.secondaryText.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("主题 \(name) 色板：8 个颜色")
    }

    private func swatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(colors.secondaryText.color)
                .lineLimit(1)
        }
    }
}
