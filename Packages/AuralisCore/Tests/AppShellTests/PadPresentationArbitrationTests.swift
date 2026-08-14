@testable import AppShell
import Domain
import Testing

/// iPad 弹窗仲裁策略的单元测试：三个底层状态（服务器配置 / 正在播放 / 浏览详情）
/// 同一时刻至多呈现一个弹窗；优先级为 服务器配置 > 正在播放 > 浏览详情；
/// 正在播放与浏览详情彼此互斥，服务器配置只遮盖不销毁。
@Suite("iPad 弹窗仲裁策略")
struct PadPresentationArbitrationTests {

    // MARK: - presentedSheet：唯一呈现推导

    @Test("服务器配置优先于正在播放与浏览详情")
    func serverSetupTakesPrecedence() {
        #expect(PadPresentationArbitration.presentedSheet(
            serverSetupPresented: true,
            nowPlayingPresented: true,
            browseDestination: .random
        ) == .serverSetup)
        #expect(PadPresentationArbitration.presentedSheet(
            serverSetupPresented: true,
            nowPlayingPresented: false,
            browseDestination: .random
        ) == .serverSetup)
    }

    @Test("正在播放优先于浏览详情（两者同时为真也只呈现一个）")
    func nowPlayingTakesPrecedenceOverBrowse() {
        #expect(PadPresentationArbitration.presentedSheet(
            serverSetupPresented: false,
            nowPlayingPresented: true,
            browseDestination: .random
        ) == .nowPlaying)
    }

    @Test("仅浏览详情时呈现浏览弹窗")
    func browseOnly() {
        #expect(PadPresentationArbitration.presentedSheet(
            serverSetupPresented: false,
            nowPlayingPresented: false,
            browseDestination: .favorites
        ) == .browse(.favorites))
    }

    @Test("全部关闭时无弹窗")
    func nonePresented() {
        #expect(PadPresentationArbitration.presentedSheet(
            serverSetupPresented: false,
            nowPlayingPresented: false,
            browseDestination: nil
        ) == nil)
    }

    // MARK: - dismissals：打开动作时清除其它状态

    @Test("打开正在播放会关闭浏览详情")
    func openingNowPlayingDismissesBrowse() {
        let dismissals = PadPresentationArbitration.dismissals(
            opening: .nowPlaying,
            serverSetupPresented: false,
            nowPlayingPresented: false,
            browseDestination: .random
        )
        #expect(dismissals == PadPresentationArbitration.Dismissals(nowPlaying: false, browse: true))
    }

    @Test("服务器配置打开时打开正在播放被拒绝（不清除任何状态）")
    func openingNowPlayingBlockedByServerSetup() {
        let dismissals = PadPresentationArbitration.dismissals(
            opening: .nowPlaying,
            serverSetupPresented: true,
            nowPlayingPresented: false,
            browseDestination: .random
        )
        #expect(dismissals == .none)
    }

    @Test("打开浏览详情会关闭正在播放")
    func openingBrowseDismissesNowPlaying() {
        let dismissals = PadPresentationArbitration.dismissals(
            opening: .browse(.random),
            serverSetupPresented: false,
            nowPlayingPresented: true,
            browseDestination: nil
        )
        #expect(dismissals == PadPresentationArbitration.Dismissals(nowPlaying: true, browse: false))
    }

    @Test("服务器配置打开时打开浏览详情被拒绝（不清除任何状态）")
    func openingBrowseBlockedByServerSetup() {
        let dismissals = PadPresentationArbitration.dismissals(
            opening: .browse(.random),
            serverSetupPresented: true,
            nowPlayingPresented: true,
            browseDestination: nil
        )
        #expect(dismissals == .none)
    }

    @Test("打开服务器配置只遮盖不清除（关闭后可恢复）")
    func openingServerSetupPreservesOthers() {
        let dismissals = PadPresentationArbitration.dismissals(
            opening: .serverSetup,
            serverSetupPresented: false,
            nowPlayingPresented: true,
            browseDestination: .random
        )
        #expect(dismissals == .none)
    }

    // MARK: - 状态机：模拟 PadMusicShell 的绑定 + onChange 接线

    /// 忠实模拟 PadMusicShell 的接线：
    /// - 打开动作先应用 `dismissals`，再写入自身状态（等价于 onChange 仲裁 + get 推导）；
    /// - 关闭动作只清除当前实际呈现的那一个（等价于 `.sheet(item:)` 写入 nil）。
    private struct State {
        var serverSetup = false
        var nowPlaying = false
        var browse: BrowseDestination?

        var presented: PadPresentedSheet? {
            PadPresentationArbitration.presentedSheet(
                serverSetupPresented: serverSetup,
                nowPlayingPresented: nowPlaying,
                browseDestination: browse
            )
        }

        mutating func open(_ action: PadPresentationArbitration.Open) {
            let dismissals = PadPresentationArbitration.dismissals(
                opening: action,
                serverSetupPresented: serverSetup,
                nowPlayingPresented: nowPlaying,
                browseDestination: browse
            )
            if dismissals.nowPlaying { nowPlaying = false }
            if dismissals.browse { browse = nil }
            switch action {
            case .serverSetup: serverSetup = true
            case .nowPlaying: nowPlaying = true
            case let .browse(destination): browse = destination
            }
        }

        mutating func dismissPresented() {
            switch presented {
            case .serverSetup: serverSetup = false
            case .nowPlaying: nowPlaying = false
            case .browse: browse = nil
            case nil: break
            }
        }
    }

    @Test("浏览详情打开后打开正在播放：浏览被关闭，只呈现一个")
    func transitionBrowseToNowPlaying() {
        var state = State()
        state.open(.browse(.random))
        #expect(state.presented == .browse(.random))
        state.open(.nowPlaying)
        #expect(state.browse == nil)
        #expect(state.presented == .nowPlaying)
    }

    @Test("正在播放打开后打开浏览详情：正在播放被关闭，只呈现一个")
    func transitionNowPlayingToBrowse() {
        var state = State()
        state.open(.nowPlaying)
        #expect(state.presented == .nowPlaying)
        state.open(.browse(.favorites))
        #expect(state.nowPlaying == false)
        #expect(state.presented == .browse(.favorites))
    }

    @Test("服务器配置在浏览详情之上：遮盖并在关闭后恢复浏览")
    func serverSetupMasksAndRestoresBrowse() {
        var state = State()
        state.open(.browse(.random))
        state.open(.serverSetup)
        #expect(state.presented == .serverSetup)
        // 遮盖不销毁：浏览状态保留
        #expect(state.browse == .random)
        state.dismissPresented()
        #expect(state.presented == .browse(.random))
    }

    @Test("底层状态同时为真（历史遗留）也只呈现一个弹窗")
    func staleBothTruePresentsExactlyOne() {
        var state = State()
        state.serverSetup = false
        state.nowPlaying = true
        state.browse = .random
        #expect(state.presented == .nowPlaying)
        // 关闭正在播放后不会出现两个弹窗
        state.dismissPresented()
        #expect(state.presented == .browse(.random))
    }

    @Test("弹窗 id 稳定且彼此不同")
    func sheetIdentifiersAreStable() {
        let nowPlaying = PadPresentedSheet.nowPlaying
        let serverSetup = PadPresentedSheet.serverSetup
        let browseA = PadPresentedSheet.browse(.random)
        let browseB = PadPresentedSheet.browse(.favorites)
        #expect(nowPlaying.id != serverSetup.id)
        #expect(nowPlaying.id != browseA.id)
        #expect(browseA.id != browseB.id)
        #expect(browseA.id == PadPresentedSheet.browse(.random).id)
    }
}
