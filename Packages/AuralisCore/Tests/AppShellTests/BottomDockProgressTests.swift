// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AppShell
import CoreGraphics
import SwiftUI
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

    @Test("原生滚动观察按 44pt 量化且顶部回弹不误触发")
    func nativeScrollBucketsIgnoreRubberBand() {
        #expect(BottomDockProgressReducer.scrollBucket(for: -120) == 0)
        #expect(BottomDockProgressReducer.scrollBucket(for: 0) == 0)
        #expect(BottomDockProgressReducer.scrollBucket(for: 43.9) == 0)
        #expect(BottomDockProgressReducer.scrollBucket(for: 44) == 1)
        #expect(BottomDockProgressReducer.scrollBucket(for: 95) == 2)

        #expect(BottomDockProgressReducer.terminalProgress(oldScrollBucket: 0, newScrollBucket: 1) == 1)
        #expect(BottomDockProgressReducer.terminalProgress(oldScrollBucket: 2, newScrollBucket: 1) == 0)
        #expect(BottomDockProgressReducer.terminalProgress(oldScrollBucket: 1, newScrollBucket: 1) == nil)
    }

    @Test("底部 rubber-band 不产生额外 Dock 桶变化")
    func bottomRubberBandIsClampedToMaximumScrollOffset() {
        let maximum: CGFloat = 176

        let atBottom = BottomDockProgressReducer.scrollBucket(
            for: maximum,
            maximumOffset: maximum
        )
        let overscrolled = BottomDockProgressReducer.scrollBucket(
            for: maximum + 120,
            maximumOffset: maximum
        )
        let bouncingBack = BottomDockProgressReducer.scrollBucket(
            for: maximum + 18,
            maximumOffset: maximum
        )

        #expect(atBottom == overscrolled)
        #expect(atBottom == bouncingBack)
        #expect(
            BottomDockProgressReducer.terminalProgress(
                oldScrollBucket: overscrolled,
                newScrollBucket: bouncingBack
            ) == nil
        )
    }

    @Test("底部临界值 settling 不会反向展开 Dock")
    func bottomBoundarySettlingUsesHysteresis() {
        // 177→175 会跨过旧的 44pt bucket 边界（4→3），但并不是用户回滚。
        let collapsed = BottomDockProgressReducer.hysteresisStep(
            anchor: 177,
            offset: 175,
            collapseProgress: 1
        )
        #expect(collapsed.terminalProgress == nil)
        #expect(collapsed.anchor == 177)

        // 只有从实际最大值反向移动满 44pt 才展开。
        let expanded = BottomDockProgressReducer.hysteresisStep(
            anchor: collapsed.anchor,
            offset: 133,
            collapseProgress: 1
        )
        #expect(expanded.terminalProgress == 0)
        #expect(expanded.anchor == 133)
    }

    @Test("展开态也要求真实向下滚满 44pt 才收拢")
    func expandedDockRequiresFullForwardTravel() {
        let shortMove = BottomDockProgressReducer.hysteresisStep(
            anchor: 100,
            offset: 143,
            collapseProgress: 0
        )
        #expect(shortMove.terminalProgress == nil)
        #expect(shortMove.anchor == 100)

        let collapse = BottomDockProgressReducer.hysteresisStep(
            anchor: shortMove.anchor,
            offset: 144,
            collapseProgress: 0
        )
        #expect(collapse.terminalProgress == 1)
        #expect(collapse.anchor == 144)
    }

    @Test("滚动采样同时裁掉顶部和底部 rubber-band")
    func clampedScrollSampleRemovesRubberBand() {
        #expect(
            BottomDockProgressReducer.clampedScrollSample(
                zeroBasedOffset: -30,
                maximumOffset: 177.8
            ) == 0
        )
        #expect(
            BottomDockProgressReducer.clampedScrollSample(
                zeroBasedOffset: 999,
                maximumOffset: 177.8
            ) == 177
        )
    }

    @Test("播放器可视胶囊使用独立宽度几何")
    func playerWidthUsesVisibleCapsuleGeometry() {
        let fullWidth: CGFloat = 760
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 0) == fullWidth)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 1) == 632)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 0.5) < fullWidth)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: 40, collapseProgress: 1) == BottomDockLayoutMetrics.minimumBarHeight)
        #expect(BottomDockLayoutMetrics.playerWidth(fullWidth: fullWidth, collapseProgress: 2) == 632)
    }

    @Test("Home Chrome 只允许当前页面清理自己的滚动来源")
    @MainActor
    func homeChromeKeepsCurrentSourceOwnership() {
        let chrome = HomeChromeState()

        chrome.beginInteraction(source: .home)
        #expect(chrome.activeSource == .home)

        chrome.beginInteraction(source: .browseDetail)
        #expect(chrome.activeSource == .browseDetail)

        // 首页离场回调迟到时，不能清掉已经进入详情页的新来源。
        chrome.endInteraction(source: .home)
        #expect(chrome.activeSource == .browseDetail)

        chrome.endInteraction(source: .browseDetail)
        #expect(chrome.activeSource == nil)
    }

    @Test("Home Chrome 页面避让高度来自共享度量")
    func homeChromeReservationUsesSharedMetrics() {
        let metrics = BottomChromeMetrics.standard
        #expect(metrics.reservedHeight(hasAccessory: false, collapseProgress: 0) == metrics.singleBarReservation)
        #expect(metrics.reservedHeight(hasAccessory: true, collapseProgress: 0) == metrics.expandedReservation)
        #expect(metrics.reservedHeight(hasAccessory: true, collapseProgress: 1) == metrics.singleBarReservation)
        #expect(metrics.reservedHeight(hasAccessory: true, collapseProgress: 0.5) == (metrics.expandedReservation + metrics.singleBarReservation) / 2)
        #expect(metrics.withSafeAreaBottom(34).safeAreaBottom == 34)
    }
}


@Suite("歌词页沉浸 Chrome")
struct LyricsChromePolicyTests {
    @Test("5 秒无操作后自动隐藏")
    func autoHideDelayIsFiveSeconds() {
        #expect(LyricsChromePolicy.autoHideDelay == .seconds(5))
    }

    @Test("向上滑隐藏、向下滑显示，短划和横划不触发")
    func verticalGestureChoosesLyricsChromeTerminalState() {
        #expect(LyricsChromePolicy.terminalHidden(for: .init(width: 2, height: -44)) == true)
        #expect(LyricsChromePolicy.terminalHidden(for: .init(width: 2, height: 80)) == false)
        #expect(LyricsChromePolicy.terminalHidden(for: .init(width: 1, height: -43)) == nil)
        #expect(LyricsChromePolicy.terminalHidden(for: .init(width: 80, height: -20)) == nil)
    }
}

@Suite("歌词逐字轻量强调")
struct LyricCharacterAnimationPolicyTests {
    @Test("逐行时间戳会换算为 0 到 1 的行内进度")
    func lineProgressUsesAdjacentLineTimes() {
        #expect(
            LyricCharacterAnimationPolicy.lineProgress(
                position: 12,
                lineStart: 10,
                nextLineStart: 14
            ) == 0.5
        )
        #expect(
            LyricCharacterAnimationPolicy.lineProgress(
                position: 8,
                lineStart: 10,
                nextLineStart: 14
            ) == 0
        )
        #expect(
            LyricCharacterAnimationPolicy.lineProgress(
                position: 20,
                lineStart: 10,
                nextLineStart: 14
            ) == 1
        )
        #expect(
            LyricCharacterAnimationPolicy.lineProgress(
                position: 12,
                lineStart: 10,
                nextLineStart: nil
            ) == nil
        )
    }

    @Test("逐字强调上限 1.1 倍，未唱到的字符基线 1.02 倍")
    func characterScaleIsVisibleAndBounded() {
        let active = LyricCharacterAnimationPolicy.scale(
            unitIndex: 2,
            unitCount: 5,
            progress: 0.5
        )
        #expect(abs(active - 1.1) < 0.0001)

        let upcoming = LyricCharacterAnimationPolicy.scale(
            unitIndex: 4,
            unitCount: 5,
            progress: 0.5
        )
        #expect(abs(upcoming - 1.02) < 0.0001)

        let fallback = LyricCharacterAnimationPolicy.scale(
            unitIndex: 0,
            unitCount: 5,
            progress: nil
        )
        #expect(abs(fallback - 1.06) < 0.0001)
    }

    @Test("唱过的字符保持放大，后续字符平滑加入")
    func sungCharactersRetainTheirScale() {
        for progress in [0.25, 0.5, 0.75, 1.0] {
            let sung = LyricCharacterAnimationPolicy.scale(
                unitIndex: 1,
                unitCount: 5,
                progress: progress
            )
            #expect(abs(sung - 1.1) < 0.0001)
        }

        let entering = LyricCharacterAnimationPolicy.scale(
            unitIndex: 2,
            unitCount: 5,
            progress: 0.375
        )
        #expect(abs(entering - 1.06) < 0.0001)

        for index in 0..<5 {
            let finished = LyricCharacterAnimationPolicy.scale(
                unitIndex: index,
                unitCount: 5,
                progress: 1
            )
            #expect(abs(finished - 1.1) < 0.0001)
        }
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

@Suite("歌词手动滚动与自动跟随")
struct LyricsScrollFollowStateTests {
    @Test("拖动及惯性过程中不允许自动跟随抢占滚动位置")
    func userScrollSuppressesPlaybackFollowing() {
        var state = LyricsScrollFollowState()
        #expect(state.isFollowingPlayback)
        for phase in [ScrollPhase.tracking, .interacting, .decelerating] {
            state.update(phase: phase)
            #expect(state.isUserScrolling)
            #expect(!state.isFollowingPlayback)
            let resumedWhileScrolling = state.resumeFollowing()
            #expect(!resumedWhileScrolling)
        }
        state.update(phase: .idle)
        #expect(!state.isUserScrolling)
        #expect(!state.isFollowingPlayback)
        let resumedAfterIdle = state.resumeFollowing()
        #expect(resumedAfterIdle)
        #expect(state.isFollowingPlayback)
    }

    @Test("程序滚动动画不打断跟随，再次触摸会暂停已恢复的跟随")
    func programmaticScrollDoesNotBecomeManualBrowsing() {
        var state = LyricsScrollFollowState()
        state.update(phase: .animating)
        #expect(!state.isUserScrolling)
        #expect(state.isFollowingPlayback)
        state.update(phase: .idle)
        #expect(state.isFollowingPlayback)
        state.update(phase: .tracking)
        state.update(phase: .idle)
        let resumedAfterIdle = state.resumeFollowing()
        #expect(resumedAfterIdle)
        state.update(phase: .tracking)
        #expect(!state.isFollowingPlayback)
        let resumedDuringNewTouch = state.resumeFollowing()
        #expect(!resumedDuringNewTouch)
    }
}
