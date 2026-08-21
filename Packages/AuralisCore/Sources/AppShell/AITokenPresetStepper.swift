import SwiftUI

/// AI 设置中可直接使用的模型能力档位。
///
/// 这些值对应常见模型的上下文窗口与单次输出上限。界面上的上下箭头
/// 在档位之间跳转，而不是按 1 token 或固定的微小步长递增。
enum AITokenLimitPresets {
    static let context: [Int] = [
        4_096,
        8_192,
        16_384,
        32_768,
        65_536,
        128_000,
        200_000,
        256_000,
        512_000,
        1_000_000
    ]

    static let output: [Int] = [
        512,
        1_024,
        2_048,
        4_096,
        8_192,
        16_384,
        32_768,
        65_536,
        100_000,
        128_000
    ]

    static func next(_ value: Int, in presets: [Int]) -> Int {
        presets.first(where: { $0 > value }) ?? presets.last ?? value
    }

    static func previous(_ value: Int, in presets: [Int]) -> Int {
        presets.last(where: { $0 < value }) ?? presets.first ?? value
    }

    static func formatted(_ value: Int) -> String {
        value.formatted(.number)
    }
}

/// 使用原生 Stepper 外观，但把每次增减映射到模型能力档位。
///
/// 保留原生 Stepper 能力，iPhone、iPad 与 macOS 都能使用键盘、辅助功能
/// 和系统控件操作；Binding setter 负责把原本的「+1/-1」转换为下一档/上一档。
struct AITokenPresetStepper: View {
    let title: String
    let presets: [Int]
    @Binding var value: Int

    var body: some View {
        Stepper(value: steppedValue, in: 0...maximumValue, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(AITokenLimitPresets.formatted(value)) token")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue("\(AITokenLimitPresets.formatted(value)) token")
    }

    private var maximumValue: Int {
        presets.last ?? value
    }

    private var steppedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { requestedValue in
                guard requestedValue != value else { return }
                value = requestedValue > value
                    ? AITokenLimitPresets.next(value, in: presets)
                    : AITokenLimitPresets.previous(value, in: presets)
            }
        )
    }
}
