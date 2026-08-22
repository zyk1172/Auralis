#if os(macOS)
@testable import AppShell
import Domain
import Testing

@Suite("Mac lyrics follower")
struct MacLyricsFollowerTests {
    @Test("二分查找返回最后一条已开始的歌词")
    func resolvesLastStartedLine() {
        let lines = LyricsIndexResolver.timeline(for: [
            TimedLyricLine(startTime: nil, text: "前奏"),
            TimedLyricLine(startTime: 10, text: "第一句"),
            TimedLyricLine(startTime: 20, text: "第二句"),
            TimedLyricLine(startTime: 30, text: "第三句")
        ])

        #expect(LyricsIndexResolver.index(at: 0, in: lines) == nil)
        #expect(LyricsIndexResolver.index(at: 19.9, in: lines) == 1)
        #expect(LyricsIndexResolver.index(at: 20, in: lines) == 2)
        #expect(LyricsIndexResolver.index(at: 40, in: lines) == 3)
    }

    @Test("预读时间只影响激活时机，不改变原始行索引")
    func appliesLeadTime() {
        let lines = LyricsIndexResolver.timeline(for: [
            TimedLyricLine(startTime: 10, text: "第一句"),
            TimedLyricLine(startTime: 20, text: "第二句")
        ])

        #expect(LyricsIndexResolver.index(at: 19.9, in: lines) == 0)
        #expect(LyricsIndexResolver.index(at: 19.9, in: lines, leadTime: 0.15) == 1)
    }
}
#endif
