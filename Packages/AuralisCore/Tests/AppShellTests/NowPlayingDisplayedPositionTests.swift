@testable import AppShell
import Foundation
import Testing

/// P0-1 回归：拖动进度条时，左/右时间文字与滑块使用 pendingSeek 显示值，
/// 松手前不显示真实播放位置（否则会出现滑块 2:30、文字 0:45 的不同步）。
@Suite("Now Playing displayed playback position")
struct NowPlayingDisplayedPositionTests {
    @Test("未拖动：显示真实播放位置")
    func showsActualPositionWhenNotScrubbing() {
        let value = NowPlayingView.displayedPlaybackPosition(
            pendingSeek: nil,
            actualPosition: 30,
            duration: 300
        )
        #expect(value == 30)
    }

    @Test("拖动中：pendingSeek 比例换算成秒（150/300 → 150 秒）")
    func showsPendingSeekInSeconds() {
        let value = NowPlayingView.displayedPlaybackPosition(
            pendingSeek: 0.5,
            actualPosition: 30,
            duration: 300
        )
        #expect(abs(value - 150) < 0.0001)
    }

    @Test("拖动中：pendingSeek 越界被夹到 0...1")
    func clampsPendingSeek() {
        let above = NowPlayingView.displayedPlaybackPosition(
            pendingSeek: 1.4,
            actualPosition: 30,
            duration: 300
        )
        #expect(abs(above - 300) < 0.0001)
        let below = NowPlayingView.displayedPlaybackPosition(
            pendingSeek: -0.2,
            actualPosition: 30,
            duration: 300
        )
        #expect(abs(below) < 0.0001)
    }
}
