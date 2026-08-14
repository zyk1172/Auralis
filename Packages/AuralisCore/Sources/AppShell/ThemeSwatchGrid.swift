import DesignSystem
import SwiftUI
import ThemeEngine

/// 可直接预览并选择所有主题的自适应卡片网格。每张卡片使用候选主题自己的
/// 背景与前景色，因此用户切换前就能判断它是纸感、实体面板还是玻璃风格。
struct ThemeChoiceGrid: View {
    @ObservedObject var themeStore: ThemeStore

    private let columns = [
        GridItem(.adaptive(minimum: 154, maximum: 230), spacing: AuralisSpacing.medium),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AuralisSpacing.medium) {
            ForEach(themeStore.themes) { candidate in
                themeCard(candidate)
            }
        }
        .padding(.vertical, AuralisSpacing.xSmall)
    }

    private func themeCard(_ candidate: BuiltInTheme) -> some View {
        let colors = candidate.colorTokens
        let isSelected = themeStore.selectedID == candidate.id

        return Button {
            themeStore.select(id: candidate.id)
        } label: {
            VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: AuralisSpacing.small) {
                    Text(candidate.name)
                        .font(.headline)
                        .foregroundStyle(colors.primaryText.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? colors.accent.color : colors.secondaryText.color)
                }

                Text(candidate.summary)
                    .font(.caption)
                    .foregroundStyle(colors.secondaryText.color)
                    .lineLimit(2)
                    .frame(minHeight: 30, alignment: .topLeading)

                HStack(spacing: 6) {
                    colorDot(colors.accent.color)
                    colorDot(colors.accentSecondary.color)
                    colorDot(colors.surface.color)
                    Spacer()
                    Text(candidate.colorScheme == .dark ? "深色" : "浅色")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(colors.secondaryText.color)
                }
            }
            .padding(AuralisSpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background {
                LinearGradient(
                    colors: [colors.background.color, colors.elevated.color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous)
                    .stroke(
                        isSelected ? colors.accent.color : colors.separator.color.opacity(0.7),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(color: isSelected ? colors.accent.color.opacity(0.18) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.name)，\(candidate.summary)，\(candidate.colorScheme == .dark ? "深色" : "浅色")")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private func colorDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

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
