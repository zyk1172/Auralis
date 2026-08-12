import AgentKit
import AppShell
import Foundation
import Testing

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("AgentMemoryStore 跨会话记忆")
@MainActor
struct AgentMemoryStoreTests {
    @Test("保存后重新实例化仍然记得（跨会话持久化）")
    func memoryPersistsAcrossInstances() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        #expect(store.saveMemory(key: "名字", value: "小明"))
        #expect(store.saveMemory(key: "喜欢的歌手", value: "周杰伦"))
        #expect(store.memories.count == 2)

        // 模拟下一次会话：同一目录重新加载
        let reloaded = AgentMemoryStore(directory: dir)
        #expect(reloaded.memories.count == 2)
        #expect(reloaded.memories.first { $0.key == "名字" }?.value == "小明")
        #expect(reloaded.memories.first { $0.key == "喜欢的歌手" }?.value == "周杰伦")
    }

    @Test("同名 key 覆盖更新，不产生重复")
    func memoryUpsert() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        #expect(store.saveMemory(key: "名字", value: "小明"))
        #expect(store.saveMemory(key: "名字", value: "小红"))
        #expect(store.memories.count == 1)
        #expect(store.memories.first?.value == "小红")
    }

    @Test("空 key / 空 value / 含换行 key 被拒绝")
    func memoryRejectsInvalidInput() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        #expect(!store.saveMemory(key: "", value: "x"))
        #expect(!store.saveMemory(key: "名字", value: "  "))
        #expect(!store.saveMemory(key: "名字\n换行", value: "x"))
        #expect(store.memories.isEmpty)
    }

    @Test("delete 与 clear")
    func memoryDeleteAndClear() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        store.saveMemory(key: "a", value: "1")
        store.saveMemory(key: "b", value: "2")
        #expect(store.deleteMemory(key: "a"))
        #expect(!store.deleteMemory(key: "不存在"))
        #expect(store.memories.map(\.key) == ["b"])
        #expect(store.clearMemory() == 1)
        #expect(store.memories.isEmpty)
        #expect(store.clearMemory() == 0)
    }

    @Test("超过 200 条记忆不静默淘汰：全部保留")
    func memoryNoSilentEviction() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        for index in 0..<250 {
            #expect(store.saveMemory(key: "记忆\(index)", value: "值\(index)"))
        }
        #expect(store.memories.count == 250)
        // 最旧的一条仍然存在。
        #expect(store.memories.contains { $0.key == "记忆0" })
        #expect(store.memories.contains { $0.key == "记忆249" })

        // 重新实例化仍全部保留。
        let reloaded = AgentMemoryStore(directory: dir)
        #expect(reloaded.memories.count == 250)
    }

    @Test("技能：创建 / 列表 / 读取 / 删除，且跨实例持久化")
    func skillLifecycle() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        let created = store.createSkill(name: "夜跑歌单", instructions: "每晚 10 点生成一首节奏稳定的歌。\n- 优先推荐 120 BPM 以上\n- 不要重复")
        #expect(created?.name == "夜跑歌单")
        #expect(store.skills.count == 1)
        #expect(store.skills.first?.summary.contains("每晚 10 点") == true)

        let reloaded = AgentMemoryStore(directory: dir)
        #expect(reloaded.readSkill(name: "夜跑歌单")?.instructions.contains("120 BPM") == true)

        #expect(reloaded.deleteSkill(name: "夜跑歌单"))
        #expect(!reloaded.deleteSkill(name: "夜跑歌单"))
        #expect(reloaded.skills.isEmpty)
    }

    @Test("技能名被安全规范化（路径分隔符被替换）")
    func skillNameSanitization() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        guard let entry = store.createSkill(name: "a/b:c", instructions: "指令") else {
            Issue.record("创建技能失败")
            return
        }
        #expect(!entry.name.contains("/"))
        #expect(!entry.name.contains(":"))
        #expect(store.readSkill(name: "a/b:c")?.instructions == "指令")
        #expect(store.readSkill(name: entry.name)?.instructions == "指令")
    }

    @Test("空指令 / 空名字的技能创建失败")
    func skillRejectsInvalidInput() {
        let dir = makeTempDirectory()
        let store = AgentMemoryStore(directory: dir)
        #expect(store.createSkill(name: "", instructions: "x") == nil)
        #expect(store.createSkill(name: "x", instructions: "   ") == nil)
        #expect(store.skills.isEmpty)
    }
}
