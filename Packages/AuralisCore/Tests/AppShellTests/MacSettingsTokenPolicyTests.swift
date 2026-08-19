#if os(macOS)
import Foundation
import Testing
@testable import AppShell

@Suite("AI Token 自定义策略")
struct MacSettingsTokenPolicyTests {
    @Test("输出预设仍保留常用档位")
    func presetsRemainAvailable() {
        #expect(OutputTokenLimitPolicy.presets.contains(4_096))
        #expect(OutputTokenLimitPolicy.presets.contains(16_384))
        #expect(OutputTokenLimitPolicy.presets.contains(65_536))
        #expect(OutputTokenLimitPolicy.presets.contains(100_000))
    }

    @Test("输出值命中预设时仍识别为预设")
    func modeInferenceFollowsValue() {
        #expect(OutputTokenLimitPolicy.containsPreset(16_384))
        #expect(!OutputTokenLimitPolicy.containsPreset(16_000))
        #expect(OutputTokenLimitPolicy.containsPreset(100_000))
    }

    @Test("输出 Token 不再存在一百万上限")
    func outputHasNoArtificialUpperBound() {
        #expect(
            OutputTokenLimitPolicy.validationMessage(
                for: 2_000_000
            ) == nil
        )

        #expect(
            OutputTokenLimitPolicy.clamp(2_000_000)
                == 2_000_000
        )
    }

    @Test("输出 Token 仍保留最低值保护")
    func outputKeepsMinimum() {
        #expect(
            OutputTokenLimitPolicy.validationMessage(
                for: 100
            ) != nil
        )

        #expect(
            OutputTokenLimitPolicy.clamp(100)
                == 512
        )
    }

    @Test("上下文 Token 可超过一百万")
    func contextHasNoArtificialUpperBound() {
        #expect(
            ContextTokenLimitPolicy.validationMessage(
                for: 2_000_000
            ) == nil
        )

        #expect(
            ContextTokenLimitPolicy.clamp(2_000_000)
                == 2_000_000
        )
    }

    @Test("上下文仍保留最低 4096")
    func contextKeepsMinimum() {
        #expect(
            ContextTokenLimitPolicy.validationMessage(
                for: 1_000
            ) != nil
        )

        #expect(
            ContextTokenLimitPolicy.clamp(1_000)
                == 4_096
        )
    }
}
#endif
