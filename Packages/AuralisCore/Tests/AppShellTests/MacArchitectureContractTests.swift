@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// Mac Architecture Freeze：导航 / Expanded Presentation / Sidebar 偏好 /
/// 循环模式 UI 的契约测试。只测行为，不测源码字符串。
@Suite("Mac architecture contract")
struct MacArchitectureContractTests {
    /// 惰性引擎：只记录状态，不产生真实音频输出。
    private actor InertPlaybackEngine: PlaybackControlling {
        private var playbackState = PlaybackState.idle
        func state() -> PlaybackState { playbackState }
        func play(track: Track) { playbackState = .playing }
        func pause() { playbackState = .paused }
        func resume() { playbackState = .playing }
        func stop() { playbackState = .idle }
    }
    // MARK: - Navigation back

    @MainActor
    @Test("back() 只弹出 detail path，不改变 sidebar selection")
    func navigationBackPopsPathOnly() {
        let nav = MacNavigationModel()
        nav.selectSidebar(.home)
        nav.push(.album(MacEntityRouteID(serverID: "server", remoteID: "a1")))
        nav.push(.artist(MacEntityRouteID(serverID: "server", remoteID: "ar1")))
        #expect(nav.path.count == 2)
        nav.back()
        #expect(nav.path.count == 1)
        #expect(nav.selection == .home) // 一级 selection 不受影响
        if case let .album(id) = nav.path[0] {
            #expect(id.remoteID == "a1")
        } else {
            Issue.record("expected album route")
        }
        nav.back()
        #expect(nav.path.isEmpty)
        nav.back() // 空 path 安全
        #expect(nav.path.isEmpty)
    }

    // MARK: - Expanded Presentation（同窗口，不改导航）

    @MainActor
    @Test("expand/collapse 是纯展示状态，不改导航 selection/path")
    func expandedPresentationDoesNotTouchNavigation() {
        let nav = MacNavigationModel()
        nav.selectSidebar(.albums)
        nav.push(.album(MacEntityRouteID(serverID: "server", remoteID: "a1")))
        let state = MacPlayerPresentationState()

        state.expand()
        #expect(state.isExpanded)
        #expect(nav.selection == .albums)
        #expect(nav.path.count == 1)

        state.collapse()
        #expect(!state.isExpanded)
        #expect(nav.selection == .albums)
        #expect(nav.path.count == 1)
    }

    @MainActor
    @Test("context toggle：点当前项关闭，点另一项切换")
    func expandedContextToggle() {
        let state = MacPlayerPresentationState()
        #expect(state.context == .none)
        state.toggleContext(.lyrics)
        #expect(state.context == .lyrics)
        state.toggleContext(.queue)
        #expect(state.context == .queue)
        state.toggleContext(.queue)
        #expect(state.context == .none)
    }

    @MainActor
    @Test("每次展开均从无 context 的居中主轨开始")
    func expandAlwaysStartsWithoutContext() {
        let state = MacPlayerPresentationState()
        state.expand()
        #expect(state.presentation == .expanded)
        #expect(state.context == .none)

        state.toggleContext(.queue)
        #expect(state.context == .queue)
        state.toggleContext(.queue)
        #expect(state.context == .none)

        state.toggleContext(.lyrics)
        #expect(state.context == .lyrics)
        state.collapse()
        state.expand()
        #expect(state.presentation == .expanded)
        #expect(state.context == .none)
    }

    // MARK: - Mac 循环模式 UI（cycleRepeatMode）

    @MainActor
    @Test("cycleRepeatMode 依次：off → all → one → off")
    func cycleRepeatModeCycles() {
        let model = AuralisAppModel(
            engine: InertPlaybackEngine(),
            defaults: UserDefaults(suiteName: "cycle-repeat-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cycle-repeat-\(UUID().uuidString).sqlite")
        )
        model.setRepeatMode(.off)
        #expect(model.repeatMode == .off)
        model.cycleRepeatMode()
        #expect(model.repeatMode == .all)
        model.cycleRepeatMode()
        #expect(model.repeatMode == .one)
        model.cycleRepeatMode()
        #expect(model.repeatMode == .off)
    }
}
