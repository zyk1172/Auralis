// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Testing
@testable import AppShell

/// 统一 iOS UI（iPhone + iPad 共用 IOSMusicShell）的纯布局策略回归：
/// - 浮动控件（Bottom Dock / AI 输入框）宽屏封顶 760pt、窄屏取满、无负数；
/// - 可读内容宽屏封顶 960pt；
/// - 44pt 最小触控目标不回退；
/// - 宽度函数单调不减。
@Suite("iOS layout metrics")
struct IOSLayoutMetricsTests {

    @Test("container 390 → 浮动控件取满可用宽度（不超过可用宽度）")
    func floatingChromeFitsPhoneWidth() {
        let width = IOSLayoutMetrics.floatingChromeWidth(containerWidth: 390)
        #expect(width == 390)
        #expect(width <= 390)
        #expect(width <= IOSLayoutMetrics.floatingChromeMaxWidth)
    }

    @Test("container 834 → 浮动控件封顶 760")
    func floatingChromeCapsAt760ForIpadPortrait() {
        let width = IOSLayoutMetrics.floatingChromeWidth(containerWidth: 834)
        #expect(width == 760)
        #expect(width <= IOSLayoutMetrics.floatingChromeMaxWidth)
    }

    @Test("container 1194 → 浮动控件仍封顶 760（横屏不横贯整屏）")
    func floatingChromeCapsAt760ForIpadLandscape() {
        let width = IOSLayoutMetrics.floatingChromeWidth(containerWidth: 1194)
        #expect(width == 760)
        #expect(width <= IOSLayoutMetrics.floatingChromeMaxWidth)
    }

    @Test("浮动控件宽度函数单调不减、无负数")
    func floatingChromeWidthIsMonotonicAndNonNegative() {
        let samples: [CGFloat] = [0, 320, 390, 760, 834, 1024, 1194, 2000]
        var previous: CGFloat = 0
        for container in samples {
            let width = IOSLayoutMetrics.floatingChromeWidth(containerWidth: container)
            #expect(width >= 0)
            #expect(width >= previous)
            previous = width
        }
        #expect(IOSLayoutMetrics.floatingChromeWidth(containerWidth: -100) == 0)
    }

    @Test("44pt 触控目标规则不回退")
    func touchTargetStaysAtLeast44() {
        #expect(IOSLayoutMetrics.minimumTouchTargetHeight >= 44)
    }

    @Test("可读内容宽度：窄屏取满、宽屏封顶 960，无负数")
    func readableContentWidthCapsAt960() {
        #expect(IOSLayoutMetrics.readableContentWidth(containerWidth: 390) == 390)
        #expect(IOSLayoutMetrics.readableContentWidth(containerWidth: 834) == 834)
        #expect(IOSLayoutMetrics.readableContentWidth(containerWidth: 1194) == 960)
        #expect(IOSLayoutMetrics.readableContentWidth(containerWidth: -1) == 0)
    }

    @Test("播放页内容宽度 token 与浮动控件上限一致（不铺满宽屏）")
    func playerAndFloatingTokensStayBounded() {
        #expect(IOSLayoutMetrics.playerContentMaxWidth < IOSLayoutMetrics.readableContentMaxWidth)
        #expect(IOSLayoutMetrics.floatingChromeMaxWidth <= IOSLayoutMetrics.readableContentMaxWidth)
    }

    @Test("正在播放页按实际容器宽高切换横屏双栏")
    func nowPlayingUsesLandscapeLayoutForWideContainers() {
        #expect(!NowPlayingLayoutPolicy.usesLandscapeLayout(containerSize: CGSize(width: 390, height: 844)))
        #expect(NowPlayingLayoutPolicy.usesLandscapeLayout(containerSize: CGSize(width: 844, height: 390)))
        #expect(NowPlayingLayoutPolicy.usesLandscapeLayout(containerSize: CGSize(width: 1194, height: 834)))
        #expect(!NowPlayingLayoutPolicy.usesLandscapeLayout(containerSize: CGSize(width: 0, height: 0)))
    }

    @Test("横屏封面受窗口高度和平台上限约束")
    func nowPlayingLandscapeArtworkStaysBounded() {
        let phone = NowPlayingLayoutPolicy.landscapeArtworkSide(
            containerSize: CGSize(width: 844, height: 390),
            isPad: false
        )
        #expect(phone >= 220)
        #expect(phone <= 360)
        #expect(phone <= 390 * 0.78 + 0.001)

        let pad = NowPlayingLayoutPolicy.landscapeArtworkSide(
            containerSize: CGSize(width: 1194, height: 834),
            isPad: true
        )
        #expect(pad >= phone)
        #expect(pad <= 520)
        #expect(pad <= 1194 * 0.40 + 0.001)
    }
}
