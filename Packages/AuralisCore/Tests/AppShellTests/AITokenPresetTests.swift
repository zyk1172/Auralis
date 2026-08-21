import Testing
@testable import AppShell

@Suite("AI Token 档位")
struct AITokenPresetTests {
    @Test("上下文档位覆盖常见窗口并到达一百万")
    func contextPresets() {
        #expect(AITokenLimitPresets.context.first == 4_096)
        #expect(AITokenLimitPresets.context.contains(128_000))
        #expect(AITokenLimitPresets.context.contains(256_000))
        #expect(AITokenLimitPresets.context.last == 1_000_000)
    }

    @Test("上下箭头按档位跳转")
    func steppingSkipsIndividualTokens() {
        #expect(AITokenLimitPresets.next(4_096, in: AITokenLimitPresets.context) == 8_192)
        #expect(AITokenLimitPresets.previous(8_192, in: AITokenLimitPresets.context) == 4_096)
        #expect(AITokenLimitPresets.next(950_000, in: AITokenLimitPresets.context) == 1_000_000)
        #expect(AITokenLimitPresets.previous(950_000, in: AITokenLimitPresets.context) == 512_000)
    }

    @Test("输出档位有明确上限")
    func outputPresets() {
        #expect(AITokenLimitPresets.output.first == 512)
        #expect(AITokenLimitPresets.output.contains(16_384))
        #expect(AITokenLimitPresets.output.last == 128_000)
    }
}
