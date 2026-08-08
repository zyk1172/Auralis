import Application
import Testing

@Suite("流质量策略")
struct StreamQualityPolicyTests {
    @Test("蜂窝 + 允许转码 → 320kbps MP3")
    func cellularTranscodes() {
        let policy = StreamQualityPolicy(
            highQualityOnWiFi: { true },
            cellularTranscodingAllowed: { true },
            isCellular: { true }
        )
        #expect(policy.maxBitRate == 320)
        #expect(policy.format == "mp3")
    }

    @Test("蜂窝 + 禁止转码 → 原始质量")
    func cellularWithoutTranscodeKeepsOriginal() {
        let policy = StreamQualityPolicy(
            highQualityOnWiFi: { true },
            cellularTranscodingAllowed: { false },
            isCellular: { true }
        )
        #expect(policy.maxBitRate == nil)
        #expect(policy.format == nil)
    }

    @Test("Wi-Fi + 优先原始 → 原始质量")
    func wifiHighQualityKeepsOriginal() {
        let policy = StreamQualityPolicy(
            highQualityOnWiFi: { true },
            cellularTranscodingAllowed: { true },
            isCellular: { false }
        )
        #expect(policy.maxBitRate == nil)
    }

    @Test("Wi-Fi + 关闭优先原始 → 限制码率")
    func wifiWithoutHighQualityCapsBitrate() {
        let policy = StreamQualityPolicy(
            highQualityOnWiFi: { false },
            cellularTranscodingAllowed: { true },
            isCellular: { false }
        )
        #expect(policy.maxBitRate == 320)
        #expect(policy.format == "mp3")
    }
}
