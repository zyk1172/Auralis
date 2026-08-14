import Foundation
import Testing
@testable import PlaybackEngine

/// 播放边界确定性状态机测试：不依赖真实 AVFoundation，覆盖
/// DidPlayToEnd / currentItem KVO 的两种到达顺序、prepared 失败、超时兜底与去重。
@Suite("PlayerItemBoundaryCoordinator")
struct PlayerItemBoundaryCoordinatorTests {
    @Test("无预载项时结束事件直接回调 trackEnded，且只一次")
    func naturalEndWithoutPrepared() {
        var c = PlayerItemBoundaryCoordinator()
        #expect(c.itemEnded(hasPrepared: false, currentItemIsPrepared: false) == [.handleTrackEnded])
        #expect(c.state == .idle)
        // 重复的结束事件（迟到的同一通知）不再重复处理。
        #expect(c.itemEnded(hasPrepared: false, currentItemIsPrepared: false) == [.handleTrackEnded])
    }

    @Test("E1 先到：进入 waiting，E2 确认 prepared 后只输出一次 completeTransition")
    func endBeforeCurrentItemChange() {
        var c = PlayerItemBoundaryCoordinator()
        #expect(c.itemEnded(hasPrepared: true, currentItemIsPrepared: false) == [])
        #expect(c.state == .waitingForPreparedAdvance)
        #expect(c.currentItemChanged(newItemIsPrepared: true) == [.completeTransition])
        #expect(c.state == .idle)
        // 同一边界不会再次输出 completeTransition。
        #expect(c.currentItemChanged(newItemIsPrepared: true) == [])
    }

    @Test("E2 先到：结束事件到达时 currentItem 已是 prepared，直接完成过渡")
    func currentItemChangeBeforeEnd() {
        var c = PlayerItemBoundaryCoordinator()
        #expect(c.itemEnded(hasPrepared: true, currentItemIsPrepared: true) == [.completeTransition])
        #expect(c.state == .idle)
    }

    @Test("waiting 中收到非 prepared 的 currentItem 变化不触发过渡")
    func unrelatedCurrentItemChangeIgnored() {
        var c = PlayerItemBoundaryCoordinator()
        _ = c.itemEnded(hasPrepared: true, currentItemIsPrepared: false)
        #expect(c.currentItemChanged(newItemIsPrepared: false) == [])
        #expect(c.state == .waitingForPreparedAdvance)
    }

    @Test("idle 下 currentItem 变化（首次 item/队列编辑）不触发过渡")
    func idleCurrentItemChangeIgnored() {
        var c = PlayerItemBoundaryCoordinator()
        #expect(c.currentItemChanged(newItemIsPrepared: true) == [])
        #expect(c.state == .idle)
    }

    @Test("prepared 在推进前失败：移除 prepared；waiting 时额外触发一次 trackEnded")
    func preparedFailureContracts() {
        var idleCoord = PlayerItemBoundaryCoordinator()
        #expect(idleCoord.preparedFailed() == [.removePrepared])
        #expect(idleCoord.state == .idle)

        var waitingCoord = PlayerItemBoundaryCoordinator()
        _ = waitingCoord.itemEnded(hasPrepared: true, currentItemIsPrepared: false)
        #expect(waitingCoord.preparedFailed() == [.removePrepared, .handleTrackEnded])
        #expect(waitingCoord.state == .idle)
    }

    @Test("超时兜底：仅在 waiting 时输出一次 removePrepared + handleTrackEnded")
    func fallbackTickContracts() {
        var idleCoord = PlayerItemBoundaryCoordinator()
        #expect(idleCoord.fallbackTick() == [])
        #expect(idleCoord.state == .idle)

        var waitingCoord = PlayerItemBoundaryCoordinator()
        _ = waitingCoord.itemEnded(hasPrepared: true, currentItemIsPrepared: false)
        #expect(waitingCoord.fallbackTick() == [.removePrepared, .handleTrackEnded])
        #expect(waitingCoord.state == .idle)
        // 兜底只执行一次。
        #expect(waitingCoord.fallbackTick() == [])
    }

    @Test("waiting 中收到重复结束事件被去重")
    func duplicateEndWhileWaitingIgnored() {
        var c = PlayerItemBoundaryCoordinator()
        _ = c.itemEnded(hasPrepared: true, currentItemIsPrepared: false)
        #expect(c.itemEnded(hasPrepared: true, currentItemIsPrepared: false) == [])
        #expect(c.state == .waitingForPreparedAdvance)
    }

    @Test("reset 回到 idle")
    func reset() {
        var c = PlayerItemBoundaryCoordinator()
        _ = c.itemEnded(hasPrepared: true, currentItemIsPrepared: false)
        c.reset()
        #expect(c.state == .idle)
    }
}
