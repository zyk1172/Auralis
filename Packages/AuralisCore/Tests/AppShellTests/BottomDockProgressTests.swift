@testable import AppShell
import CoreGraphics
import Testing

@Suite("底部 Dock 滚动进度")
struct BottomDockProgressTests {
    @Test("亚像素变化不发布而端点始终精确发布")
    func filtersTinyChangesButPublishesEndpoints() {
        let epsilon = BottomDockProgressReducer.publicationEpsilon
        #expect(!BottomDockProgressReducer.shouldPublish(current: 0.4, next: 0.4 + epsilon / 2))
        #expect(BottomDockProgressReducer.shouldPublish(current: 0.4, next: 0.4 + epsilon))
        #expect(BottomDockProgressReducer.shouldPublish(current: 0.999, next: 1))
        #expect(BottomDockProgressReducer.shouldPublish(current: 0.001, next: 0))
        #expect(!BottomDockProgressReducer.shouldPublish(current: 1, next: 1))
    }

    @Test("纵向手势结束会吸附端点而横向货架不会误触发")
    func verticalSwipeChoosesTerminalState() {
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 2, height: -48)) == 1)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 3, height: 52)) == 0)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 70, height: -18)) == nil)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 0, height: -8)) == nil)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 1, height: -43)) == nil)
    }

    @Test("同方向快慢滑动都只选择同一个端点")
    func swipeMagnitudeDoesNotControlAnimationProgress() {
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 2, height: -48)) == 1)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 2, height: -320)) == 1)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 2, height: 48)) == 0)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 2, height: 320)) == 0)
    }

    @Test("播放器命中区域跟随可视胶囊，不覆盖完整 Dock")
    func playerHitRegionUsesVisibleWidth() {
        let fullWidth: CGFloat = 760
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 0) == fullWidth)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 1) == 632)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 0.5) < fullWidth)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: 40, collapseProgress: 1) == BottomDockLayoutMetrics.minimumBarHeight)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 2) == 632)
    }
}

@Suite("播放页标题滚动判断")
struct MarqueeLayoutPolicyTests {
    @Test("能原样或轻微缩小完整显示的名称不滚动")
    func fittingNamesRemainStatic() {
        #expect(!MarqueeLayoutPolicy.shouldScroll(textWidth: 280, containerWidth: 300))
        #expect(!MarqueeLayoutPolicy.shouldScroll(textWidth: 348, containerWidth: 300))
    }

    @Test("真实超出最小缩放范围的名称才滚动")
    func trulyOverflowingNameScrolls() {
        #expect(MarqueeLayoutPolicy.shouldScroll(textWidth: 350, containerWidth: 300))
    }
}
