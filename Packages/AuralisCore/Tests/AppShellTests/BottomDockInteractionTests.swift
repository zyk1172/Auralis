@testable import AppShell
import CoreGraphics
import Testing

@Suite("底部 Dock 终态交互")
struct BottomDockInteractionTests {
    @Test("收拢阈值切换到真实紧凑交互树")
    func terminalProgressUsesCollapsedInteractionLayer() {
        let threshold = BottomDockLayoutMetrics.compactInteractionThreshold

        #expect(BottomDockLayoutMetrics.interactionLayer(for: 0) == .morphing)
        #expect(BottomDockLayoutMetrics.interactionLayer(for: threshold - 0.001) == .morphing)
        #expect(BottomDockLayoutMetrics.interactionLayer(for: threshold) == .compact)
        #expect(BottomDockLayoutMetrics.interactionLayer(for: 1) == .compact)
        #expect(BottomDockLayoutMetrics.interactionLayer(for: 2) == .compact)
        #expect(BottomDockLayoutMetrics.interactionLayer(for: -1) == .morphing)
    }

    @Test("终态交互高度从展开 126pt 收为紧凑 62pt")
    func interactionHeightsMatchDockMetrics() {
        let metrics = BottomChromeMetrics.standard

        #expect(
            BottomDockLayoutMetrics.expandedInteractionHeight(
                barHeight: metrics.miniPlayerHeight,
                spacing: metrics.spacing,
                bottomPadding: metrics.bottomPadding
            ) == 126
        )
        #expect(
            BottomDockLayoutMetrics.compactInteractionHeight(
                barHeight: metrics.dockHeight,
                bottomPadding: metrics.bottomPadding
            ) == 62
        )
    }
}
