#if os(macOS)
import CoreGraphics

/// Mac 专用视觉几何参数（不是主题系统）。
///
/// 这是「截图驱动」的多模态视觉迭代的唯一入口：所有高频调整的
/// 间距 / 尺寸 / 圆角 / 字体大小集中在这里，视觉 Agent 只改本文件，
/// 不允许进入业务层（AppModel / 导航 / 播放 / 数据模型）。
///
/// 响应式算法（根据窗口宽度算列数 / 封面尺寸）仍由 MacArtworkGridMetrics /
/// MacFullPlayerMetrics 负责，它们只引用这里的常量。
enum MacUIVisualTokens {
    // MARK: - Sidebar

    enum Sidebar {
        static let minWidth: CGFloat = 210
        static let idealWidth: CGFloat = 260
        static let maxWidth: CGFloat = 300
    }

    // MARK: - Content

    enum Content {
        static let horizontalPaddingCompact: CGFloat = 24
        static let horizontalPaddingMedium: CGFloat = 32
        static let horizontalPaddingWide: CGFloat = 40
        static let horizontalPaddingUltraWide: CGFloat = 46
        /// 普通内容页纵向网格行距。
        static let gridRowSpacing: CGFloat = 28
        /// 专辑页 / 首页网格列距（MacArtworkGridMetrics 使用）。
        static let gridColumnSpacing: CGFloat = 24
        static let homeShelfSpacing: CGFloat = 20
    }

    // MARK: - Artwork

    enum Artwork {
        static let cornerRadius: CGFloat = 10
        /// 流派 / 艺术家页自适应网格列距。
        static let gridGap: CGFloat = 20
        /// 封面 tile 内「封面→标题」间距。
        static let tileTitleSpacing: CGFloat = 7
        /// 未显式指定大小时的兜底 tile 尺寸（搜索等小尺寸场景）。
        static let tileFallbackSize: CGFloat = 168
        /// 搜索页专辑结果封面尺寸。
        static let searchResultSize: CGFloat = 168
        /// 搜索页专辑结果圆角。
        static let searchResultCornerRadius: CGFloat = 10
    }

    // MARK: - Typography

    enum Typography {
        static let pageTitle: CGFloat = 30
        static let sectionTitle: CGFloat = 21
        static let tileTitle: CGFloat = 13
        static let tileSubtitle: CGFloat = 12
        static let floatingPlayerTitle: CGFloat = 13
        static let floatingPlayerSubtitle: CGFloat = 12
        static let lyricActive: CGFloat = 29
        static let lyricInactive: CGFloat = 23
        static let queueTrackTitle: CGFloat = 13
        static let queueTrackSubtitle: CGFloat = 12
    }

    // MARK: - Floating Player

    enum FloatingPlayer {
        /// 对齐 Music.app 的内容区播放条：不覆盖 Sidebar，宽度覆盖主要内容列而非做成窄胶囊。
        static let maxWidth: CGFloat = 1_200
        /// 胶囊本体高度；外部安全区留白不计入此值。
        static let height: CGFloat = 68
        static let topInset: CGFloat = 10
        static let bottomInset: CGFloat = 14
        static let horizontalInset: CGFloat = 64
        static let artworkSize: CGFloat = 44
        static let artworkCornerRadius: CGFloat = 6
        static let sideMinWidth: CGFloat = 230
        static let sideMaxWidth: CGFloat = 260
        static let sectionSpacing: CGFloat = 10
        static let controlSpacing: CGFloat = 14
        static let contextSpacing: CGFloat = 12
        static let identitySpacing: CGFloat = 12
        static let titleMaxWidth: CGFloat = 260
        static let innerHorizontalPadding: CGFloat = 14
        static let volumePopoverWidth: CGFloat = 160
        static let volumePopoverPadding: CGFloat = 12
        static let volumePopoverContentSpacing: CGFloat = 8
    }

    // MARK: - Expanded Player

    enum ExpandedPlayer {
        /// 左轨道不是「封面宽度」：封面居中于一条固定控制轨道，歌曲资料/进度/控制同轨对齐。
        static let playerColumnMin: CGFloat = 440
        static let playerColumnMax: CGFloat = 520
        static let playerColumnWidthRatio: CGFloat = 0.316
        static let artworkMin: CGFloat = 280
        static let artworkMax: CGFloat = 420
        static let artworkWidthRatio: CGFloat = 0.23
        static let artworkHeightRatio: CGFloat = 0.36
        static let leftMarginRatio: CGFloat = 0.092
        /// Music.app 的封面在窗口内容中部开始；右侧队列则更靠上。
        static let topInsetMin: CGFloat = 190
        static let topInsetMax: CGFloat = 260
        static let topInsetRatio: CGFloat = 0.23
        static let contextTopInsetMin: CGFloat = 118
        static let contextTopInsetMax: CGFloat = 142
        static let contextTopInsetRatio: CGFloat = 0.12
        static let horizontalGapMin: CGFloat = 108
        static let horizontalGapRatio: CGFloat = 0.09
        static let artworkCornerRadius: CGFloat = 14
        /// 播放器列内各区块间距。
        static let columnBlockSpacing: CGFloat = 24
        static let trackRowSpacing: CGFloat = 4
        static let progressSpacing: CGFloat = 4
        static let transportSpacing: CGFloat = 10
        static let lyricsLineGap: CGFloat = 20
        static let queueRowSpacing: CGFloat = 8
        static let topLeftGlassHeight: CGFloat = 44
        static let topLeftGlassPaddingH: CGFloat = 18
        /// 紧邻 traffic lights 后的系统安全位置，和 Music.app 的 close / mini group 对齐。
        static let topLeftGlassPaddingL: CGFloat = 140
        static let topLeftGlassPaddingT: CGFloat = 12
        static let topRightGlassHeight: CGFloat = 46
        static let topRightGlassPaddingH: CGFloat = 18
        static let topRightGlassPaddingR: CGFloat = 20
        /// 与左侧收起 / 迷你播放器控制保持同一水平线。
        static let topRightGlassPaddingT: CGFloat = 12
        static let topRightGlassWidth: CGFloat = 150
        static let topRightControlSpacing: CGFloat = 22
    }

    // MARK: - Mini Player

    enum MiniPlayer {
        static let artworkSize: CGFloat = 220
        static let artworkCornerRadius: CGFloat = 12
        static let windowWidth: CGFloat = 252
        static let windowHeight: CGFloat = 380
        static let compactWindowWidth: CGFloat = 300
        static let compactWindowHeight: CGFloat = 120
        static let contentSpacing: CGFloat = 10
        static let controlSpacing: CGFloat = 18
    }

    // MARK: - Right Panel (Inspector)

    enum RightPanel {
        static let minWidth: CGFloat = 300
        static let idealWidth: CGFloat = 340
        static let maxWidth: CGFloat = 420
    }
}
#endif
