// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AppShell
import CoreGraphics
import DesignSystem
import Testing

@Suite("底部 Dock 安全区归属")
struct BottomDockReservationTests {
    @Test("实际滚动容器负责内容避让，AI 助手由输入栏独占")
    func scrollClearanceOwnership() {
        #expect(BottomDockReservationPolicy.scrollOwnsReservation(for: .home))
        #expect(BottomDockReservationPolicy.scrollOwnsReservation(for: .library))
        #expect(BottomDockReservationPolicy.scrollOwnsReservation(for: .browseDetail))
        #expect(!BottomDockReservationPolicy.scrollOwnsReservation(for: .assistant))
    }

    @Test("输入栏端点只改变视觉位置，不改变 safe-area 高度")
    func inputBarMatchesDockEndpoints() {
        let metrics = BottomChromeMetrics.standard

        #expect(
            AssistantDockInputLayout.horizontalPadding(
                focused: false,
                metrics: metrics,
                collapseProgress: 0
            ) == 0
        )
        #expect(
            AssistantDockInputLayout.bottomPadding(
                focused: false,
                metrics: metrics,
                collapseProgress: 0
            ) == metrics.bottomPadding
        )
        #expect(
            AssistantDockInputLayout.verticalLift(
                focused: false,
                metrics: metrics,
                collapseProgress: 0
            ) == metrics.spacing + metrics.dockHeight
        )

        #expect(
            AssistantDockInputLayout.horizontalPadding(
                focused: false,
                metrics: metrics,
                collapseProgress: 1
            ) == metrics.spacing + metrics.dockHeight
        )
        #expect(
            AssistantDockInputLayout.bottomPadding(
                focused: false,
                metrics: metrics,
                collapseProgress: 1
            ) == metrics.bottomPadding
        )
        #expect(
            AssistantDockInputLayout.verticalLift(
                focused: false,
                metrics: metrics,
                collapseProgress: 1
            ) == 0
        )
        #expect(
            AssistantDockInputLayout.scrollBottomClearance(metrics: metrics)
                == metrics.spacing + metrics.dockHeight
        )
    }

    @Test("输入焦点优先于 Dock 收拢布局")
    func focusedInputIgnoresDockCollapse() {
        let metrics = BottomChromeMetrics.standard

        #expect(
            AssistantDockInputLayout.horizontalPadding(
                focused: true,
                metrics: metrics,
                collapseProgress: 1
            ) == 0
        )
        #expect(
            AssistantDockInputLayout.bottomPadding(
                focused: true,
                metrics: metrics,
                collapseProgress: 1
            ) == AuralisSpacing.small
        )
        #expect(
            AssistantDockInputLayout.verticalLift(
                focused: true,
                metrics: metrics,
                collapseProgress: 1
            ) == 0
        )
    }

    @Test("输入栏布局会限制异常进度")
    func inputLayoutClampsProgress() {
        let metrics = BottomChromeMetrics.standard

        #expect(
            AssistantDockInputLayout.bottomPadding(
                focused: false,
                metrics: metrics,
                collapseProgress: 2
            ) == metrics.bottomPadding
        )
        #expect(
            AssistantDockInputLayout.horizontalPadding(
                focused: false,
                metrics: metrics,
                collapseProgress: -1
            ) == 0
        )
        #expect(
            AssistantDockInputLayout.verticalLift(
                focused: false,
                metrics: metrics,
                collapseProgress: -1
            ) == metrics.spacing + metrics.dockHeight
        )
        #expect(
            AssistantDockInputLayout.verticalLift(
                focused: false,
                metrics: metrics,
                collapseProgress: 2
            ) == 0
        )
    }
}
