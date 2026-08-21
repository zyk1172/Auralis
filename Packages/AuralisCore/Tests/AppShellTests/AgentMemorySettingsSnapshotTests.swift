import AgentKit
@testable import AppShell
import Foundation
import Testing

@Suite("Agent memory settings summary")
struct AgentMemorySettingsSnapshotTests {
    @Test("折叠分区只需展示条数、文件数与内容规模")
    func summariesDescribeHiddenContentWithoutListingIt() {
        let memories = [
            AgentMemoryEntry(key: "名字", value: "小明"),
            AgentMemoryEntry(key: "喜欢的歌手", value: "周杰伦"),
        ]
        let skills = [
            AgentSkillEntry(name: "夜跑", instructions: "生成夜跑歌单\n不要重复"),
        ]

        let snapshot = AgentMemorySettingsSnapshot(memories: memories, skills: skills)

        #expect(snapshot.memoryCount == 2)
        #expect(snapshot.skillCount == 1)
        #expect(["2 条 · 5 字符", "Entries: 2 · Characters: 5", "2 條 · 5 字元"].contains(snapshot.memorySummary))
        #expect(["1 个文件 · 11 字符", "Files: 1 · Characters: 11", "1 個檔案 · 11 字元"].contains(snapshot.skillSummary))
    }

    @Test("空分区摘要保持简洁")
    func emptySummaries() {
        let snapshot = AgentMemorySettingsSnapshot(memories: [], skills: [])
        #expect(["空", "Empty"].contains(snapshot.memorySummary))
        #expect(["空", "Empty"].contains(snapshot.skillSummary))
    }

    @Test("条目预览折叠空白并限制长度")
    func entryPreviewIsCompact() {
        #expect(AgentMemorySettingsSnapshot.preview("第一行\n\n第二行\t第三行") == "第一行 第二行 第三行")
        #expect(AgentMemorySettingsSnapshot.preview("123456789", limit: 5) == "12345…")
    }
}
