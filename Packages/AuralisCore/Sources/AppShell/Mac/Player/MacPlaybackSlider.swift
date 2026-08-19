#if os(macOS)
import AppKit
import SwiftUI

/// macOS 专用播放进度条：NSSlider bridge。
///
/// 切断「SwiftUI Slider ↔ @State ↔ PlaybackStore.position ↔ Slider onChange」
/// 反馈链（日志里的 `onChange(of: Double) action tried to update multiple times per frame`）：
/// - `updateNSView` 只在非拖动且值真实变化时把外部 position 写入 NSSlider.doubleValue，
///   绝不反写 SwiftUI @State；
/// - 用户拖动由 NSSlider 自己处理，按事件阶段分派：拖动中持续上报 `onScrubChange`，
///   mouseUp（松手）时一次性调用 `onCommit(value)`，由调用方执行 model.seek(...)。
///
/// 回归修复（5242da83 引入的缺陷）：
/// - Coordinator 的 onCommit/onScrubStart/onScrubChange 在每次 `updateNSView` 刷新——
///   切歌后闭包重新捕获最新 duration，杜绝「旧 /300 比例 + 新滑块范围」错位；
/// - 拖动状态用事件类型判定（leftMouseDown/Dragged/Up），不再用 `isHighlighted`
///   猜 tracking（那只是控件高亮外观状态）。
struct MacPlaybackSlider: NSViewRepresentable {
    let value: Double
    let minValue: Double
    let maxValue: Double
    let isEnabled: Bool
    /// 拖动开始（false→true 转变时只调用一次）。
    var onScrubStart: () -> Void = {}
    /// 拖动中持续上报当前滑块值（调用方用于同步时间文字等显示）。
    var onScrubChange: (Double) -> Void = { _ in }
    /// 松手 / 键盘提交：只调用一次，由调用方执行 seek。
    var onCommit: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            target: context.coordinator,
            action: #selector(Coordinator.sliderAction(_:))
        )
        // isContinuous = true：拖动全程触发 action（down/dragged/up 都上报），
        // 由 Coordinator 按 NSApp.currentEvent 事件类型区分「拖动中」与「松手提交」。
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        // NSViewRepresentable.updateNSView 在主线程执行，NSSlider 属性是
        // MainActor 隔离的：用 assumeIsolated 在 Swift 6 下安全访问。
        MainActor.assumeIsolated {
            // 每次刷新回调闭包（回归修复）：切歌后 Coordinator 不再持有旧 duration 闭包。
            context.coordinator.onCommit = onCommit
            context.coordinator.onScrubStart = onScrubStart
            context.coordinator.onScrubChange = onScrubChange

            // range 只在真实变化时写入，避免拖动高频重设触发无谓重绘。
            if slider.minValue != minValue { slider.minValue = minValue }
            if slider.maxValue != maxValue { slider.maxValue = maxValue }
            slider.isEnabled = isEnabled

            // 非用户拖动时，只把外部 position 写入滑块；
            // 值没真实变化（容差）不写，避免无谓的 KVO/刷新。
            if !context.coordinator.isScrubbing, abs(slider.doubleValue - value) > 0.0005 {
                slider.doubleValue = value
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCommit: onCommit,
            onScrubStart: onScrubStart,
            onScrubChange: onScrubChange
        )
    }

    /// 事件阶段判定（独立纯函数，便于回归测试）。
    enum ScrubPhase: Equatable {
        /// 拖动中：上报 scrub 值。
        case scrubbing
        /// 结束/提交：上报最终值并 commit 一次。
        case commit
    }

    /// 纯函数：不访问任何 actor 隔离状态，供 @objc 回调（非隔离上下文）直接调用。
    nonisolated static func phase(for eventType: NSEvent.EventType?) -> ScrubPhase {
        switch eventType {
        case .leftMouseDown, .leftMouseDragged:
            return .scrubbing
        case .leftMouseUp:
            return .commit
        default:
            // 键盘方向键等程序化修改：立即提交（无拖动过程）。
            return .commit
        }
    }

    final class Coordinator: NSObject {
        var onCommit: (Double) -> Void
        var onScrubStart: () -> Void
        var onScrubChange: (Double) -> Void
        private(set) var isScrubbing = false

        init(
            onCommit: @escaping (Double) -> Void,
            onScrubStart: @escaping () -> Void,
            onScrubChange: @escaping (Double) -> Void
        ) {
            self.onCommit = onCommit
            self.onScrubStart = onScrubStart
            self.onScrubChange = onScrubChange
        }

        @objc func sliderAction(_ sender: NSSlider) {
            // NSSlider action 在主线程触发；doubleValue 是 MainActor 隔离属性。
            let value = MainActor.assumeIsolated { sender.doubleValue }
            let eventType = MainActor.assumeIsolated { NSApp.currentEvent?.type }
            handle(value: value, eventType: eventType)
        }

        /// 事件阶段分派（internal 便于回归测试直接注入事件类型）。
        func handle(value: Double, eventType: NSEvent.EventType?) {
            switch MacPlaybackSlider.phase(for: eventType) {
            case .scrubbing:
                if !isScrubbing {
                    isScrubbing = true
                    onScrubStart()
                }
                onScrubChange(value)
            case .commit:
                isScrubbing = false
                onScrubChange(value)
                onCommit(value)
            }
        }
    }
}
#endif
