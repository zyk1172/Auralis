#if os(macOS)
import AppKit
import SwiftUI

/// macOS 专用播放进度条：NSSlider bridge。
///
/// 切断「SwiftUI Slider ↔ @State ↔ PlaybackStore.position ↔ Slider onChange」
/// 反馈链（日志里的 `onChange(of: Double) action tried to update multiple times per frame`）：
/// - `updateNSView` 只在非拖动且值真实变化时把外部 position 写入 NSSlider.doubleValue，
///   绝不反写 SwiftUI @State；
/// - 用户拖动由 NSSlider 自己处理，mouseUp（action 触发）时一次性调用 `onCommit(value)`，
///   由调用方执行 model.seek(...)。
struct MacPlaybackSlider: NSViewRepresentable {
    let value: Double
    let minValue: Double
    let maxValue: Double
    let isEnabled: Bool
    let onCommit: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            target: context.coordinator,
            action: #selector(Coordinator.sliderCommitted(_:))
        )
        slider.isContinuous = false // action 只在 mouseUp 触发一次
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        // NSViewRepresentable.updateNSView 在主线程执行，NSSlider 属性是
        // MainActor 隔离的：用 assumeIsolated 在 Swift 6 下安全访问。
        MainActor.assumeIsolated {
            slider.minValue = minValue
            slider.maxValue = maxValue
            slider.isEnabled = isEnabled
            // 非用户拖动（isHighlighted == false）时，只把外部 position 写入滑块；
            // 值没真实变化（容差）不写，避免无谓的 KVO/刷新。
            if !slider.isHighlighted, abs(slider.doubleValue - value) > 0.0005 {
                slider.doubleValue = value
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit)
    }

    final class Coordinator: NSObject {
        let onCommit: (Double) -> Void

        init(onCommit: @escaping (Double) -> Void) {
            self.onCommit = onCommit
        }

        @objc func sliderCommitted(_ sender: NSSlider) {
            // NSSlider action 在主线程触发；doubleValue 是 MainActor 隔离属性。
            let value = MainActor.assumeIsolated { sender.doubleValue }
            onCommit(value)
        }
    }
}
#endif
