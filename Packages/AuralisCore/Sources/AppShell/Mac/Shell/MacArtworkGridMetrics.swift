#if os(macOS)
import CoreGraphics

/// Apple Music 式响应式 Artwork Grid 度量。
/// 不再使用全局固定 168pt：列数与 Artwork 尺寸由可用宽度决定。
struct MacArtworkGridMetrics: Equatable {
    let columnCount: Int
    let itemWidth: CGFloat
    let horizontalPadding: CGFloat
    let spacing: CGFloat

    /// 「专辑」页网格（REFERENCE_A 基准：detail ≈1268 → 4 列，item ≈267-275）。
    static func albums(availableWidth: CGFloat) -> MacArtworkGridMetrics {
        let padding = horizontalPadding(for: availableWidth)
        let spacing = MacUIVisualTokens.Content.gridColumnSpacing
        let content = max(0, availableWidth - padding * 2)
        let columns = columnCount(for: availableWidth)
        let item = (content - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return MacArtworkGridMetrics(
            columnCount: columns,
            itemWidth: max(120, item),
            horizontalPadding: padding,
            spacing: spacing
        )
    }

    /// 首页 shelf 使用较小 Artwork（180-210），保持 5-6 可见。
    static func home(availableWidth: CGFloat) -> MacArtworkGridMetrics {
        let padding = horizontalPadding(for: availableWidth)
        let spacing = MacUIVisualTokens.Content.homeShelfSpacing
        let content = max(0, availableWidth - padding * 2)
        let columns = max(4, columnCount(for: availableWidth))
        let item = (content - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return MacArtworkGridMetrics(
            columnCount: columns,
            itemWidth: min(max(150, item), 210),
            horizontalPadding: padding,
            spacing: spacing
        )
    }

    private static func horizontalPadding(for width: CGFloat) -> CGFloat {
        if width >= 1400 { return MacUIVisualTokens.Content.horizontalPaddingUltraWide }
        if width >= 1100 { return MacUIVisualTokens.Content.horizontalPaddingWide }
        if width >= 900 { return MacUIVisualTokens.Content.horizontalPaddingMedium }
        return MacUIVisualTokens.Content.horizontalPaddingCompact
    }

    private static func columnCount(for width: CGFloat) -> Int {
        if width < 680 { return 2 }
        if width < 930 { return 3 }
        if width < 1280 { return 4 }
        if width < 1540 { return 5 }
        return 6
    }
}
#endif
