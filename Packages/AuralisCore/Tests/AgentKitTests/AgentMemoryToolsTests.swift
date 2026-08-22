import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - Test double

/// 只实现记忆 / 技能能力的 AgentSystemService；其余方法走默认实现。
private final class MemoryStubSystemService: AgentSystemService, @unchecked Sendable {
    var memories: [AgentMemoryEntry] = []
    var skills: [AgentSkillEntry] = []

    func agentMemories() async -> [AgentMemoryEntry] { memories }
    func saveMemory(key: String, value: String) async -> Bool {
        memories.removeAll { $0.key == key }
        memories.append(AgentMemoryEntry(key: key, value: value))
        return true
    }
    func deleteMemory(key: String) async -> Bool {
        let before = memories.count
        memories.removeAll { $0.key == key }
        return memories.count != before
    }
    func clearMemories() async -> Int {
        let count = memories.count
        memories.removeAll()
        return count
    }
    func agentSkills() async -> [AgentSkillEntry] { skills }
    func createSkill(name: String, instructions: String) async -> AgentSkillEntry? {
        let entry = AgentSkillEntry(name: name, instructions: instructions)
        skills.removeAll { $0.name == name }
        skills.append(entry)
        return entry
    }
    func readSkill(name: String) async -> AgentSkillEntry? {
        skills.first { $0.name == name }
    }
    func deleteSkill(name: String) async -> Bool {
        let before = skills.count
        skills.removeAll { $0.name == name }
        return skills.count != before
    }

    // 其余协议方法：固定桩返回值（默认实现未覆盖的必需方法）
    func appContext() async -> AgentAppContext { AgentAppContext() }
    func openPage(_ page: String) async -> Bool { true }
    func featureStatus() async -> AgentFeatureStatus { AgentFeatureStatus() }
    func listServers() async -> [AgentServerInfo] { [] }
    func currentServer() async -> AgentServerInfo? { nil }
    func testServerConnection() async -> AgentConnectionTestResult { AgentConnectionTestResult(success: true) }
    func serverCapabilities() async -> AgentCapabilitiesSummary { AgentCapabilitiesSummary() }
    func syncStatus() async -> AgentSyncStatus { AgentSyncStatus() }
    func networkStatus() async -> AgentNetworkStatus { AgentNetworkStatus() }
    func audioRoute() async -> AgentAudioRoute { AgentAudioRoute() }
    func storageStatus() async -> AgentStorageStatus { AgentStorageStatus() }
    func lyrics(for trackID: TrackID) async -> AgentLyricsResult { AgentLyricsResult() }
    func downloadOffline(trackID: TrackID) async -> Bool { true }
    func cacheStatus() async -> AgentCacheStatus { AgentCacheStatus() }
    func nowPlayingStatus() async -> AgentNowPlayingStatus { AgentNowPlayingStatus(title: "", artist: "", consistentWithApp: true) }
    func brokenArtwork(limit: Int) async -> [String] { [] }
    func staleCache(limit: Int) async -> [String] { [] }
    func recentlyAdded(days: Int, limit: Int) async -> [TrackCard] { [] }
    func mostPlayed(limit: Int) async -> [TrackCard] { [] }
    func topItems(kind: String, limit: Int) async -> [AgentTopItem] { [] }
    func formatDistribution() async -> [AgentFormatCount] { [] }
    func recommendByMood(_ mood: String, limit: Int) async -> AgentRecommendationResult { AgentRecommendationResult(mood: mood, tracks: []) }
    func recommendByConstraints(_ constraints: AgentRecommendationConstraints) async -> AgentRecommendationResult { AgentRecommendationResult(mood: "约束", tracks: []) }
    func diagnosticsReport() async -> String { "诊断报告" }
    func listeningSummary() async -> AgentListeningSummary { AgentListeningSummary(totalPlays: 0, uniqueTracks: 0, totalFavorites: 0) }
    func playbackDiagnostics() async -> AgentPlaybackDiagnostics { AgentPlaybackDiagnostics(state: "idle", mediaSource: "local", audioSessionActive: true, queueValid: true, isPlaying: false) }
    func recentErrors(limit: Int) async -> [AgentErrorRecord] { [] }
}

@Suite("记忆与技能工具执行")
struct AgentMemoryToolsTests {
    @Test("memory_save 保存成功并给出摘要")
    func memorySaveTool() async {
        let service = MemoryStubSystemService()
        let result = await SystemToolExecutor.execute(
            ToolCall(name: "memory_save", arguments: ["key": "名字", "value": "小明"]),
            descriptor: AgentToolRegistry.descriptor(for: "memory_save")!,
            systemService: service
        )
        #expect(result.success)
        #expect(result.summary.contains("小明"))
        #expect(service.memories.count == 1)
    }

    @Test("memory_list 空记忆给出占位，非空时列出全部")
    func memoryListTool() async {
        let service = MemoryStubSystemService()
        let empty = await SystemToolExecutor.execute(
            ToolCall(name: "memory_list", arguments: [:]),
            descriptor: AgentToolRegistry.descriptor(for: "memory_list")!,
            systemService: service
        )
        #expect(empty.success)
        #expect(empty.summary.contains("还没有记住"))

        await service.saveMemory(key: "名字", value: "小明")
        let listed = await SystemToolExecutor.execute(
            ToolCall(name: "memory_list", arguments: [:]),
            descriptor: AgentToolRegistry.descriptor(for: "memory_list")!,
            systemService: service
        )
        #expect(listed.summary.contains("1 条"))
        guard case let .text(text)? = listed.payload else {
            Issue.record("memory_list 应有文本载荷")
            return
        }
        #expect(text.contains("名字"))
        #expect(text.contains("小明"))
    }

    @Test("memory_delete 删除指定记忆")
    func memoryDeleteTool() async {
        let service = MemoryStubSystemService()
        await service.saveMemory(key: "名字", value: "小明")
        let result = await SystemToolExecutor.execute(
            ToolCall(name: "memory_delete", arguments: ["key": "名字"]),
            descriptor: AgentToolRegistry.descriptor(for: "memory_delete")!,
            systemService: service
        )
        #expect(result.success)
        #expect(result.summary.contains("名字"))
        #expect(service.memories.isEmpty)
    }

    @Test("memory_clear 清空全部记忆")
    func memoryClearTool() async {
        let service = MemoryStubSystemService()
        await service.saveMemory(key: "a", value: "1")
        await service.saveMemory(key: "b", value: "2")
        let result = await SystemToolExecutor.execute(
            ToolCall(name: "memory_clear", arguments: [:]),
            descriptor: AgentToolRegistry.descriptor(for: "memory_clear")!,
            systemService: service
        )
        #expect(result.success)
        #expect(result.summary.contains("2 条"))
        #expect(service.memories.isEmpty)
    }

    @Test("skill_create 落盘并返回技能名")
    func skillCreateTool() async {
        let service = MemoryStubSystemService()
        let result = await SystemToolExecutor.execute(
            ToolCall(name: "skill_create", arguments: ["name": "夜跑歌单", "instructions": "每晚生成节奏稳定的歌"]),
            descriptor: AgentToolRegistry.descriptor(for: "skill_create")!,
            systemService: service
        )
        #expect(result.success)
        #expect(result.summary.contains("夜跑歌单"))
        #expect(service.skills.count == 1)
    }

    @Test("skill_list / skill_read / skill_delete")
    func skillReadListDeleteTools() async {
        let service = MemoryStubSystemService()
        _ = await service.createSkill(name: "夜跑", instructions: "节奏稳定，120 BPM 以上")

        let list = await SystemToolExecutor.execute(
            ToolCall(name: "skill_list", arguments: [:]),
            descriptor: AgentToolRegistry.descriptor(for: "skill_list")!,
            systemService: service
        )
        #expect(list.success)
        #expect(list.summary.contains("1 个"))

        let read = await SystemToolExecutor.execute(
            ToolCall(name: "skill_read", arguments: ["name": "夜跑"]),
            descriptor: AgentToolRegistry.descriptor(for: "skill_read")!,
            systemService: service
        )
        #expect(read.success)
        guard case let .text(instructions)? = read.payload else {
            Issue.record("skill_read 应有文本载荷")
            return
        }
        #expect(instructions.contains("120 BPM"))

        let missing = await SystemToolExecutor.execute(
            ToolCall(name: "skill_read", arguments: ["name": "不存在"]),
            descriptor: AgentToolRegistry.descriptor(for: "skill_read")!,
            systemService: service
        )
        #expect(!missing.success)

        let deleted = await SystemToolExecutor.execute(
            ToolCall(name: "skill_delete", arguments: ["name": "夜跑"]),
            descriptor: AgentToolRegistry.descriptor(for: "skill_delete")!,
            systemService: service
        )
        #expect(deleted.success)
        #expect(service.skills.isEmpty)
    }

    @Test("executeV2 把记忆工具路由到系统服务（SystemToolNames 覆盖）")
    func v2RoutingRoutesMemoryTools() async throws {
        let service = MemoryStubSystemService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentMemoryTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalog = try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
        let result = await AgentToolkit.executeV2(
            ToolCall(name: "memory_save", arguments: ["key": "名字", "value": "小明"]),
            bridge: BridgeStub(),
            catalog: catalog,
            serverID: nil,
            systemService: service
        )
        #expect(result.success)
        #expect(service.memories.count == 1)
    }
}

// MARK: - 最小桩

private struct BridgeStub: AgentBridge {
    var activeServerID: ServerID? { nil }
    func currentTrack() -> Track? { nil }
    func currentQueue() -> [Track] { [] }
    func playTrack(globalID: GlobalID) async -> Bool { true }
    func playServerTrack(globalID: GlobalID) async -> Bool { false }
    func playAlbum(globalID: GlobalID) async -> Bool { true }
    func playPlaylist(globalID: GlobalID) async -> Bool { true }
    func playRandom(limit: Int) -> AgentMutationResult { .confirmed("ok") }
    func pause() {}
    func resume() {}
    func seek(seconds: TimeInterval) {}
    func next() {}
    func previous() {}
    func setShuffle(_ enabled: Bool) {}
    func setRepeatMode(_ mode: RepeatMode) {}
    func setPlaybackRate(_ rate: Float) {}
    func setSleepTimer(mode: String, minutes: TimeInterval) {}
    func cancelSleepTimer() {}
    func getSleepTimer() async -> (mode: String, remaining: TimeInterval) { ("off", 0) }
    func addToQueue(globalID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func playNext(globalID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult { .confirmed("ok") }
    func removeFromQueue(at index: Int) async -> AgentMutationResult { .confirmed("ok") }
    func reorderQueue(from: Int, to: Int) async -> AgentMutationResult { .confirmed("ok") }
    func clearQueue() async -> AgentMutationResult { .confirmed("ok") }
    func shuffleRemaining() async -> AgentMutationResult { .confirmed("ok") }
    func saveQueueAsPlaylist(name: String) async -> Bool { true }
    func createPlaylist(name: String) -> GlobalID? { nil }
    func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { .confirmed("ok") }
    func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult { .confirmed("ok") }
    func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult { .confirmed("ok") }
    func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult { .confirmed("ok") }
    func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult { .confirmed("ok") }
    func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult { .confirmed("ok") }
    func likeTrack(globalID: GlobalID) {}
    func unlikeTrack(globalID: GlobalID) {}
    func favoriteAlbum(globalID: GlobalID) {}
    func unfavoriteAlbum(globalID: GlobalID) {}
    func favoriteArtist(globalID: GlobalID) {}
    func unfavoriteArtist(globalID: GlobalID) {}
    func setRating(globalID: GlobalID, rating: Int) {}
    func clearRating(globalID: GlobalID) {}
    func listServers() async -> [ServerAccount] { [] }
    func getActiveServer() async -> ServerAccount? { nil }
    func testServerConnection(serverID: ServerID) async -> Bool { true }
    func addServer(displayName: String, baseURL: String, username: String, token: String) async -> AgentMutationResult { .confirmed("ok") }
    func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> AgentMutationResult { .confirmed("ok") }
    func switchServer(serverID: ServerID) async -> AgentMutationResult { .confirmed("ok") }
    func refreshLibrary() async {}
    func getSyncStatus() async -> [CatalogSyncStatus] { [] }
    func removeServer(serverID: ServerID) async {}
}


// MARK: - 系统提示词人设 / 记忆 / 技能注入

@Suite("系统提示词：小猫人设 + 记忆 + 技能")
struct AgentSystemPromptTests {
    @Test("人设：名字叫小猫、病娇但克制，功能描述保留")
    func personaInjected() {
        let prompt = AgentRunner.systemPrompt(context: AgentRunner.Context(), tools: [], nativeToolCalling: true)
        #expect(prompt.contains("小猫"))
        #expect(prompt.contains("Navidrome / OpenSubsonic"))
        #expect(prompt.contains("在线流媒体"))
        #expect(prompt.contains("memory_save"))
    }

    @Test("文本工具协议会列出推荐索引 V2 的完整工具链")
    func recommendationIndexV2ToolsAreListed() {
        let selected = ToolSelector.select(for: "构建推荐索引 V2", all: AgentToolRegistry.all)
        let prompt = AgentRunner.systemPrompt(context: AgentRunner.Context(), tools: selected, nativeToolCalling: false)
        #expect(prompt.contains("library_index_v2_status"))
        #expect(prompt.contains("library_index_v2_next_batch"))
        #expect(prompt.contains("library_index_v2_write_batch"))
    }

    @Test("索引任务的后续短指令也保留 V2 原生工具")
    func recommendationIndexV2ToolsRemainAvailableForContinuation() {
        let selected = ToolSelector.select(for: "继续", all: AgentToolRegistry.all)
        let names = Set(selected.map(\.name))
        #expect(names.contains("library_index_v2_status"))
        #expect(names.contains("library_index_v2_next_batch"))
        #expect(names.contains("library_index_v2_write_batch"))
    }

    @Test("记忆与技能注入：列出已存记忆与技能名")
    func memoryAndSkillsInjected() {
        let context = AgentRunner.Context(
            memories: [AgentMemoryEntry(key: "名字", value: "小明", updatedAt: .now)],
            skills: [AgentSkillEntry(name: "夜跑歌单", instructions: "每晚 10 点生成节奏稳定的歌", createdAt: .now)]
        )
        let prompt = AgentRunner.systemPrompt(context: context, tools: [], nativeToolCalling: true)
        #expect(prompt.contains("关于主人"))
        #expect(prompt.contains("名字"))
        #expect(prompt.contains("小明"))
        #expect(prompt.contains("可用技能"))
        #expect(prompt.contains("夜跑歌单"))
    }

    @Test("无记忆 / 无技能时给出占位文案")
    func emptyMemoryAndSkillPlaceholders() {
        let prompt = AgentRunner.systemPrompt(context: AgentRunner.Context(), tools: [], nativeToolCalling: false)
        // 占位文案跟随 App 语言：zh-Hans 为中文，en 为英文，zh-Hant 为繁体
        let hasMemoryPlaceholder = prompt.contains("还没有记住关于主人的事情")
            || prompt.contains("還沒有記住")
            || prompt.contains("No memories yet")
        let hasSkillPlaceholder = prompt.contains("还没有创建技能")
            || prompt.contains("還沒有創建技能")
            || prompt.contains("No skills yet")
        #expect(hasMemoryPlaceholder, "prompt should contain memory placeholder in any supported language")
        #expect(hasSkillPlaceholder, "prompt should contain skill placeholder in any supported language")
    }
}
