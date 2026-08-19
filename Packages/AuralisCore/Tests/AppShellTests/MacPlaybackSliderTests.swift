#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import AppShell

/// 回归 B（5242da83 引入）：MacPlaybackSlider 的拖动/提交状态机与
/// Coordinator 闭包刷新（切歌后不得持有旧 duration 闭包）。
@Suite("Mac playback slider scrub 状态机")
struct MacPlaybackSliderTests {
    private func makeCoordinator(
        onScrubStart: @escaping () -> Void = {},
        onScrubChange: @escaping (Double) -> Void = { _ in },
        onCommit: @escaping (Double) -> Void = { _ in }
    ) -> MacPlaybackSlider.Coordinator {
        MacPlaybackSlider.Coordinator(
            onCommit: onCommit,
            onScrubStart: onScrubStart,
            onScrubChange: onScrubChange
        )
    }

    // MARK: - 事件阶段判定

    @Test("拖动中事件 → scrubbing 阶段")
    func draggingEventsMapToScrubbing() {
        #expect(MacPlaybackSlider.phase(for: .leftMouseDown) == .scrubbing)
        #expect(MacPlaybackSlider.phase(for: .leftMouseDragged) == .scrubbing)
    }

    @Test("松手/键盘/未知事件 → commit 阶段")
    func commitEventsMapToCommit() {
        #expect(MacPlaybackSlider.phase(for: .leftMouseUp) == .commit)
        #expect(MacPlaybackSlider.phase(for: nil) == .commit)
        #expect(MacPlaybackSlider.phase(for: .keyDown) == .commit)
    }

    // MARK: - 状态机

    @Test("拖动开始只触发一次 onScrubStart，拖动中持续上报 scrubValue")
    func scrubbingRaisesStartOnceAndReportsValues() {
        var startCount = 0
        var reported: [Double] = []
        let coordinator = makeCoordinator(
            onScrubStart: { startCount += 1 },
            onScrubChange: { reported.append($0) }
        )

        coordinator.handle(value: 10, eventType: .leftMouseDragged)
        coordinator.handle(value: 30, eventType: .leftMouseDragged)
        coordinator.handle(value: 60, eventType: .leftMouseDragged)

        #expect(startCount == 1, "onScrubStart 只在 false→true 转变时调用一次")
        #expect(coordinator.isScrubbing == true)
        #expect(reported == [10, 30, 60])
    }

    @Test("松手：isScrubbing 复位、上报最终值、只 commit 一次")
    func mouseUpResetsAndCommitsOnce() {
        var commits: [Double] = []
        var reported: [Double] = []
        let coordinator = makeCoordinator(
            onScrubChange: { reported.append($0) },
            onCommit: { commits.append($0) }
        )

        coordinator.handle(value: 40, eventType: .leftMouseDragged)
        coordinator.handle(value: 120, eventType: .leftMouseUp)

        #expect(coordinator.isScrubbing == false)
        #expect(reported.last == 120, "松手前最后一次上报必须是最新滑块值")
        #expect(commits == [120], "松手只 commit 一次，值为最终位置")
    }

    @Test("键盘/程序化修改（无鼠标事件）：直接 commit，不进入 scrub")
    func keyboardAdjustmentCommitsImmediately() {
        var commits: [Double] = []
        var startCount = 0
        let coordinator = makeCoordinator(
            onScrubStart: { startCount += 1 },
            onCommit: { commits.append($0) }
        )

        coordinator.handle(value: 77, eventType: nil)

        #expect(startCount == 0)
        #expect(coordinator.isScrubbing == false)
        #expect(commits == [77])
    }

    @Test("完整拖动序列：mouseDown 起点、多次 dragged、mouseUp 提交，第二次拖动重新 start")
    func fullDragSequenceStartsOncePerGesture() {
        var startCount = 0
        var reported: [Double] = []
        var commits: [Double] = []
        let coordinator = makeCoordinator(
            onScrubStart: { startCount += 1 },
            onScrubChange: { reported.append($0) },
            onCommit: { commits.append($0) }
        )

        // 第一次拖动：mouseDown 起手。
        coordinator.handle(value: 20, eventType: .leftMouseDown)
        #expect(startCount == 1)
        #expect(reported == [20])
        #expect(commits.isEmpty)

        coordinator.handle(value: 30, eventType: .leftMouseDragged)
        coordinator.handle(value: 60, eventType: .leftMouseDragged)
        #expect(startCount == 1, "同一手势内 onScrubStart 只触发一次")
        #expect(reported == [20, 30, 60])

        coordinator.handle(value: 90, eventType: .leftMouseUp)
        #expect(coordinator.isScrubbing == false)
        #expect(reported.last == 90)
        #expect(commits == [90], "松手只 commit 一次，值为最终位置")

        // 第二次拖动：onScrubStart 必须再次触发（新的完整手势）。
        coordinator.handle(value: 10, eventType: .leftMouseDown)
        #expect(startCount == 2)
        #expect(commits == [90], "第二次拖动尚未提交")
        coordinator.handle(value: 40, eventType: .leftMouseUp)
        #expect(commits == [90, 40])
    }

    // MARK: - Coordinator 闭包刷新（回归核心）

    @Test("切歌后 onCommit 闭包可被替换——不再持有旧 duration 的 seek 比例")
    func onCommitClosureCanBeReplaced() {
        // 模拟歌曲 A（duration 300）创建 Coordinator：onCommit 捕获 /300。
        var lastProgress: Double = -1
        var coordinator = makeCoordinator(onCommit: { lastProgress = $0 / 300 })

        // 切到歌曲 B（duration 200）：updateNSView 刷新闭包 → 新闭包 /200。
        coordinator.onCommit = { lastProgress = $0 / 200 }

        // 用户拖到 100 秒并松手。
        coordinator.handle(value: 100, eventType: .leftMouseUp)

        #expect(abs(lastProgress - 0.5) < 0.0001,
                "切歌后必须用新 duration 计算比例（旧 /300 会得到 33% 而不是 50%）")
    }

    @Test("onScrubStart/onScrubChange 闭包同样可替换（切歌后刷新）")
    func scrubCallbacksCanBeReplaced() {
        var starts = 0
        var changes: [Double] = []
        let coordinator = makeCoordinator()

        // 模拟 updateNSView 刷新回调。
        coordinator.onScrubStart = { starts += 1 }
        coordinator.onScrubChange = { changes.append($0) }

        coordinator.handle(value: 5, eventType: .leftMouseDragged)
        coordinator.handle(value: 9, eventType: .leftMouseDragged)

        #expect(starts == 1)
        #expect(changes == [5, 9])
    }
}
#endif
