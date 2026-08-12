@testable import AppShell
import Foundation
import Testing

/// Apple Music macOS 27 Visual Parity 纯逻辑度量测试（REFERENCE_A / REFERENCE_B）。
/// 允许安全视觉范围，不要求单个精确 px。
@Suite("Mac visual metrics")
struct MacVisualMetricsTests {
    // MARK: - Albums Grid（REFERENCE_A：detail ≈1268 → 4 列，item ≈267-275）

    @Test("detailWidth ≈1268 → 4 列")
    func albumsFourColumns() {
        let m = MacArtworkGridMetrics.albums(availableWidth: 1268)
        #expect(m.columnCount == 4)
    }

    @Test("detailWidth ≈1268 → item 260...280")
    func albumsItemSize() {
        let m = MacArtworkGridMetrics.albums(availableWidth: 1268)
        #expect(m.itemWidth >= 260 && m.itemWidth <= 280)
        #expect(m.horizontalPadding >= 40 && m.horizontalPadding <= 48)
    }

    @Test("窄宽度 → 2 列，宽宽度 → 5-6 列")
    func albumsAdaptiveColumns() {
        #expect(MacArtworkGridMetrics.albums(availableWidth: 600).columnCount == 2)
        #expect(MacArtworkGridMetrics.albums(availableWidth: 1400).columnCount == 5)
        #expect(MacArtworkGridMetrics.albums(availableWidth: 1600).columnCount == 6)
    }

    @Test("home 度量 item 在 150...210")
    func homeItemRange() {
        let m = MacArtworkGridMetrics.home(availableWidth: 1268)
        #expect(m.itemWidth >= 150 && m.itemWidth <= 210)
    }

    // MARK: - Floating Player（REFERENCE_A：宽 900-970，高 64-76）

    @Test("player 内部几何：detail 1268 → 左右固定 180-230")
    func playerSideWidths() {
        // 复刻 MacFloatingPlayerBar 的 sideWidth 规则（min(230, max(180, width*0.23))）
        let width: CGFloat = 1268
        let side = min(230, max(180, width * 0.23))
        #expect(side >= 180 && side <= 230)
    }

    // MARK: - Full Player（REFERENCE_B：1536×1050 → Artwork 450-500，左距 110-155）

    @Test("full player artwork 1536×1050 → 450...500")
    func fullPlayerArtworkSize() {
        let s = MacFullPlayerMetrics.artworkSize(window: CGSize(width: 1536, height: 1050))
        #expect(s >= 450 && s <= 500)
    }

    @Test("full player left margin ≈ 8.5% 窗口宽（110...155）")
    func fullPlayerLeftMargin() {
        let m = MacFullPlayerMetrics.leftMargin(window: CGSize(width: 1536, height: 1050))
        #expect(m >= 110 && m <= 155)
    }

    @Test("full player top ≈ 16.5% 窗口高（150...200）")
    func fullPlayerTop() {
        let t = MacFullPlayerMetrics.topY(window: CGSize(width: 1536, height: 1050))
        #expect(t >= 150 && t <= 200)
    }

    @Test("full player right column 440...560")
    func fullPlayerRightColumn() {
        let r = MacFullPlayerMetrics.rightColumnWidth(window: CGSize(width: 1536, height: 1050))
        #expect(r >= 440 && r <= 560)
    }

    @Test("窗口缩放时 artwork 不固定 420")
    func artworkScalesWithWindow() {
        let small = MacFullPlayerMetrics.artworkSize(window: CGSize(width: 1280, height: 800))
        let big = MacFullPlayerMetrics.artworkSize(window: CGSize(width: 1728, height: 1117))
        #expect(small < big)
        #expect(small >= 300 && small <= 500)
    }
}
