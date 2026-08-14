@testable import AppShell
import Foundation
import Testing

/// Expanded Player 窗口 chrome 幂等策略的纯逻辑测试。
///
/// 覆盖「澜音」泄漏修复的核心决策函数 `MacExpandedChromePolicy`：
/// - 状态已正确 → 不需要任何修正（保证播放位置 tick 不会触发 titlebar 重排）
/// - 标题 / titleVisibility / titlebarAppearsTransparent / traffic lights
///   任一偏离 → 只返回对应的修正项
///
/// NSView 侧的接线（viewDidMoveToWindow 立即复检、onAppear 后的一次性延迟复检、
/// updateNSView 幂等复检、scheduleChromeLayout 合并）依赖真实窗口生命周期，无法
/// 在此无窗口环境下自动验证，标记为 MANUAL-VERIFY（不伪造）。
@Suite("Mac expanded chrome policy")
struct MacExpandedChromeTests {
    private func state(
        title: String = "",
        isTitleHidden: Bool = true,
        isTitlebarTransparent: Bool = true,
        areTrafficLightsHidden: Bool = true
    ) -> MacExpandedChromePolicy.WindowChromeState {
        .init(
            title: title,
            isTitleHidden: isTitleHidden,
            isTitlebarTransparent: isTitlebarTransparent,
            areTrafficLightsHidden: areTrafficLightsHidden
        )
    }

    @Test("状态全部正确 → 不需要任何修正（幂等）")
    func correctStateRequiresNoChanges() {
        let changes = MacExpandedChromePolicy.neededChanges(for: state())
        #expect(changes.isEmpty)
    }

    @Test("标题泄漏回 titlebar（如“澜音”）→ 只需清空标题")
    func leakedTitleNeedsClear() {
        let changes = MacExpandedChromePolicy.neededChanges(for: state(title: "澜音"))
        #expect(changes.clearTitle)
        #expect(!changes.hideTitle)
        #expect(!changes.makeTitlebarTransparent)
        #expect(!changes.hideTrafficLights)
        #expect(!changes.isEmpty)
    }

    @Test("titleVisibility 非 hidden → 需要隐藏标题可见性")
    func visibleTitleNeedsHide() {
        let changes = MacExpandedChromePolicy.neededChanges(for: state(isTitleHidden: false))
        #expect(changes.hideTitle)
        #expect(!changes.clearTitle)
        #expect(!changes.isEmpty)
    }

    @Test("titlebarAppearsTransparent 非 true → 需要透明 titlebar")
    func opaqueTitlebarNeedsTransparency() {
        let changes = MacExpandedChromePolicy.neededChanges(for: state(isTitlebarTransparent: false))
        #expect(changes.makeTitlebarTransparent)
        #expect(!changes.isEmpty)
    }

    @Test("原生 traffic lights 显示中 → 需要隐藏")
    func visibleTrafficLightsNeedHide() {
        let changes = MacExpandedChromePolicy.neededChanges(for: state(areTrafficLightsHidden: false))
        #expect(changes.hideTrafficLights)
        #expect(!changes.isEmpty)
    }

    @Test("多个偏离 → 返回全部对应修正")
    func multipleDeviationsAggregate() {
        let changes = MacExpandedChromePolicy.neededChanges(
            for: state(
                title: "澜音",
                isTitleHidden: false,
                isTitlebarTransparent: false,
                areTrafficLightsHidden: false
            )
        )
        #expect(changes.clearTitle)
        #expect(changes.hideTitle)
        #expect(changes.makeTitlebarTransparent)
        #expect(changes.hideTrafficLights)
        #expect(!changes.isEmpty)
    }

    @Test("修正后状态回到正确 → 不再需要修正（防抖/幂等）")
    func fixedStateBecomesIdempotent() {
        var changes = MacExpandedChromePolicy.neededChanges(for: state(title: "澜音"))
        #expect(!changes.isEmpty)
        changes = MacExpandedChromePolicy.neededChanges(for: state())
        #expect(changes.isEmpty)
    }

    @Test("原始要求不变：标题为空 + 隐藏 + 透明 + traffic lights 隐藏")
    func requiredChromeInvariant() {
        // 与审计要求一致：展开页期间 window.title == ""、
        // titleVisibility == .hidden、titlebarAppearsTransparent == true、
        // 原生 traffic lights 隐藏。
        let changes = MacExpandedChromePolicy.neededChanges(for: state())
        #expect(changes == MacExpandedChromePolicy.NeededChanges())
    }
}
