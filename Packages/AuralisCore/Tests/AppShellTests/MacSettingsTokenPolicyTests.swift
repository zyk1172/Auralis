#if os(macOS)
import Foundation
import Testing
@testable import AppShell

/// 问题 2：Mac 设置「单次输出上限」自定义档位策略（纯逻辑）。
@Suite("输出 token 上限预设/自定义策略")
struct MacSettingsTokenPolicyTests {
    @Test("预设档位包含常见大档位（不限制在旧 64000 上限）")
    func presetsIncludeLargeValues() {
        #expect(OutputTokenLimitPolicy.presets.contains(4_096))
        #expect(OutputTokenLimitPolicy.presets.contains(16_384))
        #expect(OutputTokenLimitPolicy.presets.contains(65_536))
        #expect(OutputTokenLimitPolicy.presets.contains(100_000))
    }

    @Test("值命中预设 → 预设模式；否则 → 自定义（值即事实）")
    func modeInferenceFollowsValue() {
        #expect(OutputTokenLimitPolicy.containsPreset(16_384) == true)
        #expect(OutputTokenLimitPolicy.containsPreset(16_000) == false, "默认 16K 不在预设中，应显示为自定义")
        #expect(OutputTokenLimitPolicy.containsPreset(100_000) == true)
    }

    @Test("自定义任意合理正整数可入库（不限制在预设档位）")
    func customValuesAreAllowed() {
        for value in [4096, 8192, 16384, 32768, 65536, 100_000] {
            #expect(OutputTokenLimitPolicy.validationMessage(for: value) == nil, "\(value) 应合法")
        }
    }

    @Test("非法值校验并夹取到合法范围")
    func validationAndClamp() {
        #expect(OutputTokenLimitPolicy.validationMessage(for: 100) != nil)
        #expect(OutputTokenLimitPolicy.validationMessage(for: 2_000_000) != nil)
        #expect(OutputTokenLimitPolicy.clamp(100) == 512)
        #expect(OutputTokenLimitPolicy.clamp(2_000_000) == 1_000_000)
        #expect(OutputTokenLimitPolicy.clamp(16_384) == 16_384)
    }
}
#endif
